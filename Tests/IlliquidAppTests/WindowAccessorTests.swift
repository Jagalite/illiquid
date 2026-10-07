import AppKit
import Testing
@testable import IlliquidApp

@Suite("Window attachment startup") @MainActor
struct WindowAccessorTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func resolvesAttachmentAfterTheInitialDeferredAttempt() async {
        var resolved: [NSWindow] = []
        let view = WindowResolverView { resolved.append($0) }
        await drainMainQueue()
        #expect(resolved.isEmpty)
        let first = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        first.contentView = view
        await drainMainQueue()
        #expect(resolved.count == 1 && resolved.first === first)
        view.scheduleResolution()
        await drainMainQueue()
        #expect(resolved.count == 1)
        first.contentView = nil
        let second = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        second.contentView = view
        await drainMainQueue()
        #expect(resolved.count == 2 && resolved.last === second)
        second.contentView = nil
        first.close(); second.close()
    }

    @Test func resolvesReusedWindowAfterCloseButNotWhileItRemainsHidden() async {
        var resolutions = 0
        let view = WindowResolverView { _ in resolutions += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        await drainMainQueue()
        #expect(resolutions == 1)

        window.close()
        view.scheduleResolution()
        await drainMainQueue()
        #expect(resolutions == 1)
        #expect(view.window === window)

        window.makeKeyAndOrderFront(nil)
        // Occlusion notifications can arrive on a later run-loop turn.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await drainMainQueue()
        #expect(resolutions == 2)
        view.scheduleResolution()
        await drainMainQueue()
        #expect(resolutions == 2)
    }
}
