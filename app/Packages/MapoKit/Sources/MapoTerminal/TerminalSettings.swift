import Foundation

/// The terminal engine, `config.toml [terminal] engine` (PLAN T0.8).
nonisolated public enum TerminalEngine: String, Sendable {
    case ghostty
    case swiftterm
}

/// `config.toml [terminal]`, the keys the app renders with. Unknown keys are ignored here; the
/// daemon validates the file and reports errors (PROTOCOL `config.error`).
nonisolated public struct TerminalSettings: Equatable, Sendable {
    /// SwiftTerm until GhosttyKit links (PLAN T0.8 fallback).
    public var engine: TerminalEngine = .swiftterm
    public var fontFamily = "SF Mono"
    public var fontSize = 12.5
    /// Whether Option sends Meta (ESC prefix) instead of composing characters like `ø`.
    public var optionAsAlt = false

    public init() {}

    /// Reads `[terminal]` from `config.toml` text, keeping the defaults for missing or mistyped keys.
    public init(configTOML text: String) {
        self.init()
        let table = TOMLSubset.table(named: "terminal", in: text)
        if case .string(let s) = table["engine"], let engine = TerminalEngine(rawValue: s) { self.engine = engine }
        if case .string(let s) = table["font-family"], !s.isEmpty { fontFamily = s }
        if case .number(let n) = table["font-size"], (6...72).contains(n) { fontSize = n }
        if case .bool(let b) = table["option-as-alt"] { optionAsAlt = b }
    }

    /// Reads `config.toml` from an instance directory; defaults when the file is missing or unreadable.
    public init(instanceDirectory: URL) {
        let url = instanceDirectory.appending(component: "config.toml")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            self.init(configTOML: text)
        } else {
            self.init()
        }
    }
}

/// Just enough TOML for flat `key = value` tables: strings, numbers, booleans and comments.
/// Arrays, inline tables and multi-line strings read as `.other`.
nonisolated public enum TOMLSubset {
    public enum Value: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case other
    }

    public static func table(named name: String, in text: String) -> [String: Value] {
        var result: [String: Value] = [:]
        var inTable = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = stripComment(line)
                inTable = header == "[\(name)]"
                continue
            }
            guard inTable, let eq = line.firstIndex(of: "=") else { continue }
            var key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, key.first == "\"", key.last == "\"" { key = String(key.dropFirst().dropLast()) }
            result[key] = value(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func value(_ raw: String) -> Value {
        if let quote = raw.first, quote == "\"" || quote == "'" {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" && quote == "\"" {
                    escaped = true
                } else if ch == quote {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return .other
        }
        let bare = stripComment(raw)
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Double(bare.replacingOccurrences(of: "_", with: "")).map(Value.number) ?? .other
        }
    }

    private static func stripComment(_ s: String) -> String {
        guard let hash = s.firstIndex(of: "#") else { return s }
        return s[..<hash].trimmingCharacters(in: .whitespaces)
    }
}
