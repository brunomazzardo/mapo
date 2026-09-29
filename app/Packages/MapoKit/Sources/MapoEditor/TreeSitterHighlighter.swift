import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterRust
import TreeSitterSql
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Highlights with a tree-sitter grammar and its `highlights.scm` (R-ED-2, ARCHITECTURE §4.4). Each call parses
/// the whole text from scratch with its own parser, so calls are independent and can run on any thread. The
/// grammar's query compiles on first use, which takes tens to hundreds of milliseconds, so the first call
/// belongs off the main thread; `isPrepared` says when it is done.
nonisolated public final class TreeSitterHighlighter: SyntaxHighlighter, @unchecked Sendable {
    /// Which of several captures on the same range wins. The tree-sitter repositories' queries list the
    /// specific patterns first; nvim-style queries (Swift, SQL) list them last.
    enum Precedence { case first, last }

    /// One parser and the queries that highlight it, from resource bundles of the grammar packages.
    struct Grammar {
        var language: () -> OpaquePointer
        /// `(bundle, file)` pairs, concatenated in order, such as JavaScript's queries under TypeScript's.
        var queries: [(bundle: String, file: String)]
        var precedence: Precedence = .first
        /// Capture names whose kind differs in this language, such as keys in data formats.
        var overrides: [String: SyntaxKind?] = [:]
    }

    private let grammar: Grammar
    /// Markdown's inline grammar, run over the block grammar's `inline` nodes.
    private let inline: TreeSitterHighlighter?
    /// Held only to read or set `compiled`, so the main thread never waits on a compile.
    private let lock = NSLock()
    /// Serializes compiling, which is slow.
    private let compileLock = NSLock()
    // Guarded by `lock`. A tree-sitter query is immutable once compiled and safe to share between threads,
    // each with its own cursor.
    private var compiled: Compiled??

    private struct Compiled {
        var language: Language
        var query: Query
        var kinds: [SyntaxKind?]
        /// Markdown only: finds the ranges the inline grammar parses.
        var inlineNodes: Query?
    }

    init(_ grammar: Grammar, inline: TreeSitterHighlighter? = nil) {
        self.grammar = grammar
        self.inline = inline
    }

    public var isPrepared: Bool {
        lock.withLock { compiled != nil } && (inline?.isPrepared ?? true)
    }

    public func prepare() {
        _ = load()
        inline?.prepare()
    }

    /// The compiled query, or nil when the grammar's queries can't be found or don't compile.
    private func load() -> Compiled? {
        if let done = lock.withLock({ compiled }) { return done }
        return compileLock.withLock {
            if let done = lock.withLock({ compiled }) { return done }
            let made = Self.compile(grammar, inline: inline != nil)
            lock.withLock { compiled = .some(made) }
            return made
        }
    }

    private static func compile(_ grammar: Grammar, inline: Bool) -> Compiled? {
        let language = Language(grammar.language())
        var source = ""
        for (bundle, file) in grammar.queries {
            guard let url = QueryFiles.url(bundle: bundle, file: file),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            source += text + "\n"
        }
        guard let query = try? Query(language: language, data: Data(source.utf8)) else { return nil }
        let kinds = (0..<query.captureCount).map { index -> SyntaxKind? in
            guard let name = query.captureName(for: index) else { return nil }
            if let override = grammar.overrides[name] { return override }
            return captureKind(name)
        }
        let inlineNodes = inline ? try? Query(language: language, data: Data("(inline) @inline".utf8)) : nil
        return Compiled(language: language, query: query, kinds: kinds, inlineNodes: inlineNodes)
    }

    public func tokens(in text: String) -> [SyntaxToken] {
        guard let compiled = load() else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(compiled.language)) != nil, let tree = parser.parse(text) else { return [] }
        var tokens = Self.captures(compiled, tree: tree, text: text, precedence: grammar.precedence)
        if let inline, let finder = compiled.inlineNodes {
            let ranges = finder.execute(in: tree).flatMap { $0.captures.map(\.node) }.map {
                TSRange(points: $0.pointRange, bytes: $0.byteRange)
            }
            if !ranges.isEmpty { tokens += inline.tokens(in: text, ranges: ranges) }
        }
        return tokens.sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
    }

    /// Tokens of a grammar parsing only `ranges` of the text (Markdown's inline grammar).
    private func tokens(in text: String, ranges: [TSRange]) -> [SyntaxToken] {
        guard let compiled = load() else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(compiled.language)) != nil else { return [] }
        parser.includedRanges = ranges
        guard let tree = parser.parse(text) else { return [] }
        return Self.captures(compiled, tree: tree, text: text, precedence: grammar.precedence)
    }

    /// The query's captures as tokens: one per range, by the grammar's precedence, dropping captures that
    /// draw as plain text (variables, parameters) so they never hide a colored one on the same range.
    private static func captures(
        _ compiled: Compiled, tree: MutableTree, text: String, precedence: Precedence
    ) -> [SyntaxToken] {
        var byRange: [NSRange: (kind: SyntaxKind, pattern: Int)] = [:]
        var order: [NSRange] = []
        let matches = compiled.query.execute(in: tree).resolve(with: Predicate.Context(string: text))
        for match in matches {
            for capture in match.captures {
                guard capture.index < compiled.kinds.count, let kind = compiled.kinds[capture.index],
                    capture.range.length > 0
                else { continue }
                let range = capture.range
                if let existing = byRange[range] {
                    let wins =
                        precedence == .first
                        ? match.patternIndex < existing.pattern : match.patternIndex >= existing.pattern
                    if wins { byRange[range] = (kind, match.patternIndex) }
                } else {
                    byRange[range] = (kind, match.patternIndex)
                    order.append(range)
                }
            }
        }
        return order.compactMap { range in byRange[range].map { SyntaxToken(range: range, kind: $0.kind) } }
    }

    /// The kind of a capture name, by its dotted parts: `keyword.function` is a keyword, `variable` is plain.
    static func captureKind(_ name: String) -> SyntaxKind? {
        switch name {
        case "string.special.key": return .function
        case "constant.builtin", "variable.builtin", "constant.macro": return .keyword
        case "punctuation.special": return .punctuation
        default: break
        }
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "comment": return .comment
        case "keyword", "conditional", "repeat", "storageclass", "include", "exception", "boolean", "attribute",
            "label", "preproc":
            return .keyword
        case "string", "character", "escape": return .string
        case "function", "method": return .function
        case "type", "constructor", "tag", "namespace", "module": return .type
        case "number", "float": return .number
        case "punctuation", "operator": return .punctuation
        case "text":
            switch name {
            case "text.title": return .keyword
            case "text.literal": return .string
            case "text.strong", "text.emphasis": return .type
            case "text.uri", "text.reference": return .function
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: Languages

    nonisolated(unsafe) private static var cache: [SyntaxLanguage: TreeSitterHighlighter] = [:]
    private static let cacheLock = NSLock()

    static func shared(for language: SyntaxLanguage) -> TreeSitterHighlighter {
        cacheLock.withLock {
            if let cached = cache[language] { return cached }
            let made = make(language)
            cache[language] = made
            return made
        }
    }

    private static func make(_ language: SyntaxLanguage) -> TreeSitterHighlighter {
        let js = (bundle: "TreeSitterJavaScript_TreeSitterJavaScript", file: "highlights.scm")
        let jsx = (bundle: "TreeSitterJavaScript_TreeSitterJavaScript", file: "highlights-jsx.scm")
        let ts = (bundle: "TreeSitterTypeScript_TreeSitterTypeScript", file: "highlights.scm")
        let keys: [String: SyntaxKind?] = ["property": .function]
        func one(_ name: String) -> [(bundle: String, file: String)] {
            [(bundle: "TreeSitter\(name)_TreeSitter\(name)", file: "highlights.scm")]
        }
        switch language {
        case .swift:
            return TreeSitterHighlighter(
                Grammar(language: { tree_sitter_swift() }, queries: one("Swift"), precedence: .last))
        case .rust:
            // Rust's query captures numbers and booleans alike as `constant.builtin`.
            return TreeSitterHighlighter(
                Grammar(
                    language: { tree_sitter_rust() }, queries: one("Rust"), overrides: ["constant.builtin": .number]))
        case .typescript:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_typescript() }, queries: [js, ts]))
        case .tsx:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_tsx() }, queries: [js, jsx, ts]))
        case .javascript:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_javascript() }, queries: [js, jsx]))
        case .json:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_json() }, queries: one("JSON")))
        case .python:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_python() }, queries: one("Python")))
        case .go:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_go() }, queries: one("Go")))
        case .markdown:
            let inline = TreeSitterHighlighter(
                Grammar(
                    language: { tree_sitter_markdown_inline() },
                    queries: [(bundle: "TreeSitterMarkdown_TreeSitterMarkdownInline", file: "highlights.scm")]))
            return TreeSitterHighlighter(
                Grammar(
                    language: { tree_sitter_markdown() }, queries: one("Markdown"), precedence: .last,
                    overrides: ["punctuation.special": .punctuation]),
                inline: inline)
        case .yaml:
            return TreeSitterHighlighter(
                Grammar(language: { tree_sitter_yaml() }, queries: one("YAML"), precedence: .last, overrides: keys))
        case .toml:
            // TOML's query captures each whole pair as `property` and its key as `type`.
            return TreeSitterHighlighter(
                Grammar(
                    language: { tree_sitter_toml() }, queries: one("TOML"),
                    overrides: ["property": SyntaxKind?.none, "type": .function]))
        case .bash:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_bash() }, queries: one("Bash")))
        case .css:
            return TreeSitterHighlighter(Grammar(language: { tree_sitter_css() }, queries: one("CSS"), overrides: keys))
        case .html:
            return TreeSitterHighlighter(
                Grammar(
                    language: { tree_sitter_html() }, queries: one("HTML"),
                    overrides: ["attribute": .function, "constant": .keyword]))
        case .sql:
            return TreeSitterHighlighter(
                Grammar(language: { tree_sitter_sql() }, queries: one("Sql"), precedence: .last))
        }
    }
}

/// Finds a grammar package's query files. SwiftPM copies each grammar's `queries` folder into a resource
/// bundle named `<Package>_<Target>.bundle`, which lands in the app's Resources, beside a command-line binary,
/// or beside the test bundle.
nonisolated enum QueryFiles {
    static func url(bundle name: String, file: String) -> URL? {
        for directory in directories {
            let bundle = directory.appending(path: "\(name).bundle", directoryHint: .isDirectory)
            for sub in ["Contents/Resources/queries", "queries"] {
                let url = bundle.appending(path: "\(sub)/\(file)")
                if FileManager.default.isReadableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private static let directories: [URL] = {
        var out: [URL] = []
        // The main bundle for the app; the test bundle when this module is linked into one.
        for bundle in [Bundle.main, Bundle(for: TreeSitterHighlighter.self)] {
            if let resources = bundle.resourceURL { out.append(resources) }
            out.append(bundle.bundleURL.deletingLastPathComponent())
        }
        return out
    }()
}
