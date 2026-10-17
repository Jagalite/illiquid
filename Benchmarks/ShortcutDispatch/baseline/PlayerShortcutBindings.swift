import AppKit
import Observation
import SwiftUI

struct PlayerShortcutDefinition: Identifiable {
    let id: String
    let title: String
    let action: PlayerKeyboardAction
    let defaultKey: String

    static let all: [Self] = [
        .init(id: "time", title: "Go to Time", action: .goToTime, defaultKey: "G"),
        .init(id: "loop-a", title: "Set loop start (A)", action: .loopA, defaultKey: "A"),
        .init(id: "loop-b", title: "Set loop end (B)", action: .loopB, defaultKey: "B"),
        .init(id: "loop-clear", title: "Clear A–B loop", action: .clearABLoop, defaultKey: "Shift+B"),
        .init(id: "screenshot", title: "Save screenshot", action: .screenshot, defaultKey: "S"),
        .init(id: "play", title: "Play or pause", action: .togglePause, defaultKey: "Space"),
        .init(id: "back", title: "Seek backward 5 seconds", action: .seek(-5), defaultKey: "Left"),
        .init(id: "forward", title: "Seek forward 5 seconds", action: .seek(5), defaultKey: "Right"),
        .init(id: "back-small", title: "Seek backward 1 second", action: .seek(-1), defaultKey: "Shift+Left"),
        .init(id: "forward-small", title: "Seek forward 1 second", action: .seek(1), defaultKey: "Shift+Right"),
        .init(id: "back-large", title: "Seek backward 10 minutes", action: .seek(-600), defaultKey: "Shift+PageUp"),
        .init(id: "forward-large", title: "Seek forward 10 minutes", action: .seek(600), defaultKey: "Shift+PageDown"),
        .init(id: "quieter", title: "Volume down 5%", action: .volume(-5), defaultKey: "Down"),
        .init(id: "louder", title: "Volume up 5%", action: .volume(5), defaultKey: "Up"),
        .init(id: "quieter-small", title: "Volume down 1%", action: .volume(-1), defaultKey: "Option+Down"),
        .init(id: "louder-small", title: "Volume up 1%", action: .volume(1), defaultKey: "Option+Up"),
        .init(id: "frame-back", title: "Previous frame", action: .stepFrame(-1), defaultKey: "Option+Left"),
        .init(id: "frame-forward", title: "Next frame", action: .stepFrame(1), defaultKey: "Option+Right"),
        .init(id: "chapter-back", title: "Previous chapter", action: .chapter(-1), defaultKey: "PageUp"),
        .init(id: "chapter-forward", title: "Next chapter", action: .chapter(1), defaultKey: "PageDown"),
        .init(id: "undo-seek", title: "Undo seek", action: .undoSeek, defaultKey: "Shift+Delete"),
        .init(id: "fullscreen", title: "Toggle fullscreen", action: .toggleFullscreen, defaultKey: "F"),
        .init(id: "mute", title: "Mute or unmute", action: .toggleMute, defaultKey: "M"),
        .init(id: "inspector", title: "Playback Inspector", action: .showInspector, defaultKey: "I"),
        .init(id: "help", title: "Keyboard Shortcuts", action: .showShortcuts, defaultKey: "?"),
    ]
}

struct PlayerShortcutChord: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ text: String) {
        guard text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty,
              key.count == 1 || ["space", "left", "right", "up", "down", "pageup", "pagedown", "delete"].contains(key) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            let flag: NSEvent.ModifierFlags
            switch part {
            case "command", "cmd": flag = .command
            case "option", "alt": flag = .option
            case "control", "ctrl": flag = .control
            case "shift": flag = .shift
            default: return nil
            }
            guard !modifiers.contains(flag) else { return nil }
            modifiers.insert(flag)
        }
        self.key = key; self.modifiers = modifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if key == "?", modifiers.isEmpty, event.characters == "?", flags.isSubset(of: [.shift, .option]) { return true }
        guard flags == modifiers else { return false }
        let navigation: [UInt16: String] = [49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 116: "pageup", 121: "pagedown", 51: "delete"]
        return (navigation[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased()) == key
    }
}

@Observable @MainActor
final class PlayerShortcutBindings {
    private(set) var overrides: [String: String]
    private let defaults: UserDefaults
    private static let storageKey = "player.shortcut-overrides.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = [:]
        let saved = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        // Restore the complete map before checking conflicts: one remap may use
        // a default key that another remap has freed. Do not write on startup.
        for definition in PlayerShortcutDefinition.all {
            if let value = saved[definition.id], let chord = PlayerShortcutChord(value),
               !chord.modifiers.contains(.command), !chord.modifiers.contains(.control) {
                overrides[definition.id] = value
            }
        }
        // Invalid stored conflicts fall back deterministically to defaults.
        // Removing an override can expose another conflict, so recheck the map.
        while let conflicting = PlayerShortcutDefinition.all.first(where: { definition in
            overrides[definition.id] != nil && PlayerShortcutDefinition.all.contains {
                $0.id != definition.id && PlayerShortcutChord(key(for: $0)) == PlayerShortcutChord(key(for: definition))
            }
        }) { overrides.removeValue(forKey: conflicting.id) }
    }

    func key(for definition: PlayerShortcutDefinition) -> String {
        overrides[definition.id] ?? definition.defaultKey
    }

    @discardableResult
    func set(_ text: String, for definition: PlayerShortcutDefinition) -> String? {
        guard let chord = PlayerShortcutChord(text) else {
            return "Use a key such as Space, Right or K, with optional Shift or Option modifiers."
        }
        // Native application/menu commands and Escape remain discoverable and
        // retain their platform meaning. Playback shortcuts are a separate layer.
        guard !chord.modifiers.contains(.command), !chord.modifiers.contains(.control),
              chord.key != "\u{1b}", chord.key != "\t", chord.key != "\r" else {
            return "Command and Control combinations, Tab and Escape are reserved for macOS and app menus."
        }
        if let conflict = PlayerShortcutDefinition.all.first(where: {
            $0.id != definition.id && PlayerShortcutChord(key(for: $0)) == chord
        }) { return "Already used by \(conflict.title). Change that shortcut first." }
        overrides[definition.id] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(overrides, forKey: Self.storageKey)
        return nil
    }

    func reset() { overrides = [:]; defaults.removeObject(forKey: Self.storageKey) }

    func menuShortcut(for action: PlayerKeyboardAction) -> KeyboardShortcut? {
        guard let definition = PlayerShortcutDefinition.all.first(where: { $0.action == action }),
              let chord = PlayerShortcutChord(key(for: definition)) else { return nil }
        let equivalents: [String: KeyEquivalent] = ["space": .space, "left": .leftArrow,
            "right": .rightArrow, "up": .upArrow, "down": .downArrow,
            "delete": .delete, "pageup": .pageUp, "pagedown": .pageDown]
        guard let equivalent = equivalents[chord.key] ?? (chord.key.count == 1 ? KeyEquivalent(Character(chord.key)) : nil) else { return nil }
        var modifiers: EventModifiers = []
        if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if chord.modifiers.contains(.option) { modifiers.insert(.option) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    func resolve(_ event: NSEvent) -> PlayerKeyboardAction? {
        for definition in PlayerShortcutDefinition.all {
            if PlayerShortcutChord(key(for: definition))?.matches(event) == true {
                if event.isARepeat {
                    switch definition.action {
                    case .seek, .volume, .stepFrame: break
                    default: return nil
                    }
                }
                return definition.action
            }
        }
        let fallback = PlayerKeyboardAction.resolve(keyCode: event.keyCode, characters: event.characters,
            modifierFlags: event.modifierFlags, isRepeat: event.isARepeat)
        if let fallback, PlayerShortcutDefinition.all.contains(where: {
            $0.action == fallback && overrides[$0.id] != nil
        }) { return nil }
        return fallback
    }
}
