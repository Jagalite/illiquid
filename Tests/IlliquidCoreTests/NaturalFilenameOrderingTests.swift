import Foundation
import Testing
@testable import IlliquidCore

@Suite("Natural filename ordering parity")
struct NaturalFilenameOrderingTests {
    @Test func emptySingletonAndPairInputsKeepEveryValue() throws {
        let urls = [
            URL(fileURLWithPath: "/Media/Episode 2.mkv"),
            URL(fileURLWithPath: "/Media/Episode 10.mkv"),
            URL(fileURLWithPath: "/Other/Episode 2.mkv"),
            try #require(URL(string: "https://example.invalid/Episode%202.mkv?version=1")),
        ]
        expectReferenceOrder([])
        for lhs in urls {
            expectReferenceOrder([lhs])
            for rhs in urls {
                expectReferenceOrder([lhs, rhs])
            }
        }
    }

    @Test func numbersRetainTheirNaturalOrder() {
        let names = ["Episode 20.mkv", "Episode 2.mkv", "Episode 10.mkv", "Episode 1.mkv"]
        let urls = names.map { URL(fileURLWithPath: "/Media/\($0)") }
        #expect(NaturalFilenameOrdering.sort(urls).map(\.lastPathComponent) == [
            "Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv", "Episode 20.mkv",
        ])
        expectReferenceOrder(urls)
    }

    @Test func unicodeCaseAndNumericVariantsMatchTheReference() {
        let urls = mixedFilenameURLs()
        let ordered = urls.sorted(by: referencePrecedes)
        expectReferenceOrder(urls)
        expectReferenceOrder(ordered)
        expectReferenceOrder(Array(ordered.reversed()))
        expectReferenceOrder(Array(urls.dropFirst()) + Array(urls.prefix(1)))
    }

    @Test func identicalNamesUseTheOriginalLiteralPathTieBreak() throws {
        let urls = ["/a/Movie.mkv", "/B/Movie.mkv", "/A/Movie.mkv"].map {
            URL(fileURLWithPath: $0)
        }
        #expect(NaturalFilenameOrdering.sort(urls).map(\.path) == [
            "/A/Movie.mkv", "/B/Movie.mkv", "/a/Movie.mkv",
        ])
        let rawPaths = [
            try #require(URL(string: "file:///Media/Season/../Movie.mkv")),
            try #require(URL(string: "file:///Media/Movie.mkv")),
            URL(fileURLWithPath: "/Caf\u{00E9}/Movie.mkv"),
            URL(fileURLWithPath: "/Cafe\u{0301}/Movie.mkv"),
            URL(fileURLWithPath: "/Media 2/Movie.mkv"),
            URL(fileURLWithPath: "/Media 10/Movie.mkv"),
        ]
        expectReferenceOrder(urls + rawPaths)
        expectReferenceOrder(Array((urls + rawPaths).reversed()))
    }

    @Test func equalRemoteKeysAndExactDuplicatesKeepTheirInputOrder() throws {
        let first = try #require(URL(string: "https://z.example.invalid/Episode%202.mkv?token=b#last"))
        let second = try #require(URL(string: "http://a.example.invalid/Episode%202.mkv?token=a#first"))
        let third = try #require(URL(string: "https://m.example.invalid:8443/Episode%202.mkv?token=c#middle"))
        let urls = [third, first, third, second, first]
        for lhs in urls {
            for rhs in urls {
                #expect(!referencePrecedes(lhs, rhs))
            }
        }
        #expect(NaturalFilenameOrdering.sort(urls).map(URLReceipt.init) == urls.map(URLReceipt.init))
        expectReferenceOrder(urls)
    }

    @Test func relativeEscapedAndRootURLRepresentationsArePreserved() throws {
        let base = try #require(URL(string: "https://example.invalid/Media/Season%201/"))
        let urls = [
            try #require(URL(string: "../Season%202/Episode%2010.mkv", relativeTo: base)),
            try #require(URL(string: "Episode%202.mkv?download=1#preview", relativeTo: base)),
            try #require(URL(string: "https://example.invalid/Media/Episode%202%2Fmkv")),
            try #require(URL(string: "file://localhost/Media/Episode%202.mkv")),
            try #require(URL(string: "https://example.invalid/")),
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/Media/Season 2/", isDirectory: true),
            URL(fileURLWithPath: "/Media/100% complete #2?.mkv"),
            URL(fileURLWithPath: "/Media/Cafe\u{0301}.mkv"),
        ]
        expectReferenceOrder(urls)
        expectReferenceOrder(Array(urls.reversed()))
    }

    @Test func boundedSeededInputsMatchTheOriginalComparator() throws {
        let corpus = mixedFilenameURLs() + [
            try #require(URL(string: "https://a.example.invalid/Episode%202.mkv?v=1")),
            try #require(URL(string: "https://b.example.invalid/Episode%202.mkv?v=2")),
            URL(fileURLWithPath: "/Other/Episode 2.mkv"),
        ]
        var random = Generator(state: 0x4E41545552414C)
        // Sampling with replacement exercises duplicate values as well as
        // different input orders. The maximum input is 64 URLs, in 48 cases.
        for _ in 0..<48 {
            let count = random.next(upperBound: 65)
            let urls = (0..<count).map { _ in corpus[random.next(upperBound: corpus.count)] }
            expectReferenceOrder(urls)
        }
    }

    @Test func playlistSortingPreservesCompleteItemsAndEqualKeyOrder() throws {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let duplicateURL = folder.appendingPathComponent("Episode 2.mkv")
        let subtitleTwo = folder.appendingPathComponent("Episode 2.srt")
        let subtitleTen = folder.appendingPathComponent("Episode 10.srt")
        let first = FolderPlaylistItem(
            url: duplicateURL,
            externalSubtitleURLs: [subtitleTen, subtitleTwo],
            dateAdded: Date(timeIntervalSince1970: 20)
        )
        let second = FolderPlaylistItem(
            url: duplicateURL,
            externalSubtitleURLs: [folder.appendingPathComponent("different.ass")],
            dateAdded: Date(timeIntervalSince1970: 10)
        )
        let remoteOne = FolderPlaylistItem(
            url: try #require(URL(string: "https://z.example.invalid/Episode%202.mkv?version=1")),
            externalSubtitleURLs: [subtitleTen],
            dateAdded: Date(timeIntervalSince1970: 30)
        )
        let remoteTwo = FolderPlaylistItem(
            url: try #require(URL(string: "https://a.example.invalid/Episode%202.mkv?version=2#part")),
            externalSubtitleURLs: [subtitleTwo],
            dateAdded: nil
        )
        // Decoding bypasses the item's initializer. Keep its original media URL
        // and deliberately unsorted subtitles when the playlist reorders items.
        let fixture = ItemFixture(
            url: try #require(URL(string: "file:///Media/Season/../Episode%202.mkv")),
            externalSubtitleURLs: [subtitleTen, subtitleTwo],
            dateAdded: Date(timeIntervalSince1970: 40)
        )
        let decoded = try JSONDecoder().decode(
            FolderPlaylistItem.self, from: JSONEncoder().encode(fixture)
        )
        #expect(decoded.externalSubtitleURLs == [subtitleTen, subtitleTwo])
        let items = [
            FolderPlaylistItem(url: folder.appendingPathComponent("Episode 10.mkv")),
            remoteOne, first, decoded, remoteTwo, second, first,
        ]
        let held = items
        let before = items.map(ItemReceipt.init)
        let expected = items.sorted { referencePrecedes($0.url, $1.url) }
        let playlist = FolderPlaylist(folderURL: folder, items: items)
        #expect(playlist.items == expected)
        #expect(playlist.items.map(ItemReceipt.init) == expected.map(ItemReceipt.init))
        #expect(playlist.items.filter { URLReceipt($0.url) == URLReceipt(duplicateURL) } == [
            first, second, first,
        ])
        #expect(playlist.items.filter { $0.url == remoteOne.url || $0.url == remoteTwo.url } == [
            remoteOne, remoteTwo,
        ])
        #expect(held.map(ItemReceipt.init) == before)
        #expect(items.map(ItemReceipt.init) == before)
        #expect(FolderPlaylist(folderURL: folder, items: playlist.items).items == playlist.items)
    }

    @Test func emptySingletonAndReversedPlaylistsKeepTheirMetadata() {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        #expect(FolderPlaylist(folderURL: folder, items: []).items.isEmpty)
        let items = mixedFilenameURLs().enumerated().map { index, url in
            FolderPlaylistItem(
                url: url,
                externalSubtitleURLs: [folder.appendingPathComponent("Subtitle \(index).srt")],
                dateAdded: index.isMultiple(of: 2) ? Date(timeIntervalSince1970: Double(index)) : nil
            )
        }
        for item in items {
            #expect(FolderPlaylist(folderURL: folder, items: [item]).items == [item])
        }
        let ordered = items.sorted { referencePrecedes($0.url, $1.url) }
        for input in [items, ordered, Array(ordered.reversed())] {
            let expected = input.sorted { referencePrecedes($0.url, $1.url) }
            #expect(FolderPlaylist(folderURL: folder, items: input).items == expected)
        }
    }

    @Test func largePlaylistsKeepEqualKeysPairedWithTheirOriginalMetadata() throws {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let corpus = mixedFilenameURLs() + [
            try #require(URL(string: "file:///Media/Season/../Episode%202.mkv")),
            try #require(URL(string: "https://a.example.invalid/Episode%202.mkv?version=1")),
            try #require(URL(string: "https://b.example.invalid/Episode%202.mkv?version=2#part")),
        ]
        var random = Generator(state: 0x494E444558534F52)
        let mixedURLs = (0..<257).map { _ in corpus[random.next(upperBound: corpus.count)] }
        let equalKeys = (0..<257).map { corpus[corpus.count - 2 + $0 % 2] }
        // Cross multiple sort runs with shuffled key groups and an entirely tied
        // group. Decode once per corpus to retain deliberately unsorted subtitles
        // and raw media-URL spellings that an item reconstruction would change.
        for urls in [mixedURLs, equalKeys] {
            let fixtures = urls.enumerated().map { index, url in
                ItemFixture(
                    url: url,
                    externalSubtitleURLs: [
                        folder.appendingPathComponent("\(index) Subtitle 10.srt"),
                        folder.appendingPathComponent("\(index) Subtitle 2.srt"),
                    ],
                    dateAdded: index.isMultiple(of: 3) ? nil : Date(timeIntervalSince1970: Double(index))
                )
            }
            let items = try JSONDecoder().decode(
                [FolderPlaylistItem].self, from: JSONEncoder().encode(fixtures)
            )
            let before = items.map(ItemReceipt.init)
            for input in [items, Array(items.reversed())] {
                let expected = input.sorted { referencePrecedes($0.url, $1.url) }
                let actual = FolderPlaylist(folderURL: folder, items: input).items
                #expect(actual.map(ItemReceipt.init) == expected.map(ItemReceipt.init))
            }
            #expect(items.map(ItemReceipt.init) == before)
        }
    }

    private func expectReferenceOrder(_ urls: [URL]) {
        let held = urls
        let before = urls.map(URLReceipt.init)
        let expected = urls.sorted(by: referencePrecedes)
        let actual = NaturalFilenameOrdering.sort(urls)
        #expect(actual == expected)
        #expect(actual.map(URLReceipt.init) == expected.map(URLReceipt.init))
        #expect(NaturalFilenameOrdering.sort(actual).map(URLReceipt.init) == actual.map(URLReceipt.init))
        #expect(held.map(URLReceipt.init) == before)
        #expect(urls.map(URLReceipt.init) == before)
    }

    // Frozen pre-optimization comparator. Expected results must not go through
    // production areInIncreasingOrder or a helper shared with the cached sort.
    private func referencePrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        switch lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
        }
    }

    private func mixedFilenameURLs() -> [URL] {
        [
            "Episode 10.mkv", "Episode 2.mkv", "Episode 1.mkv", "Episode 02.mkv",
            "Episode 002.mkv", "Episode 100000000000000000000.mkv",
            "episode 2.MKV", "EPISODE 2.mkv", "Episode-2.mkv", "Episode_2.mkv",
            "Episode 2 part 10.mkv", "Episode 2 part 2.mkv", ".Episode 2.mkv",
            "Caf\u{00E9} 2.mkv", "Cafe\u{0301} 2.mkv", "Cafe 10.mkv",
            "\u{0130}stanbul 2.mkv", "Istanbul 10.mkv", "\u{0131}stanbul 1.mkv",
            "第2話.mkv", "第10話.mkv", "الحلقة ٢.mkv", "الحلقة ١٠.mkv",
            "Episode ２.mkv", "Episode １０.mkv", "🎬 2.mkv", "🎬 10.mkv",
            "100% complete.mkv", "brackets [2].mkv", "brackets [10].mkv",
        ].map { URL(fileURLWithPath: "/Media/\($0)") }
    }

    private struct URLReceipt: Equatable {
        let relative: [UInt8]
        let absolute: [UInt8]
        let base: [UInt8]?

        init(_ url: URL) {
            // Bytes distinguish canonical Unicode spellings which String ==
            // deliberately considers equivalent.
            relative = Array(url.relativeString.utf8)
            absolute = Array(url.absoluteString.utf8)
            base = url.baseURL.map { Array($0.absoluteString.utf8) }
        }
    }

    private struct ItemReceipt: Equatable {
        let url: URLReceipt
        let subtitles: [URLReceipt]
        let dateAdded: Date?

        init(_ item: FolderPlaylistItem) {
            url = URLReceipt(item.url)
            subtitles = item.externalSubtitleURLs.map(URLReceipt.init)
            dateAdded = item.dateAdded
        }
    }

    private struct ItemFixture: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private struct Generator {
        var state: UInt64

        mutating func next(upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state % UInt64(upperBound))
        }
    }
}
