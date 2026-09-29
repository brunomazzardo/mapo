import Foundation
import MapoProtocol

// MARK: - Changes, diffs and base text (PROTOCOL §6.5, UX §5.3, §6.3)

/// The `git.status` result: the files changed against HEAD in a repository.
nonisolated public struct GitChanges: Decodable, Equatable, Sendable {
    public struct File: Decodable, Equatable, Sendable {
        /// Relative to the root, `/`-separated.
        public var path: String
        /// `M`, `A`, `D`, `R`, `?` (untracked) or `U` (conflicted).
        public var status: String
        public var added: Int
        public var deleted: Int
        public var binary: Bool?
    }

    public struct Totals: Decodable, Equatable, Sendable {
        public var files: Int
        public var added: Int
        public var deleted: Int
    }

    public var root: String
    public var branch: String?
    /// HEAD's short id, for a detached HEAD.
    public var head: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [File]
    public var totals: Totals
    public var warn: String?
}

extension MapoClient {
    nonisolated private struct PathParams: Encodable, Sendable {
        var path: String
    }

    nonisolated private struct RootPathParams: Encodable, Sendable {
        var root: String
        var path: String
    }

    nonisolated private struct TextResult: Decodable, Sendable {
        var text: String
    }

    /// `git.status`: the changes in the repository holding `path`. Fails `not_found` outside a repository.
    public func gitStatus(path: String) async throws -> GitChanges {
        try await call("git.status", PathParams(path: path), as: GitChanges.self)
    }

    /// `git.diff`: one file's unified diff against HEAD.
    public func gitDiff(root: String, path: String) async throws -> String {
        try await call("git.diff", RootPathParams(root: root, path: path), as: TextResult.self).text
    }

    /// `git.baseText`: the file's text at HEAD, or nil when HEAD doesn't have it (untracked, added, no repository).
    public func gitBaseText(path: String) async throws -> String? {
        do {
            return try await call("git.baseText", PathParams(path: path), as: TextResult.self).text
        } catch let error as RPCError where error.kind == .notFound {
            return nil
        }
    }

    /// `diff.open`: shows a file's diff in the workspace's file pane; focus stays where it is.
    @discardableResult
    public func openDiff(root: String, path: String) async throws -> FileOpenResult {
        try await call("diff.open", RootPathParams(root: root, path: path), as: FileOpenResult.self)
    }
}
