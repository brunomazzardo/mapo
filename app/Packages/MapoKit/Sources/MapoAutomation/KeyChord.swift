import AppKit

/// A key on the US layout: its virtual key code and the characters it types (ENGINEERING §4.3).
nonisolated struct USKey: Equatable, Sendable {
    var keyCode: UInt16
    /// What the key types with `shift` applied, such as "N" or "$".
    var characters: String
    /// True when typing `characters` needs shift.
    var shift = false
    /// Arrows, Home, End, Page Up, Page Down and F-keys carry the function flag; arrows also the keypad flag.
    var function = false
    var numericPad = false
}

/// The modifiers of a chord.
nonisolated struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let command = KeyModifiers(rawValue: 1)
    static let shift = KeyModifiers(rawValue: 2)
    static let option = KeyModifiers(rawValue: 4)
    static let control = KeyModifiers(rawValue: 8)

    /// `cmd`, `shift`, `alt` or `opt`, `ctrl`; nil for anything else.
    init?(name: String) {
        switch name.lowercased() {
        case "cmd", "command": self = .command
        case "shift": self = .shift
        case "alt", "opt", "option": self = .option
        case "ctrl", "control": self = .control
        default: return nil
        }
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// A parsed `ui.key` chord: modifiers joined with `+`, then a key (ENGINEERING §4.3). A chord of modifiers
/// alone (`cmd`) is allowed so a drive can hold ⌘ with `phase: "down"`.
nonisolated struct KeyChord: Equatable, Sendable {
    var modifiers: KeyModifiers
    var key: USKey?

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownModifier(String)
        case unknownKey(String)

        var description: String {
            switch self {
            case .empty: "The chord is empty"
            case .unknownModifier(let name): "Unknown modifier \"\(name)\" (use cmd, shift, alt, opt or ctrl)"
            case .unknownKey(let name): "Unknown key \"\(name)\""
            }
        }
    }

    init(modifiers: KeyModifiers, key: USKey?) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses `cmd+shift+n`, `return`, `cmd+=` or `ctrl++`. The last part is the key unless it names a
    /// modifier.
    init(parsing chord: String) throws(ParseError) {
        let text = chord.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw .empty }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // A trailing "+" key splits into two empty parts: "ctrl++" is ["ctrl", "", ""].
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        var modifiers: KeyModifiers = []
        let last = parts.removeLast()
        for part in parts {
            guard let modifier = KeyModifiers(name: part) else { throw .unknownModifier(part) }
            modifiers.insert(modifier)
        }
        if let modifier = KeyModifiers(name: last) {
            modifiers.insert(modifier)
            self.init(modifiers: modifiers, key: nil)
            return
        }
        guard let key = USKeyboard.key(named: last) else { throw .unknownKey(last) }
        if key.shift { modifiers.insert(.shift) }
        self.init(modifiers: modifiers, key: key)
    }
}

/// US-layout virtual key codes (Carbon `kVK_*`), which libghostty encodes from, and the characters each
/// key types.
nonisolated enum USKeyboard {
    private static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]

    /// Shifted characters and the key that types them.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]

    /// Whether `text` is one character that the US layout types with shift, such as "}" or "+".
    static func isShiftedSymbol(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return shifted[character] != nil
    }

    private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// The key that types `character`, with shift when needed; nil outside the US layout.
    static func key(for character: Character) -> USKey? {
        switch character {
        case "\n", "\r": return named["return"]
        case "\t": return named["tab"]
        default: break
        }
        if let code = unshifted[character] {
            return USKey(keyCode: code, characters: String(character))
        }
        if character.isUppercase, let lower = character.lowercased().first, lower != character,
            let code = unshifted[lower]
        {
            return USKey(keyCode: code, characters: String(character), shift: true)
        }
        if let base = shifted[character], let code = unshifted[base] {
            return USKey(keyCode: code, characters: String(character), shift: true)
        }
        return nil
    }

    /// A chord's key: a name such as `return` or `f5`, or a single character.
    static func key(named name: String) -> USKey? {
        let lower = name.lowercased()
        if let key = named[lower] { return key }
        if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...12).contains(number) {
            let character = Character(UnicodeScalar(UInt32(NSF1FunctionKey + number - 1)) ?? " ")
            return USKey(
                keyCode: functionKeyCodes[number - 1], characters: String(character), function: true)
        }
        guard name.count == 1, let character = name.first else { return nil }
        // Chords name keys, not characters: "N" is the n key.
        if character.isUppercase, let lower = lower.first { return key(for: lower) }
        return key(for: character)
    }

    private static func function(_ code: UInt16, _ scalar: Int, numericPad: Bool = false) -> USKey {
        USKey(
            keyCode: code, characters: String(Character(UnicodeScalar(UInt32(scalar)) ?? " ")), function: true,
            numericPad: numericPad)
    }

    private static let named: [String: USKey] = [
        "return": USKey(keyCode: 36, characters: "\r"),
        "enter": USKey(keyCode: 36, characters: "\r"),
        "escape": USKey(keyCode: 53, characters: "\u{1B}"),
        "esc": USKey(keyCode: 53, characters: "\u{1B}"),
        "tab": USKey(keyCode: 48, characters: "\t"),
        "space": USKey(keyCode: 49, characters: " "),
        "delete": USKey(keyCode: 51, characters: "\u{7F}"),
        "backspace": USKey(keyCode: 51, characters: "\u{7F}"),
        "left": function(123, NSLeftArrowFunctionKey, numericPad: true),
        "right": function(124, NSRightArrowFunctionKey, numericPad: true),
        "down": function(125, NSDownArrowFunctionKey, numericPad: true),
        "up": function(126, NSUpArrowFunctionKey, numericPad: true),
        "home": function(115, NSHomeFunctionKey),
        "end": function(119, NSEndFunctionKey),
        "pageup": function(116, NSPageUpFunctionKey),
        "pagedown": function(121, NSPageDownFunctionKey),
    ]

    /// The characters a key types under `modifiers`: shift applies, and control turns a letter into its C0
    /// code, as AppKit does.
    static func characters(of key: USKey, modifiers: KeyModifiers) -> String {
        let base = charactersIgnoringModifiers(of: key, modifiers: modifiers)
        guard modifiers.contains(.control), let scalar = base.lowercased().unicodeScalars.first,
            ("a"..."z").contains(scalar), let control = UnicodeScalar(scalar.value & 0x1F)
        else {
            return base
        }
        return String(Character(control))
    }

    /// The characters ignoring every modifier but shift, as `NSEvent.charactersIgnoringModifiers` reports.
    static func charactersIgnoringModifiers(of key: USKey, modifiers: KeyModifiers) -> String {
        guard modifiers.contains(.shift), !key.shift else { return key.characters }
        if let shiftedCharacter = shifted.first(where: { String($0.value) == key.characters })?.key {
            return String(shiftedCharacter)
        }
        return key.characters.uppercased()
    }

    /// The key codes of the modifier keys, for `flagsChanged` events.
    static func modifierKeyCode(_ modifier: KeyModifiers) -> UInt16 {
        switch modifier {
        case .command: 55
        case .shift: 56
        case .option: 58
        default: 59
        }
    }
}
