import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Source browser search equivalence")
struct SourceBrowserSearchTests {
    @Test(arguments: ["", " \t\n", "\u{2003}\r\n"])
    func emptyQueryPreservesAllRowsExactly(query: String) {
        let rows = [
            searchRow("same", "Message", kind: .message("Unavailable")),
            searchRow("same", "Header", kind: .mediaSection),
            searchRow("folder", "Folder", kind: .folder(isRoot: true)),
            searchRow("file", "Episode", ancestors: ["folder"]),
        ]
        #expect(SourceBrowserFilter.search(rows, query: query) == rows)
        #expect(SourceBrowserFilter.search([], query: query).isEmpty)
    }

    @Test func unionKeepsDuplicateRowsAndEveryMatchingRowsAncestors() {
        let rows = [
            searchRow("root", "Root", kind: .folder(isRoot: true)),
            searchRow("duplicate", "Nonmatching duplicate", ancestors: ["not-included"]),
            searchRow("message-ancestor", "Unavailable", kind: .message("Unavailable")),
            searchRow("duplicate", "NEEDLE first", ancestors: ["root", "message-ancestor", "root", "missing"]),
            searchRow("duplicate", "Needle second", ancestors: ["later", "section-ancestor", "duplicate"]),
            searchRow("sibling", "Unrelated sibling", ancestors: ["root"]),
            searchRow("later", "Later ancestor", kind: .folder(isRoot: false), ancestors: ["not-included"]),
            searchRow("section-ancestor", "Header", kind: .mediaSection),
            searchRow("message-only", "Needle", kind: .message("Needle")),
            searchRow("section-only", "Needle", kind: .mediaSection),
            searchRow("not-included", "Not a listed matching ancestor", kind: .folder(isRoot: true)),
        ]
        let expected = [0, 1, 2, 3, 4, 6, 7].map { rows[$0] }
        #expect(SourceBrowserFilter.search(rows, query: "needle") == expected)
        #expect(SourceBrowserFilter.search(rows, query: "absent-query").isEmpty)
    }

    @Test func matchingFolderIncludesAncestorsWithoutExpandingDescendants() {
        let rows = [
            searchRow("root", "Library", kind: .folder(isRoot: true)),
            searchRow("folder", "Needle folder", kind: .folder(isRoot: false), ancestors: ["root"]),
            searchRow("child", "Episode", ancestors: ["root", "folder"]),
            searchRow("message", "Needle error", kind: .message("Needle error"), ancestors: ["root", "folder"]),
        ]
        #expect(SourceBrowserFilter.search(rows, query: "  NEEDLE \n") == Array(rows.prefix(2)))
    }

    @Test func recognizedMediaControlsAdditionalSearchFields() {
        let unknown = MediaNameRecognition.recognize(relativePath: "home.mkv")
        let episode = MediaNameRecognition.recognize(
            relativePath: "Quiet Show (2020)/Season 02/S02E03.mkv"
        )
        let movie = MediaNameRecognition.recognize(
            relativePath: "Catalog Movie (2021) {imdb-tt1234567}.mp4"
        )
        let rows = [
            searchRow("display", "Visible token"),
            searchRow("raw", "Episode", fileName: "release-2160p.mkv", media: unknown),
            searchRow("section", "S02E03", media: episode),
            searchRow("catalog", "Movie", media: movie),
            searchRow("context", "Another", context: "Special archive note", media: unknown),
            searchRow("unrecognized", "Opaque", fileName: "release-2160p.mkv", context: "Special archive note"),
            searchRow("folder-metadata", "Folder", kind: .folder(isRoot: false), context: "Folder metadata", media: unknown),
            searchRow("message", "Visible token", kind: .message("Visible token"), media: episode),
            searchRow("header", "Visible token", kind: .mediaSection, media: movie),
        ]
        for (query, index) in [
            ("VISIBLE TOKEN", 0), ("2160p", 1), ("Quiet Show", 2),
            ("Season 2", 2), ("IMDB-TT1234567", 3), ("archive", 4),
            ("Folder metadata", 6),
        ] {
            #expect(SourceBrowserFilter.search(rows, query: query) == [rows[index]])
        }
    }

    @Test func unicodeAndLocaleMatchingAgreeWithOriginalPredicate() {
        let names = ["CAFÉ", "Cafe\u{301}", "Straße", "STRASSE", "İstanbul", "istanbul", "東京", "🍿 Movie"]
        let rows = names.enumerated().map { offset, name in
            searchRow("unicode-\(offset)", name)
        }
        // Foundation's locale behavior can differ by platform. Preserve its
        // existing predicate instead of imposing a new folding policy.
        for query in ["café", "cafe\u{301}", "CAFE", "strasse", "straße", "I", "İ", "ı", "東京", "🍿", " \n🍿\t"] {
            #expect(SourceBrowserFilter.search(rows, query: query) == legacySearch(rows, query: query))
        }
    }

    @Test func seededRowsMatchOriginalSearchIncludingDuplicateIdentities() {
        let words = ["Needle", "quiet", "CAFÉ", "東京", "İstanbul", "🍿", "S02E03", "plain"]
        let media = [
            MediaNameRecognition.recognize(relativePath: "The Show/Season 02/S02E03.mkv"),
            MediaNameRecognition.recognize(relativePath: "Movie (2020) {tmdb-73}.mp4"),
            MediaNameRecognition.recognize(relativePath: "home.mkv"),
        ]
        var random = SearchRandom(state: 0x5EA2_C4_2026)
        for scenario in 0..<32 {
            var rows: [SourceTreeDisplayRow] = []
            for index in 0..<120 {
                let id = "id-\(random.next(32))"
                let word = words[random.next(words.count)]
                let kind: SourceTreeDisplayRow.Kind = switch random.next(4) {
                case 0: .folder(isRoot: random.next(2) == 0)
                case 1: .media(dateAdded: Date(timeIntervalSince1970: Double(index)))
                case 2: .message("Status \(index)")
                default: .mediaSection
                }
                let ancestors = (0..<random.next(6)).map { _ in "id-\(random.next(40))" }
                var row = searchRow(id, "\(word) \(index)", kind: kind,
                    ancestors: ancestors, fileName: "\(scenario)-\(index)-\(word).mkv",
                    context: words[random.next(words.count)],
                    media: random.next(3) == 0 ? nil : media[random.next(media.count)])
                if random.next(4) == 0 {
                    row.visibility = .init(matches: [.manual], isInherited: random.next(2) == 0)
                }
                row.containsSupportedMedia = random.next(2) == 0
                rows.append(row)
            }
            for query in words + ["", " \n", "tmdb-73", "Season 2", "missing-query"] {
                #expect(SourceBrowserFilter.search(rows, query: query) == legacySearch(rows, query: query),
                    "Scenario \(scenario), query \(query)")
            }
        }
    }

    @Test func actorSearchPreservesVisibilityMetadataAndReusesItsProjection() async throws {
        let filter = SourceBrowserFilter()
        let rows = [
            searchRow("root", "Library", kind: .folder(isRoot: true)),
            searchRow("visible", "Needle visible", ancestors: ["root"]),
            searchRow("hidden", "Needle hidden", ancestors: ["root"]),
        ]
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [.init(id: "hide", pattern: "hidden", colorIndex: 2, isEnabled: true)]
        let all = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [], revealsRulePreview: false, query: ""))
        let searched = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [], revealsRulePreview: false, query: "needle"))
        #expect(searched.rows == Array(rows.prefix(2)))
        #expect(searched.hiddenCount == 1)
        #expect(searched.regexCounts == ["hide": 1])
        #expect(searched.thumbnailCandidates == [rows[1].url])
        #expect(searched.mediaPaths == [rows[1].url.standardizedFileURL.path])
        let empty = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [], revealsRulePreview: false, query: "absent-query"))
        #expect(empty.rows.isEmpty && empty.thumbnailCandidates.isEmpty && empty.mediaPaths.isEmpty)
        #expect(empty.hiddenCount == all.hiddenCount && empty.regexCounts == all.regexCounts)
        let restored = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [], revealsRulePreview: false, query: " \n"))
        #expect(restored.rows == all.rows)
        #expect(restored.thumbnailCandidates == all.thumbnailCandidates && restored.mediaPaths == all.mediaPaths)
        #expect(await filter.visibilityBuildCount == 1)

        let preview = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [], revealsRulePreview: true, query: "needle"))
        #expect(preview.rows.map(\.id) == rows.map(\.id))
        #expect(preview.rows.last?.visibility?.regexMatches == [.init(id: "hide", colorIndex: 2)])
        #expect(preview.hiddenCount == 1 && preview.regexCounts == ["hide": 1])
        #expect(await filter.visibilityBuildCount == 2)
    }

    @Test func actorMediaViewSearchGroupsOnlyMatchingFilesAndReusesTree() async throws {
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .media
        let input = SourceTreeProjectionInput(
            items: ["Series/Season 01/Series.S01E10.mkv", "Series/Season 01/Series.S01E02.mkv", "Movie (2020).mkv"].map {
                .init(kind: .file, url: URL(fileURLWithPath: "/tmp/browser-search/" + $0))
            }, visibility: configuration, roots: [], directoryContents: [:], directoryErrors: [:],
            recursiveMediaEntries: [], expandedFolderIDs: [],
            sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off)
        )
        let filter = SourceBrowserFilter()
        let all = try #require(await filter.project(input: input, revealsRulePreview: false, query: ""))
        let searched = try #require(await filter.project(input: input, revealsRulePreview: false, query: "Series"))
        let files = searched.rows.filter { $0.kind.itemKind == .media }
        #expect(files.compactMap { $0.recognizedMedia?.episode } == [2, 10])
        #expect(searched.rows.count == 3)
        #expect(searched.rows.first?.kind == .mediaSection)
        #expect(searched.rows.first?.displayName == "TV Shows · Series · Season 1 (2)")
        #expect(files == all.rows.filter { $0.recognizedMedia?.kind == .episode })
        #expect(searched.thumbnailCandidates == files.map(\.url))
        #expect(searched.mediaPaths == Set(files.map { $0.url.standardizedFileURL.path }))
        let single = try #require(await filter.project(input: input, revealsRulePreview: false, query: "Series.S01E02"))
        #expect(single.rows.count == 2 && single.rows.last == files.first)
        #expect(single.rows.first?.displayName == "TV Shows · Series · Season 1 (1)")
        #expect(await filter.treeBuildCount == 1)
        #expect(await filter.visibilityBuildCount == 1)
    }

    @Test func cancellationBeforeSearchDoesNotPublishOrReplaceCachedProjection() async throws {
        let rows = [searchRow("file", "Needle")]
        let filter = SourceBrowserFilter()
        let cached = try #require(await filter.project(rows: rows, configuration: .default,
            roots: [], revealsRulePreview: false, query: ""))
        let gate = SearchCancellationGate()
        let task = Task.detached {
            await gate.suspend()
            let searched = SourceBrowserFilter.search(rows, query: "needle")
            let blank = SourceBrowserFilter.search(rows, query: " \n")
            let projection = await filter.project(rows: [], configuration: .default,
                roots: [], revealsRulePreview: false, query: "needle")
            return (searched, blank, projection)
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.open()
        let (searched, blank, projection) = await task.value
        #expect(searched.isEmpty)
        #expect(blank == rows)
        #expect(projection == nil)
        let restored = try #require(await filter.project(rows: rows, configuration: .default,
            roots: [], revealsRulePreview: false, query: "needle"))
        #expect(restored.rows == cached.rows && restored.mediaPaths == cached.mediaPaths)
        #expect(await filter.visibilityBuildCount == 1)
    }
}

private func searchRow(
    _ id: String, _ name: String, kind: SourceTreeDisplayRow.Kind = .media(dateAdded: nil),
    ancestors: [String] = [], fileName: String? = nil,
    context: String? = nil, media: RecognizedMediaName? = nil
) -> SourceTreeDisplayRow {
    SourceTreeDisplayRow(id: id, folderID: "library", url: URL(fileURLWithPath: "/tmp/browser-search/" + (fileName ?? id + ".mkv")),
        displayName: name, contextLabel: context, recognizedMedia: media,
        depth: ancestors.count, ancestorIDs: ancestors, kind: kind)
}

/// Reference behavior from main 68274d1b09dcc866296321a5a8858efc297c4f19.
/// Keep the original materialization to independently check the set-building
/// optimization; explicit fixtures above also establish expected row contents.
private func legacySearch(_ rows: [SourceTreeDisplayRow], query: String) -> [SourceTreeDisplayRow] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return rows }
    let matchingRows = rows.filter {
        guard !Task.isCancelled else { return false }
        switch $0.kind {
        case .folder, .media:
            if $0.displayName.localizedCaseInsensitiveContains(query) { return true }
            guard let media = $0.recognizedMedia else { return false }
            return $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || media.section.localizedCaseInsensitiveContains(query)
                || media.catalogIDs.contains { $0.localizedCaseInsensitiveContains(query) }
                || ($0.contextLabel?.localizedCaseInsensitiveContains(query) ?? false)
        case .message, .mediaSection:
            return false
        }
    }
    let visibleIDs = Set(matchingRows.flatMap { [$0.id] + $0.ancestorIDs })
    return rows.filter { visibleIDs.contains($0.id) }
}

private struct SearchRandom {
    var state: UInt64
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upperBound))
    }
}

/// Resume only after the test has cancelled the suspended task. No sleeps,
/// timing thresholds, or assumptions about scheduler speed are required.
private actor SearchCancellationGate {
    private var suspended = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            suspended = true
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
        }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        suspension?.resume()
        suspension = nil
    }
}
