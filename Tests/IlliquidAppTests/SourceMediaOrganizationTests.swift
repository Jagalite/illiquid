import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source media organization")
struct SourceMediaOrganizationTests {
    private func input(_ paths: [String], configuration: SourceVisibilityConfiguration? = nil) -> SourceTreeProjectionInput {
        var visibility = configuration ?? .default
        visibility.viewMode = .media
        return SourceTreeProjectionInput(
            items: paths.map { .init(kind: .file, url: URL(fileURLWithPath: "/tmp/library/" + $0)) },
            visibility: visibility, roots: [URL(fileURLWithPath: "/tmp/library")],
            directoryContents: [:], directoryErrors: [:], recursiveMediaEntries: [], expandedFolderIDs: [],
            sortConfiguration: .init(name: .descending, dateCreated: .off, type: .off))
    }

    @Test func groupingKeepsFilesAndSortsEpisodesNumerically() async throws {
        let paths = ["Show/show.S01E10.mkv", "Show/Season 01/Show.S01E02.1080p.mkv",
                     "Show/Season 01/Show.S01E02.2160p.mkv", "Movie (2020).mkv", "Movie (2020)-trailer.mp4", "home.mp4"]
        let filter = SourceBrowserFilter()
        let projection = try #require(await filter.project(input: input(paths), revealsRulePreview: false, query: ""))
        let files = projection.rows.filter { $0.kind.itemKind == .media }
        #expect(files.count == paths.count)
        #expect(Set(files.map(\.url)).count == paths.count)
        let episodes = files.compactMap(\.recognizedMedia).filter { $0.kind == .episode }
        #expect(episodes.map(\.episode) == [2, 2, 10])
        #expect(projection.rows.contains { $0.displayName == "Movies (1)" })
        #expect(projection.rows.contains { $0.displayName == "Extras (1)" })
        #expect(Set(projection.rows.map(\.id)).count == projection.rows.count)
    }

    @Test func searchUsesShowAndRawFilenameWithoutRebuildingRecognition() async throws {
        let filter = SourceBrowserFilter()
        let snapshot = input(["The Show (2020)/Season 01/S01E02.1080p.mkv", "Movie (2021).mkv"])
        for query in ["The Show", "S01E02.1080p", "Season 1"] {
            let result = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: query))
            #expect(result.rows.filter { $0.kind.itemKind == .media }.count == 1)
            #expect(result.rows.count == 2)
        }
        #expect(await filter.treeBuildCount == 1)
        #expect(await filter.visibilityBuildCount == 1)
    }

    @Test func hiddenAncestorsDoNotLeakGroupTitlesAndPreviewRestoresThem() async throws {
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/tmp/library/Private Show"]
        let snapshot = input(["Private Show/Season 01/S01E01.mkv", "Movie (2020).mkv"], configuration: configuration)
        let filter = SourceBrowserFilter()
        let hidden = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: ""))
        #expect(hidden.hiddenCount == 1)
        #expect(!hidden.rows.contains { $0.displayName.contains("Private Show") })
        let preview = try #require(await filter.project(input: snapshot, revealsRulePreview: true, query: ""))
        #expect(preview.rows.contains { $0.displayName.contains("Private Show") })
        #expect(preview.rows.filter { $0.visibility != nil }.count == 1)
        let absent = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: "Private Show"))
        #expect(absent.rows.isEmpty)
    }

    @Test func recursiveEntriesOverlapExplicitFilesWithoutDuplication() async throws {
        let original = input(["Show/Season 01/S01E02.mkv"])
        let file = original.items[0].url
        let snapshot = SourceTreeProjectionInput(items: original.items, visibility: original.visibility,
            roots: original.roots, directoryContents: [:], directoryErrors: [:],
            recursiveMediaEntries: [.init(url: file, kind: .media, dateAdded: nil, creationDate: nil)],
            expandedFolderIDs: [], sortConfiguration: original.sortConfiguration)
        let result = try #require(await SourceBrowserFilter().project(input: snapshot, revealsRulePreview: false, query: ""))
        #expect(result.rows.filter { $0.kind.itemKind == .media }.map(\.url) == [file])
    }

    @Test func largeLibraryReusesRecognitionForSearch() async throws {
        let paths = (0..<10_000).map { index in
            "Show \(index / 100)/Season 01/S01E\(index % 100).1080p.mkv"
        }
        let snapshot = input(paths)
        let filter = SourceBrowserFilter()
        let clock = ContinuousClock()
        let start = clock.now
        let result = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: ""))
        let recognizedAt = clock.now
        #expect(result.rows.filter { $0.kind.itemKind == .media }.count == paths.count)
        let found = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: "Show 99 ·"))
        #expect(found.rows.filter { $0.kind.itemKind == .media }.count == 100)
        #expect(await filter.treeBuildCount == 1)
        #expect(await filter.visibilityBuildCount == 1)
        print("MEDIA_LIBRARY count=10000 projection=\(start.duration(to: recognizedAt)) search=\(recognizedAt.duration(to: clock.now))")
    }

    @Test func filesystemScanFeedsRecognitionAndExcludesSidecars() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-explorer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let season = root.appendingPathComponent("Show (2020)/Season 01")
        try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
        for filename in ["S01E01.mkv", "S01E01.en.srt", "poster.jpg", ".hidden.mp4"] {
            try Data().write(to: season.appendingPathComponent(filename))
        }
        let entries = SourceRecursiveMediaLoader.read([root])
        #expect(entries.count == 1)
        let original = input([])
        let snapshot = SourceTreeProjectionInput(items: [.init(kind: .folder, url: root)],
            visibility: original.visibility, roots: [root], directoryContents: [:], directoryErrors: [:],
            recursiveMediaEntries: entries, expandedFolderIDs: [], sortConfiguration: original.sortConfiguration)
        let result = try #require(await SourceBrowserFilter().project(input: snapshot, revealsRulePreview: false, query: "Show"))
        #expect(result.rows.count == 2)
        #expect(result.rows.last?.recognizedMedia?.episode == 1)
        #expect(result.rows.last?.recognizedMedia?.year == 2020)
    }

    @Test func sidecarsReachRowsForFoldersAndExplicitFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-sidecars-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("opaque.mkv")
        try Data().write(to: file)
        try Data("<movie><title>Recognized Movie</title><year>1999</year><uniqueid type='imdb'>tt12345</uniqueid></movie>".utf8)
            .write(to: root.appendingPathComponent("opaque.nfo"))
        for roots in [[root], []] {
            let entries = SourceRecursiveMediaLoader.read(roots, files: [file], readsMetadata: true)
            #expect(entries.count == 1)
            #expect(entries.first?.recognizedMedia?.title == "Recognized Movie")
            let snapshot = SourceTreeProjectionInput(items: [.init(kind: .file, url: file)],
                visibility: input([]).visibility, roots: roots, directoryContents: [:], directoryErrors: [:],
                recursiveMediaEntries: entries, expandedFolderIDs: [],
                sortConfiguration: .init(name: .off, dateCreated: .ascending, type: .off))
            let filter = SourceBrowserFilter()
            let result = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: "Recognized Movie"))
            #expect(result.rows.filter { $0.kind.itemKind == .media }.count == 1)
            #expect(result.rows.last?.displayName == "Recognized Movie (1999)")
            #expect(result.rows.last?.contextLabel?.contains("NFO") == true)
            let byID = try #require(await filter.project(input: snapshot, revealsRulePreview: false, query: "tt12345"))
            #expect(byID.rows.count == 2)
            #expect(await filter.treeBuildCount == 1)
        }
        let plain = SourceRecursiveMediaLoader.read([root])
        #expect(plain.first?.recognizedMedia == nil)
    }

    @Test func fileHeavyTabsDeduplicateWatchRootsWithoutLosingDirectories() {
        let items: [SourceTabItem] = (0..<10_000).map {
            .init(kind: .file, url: URL(fileURLWithPath: "/tmp/library/folder\($0 / 2)/file\($0).mkv"))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let roots = SourceTabItems.watchRoots(for: items + [.init(kind: .folder, url: items[0].url.deletingLastPathComponent())])
        #expect(roots.count == 5000)
        #expect(Set(roots.map(\.path)).count == 5000)
        #expect(roots.first == items[0].url.deletingLastPathComponent())
        print("SOURCE_WATCH_ROOTS files=10000 unique_directories=5000 duration=\(start.duration(to: clock.now))")
    }

    @Test func modePersistsWithoutChangingLegacyDefaults() throws {
        let config = input([]).visibility
        #expect(try JSONDecoder().decode(SourceVisibilityConfiguration.self, from: JSONEncoder().encode(config)) == config)
        #expect(SourceVisibilityConfiguration.default.viewMode == .tree)
        #expect(SourceVisibilityViewMode.media.scansRecursively)
        #expect(!SourceVisibilityViewMode.tree.scansRecursively)
    }
}
