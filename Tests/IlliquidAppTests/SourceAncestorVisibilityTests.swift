import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source ancestor visibility reuse")
struct SourceAncestorVisibilityTests {
    @Test func nearestHiddenAncestorWinsAndSiblingsKeepTheirOwnMatches() {
        let parent = "/Library/Series/Season"
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [parent, "/Library/Series"]
        configuration.alwaysShownPaths = [parent + "/first.mkv"]
        configuration.regexRules = [
            rule("first", #"first\.mkv$"#, color: 0),
            rule("second", #"second\.mkv$"#, color: 1),
            rule("parent", "Season$", color: 2),
            rule("grandparent", "Series$", color: 3),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Library")])
        var evaluator = matcher.makeAncestorEvaluator()
        for (file, direct) in [("first.mkv", "first"), ("second.mkv", "second"),
                               ("first.mkv", "first"), ("unmatched.mkv", "")] {
            let expectedRegex = direct.isEmpty ? [match("parent", color: 2)]
                : [match(direct, color: direct == "first" ? 0 : 1), match("parent", color: 2)]
            let expected = SourceVisibilityEvaluation(
                hiddenMatches: [.manual, .regex(match("parent", color: 2))],
                regexMatches: expectedRegex
            )
            let path = parent + "/" + file
            #expect(evaluator.evaluate(normalizedPath: path) == expected)
            #expect(matcher.evaluateIncludingAncestors(normalizedPath: path) == expected)
        }
    }

    @Test func shownParentsPreserveMatchOrderAndHigherAncestorHiding() {
        let parent = "/Library/Series/Season"
        var configuration = SourceVisibilityConfiguration.default
        configuration.alwaysShownPaths = [parent]
        configuration.manuallyHiddenPaths = ["/Library/Series"]
        configuration.regexRules = [
            rule("shared", #"(Episode\.mkv|Season)$"#, color: 0),
            rule("file", #"Episode\.mkv$"#, color: 1),
            rule("parent", "Season$", color: 2),
            rule("grandparent", "Series$", color: 3),
        ]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Library")])
        var evaluator = matcher.makeAncestorEvaluator()
        let hidden: [SourceVisibilityHideMatch] = [.manual, .regex(match("grandparent", color: 3))]
        for _ in 0..<2 {
            #expect(evaluator.evaluate(normalizedPath: parent + "/Episode.mkv") == .init(
                hiddenMatches: hidden,
                regexMatches: [match("shared"), match("file", color: 1),
                               match("parent", color: 2), match("grandparent", color: 3)]
            ))
            #expect(evaluator.evaluate(normalizedPath: parent + "/Other.mkv") == .init(
                hiddenMatches: hidden,
                regexMatches: [match("shared"), match("parent", color: 2), match("grandparent", color: 3)]
            ))
        }
    }

    @Test func directOverridesAndDuplicateDirectMatchesAreNotCollapsed() {
        let parent = "/Library/Season"
        var configuration = SourceVisibilityConfiguration.default
        configuration.alwaysShownPaths = ["/Library", parent, parent + "/shown.mkv"]
        configuration.manuallyHiddenPaths = [parent + "/manual.mkv"]
        // Matcher inputs can be constructed before configuration normalization.
        configuration.regexRules = [rule("same", ".*"), rule("same", ".*")]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Library")])
        var evaluator = matcher.makeAncestorEvaluator()
        let repeated = [match("same"), match("same")]
        let repeatedHidden: [SourceVisibilityHideMatch] = repeated.map { .regex($0) }
        for (file, hidden) in [("manual.mkv", [.manual] + repeatedHidden),
                               ("shown.mkv", []), ("ordinary.mkv", repeatedHidden)] {
            #expect(evaluator.evaluate(normalizedPath: parent + "/" + file) == .init(
                hiddenMatches: hidden, regexMatches: repeated
            ))
        }
    }

    @Test func rootBoundariesAndOverlappingRootsNeverShareIncorrectAncestry() {
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/Library/Collection"]
        let matcher = SourceVisibilityMatcher(
            configuration: configuration,
            roots: [url("/Library"), url("/Library/Collection/Season")]
        )
        var evaluator = matcher.makeAncestorEvaluator()
        // These first two paths have the same parent but different selected
        // roots. The nested root must not inherit a hide from outside that root.
        for (path, hidden) in [
            ("/Library/Collection/Season", false), ("/Library/Collection/other.mkv", true),
            ("/Library/Collection/Season", false), ("/Library/Collection/Season/first.mkv", false),
            ("/Library/Collection/Season/second.mkv", false), ("/Library2/other.mkv", false),
        ] {
            let expected = SourceVisibilityEvaluation(hiddenMatches: hidden ? [.manual] : [], regexMatches: [])
            #expect(evaluator.evaluate(normalizedPath: path) == expected)
            #expect(matcher.evaluateIncludingAncestors(normalizedPath: path) == expected)
        }
        configuration.manuallyHiddenPaths = ["/Movies"]
        let rootMatcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/")])
        var rootEvaluator = rootMatcher.makeAncestorEvaluator()
        for path in ["/Movies/Season/one.mkv", "/Movies/Season/two.mkv", "/Movies2/Season/three.mkv", "/"] {
            #expect(rootEvaluator.evaluate(normalizedPath: path)
                    == rootMatcher.evaluateIncludingAncestors(normalizedPath: path))
        }
    }

    @Test func canonicallyEqualParentsRetainTheirOwnRegexInput() {
        let composed = "/Library/Caf\u{00E9}"
        let decomposed = "/Library/Cafe\u{0301}"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [rule("composed", #"\u00E9$"#)]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Library")])
        var evaluator = matcher.makeAncestorEvaluator()
        let paths = [composed + "/one.mkv", decomposed + "/two.mkv",
                     composed + "/three.mkv", decomposed + "/four.mkv"]
        for path in paths {
            // Compare with each platform's Foundation path/regex behavior.
            #expect(evaluator.evaluate(normalizedPath: path)
                    == matcher.evaluateIncludingAncestors(normalizedPath: path))
        }
    }

    @Test func snapshotsAndValueCopiesRemainIndependentAcrossParentChanges() {
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/Library/First"]
        let firstMatcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Library")])
        var first = firstMatcher.makeAncestorEvaluator()
        _ = first.evaluate(normalizedPath: "/Library/First/Season/one.mkv")
        var copied = first
        configuration.manuallyHiddenPaths = ["/Library/Second"]
        let secondMatcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Library")])
        var second = secondMatcher.makeAncestorEvaluator()
        for path in ["/Library/First/Season/two.mkv", "/Library/Second/Season/three.mkv",
                     "/Library/First/Season/four.mkv"] {
            #expect(first.evaluate(normalizedPath: path)
                    == firstMatcher.evaluateIncludingAncestors(normalizedPath: path))
            #expect(copied.evaluate(normalizedPath: path)
                    == firstMatcher.evaluateIncludingAncestors(normalizedPath: path))
            #expect(second.evaluate(normalizedPath: path)
                    == secondMatcher.evaluateIncludingAncestors(normalizedPath: path))
        }
        #expect(first.evaluate(URL(string: "https://example.invalid/First/movie.mkv")!)
                == .init(hiddenMatches: [], regexMatches: []))
    }

    @Test func cancelledEvaluationUsesTheUncachedCancellationBehavior() async {
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [rule("parent", "Season$"), rule("file", #"\.mkv$"#, color: 1)]
        let root = url("/Library")
        let pair = await Task { [configuration] in
            let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])
            var evaluator = matcher.makeAncestorEvaluator()
            _ = evaluator.evaluate(normalizedPath: "/Library/Series/Season/first.mkv")
            withUnsafeCurrentTask { $0?.cancel() }
            let actual = evaluator.evaluate(normalizedPath: "/Library/Series/Season/second.mkv")
            let expected = matcher.evaluateIncludingAncestors(normalizedPath: "/Library/Series/Season/second.mkv")
            return (actual, expected)
        }.value
        #expect(pair.0 == pair.1)
    }

    @Test func recursiveProjectionRetainsCountsAndRebuildsForChangedRules() async throws {
        let parent = "/Library/Series/Season"
        let urls = [url(parent + "/one.mkv"), url(parent + "/two.mkv"), url("/Library/Other/three.mkv")]
        let rows = urls.enumerated().map { index, url in
            SourceTreeDisplayRow(id: "row-\(index)", folderID: "", url: url,
                displayName: url.lastPathComponent,
                visibilityPath: index == 1 ? nil : url.path,
                depth: 0, ancestorIDs: [], kind: .media(dateAdded: nil))
        }
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly
        configuration.showsHiddenItems = true
        configuration.regexRules = [rule("season", "Season$")]
        let filter = SourceBrowserFilter()
        let first = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [url("/Library")], revealsRulePreview: false, query: ""))
        #expect(first.rows.map(\.id) == rows.map(\.id))
        #expect(first.hiddenCount == 2)
        #expect(first.regexCounts == ["season": 2])
        #expect(first.rows.prefix(2).allSatisfy { $0.visibility?.matches == [.regex(match("season"))] })
        #expect(first.rows[2].visibility == nil)

        configuration.regexRules = [rule("other", "Other$", color: 1)]
        let changed = try #require(await filter.project(rows: rows, configuration: configuration,
            roots: [url("/Library")], revealsRulePreview: false, query: ""))
        #expect(changed.hiddenCount == 1)
        #expect(changed.regexCounts == ["other": 1])
        #expect(changed.rows.prefix(2).allSatisfy { $0.visibility == nil })
        #expect(changed.rows[2].visibility?.matches == [.regex(match("other", color: 1))])
    }

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    private func rule(_ id: String, _ pattern: String, color: Int = 0) -> SourceVisibilityRegexRule {
        .init(id: id, pattern: pattern, colorIndex: color, isEnabled: true)
    }

    private func match(_ id: String, color: Int = 0) -> SourceVisibilityRegexMatch {
        .init(id: id, colorIndex: color)
    }
}
