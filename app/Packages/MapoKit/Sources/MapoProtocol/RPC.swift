import Foundation

/// A JSON-RPC id. Clients number their requests; the daemon's requests carry strings such as `"d-17"`.
public enum RPCId: Codable, Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .number(let value): String(value)
        case .string(let value): value
        }
    }
}

/// An outgoing request: `{"jsonrpc":"2.0","id":…,"method":…,"params":{…}}`.
public struct RPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: RPCId
    public let method: String
    public let params: Params

    public init(id: RPCId, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
}

/// An outgoing response to a daemon request. Exactly one of `result` and `error` is set.
public struct RPCResponse: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: RPCId
    public let result: JSONValue?
    public let error: RPCError?

    public init(id: RPCId, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RPCId, error: RPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
}

/// The error kinds of PROTOCOL §4, with their JSON-RPC codes.
public struct RPCErrorKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let invalidArgument = RPCErrorKind(rawValue: "invalid_argument")
    public static let notFound = RPCErrorKind(rawValue: "not_found")
    public static let conflict = RPCErrorKind(rawValue: "conflict")
    public static let forbidden = RPCErrorKind(rawValue: "forbidden")
    public static let unavailable = RPCErrorKind(rawValue: "unavailable")
    public static let busy = RPCErrorKind(rawValue: "busy")
    public static let timeout = RPCErrorKind(rawValue: "timeout")
    public static let cancelled = RPCErrorKind(rawValue: "cancelled")
    public static let needsYou = RPCErrorKind(rawValue: "needs_you")
    public static let internalError = RPCErrorKind(rawValue: "internal")

    public var code: Int {
        switch self {
        case .invalidArgument: -32602
        case .notFound: -32001
        case .conflict: -32002
        case .forbidden: -32003
        case .unavailable: -32004
        case .busy: -32005
        case .timeout: -32006
        case .cancelled: -32007
        case .needsYou: -32008
        default: -32603
        }
    }
}

/// `{code, message, data: {kind, hint?, details, …}}` (PROTOCOL §4).
public struct RPCError: Codable, Error, Hashable, Sendable, CustomStringConvertible {
    public struct Data: Codable, Hashable, Sendable {
        public var kind: RPCErrorKind
        public var hint: String?
        public var details: JSONValue?
        /// Set on a protocol mismatch (PROTOCOL §2).
        public var daemonProtocol: Int?

        public init(kind: RPCErrorKind, hint: String? = nil, details: JSONValue? = nil) {
            self.kind = kind
            self.hint = hint
            self.details = details
        }
    }

    public var code: Int
    public var message: String
    public var data: Data?

    public init(kind: RPCErrorKind, message: String, hint: String? = nil) {
        self.code = kind.code
        self.message = message
        self.data = Data(kind: kind, hint: hint, details: .object([:]))
    }

    public var kind: RPCErrorKind? { data?.kind }
    public var description: String { "\(message) (\(data?.kind.rawValue ?? String(code)))" }
}

/// The routing members of an incoming line, decoded before the rest of it.
public struct RPCEnvelope: Decodable, Sendable {
    public let id: RPCId?
    public let method: String?

    public enum Kind: Sendable {
        case response(RPCId)
        case notification(String)
        case request(RPCId, String)
        case invalid
    }

    public var kind: Kind {
        switch (id, method) {
        case (let id?, let method?): .request(id, method)
        case (nil, let method?): .notification(method)
        case (let id?, nil): .response(id)
        case (nil, nil): .invalid
        }
    }
}

/// A response to one of our requests, with its result decoded as `Result`.
public struct RPCResultEnvelope<Result: Decodable>: Decodable {
    public let result: Result?
    public let error: RPCError?
}

/// A request or notification with its params decoded as `Params`.
public struct RPCParamsEnvelope<Params: Decodable>: Decodable {
    public let params: Params?
}
