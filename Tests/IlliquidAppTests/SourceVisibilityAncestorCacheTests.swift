import Foundation
import Testing
@testable import IlliquidApp

@Suite("Recursive source visibility ancestry")
struct SourceVisibilityAncestorCacheTests {
    private let root = URL(fileURLWithPath: "/media", isDirectory: true)

    @Test func nearestHiddenAncestorWinsAndPreservesMatchOrder() {
        let configuration = configuration(
            rules: [rule("leaf", #"\.mkv$"#, color: 0),
                    rule("shared", #"^Show/"#, color: 1),
                    rule("parent", #"^Show/Season$"#, color: 2),
                    rule("grandparent", #"^Show$"#, color: 3)],
            hidden: ["/media/Show", "/media/Show/Season"]
        )
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])

        for file in ["One.mkv", "Two.mkv", "One.mkv"] {
            let result = matcher.evaluateIncludingAncestors(
                root.appendingPathComponent("Show/Season/\(file)")
            )
            #expect(result.hiddenMatches == [
                .manual, .regex(match("shared", color: 1)), .regex(match("parent", color: 2)),
            ])
            #expect(result.regexMatches == [
                match("leaf", color: 0), match("shared", color: 1), match("parent", color: 2),
            ])
        }
    }

    @Test func alwaysShownFileAndParentDoNotOverrideHiddenGrandparent() {
        let configuration = configuration(
            rules: [rule("leaf", #"\.mkv$"#),
                    rule("parent", #"^Show/Season$"#),
                    rule("grandparent", #"^Show$"#)],
            hidden: ["/media/Show"],
            shown: ["/media/Show/Season", "/media/Show/Season/One.mkv",
                    "/media/Show/Season/Two.mkv"]
        )
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])

        for file in ["One.mkv", "Two.mkv", "One.mkv"] {
            let path = "/media/Show/Season/\(file)"
            #expect(matcher.evaluate(normalizedPath: path).hiddenMatches.isEmpty)
            let result = matcher.evaluateIncludingAncestors(normalizedPath: path)
            #expect(result.hiddenMatches == [.manual, .regex(match("grandparent"))])
            #expect(result.regexMatches == [match("leaf"), match("parent"), match("grandparent")])
        }
    }

    @Test func deepestRootBoundsAncestorRulesAndRelativePaths() {
        let nestedRoot = root.appendingPathComponent("Show", isDirectory: true)
        let configuration = configuration(
            rules: [rule("outer-relative", #"^Show/Season$"#)],
            hidden: [root.path]
        )
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root, nestedRoot])

        for file in ["One.mkv", "Two.mkv", "One.mkv"] {
            let url = nestedRoot.appendingPathComponent("Season/\(file)")
            #expect(matcher.relativePath(for: url) == "Season/\(file)")
            let result = matcher.evaluateIncludingAncestors(url)
            #expect(result.hiddenMatches.isEmpty)
            #expect(result.regexMatches.isEmpty)
        }
    }

    @Test func canonicallyEquivalentAncestorSpellingsMatchFreshEvaluation() {
        let composed = "Caf\u{00e9}"
        let decomposed = "Cafe\u{0301}"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        let configuration = configuration(
            rules: [rule("composed", "^\(composed)$"),
                    rule("decomposed", "^\(decomposed)$")]
        )
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])

        // Foundation may normalize ancestor spellings differently by platform.
        // Cache reuse must preserve that platform's fresh evaluation exactly.
        for parent in [composed, decomposed, composed, decomposed] {
            let path = "/media/\(parent)/Episode.mkv"
            var fresh = SourceVisibilityMatcher(configuration: configuration, roots: [root])
            let expected = fresh.evaluateIncludingAncestors(normalizedPath: path)
            #expect(expected.regexMatches.count == 1)
            #expect(expected.hiddenMatches == expected.regexMatches.map(SourceVisibilityHideMatch.regex))
            let result = matcher.evaluateIncludingAncestors(normalizedPath: path)
            #expect(result == expected)
        }
    }

    @Test func escapedLookingAndUnicodePathsMatchFreshEvaluation() {
        let parents = ["100%2F literal/Season 1", "子/シーズン 1", "Space #? & %/Extras"]
        let configuration = configuration(
            rules: [rule("season", #"Season 1$|シーズン 1$"#),
                    rule("literal-percent", #"%2F literal$"#),
                    rule("extras", #"Extras$"#)]
        )
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])

        for parent in parents + parents.reversed() + parents {
            let url = root.appendingPathComponent(parent).appendingPathComponent("Episode.mkv")
            var fresh = SourceVisibilityMatcher(configuration: configuration, roots: [root])
            #expect(matcher.evaluateIncludingAncestors(url) == fresh.evaluateIncludingAncestors(url))
            #expect(matcher.relativePath(for: url) == "\(parent)/Episode.mkv")
        }
    }

    @Test func broadAncestorInventoryPreservesResultsOnRevisits() {
        let parentCount = 1_100
        let hidden = Set((0..<parentCount).filter { $0.isMultiple(of: 2) }.map {
            "/media/Folder-\($0)/Season"
        })
        let configuration = configuration(
            rules: [rule("season", #"^Folder-[0-9]+/Season$"#)], hidden: hidden
        )
        var matcher = SourceVisibilityMatcher(configuration: configuration, roots: [root])

        // Revisit both early and late parents after a broad first pass, without
        // relying on whether any particular parent remains memoized.
        for index in Array(0..<parentCount) + Array((0..<parentCount).reversed()) {
            let result = matcher.evaluateIncludingAncestors(
                normalizedPath: "/media/Folder-\(index)/Season/Episode.mkv"
            )
            let expected: [SourceVisibilityHideMatch] = index.isMultiple(of: 2)
                ? [.manual, .regex(match("season"))] : [.regex(match("season"))]
            #expect(result.hiddenMatches == expected)
            #expect(result.regexMatches == [match("season")])
        }
    }

    @Test func ruleAndRootChangesRebuildProjectionVisibility() async throws {
        let rows = ["One.mkv", "Two.mkv"].map { file in
            let path = "/media/Show/Season/\(file)"
            return SourceTreeDisplayRow(
                id: path, folderID: "/media/Show/Season",
                url: URL(fileURLWithPath: path), displayName: file,
                visibilityPath: path, depth: 0, ancestorIDs: [], kind: .media(dateAdded: nil)
            )
        }
        let filter = SourceBrowserFilter()
        let original = configuration(rules: [rule("hide", #"^Show/Season$"#)])
        let changed = configuration(rules: [rule("hide", #"^Season$"#)])
        let nestedRoot = root.appendingPathComponent("Show", isDirectory: true)

        for (configuration, roots, hiddenCount) in [
            (original, [root], 2), (changed, [root], 0),
            (changed, [root, nestedRoot], 2), (original, [root], 2),
        ] {
            let result = try #require(await filter.project(
                rows: rows, configuration: configuration, roots: roots,
                revealsRulePreview: false, query: ""
            ))
            #expect(result.hiddenCount == hiddenCount)
            #expect(result.rows.count == rows.count - hiddenCount)
            #expect(result.regexCounts == ["hide": hiddenCount])
        }
    }

    private func configuration(
        rules: [SourceVisibilityRegexRule], hidden: Set<String> = [], shown: Set<String> = []
    ) -> SourceVisibilityConfiguration {
        SourceVisibilityConfiguration(
            viewMode: .filesOnly, showsHiddenItems: false,
            manuallyHiddenPaths: hidden, alwaysShownPaths: shown, regexRules: rules
        )
    }

    private func rule(_ id: String, _ pattern: String, color: Int = 0) -> SourceVisibilityRegexRule {
        SourceVisibilityRegexRule(id: id, pattern: pattern, colorIndex: color, isEnabled: true)
    }

    private func match(_ id: String, color: Int = 0) -> SourceVisibilityRegexMatch {
        SourceVisibilityRegexMatch(id: id, colorIndex: color)
    }
}
