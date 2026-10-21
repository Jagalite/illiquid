import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Source media grouping")
struct SourceMediaGroupingTests {
    @Test func firstMatchingSpellingOwnsTheHeaderOnEveryProjection() async throws {
        let first = row("first", filename: "MiXeD Show.S01E10.mkv")
        let second = row("second", filename: "mixed show.S01E02.1080p.mkv", label: "needle one")
        let third = row("third", filename: "MIXED SHOW.S01E02.2160p.mkv", label: "needle two")
        let fourth = row("fourth", filename: "mixed show.S01E03.mkv", label: "needle three")
        let fifth = row("fifth", filename: "MiXeD Show.S01E01.mkv")
        let rows = [first, second, third, fourth, fifth]
        let filter = SourceBrowserFilter()

        let all = try await project(rows, filter: filter)
        #expect(headers(all).map(\.displayName) == ["TV Shows · MiXeD Show · Season 1 (5)"])
        // Header identity and URL come from the first input member, even when
        // numeric episode ordering moves that member to the end of its section.
        #expect(all.rows.first?.id == "media-section:TV Shows · MiXeD Show · Season 1")
        #expect(all.rows.first?.url == first.url)
        #expect(files(all) == [fifth, second, third, fourth, first])

        let searched = try await project(rows, filter: filter, query: "needle")
        #expect(headers(searched).map(\.displayName) == ["TV Shows · mixed show · Season 1 (3)"])
        #expect(searched.rows.first?.url == second.url)
        #expect(files(searched) == [second, third, fourth])
        #expect(searched.thumbnailCandidates == [second, third, fourth].map(\.url))
        #expect(searched.mediaPaths == Set([second, third, fourth].map { $0.url.standardizedFileURL.path }))

        let restored = try await project(rows, filter: filter, query: " \n")
        #expect(restored.rows == all.rows)
        #expect(await filter.visibilityBuildCount == 1)
    }

    @Test(arguments: [
        ("Épisode", "éPISODE"),
        ("Cafe\u{301}", "Café"),
        ("Straße", "STRASSE"),
    ])
    func unicodeCaseAndCanonicalEquivalenceKeepTheFirstSpelling(
        titles: (String, String)
    ) async throws {
        let first = row("first", filename: titles.0 + ".S01E02.mkv")
        let second = row("second", filename: titles.1 + ".S01E01.mkv")
        let result = try await project([first, second, first])
        let expectedTitle = try #require(first.recognizedMedia?.section) + " (3)"
        let header = try #require(headers(result).first)
        #expect(headers(result).count == 1)
        // String equality alone cannot distinguish composed/decomposed spelling.
        #expect(Array(header.displayName.utf8) == Array(expectedTitle.utf8))
        #expect(files(result) == [second, first, first])
    }

    @Test func canonicallyEqualTitlesUseTheirOwnFoundationFold() async throws {
        // Canonically equal Swift strings need not have canonically equal
        // Foundation case folds. Folding the iota subscript can expose the
        // original combining-mark order. Derive the expected groups using the
        // platform's Foundation operation, without assuming one ICU behavior.
        let a = "Α\u{345}\u{300}"
        let c = "α\u{300}ι"
        let b = "Α\u{300}\u{345}"
        #expect(a == b)
        #expect(!a.utf8.elementsEqual(b.utf8))
        let titles = [a, c, b, a, c, b]
        let rows = titles.enumerated().map { index, title in
            row("combining-\(index)", filename: title + ".S01E\(index + 1).mkv")
        }
        var canonicalTitles: [(key: String, title: String)] = []
        var expected: [(title: String, members: [SourceTreeDisplayRow])] = []
        for member in rows {
            let title = try #require(member.recognizedMedia?.section)
            let folded = title.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            let canonical: String
            if let prior = canonicalTitles.first(where: { $0.key == folded }) {
                canonical = prior.title
            } else {
                canonical = title
                canonicalTitles.append((folded, title))
            }
            // The original algorithm has two equality boundaries: folded keys
            // select canonical spellings, then those spellings group the rows.
            // Different folded keys can still return Swift-equal spellings.
            if let index = expected.firstIndex(where: { $0.title == canonical }) {
                expected[index].members.append(member)
            } else {
                expected.append((canonical, [member]))
            }
        }
        let result = try await project(rows)
        #expect(headers(result).count == expected.count)
        // Compare membership independently of section order: a native locale
        // may collate two distinct section titles equally, with no tie-break.
        var actual: [(header: SourceTreeDisplayRow, members: [SourceTreeDisplayRow])] = []
        for row in result.rows {
            if row.kind == .mediaSection {
                actual.append((row, []))
            } else {
                #expect(!actual.isEmpty)
                if !actual.isEmpty { actual[actual.count - 1].members.append(row) }
            }
        }
        for group in expected {
            let found = try #require(actual.first { $0.header.id == "media-section:" + group.title })
            #expect(Array(found.header.displayName.utf8)
                == Array((group.title + " (\(group.members.count))").utf8))
            #expect(found.header.url == group.members.first?.url)
            #expect(found.members == group.members)
        }
    }

    @Test func caseFoldingDoesNotEraseAccentsOrWidthDifferences() async throws {
        let rows = [
            row("plain", filename: "Cafe.S01E01.mkv"),
            row("accented", filename: "Café.S01E01.mkv"),
            row("narrow", filename: "Show.S01E01.mkv"),
            row("wide", filename: "Ｓｈｏｗ.S01E01.mkv"),
        ]
        let result = try await project(rows)
        #expect(headers(result).count == 4)
        #expect(Set(headers(result).map(\.displayName)) == [
            "TV Shows · Cafe · Season 1 (1)", "TV Shows · Café · Season 1 (1)",
            "TV Shows · Show · Season 1 (1)", "TV Shows · Ｓｈｏｗ · Season 1 (1)",
        ])
        #expect(Set(files(result).map(\.id)) == Set(rows.map(\.id)))
    }

    @Test func airDatesSortChronologicallyAndRetainVariantOrderForTies() async throws {
        let later = row("later", filename: "News.2020.01.03.mkv")
        let earlierA = row("earlier-a", filename: "News.2020.01.01.2160p.mkv")
        let earlierB = row("earlier-b", filename: "News.2020.01.01.1080p.mkv")
        #expect(later.recognizedMedia?.airDate == "2020-01-03")
        #expect(earlierA.recognizedMedia?.airDate == earlierB.recognizedMedia?.airDate)
        let result = try await project([later, earlierA, earlierB])
        #expect(headers(result).map(\.displayName) == ["TV Shows · News · By date (3)"])
        #expect(files(result) == [earlierA, earlierB, later])
    }

    @Test func yearsSeasonsAndSpecialsRemainSeparateSections() async throws {
        let rows = [
            row("season-one", filename: "Show (2020).S01E01.mkv"),
            row("season-two", filename: "Show (2020).S02E01.mkv"),
            row("special", filename: "Show (2020).S00E01.mkv"),
            row("remake", filename: "Show (2021).S01E01.mkv"),
        ]
        let result = try await project(rows)
        #expect(Set(headers(result).map(\.displayName)) == [
            "TV Shows · Show (2020) · Season 1 (1)",
            "TV Shows · Show (2020) · Season 2 (1)",
            "TV Shows · Show (2020) · Specials (1)",
            "TV Shows · Show (2021) · Season 1 (1)",
        ])
        #expect(Set(files(result).map(\.id)) == Set(rows.map(\.id)))
    }

    @Test func sectionRanksAndNonEpisodeMemberOrderRemainIntact() async throws {
        let unknownA = row("unknown-a", filename: "home.mp4")
        let movieZ = row("movie-z", filename: "Zed (2020).mkv")
        let extraA = row("extra-a", filename: "Film-trailer.mp4")
        let showTen = row("show-ten", filename: "Series 10.S01E01.mkv")
        let movieA = row("movie-a", filename: "Alpha (2021).mkv")
        let extraB = row("extra-b", filename: "Film-featurette.mp4")
        var unknownB = row("unknown-b", filename: "another-home.mp4")
        unknownB.recognizedMedia = nil
        let showTwo = row("show-two", filename: "Series 2.S01E01.mkv")
        let result = try await project([unknownA, movieZ, extraA, showTen, movieA, extraB, unknownB, showTwo])
        #expect(headers(result).map(\.displayName) == [
            "Movies (2)", "TV Shows · Series 2 · Season 1 (1)",
            "TV Shows · Series 10 · Season 1 (1)", "Extras (2)", "Other Videos (2)",
        ])
        #expect(files(result) == [movieZ, movieA, showTwo, showTen, extraA, extraB, unknownA, unknownB])
    }

    @Test func emptyAndUnmatchedProjectionsDoNotRetainHeaders() async throws {
        let filter = SourceBrowserFilter()
        let rows = [row("file", filename: "Show.S01E01.mkv")]
        let initial = try await project(rows, filter: filter)
        #expect(initial.rows.count == 2)
        let unmatched = try await project(rows, filter: filter, query: "absent-marker")
        #expect(unmatched.rows.isEmpty)
        #expect(unmatched.thumbnailCandidates.isEmpty && unmatched.mediaPaths.isEmpty)
        let empty = try await project([], filter: filter)
        #expect(empty.rows.isEmpty)
        #expect(empty.thumbnailCandidates.isEmpty && empty.mediaPaths.isEmpty)
        #expect(empty.hiddenCount == 0 && empty.regexCounts.isEmpty)
    }

    private func row(_ id: String, filename: String, label: String? = nil) -> SourceTreeDisplayRow {
        let url = URL(fileURLWithPath: "/tmp/source-media-grouping/" + id + ".mkv")
        var recognized = MediaNameRecognition.recognize(relativePath: filename)
        recognized.metadataSources = ["NFO", ".plexmatch"]
        return SourceTreeDisplayRow(
            id: id, folderID: "folder-" + id, url: url, displayName: label ?? id,
            contextLabel: "Original context " + id, recognizedMedia: recognized,
            visibilityPath: url.path, depth: 2, ancestorIDs: ["ancestor-" + id],
            kind: .media(dateAdded: Date(timeIntervalSince1970: 123_456)),
            containsSupportedMedia: true
        )
    }

    private func project(
        _ rows: [SourceTreeDisplayRow], filter: SourceBrowserFilter = SourceBrowserFilter(),
        query: String = ""
    ) async throws -> SourceBrowserProjection {
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .media
        return try #require(await filter.project(
            rows: rows, configuration: configuration, roots: [], revealsRulePreview: false, query: query
        ))
    }

    private func headers(_ result: SourceBrowserProjection) -> [SourceTreeDisplayRow] {
        result.rows.filter { $0.kind == .mediaSection }
    }

    private func files(_ result: SourceBrowserProjection) -> [SourceTreeDisplayRow] {
        result.rows.filter { $0.kind.itemKind == .media }
    }
}
