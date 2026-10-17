import Foundation
import Testing
@testable import IlliquidCore

@Suite("Natural filename ordering")
struct NaturalFilenameOrderingTests {
    @Test func emptyAndSingletonInputsPreserveOriginalURLs() throws {
        #expect(NaturalFilenameOrdering.sort([]).isEmpty)
        let base = try #require(URL(string: "https://example.invalid/shows/season/"))
        let relative = try #require(URL(string: "../Episode%202.mkv?edition=1#scene", relativeTo: base))
        #expect(records(NaturalFilenameOrdering.sort([relative])) == records([relative]))
    }

    @Test func filenameOrderPrecedesDirectoryOrderAndLiteralPathsBreakTies() {
        let early = file("/z/Episode 1.mkv")
        let late = file("/a/Episode 10.mkv")
        let ties = [
            file("/z/Episode 2.mkv"),
            file("/A/Episode 2.mkv"),
            file("/a/Episode 2.mkv"),
        ]
        let expectedTies = ties.sorted {
            $0.path.compare($1.path, options: [.literal]) == .orderedAscending
        }
        let input = [late, ties[0], early, ties[1], ties[2]]
        #expect(records(NaturalFilenameOrdering.sort(input)) == records([early] + expectedTies + [late]))
    }

    @Test func equalComparatorKeysRetainInputOrderAndOriginalURLRepresentation() throws {
        let base = try #require(URL(string: "https://base.example.invalid/shows/"))
        let first = try #require(URL(string: "https://z.example.invalid/shows/Episode%202.mkv?edition=first#scene"))
        let second = try #require(URL(string: "https://a.example.invalid/shows/Episode%202.mkv?edition=second"))
        let relative = try #require(URL(string: "Episode%202.mkv?edition=relative", relativeTo: base))
        // Authority, query, fragment and URL base are deliberately absent from
        // the comparator's keys. They must survive the sort in their input order.
        let ties = [first, relative, file("/shows/Episode 2.mkv"), second, first]
        for lhs in ties {
            for rhs in ties {
                #expect(!NaturalFilenameOrdering.areInIncreasingOrder(lhs, rhs))
            }
        }
        let early = file("/shows/Episode 1.mkv")
        let late = file("/shows/Episode 10.mkv")
        let input = [ties[0], late, ties[1], ties[2], early, ties[3], ties[4]]
        #expect(records(NaturalFilenameOrdering.sort(input)) == records([early] + ties + [late]))
    }

    @Test func caseDiacriticsAndNumericVariantsFollowTheCurrentLocaleComparator() {
        let names = [
            "Episode 2.mkv", "episode 2.mkv", "EPISODE 2.mkv",
            "Episode 02.mkv", "Episode 0002.mkv", "Episode 10.mkv",
            "Épisode 2.mkv", "E\u{301}pisode 2.mkv", "épisode 2.mkv",
            "Äpisode 2.mkv", "Åpisode 2.mkv", "Öpisode 2.mkv",
            "İstanbul 2.mkv", "istanbul 2.mkv", "ıstanbul 2.mkv",
        ]
        let urls = names.enumerated().map { file("/folder-\($0.offset % 3)/\($0.element)") }
        // Exact accent/case collation is locale-dependent. Compare with the
        // existing public ordering rule rather than imposing an English locale.
        expectMatchesPublicComparator(urls)
        expectMatchesPublicComparator(Array(urls.reversed()))
        for lhs in urls {
            for rhs in urls where lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedSame {
                #expect(
                    NaturalFilenameOrdering.areInIncreasingOrder(lhs, rhs)
                        == (lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending)
                )
            }
        }
    }

    @Test func relativeEncodedAndDirectoryURLsMatchPublicComparator() throws {
        let remoteBase = try #require(URL(string: "https://example.invalid/base/season/"))
        let fileBase = URL(fileURLWithPath: "/media/base/season/", isDirectory: true)
        var urls = [
            file("/media/Café/Episode 2.mkv"),
            file("/media/Cafe\u{301}/Episode 10.mkv"),
            file("/media/Season/../Episode 1.mkv"),
            file("/media/Episode%202.mkv"),
            file("/media/Episode #2?.mkv"),
            URL(fileURLWithPath: "/media/Episode 2.mkv", isDirectory: true),
            URL(fileURLWithPath: "/", isDirectory: true),
        ]
        for value in ["../Episode%202.mkv", "Episode%2010.mkv?b=2#part", "./Episode%201.mkv", "../Caf%C3%A9.mkv"] {
            urls.append(try #require(URL(string: value, relativeTo: remoteBase)))
            urls.append(try #require(URL(string: value, relativeTo: fileBase)))
        }
        for value in [
            "https://example.invalid/media/Episode%202.mkv",
            "https://example.invalid/media/Episode%25202.mkv",
            "https://example.invalid/media/Episode%2F2.mkv",
            "https://example.invalid/media/%C3%A9pisode%202.mkv",
        ] {
            urls.append(try #require(URL(string: value)))
        }
        expectMatchesPublicComparator(urls)
        expectMatchesPublicComparator(Array(urls.reversed()))
    }

    @Test func duplicateCountsAndRepeatedSortsPreserveOrder() throws {
        let first = try #require(URL(string: "https://example.invalid/Episode%202.mkv?first"))
        let second = try #require(URL(string: "https://example.invalid/Episode%202.mkv?second"))
        let input = [first, file("/Episode 10.mkv"), first, second, file("/Episode 1.mkv"), second, first]
        let snapshot = records(input)
        let sorted = NaturalFilenameOrdering.sort(input)
        #expect(sorted.count == input.count)
        #expect(sorted.filter { $0 == first }.count == 3)
        #expect(sorted.filter { $0 == second }.count == 2)
        #expect(records(NaturalFilenameOrdering.sort(sorted)) == records(sorted))
        #expect(records(input) == snapshot)
        expectMatchesPublicComparator(input)
    }

    @Test func seededDiverseListsMatchUnchangedPublicComparator() throws {
        let stems = [
            "Episode", "episode", "Épisode", "E\u{301}pisode", "Café", "Cafe\u{301}",
            "第", "🎬 Episode", "Ä", "Å", "Ö", "İ", "ı", "A-B", "A_B", "A.B",
        ]
        let numbers = ["", "0", "1", "01", "2", "02", "0002", "9", "10", "100", "٢", "１２"]
        let extensions = [".mkv", ".MKV", ".mp4", ".srt", ""]
        var corpus: [URL] = []
        for (index, stem) in stems.enumerated() {
            for (numberIndex, number) in numbers.enumerated() {
                corpus.append(file("/root-\((index + numberIndex) % 5)/\(stem) \(number)\(extensions[(index + numberIndex) % extensions.count])"))
            }
        }
        let base = try #require(URL(string: "https://base.example.invalid/root/"))
        corpus.append(try #require(URL(string: "Episode%202.mkv?one", relativeTo: base)))
        corpus.append(try #require(URL(string: "Episode%202.mkv?two", relativeTo: base)))
        corpus.append(try #require(URL(string: "https://other.example.invalid/root/Episode%202.mkv#scene")))
        corpus.append(file("/root/Episode 2.mkv"))

        var random = DeterministicGenerator(state: 0x8D29_5B76_0AE3_C419)
        let counts = [0, 1, 2, 3, 8, 16, 31, 64, 129, 257]
        for iteration in 0..<120 {
            let count = counts[iteration % counts.count]
            var input: [URL] = []
            for _ in 0..<count {
                input.append(corpus[Int(random.next() % UInt64(corpus.count))])
            }
            expectMatchesPublicComparator(input)
        }
    }

    private func file(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    private func expectMatchesPublicComparator(_ input: [URL]) {
        let expected = input.sorted(by: NaturalFilenameOrdering.areInIncreasingOrder)
        #expect(records(NaturalFilenameOrdering.sort(input)) == records(expected))
    }

    private func records(_ urls: [URL]) -> [URLRecord] {
        urls.map {
            URLRecord(
                absoluteString: $0.absoluteString,
                relativeString: $0.relativeString,
                baseString: $0.baseURL?.absoluteString,
                hasDirectoryPath: $0.hasDirectoryPath
            )
        }
    }

    private struct URLRecord: Equatable {
        let absoluteString: String
        let relativeString: String
        let baseString: String?
        let hasDirectoryPath: Bool
    }

    private struct DeterministicGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 16
        }
    }
}
