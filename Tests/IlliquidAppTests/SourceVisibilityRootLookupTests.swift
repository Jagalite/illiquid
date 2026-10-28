import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility root lookup")
struct SourceVisibilityRootLookupTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 32])
    func smallAndLargeLibrariesMatchOriginalSelection(rootCount: Int) {
        let candidates = [
            "/library", "/library/Shows", "/library/Shows/Season 01",
            "/library/Shows Extra", "/"
        ] + (0..<27).map { "/other/\($0)" }
        let roots = urls(Array(candidates.prefix(rootCount)))
        let paths = [
            "/", "/library", "/library/Shows", "/library/Shows/Season 01",
            "/library/Shows/Season 01/Episode 01.mkv",
            "/library/Shows/Season 010/Episode 02.mkv",
            "/library/Shows Extra/Movie.mkv", "/library-extra/Movie.mkv",
            "/elsewhere/Film.mkv"
        ]
        expectOriginalResults(roots: roots, paths: paths)
        expectOriginalResults(roots: Array(roots.reversed()), paths: paths)
    }

    @Test(arguments: [0, 8])
    func mostSpecificRootPreservesExactRootAndOutsideRootBehavior(padding: Int) {
        let roots = urls([
            "/library", "/library/Shows", "/library/Shows/Season 01"
        ] + unrelatedRoots(padding))
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
        #expect(matcher.relativePath(normalizedPath:
            "/library/Shows/Season 01/Episode 01.mkv") == "Episode 01.mkv")
        #expect(matcher.relativePath(normalizedPath:
            "/library/Shows/Season 01") == "Season 01")
        #expect(matcher.relativePath(normalizedPath:
            "/library/Shows/Season 010/Episode 01.mkv") == "Season 010/Episode 01.mkv")
        #expect(matcher.relativePath(normalizedPath:
            "/library/Shows Extra/Movie.mkv") == "Shows Extra/Movie.mkv")
        #expect(matcher.relativePath(normalizedPath:
            "/library-extra/Outside/Movie.mkv") == "Movie.mkv")
    }

    @Test(arguments: [0, 8])
    func canonicalRootLookupPreservesReturnedPathBytes(padding: Int) throws {
        let root = "/library/Caf\u{e9}"
        let decomposedRoot = "/library/Cafe\u{301}"
        let roots = urls([root] + unrelatedRoots(padding))
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
        let suffix = "Season/e\u{301}pisode.mkv"
        let path = decomposedRoot + "/" + suffix
        #expect(Array(matcher.relativePath(normalizedPath: path).utf8) == Array(suffix.utf8))

        // An exact match returns the stored, normalized root's last component,
        // rather than the canonically equal query spelling.
        let stored = try #require(SourceVisibilityPath.normalized(roots[0]))
        let expected = URL(fileURLWithPath: stored, isDirectory: false).lastPathComponent
        #expect(Array(matcher.relativePath(normalizedPath: decomposedRoot).utf8)
                == Array(expected.utf8))
        expectOriginalResults(roots: roots, paths: [
            root, decomposedRoot, path, root + "/映画/👩🏽‍💻.mkv",
            "/library/Caf\u{e9} Extras/Movie.mkv"
        ])
    }

    @Test(arguments: [0, 8])
    func scalarSeparatorBoundariesAndCharacterCountTiesMatchOriginal(padding: Int) {
        // A slash can share a Character with combining/Prepend scalars. Walking
        // Character "/" values would miss some lexical ancestor candidates.
        let chains = [
            ["/", "/\u{301}", "/\u{301}/\u{301}"],
            ["/a", "/a\u{600}", "/a\u{600}/\u{301}"],
            ["/library", "/library/\u{301}", "/library/\u{301}/\u{600}"],
            ["/library", "/library/\u{200d}", "/library/\u{200d}/\u{fe0f}"],
            ["/library", "/library/\u{034f}", "/library/\u{034f}/\u{20e3}"],
            ["/library", "/library/👩🏽‍💻", "/library/👩🏽‍💻/Cafe\u{301}"]
        ]
        for chain in chains {
            let paths = chain.flatMap { root in
                [root, root + "/Film.mkv", root + "/\u{301}/Film.mkv",
                 root + "/\u{600}/\u{301}/Film.mkv", root + "-extra/Film.mkv"]
            }
            let roots = urls(chain + unrelatedRoots(padding))
            expectOriginalResults(roots: roots, paths: paths)
            expectOriginalResults(roots: Array(roots.reversed()), paths: paths)
        }
    }

    @Test func wideOverlappingLibrariesMatchOriginalForEveryQuery() {
        let roots = (0..<64).flatMap { index in
            let base = "/Library \(index)/映画"
            return [base, base + "/Season 01", base + "/Season 01/Extras"]
        }
        let paths = (0..<65).flatMap { index in
            let base = "/Library \(index)/映画"
            return [base, base + "/Movie.mkv", base + "/Season 01/Episode.mkv",
                    base + "/Season 010/Episode.mkv", base + "/Season 01/Extras/Trailer.mkv",
                    base + "集/Movie.mkv"]
        }
        for stride in [1, 2, 5] {
            let subset = roots.enumerated().compactMap { index, root in
                index % stride == 0 ? root : nil
            }
            expectOriginalResults(roots: urls(subset), paths: paths)
            expectOriginalResults(roots: urls(Array(subset.reversed())), paths: paths)
        }
    }

    @Test(arguments: [0, 8])
    func ancestorVisibilityStopsAtTheSelectedRoot(padding: Int) {
        let season = "/library/Shows/Season 01"
        let file = season + "/Episode 01.mkv"
        let roots = urls(["/library", "/library/Shows", season] + unrelatedRoots(padding))
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/library", "/library/Shows"]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        #expect(matcher.evaluateIncludingAncestors(normalizedPath: file).hiddenMatches.isEmpty)

        configuration.manuallyHiddenPaths.insert(season)
        configuration.alwaysShownPaths.insert(file)
        let hidden = SourceVisibilityMatcher(configuration: configuration, roots: roots)
            .evaluateIncludingAncestors(normalizedPath: file)
        // A direct Always Show override does not override a hidden ancestor.
        #expect(hidden.hiddenMatches == [.manual])
        #expect(hidden.regexMatches.isEmpty)

        configuration.manuallyHiddenPaths.remove(season)
        configuration.alwaysShownPaths.insert(season)
        #expect(SourceVisibilityMatcher(configuration: configuration, roots: roots)
            .evaluateIncludingAncestors(normalizedPath: file).hiddenMatches.isEmpty)
    }

    @Test(arguments: [0, 8])
    func relativeRegexCandidatesAndCachedRootEvaluationsKeepTheirOrder(padding: Int) {
        let season = "/library/Shows/Season 01"
        let file = season + "/Episode 01.mkv"
        let roots = urls(["/library", "/library/Shows", season] + unrelatedRoots(padding))
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "episode", pattern: "^Episode", colorIndex: 1, isEnabled: true),
            .init(id: "season", pattern: "^Season 01$", colorIndex: 2, isEnabled: true),
            .init(id: "broad", pattern: "^Shows/", colorIndex: 3, isEnabled: true),
            .init(id: "disabled", pattern: "Episode", colorIndex: 4, isEnabled: false),
        ]
        let episode = SourceVisibilityRegexMatch(id: "episode", colorIndex: 1)
        let seasonMatch = SourceVisibilityRegexMatch(id: "season", colorIndex: 2)
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        #expect(matcher.evaluate(normalizedPath: file) == .init(
            hiddenMatches: [.regex(episode)], regexMatches: [episode]))
        #expect(matcher.evaluateIncludingAncestors(normalizedPath: file) == .init(
            hiddenMatches: [.regex(seasonMatch)], regexMatches: [episode, seasonMatch]))

        configuration.alwaysShownPaths = [season]
        #expect(SourceVisibilityMatcher(configuration: configuration, roots: roots)
            .evaluateIncludingAncestors(normalizedPath: file) == .init(
                hiddenMatches: [.regex(episode)], regexMatches: [episode, seasonMatch]))
    }

    @Test func urlNormalizationAndNonFileRootsPreserveFallbacks() throws {
        let remote = try #require(URL(string: "https://example.invalid/library"))
        let file = URL(fileURLWithPath: "/library/Shows/../Café/Movie.mkv")
        let roots = urls(["/library/Café"] + unrelatedRoots(8)) + [remote]
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
        let normalized = try #require(SourceVisibilityPath.normalized(file))
        #expect(matcher.relativePath(for: file) == originalRelativePath(
            normalized, roots: roots.compactMap(SourceVisibilityPath.normalized)))
        #expect(matcher.relativePath(for: remote) == "library")
        #expect(matcher.evaluate(remote) == .init(hiddenMatches: [], regexMatches: []))

        let empty = SourceVisibilityMatcher(configuration: .default, roots: [remote])
        #expect(empty.relativePath(normalizedPath: "/library/Shows/Film.mkv") == "Film.mkv")
    }

    private func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func unrelatedRoots(_ count: Int) -> [String] {
        (0..<count).map { "/unrelated-root-\($0)" }
    }

    private func expectOriginalResults(roots: [URL], paths: [String]) {
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
        let normalizedRoots = roots.compactMap(SourceVisibilityPath.normalized)
        for path in paths {
            let actual = matcher.relativePath(normalizedPath: path)
            let expected = originalRelativePath(path, roots: normalizedRoots)
            // String equality alone would conceal changed Unicode spellings.
            #expect(Array(actual.utf8) == Array(expected.utf8),
                    Comment(rawValue: "Path: \(path.debugDescription); roots: \(normalizedRoots)"))
        }
    }

    /// The original root-selection policy is the differential oracle. Keep its
    /// filter/max ordering and Character-based slicing independent of the index.
    private func originalRelativePath(_ path: String, roots: [String]) -> String {
        let match = roots.filter { SourceTreeIdentity.contains(path, within: $0) }
            .max { $0.count < $1.count }
        guard let match else {
            return URL(fileURLWithPath: path, isDirectory: false).lastPathComponent
        }
        guard path != match else {
            return URL(fileURLWithPath: match, isDirectory: false).lastPathComponent
        }
        return String(path.dropFirst(match == "/" ? 1 : match.count + 1))
    }
}
