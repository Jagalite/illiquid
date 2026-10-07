import AppKit
import IlliquidCore
import IlliquidPlayback
import Testing
@testable import IlliquidApp

/// Regression probes for the verified UX input and lifecycle contracts.
@Suite("UX verification probes", .serialized)
@MainActor
struct UXVerificationProbeTests {
    @Test func focusedButtonRetainsSpaceInsteadOfTogglingTransport() {
        let button = NSButton(title: "Settings", target: nil, action: nil)
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .togglePause, firstResponder: button,
            isPlaybackChromeVisible: true, isVoiceOverEnabled: false
        ))
    }

    @Test func focusedEditorRetainsInputAcrossChromeVisibilityChange() {
        let editor = NSTextView()
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .togglePause, firstResponder: editor,
            isPlaybackChromeVisible: false, isVoiceOverEnabled: false
        ))
    }

    @Test func cancelledScrollCannotRestartFromLateMomentum() {
        var scroll = SurfaceScrollAccumulator()
        _ = scroll.consume(.init(deltaX: 8, deltaY: 0, isPrecise: true, phase: .began))
        _ = scroll.consume(.init(deltaX: 0, deltaY: 0, isPrecise: true, phase: .cancelled))
        #expect(scroll.consume(.init(
            deltaX: 8, deltaY: 0, isPrecise: true, phase: .momentum
        )) == nil)
    }

    @Test func launchReadinessBoundaryPreservesURLsAndRequestGrouping() {
        let a = URL(fileURLWithPath: "/tmp/ux-a.mkv")
        let b = URL(fileURLWithPath: "/tmp/ux-b.mkv")
        var early = LaunchOpenQueue()
        _ = early.receive(urls: [a])
        _ = early.receive(urls: [b])
        let merged = early.markReady()
        var straddling = LaunchOpenQueue()
        _ = straddling.receive(urls: [a])
        let split = straddling.markReady() + straddling.receive(urls: [b])
        #expect(merged.flatMap(\.urls) == split.flatMap(\.urls))
        #expect(merged == split)
        #expect(split.count == 2)
        print("UX-054 verified: before-ready and straddling-ready preserve the same requests")
    }

    @Test func momentumKeepsItsAxisAfterFingerLiftButCannotOutliveItsOwner() {
        var scroll = SurfaceScrollAccumulator()
        _ = scroll.consume(.init(deltaX: 8, deltaY: 0, isPrecise: true, phase: .began))
        _ = scroll.consume(.init(deltaX: 0, deltaY: 0, isPrecise: true, phase: .ended))
        #expect(scroll.consume(.init(deltaX: 8, deltaY: 20, isPrecise: true,
                                    phase: .momentum)) == .seek(5))
        _ = scroll.consume(.init(deltaX: 0, deltaY: 0, isPrecise: true, phase: .momentumEnded))
        #expect(scroll.consume(.init(deltaX: 8, deltaY: 0, isPrecise: true, phase: .momentum)) == nil)
        _ = scroll.consume(.init(deltaX: 4, deltaY: 0, isPrecise: true, phase: .began))
        scroll.cancel() // Pointer exit, presentation, or source replacement.
        #expect(scroll.consume(.init(deltaX: 4, deltaY: 0, isPrecise: true, phase: .changed)) == nil)
        #expect(scroll.consume(.init(deltaX: 4, deltaY: 0, isPrecise: true, phase: .began)) == nil)
    }

    @Test func longAndUnavailableTimecodesHaveFiniteReadableOutput() {
        #expect(TimecodeFormatter.string(from: 10_801.9) == "3:00:01")
        #expect(TimecodeFormatter.string(from: 359_999) == "99:59:59")
        #expect(TimecodeFormatter.string(from: 0) == "00:00")
        for value in [Double.nan, .infinity, -.infinity, -1] {
            #expect(TimecodeFormatter.string(from: value) == "0:00")
        }
    }

    @Test func printedShortcutSymbolsFollowTheLayoutInsteadOfUSKeyPositions() {
        #expect(PlayerKeyboardAction.resolve(keyCode: 41, characters: "m",
                                             modifierFlags: [], isRepeat: false) == .toggleMute)
        #expect(PlayerKeyboardAction.resolve(keyCode: 46, characters: ",",
                                             modifierFlags: [], isRepeat: false) == nil)
        #expect(PlayerKeyboardAction.resolve(keyCode: 46, characters: "ь",
                                             modifierFlags: [], isRepeat: false) == nil)
        for symbol in ["+", "_"] {
            #expect(PlayerKeyboardAction.resolve(keyCode: 44, characters: symbol,
                                                 modifierFlags: .shift, isRepeat: false) == nil)
        }
        #expect(PlayerKeyboardAction.resolve(keyCode: 27, characters: "?",
                                             modifierFlags: .shift, isRepeat: false) == .showShortcuts)
        #expect(PlayerKeyboardAction.resolve(keyCode: 46, characters: "M",
                                             modifierFlags: .capsLock, isRepeat: false) == .toggleMute)
        #expect(PlayerKeyboardAction.resolve(keyCode: 46, characters: "m",
                                             modifierFlags: .command, isRepeat: false) == nil)
        #expect(PlayerKeyboardAction.resolve(keyCode: 3, characters: "f",
                                             modifierFlags: [], isRepeat: true) == nil)
    }
}
