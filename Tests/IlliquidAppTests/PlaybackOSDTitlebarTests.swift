import AppKit
import SwiftUI
import Testing
@testable import IlliquidApp

@Suite("Titlebar notification layout")
@MainActor
struct PlaybackOSDTitlebarTests {
    @Test func shortPillsUseTheirContentWidth() {
        let size = pillSize(for: .volume(value: 50, isMuted: false))
        #expect(size.width > 40)
        #expect(size.width < 200)
        #expect(size.height <= 28)
    }

    @Test func longMessagesFitTheTitlebarWithoutGrowingVertically() {
        let size = pillSize(for: .status(String(repeating: "A long playback message ", count: 20)))
        #expect(size.width <= 280)
        #expect(size.height <= 28)
    }

    private func pillSize(for item: PlaybackOSDItem) -> NSSize {
        let presenter = PlaybackOSDPresenter()
        presenter.present(item)
        defer { presenter.invalidate() }
        let host = NSHostingView(rootView:
            PlaybackOSDView(presenter: presenter, showHistory: {}, isTitlebar: true)
                .fixedSize(horizontal: true, vertical: false)
        )
        return host.fittingSize
    }
}
