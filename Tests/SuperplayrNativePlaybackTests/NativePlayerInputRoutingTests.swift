import AppKit
import AVFoundation
import SuperplayrPlayback
import Testing
@testable import SuperplayrNativePlayback

@Suite("Native player input routing")
struct NativePlayerInputRoutingTests {
    @Test @MainActor
    func pointerTrackingRemainsActiveWhenWindowIsNotKey() {
        #expect(NativePlayerNSView.pointerTrackingOptions.contains(.activeAlways))
        #expect(!NativePlayerNSView.pointerTrackingOptions.contains(.activeInKeyWindow))
    }

    @Test @MainActor
    func mouseMovementReportsItsWindowLocation() throws {
        let view = makeView()
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 48, y: 72),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseMoved(with: event)

        #expect(interactions == [.pointerMoved(CGPoint(x: 48, y: 72))])
    }

    @Test @MainActor
    func mouseExitReportsItsWindowLocation() throws {
        let view = makeView()
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseExited,
            location: CGPoint(x: -1, y: 72),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 1,
            userData: nil
        ))

        view.mouseExited(with: event)

        #expect(interactions == [.pointerExited(CGPoint(x: -1, y: 72))])
    }

    @Test @MainActor
    func spaceEmitsPlaybackToggleWithoutGenericActivity() throws {
        let view = makeView()
        var interactions: [PlaybackSurfaceInteraction] = []
        var activityCount = 0
        view.onInteraction = { interactions.append($0) }
        view.onUserActivity = { activityCount += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        view.keyDown(with: event)

        #expect(interactions == [.togglePause])
        #expect(activityCount == 0)
    }

    @Test @MainActor
    func arrowsEmitRelativeSeekCommands() throws {
        let view = makeView()
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }

        for (keyCode, modifiers) in [
            (UInt16(123), NSEvent.ModifierFlags()),
            (UInt16(124), NSEvent.ModifierFlags()),
            (UInt16(123), NSEvent.ModifierFlags.shift),
            (UInt16(124), NSEvent.ModifierFlags.shift),
        ] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ))
            view.keyDown(with: event)
        }

        #expect(interactions == [
            .seekRelative(-5),
            .seekRelative(5),
            .seekRelative(-1),
            .seekRelative(1),
        ])
    }

    @MainActor
    private func makeView() -> NativePlayerNSView {
        let view = NativePlayerNSView(
            videoLayer: AVSampleBufferDisplayLayer(),
            subtitleOverlay: SubtitleOverlayView(),
            rotationDegrees: 0
        )
        view.isVoiceOverEnabled = { false }
        return view
    }

    @Test @MainActor
    func voiceOverForwardedKeysDoNotControlPlayback() throws {
        let view = makeView()
        view.isVoiceOverEnabled = { true }
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        for code: UInt16 in [49, 123, 124] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        #expect(interactions.isEmpty)
    }
}
