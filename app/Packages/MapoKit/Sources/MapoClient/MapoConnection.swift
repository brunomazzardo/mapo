import Foundation
import MapoProtocol
import Network

/// A notification from the daemon, decoded off the main actor.
nonisolated public enum ServerNotification: Sendable {
    case event(Event)
    /// An `event` whose params didn't decode. The client resyncs from a fresh snapshot.
    case undecodable(method: String, reason: String)
    case other(method: String)
}

/// A request the daemon sends to the app, with a string id such as `"d-17"` (PLAN T0.9).
nonisolated public struct DaemonRequest: Sendable {
    public let id: RPCId
    public let method: String
    public let params: JSONValue
}

nonisolated public enum ConnectionError: Error, Sendable, CustomStringConvertible {
    /// The socket couldn't be reached: `ENOENT` when it doesn't exist, `ECONNREFUSED` when nobody listens.
    case posix(POSIXErrorCode)
    /// The connection closed before the reply arrived.
    case closed
    case timeout(method: String)
    case transport(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .posix(let code): "socket error \(code.rawValue) (\(String(cString: strerror(code.rawValue))))"
        case .closed: "connection closed"
        case .timeout(let method): "\(method) timed out"
        case .transport(let message): "transport error: \(message)"
        case .malformed(let message): "malformed message: \(message)"
        }
    }

    /// True when no daemon serves the socket, which is when the app may spawn one.
    public var isDaemonAbsent: Bool {
        if case .posix(let code) = self { return code == .ENOENT || code == .ECONNREFUSED }
        return false
    }
}

/// One control connection to mapod: JSON-RPC 2.0 over NDJSON on the instance's Unix socket (PROTOCOL §1).
///
/// All socket I/O and bookkeeping run on a private serial queue; the main thread never waits on the
/// socket. Responses resume the caller's continuation, notifications feed `notifications`, and daemon
/// requests go to `requestHandler` on the main actor. The stream finishes when the connection closes.
nonisolated public final class MapoConnection: @unchecked Sendable {
    public typealias RequestHandler = @MainActor @Sendable (DaemonRequest) async -> Result<JSONValue, RPCError>

    public let socketPath: String
    public let notifications: AsyncStream<ServerNotification>

    private let queue = DispatchQueue(label: "dev.mapo.app.connection")
    private let connection: NWConnection
    private let notificationSink: AsyncStream<ServerNotification>.Continuation
    // Everything below is confined to `queue`.
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: @Sendable (Result<Data, Error>) -> Void] = [:]
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var isClosed = false
    private var requestHandler: RequestHandler?

    public init(socketPath: String) {
        self.socketPath = socketPath
        self.connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        (notifications, notificationSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        connection.cancel()
    }

    /// Connects. Throws `ConnectionError.posix` when the socket is missing or refuses the connection.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                startWaiter = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                connection.start(queue: queue)
            }
        }
    }

    /// Handles daemon-originated requests. Without a handler they get `unavailable`.
    public func setRequestHandler(_ handler: RequestHandler?) {
        queue.async { [self] in requestHandler = handler }
    }

    /// Sends a request and decodes its result as `Result`. Fails with `RPCError` when the daemon answers
    /// with an error, and with `ConnectionError` when the connection closes or the timeout expires.
    public func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, _ params: Params, as _: Result.Type = Result.self, timeout: Duration = .seconds(30)
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            queue.async { [self] in
                guard !isClosed else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                let id = nextId
                nextId += 1
                let line: Data
                do {
                    line = try JSONEncoder().encode(RPCRequest(id: .number(id), method: method, params: params))
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                pending[id] = { outcome in
                    switch outcome {
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .success(let data):
                        do {
                            let envelope = try JSONDecoder().decode(RPCResultEnvelope<Result>.self, from: data)
                            if let error = envelope.error {
                                continuation.resume(throwing: error)
                            } else if let result = envelope.result {
                                continuation.resume(returning: result)
                            } else {
                                continuation.resume(throwing: ConnectionError.malformed("\(method): no result"))
                            }
                        } catch {
                            continuation.resume(throwing: ConnectionError.malformed("\(method): \(error)"))
                        }
                    }
                }
                write(line)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.pending.removeValue(forKey: id)?(.failure(ConnectionError.timeout(method: method)))
                }
            }
        }
    }

    /// Closes the connection. Pending requests fail with `.closed` and `notifications` finishes.
    public func cancel() {
        queue.async { [self] in close(ConnectionError.closed) }
    }

    // MARK: Queue-confined internals

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            startWaiter?.resume()
            startWaiter = nil
            receive()
        case .waiting(let error), .failed(let error):
            // `.waiting` is how NWConnection reports ENOENT and ECONNREFUSED; the client retries itself.
            close(Self.connectionError(error))
        case .cancelled:
            close(ConnectionError.closed)
        default:
            break
        }
    }

    private static func connectionError(_ error: NWError) -> ConnectionError {
        if case .posix(let code) = error { return .posix(code) }
        return .transport(error.localizedDescription)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                drainLines()
            }
            if let error {
                close(Self.connectionError(error))
            } else if isComplete {
                close(ConnectionError.closed)
            } else if !isClosed {
                receive()
            }
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { dispatch(Data(line)) }
        }
    }

    private func dispatch(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: line) else {
            MapoLog.shared.warn("dropped a line that is not a JSON-RPC message (\(line.count) bytes)")
            return
        }
        switch envelope.kind {
        case .response(.number(let id)):
            pending.removeValue(forKey: id)?(.success(line))
        case .response(let id):
            MapoLog.shared.warn("dropped a response with unknown id \(id)")
        case .notification(let method):
            notificationSink.yield(Self.decodeNotification(method: method, line: line))
        case .request(let id, let method):
            let params = (try? JSONDecoder().decode(RPCParamsEnvelope<JSONValue>.self, from: line))?.params
            serve(DaemonRequest(id: id, method: method, params: params ?? .object([:])))
        case .invalid:
            MapoLog.shared.warn("dropped a message without id or method")
        }
    }

    private static func decodeNotification(method: String, line: Data) -> ServerNotification {
        guard method == Method.event else { return .other(method: method) }
        do {
            guard let event = try JSONDecoder().decode(RPCParamsEnvelope<Event>.self, from: line).params else {
                return .undecodable(method: method, reason: "no params")
            }
            return .event(event)
        } catch {
            return .undecodable(method: method, reason: String(describing: error))
        }
    }

    private func serve(_ request: DaemonRequest) {
        guard let handler = requestHandler else {
            let error = RPCError(kind: .unavailable, message: "The app does not handle \(request.method) yet")
            respond(RPCResponse(id: request.id, error: error))
            return
        }
        Task { @MainActor [weak self] in
            let outcome = await handler(request)
            let response: RPCResponse
            switch outcome {
            case .success(let result): response = RPCResponse(id: request.id, result: result)
            case .failure(let error): response = RPCResponse(id: request.id, error: error)
            }
            guard let self else { return }
            queue.async { self.respond(response) }
        }
    }

    private func respond(_ response: RPCResponse) {
        guard !isClosed, let line = try? JSONEncoder().encode(response) else { return }
        write(line)
    }

    private func write(_ line: Data) {
        var framed = line
        framed.append(UInt8(ascii: "\n"))
        connection.send(
            content: framed,
            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                queue.async { self.close(Self.connectionError(error)) }
            })
    }

    private func close(_ error: ConnectionError) {
        guard !isClosed else { return }
        isClosed = true
        startWaiter?.resume(throwing: error)
        startWaiter = nil
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters { waiter(.failure(isReady ? ConnectionError.closed : error)) }
        notificationSink.finish()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
