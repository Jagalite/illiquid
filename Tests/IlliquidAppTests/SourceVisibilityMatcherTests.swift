import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility matcher")
struct SourceVisibilityMatcherTests {
    private func configuration(_ flavor: String) -> SourceVisibilityConfiguration {
        var result = SourceVisibilityConfiguration.default
        switch flavor {
        case "none":
            break
        case "disabled":
            result.regexRules = [
                .init(id: "disabled", pattern: ".*", colorIndex: 1, isEnabled: false),
            ]
        case "invalid":
            // Exercise the matcher's own invalid-rule handling without normalization.
            result.regexRules = [
                .init(id: "invalid", pattern: "[", colorIndex: 2, isEnabled: true),
            ]
        default:
            preconditionFailure("Unknown rule fixture")
        }
        return result
    }

    @Test(arguments: ["none", "disabled", "invalid"])
    func ruleFreeConfigurationsPreserveManualPrecedence(flavor: String) {
        let root = URL(fileURLWithPath: "/tmp/source-visibility", isDirectory: true)
        let hidden = root.appendingPathComponent("Hidden.mkv")
        let shown = root.appendingPathComponent("Shown.mkv")
        let collision = root.appendingPathComponent("Both.mkv")
        let ordinary = root.appendingPathComponent("Ordinary.mkv")
        let outside = URL(fileURLWithPath: "/tmp/outside/Ordinary.mkv")
        var settings = configuration(flavor)
        settings.manuallyHiddenPaths = [hidden.path, collision.path]
        settings.alwaysShownPaths = [shown.path, collision.path]
        let matcher = SourceVisibilityMatcher(configuration: settings, roots: [root])

        let cases: [(URL, [SourceVisibilityHideMatch])] = [
            (hidden, [.manual]), (shown, []), (collision, [.manual]),
            (ordinary, []), (outside, []),
        ]
        for (url, matches) in cases {
            let expected = SourceVisibilityEvaluation(hiddenMatches: matches, regexMatches: [])
            #expect(matcher.evaluate(url) == expected)
            #expect(matcher.evaluate(normalizedPath: url.path) == expected)
            #expect(matcher.evaluateIncludingAncestors(url) == expected)
        }

        let remote = URL(string: "https://example.invalid/Hidden.mkv")!
        let empty = SourceVisibilityEvaluation(hiddenMatches: [], regexMatches: [])
        #expect(matcher.evaluate(remote) == empty)
        #expect(matcher.evaluateIncludingAncestors(remote) == empty)
    }

    @Test(arguments: ["none", "disabled", "invalid"])
    func hiddenRootsAndAncestorsStillHideAlwaysShownChildren(flavor: String) {
        for rootPath in ["/tmp/source-visibility", "/"] {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let folder = root.appendingPathComponent("Private", isDirectory: true)
            let file = folder.appendingPathComponent("Season 01/Clip.mkv")
            var settings = configuration(flavor)
            settings.manuallyHiddenPaths = [folder.path]
            settings.alwaysShownPaths = [file.path]
            var matcher = SourceVisibilityMatcher(configuration: settings, roots: [root])

            #expect(matcher.evaluate(file).hiddenMatches.isEmpty)
            #expect(matcher.evaluateIncludingAncestors(file) ==
                SourceVisibilityEvaluation(hiddenMatches: [.manual], regexMatches: []))

            settings.manuallyHiddenPaths = [root.path]
            matcher = SourceVisibilityMatcher(configuration: settings, roots: [root])
            #expect(matcher.evaluate(root).hiddenMatches == [.manual])
            #expect(matcher.evaluateIncludingAncestors(root).hiddenMatches == [.manual])
            #expect(matcher.evaluateIncludingAncestors(normalizedPath: file.path) ==
                SourceVisibilityEvaluation(hiddenMatches: [.manual], regexMatches: []))

            if rootPath != "/" {
                let neighbor = URL(fileURLWithPath: "/tmp/source-visibility-other/Clip.mkv")
                #expect(matcher.evaluateIncludingAncestors(neighbor).hiddenMatches.isEmpty)
            }
        }
    }

    @Test
    func enabledRulesRetainMatchesAndOrderAcrossManualOverrides() {
        let root = URL(fileURLWithPath: "/tmp/source-visibility", isDirectory: true)
        let file = root.appendingPathComponent("Clip.mkv")
        let name = SourceVisibilityRegexMatch(id: "name", colorIndex: 3)
        let suffix = SourceVisibilityRegexMatch(id: "suffix", colorIndex: 4)
        var settings = SourceVisibilityConfiguration.default
        settings.regexRules = [
            .init(id: "disabled", pattern: ".*", colorIndex: 0, isEnabled: false),
            .init(id: "invalid", pattern: "[", colorIndex: 1, isEnabled: true),
            .init(id: name.id, pattern: "Clip", colorIndex: name.colorIndex, isEnabled: true),
            .init(id: suffix.id, pattern: "\\.mkv$", colorIndex: suffix.colorIndex, isEnabled: true),
        ]

        var matcher = SourceVisibilityMatcher(configuration: settings, roots: [root])
        #expect(matcher.evaluate(file) == SourceVisibilityEvaluation(
            hiddenMatches: [.regex(name), .regex(suffix)], regexMatches: [name, suffix]))

        settings.manuallyHiddenPaths = [file.path]
        settings.alwaysShownPaths = [file.path]
        matcher = SourceVisibilityMatcher(configuration: settings, roots: [root])
        #expect(matcher.evaluate(file) == SourceVisibilityEvaluation(
            hiddenMatches: [.manual, .regex(name), .regex(suffix)], regexMatches: [name, suffix]))

        settings.manuallyHiddenPaths = []
        matcher = SourceVisibilityMatcher(configuration: settings, roots: [root])
        #expect(matcher.evaluate(file) == SourceVisibilityEvaluation(
            hiddenMatches: [], regexMatches: [name, suffix]))
        #expect(matcher.evaluateIncludingAncestors(file) == matcher.evaluate(file))
    }

    @Test
    func overlappingUnicodeRootsKeepRelativeNamesAndRootRuleMatches() {
        let outer = URL(fileURLWithPath: "/tmp/図書館", isDirectory: true)
        let inner = outer.appendingPathComponent("Café", isDirectory: true)
        let file = inner.appendingPathComponent("映像.mkv")
        let decomposed = URL(fileURLWithPath: "/tmp/図書館/Cafe\u{301}/映像.mkv")
        let neighbor = outer.appendingPathComponent("Café2/映像.mkv")
        let direct = SourceVisibilityRegexMatch(id: "file", colorIndex: 1)
        let inherited = SourceVisibilityRegexMatch(id: "root", colorIndex: 2)
        var settings = SourceVisibilityConfiguration.default
        settings.regexRules = [
            .init(id: direct.id, pattern: "^映像\\.mkv$", colorIndex: direct.colorIndex, isEnabled: true),
            .init(id: inherited.id, pattern: "^Café$", colorIndex: inherited.colorIndex, isEnabled: true),
        ]

        for roots in [[outer, inner], [inner, outer]] {
            let matcher = SourceVisibilityMatcher(configuration: settings, roots: roots)
            for url in [file, decomposed] {
                #expect(matcher.relativePath(for: url) == "映像.mkv")
                #expect(matcher.evaluate(url) == SourceVisibilityEvaluation(
                    hiddenMatches: [.regex(direct)], regexMatches: [direct]))
                #expect(matcher.evaluateIncludingAncestors(url) == SourceVisibilityEvaluation(
                    hiddenMatches: [.regex(inherited)], regexMatches: [direct, inherited]))
            }
            #expect(matcher.relativePath(for: neighbor) == "Café2/映像.mkv")
            #expect(matcher.evaluateIncludingAncestors(neighbor).hiddenMatches.isEmpty)
        }
    }

    @Test(arguments: [SourceVisibilityViewMode.tree, .filesOnly, .media])
    func ruleFreePreviewAndVisibilityEditsPreserveProjection(mode: SourceVisibilityViewMode) async throws {
        let root = URL(fileURLWithPath: "/tmp/visibility-integration", isDirectory: true)
        let folder = root.appendingPathComponent("Private", isDirectory: true)
        let hiddenURL = folder.appendingPathComponent("Hidden.mp4")
        let visibleURL = root.appendingPathComponent("Visible.mp4")
        let rootID = SourceTreeIdentity.folderID(for: root)
        let folderID = SourceTreeIdentity.folderID(for: folder)
        func entry(_ url: URL, folder: Bool = false) -> SourceTreeEntry {
            SourceTreeEntry(url: url, kind: folder ? .folder : .media,
                dateAdded: nil, creationDate: nil, visibilityPath: url.path)
        }
        func input(_ settings: SourceVisibilityConfiguration) -> SourceTreeProjectionInput {
            SourceTreeProjectionInput(
                items: [.init(kind: .folder, url: root)], visibility: settings, roots: [root],
                directoryContents: [
                    rootID: [entry(folder, folder: true), entry(visibleURL)],
                    folderID: [entry(hiddenURL)],
                ],
                directoryErrors: [:],
                recursiveMediaEntries: [entry(hiddenURL), entry(visibleURL)],
                expandedFolderIDs: [rootID, folderID],
                sortConfiguration: .init(name: .off, dateCreated: .off, type: .off))
        }

        for flavor in ["none", "disabled", "invalid"] {
            var settings = configuration(flavor)
            settings.viewMode = mode
            settings.manuallyHiddenPaths = [folder.path]
            settings.alwaysShownPaths = [hiddenURL.path]
            let filter = SourceBrowserFilter()
            let hidden = try #require(await filter.project(
                input: input(settings), revealsRulePreview: false, query: ""))
            #expect(hidden.rows.filter { $0.kind.itemKind == .media }.map(\.url) == [visibleURL])
            #expect(hidden.hiddenCount == (mode == .tree ? 2 : 1))
            #expect(hidden.mediaPaths == [visibleURL.path])
            #expect(hidden.thumbnailCandidates == [visibleURL])
            let counts = Dictionary(uniqueKeysWithValues: settings.regexRules.map { ($0.id, 0) })
            #expect(hidden.regexCounts == counts)

            let preview = try #require(await filter.project(
                input: input(settings), revealsRulePreview: true, query: ""))
            #expect(Set(preview.rows.filter { $0.kind.itemKind == .media }.map(\.url)) ==
                Set([hiddenURL, visibleURL]))
            #expect(preview.hiddenCount == hidden.hiddenCount)
            #expect(preview.regexCounts == counts)
            #expect(preview.mediaPaths == [hiddenURL.path, visibleURL.path])
            #expect(Set(preview.thumbnailCandidates) == Set([hiddenURL, visibleURL]))
            let hiddenRow = try #require(preview.rows.first {
                $0.url == hiddenURL && $0.kind.itemKind == .media
            })
            #expect(hiddenRow.visibility?.matches == [.manual])
            #expect(hiddenRow.visibility?.isInherited == (mode == .tree))

            settings.showsHiddenItems = true
            let shown = try #require(await filter.project(
                input: input(settings), revealsRulePreview: false, query: ""))
            #expect(shown.rows == preview.rows)
            #expect(shown.hiddenCount == preview.hiddenCount)
            #expect(shown.mediaPaths == preview.mediaPaths)
            #expect(shown.thumbnailCandidates == preview.thumbnailCandidates)

            settings.manuallyHiddenPaths = []
            settings.showsHiddenItems = false
            let restored = try #require(await filter.project(
                input: input(settings), revealsRulePreview: false, query: ""))
            #expect(restored.hiddenCount == 0)
            #expect(restored.rows.allSatisfy { $0.visibility == nil })
            #expect(restored.mediaPaths == [hiddenURL.path, visibleURL.path])
            #expect(await filter.treeBuildCount == 1)
            #expect(preview.rows.first {
                $0.url == hiddenURL && $0.kind.itemKind == .media
            }?.visibility?.matches == [.manual])
        }
    }
}
