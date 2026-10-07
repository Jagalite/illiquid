import Foundation
import Testing
@testable import IlliquidCore

@Suite("Folder playlist")
struct FolderPlaylistTests {
    @Test("Initial index restores the last file or falls back to first")
    func initialIndexRestoresLastFileOrFallsBackToFirst() {
        let folder = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
        let first = folder.appendingPathComponent("Episode 1.mkv")
        let second = folder.appendingPathComponent("Episode 2.mkv")
        let playlist = FolderPlaylist(
            folderURL: folder,
            items: [FolderPlaylistItem(url: second), FolderPlaylistItem(url: first)]
        )

        #expect(playlist.initialIndex(restoring: second) == 1)
        #expect(playlist.initialIndex(restoring: folder.appendingPathComponent("Missing.mkv")) == 0)
        #expect(playlist.initialIndex(restoring: nil) == 0)
    }

    @Test("Initial index is nil for an empty playlist")
    func initialIndexIsNilForEmptyPlaylist() {
        let playlist = FolderPlaylist(
            folderURL: URL(fileURLWithPath: "/tmp/Empty", isDirectory: true),
            items: []
        )
        #expect(playlist.initialIndex(restoring: nil) == nil)
    }

    @Test("Next and previous stop at playlist boundaries")
    func nextAndPreviousStopAtPlaylistBoundaries() {
        let folder = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
        let playlist = FolderPlaylist(
            folderURL: folder,
            items: [
                FolderPlaylistItem(url: folder.appendingPathComponent("Episode 1.mkv")),
                FolderPlaylistItem(url: folder.appendingPathComponent("Episode 2.mkv")),
            ]
        )

        #expect(playlist.nextIndex(after: 0) == 1)
        #expect(playlist.nextIndex(after: 1) == nil)
        #expect(playlist.previousIndex(before: 1) == 0)
        #expect(playlist.previousIndex(before: 0) == nil)
    }
}
