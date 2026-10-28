import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail ranking context")
struct ThumbnailRankingContextTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let horizon: TimeInterval = 7 * 86_400

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: "/media/\(path)")
    }

    @Test func missingFolderKeepsExplicitInterestAndRecencyBoundary() {
        let current = url("current.mkv")
        let visible = url("visible.mkv")
        let recent = url("recent.mkv")
        let neighbor = url("neighbor.mkv")
        let boundary = url("boundary.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [
            .init(url: boundary, lastUsed: now.addingTimeInterval(-horizon)),
            .init(url: neighbor, neighborDistance: 1),
            .init(url: url("expired.mkv"),
                  lastUsed: now.addingTimeInterval(-horizon - 1)),
            .init(url: url("uninterested.mkv")),
            .init(url: visible, isVisible: true),
            .init(url: current),
            .init(url: recent, lastUsed: now),
            .init(url: URL(string: "https://example.invalid/video.mkv")!,
                  lastUsed: now, isVisible: true, neighborDistance: 0),
        ]

        #expect(ThumbnailPolicy.ranked(
            candidates, current: current, folder: nil, now: now,
            preferences: .init()
        ) == [current, visible, recent, neighbor, boundary])
    }

    @Test func missingFolderPreservesFirstOccurrenceOfNormalizedDuplicates() {
        let suppressed = url("duplicates/suppressed.mkv")
        let retained = url("duplicates/retained.mkv")
        let newer = url("duplicates/newer.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [
            .init(url: suppressed),
            .init(url: url("duplicates/../duplicates/suppressed.mkv"),
                  isVisible: true),
            .init(url: retained,
                  lastUsed: now.addingTimeInterval(-horizon * 0.75)),
            .init(url: url("duplicates/../duplicates/retained.mkv"),
                  lastUsed: now, isVisible: true),
            .init(url: newer,
                  lastUsed: now.addingTimeInterval(-horizon * 0.5)),
        ]

        // A later duplicate cannot admit an ineligible first occurrence or
        // replace the ranking metadata of an already eligible occurrence.
        #expect(ThumbnailPolicy.ranked(
            candidates, current: nil, folder: nil, now: now,
            preferences: .init()
        ) == [newer, retained])
    }

    @Test func missingFolderPreservesPrioritiesStableTiesAndLimits() {
        let firstRecent = url("first-recent.mkv")
        let secondRecent = url("second-recent.mkv")
        let neighbor = url("neighbor.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [
            .init(url: firstRecent,
                  lastUsed: now.addingTimeInterval(-horizon * 0.5)),
            .init(url: secondRecent,
                  lastUsed: now.addingTimeInterval(-horizon * 0.5)),
            .init(url: neighbor, neighborDistance: 0),
        ]

        for priority in ThumbnailPreferences.Priority.allCases {
            var settings = ThumbnailPreferences()
            settings.priority = priority
            settings.videosPerPass = 2
            let expected = priority == .recent
                ? [firstRecent, secondRecent, neighbor]
                : [neighbor, firstRecent, secondRecent]

            #expect(ThumbnailPolicy.ranked(
                candidates, current: nil, folder: nil, now: now,
                preferences: settings, maximumCount: candidates.count
            ) == expected)
            #expect(ThumbnailPolicy.ranked(
                candidates, current: nil, folder: nil, now: now,
                preferences: settings
            ) == Array(expected.prefix(2)))
            #expect(ThumbnailPolicy.ranked(
                candidates, current: nil, folder: nil, now: now,
                preferences: settings, maximumCount: 0
            ).isEmpty)
        }
    }

    @Test func missingFolderPreservesExclusionBoundariesAndRootExclusion() {
        let current = url("blocked/current.mkv")
        let permitted = url("blocked-other/visible.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [
            .init(url: current),
            .init(url: url("blocked/nested/visible.mkv"), isVisible: true),
            .init(url: permitted, isVisible: true),
        ]
        var settings = ThumbnailPreferences()
        settings.excludedFolderPaths = ["/media/blocked/../blocked"]

        #expect(ThumbnailPolicy.ranked(
            candidates, current: current, folder: nil, now: now,
            preferences: settings
        ) == [permitted])

        settings.excludedFolderPaths = ["/"]
        #expect(ThumbnailPolicy.ranked(
            candidates, current: current, folder: nil, now: now,
            preferences: settings
        ).isEmpty)
    }

    @Test func presentFolderStillSuppliesLocalEligibilityAndPriority() {
        let local = url("movies/local.mkv")
        let recent = url("elsewhere/recent.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [
            .init(url: recent,
                  lastUsed: now.addingTimeInterval(-horizon * 0.5)),
            .init(url: local),
            .init(url: url("movies/season/child.mkv")),
            .init(url: url("movies-other/sibling.mkv")),
        ]
        let folder = url("movies/temporary/..")
        var settings = ThumbnailPreferences()
        settings.priority = .nearby

        #expect(ThumbnailPolicy.ranked(
            candidates, current: nil, folder: nil, now: now,
            preferences: settings
        ) == [recent])
        #expect(ThumbnailPolicy.ranked(
            candidates, current: nil, folder: folder, now: now,
            preferences: settings
        ) == [local, recent])

        settings.priority = .recent
        #expect(ThumbnailPolicy.ranked(
            candidates, current: nil, folder: folder, now: now,
            preferences: settings
        ) == [recent, local])
    }
}
