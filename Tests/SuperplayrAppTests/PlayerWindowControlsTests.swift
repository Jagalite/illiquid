import AppKit
import Testing
@testable import SuperplayrApp

@Suite("Player window controls", .serialized)
@MainActor
struct PlayerWindowControlsTests {
    @Test func lockedExpansionPreservesVideoProportionsAndRestoresFrame() throws {
        let window = WindowActionRecorder()
        defer { window.close() }
        let screen = try #require(window.screen)
        window.contentAspectRatio = NSSize(width: 16.0 / 9.0, height: 1)
        let original = NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY + 17,
                              width: screen.visibleFrame.width, height: screen.visibleFrame.width * 9 / 16)
        window.setFrame(original, display: false)
        let bar = try #require(window.standardWindowButton(.zoomButton)?.superview)
        let rect = bar.convert(bar.bounds, to: nil)
        let event = try mouseEvent(window, at: NSPoint(x: rect.midX, y: rect.midY))
        let passiveTitle = NSView(frame: bar.bounds)
        bar.addSubview(passiveTitle)
        #expect(PlayerWindowControls.handleTitlebarDoubleClick(event, in: window, accessory: passiveTitle))
        let expanded = window.contentRect(forFrameRect: window.frame)
        #expect(abs(expanded.width / expanded.height - 16.0 / 9.0) < 0.0001)
        #expect(window.frame.width <= screen.visibleFrame.width + 0.001)
        #expect(window.frame.height <= screen.visibleFrame.height + 0.001)
        #expect(window.frame.width == screen.visibleFrame.width
            || window.frame.height == screen.visibleFrame.height)
        #expect(window.contentAspectRatio == NSSize(width: 16.0 / 9.0, height: 1))
        #expect(window.zoomRequests == 0)
        #expect(window.fullscreenRequests == 0)
        let expandedBar = bar.convert(bar.bounds, to: nil)
        let second = try mouseEvent(window, at: NSPoint(x: expandedBar.midX, y: expandedBar.midY))
        #expect(PlayerWindowControls.handleTitlebarDoubleClick(second, in: window, accessory: passiveTitle))
        #expect(window.frame == original)
        #expect(window.animatedResizeRequests == [true, true]
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @Test func manualResizeBecomesTheNextRestoreFrame() throws {
        let window = WindowActionRecorder()
        defer { window.close() }
        let desktop = try #require(window.screen).visibleFrame
        PlayerWindowControls.toggleDesktopFill(window)
        let resized = NSRect(x: desktop.minX + 30, y: desktop.minY + 30, width: 800, height: 600)
        window.setFrame(resized, display: false)
        PlayerWindowControls.toggleDesktopFill(window)
        #expect(window.frame == desktop)
        PlayerWindowControls.toggleDesktopFill(window)
        #expect(window.frame == resized)
    }

    @Test func titlebarRoutingPreservesControlsVideoAndSingleClicks() throws {
        let window = WindowActionRecorder()
        defer { window.close() }
        let bar = try #require(window.standardWindowButton(.zoomButton)?.superview)
        let rect = bar.convert(bar.bounds, to: nil)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(type))
            let frame = button.convert(button.bounds, to: nil)
            #expect(!PlayerWindowControls.handleTitlebarDoubleClick(
                try mouseEvent(window, at: NSPoint(x: frame.midX, y: frame.midY)),
                in: window, accessory: nil))
        }
        let accessory = NSView(frame: bar.bounds)
        bar.addSubview(accessory)
        accessory.addSubview(TitlebarInteractiveRegionView(frame: accessory.bounds))
        #expect(!PlayerWindowControls.handleTitlebarDoubleClick(
            try mouseEvent(window, at: point), in: window, accessory: accessory))
        #expect(!PlayerWindowControls.handleTitlebarDoubleClick(
            try mouseEvent(window, at: point, count: 1), in: window, accessory: nil))
        #expect(!PlayerWindowControls.handleTitlebarDoubleClick(
            try mouseEvent(window, at: NSPoint(x: 400, y: 100)), in: window, accessory: nil))
        #expect(window.zoomRequests == 0)
        #expect(window.fullscreenRequests == 0)
    }

    private func mouseEvent(_ window: NSWindow, at point: NSPoint, count: Int = 2) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }

    @Test func greenTrafficLightEntersFullscreenInsteadOfZooming() throws {
        let window = WindowActionRecorder()
        defer { window.close() }
        PlayerWindowControls.configure(window)
        let green = try #require(window.standardWindowButton(.zoomButton))
        green.performClick(nil)
        #expect(window.fullscreenRequests == 1)
        #expect(window.zoomRequests == 0)
    }

    @Test func zoomRemainsSeparateFromFullscreen() {
        let window = WindowActionRecorder()
        defer { window.close() }
        PlayerWindowControls.configure(window)
        window.performZoom(nil)
        #expect(window.zoomRequests == 1)
        #expect(window.fullscreenRequests == 0)
    }

    @Test func inheritedFullscreenExclusionIsRemovedWithoutChangingOtherBehaviors() {
        let window = WindowActionRecorder()
        defer { window.close() }
        window.collectionBehavior = [.primary, .fullScreenNone, .fullScreenDisallowsTiling]
        PlayerWindowControls.configure(window)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.primary))
        #expect(window.collectionBehavior.contains(.fullScreenDisallowsTiling))
        #expect(window.areCursorRectsEnabled)
    }
}

@MainActor
private final class WindowActionRecorder: NSWindow {
    var fullscreenRequests = 0
    var zoomRequests = 0
    var animatedResizeRequests: [Bool] = []

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func toggleFullScreen(_ sender: Any?) { fullscreenRequests += 1 }
    override func zoom(_ sender: Any?) { zoomRequests += 1 }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        animatedResizeRequests.append(animateFlag)
        super.setFrame(frameRect, display: flag, animate: false)
    }
}
