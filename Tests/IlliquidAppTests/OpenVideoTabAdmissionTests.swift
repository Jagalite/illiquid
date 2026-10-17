import Foundation
import Observation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Video tab visible admission") @MainActor
struct OpenVideoTabAdmissionTests {
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func local(_ name: String) -> MediaSource {
        .localFile(URL(fileURLWithPath: "/tmp/video-tab-admission/" + name))
    }

    @Test func additionsAndFirstRecordsAppendOrderedItemsWithTheirOriginalTitles() throws {
        let store = OpenVideoTabStore()
        let original = local("Caf\u{00E9} episode.mkv")
        let originalID = store.add(original)
        store.select(originalID)
        var expected = [OpenVideoTabStore.Item(id: originalID, source: original, title: "Caf\u{00E9} episode.mkv")]
        let remote = MediaSource.remoteStream(try #require(URL(string: "https://example.test/watch/Trailer.mp4?token=one#t=3")))
        let remoteID = store.add(remote)
        expected.append(.init(id: remoteID, source: remote, title: "Trailer.mp4"))
        #expect(store.items == expected)
        let heldInitialItems = store.items

        for index in 0..<32 {
            let name = "Episode \(index).mkv"
            let source = local(name)
            let prefix = store.items
            let id: UUID
            if index.isMultiple(of: 2) {
                id = store.add(source)
            } else {
                store.record(source: source, position: Double(index), wasPaused: true, playlist: [], folder: nil)
                id = try #require(store.items.last?.id)
                #expect(store.tab(id: id)?.position == Double(index))
                #expect(store.tab(id: id)?.wasPaused == true)
            }
            expected.append(.init(id: id, source: source, title: name))
            #expect(Array(store.items.dropLast()) == prefix)
            #expect(store.items == expected)
            #expect(store.selectedID == originalID)
        }

        let alias = local("nested/../Caf\u{0065}\u{0301} episode.mkv")
        let folder = URL(fileURLWithPath: "/tmp/video-tab-admission/", isDirectory: true)
        let playlist = [FolderPlaylistItem(url: alias.url), FolderPlaylistItem(url: remote.url)]
        #expect(store.add(alias) == originalID)
        store.record(source: alias, position: 17.5, wasPaused: true, playlist: playlist, folder: folder)
        #expect(store.items == expected)
        #expect(store.tab(id: originalID)?.source == original)
        #expect(store.tab(id: originalID)?.source.url.absoluteString == original.url.absoluteString)
        #expect(store.tab(id: originalID)?.playlist == playlist)
        #expect(store.tab(id: originalID)?.folder == folder)
        #expect(store.selected?.position == 17.5)
        store.close(remoteID)
        #expect(heldInitialItems.map(\.id) == [originalID, remoteID])
        #expect(heldInitialItems.map(\.source) == [original, remote])
        #expect(heldInitialItems.map(\.title) == ["Caf\u{00E9} episode.mkv", "Trailer.mp4"])
        #expect(store.items.map(\.id) == expected.map(\.id).filter { $0 != remoteID })
    }

    @Test func equivalentAdmissionsStayQuietAndEachNewMemberPublishes() throws {
        let store = OpenVideoTabStore()
        let original = local("Caf\u{00E9}.mkv")
        let alias = local("nested/../Caf\u{0065}\u{0301}.mkv")
        let id = store.add(original)
        store.select(id)
        let membership = Changes(), selection = Changes()
        withObservationTracking { _ = store.items } onChange: { membership.increment() }
        withObservationTracking { _ = store.selectedID } onChange: { selection.increment() }
        #expect(store.add(alias) == id)
        store.record(source: alias, position: 15, wasPaused: false, playlist: [], folder: nil)
        store.select(id)
        store.close(UUID())
        #expect(membership.count == 0)
        #expect(selection.count == 0)
        #expect(store.items.count == 1)

        let second = local("second.mkv")
        store.record(source: second, position: 22, wasPaused: true, playlist: [], folder: nil)
        #expect(membership.count == 1)
        #expect(selection.count == 0)
        let secondID = try #require(store.items.last?.id)
        #expect(store.tab(id: secondID)?.position == 22)
        #expect(store.items.map(\.source) == [original, second])

        for index in 0..<8 {
            let changes = Changes()
            withObservationTracking { _ = store.items } onChange: { changes.increment() }
            let next = local("new-\(index).mkv")
            let nextID = store.add(next)
            #expect(changes.count == 1)
            let duplicates = Changes()
            withObservationTracking { _ = store.items } onChange: { duplicates.increment() }
            #expect(store.add(next) == nextID)
            store.record(source: next, position: 1, wasPaused: true, playlist: [], folder: nil)
            #expect(duplicates.count == 0)
            #expect(selection.count == 0)
        }
    }

    @Test func closingThenReadmittingMaintainsVisibleOrderAndIndependentResumeData() throws {
        let store = OpenVideoTabStore()
        let sources = [local("first.mkv"), local("second.mkv"), local("third.mkv")]
        let ids = sources.map { store.add($0) }
        store.select(ids[0])
        store.record(source: sources[2], position: 42, wasPaused: true, playlist: [], folder: nil)
        let original = store.items
        store.close(ids[1])
        #expect(store.items == [original[0], original[2]])
        #expect(store.selectedID == ids[0])
        #expect(store.add(sources[0]) == ids[0])
        #expect(store.add(sources[2]) == ids[2])

        let alias = local("nested/../second.mkv")
        store.record(source: alias, position: 8, wasPaused: false, playlist: [], folder: nil)
        let replacement = try #require(store.items.last)
        #expect(replacement.id != ids[1])
        #expect(replacement.source == alias)
        #expect(replacement.title == "second.mkv")
        #expect(store.items == [original[0], original[2], replacement])
        #expect(store.tab(id: ids[1]) == nil)
        #expect(store.tab(id: ids[2])?.position == 42)
        #expect(store.tab(id: replacement.id)?.position == 8)

        store.close(ids[0])
        #expect(store.selectedID == ids[2])
        #expect(store.selected?.position == 42)
        store.close(ids[2])
        #expect(store.selectedID == replacement.id)
        store.close(replacement.id)
        #expect(store.items.isEmpty && store.selectedID == nil)
        let reopened = store.add(sources[1])
        #expect(reopened != replacement.id && reopened != ids[1])
        #expect(store.items.map(\.source) == [sources[1]])
        #expect(store.tab(id: reopened)?.position == 0)
    }

    @Test func invalidLocalAndRemoteFileAdmissionsPublishDistinctItems() throws {
        let store = OpenVideoTabStore()
        let remoteURL = try #require(URL(string: "https://example.test/clip.mkv"))
        let file = local("clip.mkv")
        let sources: [MediaSource] = [
            .remoteStream(remoteURL), .localFile(remoteURL), .localFile(remoteURL),
            file, .remoteStream(file.url),
        ]
        let ids = sources.map { store.add($0) }
        #expect(Set(ids).count == sources.count)
        #expect(store.items.map(\.source) == sources)
        #expect(store.items.map(\.title) == Array(repeating: "clip.mkv", count: sources.count))
        store.close(ids[1])
        #expect(store.add(sources[0]) == ids[0])
        #expect(store.add(file) == ids[3])
        #expect(store.add(sources[4]) == ids[4])
        #expect(store.items.map(\.id) == [ids[0], ids[2], ids[3], ids[4]])
    }
}
