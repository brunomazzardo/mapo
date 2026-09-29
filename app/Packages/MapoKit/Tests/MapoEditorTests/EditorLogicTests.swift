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
@MainActor private func words(_ language: SyntaxLanguage, _ text: String, _ kind: SyntaxKind) -> [String] {
    language.highlighter.tokens(in: text).filter { $0.kind == kind }.map {
        (text as NSString).substring(with: $0.range)
    }
}

@MainActor @Test func highlightsSwift() {
    let code = "// note \"x\"\nlet s = \"a // b\" + Foo.bar(42)\n"
    #expect(words(.swift, code, .comment) == ["// note \"x\""])
    #expect(words(.swift, code, .string) == ["\"a // b\""])
    #expect(words(.swift, code, .keyword) == ["let"])
    #expect(words(.swift, code, .type) == ["Foo"])
    #expect(words(.swift, code, .function) == ["bar"])
    #expect(words(.swift, code, .number) == ["42"])
}

@MainActor @Test func highlightsOtherLanguages() {
    #expect(words(.rust, "fn main() { println!(\"hi\"); }", .keyword) == ["fn"])
    #expect(words(.rust, "fn main() { println!(\"hi\"); }", .function) == ["main", "println!"])
    #expect(words(.typescript, "const x: Foo = `t${1}`; interface A {}", .keyword) == ["const", "interface"])
    #expect(words(.javascript, "const x = 'a' /* c */", .comment) == ["/* c */"])
    #expect(words(.json, "{\"k\": \"v\", \"n\": true}", .function) == ["\"k\"", "\"n\""])
    #expect(words(.json, "{\"k\": \"v\", \"n\": true}", .string) == ["\"v\""])
    #expect(words(.markdown, "# Title\nsome `code` here\n", .keyword) == ["# Title"])
    #expect(words(.markdown, "# Title\nsome `code` here\n", .string) == ["`code`"])
    #expect(SyntaxLanguage(path: "/a/b.tsx") == .typescript)
    #expect(SyntaxLanguage(path: "/a/b.txt") == nil)
}
