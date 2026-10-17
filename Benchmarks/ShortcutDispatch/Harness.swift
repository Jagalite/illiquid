import Foundation
@testable import IlliquidApp
#if canImport(AppKit)
import AppKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

// The driver consumes the selected revision's complete shortcut implementation
// and its actual PlayerKeyboardAction. No copied resolver supplies expected
// results. `verify` produces deterministic receipts to compare two separately
// compiled revisions; native unit tests supply independent semantic assertions.
// Linux runs use value adapters and qualify parsing/dispatch algorithms only.
// macOS runs construct real NSEvent objects and use real SwiftUI menu values.

private let workloadNames = [
    "head-hit", "seek-repeat", "late-hit", "unmatched", "fallback",
    "modifiers", "question-layout", "mixed", "cached-remap", "construction",
]

@MainActor
private func keyboardEvent(
    _ keyCode: UInt16,
    _ characters: String,
    _ flags: NSEvent.ModifierFlags = [],
    _ isRepeat: Bool = false,
    ignoring: String? = nil
) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 1, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: ignoring ?? characters,
        isARepeat: isRepeat, keyCode: keyCode
    ) else { preconditionFailure("Unable to construct the qualification event") }
    return event
}

// Codes describe resolved outputs only. They do not encode event-to-action
// behavior and cannot conceal changed routing behind a duplicate resolver.
private func actionCode(_ action: PlayerKeyboardAction?) -> Int64 {
    guard let action else { return 1 }
    switch action {
    case .togglePause: return 2
    case let .seek(value): return 2_000_000 + Int64(value * 1_000)
    case let .volume(value): return 3_000_000 + Int64(value * 1_000)
    case let .stepFrame(value): return 4_000_000 + Int64(value)
    case let .chapter(value): return 5_000_000 + Int64(value)
    case .undoSeek: return 6
    case .dismiss: return 7
    case .showShortcuts: return 8
    case .showInspector: return 9
    case .toggleFullscreen: return 10
    case .toggleMute: return 11
    case .goToTime: return 12
    case .loopA: return 13
    case .loopB: return 14
    case .clearABLoop: return 15
    case .screenshot: return 16
    }
}

private struct ReceiptDigest {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ integer: Int64) {
        let unsigned = UInt64(bitPattern: integer)
        for shift in stride(from: 0, to: 64, by: 8) {
            value = (value ^ ((unsigned >> shift) & 255)) &* 1_099_511_628_211
        }
    }

    mutating func append(_ string: String) {
        append(Int64(string.utf8.count))
        for byte in string.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    var hexadecimal: String { String(value, radix: 16) }
}

@MainActor
@inline(never)
private func dispatchBatch(
    _ bindings: PlayerShortcutBindings,
    events: [NSEvent], iterations: Int
) -> Int64 {
    var checksum: Int64 = 0
    for _ in 0..<iterations {
        for event in events { checksum &+= actionCode(bindings.resolve(event)) }
    }
    return checksum
}

@MainActor
@inline(never)
private func constructionBatch(_ defaults: UserDefaults, iterations: Int) -> Int64 {
    var checksum: Int64 = 0
    for _ in 0..<iterations {
        let bindings = PlayerShortcutBindings(defaults: defaults)
        for definition in PlayerShortcutDefinition.all {
            checksum &+= Int64(bindings.key(for: definition).utf8.count)
        }
    }
    return checksum
}

@MainActor
private func events(for name: String) -> [NSEvent] {
    switch name {
    case "head-hit": return [keyboardEvent(5, "g")]
    case "seek-repeat": return [keyboardEvent(124, "\u{f703}", [], true)]
    case "late-hit": return [keyboardEvent(46, "m"), keyboardEvent(34, "i")]
    case "unmatched": return [keyboardEvent(7, "x"), keyboardEvent(8, "c")]
    case "fallback": return [keyboardEvent(53, "\u{1b}")]
    case "modifiers": return [
        keyboardEvent(7, "x", .command), keyboardEvent(7, "X", .control),
        keyboardEvent(123, "\u{f702}", .option, true),
    ]
    case "question-layout": return [
        keyboardEvent(27, "?", .shift, ignoring: "/"),
        keyboardEvent(27, "?", .option, ignoring: "ß"),
    ]
    case "mixed": return [
        keyboardEvent(124, "\u{f703}", [], true),
        keyboardEvent(123, "\u{f702}", .shift, true),
        keyboardEvent(49, " "), keyboardEvent(3, "f"),
        keyboardEvent(7, "x"), keyboardEvent(53, "\u{1b}"),
        keyboardEvent(46, "M", .capsLock),
    ]
    case "cached-remap": return [
        keyboardEvent(7, "x"), keyboardEvent(7, "x", [], true),
        keyboardEvent(46, "m"), keyboardEvent(40, "k", .option),
        keyboardEvent(40, "k", .option, true), keyboardEvent(11, "b", .shift),
    ]
    case "construction": return []
    default: preconditionFailure("Unknown workload")
    }
}

@MainActor
private func definition(_ id: String) -> PlayerShortcutDefinition {
    guard let value = PlayerShortcutDefinition.all.first(where: { $0.id == id }) else {
        preconditionFailure("Unknown shortcut definition: \(id)")
    }
    return value
}

@MainActor
private func makeVerificationEvents() -> [NSEvent] {
    let keys: [(UInt16, String, String)] = [
        (5, "g", "g"), (0, "a", "a"), (11, "b", "b"), (1, "s", "s"),
        (3, "f", "f"), (34, "i", "i"), (46, "m", "m"), (7, "x", "x"),
        (40, "k", "k"), (27, "?", "/"), (27, "?", "ß"),
        (49, " ", " "), (123, "\u{f702}", "\u{f702}"),
        (124, "\u{f703}", "\u{f703}"), (125, "\u{f701}", "\u{f701}"),
        (126, "\u{f700}", "\u{f700}"), (116, "\u{f72c}", "\u{f72c}"),
        (121, "\u{f72d}", "\u{f72d}"), (51, "\u{7f}", "\u{7f}"),
        (53, "\u{1b}", "\u{1b}"), (46, "M", "M"), (46, "ь", "ь"),
        (7, "é", "é"), (7, "e\u{301}", "e\u{301}"), (7, "猫", "猫"),
        (7, "👩‍💻", "👩‍💻"), (7, "", ""), (7, "+", "+"),
        (7, "_", "_"), (7, "i", "x"), (7, "x", "i"),
        (7, "LEFT", "LEFT"), (124, "x", "x"), (49, "x", "x"),
    ]
    let flagBits: [NSEvent.ModifierFlags] = [
        .shift, .option, .control, .command, .capsLock, .function, .numericPad, .help,
    ]
    var result: [NSEvent] = []
    result.reserveCapacity(keys.count * 256 * 2)
    for (code, characters, ignoring) in keys {
        for mask in 0..<256 {
            var flags: NSEvent.ModifierFlags = []
            for (bit, flag) in flagBits.enumerated() where mask & (1 << bit) != 0 {
                flags.insert(flag)
            }
            for isRepeat in [false, true] {
                result.append(keyboardEvent(code, characters, flags, isRepeat, ignoring: ignoring))
            }
        }
    }
    return result
}

@MainActor
private func verify(defaults: UserDefaults) -> [String: Any] {
    let storageKey = "player.shortcut-overrides.v1"
    let allEvents = makeVerificationEvents()
    var receipts: [[String: Any]] = []
    var operationReceipt: [String] = []
    var bindings = PlayerShortcutBindings(defaults: defaults)

    func record(_ label: String) {
        var digest = ReceiptDigest()
        var keys: [String: String] = [:]
        var menus: [String: Any] = [:]
        for item in PlayerShortcutDefinition.all {
            keys[item.id] = bindings.key(for: item)
            digest.append(item.id)
            digest.append(bindings.key(for: item))
            if let menu = bindings.menuShortcut(for: item.action) {
                let character = String(menu.key.character)
                let hasShift = menu.modifiers.contains(.shift)
                let hasOption = menu.modifiers.contains(.option)
                menus[item.id] = ["key": character, "shift": hasShift, "option": hasOption]
                digest.append(character)
                digest.append(hasShift ? 1 : 0)
                digest.append(hasOption ? 1 : 0)
            } else {
                menus[item.id] = NSNull()
                digest.append("no-menu")
            }
        }
        var actionCodes: [Int64] = []
        actionCodes.reserveCapacity(allEvents.count)
        for event in allEvents {
            let code = actionCode(bindings.resolve(event))
            actionCodes.append(code)
            digest.append(code)
        }
        receipts.append(["state": label, "event_count": allEvents.count,
                         "digest": digest.hexadecimal, "keys": keys,
                         "menus": menus, "action_codes": actionCodes])
    }

    func assign(_ key: String, to id: String) {
        let message = bindings.set(key, for: definition(id))
        operationReceipt.append("\(id):\(key):\(message ?? "accepted")")
    }

    record("defaults")
    assign("  X  ", to: "mute")
    assign("M", to: "screenshot")
    assign(" oPtIoN + K ", to: "loop-clear")
    record("accepted-remaps")

    for invalid in ["F", "Shift+Shift+K", "Command+Q", "Control+K", "", "\n", "Alt++K"] {
        assign(invalid, to: "mute")
    }
    record("rejected-remaps")
    bindings = PlayerShortcutBindings(defaults: defaults)
    record("reloaded-remaps")

    // The original object has no UserDefaults subscription. External writes
    // affect a newly created object and must not silently invalidate one cache.
    defaults.set(["mute": "É", "loop-a": "猫", "help": "K"], forKey: storageKey)
    record("external-write-existing-instance")
    bindings = PlayerShortcutBindings(defaults: defaults)
    record("external-write-new-instance")
    assign("?", to: "loop-a")
    record("question-precedence")

    bindings.reset()
    record("reset")
    defaults.set([
        "mute": "F", "fullscreen": "I", "inspector": "M", // valid cycle
        "screenshot": "Shift+B", "loop-clear": "s", // valid swap
        "time": "Command+Q", "loop-a": "Shift+Shift+A", // rejected syntax
        "help": "G", // conflicts with the restored time default
    ], forKey: storageKey)
    bindings = PlayerShortcutBindings(defaults: defaults)
    record("restored-cycles-and-invalid-overrides")

    defaults.set(["screenshot": "F", "fullscreen": "I", "mute": "X"], forKey: storageKey)
    bindings = PlayerShortcutBindings(defaults: defaults)
    record("restored-conflict-chain")

    return ["schema_version": 1, "mode": "verify", "states": receipts,
            "operations": operationReceipt,
            "event_comparisons": allEvents.count * receipts.count]
}

@main
private struct ShortcutDispatchHarness {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else { fail("Expected list, verify, or benchmark") }
        if mode == "list" {
            emit(["schema_version": 1, "workloads": workloadNames])
            return
        }

        let suite = "com.illiquid.benchmark.shortcuts." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { fail("Cannot create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }

        if mode == "verify" {
            emit(verify(defaults: defaults))
            return
        }

        guard mode == "benchmark", arguments.count == 3,
              workloadNames.contains(arguments[1]),
              let iterations = Int(arguments[2]), iterations > 0,
              iterations <= Int.max / 8 else { fail("Expected benchmark <workload> <positive iterations>") }
        let name = arguments[1]
        let bindings = PlayerShortcutBindings(defaults: defaults)
        if name == "cached-remap" {
            precondition(bindings.set("X", for: definition("mute")) == nil)
            precondition(bindings.set("Option+K", for: definition("loop-clear")) == nil)
        }
        let inputs = events(for: name)
        let isConstruction = name == "construction"
        if isConstruction {
            _ = constructionBatch(defaults, iterations: 3)
        } else {
            _ = dispatchBatch(bindings, events: inputs, iterations: 50)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = isConstruction
            ? constructionBatch(defaults, iterations: iterations)
            : dispatchBatch(bindings, events: inputs, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        emit(["schema_version": 1, "mode": "benchmark", "workload": name,
              "elapsed_ns": elapsed, "operations": iterations * (isConstruction ? 1 : inputs.count),
              "checksum": checksum])
    }

    private static func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
