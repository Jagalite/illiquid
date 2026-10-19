import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source tree sorting semantics")
struct SourceTreeSortingTests {
    @Test func disabledSortingPreservesMixedInputOrder() {
        let entries = [
            entry("/media/Episode 10.mkv", created: 300),
            entry("/media/Season 2", kind: .folder, created: 100),
            entry("/media/Episode 2.mkv"),
            entry("/media/Season 1", kind: .folder, created: 200),
        ]

        #expect(SourceTreeSorting.sorted(entries, using: configuration()) == entries)
    }

    @Test func emptyAndSingletonInputsAreUnchangedForEveryConfiguration() {
        let singleton = [entry("/media/Episode 2.mkv", marker: 42)]
        for name in SourceTreeSortDirection.allCases {
            for date in SourceTreeSortDirection.allCases {
                for type in SourceTreeSortDirection.allCases {
                    let sort = configuration(name: name, date: date, type: type)
                    #expect(SourceTreeSorting.sorted([], using: sort).isEmpty)
                    #expect(SourceTreeSorting.sorted(singleton, using: sort) == singleton)
                }
            }
        }
    }

    @Test func numericNamesSortNaturallyInBothDirections() {
        let ten = entry("/media/Episode 10.mkv")
        let one = entry("/media/Episode 1.mkv")
        let two = entry("/media/Episode 2.mkv")
        let entries = [ten, one, two]

        #expect(SourceTreeSorting.sorted(entries, using: configuration(name: .ascending))
            == [one, two, ten])
        #expect(SourceTreeSorting.sorted(entries, using: configuration(name: .descending))
            == [ten, two, one])
    }

    @Test func typeSortingTakesPrecedenceOverNamesInBothDirections() {
        let mediaTwo = entry("/media/A 2.mkv")
        let folderTen = entry("/media/Z 10", kind: .folder)
        let mediaOne = entry("/media/A 1.mkv")
        let folderTwo = entry("/media/Z 2", kind: .folder)
        let entries = [mediaTwo, folderTen, mediaOne, folderTwo]

        #expect(SourceTreeSorting.sorted(
            entries, using: configuration(name: .ascending, type: .ascending)
        ) == [folderTwo, folderTen, mediaOne, mediaTwo])
        #expect(SourceTreeSorting.sorted(
            entries, using: configuration(name: .ascending, type: .descending)
        ) == [mediaOne, mediaTwo, folderTwo, folderTen])
    }

    @Test func disabledNameSortingKeepsInputOrderWithinTypeGroups() {
        let mediaTwo = entry("/media/Episode 2.mkv", created: 300)
        let folderTen = entry("/media/Season 10", kind: .folder, created: 200)
        let mediaOne = entry("/media/Episode 1.mkv", created: 100)
        let folderTwo = entry("/media/Season 2", kind: .folder)
        let entries = [mediaTwo, folderTen, mediaOne, folderTwo]

        #expect(SourceTreeSorting.sorted(entries, using: configuration(type: .ascending))
            == [folderTen, folderTwo, mediaTwo, mediaOne])
        #expect(SourceTreeSorting.sorted(entries, using: configuration(type: .descending))
            == [mediaTwo, mediaOne, folderTen, folderTwo])
    }

    @Test func missingCreationDatesRemainLastInBothDirections() {
        let missingFirst = entry("/media/Episode 10.mkv", marker: 1)
        let later = entry("/media/Episode 1.mkv", created: 300)
        let earlier = entry("/media/Episode 2.mkv", created: 100)
        let missingSecond = entry("/media/Episode 0.mkv", marker: 2)
        let entries = [missingFirst, later, earlier, missingSecond]

        #expect(SourceTreeSorting.sorted(entries, using: configuration(date: .ascending))
            == [earlier, later, missingFirst, missingSecond])
        #expect(SourceTreeSorting.sorted(entries, using: configuration(date: .descending))
            == [later, earlier, missingFirst, missingSecond])
        #expect(SourceTreeSorting.sorted(
            entries, using: configuration(name: .ascending, date: .descending)
        ) == [later, earlier, missingSecond, missingFirst])
    }

    @Test func typeThenCreationDateThenNameHasFixedPrecedence() {
        let folderOlderTen = entry("/media/Z 10", kind: .folder, created: 100)
        let folderOlderTwo = entry("/media/Z 2", kind: .folder, created: 100)
        let folderNewer = entry("/media/A 1", kind: .folder, created: 200)
        let folderMissing = entry("/media/A 0", kind: .folder)
        let mediaOlderTen = entry("/media/Episode 10.mkv", created: 100)
        let mediaOlderTwo = entry("/media/Episode 2.mkv", created: 100)
        let mediaNewer = entry("/media/Episode 1.mkv", created: 200)
        let mediaMissing = entry("/media/Episode 0.mkv")
        let entries = [mediaMissing, folderNewer, mediaOlderTen, folderMissing,
                       folderOlderTen, mediaNewer, folderOlderTwo, mediaOlderTwo]

        #expect(SourceTreeSorting.sorted(
            entries, using: configuration(name: .ascending, date: .ascending, type: .ascending)
        ) == [folderOlderTwo, folderOlderTen, folderNewer, folderMissing,
              mediaOlderTwo, mediaOlderTen, mediaNewer, mediaMissing])
        #expect(SourceTreeSorting.sorted(
            entries, using: configuration(name: .descending, date: .descending, type: .descending)
        ) == [mediaNewer, mediaOlderTen, mediaOlderTwo, mediaMissing,
              folderNewer, folderOlderTen, folderOlderTwo, folderMissing])
    }

    @Test func identicalBasenamesUseLiteralFullPathOrderInBothDirections() {
        let parentTwo = entry("/media/Collection 2/Episode 1.mkv")
        let parentTen = entry("/media/Collection 10/Episode 1.mkv")
        let entries = [parentTwo, parentTen]

        // Parent paths use literal ordering, so 10 precedes 2 here.
        #expect(SourceTreeSorting.sorted(entries, using: configuration(name: .ascending))
            == [parentTen, parentTwo])
        #expect(SourceTreeSorting.sorted(entries, using: configuration(name: .descending))
            == [parentTwo, parentTen])
    }

    @Test func canonicallyEquivalentParentPathsRetainLiteralTieBreak() throws {
        let composed = entry("/media/caf\u{00E9}/Episode 1.mkv", marker: 1)
        let decomposed = entry("/media/cafe\u{0301}/Episode 1.mkv", marker: 2)
        let comparison = composed.url.path.compare(decomposed.url.path, options: [.literal])

        // Swift String equality folds canonical equivalents; .literal must not.
        #expect(composed.url.path == decomposed.url.path)
        try #require(comparison != .orderedSame)
        expectFoundationNameOrder(composed, decomposed)
    }

    @Test func unicodeBasenamesKeepFoundationCollation() {
        let names: [(String, String)] = [
            ("Épisode 2.mkv", "E\u{0301}pisode 10.mkv"),
            ("映画 10.mkv", "映画 2.mkv"),
            ("🧪 10.mkv", "🧪 2.mkv"),
            ("İ 2.mkv", "i 10.mkv"),
            ("Episode 02.mkv", "episode 2.mkv"),
        ]
        for (left, right) in names {
            expectFoundationNameOrder(entry("/media/\(left)"), entry("/media/\(right)"))
        }
    }

    @Test func escapedURLComponentsKeepFoundationDecodingAndTieBreaks() throws {
        let urls: [(String, String)] = [
            ("file:///media/Episode%20%31%30.mkv", "file:///media/Episode%202.mkv"),
            ("file:///media/%7A/Episode%201.mkv", "file:///media/a/Episode%201.mkv"),
            ("file:///media/%61/Episode%201.mkv", "file:///media/a/Episode%201.mkv"),
            ("file:///media/100%25%20%23%3F%2010.mkv", "file:///media/100%25%20%23%3F%202.mkv"),
            ("https://example.invalid/media/Z%2F2.mkv", "https://example.invalid/media/A%2F10.mkv"),
        ]
        for (left, right) in urls {
            let leftURL = try #require(URL(string: left))
            let rightURL = try #require(URL(string: right))
            expectFoundationNameOrder(entry(leftURL, marker: 1), entry(rightURL, marker: 2))
        }

        expectFoundationNameOrder(
            entry("/media/%zz/100% Episode #10?.mkv"),
            entry("/media/%2F/100% Episode #2?.mkv")
        )
        expectFoundationNameOrder(
            entry("/media/Season 10/", kind: .folder),
            entry("/media/Season 2/", kind: .folder)
        )
    }

    @Test func completeTiesKeepInputOrderAndMetadataForEveryConfiguration() {
        let url = URL(fileURLWithPath: "/media/Episode 2.mkv", isDirectory: false)
        let entries = (0..<129).reversed().map { marker in
            SourceTreeEntry(
                url: url,
                kind: .media,
                dateAdded: Date(timeIntervalSince1970: TimeInterval(marker)),
                creationDate: Date(timeIntervalSince1970: 100),
                visibilityPath: "/visibility/\(marker)"
            )
        }
        for name in SourceTreeSortDirection.allCases {
            for date in SourceTreeSortDirection.allCases {
                for type in SourceTreeSortDirection.allCases {
                    let sort = configuration(name: name, date: date, type: type)
                    let context = Comment(rawValue: "name=\(name), date=\(date), type=\(type)")
                    #expect(SourceTreeSorting.sorted(entries, using: sort) == entries, context)
                }
            }
        }
    }

    private func expectFoundationNameOrder(_ left: SourceTreeEntry, _ right: SourceTreeEntry) {
        // Foundation owns locale-sensitive name ordering and URL decoding. The
        // expected order intentionally uses its public comparators at runtime.
        let nameComparison = left.url.lastPathComponent.localizedStandardCompare(right.url.lastPathComponent)
        let comparison = nameComparison == .orderedSame
            ? left.url.path.compare(right.url.path, options: [.literal])
            : nameComparison
        for direction in [SourceTreeSortDirection.ascending, .descending] {
            for input in [[left, right], [right, left]] {
                let expected: [SourceTreeEntry]
                if comparison == .orderedSame {
                    expected = input
                } else {
                    let leftFirst = direction == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                    expected = leftFirst ? [left, right] : [right, left]
                }
                let context = Comment(rawValue: "left=\(left.url), right=\(right.url), direction=\(direction)")
                #expect(SourceTreeSorting.sorted(input, using: configuration(name: direction)) == expected, context)
            }
        }
    }

    private func configuration(
        name: SourceTreeSortDirection = .off,
        date: SourceTreeSortDirection = .off,
        type: SourceTreeSortDirection = .off
    ) -> SourceTreeSortConfiguration {
        SourceTreeSortConfiguration(name: name, dateCreated: date, type: type)
    }

    private func entry(
        _ path: String,
        kind: SourceTreeEntry.Kind = .media,
        created: TimeInterval? = nil,
        marker: TimeInterval = 0
    ) -> SourceTreeEntry {
        entry(URL(fileURLWithPath: path, isDirectory: kind == .folder),
              kind: kind, created: created, marker: marker)
    }

    private func entry(
        _ url: URL,
        kind: SourceTreeEntry.Kind = .media,
        created: TimeInterval? = nil,
        marker: TimeInterval = 0
    ) -> SourceTreeEntry {
        SourceTreeEntry(
            url: url,
            kind: kind,
            dateAdded: Date(timeIntervalSince1970: marker),
            creationDate: created.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
