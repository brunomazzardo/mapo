import Foundation
import Testing

@testable import MapoEditor

@MainActor @Test func lineIndexFindsLines() {
    let index = LineIndex("ab\ncd\n\nef" as NSString)
    #expect(index.starts == [0, 3, 6, 7])
    #expect([0, 2, 3, 5, 6, 7, 9].map(index.line(at:)) == [0, 0, 1, 1, 2, 3, 3])
    #expect(index.start(of: 99) == 7)
    #expect(LineIndex("x\n" as NSString).count == 2)
}

@MainActor @Test func goToLineParses() {
    #expect(GoToLineBar.parse("42")! == (42, nil))
    #expect(GoToLineBar.parse(" 42:7 ")! == (42, 7))
    #expect(GoToLineBar.parse("0") == nil)
    #expect(GoToLineBar.parse("4:") == nil)
    #expect(GoToLineBar.parse("x") == nil)
}

@MainActor @Test func detectsIndent() {
    #expect(FileEditorView.detectIndent("a\n\tb\n\tc\n" as NSString) == "\t")
    #expect(FileEditorView.detectIndent("a\n  b\n    c\n  d\n" as NSString) == "  ")
    #expect(FileEditorView.detectIndent("a\n    b\n        c\n" as NSString) == "    ")
    #expect(FileEditorView.detectIndent("plain\n" as NSString) == "    ")
}

@MainActor @Test func classifiesFiles() {
    let text = Data("hello".utf8)
    #expect(FileKind.classify(path: "/a/b.swift", size: 5, head: text) == .text)
    #expect(FileKind.classify(path: "/a/b.log", size: 9 * 1024 * 1024, head: text) == .largeText)
    #expect(FileKind.classify(path: "/a/b.db", size: 3, head: Data([1, 0, 2])) == .binary)
    #expect(FileKind.classify(path: "/a/logo.PNG", size: 3, head: Data([0])) == .image)
    #expect(FileKind.classify(path: "/a/doc.pdf", size: 3, head: Data([0])) == .pdf)
}

@MainActor @Test func recoveryRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mapo-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecoveryStore(directory: dir)
    try store.write(path: "/x/a.swift", text: "let a = 1")
    #expect(store.read(path: "/x/a.swift")?.text == "let a = 1")
    #expect(store.read(path: "/x/b.swift") == nil)
    store.remove(path: "/x/a.swift")
    #expect(store.read(path: "/x/a.swift") == nil)
    #expect(RecoveryStore.hash("/x/a.swift") == RecoveryStore.hash("/x/a.swift"))
    #expect(RecoveryStore.hash("/x/a.swift") != RecoveryStore.hash("/x/b.swift"))
}

/// The text of each token of one kind.
private func words(_ highlighter: any SyntaxHighlighter, _ text: String, _ kind: SyntaxKind) -> [String] {
    highlighter.tokens(in: text).filter { $0.kind == kind }.map { (text as NSString).substring(with: $0.range) }
}

/// Every kind's tokens, for one snapshot-style comparison.
private func kinds(_ language: SyntaxLanguage, _ text: String) -> [SyntaxKind: [String]] {
    var out: [SyntaxKind: [String]] = [:]
    for kind in SyntaxKind.allCases where kind != .punctuation {
        let found = words(language.highlighter, text, kind)
        if !found.isEmpty { out[kind] = found }
    }
    return out
}

@Test func treeSitterHighlightsSwift() {
    let code = "// note \"x\"\nstruct Foo: Bar {\n    func run() -> String { return baz(\"a // b\", 42) }\n}\n"
    #expect(
        kinds(.swift, code) == [
            .comment: ["// note \"x\""],
            .keyword: ["struct", "func", "return"],
            .type: ["Foo", "Bar", "String"],
            .function: ["run", "baz"],
            .string: ["\"", "a // b", "\""],
            .number: ["42"],
        ])
}

@Test func treeSitterHighlightsRust() {
    let code =
        "/// Doc\npub struct Foo { x: u8 }\nfn main() {\n    let v = Vec::new(); // c\n    println!(\"hi\", 3);\n}\n"
    #expect(
        kinds(.rust, code) == [
            .comment: ["/// Doc\n", "// c"],
            .keyword: ["pub", "struct", "fn", "let"],
            .type: ["Foo", "u8", "Vec"],
            .function: ["main", "new", "println", "!"],
            .string: ["\"hi\""],
            .number: ["3"],
        ])
}

@Test func treeSitterHighlightsOtherLanguages() {
    let samples: [(SyntaxLanguage, String, SyntaxKind, [String])] = [
        (.typescript, "const x: Foo = 1; interface A {}", .keyword, ["const", "interface"]),
        (.tsx, "const a = <div className=\"x\" />;", .string, ["\"x\""]),
        (.javascript, "const x = 'a' /* c */", .comment, ["/* c */"]),
        (.json, "{\"k\": \"v\", \"n\": true}", .function, ["\"k\"", "\"n\""]),
        (.python, "def f(): return None", .keyword, ["def", "return", "None"]),
        (.go, "func main() { fmt.Println(1) }", .function, ["main", "Println"]),
        (.markdown, "# Title\nsome `code` here\n", .string, ["`code`"]),
        (.yaml, "key: 3 # c\n", .comment, ["# c"]),
        (.toml, "[a]\nkey = \"v\"\n", .string, ["\"v\""]),
        (.bash, "echo \"$HOME\" # c\n", .comment, ["# c"]),
        (.css, "a { color: red; }", .function, ["color"]),
        (.html, "<div class=\"x\">hi</div>", .type, ["div", "div"]),
        (.sql, "SELECT a FROM t;", .keyword, ["SELECT", "FROM"]),
    ]
    let found = samples.map { words($0.0.highlighter, $0.1, $0.2) }
    #expect(found == samples.map(\.3))
}

@Test func treeSitterPreparesOffTheMainThread() {
    let highlighter = TreeSitterHighlighter.shared(for: .go)
    highlighter.prepare()
    #expect(highlighter.isPrepared)
}

@MainActor @Test func quickHighlighterCoversTheFirstScreen() throws {
    let swift = try #require(SyntaxLanguage.swift.quickHighlighter)
    let code = "// note \"x\"\nlet s = \"a // b\" + Foo.bar(42)\n"
    #expect(words(swift, code, .comment) == ["// note \"x\""])
    #expect(words(swift, code, .string) == ["\"a // b\""])
    #expect(words(swift, code, .function) == ["bar"])
    let rust = try #require(SyntaxLanguage.rust.quickHighlighter)
    #expect(words(rust, "fn main() { println!(\"hi\"); }", .function) == ["main", "println!"])
    #expect(SyntaxLanguage.python.quickHighlighter == nil)
}

@Test func languagesByPath() {
    let paths = ["/a/b.tsx", "/a/b.ts", "/a/b.py", "/a/.zshrc", "/a/Cargo.lock", "/a/b.yml", "/a/b.txt"]
    #expect(paths.map { SyntaxLanguage(path: $0) } == [.tsx, .typescript, .python, .bash, .toml, .yaml, nil])
}

@MainActor @Test func gitGutterMarksHunks() {
    let base = "a\nb\nc\nd\ne\n"
    let marks = GitGutterMarks(base: base, text: "a\nB\nc\nnew\nd\n")
    #expect(marks.lines == [1: .modified, 3: .added])
    #expect(marks.deletions == [5])
    #expect(marks.hunks == 3)
    #expect(marks.summary == "3 changed hunks")
    #expect(GitGutterMarks(base: base, text: base).summary == "no changes")
    #expect(GitGutterMarks(base: base, text: "b\nc\nd\ne\n").deletions == [0])
}

@MainActor @Test func diffLinesParse() {
    let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n"
    let lines = DiffLine.parse(diff)
    #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .context])
    #expect(lines.map(\.old) == [nil, 1, 2, nil, 3])
    #expect(lines.map(\.new) == [nil, 1, nil, 2, 3])
}
