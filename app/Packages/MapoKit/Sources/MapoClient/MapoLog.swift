import Foundation
import os

/// The app log: `<logDir>/app.YYYY-MM-DD.log`, stderr and unified logging (subsystem `dev.mapo.app`)
/// (ENGINEERING §3.6). `MAPO_LOG` sets the level. Never log tokens, prompts or terminal contents.
nonisolated public final class MapoLog: @unchecked Sendable {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, warn, error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .warn: "WARN"
            case .error: "ERROR"
            }
        }
    }

    public static let shared = MapoLog()

    private let queue = DispatchQueue(label: "dev.mapo.app.log")
    private let logger = Logger(subsystem: "dev.mapo.app", category: "app")
    private let minimum: Level
    // Confined to `queue`.
    private var directory: URL?
    private var fileDay = ""
    private var file: FileHandle?

    private init() {
        let setting = (ProcessInfo.processInfo.environment["MAPO_LOG"] ?? "info").lowercased()
        let level = setting.split(separator: ",").first.map(String.init) ?? "info"
        switch level {
        case "trace", "debug": minimum = .debug
        case "warn": minimum = .warn
        case "error": minimum = .error
        default: minimum = .info
        }
    }

    /// Starts writing daily files into `directory` and removes app logs older than 7 days.
    public func configure(directory: URL) {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            file = nil
            fileDay = ""
            prune(directory)
        }
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func warn(_ message: @autoclosure () -> String) { log(.warn, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }

    public func log(_ level: Level, _ message: String) {
        guard level >= minimum else { return }
        let now = Date()
        queue.async { [self] in
            let line = "\(Self.timestamp(now)) \(level.label) \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .warn: logger.warning("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
            handle(for: now)?.write(Data(line.utf8))
        }
    }

    /// Waits until every queued line is written, for termination.
    public func flush() {
        queue.sync {}
    }

    private func handle(for date: Date) -> FileHandle? {
        guard let directory else { return nil }
        let day = Self.day(date)
        if day == fileDay, let file { return file }
        try? file?.close()
        let url = directory.appending(component: "app.\(day).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
        fileDay = day
        return file
    }

    private func prune(_ directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let logs = names.filter { $0.hasPrefix("app.") && $0.hasSuffix(".log") }.sorted()
        for name in logs.dropLast(7) {
            try? FileManager.default.removeItem(at: directory.appending(component: name))
        }
    }

    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
