import Testing
@testable import IlliquidApp

struct SourceRootPruningTests {
    @Test func respectsPathBoundariesAndLexicalSiblingOrdering() {
        #expect(SourceRootPruning.minimal([
            "/media/a", "/media/a-", "/media/a/b", "/media/ab", "/media/a",
            "/media/映画", "/media/映画/season 1", "/media/映画集"
        ]) == ["/media/a", "/media/a-", "/media/ab", "/media/映画", "/media/映画集"])
        #expect(SourceRootPruning.minimal(["/", "/media", "/media/a"]) == ["/"])
        #expect(SourceRootPruning.minimal([]).isEmpty)
    }

    @Test func matchesPairwisePolicyAcrossOverlappingLibraries() {
        let paths = (0..<200).flatMap { index in
            ["/library/\(index)", "/library/\(index)/season", "/library/\(index)-extra"]
        }
        for stride in [1, 2, 3, 7, 11] {
            let selected = paths.enumerated().filter { $0.offset % stride != 0 }.map(\.element)
            let unique = Set(selected)
            let reference = unique.filter { path in
                !unique.contains { $0 != path && path.hasPrefix($0 + "/") }
            }.sorted()
            #expect(SourceRootPruning.minimal(Array(selected.reversed())) == reference)
        }
    }
}
