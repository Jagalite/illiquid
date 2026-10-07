import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist mutation")
struct PlaylistMutationTests {
    @Test func sortingIsStableAndDefinesPlaybackOrder() {
        let older = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode 10.mkv"),
            dateAdded: Date(timeIntervalSince1970: 10)
        )
        let newer = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode 2.mkv"),
            dateAdded: Date(timeIntervalSince1970: 20)
        )

        #expect(PlaylistMutation.sorted(
            [older, newer],
            by: .dateAdded,
            ascending: false
        ).map(\.id) == [newer.id, older.id])
        #expect(PlaylistMutation.sorted(
            [older, newer],
            by: .name,
            ascending: true
        ).map(\.id) == [newer.id, older.id])
    }

    @Test func deduplicationAndReorderingPreserveResourceIdentity() {
        let first = FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/One.mkv"))
        let duplicate = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Season/../One.mkv")
        )
        let second = FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Two.mkv"))
        let items = PlaylistMutation.deduplicated([first, duplicate, second])

        #expect(items.map(\.id) == [first.id, second.id])
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: second.url,
            fallbackIndex: 0,
            in: [second, first]
        ) == 0)
    }
}
