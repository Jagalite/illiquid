import Foundation
import Testing
@testable import IlliquidCore

@Suite("External subtitle candidate traversal")
struct ExternalSubtitleCandidateTraversalTests {
    @Test func ancestorAndDescendantCandidatesCompeteUsingTheExistingScores() {
        let ancestor = url("Series.mkv")
        let descendant = url("Series Finale Extended.mkv")
        let subtitle = url("Series Finale.en.forced.srt")
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [subtitle], with: [ancestor, descendant]
        )
        // There is no media terminal at "Series Finale". The more-specific
        // descendant must still beat the earlier shorter-name ancestor.
        #expect(matches == [ancestor: [], descendant: [subtitle]])
    }

    @Test func missingQueryChildStillCompletesWithAnAncestorMatch() {
        let ancestor = url("Documentary Film.mkv")
        let unrelatedChild = url("Documentary Film Remastered.mkv")
        let subtitle = url("Documentary Film Extended.en.srt")
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [subtitle], with: [ancestor, unrelatedChild]
        ) == [ancestor: [subtitle], unrelatedChild: []])
    }

    @Test(arguments: [false, true])
    func laterSpecificWinnerClearsAnAncestorTieAndLaterExactTiesRemainAmbiguous(_ reversed: Bool) {
        let firstAncestor = url("The Show.mkv")
        let secondAncestor = url("The Show.mp4")
        let specific = url("The Show Extended.mkv")
        let otherSpecific = url("The Show Extended.mp4")
        let subtitle = url("The Show Extended.en.srt")
        let inventory = [firstAncestor, secondAncestor, specific]
        let media = reversed ? Array(inventory.reversed()) : inventory
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [subtitle], with: media
        ) == [firstAncestor: [], secondAncestor: [], specific: [subtitle]])

        let tiedInventory = [firstAncestor, specific, otherSpecific]
        let tiedMedia = reversed ? Array(tiedInventory.reversed()) : tiedInventory
        let tied = ExternalSubtitleMatcher.associate(subtitleURLs: [subtitle], with: tiedMedia)
        #expect(tied.count == tiedMedia.count)
        #expect(tied.values.allSatisfy { $0.isEmpty })
    }

    @Test func denseTerminalGroupKeepsReleaseSpecificityAndGenericAmbiguity() {
        let media = encodes(count: 128)
        let selected = 73
        let generic = url("Feature.en.srt")
        let specific = media[selected].deletingPathExtension().appendingPathExtension("en.srt")
        // All numeric resolution suffixes normalize to the same trie terminal.
        // The generic subtitle ties; the release-specific subtitle has one winner.
        for inventory in [media, Array(media.reversed())] {
            let matches = ExternalSubtitleMatcher.associate(
                subtitleURLs: [generic, specific], with: inventory
            )
            #expect(matches.count == media.count)
            for index in media.indices {
                #expect(matches[media[index]] == (index == selected ? [specific] : []))
            }
        }
    }

    @Test(arguments: [false, true])
    func cancellationWithinADenseTerminalGroupDiscardsEarlierAssociations(_ sticky: Bool) {
        let group = encodes(count: 64)
        let earlier = url("Earlier Winner.mkv")
        let media = [earlier] + group
        let subtitles = [url("Earlier Winner.en.srt"), url("Feature.srt")]
        var completeCheckpoints = 0
        let complete = ExternalSubtitleMatcher.associate(
            subtitleURLs: subtitles, with: media, isCancelled: {
                completeCheckpoints += 1
                return false
            }
        )
        #expect(complete[earlier] == [subtitles[0]])
        #expect(group.allSatisfy { complete[$0] == [] })

        // The final lookup has one terminal group and no child nodes. Its
        // candidate polls precede the per-media sorting polls and final poll.
        // Choose the first, middle and last candidate, without depending on
        // dictionary iteration order or the earlier lookup's token count.
        let firstCandidateCheckpoint = completeCheckpoints - media.count - 1 - group.count + 1
        #expect(firstCandidateCheckpoint > 0)
        for offset in [0, group.count / 2, group.count - 1] {
            let cancelAt = firstCandidateCheckpoint + offset
            var checkpoint = 0
            let cancelled = ExternalSubtitleMatcher.associate(
                subtitleURLs: subtitles, with: media, isCancelled: {
                    checkpoint += 1
                    return sticky ? checkpoint >= cancelAt : checkpoint == cancelAt
                }
            )
            #expect(checkpoint == cancelAt)
            #expect(cancelled.isEmpty)
        }
    }

    @Test func associationOwnsItsOutputAndLeavesInputInventoriesUnchanged() {
        let first = url("Series.mkv")
        let specific = url("Series Finale.mkv")
        let subtitle = url("Series Finale.en.srt")
        var media = [first, specific]
        var subtitles = [subtitle]
        let matches = ExternalSubtitleMatcher.associate(subtitleURLs: subtitles, with: media)
        #expect(media == [first, specific])
        #expect(subtitles == [subtitle])
        media.removeAll()
        subtitles = [url("Replacement.srt")]
        #expect(matches == [first: [], specific: [subtitle]])
    }

    @Test func eachMediaValueIsSortedWithoutLosingKeysOrDuplicateSubtitles() {
        let first = url("Film One.mkv")
        let second = url("Film Two.mkv")
        let unmatched = url("Unrelated.mkv")
        let unsupported = url("Readme.txt")
        let firstEnglish = url("Film One.en.srt")
        let firstFrench = url("Film One.fr.srt")
        let firstJapanese = url("Film One.ja.srt")
        let secondEnglish = url("Film Two.en.srt")
        let secondJapanese = url("Film Two.ja.srt")
        let media = [second, first, unsupported, first, unmatched]
        let subtitles = [firstJapanese, secondJapanese, firstFrench,
                         firstEnglish, secondEnglish, firstEnglish]
        let expected = [
            first: [firstEnglish, firstEnglish, firstFrench, firstJapanese],
            second: [secondEnglish, secondJapanese],
            unmatched: [], unsupported: [],
        ]
        #expect(ExternalSubtitleMatcher.associate(subtitleURLs: subtitles, with: media) == expected)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: Array(subtitles.reversed()), with: Array(media.reversed())
        ) == expected)
    }

    @Test func emptyNormalizedQueryCompletesWithoutCandidates() {
        let media = [url("Feature.mkv"), url("Feature Extended.mkv")]
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [url("__---.srt")], with: media
        )
        #expect(matches.count == media.count)
        #expect(matches.values.allSatisfy { $0.isEmpty })
    }

    private func encodes(count: Int) -> [URL] {
        (0..<count).map { url("Feature.\(360 + $0 * 8)p.mkv") }
    }

    private func url(_ filename: String) -> URL {
        URL(fileURLWithPath: "/tmp/SubtitleCandidates", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
