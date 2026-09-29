import Foundation
import MapoProtocol

// MARK: - File pane commands (PROTOCOL §6.5, UX §6)

extension MapoClient {
    nonisolated private struct OpenParams: Encodable, Sendable {
        var path: String
    }

    nonisolated private struct PaneParams: Encodable, Sendable {
        var pane: String
    }

    /// The `file.open` result: the path shown and its pane.
    nonisolated public struct FileOpenResult: Decodable, Sendable {
        public var path: String
        public var paneId: String
    }

    /// `file.open`: shows an existing file in the workspace's file pane. The daemon rejects folders, missing
    /// paths, broken links and unreadable files before any change.
    @discardableResult
    public func openFile(path: String) async throws -> FileOpenResult {
        try await call("file.open", OpenParams(path: path), as: FileOpenResult.self)
    }

    /// Clear Recent Files in a file pane's pull-down.
    public func clearRecentFiles(pane: String) async throws {
        _ = try await call("pane.clearRecent", PaneParams(pane: pane), as: Layout.self)
    }
}
