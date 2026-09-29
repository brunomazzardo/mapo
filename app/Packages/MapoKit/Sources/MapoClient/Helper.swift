import Foundation
import MapoProtocol

/// What the bundled `mapo instance show --json` prints (ENGINEERING §2.1, §2.4). The app never
/// re-implements instance resolution; it uses these names and paths.
nonisolated public struct InstanceInfo: Decodable, Sendable {
    public struct Daemon: Decodable, Sendable {
        public var running: Bool
        public var pid: Int?
        public var bootId: String?
        public var `protocol`: Int?
    }

    public var name: String
    public var source: String
    public var dataDir: String
    public var runtimeDir: String
    public var socket: String
    /// The path of `app.token`, not the token.
    public var token: String
    public var logDir: String
    public var appPidFile: String
    public var daemon: Daemon?

    public var dataDirectory: URL { URL(filePath: dataDir, directoryHint: .isDirectory) }
    public var logDirectory: URL { URL(filePath: logDir, directoryHint: .isDirectory) }
}

nonisolated public struct HelperOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    /// The first line of stderr, for log lines and error messages.
    public var reason: String {
        let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "exit \(status)" : line
    }
}

nonisolated public enum HelperError: Error, CustomStringConvertible {
    case failed(arguments: [String], output: HelperOutput)
    case badOutput(arguments: [String], reason: String)

    public var description: String {
        switch self {
        case .failed(let arguments, let output): "mapo \(arguments.joined(separator: " ")): \(output.reason)"
        case .badOutput(let arguments, let reason): "mapo \(arguments.joined(separator: " ")): \(reason)"
        }
    }
}

/// Runs the bundled `Contents/Helpers/mapo`. Output goes through temporary files, not pipes, because
/// `mapo daemon` leaves a detached child that may keep inherited descriptors open.
nonisolated public struct MapoHelper: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// `<bundle>/Contents/Helpers/mapo`.
    public static func bundled(in bundle: Bundle = .main) -> MapoHelper {
        MapoHelper(executable: bundle.bundleURL.appending(components: "Contents", "Helpers", "mapo"))
    }

    public func run(_ arguments: [String], timeout: Duration = .seconds(15)) async throws -> HelperOutput {
        let directory = FileManager.default.temporaryDirectory
        let outURL = directory.appending(component: "mapo-helper-\(UUID().uuidString).out")
        let errURL = directory.appending(component: "mapo-helper-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            let seconds = Double(timeout.components.seconds)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if process.isRunning { process.terminate() }
            }
        }
        try? outHandle.close()
        try? errHandle.close()
        let stdout = (try? Data(contentsOf: outURL)) ?? Data()
        let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        return HelperOutput(status: status, stdout: stdout, stderr: stderr)
    }

    /// `mapo [--instance I] instance show --json`.
    public func instanceShow(instance: String?) async throws -> InstanceInfo {
        let arguments = Self.instanceArguments(instance) + ["instance", "show", "--json"]
        let output = try await run(arguments)
        guard output.status == 0 else { throw HelperError.failed(arguments: arguments, output: output) }
        do {
            return try JSONDecoder().decode(InstanceInfo.self, from: output.stdout)
        } catch {
            throw HelperError.badOutput(arguments: arguments, reason: String(describing: error))
        }
    }

    /// `--instance` goes before the subcommand, where every `mapo` verb accepts it.
    static func instanceArguments(_ instance: String?) -> [String] {
        instance.map { ["--instance", $0] } ?? []
    }
}

/// Starts and stops this instance's daemon with the bundled helper (PLAN T0.7 step 5).
nonisolated public struct DaemonLauncher: Sendable {
    public let helper: MapoHelper
    public let instance: String

    public init(helper: MapoHelper, instance: String) {
        self.helper = helper
        self.instance = instance
    }

    /// `mapo daemon --instance I`: detaches the daemon and returns once its socket answers.
    /// Returns the daemon's pid when it printed one.
    @discardableResult
    public func launch() async throws -> Int? {
        let arguments = MapoHelper.instanceArguments(instance) + ["daemon"]
        let output = try await helper.run(arguments, timeout: .seconds(15))
        guard output.status == 0 else { throw HelperError.failed(arguments: arguments, output: output) }
        let reply = try? JSONDecoder().decode(JSONValue.self, from: output.stdout)
        return reply?["pid"]?.intValue
    }

    /// `mapo instance stop`: `daemon.shutdown`, then signals, for Restart mapod.
    public func stop() async throws {
        let arguments = MapoHelper.instanceArguments(instance) + ["instance", "stop"]
        let output = try await helper.run(arguments, timeout: .seconds(12))
        guard output.status == 0 else { throw HelperError.failed(arguments: arguments, output: output) }
    }
}
