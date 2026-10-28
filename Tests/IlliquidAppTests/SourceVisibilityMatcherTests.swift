import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility matcher")
struct SourceVisibilityMatcherTests {
    @Test(arguments: ["none", "disabled", "invalid", "disabled-and-invalid"])
    func pathOnlyRulesPreserveManualPrecedence(ruleState: String) {
        let root = URL(fileURLWithPath: "/media/Series é", isDirectory: true)
        let hidden = root.appendingPathComponent("Hidden.mkv")
        let shown = root.appendingPathComponent("Shown.mkv")
        let ordinary = root.appendingPathComponent("Ordinary.mkv")
        var configuration = SourceVisibilityConfiguration.default
        // Deliberate overlap checks the evaluator's manual-before-always contract,
        // independently of configuration.normalize() removing the overlap.
        configuration.manuallyHiddenPaths = [hidden.path]
        configuration.alwaysShownPaths = [hidden.path, shown.path]
        if ruleState == "disabled" || ruleState == "disabled-and-invalid" {
            configuration.regexRules.append(.init(
                id: "disabled", pattern: ".*", colorIndex: 1, isEnabled: false
            ))
        }
        if ruleState == "invalid" || ruleState == "disabled-and-invalid" {
            configuration.regexRules.append(.init(
                id: "invalid", pattern: "[", colorIndex: 2, isEnabled: true
            ))
        }
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(matcher.evaluate(hidden).hiddenMatches == [.manual])
        #expect(matcher.evaluate(hidden).regexMatches.isEmpty)
        #expect(matcher.evaluate(shown).hiddenMatches.isEmpty)
        #expect(matcher.evaluate(shown).regexMatches.isEmpty)
        #expect(matcher.evaluate(ordinary).hiddenMatches.isEmpty)
        #expect(matcher.evaluate(normalizedPath: hidden.path) == matcher.evaluate(hidden))
        #expect(matcher.evaluate(normalizedPath: shown.path) == matcher.evaluate(shown))
    }

    @Test func nearestRootDefinesRegexSubjectAndAncestorBoundary() {
        let outer = URL(fileURLWithPath: "/media", isDirectory: true)
        let inner = outer.appendingPathComponent("Series 日本", isDirectory: true)
        let season = inner.appendingPathComponent("Season é", isDirectory: true)
        let file = season.appendingPathComponent("Episode 2.mkv")
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [outer.path]
        configuration.regexRules = [
            .init(id: "episode", pattern: #"^Episode 2\.mkv$"#, colorIndex: 3, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(
            configuration: configuration, roots: [outer, inner, season]
        )
        let match = SourceVisibilityRegexMatch(id: "episode", colorIndex: 3)
        #expect(matcher.relativePath(for: file) == "Episode 2.mkv")
        #expect(matcher.relativePath(for: season) == "Season é")
        #expect(matcher.evaluate(file).hiddenMatches == [.regex(match)])
        #expect(matcher.evaluateIncludingAncestors(file).hiddenMatches == [.regex(match)])
        // The outer root's manual rule must not leak above the nearest root.
        configuration.regexRules = []
        let manualOnly = SourceVisibilityMatcher(
            configuration: configuration, roots: [outer, inner, season]
        )
        #expect(manualOnly.evaluateIncludingAncestors(file).hiddenMatches.isEmpty)
    }

    @Test(arguments: ["Café", "Cafe\u{301}", "日本語", "🎬👨‍👩‍👦"])
    func unicodePathsPreserveRelativeSubject(spelling: String) {
        let root = URL(fileURLWithPath: "/media/\(spelling)", isDirectory: true)
        let file = root.appendingPathComponent("季節/Épisode.mkv")
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "unicode", pattern: "^季節/", colorIndex: 4, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(Array(matcher.relativePath(for: file).utf8) == Array("季節/Épisode.mkv".utf8))
        #expect(matcher.evaluate(file).regexMatches == [
            .init(id: "unicode", colorIndex: 4),
        ])
    }

    @Test func rootSlashOutsideRootsAndComponentBoundariesKeepTheirSubjects() {
        let root = URL(fileURLWithPath: "/Movies", isDirectory: true)
        let inside = URL(fileURLWithPath: "/Movies/Season 1/Episode.mkv")
        let sibling = URL(fileURLWithPath: "/Movies2/Season 1/Episode.mkv")
        let outside = URL(fileURLWithPath: "/Elsewhere/Season 1/Episode.mkv")
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "season", pattern: "^Season 1/", colorIndex: 0, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(matcher.relativePath(for: inside) == "Season 1/Episode.mkv")
        #expect(matcher.relativePath(for: sibling) == "Episode.mkv")
        #expect(matcher.relativePath(for: outside) == "Episode.mkv")
        #expect(matcher.evaluate(inside).regexMatches.map(\.id) == ["season"])
        #expect(matcher.evaluate(sibling).regexMatches.isEmpty)
        #expect(matcher.evaluate(outside).regexMatches.isEmpty)

        configuration.regexRules = [
            .init(id: "absolute-root", pattern: #"^Movies/Season 1/"#, colorIndex: 2, isEnabled: true),
        ]
        let filesystemRoot = SourceVisibilityMatcher(
            configuration: configuration, roots: [URL(fileURLWithPath: "/", isDirectory: true)]
        )
        #expect(filesystemRoot.relativePath(for: inside) == "Movies/Season 1/Episode.mkv")
        #expect(filesystemRoot.evaluate(inside).regexMatches.map(\.id) == ["absolute-root"])
    }

    @Test func manualAncestorsOverrideAlwaysShownChildrenAndStopAtRoots() {
        let root = URL(fileURLWithPath: "/media/Shows", isDirectory: true)
        let extras = root.appendingPathComponent("Extras", isDirectory: true)
        let disc = extras.appendingPathComponent("Disc 1", isDirectory: true)
        let child = disc.appendingPathComponent("Featurette.mkv")
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly
        configuration.manuallyHiddenPaths = [extras.path, disc.path]
        configuration.alwaysShownPaths = [child.path]
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(matcher.evaluate(child).hiddenMatches.isEmpty)
        #expect(matcher.evaluateIncludingAncestors(child).hiddenMatches == [.manual])
        #expect(matcher.evaluateIncludingAncestors(normalizedPath: child.path)
            == matcher.evaluateIncludingAncestors(child))

        configuration.manuallyHiddenPaths = [root.path]
        matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(matcher.evaluateIncludingAncestors(child).hiddenMatches == [.manual])

        let outside = URL(fileURLWithPath: "/outside/Hidden/Featurette.mkv")
        configuration.manuallyHiddenPaths = ["/outside/Hidden"]
        matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(matcher.evaluateIncludingAncestors(outside).hiddenMatches.isEmpty)
    }

    @Test func mixedRegexOrderAndAlwaysShowRemainObservable() {
        let root = URL(fileURLWithPath: "/media/Shows", isDirectory: true)
        let hidden = root.appendingPathComponent("Episode 1.mkv")
        let shown = root.appendingPathComponent("Episode 2.mkv")
        let plain = root.appendingPathComponent("Episode 3.mkv")
        let episode = SourceVisibilityRegexMatch(id: "episode", colorIndex: 1)
        let extensionMatch = SourceVisibilityRegexMatch(id: "extension", colorIndex: 4)
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [hidden.path]
        configuration.alwaysShownPaths = [shown.path]
        configuration.regexRules = [
            .init(id: "disabled", pattern: ".*", colorIndex: 0, isEnabled: false),
            .init(id: episode.id, pattern: "Episode", colorIndex: episode.colorIndex, isEnabled: true),
            .init(id: "invalid", pattern: "[", colorIndex: 2, isEnabled: true),
            .init(id: "nonmatching", pattern: "^Missing$", colorIndex: 3, isEnabled: true),
            .init(id: extensionMatch.id, pattern: #"\.mkv$"#,
                  colorIndex: extensionMatch.colorIndex, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        #expect(matcher.evaluate(hidden).hiddenMatches == [
            .manual, .regex(episode), .regex(extensionMatch),
        ])
        #expect(matcher.evaluate(shown).hiddenMatches.isEmpty)
        #expect(matcher.evaluate(shown).regexMatches == [episode, extensionMatch])
        #expect(matcher.evaluate(plain).hiddenMatches == [.regex(episode), .regex(extensionMatch)])
    }

    @Test func ancestorRegexCollectionRetainsDirectThenAncestorOrder() {
        let root = URL(fileURLWithPath: "/media", isDirectory: true)
        let extras = root.appendingPathComponent("Extras", isDirectory: true)
        let child = extras.appendingPathComponent("Disc/Sample.mkv")
        let sample = SourceVisibilityRegexMatch(id: "sample", colorIndex: 2)
        let extra = SourceVisibilityRegexMatch(id: "extras", colorIndex: 1)
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [extras.path]
        configuration.regexRules = [
            .init(id: extra.id, pattern: "^Extras$", colorIndex: extra.colorIndex, isEnabled: true),
            .init(id: sample.id, pattern: #"\.mkv$"#, colorIndex: sample.colorIndex, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        let result = matcher.evaluateIncludingAncestors(child)
        #expect(result.hiddenMatches == [.manual, .regex(extra)])
        #expect(result.regexMatches == [sample, extra])
    }

    @Test func rootRegexEvaluationUsesRootFilename() {
        let root = URL(fileURLWithPath: "/media/Extras", isDirectory: true)
        let child = root.appendingPathComponent("Disc/Featurette.mkv")
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "root", pattern: "^Extras$", colorIndex: 5, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        let rule = SourceVisibilityRegexMatch(id: "root", colorIndex: 5)
        #expect(matcher.evaluate(child).regexMatches.isEmpty)
        #expect(matcher.evaluate(root).regexMatches == [rule])
        #expect(matcher.evaluateIncludingAncestors(child).hiddenMatches == [.regex(rule)])
    }

    @Test func projectionRetainsCountsAndPreviewAnnotations() async throws {
        let root = URL(fileURLWithPath: "/media/Shows", isDirectory: true)
        let rows = ["Episode 1.mkv", "Episode 2.mkv", "Feature.mkv"].map { name in
            let url = root.appendingPathComponent(name)
            return SourceTreeDisplayRow(
                id: "media:\(url.path)", folderID: root.path, url: url,
                displayName: name, visibilityPath: url.path, depth: 0,
                ancestorIDs: [], kind: .media(dateAdded: nil)
            )
        }
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[0].url.path]
        configuration.alwaysShownPaths = [rows[1].url.path]
        configuration.regexRules = [
            .init(id: "episodes", pattern: "Episode", colorIndex: 1, isEnabled: true),
            .init(id: "invalid", pattern: "[", colorIndex: 2, isEnabled: true),
            .init(id: "disabled", pattern: ".*", colorIndex: 3, isEnabled: false),
        ]
        let filter = SourceBrowserFilter()
        let preview = try #require(await filter.project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: true, query: ""
        ))
        var expected = rows
        expected[0].visibility = .init(matches: [
            .manual, .regex(.init(id: "episodes", colorIndex: 1)),
        ], isInherited: false)
        #expect(preview.rows == expected)
        #expect(preview.hiddenCount == 1)
        #expect(preview.regexCounts == ["episodes": 2, "invalid": 0, "disabled": 0])
        #expect(preview.thumbnailCandidates == rows.map(\.url))
        #expect(preview.mediaPaths == Set(rows.map { $0.url.standardizedFileURL.path }))
        #expect(rows[0].visibility == nil)

        let filtered = try #require(await filter.project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        #expect(filtered.rows == Array(rows.dropFirst()))
        #expect(filtered.hiddenCount == 1)
        #expect(filtered.regexCounts == preview.regexCounts)
    }

    @Test func enabledEmptyPatternStillRunsAsARegex() {
        let root = URL(fileURLWithPath: "/media/Shows", isDirectory: true)
        let ordinary = root.appendingPathComponent("Episode.mkv")
        let shown = root.appendingPathComponent("Shown.mkv")
        var configuration = SourceVisibilityConfiguration.default
        configuration.alwaysShownPaths = [shown.path]
        // Direct, unnormalized input is accepted by the matcher. Foundation's
        // valid empty expression matches; it is not an empty compiled-rule list.
        configuration.regexRules = [
            .init(id: "empty-pattern", pattern: "", colorIndex: 2, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
        let rule = SourceVisibilityRegexMatch(id: "empty-pattern", colorIndex: 2)
        #expect(matcher.evaluate(ordinary).hiddenMatches == [.regex(rule)])
        #expect(matcher.evaluate(shown).hiddenMatches.isEmpty)
        #expect(matcher.evaluate(shown).regexMatches == [rule])
    }

    @Test func nonFileURLsHaveNoVisibilityEvaluation() throws {
        let url = try #require(URL(string: "https://example.invalid/Shows/Episode.mkv"))
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "everything", pattern: ".*", colorIndex: 0, isEnabled: true),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [])
        #expect(matcher.evaluate(url).hiddenMatches.isEmpty)
        #expect(matcher.evaluateIncludingAncestors(url).regexMatches.isEmpty)
    }
}
