import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility root selection")
struct SourceRootSelectionTests {
    private func matcher(_ paths: [String],
                         configuration: SourceVisibilityConfiguration = .default) -> SourceVisibilityMatcher {
        SourceVisibilityMatcher(configuration: configuration,
                                roots: paths.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    @Test func longestRootWinsInEveryOrder() {
        let roots = ["/Volumes/Library", "/Volumes/Library/Shows",
                     "/Volumes/Library/Shows/Season 01"]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2],
                      [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            let subject = matcher(order.map { roots[$0] })
            #expect(subject.relativePath(normalizedPath:
                "/Volumes/Library/Shows/Season 01/Episode.mkv") == "Episode.mkv")
            #expect(subject.relativePath(normalizedPath:
                "/Volumes/Library/Shows/Other Season/Episode.mkv") == "Other Season/Episode.mkv")
        }
    }

    @Test func exactRootsEmptyRootsAndUnrelatedPaths() {
        #expect(matcher([]).relativePath(normalizedPath: "/Elsewhere/Season/Episode.mkv") == "Episode.mkv")
        let single = matcher(["/Volumes/Shows"])
        #expect(single.relativePath(normalizedPath: "/Volumes/Shows") == "Shows")
        #expect(single.relativePath(normalizedPath: "/Volumes/Shows/Season/Episode.mkv") == "Season/Episode.mkv")
        #expect(single.relativePath(normalizedPath: "/Volumes/Shows2/Season/Episode.mkv") == "Episode.mkv")
        #expect(matcher(["/"]).relativePath(normalizedPath: "/Volumes/Shows/Episode.mkv") == "Volumes/Shows/Episode.mkv")
        let subject = matcher(["/Volumes/Movies", "/Volumes/Shows"])
        #expect(subject.relativePath(normalizedPath: "/Volumes/Shows") == "Shows")
        #expect(subject.relativePath(normalizedPath: "/Volumes/Movies2/Season/Episode.mkv") == "Episode.mkv")
        #expect(subject.relativePath(normalizedPath: "/Volumes/Movies/Season/Episode.mkv") == "Season/Episode.mkv")
    }

    @Test func filesystemRootAndNestedRootPreserveSlashBoundary() {
        for roots in [["/", "/Volumes/Shows"], ["/Volumes/Shows", "/"]] {
            let subject = matcher(roots)
            #expect(subject.relativePath(normalizedPath: "/Elsewhere/Season/Episode.mkv") == "Elsewhere/Season/Episode.mkv")
            #expect(subject.relativePath(normalizedPath: "/Volumes/Shows/Season/Episode.mkv") == "Season/Episode.mkv")
            #expect(subject.relativePath(normalizedPath: "/Volumes/Shows2/Season/Episode.mkv") == "Volumes/Shows2/Season/Episode.mkv")
        }
    }

    @Test func unicodeRootsPreserveRelativePathBytes() {
        let root = "/Volumes/\u{00c9}missions/\u{1f3ac}"
        let equivalentRoot = "/Volumes/E\u{0301}missions/\u{1f3ac}"
        let suffix = "Saison 01/E\u{0301}pisode \u{1f469}\u{200d}\u{1f4bb}.mkv"
        for roots in [[root], ["/Volumes", root]] {
            for pathRoot in [root, equivalentRoot] {
                let actual = matcher(roots).relativePath(normalizedPath: pathRoot + "/" + suffix)
                #expect(Array(actual.utf8) == Array(suffix.utf8))
            }
        }
    }

    @Test func regexesUseTheMostSpecificRoot() {
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "outer", pattern: "^Show/", colorIndex: 0, isEnabled: true),
            .init(id: "relative", pattern: "^Season 01/", colorIndex: 1, isEnabled: true),
        ]
        let subject = matcher(["/Library", "/Library/Show"], configuration: configuration)
        let result = subject.evaluate(normalizedPath: "/Library/Show/Season 01/Episode.mkv")
        #expect(result.regexMatches == [.init(id: "relative", colorIndex: 1)])
        #expect(result.hiddenMatches == [.regex(.init(id: "relative", colorIndex: 1))])
    }

    @Test func ancestorVisibilityStopsAtTheSelectedRoot() {
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/Library"]
        configuration.regexRules = [
            .init(id: "episode", pattern: "Episode", colorIndex: 2, isEnabled: true),
        ]
        let path = "/Library/Show/Season/Episode.mkv"
        configuration.alwaysShownPaths = [path]
        let bounded = matcher(["/Library", "/Library/Show"], configuration: configuration)
            .evaluateIncludingAncestors(normalizedPath: path)
        #expect(bounded.hiddenMatches.isEmpty)
        #expect(bounded.regexMatches == [.init(id: "episode", colorIndex: 2)])

        configuration.manuallyHiddenPaths.insert("/Library/Show/Season")
        let hidden = matcher(["/Library/Show", "/Library"], configuration: configuration)
            .evaluateIncludingAncestors(normalizedPath: path)
        #expect(hidden.hiddenMatches == [.manual])
        #expect(hidden.regexMatches == [.init(id: "episode", colorIndex: 2)])
    }
}
