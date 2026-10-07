import AppKit
import Foundation
import Testing
@testable import IlliquidApp

@Suite("Persistent playback shortcut mapping") @MainActor
struct PlayerShortcutBindingsTests {
    @Test func remappingSuppressesDefaultAndRejectsConflicts() throws {
        let name = "test.shortcuts.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let bindings = PlayerShortcutBindings(defaults: defaults)
        let mute = try #require(PlayerShortcutDefinition.all.first { $0.id == "mute" })
        #expect(bindings.set("F", for: mute) != nil)
        #expect(bindings.set("Command+Q", for: mute) != nil)
        #expect(bindings.set("X", for: mute) == nil)
        func event(_ key: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 7))
        }
        #expect(bindings.resolve(try event("x")) == .toggleMute)
        #expect(bindings.resolve(try event("m")) == nil)
        #expect(PlayerShortcutBindings(defaults: defaults).key(for: mute) == "X")
        let screenshot = try #require(PlayerShortcutDefinition.all.first { $0.id == "screenshot" })
        #expect(bindings.set("M", for: screenshot) == nil)
        let restored = PlayerShortcutBindings(defaults: defaults)
        #expect(restored.key(for: screenshot) == "M")
        #expect(restored.key(for: mute) == "X")
        #expect(bindings.set("\n", for: mute) != nil)
        bindings.reset()
        #expect(bindings.resolve(try event("m")) == .toggleMute)
        #expect(bindings.resolve(try event("x")) == nil)
    }
}
