import Foundation

/// A highlight class, matching the syntax tokens of UX §9.1.
nonisolated public enum SyntaxKind: String, CaseIterable, Sendable {
    case keyword, string, function, type, number, punctuation, comment
}

/// One highlighted range, in UTF-16 offsets of the text it was computed from.
nonisolated public struct SyntaxToken: Equatable, Sendable {
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// Turns a document's text into highlight tokens. Runs off the main thread, so implementations are
/// `Sendable` and pure. Tree-sitter was the plan (ARCHITECTURE §4.4); `RegexHighlighter` stands behind this
/// interface until SwiftTreeSitter and Neon build with the current toolchain.
nonisolated public protocol SyntaxHighlighter: Sendable {
    func tokens(in text: String) -> [SyntaxToken]
}

/// The languages the editor highlights, chosen by file extension. Anything else is plain text.
nonisolated public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, rust, typescript, javascript, json, markdown

    public init?(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": self = .swift
        case "rs": self = .rust
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "json", "jsonc", "json5": self = .json
        case "md", "markdown", "mdx": self = .markdown
        default: return nil
        }
    }

    /// The highlighter for this language.
    public var highlighter: any SyntaxHighlighter {
        RegexHighlighter.shared(for: self)
    }
}

/// A single-pass regex highlighter: one alternation of named groups per language, scanned left to right, so
/// a comment marker inside a string (or the reverse) is taken by whichever starts first.
nonisolated public final class RegexHighlighter: SyntaxHighlighter, @unchecked Sendable {
    // NSRegularExpression is immutable and documented as thread-safe.
    private let expression: NSRegularExpression
    private let groups: [(name: String, kind: SyntaxKind)]

    init(rules: [(name: String, kind: SyntaxKind, pattern: String)], options: NSRegularExpression.Options = []) {
        let body = rules.map { "(\($0.pattern))" }.joined(separator: "|")
        // The patterns are fixed and tested; a bad one is a programming error caught by the tests.
        expression = (try? NSRegularExpression(pattern: body, options: options)) ?? NSRegularExpression()
        groups = rules.map { ($0.name, $0.kind) }
    }

    public func tokens(in text: String) -> [SyntaxToken] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var out: [SyntaxToken] = []
        expression.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
            guard let match else { return }
            // Group n + 1 is rule n; the rules' own patterns use only non-capturing groups.
            for (index, group) in groups.enumerated() {
                let range = match.range(at: index + 1)
                if range.location != NSNotFound {
                    out.append(SyntaxToken(range: range, kind: group.kind))
                    break
                }
            }
        }
        return out
    }

    nonisolated(unsafe) private static var cache: [SyntaxLanguage: RegexHighlighter] = [:]
    private static let lock = NSLock()

    static func shared(for language: SyntaxLanguage) -> RegexHighlighter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] { return cached }
        let made = make(language)
        cache[language] = made
        return made
    }

    private static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    private static let cComment = "//[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$)"
    private static let number =
        "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
    private static let typeName = "\\b[A-Z][A-Za-z0-9_]*\\b"
    private static let call = "\\b[a-z_][A-Za-z0-9_]*(?=\\s*\\()"
    private static let dq = "\"(?:\\\\.|[^\"\\\\\\n])*\"?"
    private static let sq = "'(?:\\\\.|[^'\\\\\\n])*'?"

    private static func make(_ language: SyntaxLanguage) -> RegexHighlighter {
        switch language {
        case .swift:
            return RegexHighlighter(rules: [
                ("comment", .comment, cComment),
                ("string", .string, "\"\"\"[\\s\\S]*?(?:\"\"\"|$)|" + dq),
                ("number", .number, number),
                (
                    "keyword", .keyword,
                    words(
                        "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in indirect init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias unowned var weak where while"
                    )
                ),
                ("attribute", .keyword, "@[A-Za-z_][A-Za-z0-9_]*"),
                ("type", .type, typeName),
                ("function", .function, call),
            ])
        case .rust:
            return RegexHighlighter(rules: [
                ("comment", .comment, cComment),
                ("string", .string, "b?r#*\"[\\s\\S]*?\"#*|b?\"(?:\\\\.|[^\"\\\\])*\"?"),
                ("char", .string, "b?'(?:\\\\.|[^'\\\\\\n])'"),
                ("number", .number, number),
                (
                    "keyword", .keyword,
                    words(
                        "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
                    )
                ),
                ("lifetime", .keyword, "'[a-z_][A-Za-z0-9_]*\\b"),
                ("macro", .function, "\\b[a-z_][A-Za-z0-9_]*!"),
                ("type", .type, typeName),
                ("function", .function, call),
            ])
        case .typescript, .javascript:
            let tsOnly =
                language == .typescript
                ? " abstract declare enum implements interface keyof namespace private protected public readonly type satisfies infer is"
                : ""
            return RegexHighlighter(rules: [
                ("comment", .comment, cComment),
                ("template", .string, "`(?:\\\\[\\s\\S]|[^`\\\\])*`?"),
                ("string", .string, dq + "|" + sq),
                ("number", .number, number + "n?"),
                (
                    "keyword", .keyword,
                    words(
                        "as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield"
                            + tsOnly)
                ),
                ("type", .type, typeName),
                ("function", .function, "\\b[a-zA-Z_$][A-Za-z0-9_$]*(?=\\s*\\()"),
            ])
        case .json:
            return RegexHighlighter(rules: [
                ("comment", .comment, cComment),
                ("key", .function, dq + "(?=\\s*:)"),
                ("string", .string, dq),
                ("number", .number, "-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?"),
                ("keyword", .keyword, words("true false null")),
                ("punctuation", .punctuation, "[{}\\[\\]:,]"),
            ])
        case .markdown:
            return RegexHighlighter(
                rules: [
                    ("fence", .string, "^(?:```|~~~)[^\\n]*\\n[\\s\\S]*?(?:^(?:```|~~~)[^\\n]*$|\\z)"),
                    ("heading", .keyword, "^#{1,6}[ \\t][^\\n]*"),
                    ("code", .string, "`[^`\\n]+`"),
                    ("link", .function, "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"),
                    ("strong", .type, "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__"),
                    ("list", .punctuation, "^[ \\t]*(?:[-*+]|\\d+[.)])(?=[ \\t])"),
                    ("quote", .comment, "^>[^\\n]*"),
                ], options: [.anchorsMatchLines])
        }
    }
}
