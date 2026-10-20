import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source browser sorting contracts")
struct SourceTreeSortingTests {
    @Test func allCriteriaOffPreservesEveryEntryInItsOriginalPosition() {
        let entries = [
            entry("/media/Episode 10.mkv", created: 300, added: 900),
            entry("/media/Episode 2.mkv", created: nil, visibilityPath: "/first-copy"),
            entry("/media/Season 1", kind: .folder, created: 100),
            entry("/media/Episode 2.mkv", created: 200, visibilityPath: "/second-copy"),
        ]

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .off, dateCreated: .off, type: .off)
        ) == entries)
    }

    @Test(arguments: [SourceTreeSortDirection.ascending, .descending])
    func namesUseNaturalNumericBasenamesBeforeParentPaths(_ direction: SourceTreeSortDirection) {
        let first = entry("/Z/Episode 1.mkv")
        let second = entry("/Y/Episode 2.mkv")
        let tenth = entry("/A/Episode 10.mkv")
        let entries = [tenth, first, second]

        let expected = direction == .ascending
            ? [first, second, tenth]
            : [tenth, second, first]
        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: direction, dateCreated: .off, type: .off)
        ) == expected)
    }

    @Test(arguments: [SourceTreeSortDirection.ascending, .descending])
    func equalBasenamesUseLiteralFullPathsInTheSelectedDirection(_ direction: SourceTreeSortDirection) {
        let seasonOne = entry("/media/Season 1/Episode.mkv")
        let seasonTwo = entry("/media/Season 2/Episode.mkv")
        let seasonTen = entry("/media/Season 10/Episode.mkv")
        let entries = [seasonTwo, seasonOne, seasonTen]

        // The basename uses natural order; its full-path tiebreaker is literal.
        // In particular, "Season 10" precedes "Season 2" for equal basenames.
        let expected = direction == .ascending
            ? [seasonOne, seasonTen, seasonTwo]
            : [seasonTwo, seasonTen, seasonOne]
        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: direction, dateCreated: .off, type: .off)
        ) == expected)
    }

    @Test func typePrecedesCreationDateAndCreationDatePrecedesName() {
        let oldFolderOne = entry("/media/Folder 1", kind: .folder, created: 100)
        let oldFolderTen = entry("/media/Folder 10", kind: .folder, created: 100)
        let newFolderTwo = entry("/media/Folder 2", kind: .folder, created: 300)
        let oldMediaOne = entry("/media/Episode 1.mkv", created: 100)
        let oldMediaTen = entry("/media/Episode 10.mkv", created: 100)
        let newMediaTwo = entry("/media/Episode 2.mkv", created: 300)
        let entries = [
            oldMediaTen, newFolderTwo, newMediaTwo,
            oldFolderTen, oldMediaOne, oldFolderOne,
        ]

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .ascending, dateCreated: .descending, type: .ascending)
        ) == [newFolderTwo, oldFolderOne, oldFolderTen, newMediaTwo, oldMediaOne, oldMediaTen])

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .descending, dateCreated: .ascending, type: .descending)
        ) == [oldMediaTen, oldMediaOne, newMediaTwo, oldFolderTen, oldFolderOne, newFolderTwo])

        // With type disabled, equally dated folders and media share a name sort.
        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .ascending, dateCreated: .descending, type: .off)
        ) == [newMediaTwo, newFolderTwo, oldMediaOne, oldMediaTen, oldFolderOne, oldFolderTen])

        // With name disabled, equally dated entries keep their input order.
        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .off, dateCreated: .ascending, type: .ascending)
        ) == [oldFolderTen, oldFolderOne, newFolderTwo, oldMediaTen, oldMediaOne, newMediaTwo])
    }

    @Test func disabledDatesDoNotAffectTypeAndNameOrdering() {
        let folderOne = entry("/media/Folder 1", kind: .folder, created: 300)
        let folderTen = entry("/media/Folder 10", kind: .folder, created: 100)
        let mediaOne = entry("/media/Episode 1.mkv", created: nil)
        let mediaTen = entry("/media/Episode 10.mkv", created: 200)
        let entries = [mediaTen, folderTen, mediaOne, folderOne]

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .ascending, dateCreated: .off, type: .ascending)
        ) == [folderOne, folderTen, mediaOne, mediaTen])

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .descending, dateCreated: .off, type: .descending)
        ) == [mediaTen, mediaOne, folderTen, folderOne])

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .off, dateCreated: .off, type: .ascending)
        ) == [folderTen, folderOne, mediaTen, mediaOne])
    }

    @Test(arguments: [SourceTreeSortDirection.ascending, .descending])
    func missingDatesStayLastWithinEachKindInEitherDateDirection(_ dateDirection: SourceTreeSortDirection) {
        let oldFolder = entry("/media/Folder 2", kind: .folder, created: 100)
        let newFolder = entry("/media/Folder 3", kind: .folder, created: 300)
        let unknownFolderZero = entry("/media/Folder 0", kind: .folder)
        let unknownFolderOne = entry("/media/Folder 1", kind: .folder)
        let oldMedia = entry("/media/Episode 2.mkv", created: 100)
        let newMedia = entry("/media/Episode 3.mkv", created: 300)
        let unknownMediaZero = entry("/media/Episode 0.mkv")
        let unknownMediaOne = entry("/media/Episode 1.mkv")
        let entries = [
            unknownMediaOne, unknownFolderOne, newMedia, oldFolder,
            oldMedia, newFolder, unknownMediaZero, unknownFolderZero,
        ]
        let expectedFolders = dateDirection == .ascending
            ? [oldFolder, newFolder, unknownFolderZero, unknownFolderOne]
            : [newFolder, oldFolder, unknownFolderZero, unknownFolderOne]
        let expectedMedia = dateDirection == .ascending
            ? [oldMedia, newMedia, unknownMediaZero, unknownMediaOne]
            : [newMedia, oldMedia, unknownMediaZero, unknownMediaOne]

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .ascending, dateCreated: dateDirection, type: .ascending)
        ) == expectedFolders + expectedMedia)

        #expect(SourceTreeSorting.sorted(
            entries, using: .init(name: .ascending, dateCreated: dateDirection, type: .descending)
        ) == expectedMedia + expectedFolders)
    }

    @Test func everyConfigurationPreservesInputPayloadAndTheOrderOfCompleteSortTies() {
        let sharedPath = "/media/Episode 2.mkv"
        let ties = (0..<48).map { index in
            entry(
                sharedPath, created: 200, added: TimeInterval(48 - index),
                visibilityPath: "/payload-\(index)"
            )
        }
        var entries: [SourceTreeEntry] = []
        for (index, tiedEntry) in ties.enumerated() {
            entries.append(tiedEntry)
            if index.isMultiple(of: 8) {
                entries.append(entry(
                    "/media/Other \(index)", kind: .folder,
                    created: index.isMultiple(of: 16) ? nil : 100,
                    added: 500, visibilityPath: "/other-\(index)"
                ))
            }
        }
        let original = entries

        #expect(Self.allConfigurations.count == 27)
        for configuration in Self.allConfigurations {
            let sorted = SourceTreeSorting.sorted(entries, using: configuration)

            // dateAdded and visibilityPath are payload, not hidden sort keys.
            // Duplicate URLs must remain distinct and keep their payload attached.
            #expect(sorted.filter { $0.url.path == sharedPath } == ties)
            #expect(sorted.count == entries.count)
            for entry in original {
                #expect(sorted.filter { $0 == entry }.count == 1)
            }
            #expect(entries == original)
            #expect(SourceTreeSorting.sorted(sorted, using: configuration) == sorted)
        }
    }

    @Test func emptyAndSingletonInputsArePreservedForAllConfigurations() {
        let singleton = [entry(
            "/media/Episode 2.mkv", created: 300, added: 100,
            visibilityPath: "/retained-visibility-path"
        )]

        for configuration in Self.allConfigurations {
            #expect(SourceTreeSorting.sorted([], using: configuration).isEmpty)
            #expect(SourceTreeSorting.sorted(singleton, using: configuration) == singleton)
        }
    }

    private static var allConfigurations: [SourceTreeSortConfiguration] {
        SourceTreeSortDirection.allCases.flatMap { type in
            SourceTreeSortDirection.allCases.flatMap { dateCreated in
                SourceTreeSortDirection.allCases.map { name in
                    SourceTreeSortConfiguration(name: name, dateCreated: dateCreated, type: type)
                }
            }
        }
    }

    private func entry(
        _ path: String,
        kind: SourceTreeEntry.Kind = .media,
        created: TimeInterval? = nil,
        added: TimeInterval? = nil,
        visibilityPath: String? = nil
    ) -> SourceTreeEntry {
        SourceTreeEntry(
            url: URL(fileURLWithPath: path, isDirectory: kind == .folder),
            kind: kind,
            dateAdded: added.map { Date(timeIntervalSince1970: $0) },
            creationDate: created.map { Date(timeIntervalSince1970: $0) },
            visibilityPath: visibilityPath
        )
    }
}
