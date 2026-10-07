import Foundation
import Observation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Video tab observation") @MainActor
struct OpenVideoTabStoreTests {
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Observable @MainActor final class LegacyTabs {
        var value = OpenVideoTabs()
    }

    @Test func playbackTicksRetainResumeStateWithoutInvalidatingTabChrome() {
        let source = MediaSource.localFile(URL(fileURLWithPath: "/tmp/tab-a.mkv"))
        let folder = URL(fileURLWithPath: "/tmp")
        let playlist = [FolderPlaylistItem(url: source.url)]
        let store = OpenVideoTabStore(), legacy = LegacyTabs()
        let id = store.add(source)
        store.select(id)
        let legacyID = legacy.value.add(source)
        legacy.value.select(legacyID)
        let currentChanges = Changes(), legacyChanges = Changes()
        withObservationTracking {
            _ = store.items
            _ = store.selectedID
        } onChange: { currentChanges.increment() }
        for tick in 0..<1_000 {
            // Re-arm the old title-bar dependency as SwiftUI would after each
            // invalidation. The new dependency remains armed the whole time.
            withObservationTracking {
                _ = legacy.value.items
                _ = legacy.value.selectedID
            } onChange: { legacyChanges.increment() }
            let position = Double(tick) / 4
            legacy.value.record(source: source, position: position, wasPaused: true,
                                playlist: playlist, folder: folder)
            store.record(source: source, position: position, wasPaused: true,
                         playlist: playlist, folder: folder)
        }
        #expect(legacyChanges.count == 1_000)
        #expect(currentChanges.count == 0)
        #expect(store.tab(id: id)?.position == 249.75)
        #expect(store.tab(id: id)?.wasPaused == true)
        #expect(store.tab(id: id)?.playlist == playlist)
        #expect(store.tab(id: id)?.folder == folder)
        print("TAB_OBSERVATION ticks=1000 previous_invalidations=\(legacyChanges.count) current_invalidations=\(currentChanges.count)")
    }

    @Test func membershipAndSelectionPublishWhileNoOpsStayQuiet() {
        let store = OpenVideoTabStore()
        let first = MediaSource.localFile(URL(fileURLWithPath: "/tmp/a.mkv"))
        let second = MediaSource.localFile(URL(fileURLWithPath: "/tmp/b.mkv"))
        let firstID = store.add(first)
        store.select(firstID)
        let noOps = Changes()
        withObservationTracking { _ = store.items; _ = store.selectedID }
            onChange: { noOps.increment() }
        #expect(store.add(first) == firstID)
        store.select(firstID)
        store.select(UUID())
        store.close(UUID())
        #expect(noOps.count == 0)
        let secondID = store.add(second)
        #expect(noOps.count == 1)
        let selection = Changes()
        withObservationTracking { _ = store.selectedID }
            onChange: { selection.increment() }
        store.select(secondID)
        #expect(selection.count == 1)
        store.record(source: first, position: 12, wasPaused: true, playlist: [], folder: nil)
        #expect(store.close(secondID)?.position == 12)
        #expect(store.selectedID == firstID)
        #expect(store.items.map(\.id) == [firstID])
        store.close(firstID)
        #expect(store.items.isEmpty && store.selectedID == nil)
    }
}
