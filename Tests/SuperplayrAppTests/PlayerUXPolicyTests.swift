import AppKit
import Foundation
import Testing
@testable import SuperplayrApp

@Suite("UX ownership and lifecycle policies")
struct PlayerUXPolicyTests {
    @Test func invalidatedOSDStartsFreshSeekSequence() {
        var machine = PlaybackOSDStateMachine()
        machine.present(.seek(delta: 5, target: 15), at: 10)
        machine.invalidate()
        machine.present(.seek(delta: -5, target: 10), at: 10.1)
        #expect(machine.item == .seek(delta: -5, target: 10))
        #expect(machine.deadline == 11.1)
    }

    @Test func lateTimerCannotCoalesceAnExpiredSeek() {
        var machine = PlaybackOSDStateMachine()
        machine.present(.seek(delta: 5, target: 15), at: 10)
        machine.present(.seek(delta: 5, target: 20), at: 12)
        #expect(machine.item == .seek(delta: 5, target: 20))
        machine.deadlineReached(at: 99)
        #expect(machine.item == nil)
        #expect(machine.deadline == nil)
    }

    @Test @MainActor func presenterInvalidationRetainsHistoryWithoutReplacingOldMessage() {
        let presenter = PlaybackOSDPresenter()
        presenter.present(.seek(delta: 5, target: 15))
        presenter.invalidate()
        presenter.present(.seek(delta: 5, target: 20))
        #expect(presenter.messages.count == 2)
        #expect(presenter.messages[0].item == .seek(delta: 5, target: 15))
        #expect(presenter.item == .seek(delta: 5, target: 20))
        presenter.invalidate()
    }

    @Test func keyboardCanRevealControlsWhilePointerIsOutside() {
        var chrome = PlaybackChromeStateMachine()
        chrome.hideForPointerExit(reducedMotion: true, now: 0)
        chrome.revealForKeyboardNavigation(at: 1)
        #expect(chrome.phase.isMounted)
        chrome.setPin(.playbackFocus, active: true, now: 1.1)
        chrome.deadlineReached(at: 10, reducedMotion: true)
        #expect(chrome.phase == .pinned)
    }

    @Test func focusSurvivesPointerExitAndPlayHiding() {
        var chrome = PlaybackChromeStateMachine()
        chrome.setPin(.playbackFocus, active: true, now: 0)
        chrome.hideForPointerExit(reducedMotion: true, now: 10)
        chrome.hideImmediatelyForKeyboardPlay()
        #expect(chrome.phase == .pinned)
        chrome.setPin(.playbackFocus, active: false, now: 11)
        #expect(chrome.phase == .hidden)
    }

    @Test func alwaysVisibleDoesNotOverrideOtherOwnersWhenDisabled() {
        var chrome = PlaybackChromeStateMachine()
        chrome.setPin(.alwaysVisible, active: true, now: 0)
        chrome.setPin(.scrubbing, active: true, now: 0)
        chrome.setPin(.alwaysVisible, active: false, now: 20)
        chrome.deadlineReached(at: 100, reducedMotion: true)
        #expect(chrome.phase == .pinned)
        chrome.setPin(.scrubbing, active: false, now: 101)
        #expect(chrome.deadline == .autoHide(103.5))
    }

    @Test func scrubReleaseOutsideCommitsLastPreviewAndEscapeRestoresOrigin() {
        var gesture = TimelineGestureTransaction(sourceRevision: 7, origin: 12, duration: 100)
        #expect(gesture.preview(fraction: 0.4, currentRevision: 7) == 40)
        #expect(gesture.finish(currentRevision: 7, cancelled: false) == 40)
        #expect(gesture.finish(currentRevision: 7, cancelled: true) == 12)
    }

    @Test func sameURLReloadCannotReceiveStalePreviewOrRelease() {
        var gesture = TimelineGestureTransaction(sourceRevision: 7, origin: 12, duration: 100)
        _ = gesture.preview(fraction: 0.4, currentRevision: 7)
        #expect(gesture.preview(fraction: 0.8, currentRevision: 8) == nil)
        #expect(gesture.finish(currentRevision: 8, cancelled: false) == nil)
        #expect(gesture.finish(currentRevision: 8, cancelled: true) == nil)
    }

    @Test func sourceReplacementBetweenStationaryPressAndReleaseRejectsTap() {
        var gesture = TimelineGestureTransaction(sourceRevision: 7, origin: 12, duration: 100)
        #expect(gesture.preview(fraction: 0.5, currentRevision: 8) == nil)
        #expect(gesture.finish(currentRevision: 8, cancelled: false) == nil)
    }

    @Test func untouchedOrInvalidScrubDoesNotSeekOnCancel() {
        var gesture = TimelineGestureTransaction(sourceRevision: 7, origin: 12, duration: 0)
        #expect(gesture.preview(fraction: 0.4, currentRevision: 7) == nil)
        #expect(gesture.finish(currentRevision: 7, cancelled: true) == nil)
    }

    @Test func restoredWindowFitsAfterMonitorRemoval() throws {
        let screen = CGRect(x: 0, y: 50, width: 1200, height: 750)
        let restored = try #require(PlayerWindowGeometry.restoredFrame(
            CGRect(x: 1198, y: -300, width: 1800, height: 900), screens: [screen]))
        #expect(restored == screen)
        #expect(PlayerWindowGeometry.restoredFrame(CGRect(x: 0, y: 0, width: 800, height: 500), screens: []) == nil)
    }

    @Test func restoredWindowPreservesUsablePlacement() {
        let original = CGRect(x: -1000, y: 100, width: 900, height: 600)
        let screens = [CGRect(x: -1400, y: 0, width: 1400, height: 900), CGRect(x: 0, y: 0, width: 1200, height: 800)]
        #expect(PlayerWindowGeometry.restoredFrame(original, screens: screens) == original)
    }
}
