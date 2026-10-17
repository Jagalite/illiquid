// Linux adapters for the shortcut algorithm qualification. These are value
// stand-ins for framework APIs, not AppKit or SwiftUI performance models.
// On macOS the harness and tests use the real framework implementations.
#if !canImport(AppKit)
import Foundation

final class NSEvent: @unchecked Sendable {
    struct ModifierFlags: OptionSet, Sendable {
        var rawValue: UInt
        static let capsLock = Self(rawValue: 1 << 16)
        static let shift = Self(rawValue: 1 << 17)
        static let control = Self(rawValue: 1 << 18)
        static let option = Self(rawValue: 1 << 19)
        static let command = Self(rawValue: 1 << 20)
        static let numericPad = Self(rawValue: 1 << 21)
        static let help = Self(rawValue: 1 << 22)
        static let function = Self(rawValue: 1 << 23)
        static let deviceIndependentFlagsMask = Self(rawValue: 0xffff0000)
    }

    enum EventType { case keyDown }

    let keyCode: UInt16
    let characters: String?
    let charactersIgnoringModifiers: String?
    let modifierFlags: ModifierFlags
    let isARepeat: Bool

    private init(keyCode: UInt16, characters: String,
                 charactersIgnoringModifiers: String,
                 modifierFlags: ModifierFlags, isARepeat: Bool) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifierFlags = modifierFlags
        self.isARepeat = isARepeat
    }

    static func keyEvent(
        with type: EventType,
        location: CGPoint,
        modifierFlags: ModifierFlags,
        timestamp: TimeInterval,
        windowNumber: Int,
        context: Any?,
        characters: String,
        charactersIgnoringModifiers: String,
        isARepeat: Bool,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent(keyCode: keyCode, characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifierFlags: modifierFlags, isARepeat: isARepeat)
    }
}
#endif

#if !canImport(SwiftUI)
struct KeyEquivalent: Equatable, Hashable, Sendable {
    let character: Character
    init(_ character: Character) { self.character = character }
    static let space = Self(" ")
    static let leftArrow = Self("\u{f702}")
    static let rightArrow = Self("\u{f703}")
    static let upArrow = Self("\u{f700}")
    static let downArrow = Self("\u{f701}")
    static let delete = Self("\u{7f}")
    static let pageUp = Self("\u{f72c}")
    static let pageDown = Self("\u{f72d}")
}

struct EventModifiers: OptionSet, Sendable {
    var rawValue: UInt
    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

struct KeyboardShortcut: Equatable, Sendable {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }
}
#endif
