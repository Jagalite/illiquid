import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source tree cache visibility boundaries")
struct SourceTreeVisibilityCacheTests {
    @Test(arguments: SourceVisibilityViewMode.allCases)
    func visibilityChangesMatchFreshProjection(mode: SourceVisibilityViewMode) async throws {
        let fixture = Fixture(mode: mode)
        let filter = SourceBrowserFilter()
        let retained = try #require(await filter.project(
            input: fixture.input, revealsRulePreview: false, query: ""
        ))

        for configuration in fixture.visibilityChanges {
            let input = replacing(fixture.input, visibility: configuration)
            for preview in [false, true] {
                for query in ["", "S01E02", "Movie"] {
                    let actual = try #require(await filter.project(
                        input: input, revealsRulePreview: preview, query: query
                    ))
                    let expected = try #require(await SourceBrowserFilter().project(
                        input: input, revealsRulePreview: preview, query: query
                    ))
                    expectEquivalent(actual, expected)
                }
            }
        }

        // An earlier published projection remains a value snapshot even after
        // later rules change hidden annotations, counts, and search results.
        let original = try #require(await SourceBrowserFilter().project(
            input: fixture.input, revealsRulePreview: false, query: ""
        ))
        expectEquivalent(retained, original)
    }

    @Test(arguments: SourceVisibilityViewMode.allCases)
    func reuseTreeAcrossVisibilityChanges(mode: SourceVisibilityViewMode) async throws {
        let fixture = Fixture(mode: mode)
        let filter = SourceBrowserFilter()
        _ = try #require(await filter.project(
            input: fixture.input, revealsRulePreview: false, query: ""
        ))

        for configuration in fixture.visibilityChanges {
            _ = try #require(await filter.project(
                input: replacing(fixture.input, visibility: configuration),
                revealsRulePreview: false, query: ""
            ))
        }

        #expect(await filter.treeBuildCount == 1)
        #expect(await filter.visibilityBuildCount == fixture.visibilityChanges.count + 1)
    }

    @Test func treeDependenciesRebuildAndMatchFreshProjection() async throws {
        let tree = Fixture(mode: .tree)
        let files = Fixture(mode: .filesOnly)
        let media = Fixture(mode: .media)
        var changedContents = tree.input.directoryContents
        changedContents[tree.seasonID] = [Fixture.entry(tree.episode2)]
        var changedPresence = tree.input.mediaPresence
        changedPresence[tree.emptyID] = true
        var changedExpansion = tree.input.expandedFolderIDs
        changedExpansion.remove(tree.showID)
        var mediaVisibility = tree.input.visibility
        mediaVisibility.viewMode = .media
        let addedFile = tree.root.appendingPathComponent("New Movie (2024).mkv")
        let cases: [(String, SourceTreeProjectionInput, SourceTreeProjectionInput)] = [
            ("items", tree.input, replacing(tree.input,
                items: tree.input.items + [.init(kind: .file, url: addedFile)])),
            ("roots", files.input, replacing(files.input, roots: [files.show])),
            ("directory contents", tree.input, replacing(tree.input,
                directoryContents: changedContents)),
            ("directory errors", tree.input, replacing(tree.input,
                directoryErrors: [tree.seasonID: "Folder unavailable"])),
            ("recursive entries", files.input, replacing(files.input,
                recursiveMediaEntries: files.input.recursiveMediaEntries + [Fixture.entry(addedFile)])),
            ("expanded folders", tree.input, replacing(tree.input,
                expandedFolderIDs: changedExpansion)),
            ("sort configuration", tree.input, replacing(tree.input,
                sortConfiguration: .init(name: .descending, dateCreated: .off, type: .ascending))),
            ("media presence", tree.input, replacing(tree.input, mediaPresence: changedPresence)),
            ("view mode", tree.input, replacing(tree.input, visibility: mediaVisibility)),
            ("enable recognition", files.input, replacing(files.input, visibility: media.input.visibility)),
            ("disable recognition", media.input, replacing(media.input, visibility: files.input.visibility)),
        ]

        for (name, initialInput, replacement) in cases {
            let filter = SourceBrowserFilter()
            let initial = try #require(await filter.project(
                input: initialInput, revealsRulePreview: false, query: ""
            ))
            let actual = try #require(await filter.project(
                input: replacement, revealsRulePreview: false, query: ""
            ))
            let expected = try #require(await SourceBrowserFilter().project(
                input: replacement, revealsRulePreview: false, query: ""
            ))
            expectEquivalent(actual, expected)
            #expect(actual.rows != initial.rows, Comment(rawValue: name))
            #expect(await filter.treeBuildCount == 2, Comment(rawValue: name))

            let repeated = try #require(await filter.project(
                input: replacement, revealsRulePreview: false, query: ""
            ))
            expectEquivalent(repeated, expected)
            #expect(await filter.treeBuildCount == 2, Comment(rawValue: name))
        }
    }

    @Test func cancelledRequestLeavesThePreviousTreeAvailable() async throws {
        let fixture = Fixture(mode: .tree)
        let filter = SourceBrowserFilter()
        let original = try #require(await filter.project(
            input: fixture.input, revealsRulePreview: false, query: ""
        ))
        let replacement = replacing(fixture.input, items: [
            .init(kind: .file, url: fixture.root.appendingPathComponent("Replacement.mkv")),
        ])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await filter.project(
                input: replacement, revealsRulePreview: true, query: "Replacement"
            )
        }
        #expect(await cancelled.value == nil)

        let restored = try #require(await filter.project(
            input: fixture.input, revealsRulePreview: false, query: ""
        ))
        expectEquivalent(restored, original)
        #expect(await filter.treeBuildCount == 1)

        let accepted = try #require(await filter.project(
            input: replacement, revealsRulePreview: false, query: ""
        ))
        #expect(accepted.rows.map(\.displayName) == ["Replacement"])
        #expect(await filter.treeBuildCount == 2)
    }

    private func expectEquivalent(_ actual: SourceBrowserProjection, _ expected: SourceBrowserProjection) {
        #expect(actual.rows == expected.rows)
        #expect(actual.hiddenCount == expected.hiddenCount)
        #expect(actual.regexCounts == expected.regexCounts)
        #expect(actual.thumbnailCandidates == expected.thumbnailCandidates)
        #expect(actual.mediaPaths == expected.mediaPaths)
    }

    private func replacing(
        _ input: SourceTreeProjectionInput,
        items: [SourceTabItem]? = nil,
        visibility: SourceVisibilityConfiguration? = nil,
        roots: [URL]? = nil,
        directoryContents: [String: [SourceTreeEntry]]? = nil,
        directoryErrors: [String: String]? = nil,
        recursiveMediaEntries: [SourceTreeEntry]? = nil,
        expandedFolderIDs: Set<String>? = nil,
        sortConfiguration: SourceTreeSortConfiguration? = nil,
        mediaPresence: [String: Bool]? = nil
    ) -> SourceTreeProjectionInput {
        SourceTreeProjectionInput(
            items: items ?? input.items,
            visibility: visibility ?? input.visibility,
            roots: roots ?? input.roots,
            directoryContents: directoryContents ?? input.directoryContents,
            directoryErrors: directoryErrors ?? input.directoryErrors,
            recursiveMediaEntries: recursiveMediaEntries ?? input.recursiveMediaEntries,
            expandedFolderIDs: expandedFolderIDs ?? input.expandedFolderIDs,
            sortConfiguration: sortConfiguration ?? input.sortConfiguration,
            mediaPresence: mediaPresence ?? input.mediaPresence
        )
    }

    private struct Fixture {
        let root = URL(fileURLWithPath: "/tmp/illiquid-visibility-cache/Library", isDirectory: true)
        let show: URL
        let episode2: URL
        let showID: String
        let seasonID: String
        let emptyID: String
        let input: SourceTreeProjectionInput
        let visibilityChanges: [SourceVisibilityConfiguration]

        init(mode: SourceVisibilityViewMode) {
            show = root.appendingPathComponent("The Show (2020)", isDirectory: true)
            let season = show.appendingPathComponent("Season 01", isDirectory: true)
            let empty = root.appendingPathComponent("Empty", isDirectory: true)
            let movie = root.appendingPathComponent("Movie (2021).mkv")
            let loose = root.deletingLastPathComponent().appendingPathComponent("Loose Movie (2022).mp4")
            let episode1 = season.appendingPathComponent("S01E01.mkv")
            episode2 = season.appendingPathComponent("S01E02.mkv")
            let rootID = SourceTreeIdentity.folderID(for: root)
            showID = SourceTreeIdentity.folderID(for: show)
            seasonID = SourceTreeIdentity.folderID(for: season)
            emptyID = SourceTreeIdentity.folderID(for: empty)
            var configuration = SourceVisibilityConfiguration.default
            configuration.viewMode = mode
            input = SourceTreeProjectionInput(
                items: [.init(kind: .folder, url: root), .init(kind: .file, url: loose)],
                visibility: configuration,
                roots: [root],
                directoryContents: [
                    rootID: [Self.entry(movie), Self.entry(show, folder: true), Self.entry(empty, folder: true)],
                    showID: [Self.entry(season, folder: true)],
                    seasonID: [Self.entry(episode2), Self.entry(episode1)],
                    emptyID: [],
                ],
                directoryErrors: [:],
                recursiveMediaEntries: [Self.entry(movie), Self.entry(episode2), Self.entry(episode1)],
                expandedFolderIDs: [rootID, showID, seasonID, emptyID],
                sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .ascending),
                mediaPresence: [rootID: true, showID: true, seasonID: true, emptyID: false]
            )

            // Exercise both directions of each setting, direct/ancestor hiding,
            // overrides, and changes to rule identity, order, color and enablement.
            var changes: [SourceVisibilityConfiguration] = []
            configuration.showsHiddenItems = true
            changes.append(configuration)
            configuration.manuallyHiddenPaths = [movie.path]
            changes.append(configuration)
            configuration.showsHiddenItems = false
            changes.append(configuration)
            configuration.manuallyHiddenPaths.insert(season.path)
            changes.append(configuration)
            configuration.manuallyHiddenPaths.remove(movie.path)
            configuration.alwaysShownPaths.insert(movie.path)
            changes.append(configuration)
            configuration.alwaysShownPaths.insert(empty.path)
            changes.append(configuration)
            configuration.manuallyHiddenPaths.removeAll()
            changes.append(configuration)
            configuration.regexRules = [.init(id: "episodes", pattern: "S01E", colorIndex: 0, isEnabled: true)]
            changes.append(configuration)
            configuration.alwaysShownPaths.insert(episode2.path)
            changes.append(configuration)
            configuration.regexRules.append(.init(id: "movies", pattern: "Movie", colorIndex: 1, isEnabled: true))
            changes.append(configuration)
            configuration.regexRules[0].isEnabled = false
            changes.append(configuration)
            configuration.regexRules[0] = .init(id: "episodes", pattern: "Season", colorIndex: 3, isEnabled: true)
            changes.append(configuration)
            configuration.regexRules.reverse()
            changes.append(configuration)
            configuration.regexRules.removeFirst()
            changes.append(configuration)
            configuration.regexRules.removeAll()
            changes.append(configuration)
            configuration.alwaysShownPaths.removeAll()
            changes.append(configuration)
            visibilityChanges = changes
        }

        static func entry(_ url: URL, folder: Bool = false) -> SourceTreeEntry {
            .init(url: url, kind: folder ? .folder : .media, dateAdded: nil,
                  creationDate: nil, visibilityPath: SourceVisibilityPath.normalized(url))
        }
    }
}
