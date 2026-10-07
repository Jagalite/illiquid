import Foundation
import Testing
@testable import IlliquidCore

@Suite("Open video tabs")
struct OpenVideoTabsTests {
    private func source(_ name: String) -> MediaSource { .localFile(URL(fileURLWithPath: "/tmp/" + name + ".mkv")) }

    @Test func reopeningSameVideoKeepsItsIdentityAndPosition() {
        var tabs = OpenVideoTabs()
        let a = source("a")
        let id = tabs.add(a)
        _ = tabs.select(id)
        tabs.record(source: a, position: 42.5, wasPaused: true, playlist: [], folder: nil)
        #expect(tabs.add(a) == id)
        #expect(tabs.items.count == 1)
        #expect(tabs.selected?.position == 42.5)
        #expect(tabs.selected?.wasPaused == true)
    }

    @Test func switchingRetainsIndependentPositionAndPlaylistContext() {
        var tabs = OpenVideoTabs()
        let a = source("a"), b = source("b")
        let aid = tabs.add(a), bid = tabs.add(b)
        let playlist = [FolderPlaylistItem(url: a.url), FolderPlaylistItem(url: b.url)]
        tabs.record(source: a, position: 12, wasPaused: true, playlist: playlist, folder: URL(fileURLWithPath: "/tmp"))
        tabs.record(source: b, position: 80, wasPaused: false, playlist: [], folder: nil)
        #expect(tabs.select(aid)?.position == 12)
        #expect(tabs.selected?.playlist == playlist)
        #expect(tabs.select(bid)?.position == 80)
        #expect(tabs.selected?.wasPaused == false)
        #expect(tabs.select(aid)?.wasPaused == true)
    }

    @Test func closingBackgroundTabDoesNotChangeSelection() {
        var tabs = OpenVideoTabs()
        let a = tabs.add(source("a")), b = tabs.add(source("b"))
        _ = tabs.select(a)
        #expect(tabs.close(b)?.id == a)
        #expect(tabs.selectedID == a)
    }

    @Test func closingActiveTabChoosesNeighborAndLastCloseEmptiesSelection() {
        var tabs = OpenVideoTabs()
        let a = tabs.add(source("a")), b = tabs.add(source("b")), c = tabs.add(source("c"))
        _ = tabs.select(b)
        #expect(tabs.close(b)?.id == c)
        #expect(tabs.close(c)?.id == a)
        #expect(tabs.close(a) == nil)
        #expect(tabs.items.isEmpty && tabs.selectedID == nil)
        #expect(tabs.adjacentID(1) == nil)
    }

    @Test func keyboardNavigationWrapsAndInvalidSelectionIsIgnored() {
        var tabs = OpenVideoTabs()
        let a = tabs.add(source("a")), b = tabs.add(source("b"))
        _ = tabs.select(a)
        #expect(tabs.adjacentID(-1) == b)
        _ = tabs.select(b)
        #expect(tabs.adjacentID(1) == a)
        #expect(tabs.select(UUID()) == nil)
        #expect(tabs.selectedID == b)
    }
}
