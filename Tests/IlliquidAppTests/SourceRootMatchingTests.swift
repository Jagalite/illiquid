import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility root matching")
struct SourceRootMatchingTests {
    @Test func absentAndNonFileRootsUseFilenameFallback() throws {
        let remote = try #require(URL(string: "https://example.test/Season/Clip.mkv"))
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [rule("clip", "Clip")]
        let rootSets: [[URL]] = [[], [remote]]
        for roots in rootSets {
            let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
            #expect(matcher.relativePath(normalizedPath: "/Elsewhere/Season/Clip.mkv") == "Clip.mkv")
            #expect(matcher.relativePath(normalizedPath: "Season/Clip.mkv") == "Clip.mkv")
            #expect(matcher.relativePath(for: remote) == "Clip.mkv")
            #expect(matcher.evaluate(remote) == .init(hiddenMatches: [], regexMatches: []))
            #expect(matcher.evaluateIncludingAncestors(remote) == .init(hiddenMatches: [], regexMatches: []))
        }
    }

    @Test func filesystemRootAndExactRootsKeepTheirBasenames() {
        let root = file("/")
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: [root, file("/Movies")])
        #expect(matcher.relativePath(for: root) == root.lastPathComponent)
        #expect(matcher.relativePath(normalizedPath: "/Movies") == "Movies")
        #expect(matcher.relativePath(normalizedPath: "/Movies/Season/Clip.mkv") == "Season/Clip.mkv")
        #expect(matcher.relativePath(normalizedPath: "/Elsewhere/Clip.mkv") == "Elsewhere/Clip.mkv")
    }

    @Test func deepestRootWinsRegardlessOfInputOrder() {
        let paths = ["/Library", "/Library/Shows", "/Library/Shows/Season"]
        for order in [[0, 1, 2], [2, 0, 1], [1, 2, 0], [2, 1, 0]] {
            let matcher = SourceVisibilityMatcher(configuration: .default, roots: order.map { file(paths[$0]) })
            #expect(matcher.relativePath(normalizedPath: "/Library/Shows/Season/Extras/Clip.mkv") == "Extras/Clip.mkv")
            #expect(matcher.relativePath(normalizedPath: "/Library/Shows/Season") == "Season")
            #expect(matcher.relativePath(normalizedPath: "/Library/Shows/Special.mkv") == "Special.mkv")
        }
    }

    @Test func matchingRequiresAComponentBoundary() {
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: [file("/a"), file("/a/b")])
        #expect(matcher.relativePath(normalizedPath: "/a/b/Season/Clip.mkv") == "Season/Clip.mkv")
        #expect(matcher.relativePath(normalizedPath: "/a/bc/Clip.mkv") == "bc/Clip.mkv")
        #expect(matcher.relativePath(normalizedPath: "/ab/Season/Clip.mkv") == "Clip.mkv")
        #expect(matcher.relativePath(normalizedPath: "/A/Season/Clip.mkv") == "Clip.mkv")
    }

    @Test func urlEntryPointsNormalizeRootsAndCandidatesLexically() {
        let matcher = SourceVisibilityMatcher(configuration: .default,
            roots: [file("/tmp/unused/../Library/.")])
        #expect(matcher.relativePath(for: file("/tmp/Library/Season/../Extras/Clip.mkv")) == "Extras/Clip.mkv")
        #expect(matcher.relativePath(for: file("/tmp/Library/.")) == "Library")
    }

    @Test func unicodePathsKeepTheExistingCharacterBasedContract() {
        let longComponent = String(repeating: "📺e\u{301}", count: 96)
        let roots = [file("/Café"), file("/Café/東京"), file("/" + longComponent)]
        let matcher = SourceVisibilityMatcher(configuration: .default, roots: roots)
        let cases = [
            "/Cafe\u{301}/東京/👩🏽‍💻.mkv",
            "/Café/Extras/Cafe\u{301}.mkv",
            "/" + longComponent + "/東京/Clip.mkv",
            // A combining mark adjacent to a separator exercises the existing
            // hasPrefix/dropFirst Character contract of the string overload.
            "/Café/\u{301}Clip.mkv",
            "/Café/\u{200D}Clip.mkv",
            "/Caféteria/Season/Clip.mkv",
        ]
        for path in cases {
            let expected = originalRelativePath(path, roots: roots)
            let actual = matcher.relativePath(normalizedPath: path)
            #expect(actual.utf8.elementsEqual(expected.utf8))
        }
        #expect(matcher.relativePath(for: file("/Cafe\u{301}/東京/Clip.mkv")) == "Clip.mkv")
    }

    @Test func rootBasenameRulesApplyToTheRootAndItsDescendants() {
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [rule("root", "^Library$")]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [file("/Library")])
        let match = SourceVisibilityRegexMatch(id: "root", colorIndex: 0)
        #expect(matcher.evaluate(file("/Library")).hiddenMatches == [.regex(match)])
        #expect(matcher.evaluate(file("/Library/Season/Clip.mkv")).hiddenMatches.isEmpty)
        #expect(matcher.evaluateIncludingAncestors(file("/Library/Season/Clip.mkv"))
            == .init(hiddenMatches: [.regex(match)], regexMatches: [match]))
    }

    @Test func manualAndAlwaysShownPrecedenceRetainsRuleOrder() {
        let path = "/Library/Season/Clip.mkv"
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [path]
        configuration.alwaysShownPaths = [path]
        configuration.regexRules = [
            rule("second", "Clip", color: 2),
            .init(id: "disabled", pattern: ".*", colorIndex: 3, isEnabled: false),
            rule("invalid", "["),
            rule("first", "^Season/", color: 1),
        ]
        let matches = [
            SourceVisibilityRegexMatch(id: "second", colorIndex: 2),
            SourceVisibilityRegexMatch(id: "first", colorIndex: 1),
        ]
        let hidden = SourceVisibilityMatcher(configuration: configuration, roots: [file("/Library")])
        #expect(hidden.evaluate(normalizedPath: path)
            == .init(hiddenMatches: [.manual] + matches.map { .regex($0) }, regexMatches: matches))
        configuration.manuallyHiddenPaths.removeAll()
        let shown = SourceVisibilityMatcher(configuration: configuration, roots: [file("/Library")])
        #expect(shown.evaluate(normalizedPath: path)
            == .init(hiddenMatches: [], regexMatches: matches))
    }

    @Test func ancestorHidingStopsAtTheDeepestRoot() {
        let path = "/Library/Shows/Season/Clip.mkv"
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/Library/Shows"]
        configuration.alwaysShownPaths = [path]
        let outer = SourceVisibilityMatcher(configuration: configuration, roots: [file("/Library")])
        #expect(outer.evaluateIncludingAncestors(normalizedPath: path).hiddenMatches == [.manual])
        for roots in [[file("/Library"), file("/Library/Shows/Season")],
                      [file("/Library/Shows/Season"), file("/Library")]] {
            let nested = SourceVisibilityMatcher(configuration: configuration, roots: roots)
            #expect(nested.evaluateIncludingAncestors(normalizedPath: path).hiddenMatches.isEmpty)
        }
    }

    @Test func filesOnlyProjectionPreservesCompleteRowsAndVisibility() async throws {
        let roots = [file("/Library"), file("/Archive"), file("/Library/Shows")]
        let paths = ["/Library/Shows/Season/Clip.mkv", "/Library/Movie.mkv",
                     "/Archive/Extras/Bonus.mp4", "/Outside/Loose.mkv"]
        let contexts: [String?] = ["Season", nil, "Extras", nil]
        let urls = paths.map(file)
        let stamp = Date(timeIntervalSince1970: 123)
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly
        configuration.regexRules = [rule("season", "^Season/")]
        let input = SourceTreeProjectionInput(
            items: roots.map { .init(kind: .folder, url: $0) },
            visibility: configuration, roots: roots, directoryContents: [:],
            directoryErrors: [:],
            recursiveMediaEntries: urls.map {
                .init(url: $0, kind: .media, dateAdded: stamp, creationDate: nil,
                      visibilityPath: SourceVisibilityPath.normalized($0))
            },
            expandedFolderIDs: [],
            sortConfiguration: .init(name: .off, dateCreated: .off, type: .off))
        let expected = urls.enumerated().map { index, url in
            SourceTreeDisplayRow(
                id: "media:" + paths[index], folderID: url.deletingLastPathComponent().path,
                url: url, displayName: url.deletingPathExtension().lastPathComponent,
                contextLabel: contexts[index], visibilityPath: paths[index],
                depth: 0, ancestorIDs: [], kind: .media(dateAdded: stamp))
        }
        #expect(input.rows() == expected)
        let projection = try #require(await SourceBrowserFilter().project(
            input: input, revealsRulePreview: false, query: ""))
        #expect(projection.rows == Array(expected.dropFirst()))
        #expect(projection.hiddenCount == 1)
        #expect(projection.regexCounts == ["season": 1])
        #expect(projection.thumbnailCandidates == Array(urls.dropFirst()))
        #expect(projection.mediaPaths == Set(paths.dropFirst()))
    }

    private func file(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    private func rule(_ id: String, _ pattern: String, color: Int = 0) -> SourceVisibilityRegexRule {
        .init(id: id, pattern: pattern, colorIndex: color, isEnabled: true)
    }

    // The pre-change reference is limited to Unicode differential cases.
    // No assumptions about UTF-8 length or grapheme boundaries replace it.
    private func originalRelativePath(_ path: String, roots: [URL]) -> String {
        let root = roots.compactMap(SourceVisibilityPath.normalized)
            .filter { SourceTreeIdentity.contains(path, within: $0) }
            .max { $0.count < $1.count }
        guard let root else { return file(path).lastPathComponent }
        guard path != root else { return file(root).lastPathComponent }
        return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
    }
}
