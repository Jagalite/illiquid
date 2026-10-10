import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail scheduling policy regressions")
struct ThumbnailSchedulingPolicyRegressionTests {
    @Test func visibilityTruthTable() {
        for hasWindow in [false, true] {
            for hidden in [false, true] {
                for visible in [false, true] {
                    for miniaturized in [false, true] {
                        for occluded in [false, true] {
                            #expect(ThumbnailVisibilityPolicy.isVisible(hasWindow: hasWindow,
                                isApplicationHidden: hidden, isWindowVisible: visible,
                                isMiniaturized: miniaturized, isOccluded: occluded)
                                == (hasWindow && !hidden && visible && !miniaturized && !occluded))
                        }
                    }
                }
            }
        }
    }

    @Test func cancelledLeaderIsNotRetriedBeforeLaterFiles() {
        let urls = (1...4).map { URL(fileURLWithPath: "/media/\($0).mkv") }
        var cursor = ThumbnailPassCursor()
        #expect(cursor.batch(from: urls, limit: 2) == Array(urls.prefix(2)))
        // Simulate cancellation during the very first duration probe/decode.
        cursor.advance(past: urls[0])
        #expect(cursor.batch(from: urls, limit: 2) == Array(urls[1...2]))
        cursor.advance(past: urls[2])
        #expect(cursor.batch(from: urls, limit: 2) == [urls[3]])
        #expect(cursor.hasRemaining(in: urls))
        cursor.advance(past: urls[3])
        #expect(!cursor.hasRemaining(in: urls))
        #expect(cursor.batch(from: urls, limit: 2) == Array(urls.prefix(2)))
    }

    @Test func cursorReconcilesRemovedAndReorderedCandidates() {
        let a = URL(fileURLWithPath: "/media/a.mkv")
        let b = URL(fileURLWithPath: "/media/b.mkv")
        let c = URL(fileURLWithPath: "/media/c.mkv")
        var cursor = ThumbnailPassCursor()
        cursor.advance(past: b)
        #expect(cursor.batch(from: [c, b, a], limit: 8) == [a])
        #expect(cursor.batch(from: [c, a], limit: 8) == [c, a])
        #expect(cursor.batch(from: [], limit: 8).isEmpty)
        #expect(cursor.batch(from: [a], limit: 0).isEmpty)
    }

    @Test func rankingBeforeBatchingReachesBeyondOriginalPrefix() {
        let folder = URL(fileURLWithPath: "/media")
        let urls = (1...10).map { folder.appendingPathComponent("\($0).mkv") }
        let candidates = urls.map { ThumbnailPolicy.Candidate(url: $0) }
        var settings = ThumbnailPreferences()
        settings.videosPerPass = 2
        let defaultRanking = ThumbnailPolicy.ranked(candidates, current: urls[0], folder: folder,
            now: Date(timeIntervalSince1970: 0), preferences: settings)
        #expect(defaultRanking.count == 2)
        let all = ThumbnailPolicy.ranked(candidates, current: urls[0], folder: folder,
            now: Date(timeIntervalSince1970: 0), preferences: settings, maximumCount: candidates.count)
        var cursor = ThumbnailPassCursor()
        var visited: [URL] = []
        repeat {
            for url in cursor.batch(from: all, limit: settings.videosPerPass) {
                cursor.advance(past: url)
                visited.append(url)
            }
        } while cursor.hasRemaining(in: all)
        #expect(visited == urls)
        settings.excludedFolderPaths = ["/media"]
        #expect(ThumbnailPolicy.ranked(candidates, current: urls[0], folder: folder,
            now: Date(), preferences: settings, maximumCount: candidates.count).isEmpty)
    }
}
