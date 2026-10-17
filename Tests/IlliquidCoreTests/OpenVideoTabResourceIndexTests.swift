import Foundation
import Testing
@testable import IlliquidCore

@Suite("Open video tab resource admission")
struct OpenVideoTabResourceIndexTests {
    private func local(_ name: String) -> MediaSource {
        .localFile(URL(fileURLWithPath: "/tmp/open-video-tab-tests/" + name))
    }

    private func resourceSamples() throws -> [MediaSource] {
        let fileBase = URL(fileURLWithPath: "/tmp/open-video-tab-tests/", isDirectory: true)
        let remoteBase = try #require(URL(string: "https://example.test/media/"))
        let remote = try #require(URL(string: "clip.mkv?token=one#t=2", relativeTo: remoteBase))
        let invalidLocal = try #require(URL(string: "https://example.test/media/clip.mkv"))
        return [
            local("Caf\u{00E9}.mkv"),
            local("nested/../Caf\u{0065}\u{0301}.mkv"),
            .localFile(try #require(URL(string: "./Caf%C3%A9.mkv", relativeTo: fileBase))),
            local("CAF\u{00C9}.mkv"),
            local("space name.mkv"),
            .localFile(try #require(URL(string: "file:///tmp/open-video-tab-tests/space%20name.mkv"))),
            .remoteStream(remote),
            .remoteStream(try #require(URL(string: "https://example.test/media/clip.mkv?token=one#t=2"))),
            .remoteStream(try #require(URL(string: "https://example.test/media/clip.mkv?token=two#t=2"))),
            .remoteStream(try #require(URL(string: "https://example.test/media/clip.mkv?token=one#t=3"))),
            .remoteStream(try #require(URL(string: "https://example.test/media/%63lip.mkv?token=one#t=2"))),
            .remoteStream(try #require(URL(string: "https://example.test/media/clip.mkv?a=1&b=2"))),
            .remoteStream(try #require(URL(string: "https://example.test/media/clip.mkv?b=2&a=1"))),
            .remoteStream(local("Caf\u{00E9}.mkv").url),
            .remoteStream(invalidLocal),
            // Enum construction permits non-file URLs. These have no local
            // resource identity, including when the same value is re-added.
            .localFile(invalidLocal),
            .localFile(invalidLocal),
        ]
    }

    @Test func admissionMatchesResourceComparisonInBothOrders() throws {
        let samples = try resourceSamples()
        for first in samples {
            for second in samples {
                var tabs = OpenVideoTabs()
                let firstID = tabs.add(first)
                let secondID = tabs.add(second)
                let sameResource = first.representsSameResource(as: second)
                #expect((firstID == secondID) == sameResource)
                #expect(tabs.items.count == (sameResource ? 1 : 2))
                #expect(tabs.items.first?.source == first)
                #expect(tabs.items.last?.source == (sameResource ? first : second))
                #expect(tabs.selectedID == nil)
            }
        }
    }

    @Test func normalizedLocalAndRelativeRemoteAdmissionsRetainOriginalSources() throws {
        let samples = try resourceSamples()
        let original = samples[0]
        var tabs = OpenVideoTabs()
        let originalID = tabs.add(original)
        for alias in samples[1...2] {
            #expect(original.representsSameResource(as: alias))
            #expect(tabs.add(alias) == originalID)
        }
        let relativeRemote = samples[6]
        let absoluteRemote = samples[7]
        #expect(relativeRemote.representsSameResource(as: absoluteRemote))
        let remoteID = tabs.add(relativeRemote)
        #expect(tabs.add(absoluteRemote) == remoteID)
        for distinctRemote in samples[8...10] {
            #expect(!relativeRemote.representsSameResource(as: distinctRemote))
            #expect(tabs.add(distinctRemote) != remoteID)
        }
        #expect(tabs.items.first?.source == original)
        #expect(tabs.items.first?.source.url.absoluteString == original.url.absoluteString)
        #expect(tabs.items[1].source == relativeRemote)
        #expect(tabs.items[1].source.url.relativeString == relativeRemote.url.relativeString)
        #expect(tabs.items[1].source.url.baseURL == relativeRemote.url.baseURL)
    }

    @Test func unidentifiableLocalsAndDifferentSourceKindsRemainIndependent() throws {
        let url = try #require(URL(string: "https://example.test/stream.mkv"))
        let invalidLocal = MediaSource.localFile(url)
        let remote = MediaSource.remoteStream(url)
        let file = local("same.mkv")
        let remoteFile = MediaSource.remoteStream(file.url)
        var tabs = OpenVideoTabs()
        let remoteID = tabs.add(remote)
        let firstInvalidID = tabs.add(invalidLocal)
        let secondInvalidID = tabs.add(invalidLocal)
        let fileID = tabs.add(file)
        let remoteFileID = tabs.add(remoteFile)
        #expect(Set(tabs.items.map(\.id)).count == 5)
        #expect(firstInvalidID != secondInvalidID)
        #expect(fileID != remoteFileID)

        tabs.close(firstInvalidID)
        #expect(tabs.add(remote) == remoteID)
        #expect(tabs.add(file) == fileID)
        #expect(tabs.add(remoteFile) == remoteFileID)
        let thirdInvalidID = tabs.add(invalidLocal)
        #expect(thirdInvalidID != firstInvalidID && thirdInvalidID != secondInvalidID)
        #expect(tabs.items.filter { $0.source == invalidLocal }.count == 2)
    }

    @Test func closingAndReadmittingAnyPositionPreservesRemainingIdentities() {
        for removedIndex in 0..<5 {
            var tabs = OpenVideoTabs()
            let sources = (0..<5).map { local("episode-\($0).mkv") }
            let ids = sources.map { tabs.add($0) }
            tabs.select(ids[removedIndex])
            let removedID = ids[removedIndex]
            tabs.close(removedID)
            for index in sources.indices where index != removedIndex {
                #expect(tabs.add(sources[index]) == ids[index])
            }
            let replacementID = tabs.add(sources[removedIndex])
            #expect(replacementID != removedID)
            #expect(tabs.items.map(\.id) == ids.enumerated().compactMap {
                $0.offset == removedIndex ? nil : $0.element
            } + [replacementID])
            for id in tabs.items.map(\.id) { tabs.close(id) }
            #expect(tabs.items.isEmpty)
            #expect(tabs.selectedID == nil)
            for index in sources.indices {
                let reopened = tabs.add(sources[index])
                #expect(!ids.contains(reopened) && reopened != replacementID)
                #expect(tabs.add(sources[index]) == reopened)
            }
            #expect(tabs.items.map(\.source) == sources)
        }
    }

    @Test func recordedAliasesUpdateExistingStateAndReopeningStartsFresh() {
        let original = local("Caf\u{00E9}.mkv")
        let alias = local("nested/../Caf\u{0065}\u{0301}.mkv")
        let folder = URL(fileURLWithPath: "/tmp/open-video-tab-tests/", isDirectory: true)
        let playlist = [FolderPlaylistItem(url: original.url), FolderPlaylistItem(url: local("next.mkv").url)]
        var tabs = OpenVideoTabs()
        let id = tabs.add(original)
        tabs.select(id)
        tabs.record(source: alias, position: 91.25, wasPaused: true, playlist: playlist, folder: folder)
        #expect(tabs.items.count == 1)
        #expect(tabs.selected?.source == original)
        #expect(tabs.selected?.position == 91.25)
        #expect(tabs.selected?.wasPaused == true)
        #expect(tabs.selected?.playlist == playlist)
        #expect(tabs.selected?.folder == folder)

        tabs.record(source: alias, position: .infinity, wasPaused: false, playlist: [], folder: nil)
        #expect(tabs.selected?.position == 0)
        #expect(tabs.selected?.playlist == [FolderPlaylistItem(url: alias.url)])
        #expect(tabs.selected?.folder == nil)
        tabs.close(id)
        tabs.record(source: alias, position: 14, wasPaused: true, playlist: [], folder: folder)
        #expect(tabs.items.count == 1)
        #expect(tabs.items.first?.id != id)
        #expect(tabs.items.first?.source == alias)
        #expect(tabs.items.first?.position == 14)
        #expect(tabs.selectedID == nil)
        #expect(tabs.add(original) == tabs.items.first?.id)
    }

    @Test func copiedValuesKeepIndependentAdmissionsAndSemanticEquality() {
        let first = local("first.mkv"), second = local("second.mkv"), third = local("third.mkv")
        var original = OpenVideoTabs()
        let firstID = original.add(first), secondID = original.add(second)
        original.select(firstID)
        var copy = original
        #expect(copy == original)
        #expect(copy.add(local("nested/../first.mkv")) == firstID)
        #expect(copy == original)

        let transientID = copy.add(third)
        #expect(copy != original)
        copy.close(transientID)
        #expect(copy == original)

        copy.record(source: first, position: 30, wasPaused: true, playlist: [], folder: nil)
        #expect(copy != original)
        #expect(original.selected?.position == 0)
        copy.record(source: first, position: 0, wasPaused: false, playlist: [], folder: nil)
        #expect(copy == original)
        copy.select(secondID)
        #expect(copy != original)
        copy.select(firstID)
        #expect(copy == original)

        copy.close(secondID)
        let replacementID = copy.add(second)
        #expect(replacementID != secondID)
        #expect(original.add(second) == secondID)
        #expect(copy != original)
        let originalThirdID = original.add(third)
        #expect(originalThirdID != transientID)
        #expect(copy.add(third) != originalThirdID)
    }

    @Test func mixedAdmissionsMatchALinearResourceModel() throws {
        struct ExpectedTab {
            let id: UUID
            let source: MediaSource
            var position: TimeInterval = 0
            var wasPaused = false
            var playlist: [FolderPlaylistItem]
            var folder: URL?
        }
        let samples = try resourceSamples()
        var state: UInt64 = 0xA8B4_6317_50E2_C9D1
        func choose(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state >> 32) % bound
        }
        var tabs = OpenVideoTabs()
        var expected: [ExpectedTab] = []
        var selectedID: UUID?
        for step in 0..<300 {
            let source = samples[choose(samples.count)]
            switch choose(6) {
            case 0, 1:
                let existing = expected.first { $0.source.representsSameResource(as: source) }
                let id = tabs.add(source)
                if let existing {
                    #expect(id == existing.id)
                } else {
                    #expect(!expected.contains { $0.id == id })
                    expected.append(ExpectedTab(id: id, source: source, playlist: [FolderPlaylistItem(url: source.url)]))
                }
            case 2:
                let existingIndex = expected.firstIndex { $0.source.representsSameResource(as: source) }
                let positions: [Double] = [Double(step) / 4, -8, .nan, .infinity]
                let position = positions[choose(positions.count)]
                let paused = choose(2) == 0
                let playlist = choose(2) == 0 ? [] : [FolderPlaylistItem(url: samples[choose(samples.count)].url)]
                let folder = choose(2) == 0 ? nil : URL(fileURLWithPath: "/tmp/recorded-folder", isDirectory: true)
                tabs.record(source: source, position: position, wasPaused: paused, playlist: playlist, folder: folder)
                let index: Int
                if let existingIndex {
                    index = existingIndex
                } else {
                    index = expected.count
                    let id = try #require(tabs.items.last?.id)
                    #expect(!expected.contains { $0.id == id })
                    expected.append(ExpectedTab(id: id, source: source, playlist: []))
                }
                expected[index].position = position.isFinite ? max(0, position) : 0
                expected[index].wasPaused = paused
                expected[index].playlist = playlist.isEmpty ? [FolderPlaylistItem(url: source.url)] : playlist
                expected[index].folder = folder
            case 3:
                let id = !expected.isEmpty && choose(4) != 0 ? expected[choose(expected.count)].id : UUID()
                let existing = expected.first { $0.id == id }
                #expect(tabs.select(id)?.id == existing?.id)
                if existing != nil { selectedID = id }
            default:
                let id = !expected.isEmpty && choose(4) != 0 ? expected[choose(expected.count)].id : UUID()
                if let index = expected.firstIndex(where: { $0.id == id }) {
                    expected.remove(at: index)
                    if selectedID == id {
                        selectedID = expected.isEmpty ? nil : expected[min(index, expected.count - 1)].id
                    }
                }
                #expect(tabs.close(id)?.id == selectedID)
            }

            #expect(tabs.items.count == expected.count)
            #expect(tabs.selectedID == selectedID)
            for (actual, model) in zip(tabs.items, expected) {
                #expect(actual.id == model.id)
                #expect(actual.source == model.source)
                #expect(actual.position == model.position)
                #expect(actual.wasPaused == model.wasPaused)
                #expect(actual.playlist == model.playlist)
                #expect(actual.folder == model.folder)
            }
            if expected.count > 1, let index = expected.firstIndex(where: { $0.id == selectedID }) {
                #expect(tabs.adjacentID(1) == expected[(index + 1) % expected.count].id)
                #expect(tabs.adjacentID(-1) == expected[(index + expected.count - 1) % expected.count].id)
            } else {
                #expect(tabs.adjacentID(1) == nil)
                #expect(tabs.adjacentID(-1) == nil)
            }
        }
    }
}
