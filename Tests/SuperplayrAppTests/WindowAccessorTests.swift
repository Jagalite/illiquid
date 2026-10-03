import AppKit
import Testing
@testable import SuperplayrApp

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
}
