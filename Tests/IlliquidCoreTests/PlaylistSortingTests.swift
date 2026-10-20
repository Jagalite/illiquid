import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist sorting parity")
struct PlaylistSortingTests {
    @Test func emptySingletonAndPairInputsKeepEveryEntry() throws {
        let fixtures = [
            item("/Media/Episode 2.mkv", marker: 0),
            item("/Media/Episode 10.mkv", marker: 1, dateAdded: date(20)),
            item("/Other/Episode 2.mkv", marker: 2, dateAdded: date(10)),
            item("/Media/Episode 2.mkv", marker: 3),
            try decodedItem(
                try #require(URL(string: "https://example.invalid/Episode%202.mkv?v=1")),
                marker: 4, dateAdded: date(10)
            ),
        ]
        expectOriginalOrder([])
        for lhs in fixtures {
            expectOriginalOrder([lhs])
            for rhs in fixtures {
                expectOriginalOrder([lhs, rhs])
            }
        }
    }

    @Test func numericNameOrderingIgnoresConflictingDates() {
        let one = item("/Media/Episode 1.mkv", marker: 1, dateAdded: date(40))
        let two = item("/Media/Episode 2.mkv", marker: 2, dateAdded: nil)
        let ten = item("/Media/Episode 10.mkv", marker: 10, dateAdded: date(20))
        let twenty = item("/Media/Episode 20.mkv", marker: 20, dateAdded: date(10))
        let input = [twenty, two, ten, one]
        expectCompleteEntries(
            PlaylistMutation.sorted(input, by: .name, ascending: true),
            [one, two, ten, twenty]
        )
        expectCompleteEntries(
            PlaylistMutation.sorted(input, by: .name, ascending: false),
            [twenty, ten, two, one]
        )
        expectOriginalOrder(input)
    }

    @Test func dateOrderingReversesMissingPlacementAndFilenameTies() {
        let earlyTwo = item("/Media/Episode 2.mkv", marker: 0, dateAdded: date(-10))
        let earlyTen = item("/Media/Episode 10.mkv", marker: 1, dateAdded: date(-10))
        let lateOne = item("/Media/Episode 1.mkv", marker: 2, dateAdded: date(20))
        let missingTwo = item("/Media/Episode 2.mkv", marker: 3)
        let missingTen = item("/Media/Episode 10.mkv", marker: 4)
        let input = [missingTen, earlyTen, lateOne, missingTwo, earlyTwo]
        expectCompleteEntries(
            PlaylistMutation.sorted(input, by: .dateAdded, ascending: true),
            [earlyTwo, earlyTen, lateOne, missingTwo, missingTen]
        )
        // Descending swaps the entire comparator: missing dates move first,
        // and the filename fallback reverses within equal or missing dates.
        expectCompleteEntries(
            PlaylistMutation.sorted(input, by: .dateAdded, ascending: false),
            [missingTen, missingTwo, lateOne, earlyTen, earlyTwo]
        )
        expectOriginalOrder(input)
    }

    @Test func normalizedLocalAliasesRemainStableInNameOrder() throws {
        let base = try #require(URL(string: "file:///Media/Caf%C3%A9/"))
        // Keep the basename identical: localized comparison of NFC/NFD
        // basenames differs by platform. Parent paths still test ID normalization.
        let urls = try [
            "file:///Media/Cafe%CC%81/Season/../Movie.mkv",
            "file://localhost/Media/Caf%C3%A9/Movie.mkv",
            "file://LOCALHOST/Media/Cafe%CC%81/Movie.mkv",
            "file:///Media/Caf%C3%A9/Movie.mkv",
        ].map { try #require(URL(string: $0)) } + [
            try #require(URL(string: "Season/../Movie.mkv", relativeTo: base)),
        ]
        let input = try urls.enumerated().map { index, url in
            try decodedItem(url, marker: index, dateAdded: date(Double(index)))
        }
        let first = try #require(input.first)
        for entry in input {
            #expect(entry.id == "/Media/Café/Movie.mkv")
            #expect(entry.url.lastPathComponent.localizedStandardCompare(
                first.url.lastPathComponent
            ) == .orderedSame)
        }
        #expect(input[0].url.absoluteString.contains("/Season/../"))
        for ascending in [true, false] {
            expectCompleteEntries(
                PlaylistMutation.sorted(input, by: .name, ascending: ascending), input
            )
        }
        expectOriginalOrder(input)
    }

    @Test func dateTiesUseLiteralPathsWhileNameTiesUseNormalizedIdentities() throws {
        let urls = try [
            "file:///Caf%C3%A9/Movie.mkv",
            "file:///Cafe%CC%81/Movie.mkv",
            "file:///Caf%C3%A9/Season/../Movie.mkv",
        ].map { try #require(URL(string: $0)) }
        let entries = try urls.enumerated().map { index, url in
            try decodedItem(url, marker: index, dateAdded: date(10))
        }
        for entry in entries { #expect(entry.id == "/Café/Movie.mkv") }
        #expect(entries[0].url.path.compare(
            entries[1].url.path, options: [.literal]
        ) != .orderedSame)
        let input = entries.sorted {
            $0.url.path.compare($1.url.path, options: [.literal]) == .orderedDescending
        }
        let literalAscending = input.sorted {
            $0.url.path.compare($1.url.path, options: [.literal]) == .orderedAscending
        }
        #expect(input.map(ItemReceipt.init) != literalAscending.map(ItemReceipt.init))
        for ascending in [true, false] {
            expectCompleteEntries(
                PlaylistMutation.sorted(input, by: .name, ascending: ascending), input
            )
            expectCompleteEntries(
                PlaylistMutation.sorted(input, by: .dateAdded, ascending: ascending),
                ascending ? literalAscending : input
            )
        }
        expectOriginalOrder(input)
    }

    @Test func remoteNameTiesIncludeTheFullURLButDateTiesKeepInputOrder() throws {
        let urls = try [
            "https://z.example.invalid/Media/Episode%202.mkv?v=1#last",
            "http://a.example.invalid/Media/Episode%202.mkv?v=2#first",
            "https://z.example.invalid/Media/%45pisode%202.mkv?v=0#middle",
            "https://m.example.invalid:8443/Media/Episode%202.mkv?v=3",
        ].map { try #require(URL(string: $0)) }
        let input = try urls.enumerated().map { index, url in
            try decodedItem(url, marker: index)
        }
        let first = try #require(input.first)
        for entry in input {
            #expect(NormalizedFileURL.persistenceKey(for: entry.url) == nil)
            #expect(entry.id == entry.url.absoluteString)
            #expect(entry.url.path.compare(first.url.path, options: [.literal]) == .orderedSame)
        }
        for ascending in [true, false] {
            let expected = input.sorted {
                ascending
                    ? $0.url.absoluteString < $1.url.absoluteString
                    : $1.url.absoluteString < $0.url.absoluteString
            }
            expectCompleteEntries(
                PlaylistMutation.sorted(input, by: .name, ascending: ascending), expected
            )
            expectCompleteEntries(
                PlaylistMutation.sorted(input, by: .dateAdded, ascending: ascending), input
            )
        }
        expectOriginalOrder(input)
    }

    @Test func completeTiesKeepDuplicateEntriesAndTheirMetadataInBothDirections() throws {
        let url = URL(fileURLWithPath: "/Media/Movie.mkv")
        for commonDate in [nil, date(10)] as [Date?] {
            let fixtures = try (0..<129).map { index in
                try decodedItem(url, marker: index, dateAdded: commonDate)
            }
            for count in [2, 3, 16, 64, 129] {
                var input = Array(fixtures.prefix(count))
                // Include both identical records and same-key records carrying
                // distinct subtitle arrays; sorting must not deduplicate either.
                if count > 2 { input[1] = input[0] }
                for order in PlaylistSortOrder.allCases {
                    for ascending in [true, false] {
                        expectCompleteEntries(
                            PlaylistMutation.sorted(input, by: order, ascending: ascending), input
                        )
                    }
                }
            }
        }
    }

    @Test func decodedURLsAndUnsortedDuplicateSubtitlesSurviveReordering() throws {
        let subtitleBase = try #require(URL(string: "https://example.invalid/subtitles/"))
        let rawSubtitles = [
            try #require(URL(string: "../tracks/Caption%2010.ass?lang=fr", relativeTo: subtitleBase)),
            try #require(URL(string: "file:///Subtitles/Season/../Cafe%CC%81%202.srt")),
            URL(fileURLWithPath: "/Subtitles/Caption 2.srt"),
            try #require(URL(string: "../tracks/Caption%2010.ass?lang=fr", relativeTo: subtitleBase)),
        ]
        let decoded = try decodedItem(
            try #require(URL(string: "file://LOCALHOST/Media/Season/../Episode%2010.mkv")),
            marker: 0, dateAdded: date(123.25), subtitles: rawSubtitles
        )
        // URL Codable resolves relative bases while preserving absolute URL
        // spellings. Subsequent sorting must preserve every decoded field.
        #expect(decoded.externalSubtitleURLs.map { Array($0.absoluteString.utf8) }
            == rawSubtitles.map { Array($0.absoluteString.utf8) })
        #expect(decoded.url.absoluteString.contains("/Season/../"))
        let initialized = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode 1.mkv"),
            externalSubtitleURLs: rawSubtitles, dateAdded: date(30)
        )
        #expect(initialized.externalSubtitleURLs.contains { $0.baseURL != nil })
        let input = [
            item("/Media/Episode 20.mkv", marker: 1, dateAdded: date(20)),
            decoded,
            item("/Media/Episode 2.mkv", marker: 2),
            decoded,
            initialized,
        ]
        expectOriginalOrder(input)
        for order in PlaylistSortOrder.allCases {
            for ascending in [true, false] {
                let actual = PlaylistMutation.sorted(input, by: order, ascending: ascending)
                let retained = actual.filter { $0.url.absoluteString == decoded.url.absoluteString }
                expectCompleteEntries(retained, [decoded, decoded])
                expectCompleteEntries(actual.filter { $0.url == initialized.url }, [initialized])
            }
        }
    }

    @Test func unicodeEncodedAndRelativeURLFormsMatchTheOriginalComparator() throws {
        let corpus = try mixedItems()
        expectOriginalOrder(corpus)
        expectOriginalOrder(Array(corpus.reversed()))
        expectOriginalOrder(Array(corpus.dropFirst()) + Array(corpus.prefix(1)))
        for order in PlaylistSortOrder.allCases {
            let ordered = originalSorted(corpus, by: order, ascending: true)
            expectOriginalOrder(ordered)
            expectOriginalOrder(Array(ordered.reversed()))
        }
    }

    @Test func boundedSeededQueuesMatchTheOriginalComparator() throws {
        let corpus = try mixedItems()
        var random = Generator(state: 0x504C41594C495354)
        // Fixed sizes exercise empty, small, and multi-run stable sorts.
        // Sampling with replacement includes repeated identities and records.
        for _ in 0..<4 {
            for count in [0, 1, 2, 3, 8, 17, 32, 64, 129] {
                let input = (0..<count).map { _ in corpus[random.next(upperBound: corpus.count)] }
                expectOriginalOrder(input)
            }
        }
    }

    private func expectOriginalOrder(_ input: [FolderPlaylistItem]) {
        let before = input.map(ItemReceipt.init)
        for order in PlaylistSortOrder.allCases {
            for ascending in [true, false] {
                let expected = originalSorted(input, by: order, ascending: ascending)
                let actual = PlaylistMutation.sorted(input, by: order, ascending: ascending)
                expectCompleteEntries(actual, expected)
            }
        }
        #expect(input.map(ItemReceipt.init) == before)
    }

    private func expectCompleteEntries(_ actual: [FolderPlaylistItem], _ expected: [FolderPlaylistItem]) {
        #expect(actual == expected)
        // URL/String equality may conceal representation changes. Check bytes,
        // relative bases, subtitle order and multiplicity as well as item values.
        #expect(actual.map(ItemReceipt.init) == expected.map(ItemReceipt.init))
    }

    // Frozen original PlaylistMutation.sorted comparator. The oracle does not
    // call the production sorting or natural-ordering helpers.
    private func originalSorted(
        _ items: [FolderPlaylistItem], by order: PlaylistSortOrder, ascending: Bool
    ) -> [FolderPlaylistItem] {
        func precedes(_ lhs: FolderPlaylistItem, _ rhs: FolderPlaylistItem) -> Bool {
            switch order {
            case .name:
                let comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
                if comparison == .orderedSame { return lhs.id < rhs.id }
                return comparison == .orderedAscending
            case .dateAdded:
                switch (lhs.dateAdded, rhs.dateAdded) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    switch lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) {
                    case .orderedAscending:
                        return true
                    case .orderedDescending:
                        return false
                    case .orderedSame:
                        return lhs.url.path.compare(rhs.url.path, options: [.literal]) == .orderedAscending
                    }
                }
            }
        }
        return items.sorted { lhs, rhs in
            ascending ? precedes(lhs, rhs) : precedes(rhs, lhs)
        }
    }

    private func mixedItems() throws -> [FolderPlaylistItem] {
        let names = [
            "Episode 10.mkv", "Episode 2.mkv", "Episode 02.mkv", "Episode 002.mkv",
            "Episode 100000000000000000000.mkv", "episode 2.MKV", "EPISODE 2.mkv",
            "Episode-2.mkv", "Episode_2.mkv", ".Episode 2.mkv",
            "Caf\u{00E9} 2.mkv", "Cafe\u{0301} 2.mkv", "Cafe 10.mkv",
            "\u{0130}stanbul 2.mkv", "Istanbul 10.mkv", "\u{0131}stanbul 1.mkv",
            "第2話.mkv", "第10話.mkv", "الحلقة ٢.mkv", "الحلقة ١٠.mkv",
            "Episode ２.mkv", "Episode １０.mkv", "🎬 2.mkv", "🎬 10.mkv",
            "100% complete #2?.mkv", "brackets [2].mkv", "brackets [10].mkv",
        ]
        let localBase = try #require(URL(string: "file:///Media/"))
        let remoteBase = try #require(URL(string: "https://example.invalid/Media/Season%201/"))
        let urls = names.map { URL(fileURLWithPath: "/Media/\($0)") } + (try [
            "file:///Media/Season/../Episode%202.mkv",
            "file://localhost/Media/Episode%202.mkv",
            "file://media-server.example/Media/Episode%202.mkv",
            "file:///Caf%C3%A9/Episode%202.mkv",
            "file:///Cafe%CC%81/Episode%202.mkv",
            "file:relative.mkv",
            "https://a.example.invalid/Media/Episode%202.mkv?v=1",
            "https://b.example.invalid/Media/Episode%202.mkv?v=2#part",
            "https://example.invalid/Media/Episode%202%2Fmkv",
            "https://example.invalid/",
        ].map { try #require(URL(string: $0)) }) + [
            try #require(URL(string: "Season/../Episode%202.mkv", relativeTo: localBase)),
            try #require(URL(string: "../Season%202/Episode%2010.mkv", relativeTo: remoteBase)),
            try #require(URL(string: "Episode%202.mkv?download=1#preview", relativeTo: remoteBase)),
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/Media/Season 2/", isDirectory: true),
        ]
        let dates: [Date?] = [nil, date(-100), date(10), date(10), .distantPast, .distantFuture]
        return try urls.enumerated().map { index, url in
            try decodedItem(url, marker: index, dateAdded: dates[index % dates.count])
        }
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func item(_ path: String, marker: Int, dateAdded: Date? = nil) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: path),
            externalSubtitleURLs: subtitleURLs(marker: marker), dateAdded: dateAdded
        )
    }

    private func subtitleURLs(marker: Int) -> [URL] {
        [10, 2, 10].map { URL(fileURLWithPath: "/Subtitles/\(marker)/Caption \($0).srt") }
    }

    private func decodedItem(
        _ url: URL, marker: Int, dateAdded: Date? = nil, subtitles: [URL]? = nil
    ) throws -> FolderPlaylistItem {
        // Synthesized decoding bypasses the public initializer's normalization
        // and subtitle sorting, as it does when restoring persisted metadata.
        let payload = RawItemPayload(
            url: url, externalSubtitleURLs: subtitles ?? subtitleURLs(marker: marker), dateAdded: dateAdded
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(payload))
    }

    private struct RawItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private struct URLReceipt: Equatable {
        let relative: [UInt8]
        let absolute: [UInt8]
        let base: [UInt8]?

        init(_ url: URL) {
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

    private struct Generator {
        var state: UInt64

        mutating func next(upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }
}
