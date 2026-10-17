import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import IlliquidApp

@Suite("Player shortcut dispatch") @MainActor
struct PlayerShortcutDispatchTests {
    private static let storageKey = "player.shortcut-overrides.v1"

    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func withBindings(
        saved: [String: String] = [:],
        _ body: (PlayerShortcutBindings, UserDefaults) throws -> Void
    ) throws {
        let name = "test.shortcut-dispatch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if !saved.isEmpty { defaults.set(saved, forKey: Self.storageKey) }
        try body(PlayerShortcutBindings(defaults: defaults), defaults)
    }

    private func definition(_ id: String) throws -> PlayerShortcutDefinition {
        try #require(PlayerShortcutDefinition.all.first { $0.id == id })
    }

    private func event(
        _ characters: String,
        ignoringModifiers: String? = nil,
        keyCode: UInt16 = 7,
        flags: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: isRepeat, keyCode: keyCode))
    }

    private func expectResolution(
        _ bindings: PlayerShortcutBindings,
        _ event: NSEvent,
        _ expected: PlayerKeyboardAction?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(bindings.resolve(event) == expected, sourceLocation: sourceLocation)
    }

    @Test func defaultLettersAndLateBindingsResolveWithoutRepeating() throws {
        try withBindings { bindings, _ in
            let cases: [(String, PlayerKeyboardAction)] = [
                ("g", .goToTime), ("a", .loopA), ("b", .loopB), ("s", .screenshot),
                ("f", .toggleFullscreen), ("m", .toggleMute), ("i", .showInspector),
                ("?", .showShortcuts),
            ]
            for (key, expected) in cases {
                try expectResolution(bindings, event(key), expected)
                try expectResolution(bindings, event(key, isRepeat: true), nil)
            }
            try expectResolution(bindings, event("B", ignoringModifiers: "b", flags: .shift), .clearABLoop)
            try expectResolution(bindings, event("B", ignoringModifiers: "b", flags: .shift, isRepeat: true), nil)
            try expectResolution(bindings, event("x"), nil)
            // Escape is intentionally supplied by the fallback, outside the editable definitions.
            try expectResolution(bindings, event("\u{1b}", keyCode: 53), .dismiss)
            try expectResolution(bindings, event("\u{1b}", keyCode: 53, isRepeat: true), nil)
        }
    }

    @Test func navigationUsesKeyCodesAndPreservesRepeatPolicy() throws {
        try withBindings { bindings, _ in
            let cases: [(UInt16, NSEvent.ModifierFlags, PlayerKeyboardAction, PlayerKeyboardAction?)] = [
                (49, [], .togglePause, nil),
                (123, [], .seek(-5), .seek(-5)), (124, [], .seek(5), .seek(5)),
                (123, .shift, .seek(-1), .seek(-1)), (124, .shift, .seek(1), .seek(1)),
                (116, .shift, .seek(-600), .seek(-600)), (121, .shift, .seek(600), .seek(600)),
                (125, [], .volume(-5), .volume(-5)), (126, [], .volume(5), .volume(5)),
                (125, .option, .volume(-1), .volume(-1)), (126, .option, .volume(1), .volume(1)),
                (123, .option, .stepFrame(-1), .stepFrame(-1)), (124, .option, .stepFrame(1), .stepFrame(1)),
                (116, [], .chapter(-1), nil), (121, [], .chapter(1), nil),
                (51, .shift, .undoSeek, nil),
            ]
            let incidentalFlags: [NSEvent.ModifierFlags] = [[], [.capsLock, .function, .numericPad]]
            for (code, modifiers, expected, repeated) in cases {
                for incidental in incidentalFlags {
                    let flags = modifiers.union(incidental)
                    try expectResolution(bindings, event("unrelated", keyCode: code, flags: flags), expected)
                    try expectResolution(bindings, event("unrelated", keyCode: code, flags: flags, isRepeat: true), repeated)
                }
            }
            try expectResolution(bindings, event("", keyCode: 124, flags: [.shift, .option]), nil)
            try expectResolution(bindings, event("", keyCode: 124, flags: .command), nil)
            try expectResolution(bindings, event("", keyCode: 124, flags: .control), nil)
        }
    }

    @Test func lettersFollowLayoutAndRequireExactShortcutModifiers() throws {
        try withBindings { bindings, _ in
            try expectResolution(bindings, event("F", keyCode: 7, flags: [.capsLock, .function, .numericPad]), .toggleFullscreen)
            try expectResolution(bindings, event("x", keyCode: 3), nil)
            try expectResolution(bindings, event("F", ignoringModifiers: "f", flags: .shift), nil)
            let mute = try definition("mute")
            #expect(bindings.set("Option+W", for: mute) == nil)
            try expectResolution(bindings, event("∑", ignoringModifiers: "w", flags: .option), .toggleMute)
            let extraModifiers: [NSEvent.ModifierFlags] = [.shift, .command, .control]
            for extra in extraModifiers {
                try expectResolution(bindings, event("∑", ignoringModifiers: "w", flags: [.option, extra]), nil)
            }
        }
    }

    @Test func questionMarkAcceptsLayoutModifiersButRejectsRepeatsAndCommands() throws {
        try withBindings { bindings, _ in
            let allowed: [NSEvent.ModifierFlags] = [[], .shift, .option, [.shift, .option],
                [.shift, .option, .capsLock, .function, .numericPad]]
            for flags in allowed {
                try expectResolution(bindings, event("?", ignoringModifiers: "/", keyCode: 44, flags: flags), .showShortcuts)
                try expectResolution(bindings, event("?", ignoringModifiers: "/", keyCode: 44, flags: flags, isRepeat: true), nil)
            }
            let reserved: [NSEvent.ModifierFlags] = [.command, .control, [.shift, .command], [.option, .control]]
            for flags in reserved {
                try expectResolution(bindings, event("?", ignoringModifiers: "/", keyCode: 44, flags: flags), nil)
            }
        }
    }

    @Test func remappingHelpSuppressesQuestionMarkFallbackAndCanFreeTheChord() throws {
        try withBindings { bindings, _ in
            let help = try definition("help"), screenshot = try definition("screenshot")
            #expect(bindings.set("H", for: help) == nil)
            try expectResolution(bindings, event("h"), .showShortcuts)
            let question = try event("?", ignoringModifiers: "/", flags: [.shift, .option])
            #expect(bindings.resolve(question) == nil)
            #expect(bindings.set("?", for: screenshot) == nil)
            #expect(bindings.resolve(question) == .screenshot)
            try expectResolution(bindings, event("?", ignoringModifiers: "/", flags: [.shift, .option], isRepeat: true), nil)
            try expectResolution(bindings, event("h"), .showShortcuts)
        }
    }

    @Test func overlappingLayoutBindingsKeepDefinitionOrderAndFirstMatchRepeatPolicy() throws {
        try withBindings { bindings, _ in
            // Option+/ and '?' are distinct chords that can match the same layout event.
            // The earlier definition must win, regardless of override insertion order.
            let help = try definition("help"), back = try definition("back")
            #expect(bindings.set("?", for: help) == nil)
            let screenshot = try definition("screenshot")
            #expect(bindings.set("Option+/", for: screenshot) == nil)
            let press = try event("?", ignoringModifiers: "/", flags: .option)
            let repeatPress = try event("?", ignoringModifiers: "/", flags: .option, isRepeat: true)
            #expect(bindings.resolve(press) == .screenshot)
            #expect(bindings.resolve(repeatPress) == nil)
            #expect(bindings.set("S", for: screenshot) == nil)
            #expect(bindings.set("Option+/", for: back) == nil)
            #expect(bindings.resolve(press) == .seek(-5))
            #expect(bindings.resolve(repeatPress) == .seek(-5))
        }
    }

    @Test func successfulChangesImmediatelyReplaceDispatchAndSuppressOldDefaults() throws {
        try withBindings { bindings, defaults in
            let mute = try definition("mute"), screenshot = try definition("screenshot")
            #expect(bindings.set("X", for: mute) == nil)
            try expectResolution(bindings, event("x"), .toggleMute)
            try expectResolution(bindings, event("m"), nil)
            #expect(bindings.set("M", for: screenshot) == nil)
            try expectResolution(bindings, event("m"), .screenshot)
            try expectResolution(bindings, event("s"), nil)
            #expect(bindings.set("Q", for: screenshot) == nil)
            try expectResolution(bindings, event("m"), nil)
            try expectResolution(bindings, event("q"), .screenshot)
            #expect(bindings.set("  Shift+X  ", for: mute) == nil)
            try expectResolution(bindings, event("x"), nil)
            try expectResolution(bindings, event("X", ignoringModifiers: "x", flags: .shift), .toggleMute)
            try expectResolution(bindings, event("X", ignoringModifiers: "x", flags: .shift, isRepeat: true), nil)
            #expect(defaults.dictionary(forKey: Self.storageKey) as? [String: String] == ["mute": "Shift+X", "screenshot": "Q"])
        }
    }

    @Test func rejectedChangesKeepActiveBindingAndSavedPreferences() throws {
        try withBindings { bindings, defaults in
            let mute = try definition("mute")
            #expect(bindings.set("X", for: mute) == nil)
            for invalid in ["", " ", "Shift+", "Shift+Shift+X", "Unknown+X", "\n", "Command+X", "Control+X", "F"] {
                #expect(bindings.set(invalid, for: mute) != nil)
                #expect(bindings.key(for: mute) == "X")
                try expectResolution(bindings, event("x"), .toggleMute)
                try expectResolution(bindings, event("m"), nil)
                #expect(defaults.dictionary(forKey: Self.storageKey) as? [String: String] == ["mute": "X"])
            }
        }
    }

    @Test func savedRemapChainsAndCyclesRestoreAsACompleteMap() throws {
        let saved = ["time": "A", "loop-a": "B", "loop-b": "X",
            "screenshot": "M", "mute": "F", "fullscreen": "S"]
        try withBindings(saved: saved) { bindings, defaults in
            let cases: [(String, PlayerKeyboardAction?)] = [
                ("a", .goToTime), ("b", .loopA), ("x", .loopB), ("g", nil),
                ("m", .screenshot), ("f", .toggleMute), ("s", .toggleFullscreen),
            ]
            for (key, expected) in cases { try expectResolution(bindings, event(key), expected) }
            #expect(defaults.dictionary(forKey: Self.storageKey) as? [String: String] == saved)
        }
    }

    @Test func savedConflictRepairCascadesBeforeDispatchWithoutWritingOnStartup() throws {
        // Removing time's conflicting X exposes loop-a's G conflict, then loop-b's A conflict.
        let saved = ["time": "X", "loop-a": "G", "loop-b": "A", "screenshot": "X"]
        try withBindings(saved: saved) { bindings, defaults in
            let cases: [(String, PlayerKeyboardAction?)] = [
                ("g", .goToTime), ("a", .loopA), ("b", .loopB), ("x", .screenshot), ("s", nil),
            ]
            for (key, expected) in cases { try expectResolution(bindings, event(key), expected) }
            #expect(bindings.overrides == ["screenshot": "X"])
            #expect(defaults.dictionary(forKey: Self.storageKey) as? [String: String] == saved)
        }
    }

    @Test func blankMalformedReservedAndUnknownSavedBindingsAreIgnored() throws {
        let saved = ["time": "", "loop-a": "Shift+Shift+A", "loop-b": "Command+X",
            "screenshot": "Ctrl+X", "mute": "\nX", "help": " ", "unknown-action": "X",
            "forward": " Shift + Option + X "]
        try withBindings(saved: saved) { bindings, defaults in
            let cases: [(String, PlayerKeyboardAction?)] = [
                ("g", .goToTime), ("a", .loopA), ("b", .loopB), ("s", .screenshot),
                ("m", .toggleMute), ("?", .showShortcuts), ("x", nil),
            ]
            for (key, expected) in cases { try expectResolution(bindings, event(key), expected) }
            try expectResolution(bindings, event("X", ignoringModifiers: "x", flags: [.shift, .option]), .seek(5))
            try expectResolution(bindings, event("", keyCode: 124), nil)
            #expect(bindings.overrides == ["forward": " Shift + Option + X "])
            #expect(defaults.dictionary(forKey: Self.storageKey) as? [String: String] == saved)
        }
    }

    @Test func eachInstanceKeepsItsOwnPreferenceSnapshot() throws {
        try withBindings(saved: ["mute": "X"]) { first, defaults in
            let second = PlayerShortcutBindings(defaults: defaults)
            defaults.set(["mute": "Z"], forKey: Self.storageKey)
            let third = PlayerShortcutBindings(defaults: defaults)
            for bindings in [first, second] {
                try expectResolution(bindings, event("x"), .toggleMute)
                try expectResolution(bindings, event("z"), nil)
            }
            try expectResolution(third, event("z"), .toggleMute)
            try expectResolution(third, event("x"), nil)
            let mute = try definition("mute")
            #expect(first.set("K", for: mute) == nil)
            try expectResolution(first, event("k"), .toggleMute)
            try expectResolution(first, event("x"), nil)
            try expectResolution(second, event("x"), .toggleMute)
            try expectResolution(third, event("z"), .toggleMute)
        }
    }

    @Test func keyAndMenuObserversStillPublishChangesAndResetRestoresDefaults() throws {
        try withBindings { bindings, defaults in
            let mute = try definition("mute")
            let keyChanges = Changes(), menuChanges = Changes()
            @MainActor func observe() {
                withObservationTracking { _ = bindings.key(for: mute) }
                    onChange: { keyChanges.increment() }
                withObservationTracking { _ = bindings.menuShortcut(for: .toggleMute) }
                    onChange: { menuChanges.increment() }
            }
            observe()
            try expectResolution(bindings, event("m"), .toggleMute)
            #expect(keyChanges.count == 0 && menuChanges.count == 0)
            #expect(bindings.set("Shift+Option+X", for: mute) == nil)
            #expect(keyChanges.count == 1 && menuChanges.count == 1)
            #expect(bindings.key(for: mute) == "Shift+Option+X")
            let remapped = try #require(bindings.menuShortcut(for: .toggleMute))
            #expect(remapped.key == KeyEquivalent("x"))
            #expect(remapped.modifiers == [.shift, .option])
            observe()
            bindings.reset()
            #expect(keyChanges.count == 2 && menuChanges.count == 2)
            #expect(bindings.key(for: mute) == "M")
            let restored = try #require(bindings.menuShortcut(for: .toggleMute))
            #expect(restored.key == KeyEquivalent("m"))
            #expect(restored.modifiers.isEmpty)
            try expectResolution(bindings, event("m"), .toggleMute)
            try expectResolution(bindings, event("X", ignoringModifiers: "x", flags: [.shift, .option]), nil)
            #expect(defaults.object(forKey: Self.storageKey) == nil)
        }
    }
}
