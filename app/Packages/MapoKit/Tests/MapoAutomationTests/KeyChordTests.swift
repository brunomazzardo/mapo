import Testing

@testable import MapoAutomation

@Test func parsesModifiersAndLetter() throws {
    let chord = try KeyChord(parsing: "cmd+shift+n")
    #expect(chord.modifiers == [.command, .shift])
    #expect(chord.key?.keyCode == 45)
    #expect(chord.key.map { USKeyboard.characters(of: $0, modifiers: chord.modifiers) } == "N")
}

@Test func parsesNamedKeysAndAliases() throws {
    #expect(try KeyChord(parsing: "return").key?.keyCode == 36)
    #expect(try KeyChord(parsing: "opt+left").modifiers == .option)
    #expect(try KeyChord(parsing: "alt+left").key?.function == true)
    #expect(try KeyChord(parsing: "f12").key?.keyCode == 111)
    #expect(try KeyChord(parsing: "pagedown").key?.keyCode == 121)
}

@Test func parsesPunctuationAndPlus() throws {
    #expect(try KeyChord(parsing: "cmd+=").key?.keyCode == 24)
    let plus = try KeyChord(parsing: "ctrl++")
    #expect(plus.modifiers == [.control, .shift])
    #expect(plus.key?.keyCode == 24)
    #expect(try KeyChord(parsing: "cmd+[").key?.keyCode == 33)
}

@Test func modifiersAlone() throws {
    let chord = try KeyChord(parsing: "cmd")
    #expect(chord.key == nil)
    #expect(chord.modifiers == .command)
}

@Test func rejectsBadChords() {
    #expect(throws: KeyChord.ParseError.unknownKey("banana")) { try KeyChord(parsing: "cmd+banana") }
    #expect(throws: KeyChord.ParseError.unknownModifier("hyper")) { try KeyChord(parsing: "hyper+t") }
    #expect(throws: KeyChord.ParseError.empty) { try KeyChord(parsing: " ") }
}

@Test func typesShiftedCharacters() {
    #expect(USKeyboard.key(for: "$") == USKey(keyCode: 21, characters: "$", shift: true))
    #expect(USKeyboard.key(for: "E") == USKey(keyCode: 14, characters: "E", shift: true))
    #expect(USKeyboard.key(for: "\n")?.keyCode == 36)
    #expect(USKeyboard.key(for: "é") == nil)
}

@Test func controlLettersBecomeC0() {
    let key = USKeyboard.key(for: "c")
    #expect(key.map { USKeyboard.characters(of: $0, modifiers: .control) } == "\u{03}")
    #expect(key.map { USKeyboard.charactersIgnoringModifiers(of: $0, modifiers: .control) } == "c")
}
