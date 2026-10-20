import Foundation
import Testing
import IlliquidCore

@Suite("Prepared folder playlist construction")
struct PreparedPlaylistConstructionTests {
    @Test func emptySingletonAndDuplicateListingsKeepCompleteModels() throws {
        let folder = try #require(URL(string: "file://LOCALHOST/tmp/PreparedPlaylist/Season/../"))
        let movie = local("Episode 2.mkv")
        let subtitle = local("Episode 2.en.srt")
        let date = Date(timeIntervalSince1970: 123.25)
        for media in [[], [movie], [movie, movie], [local("Episode 10.mkv"), movie]] {
            for subtitles in [[], [subtitle], [subtitle, subtitle]] {
                expectBaseline(folder: folder, media: media, subtitles: subtitles, dates: [movie: date])
            }
        }
        let empty = expectBaseline(folder: folder, media: [], subtitles: [subtitle])
        #expect(empty.isEmpty)
        #expect(empty.initialIndex(restoring: movie) == nil)
        #expect(URLReceipt(empty.folderURL) == URLReceipt(local("", isDirectory: true)))
    }

    @Test(arguments: [UInt64(0), 1, 0xCAFE_0123_4567, UInt64.max])
    func shuffledSortedAndReverseListingsMatchTheOriginalPipeline(seed: UInt64) throws {
        var random = PreparedPlaylistGenerator(seed: seed)
        let names = [
            "Episode 10.mkv", "Episode 2.mkv", "Episode 02.mkv", "Episode 1.mkv",
            "episode 2.MKV", "Caf\u{00E9} 2.mkv", "Cafe\u{0301} 2.mkv", "Cafe 10.mp4",
            "東京 2.mkv", "東京 10.mkv", "🎬 2.mkv", "🎬 10.mkv", "100% complete #2?.mkv",
        ]
        let corpus = names.map { local($0) } + [local("2/Same.mkv"), local("10/Same.mkv")]
        var media = corpus + (0..<32).map { _ in corpus[Int(random.next() % UInt64(corpus.count))] }
        media.shuffle(using: &random)
        var subtitles = ["Episode 2.en.srt", "Episode 2.fr.srt", "Episode 10.ass",
                         "Café 2.en.srt", "Same.srt", "Unrelated.srt"].map { local($0) }
        subtitles.shuffle(using: &random)
        let dates = metadata(for: corpus)
        let ordered = media.sorted(by: referencePrecedes)
        for input in [media, ordered, Array(ordered.reversed())] {
            for candidates in [[], subtitles, Array(subtitles.reversed())] {
                expectBaseline(folder: local("", isDirectory: true), media: input,
                               subtitles: candidates, dates: dates)
            }
        }
    }

    @Test func canonicalAliasesDeduplicateAfterNormalizationAndUseCanonicalDates() throws {
        let canonical = local("Caf\u{00E9} 2.mkv")
        let raw = try #require(URL(string:
            "file://LOCALHOST/tmp/PreparedPlaylist/Season/../Cafe%CC%81%202.mkv?copy=raw#part"))
        let base = local("Season", isDirectory: true)
        let relative = try #require(URL(string: "../Cafe%CC%81%202.mkv", relativeTo: base))
        let rawDateURL = try #require(URL(string: "file:///tmp/PreparedPlaylist/Season/../Other.mkv"))
        let subtitle = local("Café 2.en.srt")
        let rawSubtitle = try #require(URL(string:
            "file://localhost/tmp/PreparedPlaylist/Season/../Cafe%CC%81%202.en.srt"))
        let date = Date(timeIntervalSince1970: 321.5)
        let dates = [canonical: date, raw: Date(timeIntervalSince1970: 999),
                     rawDateURL: Date(timeIntervalSince1970: 111)]
        let media = [rawDateURL, raw, canonical, relative, local("Cafe\u{0301} 2.mkv")]
        let value = expectBaseline(folder: base.appendingPathComponent("..", isDirectory: true),
                                   media: media, subtitles: [rawSubtitle, subtitle], dates: dates)
        #expect(value.count == 2)
        let item = try #require(value.items.first { $0.url == canonical })
        #expect(item.dateAdded == date)
        #expect(item.externalSubtitleURLs.map(URLReceipt.init) == [URLReceipt(subtitle), URLReceipt(subtitle)])
        let other = try #require(value.items.first { $0.url == local("Other.mkv") })
        #expect(other.dateAdded == nil)
        #expect(value.items.allSatisfy { $0.url.baseURL == nil && ($0.url.host ?? "").isEmpty })
    }

    @Test func equalFilenamesKeepLiteralPathTiesAndAmbiguousSubtitles() {
        let media = ["2", "10", "1"].map { local("\($0)/Same.mkv") }
        let value = expectBaseline(folder: local("", isDirectory: true), media: media + [media[0]],
                                   subtitles: [local("Same.en.srt")], dates: metadata(for: media))
        #expect(value.mediaURLs.map { $0.deletingLastPathComponent().lastPathComponent } == ["1", "10", "2"])
        #expect(value.count == 3)
        #expect(value.items.allSatisfy { $0.externalSubtitleURLs.isEmpty })
    }

    @Test func encodedSegmentsPreserveTheFinalOrderAfterItemNormalization() throws {
        let media = try [
            "file:///tmp/%2E%2E/Episode.mkv",
            "file:///tmp/dir%2F..%2FEpisode.mkv",
            "file:///tmp/PreparedPlaylist/A/%2E%2E/Same.mkv",
            "file:///tmp/PreparedPlaylist/A%2F..%2FZ/Same.mkv",
            "file:///tmp/PreparedPlaylist/B/Same.mkv",
            "file:///tmp/PreparedPlaylist/Z/Same.mkv",
            "file:///tmp/PreparedPlaylist/%252E%252E/Episode.mkv",
            "file:///tmp/PreparedPlaylist/dir%252F..%252FEpisode.mkv",
            "file:///tmp/PreparedPlaylist/%2E/Season/%2E%2E/Episode%202.mkv",
            "file:///tmp/PreparedPlaylist/Season%2F..%2FCafe%CC%81%202.mkv",
            "file:///tmp/PreparedPlaylist/Caf%C3%A9%202.mkv",
            "file:///tmp/PreparedPlaylist/Name%25202.mkv",
            "file:///tmp/PreparedPlaylist/Name%202.mkv",
        ].map { try #require(URL(string: $0)) }
        let subtitles = try [
            "file:///tmp/PreparedPlaylist/Season%2F..%2FEpisode%202.en.srt",
            "file:///tmp/PreparedPlaylist/%2E%2E/Episode.srt",
            "file:///tmp/PreparedPlaylist/Cafe%CC%81%202.en.srt",
        ].map { try #require(URL(string: $0)) }
        var shuffled = media + Array(media.prefix(3))
        var random = PreparedPlaylistGenerator(seed: 0xD075_1A5E)
        shuffled.shuffle(using: &random)
        for input in [media, shuffled, Array(media.reversed()), media.sorted(by: referencePrecedes)] {
            expectBaseline(folder: local("", isDirectory: true), media: input,
                           subtitles: subtitles, dates: metadata(for: media))
        }
        // This trio changes relative path order when item construction resolves
        // a dot segment exposed by the first normalization pass.
        let orderChanging = try [
            "file:///tmp/Z/%2E%2E/A/Same.mkv", "file:///tmp/M/Same.mkv", "file:///tmp/N/Same.mkv",
        ].map { try #require(URL(string: $0)) }
        expectBaseline(folder: local("", isDirectory: true), media: orderChanging,
                       subtitles: [], dates: metadata(for: orderChanging))
    }

    @Test(arguments: [
        "https://example.invalid/tmp/PreparedPlaylist/Movie.mkv",
        "file://archive.example/tmp/PreparedPlaylist/Movie.mkv",
        "file://localhost.example/tmp/PreparedPlaylist/Movie.mkv",
        "file://127.0.0.1/tmp/PreparedPlaylist/Movie.mkv",
        "file://[::1]/tmp/PreparedPlaylist/Movie.mkv",
        "file://user@localhost/tmp/PreparedPlaylist/Movie.mkv",
        "file://user:example@localhost/tmp/PreparedPlaylist/Movie.mkv",
        "file://localhost:1234/tmp/PreparedPlaylist/Movie.mkv",
        "file:relative.mkv", "Movie.mkv",
    ])
    func rejectedAuthoritiesCannotBecomeMediaOrSubtitleIdentities(_ spelling: String) throws {
        let rejectedMedia = try #require(URL(string: spelling))
        let rejectedSubtitle = try #require(URL(string: spelling.replacingOccurrences(of: ".mkv", with: ".srt")))
        let movie = local("Movie.mkv")
        let subtitle = local("Movie.en.srt")
        let value = expectBaseline(folder: local("", isDirectory: true), media: [rejectedMedia, movie],
                                   subtitles: [rejectedSubtitle, subtitle])
        #expect(value.mediaURLs.map(URLReceipt.init) == [URLReceipt(movie)])
        #expect(value.items.first?.externalSubtitleURLs.map(URLReceipt.init) == [URLReceipt(subtitle)])
    }

    @Test func relativeURLsUseTheirAbsoluteAuthorityAndFolderPolicyIsPreserved() throws {
        let rejectedBase = try #require(URL(string: "file://archive.example/tmp/PreparedPlaylist/"))
        let relative = try #require(URL(string: "Movie.mkv", relativeTo: rejectedBase))
        let accepted = [local("Episode 10.mkv"), local("Movie.mkv"), local("Episode 2.mkv")]
        let rawFolder = try #require(URL(string: "file://LOCALHOST/tmp/PreparedPlaylist/Season/../"))
        // Three surviving items exercise prepared construction as well as the
        // public constructor's folder normalization and unsupported-URL fallback.
        for folder in [local("", isDirectory: true), rawFolder, rejectedBase,
                       try #require(URL(string: "https://example.invalid/playlist/"))] {
            let value = expectBaseline(folder: folder, media: [relative] + accepted, subtitles: [])
            #expect(value.mediaURLs.map(URLReceipt.init)
                == accepted.sorted(by: referencePrecedes).map(URLReceipt.init))
            #expect(URLReceipt(value.folderURL) == URLReceipt(NormalizedFileURL.normalize(folder) ?? folder))
        }
    }

    @Test func publicInitializerStillSortsUnpreparedItemsAndPreservesDuplicateMetadata() {
        let items = [20, 2, 1, 2, 10].enumerated().map { offset, episode in
            FolderPlaylistItem(url: local("Episode \(episode).mkv"),
                               externalSubtitleURLs: [local("Caption \(offset).srt")],
                               dateAdded: offset == 3 ? nil : Date(timeIntervalSince1970: Double(offset)))
        }
        let value = FolderPlaylist(folderURL: local("", isDirectory: true), items: items)
        #expect(value.items.map(ItemReceipt.init)
            == items.sorted { referencePrecedes($0.url, $1.url) }.map(ItemReceipt.init))
        #expect(value.mediaURLs.map(\.lastPathComponent) == [
            "Episode 1.mkv", "Episode 2.mkv", "Episode 2.mkv", "Episode 10.mkv", "Episode 20.mkv",
        ])
        #expect(value.items.filter { $0.url == local("Episode 2.mkv") } == [items[1], items[3]])
    }

    @discardableResult
    private func expectBaseline(folder: URL, media: [URL], subtitles: [URL], dates: [URL: Date] = [:]) -> FolderPlaylist {
        let expected = originalPipeline(folder: folder, media: media, subtitles: subtitles, dates: dates)
        let actual = FolderPlaylistDiscovery.makePlaylist(folderURL: folder, mediaURLs: media,
                                                         subtitleURLs: subtitles, metadataDates: dates)
        #expect(actual == expected)
        #expect(URLReceipt(actual.folderURL) == URLReceipt(expected.folderURL))
        #expect(actual.items.map(ItemReceipt.init) == expected.items.map(ItemReceipt.init))
        return actual
    }

    // Preserved construction pipeline from 33fff16155c3472960f88e04c72dfdfdefd56dcf.
    // Its final public constructor must remain independent of the prepared path.
    private func originalPipeline(folder: URL, media: [URL], subtitles: [URL], dates: [URL: Date]) -> FolderPlaylist {
        let normalizedMedia = media.compactMap(NormalizedFileURL.normalize).sorted(by: referencePrecedes)
        let normalizedSubtitles = subtitles.compactMap(NormalizedFileURL.normalize)
        let associations = ExternalSubtitleMatcher.associate(subtitleURLs: normalizedSubtitles, with: normalizedMedia)
        var seen: Set<FolderPlaylistItem.ID> = []
        let items = normalizedMedia.map { url in
            FolderPlaylistItem(url: url, externalSubtitleURLs: associations[url, default: []], dateAdded: dates[url])
        }.filter { seen.insert($0.id).inserted }
        return FolderPlaylist(folderURL: folder, items: items)
    }

    private func referencePrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        switch lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
        }
    }

    private func local(_ path: String, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: "/tmp/PreparedPlaylist/\(path)", isDirectory: isDirectory)
    }

    private func metadata(for urls: [URL]) -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for (index, url) in urls.enumerated() where !index.isMultiple(of: 3) {
            if let normalized = NormalizedFileURL.normalize(url) {
                dates[normalized] = Date(timeIntervalSince1970: Double(index) + 0.25)
            }
        }
        return dates
    }

    private struct URLReceipt: Equatable {
        let absolute: [UInt8]
        let relative: [UInt8]
        let base: [UInt8]?
        init(_ url: URL) {
            absolute = Array(url.absoluteString.utf8)
            relative = Array(url.relativeString.utf8)
            base = url.baseURL.map { Array($0.absoluteString.utf8) }
        }
    }

    private struct ItemReceipt: Equatable {
        let url: URLReceipt
        let subtitles: [URLReceipt]
        let date: Date?
        init(_ item: FolderPlaylistItem) {
            url = URLReceipt(item.url)
            subtitles = item.externalSubtitleURLs.map(URLReceipt.init)
            date = item.dateAdded
        }
    }

    private struct PreparedPlaylistGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
}
