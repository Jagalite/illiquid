import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility root lookup")
struct SourceVisibilityRootLookupTests {
    @Test func longestNestedRootIsIndependentOfInputOrder() {
        let roots = [url("/Media"), url("/Media/TV"), url("/Media/TV/Show"), url("/Archive")]
        let orders = [roots, Array(roots.reversed()), [roots[1], roots[3], roots[2], roots[0]]]
        for order in orders {
            let matcher = SourceVisibilityMatcher(configuration: .default, roots: order)
            expectBytes(matcher.relativePath(normalizedPath: "/Media/TV/Show/Season 1/Episode.mkv"),
                        "Season 1/Episode.mkv")
            expectBytes(matcher.relativePath(normalizedPath: "/Media/TV/Show"), "Show")
            expectBytes(matcher.relativePath(normalizedPath: "/Media/TV/Film.mkv"), "Film.mkv")
            expectBytes(matcher.relativePath(normalizedPath: "/Media/TV/Showcase/Episode.mkv"),
                        "Showcase/Episode.mkv")
        }
    }

    @Test func slashRootAndPrefixBoundariesKeepCompleteRelativePaths() {
        let matcher = SourceVisibilityMatcher(configuration: .default,
            roots: [url("/Movies"), url("/"), url("/Movies/Season")])
        for (path, expected) in [
            ("/Movies/Season/Episode.mkv", "Episode.mkv"),
            ("/Movies/Seasonal/Episode.mkv", "Seasonal/Episode.mkv"),
            ("/Movies2/Episode.mkv", "Movies2/Episode.mkv"),
            ("/Episode.mkv", "Episode.mkv"),
            ("/", "/"),
        ] {
            expectBytes(matcher.relativePath(normalizedPath: path), expected)
        }
        let ordinary = SourceVisibilityMatcher(configuration: .default, roots: [url("/Movies")])
        expectBytes(ordinary.relativePath(normalizedPath: "/Movies2/Season/Episode.mkv"), "Episode.mkv")
        expectBytes(ordinary.relativePath(normalizedPath: "/Movies-old/Episode.mkv"), "Episode.mkv")
    }

    @Test func emptyAndNonfileRootsKeepFilenameFallbacks() throws {
        let remote = try #require(URL(string: "https://example.invalid/Media/Show"))
        let path = "/Media/Show/Season/Episode.mkv"
        for roots in [[URL](), [remote]] {
            let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
            expectBytes(matcher.relativePath(normalizedPath: path), "Episode.mkv")
            expectEvaluation(matcher.evaluateIncludingAncestors(normalizedPath: path), hidden: [], regex: [])
        }
        let mixed = SourceVisibilityMatcher(configuration: .default, roots: [remote, url("/Media")])
        expectBytes(mixed.relativePath(normalizedPath: path), "Show/Season/Episode.mkv")
        expectBytes(mixed.relativePath(for: remote), "Show")
        expectEvaluation(mixed.evaluate(remote), hidden: [], regex: [])
        expectEvaluation(mixed.evaluateIncludingAncestors(remote), hidden: [], regex: [])
    }

    @Test func rootNormalizationAndPercentLikeComponentsRemainLiteral() {
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: [
            url("/Media/Discard/../Shows/./"),
            url("/Media/100% complete/%2F"),
            url("/Media/100% complete/%252F"),
        ])
        expectBytes(matcher.relativePath(normalizedPath: "/Media/Shows/Season/Episode.mkv"),
                    "Season/Episode.mkv")
        expectBytes(matcher.relativePath(normalizedPath: "/Media/100% complete/%2F/Season #1/100%.mkv"),
                    "Season #1/100%.mkv")
        expectBytes(matcher.relativePath(normalizedPath: "/Media/100% complete/%252F/%2E%2E/Episode.mkv"),
                    "%2E%2E/Episode.mkv")
        expectBytes(matcher.relativePath(normalizedPath: "/Media/100% complete/%2F-old/Season/Episode.mkv"),
                    "Episode.mkv")
    }

    @Test func graphemeCountsPreserveExactUnicodeSuffixBytes() {
        let broad = "/Volumes/Café 👩🏽‍💻"
        let nested = broad + "/日本語"
        let rawSuffix = "Se\u{301}rie – 01.mkv"
        let rawPath = "/Volumes/Cafe\u{301} 👩🏽‍💻/日本語/" + rawSuffix
        // Foundation may expose decomposed path bytes even after a composed
        // path is passed to URL. Resolve the expected input independently of
        // the production normalizer and matcher, then retain its exact suffix.
        let expectedURLPath = URL(fileURLWithPath: rawPath.precomposedStringWithCanonicalMapping,
                                  isDirectory: false).path
        let expectedURLSuffix = String(expectedURLPath.split(separator: "/").last!)
        for roots in [[url(broad), url(nested)], [url(nested), url(broad)]] {
            let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
            expectBytes(matcher.relativePath(normalizedPath: rawPath), rawSuffix)
            expectBytes(matcher.relativePath(for: url(rawPath)), expectedURLSuffix)
            expectBytes(matcher.relativePath(normalizedPath: broad + "/別の季節/" + rawSuffix),
                        "別の季節/" + rawSuffix)
        }
    }

    @Test func longestRootControlsDirectAndOrderedAncestorRegexMatches() {
        let episode = SourceVisibilityRegexMatch(id: "episode", colorIndex: 2)
        let rootMatch = SourceVisibilityRegexMatch(id: "root e\u{301}", colorIndex: 4)
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly
        configuration.manuallyHiddenPaths = ["/Media"]
        configuration.regexRules = [
            rule(episode.id, #"^Episode [0-9]+\.mkv$"#, color: episode.colorIndex),
            rule("wrong-broad-root", #"^Show/Episode [0-9]+\.mkv$"#),
            rule(rootMatch.id, "^Show$", color: rootMatch.colorIndex),
            rule("disabled", ".*", enabled: false),
            rule("invalid", "["),
        ]
        for roots in [[url("/Media"), url("/Media/Show")], [url("/Media/Show"), url("/Media")]] {
            let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
            let path = "/Media/Show/Episode 01.mkv"
            expectEvaluation(matcher.evaluate(normalizedPath: path), hidden: [.regex(episode)], regex: [episode])
            expectEvaluation(matcher.evaluateIncludingAncestors(normalizedPath: path),
                             hidden: [.regex(rootMatch)], regex: [episode, rootMatch])
            expectEvaluation(matcher.evaluateIncludingAncestors(url(path)),
                             hidden: [.regex(rootMatch)], regex: [episode, rootMatch])
        }
    }

    @Test func ancestorHidingStopsAtSelectedRootAndKeepsNearestPrecedence() {
        let path = "/Media/Show/Season/Episode.mkv"
        let roots = [url("/Media"), url("/Media/Show")]
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly
        configuration.manuallyHiddenPaths = ["/Media"]
        configuration.alwaysShownPaths = [path]
        let bounded = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        expectEvaluation(bounded.evaluateIncludingAncestors(normalizedPath: path), hidden: [], regex: [])

        let episode = SourceVisibilityRegexMatch(id: "episode", colorIndex: 1)
        let season = SourceVisibilityRegexMatch(id: "season", colorIndex: 3)
        configuration.manuallyHiddenPaths.insert("/Media/Show/Season")
        configuration.regexRules = [
            rule(episode.id, "Episode", color: episode.colorIndex),
            rule(season.id, "^Season$", color: season.colorIndex),
            rule("more-distant-root", "^Show$"),
        ]
        let inherited = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        expectEvaluation(inherited.evaluate(normalizedPath: path), hidden: [], regex: [episode])
        expectEvaluation(inherited.evaluateIncludingAncestors(normalizedPath: path),
                         hidden: [.manual, .regex(season)], regex: [episode, season])
    }

    @Test func matcherKeepsItsInitializationSnapshot() {
        var roots = [url("/Media"), url("/Media/Show")]
        var configuration = SourceVisibilityConfiguration.default
        let season = SourceVisibilityRegexMatch(id: "season", colorIndex: 1)
        configuration.regexRules = [rule(season.id, "^Season/", color: season.colorIndex)]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        roots.removeAll()
        configuration.regexRules.removeAll()

        let path = "/Media/Show/Season/Episode.mkv"
        expectBytes(matcher.relativePath(normalizedPath: path), "Season/Episode.mkv")
        expectEvaluation(matcher.evaluate(normalizedPath: path), hidden: [.regex(season)], regex: [season])
        let changed = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        expectBytes(changed.relativePath(normalizedPath: path), "Episode.mkv")
        expectEvaluation(changed.evaluate(normalizedPath: path), hidden: [], regex: [])
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: false) }

    private func rule(_ id: String, _ pattern: String, color: Int = 0, enabled: Bool = true) -> SourceVisibilityRegexRule {
        .init(id: id, pattern: pattern, colorIndex: color, isEnabled: enabled)
    }

    private func expectBytes(_ actual: String, _ expected: String) {
        #expect(actual.utf8.elementsEqual(expected.utf8))
    }

    private func expectEvaluation(
        _ actual: SourceVisibilityEvaluation,
        hidden: [SourceVisibilityHideMatch], regex: [SourceVisibilityRegexMatch]
    ) {
        #expect(actual == SourceVisibilityEvaluation(hiddenMatches: hidden, regexMatches: regex))
        for (actualMatch, expectedMatch) in zip(actual.regexMatches, regex) {
            expectBytes(actualMatch.id, expectedMatch.id)
        }
        for (actualMatch, expectedMatch) in zip(actual.hiddenMatches, hidden) {
            if case let .regex(actualRule) = actualMatch,
               case let .regex(expectedRule) = expectedMatch {
                expectBytes(actualRule.id, expectedRule.id)
            }
        }
    }
}
