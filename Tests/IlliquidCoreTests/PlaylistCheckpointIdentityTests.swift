import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist checkpoint identity projection")
struct PlaylistCheckpointIdentityTests {
    @Test func emptyInputsAndEmptySavedOrderPreserveTheCurrentIdentityOrder() {
        let a = item(0), b = item(1)
        #expect(PlaylistMutation.restoringIDs([], ids: []) == [])
        #expect(PlaylistMutation.restoringIDs([], ids: [a.id, a.id]) == [])
        #expect(PlaylistMutation.restoringIDs([b], ids: []) == [b.id])
        #expect(PlaylistMutation.restoringIDs(
            [b, a, item(1, revision: 9), a], ids: []
        ) == [b.id, a.id])
    }

    @Test func reconciliationDropsRemovedEntriesAndAppendsNewEntriesInCurrentOrder() {
        let a = item(0), b = item(1), c = item(2), d = item(3), e = item(4)
        let current = [e, c, d, a, item(2, revision: 9)]
        let saved = [a.id, b.id, a.id, c.id, b.id]
        let expected = [a.id, c.id, e.id, d.id]

        let actual = PlaylistMutation.restoringIDs(current, ids: saved)
        #expect(actual == expected)
        #expect(utf8(actual) == utf8(
            PlaylistMutation.restoringOrder(current, ids: saved).map(\.id)
        ))
        #expect(PlaylistMutation.restoringIDs(current, ids: actual) == expected)

        // A subsequent edit removes A and E. Neither may return from history.
        #expect(PlaylistMutation.restoringIDs(
            [d, c, b], ids: actual
        ) == [c.id, d.id, b.id])
    }

    @Test func outputKeepsTheCurrentIdentityBytesWhenSavedSpellingIsCanonicallyEqual() {
        let current = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Caf\u{e9}.mkv")
        )
        let decomposedSavedID = "/Media/Cafe\u{301}.mkv"

        // String equality alone would hide returning the saved spelling.
        #expect(current.id == decomposedSavedID)
        #expect(Array(current.id.utf8) != Array(decomposedSavedID.utf8))

        let actual = PlaylistMutation.restoringIDs(
            [current, current],
            ids: [decomposedSavedID, current.id, decomposedSavedID]
        )
        #expect(utf8(actual) == [Array(current.id.utf8)])
        #expect(utf8(actual) == utf8(
            PlaylistMutation.restoringOrder(
                [current, current],
                ids: [decomposedSavedID, current.id, decomposedSavedID]
            ).map(\.id)
        ))
    }

    @Test func rawDecodedLocalAliasesAndRemoteIdentitiesKeepTheirExistingSemantics() throws {
        let rawURL = try #require(URL(
            string: "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv"
        ))
        let raw = try decodedItem(rawURL)
        #expect(raw.url.absoluteString == rawURL.absoluteString)
        #expect(raw.url.absoluteString.contains("/Season/../"))

        let canonical = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Caf\u{e9}.mkv")
        )
        let remoteA = FolderPlaylistItem(url: try #require(URL(
            string: "https://example.invalid/media?id=1#first"
        )))
        let remoteB = FolderPlaylistItem(url: try #require(URL(
            string: "https://example.invalid/media?id=2#second"
        )))
        let unsupportedFile = FolderPlaylistItem(url: try #require(URL(
            string: "file://media-server.example/Media/Caf%C3%A9.mkv"
        )))
        let current = [
            remoteB, raw, remoteA, canonical, unsupportedFile, remoteB
        ]
        let saved = [
            "/Media/Cafe\u{301}.mkv",
            remoteA.url.absoluteString,
            "/Media/removed.mkv",
        ]
        let expected = [
            canonical.id,
            remoteA.url.absoluteString,
            remoteB.url.absoluteString,
            unsupportedFile.url.absoluteString,
        ]

        let actual = PlaylistMutation.restoringIDs(current, ids: saved)
        #expect(utf8(actual) == utf8(expected))
        #expect(utf8(actual) == utf8(
            PlaylistMutation.restoringOrder(current, ids: saved).map(\.id)
        ))
        #expect(utf8(PlaylistMutation.restoringIDs(current, ids: [])) == utf8([
            remoteB.url.absoluteString,
            canonical.id,
            remoteA.url.absoluteString,
            unsupportedFile.url.absoluteString,
        ]))
    }

    @Test func allSmallCurrentAndSavedSequencesMatchIndependentIdentityLabels() {
        let currentCases = sequences(alphabetSize: 3, maximumLength: 3)
        let savedCases = sequences(alphabetSize: 4, maximumLength: 3)
        // Label 3 exists only in the saved order and must never be resurrected.
        let identities = (0..<4).map { "/Media/Episode \($0).mkv" }
        var checked = 0

        for currentLabels in currentCases {
            let current = currentLabels.enumerated().map {
                item($0.element, revision: $0.offset)
            }
            for savedLabels in savedCases {
                // Independent oracle: integer labels and linear membership.
                var expectedLabels: [Int] = []
                for label in savedLabels + currentLabels {
                    if currentLabels.contains(label),
                       !expectedLabels.contains(label) {
                        expectedLabels.append(label)
                    }
                }
                let expected = expectedLabels.map { identities[$0] }
                let saved = savedLabels.map { identities[$0] }
                let actual = PlaylistMutation.restoringIDs(current, ids: saved)

                #expect(utf8(actual) == utf8(expected))
                checked += 1
            }
        }
        #expect(checked == 3_400)
    }

    private func utf8(_ values: [String]) -> [[UInt8]] {
        values.map { Array($0.utf8) }
    }

    private func item(_ number: Int, revision: Int = 0) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode \(number).mkv"),
            externalSubtitleURLs: [
                URL(fileURLWithPath: "/Subtitles/\(number)-\(revision).srt")
            ],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
    }

    private struct RawItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private func decodedItem(_ url: URL) throws -> FolderPlaylistItem {
        let payload = RawItemPayload(
            url: url,
            externalSubtitleURLs: [
                URL(fileURLWithPath: "/Subtitles/raw.srt")
            ],
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        return try JSONDecoder().decode(
            FolderPlaylistItem.self,
            from: JSONEncoder().encode(payload)
        )
    }

    private func sequences(alphabetSize: Int, maximumLength: Int) -> [[Int]] {
        var result: [[Int]] = [[]]
        var layer: [[Int]] = [[]]
        for _ in 0..<maximumLength {
            layer = layer.flatMap { prefix in
                (0..<alphabetSize).map { prefix + [$0] }
            }
            result.append(contentsOf: layer)
        }
        return result
    }
}
