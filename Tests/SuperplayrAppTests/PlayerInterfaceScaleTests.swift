import AppKit
import SwiftUI
import Testing
@testable import SuperplayrApp

@Suite("Interface scale", .serialized)
@MainActor
struct PlayerInterfaceScaleTests {
    @Test func preferenceSurvivesRelaunchAndReset() {
        let name = "InterfaceScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PlayerInterfaceScaleStore(defaults: defaults)
        #expect(store.percentage == 100)
        store.increase()
        #expect(PlayerInterfaceScaleStore(defaults: defaults).percentage == 110)
        store.decrease()
        store.decrease()
        #expect(PlayerInterfaceScaleStore(defaults: defaults).percentage == 90)
        store.reset()
        #expect(PlayerInterfaceScaleStore(defaults: defaults).percentage == 100)
    }

    @Test func repeatedShortcutsStopAtBoundsAndInvalidPreferencesRecover() {
        let name = "InterfaceScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(999, forKey: PlayerInterfaceScaleStore.storageKey)
        let store = PlayerInterfaceScaleStore(defaults: defaults)
        #expect(store.percentage == 100)
        for _ in 0..<20 { store.increase() }
        #expect(store.percentage == 150)
        #expect(!store.canIncrease && store.canDecrease)
        for _ in 0..<20 { store.decrease() }
        #expect(store.percentage == 80)
        #expect(store.canIncrease && !store.canDecrease)
        store.select(123)
        #expect(store.percentage == 80)
    }

    @Test(arguments: [0.8, 1.0, 1.5])
    func sidebarEdgeTracksPhysicalPointerTravel(factor: Double) {
        let start: CGFloat = 420
        for distance: CGFloat in [-72, 96] {
            let end = SourcesSidebarSizing.resolvedWidth(
                storedWidth: start, dragTranslation: distance,
                maximumWidth: 700, interfaceScale: factor
            )
            #expect(abs((end - start) * factor - distance) < 0.01)
        }
        // A narrower logical viewport can clamp the saved width after zooming.
        // Dragging must start at that visible edge, rather than the old width.
        let visibleStart = SourcesSidebarSizing.settledWidth(storedWidth: 720, maximumWidth: 600)
        let end = SourcesSidebarSizing.resolvedWidth(
            storedWidth: visibleStart, dragTranslation: -60,
            maximumWidth: 600, interfaceScale: factor
        )
        #expect(abs((end - visibleStart) * factor + 60) < 0.01)
    }

    @Test(arguments: [0.8, 1.0, 1.5])
    func scaledContentReservesItsVisibleFootprint(factor: Double) {
        let view = NSHostingView(rootView:
            PlayerInterfaceScaleLayout(factor: factor) {
                Color.red.frame(width: 200, height: 80)
                    .scaleEffect(factor, anchor: .topLeading)
            }
        )
        #expect(abs(view.fittingSize.width - 200 * factor) < 0.01)
        #expect(abs(view.fittingSize.height - 80 * factor) < 0.01)
    }

    @Test(arguments: [0.8, 1.0, 1.5])
    func chromeUsesLogicalViewportWhileVideoKeepsPhysicalViewport(factor: Double) {
        let sizes = ViewportSizes()
        let view = NSHostingView(rootView: ZStack {
            GeometryReader { geometry in
                Color.black.onAppear { sizes.video = geometry.size }
            }
            PlayerInterfaceScaleLayout(factor: factor) {
                GeometryReader { geometry in
                    Color.clear.onAppear { sizes.chrome = geometry.size }
                }
                .scaleEffect(factor, anchor: .topLeading)
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        #expect(sizes.video == CGSize(width: 1200, height: 760))
        // SwiftUI rounds logical proposals to the display's pixel grid.
        #expect(abs(sizes.chrome.width * factor - 1200) <= 0.5)
        #expect(abs(sizes.chrome.height * factor - 760) <= 0.5)
    }
}

@MainActor
private final class ViewportSizes {
    var video = CGSize.zero
    var chrome = CGSize.zero
}
