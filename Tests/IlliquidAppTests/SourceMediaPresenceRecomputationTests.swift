import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source media presence recomputation")
struct SourceMediaPresenceRecomputationTests {
    @Test func emptyInputsAndUnwatchedChangesProduceNoWork() {
        #expect(SourceMediaPresenceRecomputation.orderedPaths([String](), roots: ["/Media"]).isEmpty)
        #expect(SourceMediaPresenceRecomputation.orderedPaths(["/Media/Show"], roots: []).isEmpty)
        #expect(SourceMediaPresenceRecomputation.orderedPaths(
            ["/Other/Show", "/", "/Media"], roots: ["/Media/Watched"]
        ).isEmpty)
    }

    @Test func duplicatesAndSharedAncestorsAreScheduledOnlyOnce() {
        let folders = ["/Media/Show/Season/A", "/Media/Show/Season/B",
                       "/Media/Show/Season/A", "/Media/Show", "/Media"]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(folders, roots: ["/Media"])
        let expected: Set<String> = ["/Media/Show/Season/A", "/Media/Show/Season/B",
                                     "/Media/Show/Season", "/Media/Show", "/Media"]
        #expect(Set(ordered) == expected)
        #expect(ordered.count == expected.count)
        #expect(isChildBeforeParent(ordered))
        #expect(ordered.last == "/Media")
    }

    @Test func prefixSiblingsStayOutsideTheWatchedRoot() {
        let folders = ["/Media2/Show", "/Media-old/Show", "/Media/Show", "/Media"]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(folders, roots: ["/Media"])
        #expect(ordered == ["/Media/Show", "/Media"])
    }

    @Test func nestedAndDisjointRootsRetainTheirBoundaries() {
        let folders = ["/Media/Show/Season", "/Archive/Movies/A", "/Media/Other"]
        let roots = ["/Media/Show", "/Archive/Movies", "/Media/Show/Season", "/Media/Show"]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(folders, roots: roots)
        #expect(Set(ordered) == ["/Media/Show/Season", "/Media/Show",
                                 "/Archive/Movies/A", "/Archive/Movies"])
        #expect(ordered.count == 4)
        #expect(isChildBeforeParent(ordered))

        let covered = SourceMediaPresenceRecomputation.orderedPaths(
            folders, roots: roots + ["/Media"]
        )
        #expect(Set(covered) == Set(ordered).union(["/Media", "/Media/Other"]))
        #expect(covered.count == 6)
        #expect(isChildBeforeParent(covered))
    }

    @Test func filesystemRootIsIncludedOnceAndTerminatesTheWalk() {
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(
            ["/", "/Media/Show", "/Archive/Film", "/Media", "/"], roots: ["/"]
        )
        #expect(Set(ordered) == ["/", "/Media", "/Media/Show", "/Archive", "/Archive/Film"])
        #expect(ordered.count == 5)
        #expect(ordered.last == "/")
        #expect(isChildBeforeParent(ordered))
    }

    @Test func canonicalUnicodePathsAndDictionaryKeysRemainUsable() {
        let root = "/Volumes/Café"
        let decomposedRoot = "/Volumes/Cafe\u{301}"
        let leaf = decomposedRoot + "/动画/👩🏽‍💻"
        let another = root + "/100% complete/#1"
        let changes = [leaf: 1, another: 2, root: 3]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(changes.keys, roots: [root])
        let expected: Set<String> = [root, root + "/动画", leaf, root + "/100% complete", another]
        #expect(Set(ordered) == expected)
        #expect(ordered.count == expected.count)
        #expect(isChildBeforeParent(ordered))
    }

    @Test func equivalentUnicodeSpellingsDoNotPutAParentBeforeItsChild() {
        let root = "/Media"
        let composedParent = root + "/éééééééé"
        let decomposedParent = root + "/" + String(repeating: "e\u{301}", count: 8)
        let child = composedParent + "/x"
        #expect(composedParent == decomposedParent)
        #expect(decomposedParent.utf8.count > child.utf8.count)
        // Preserve the first spelling of an equivalent ID, just as a Set does.
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(
            [decomposedParent, child], roots: [root]
        )
        #expect(ordered == [child, composedParent, root])
        #expect(isChildBeforeParent(ordered))

        let summaries = [
            root: Summary(hasDirectMedia: false, children: [composedParent], isComplete: true, isReadable: true),
            composedParent: Summary(hasDirectMedia: false, children: [child], isComplete: true, isReadable: true),
            child: Summary(hasDirectMedia: true, children: [], isComplete: true, isReadable: true),
        ]
        #expect(applying(ordered, summaries: summaries, initial: [:])
                == [root: true, composedParent: true, child: true])
    }

    @Test func deepAndWideBatchesHaveOneEntryPerAffectedFolder() {
        let root = "/Media"
        var deep = root
        var expected: Set<String> = [root]
        for _ in 0..<128 {
            deep += "/d"
            expected.insert(deep)
        }
        let wide = (0..<512).map { root + "/Folder-\($0)" }
        expected.formUnion(wide)
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(
            wide + [deep, deep, root] + wide, roots: [root]
        )
        #expect(Set(ordered) == expected)
        #expect(ordered.count == expected.count)
        #expect(isChildBeforeParent(ordered))
    }

    @Test func aChangedParentSummaryIsEvaluatedEvenWhenItsChildStaysFalse() {
        let root = "/Media"
        let child = root + "/Empty"
        let summaries = [
            root: Summary(hasDirectMedia: true, children: [child], isComplete: true, isReadable: true),
            child: Summary(hasDirectMedia: false, children: [], isComplete: true, isReadable: true),
        ]
        let initial = [root: false, child: false]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths([child, root], roots: [root])
        let result = applying(ordered, summaries: summaries, initial: initial)
        #expect(result == [root: true, child: false])

        // An unchanged child is not a reason to omit its ancestors from work.
        let ancestors = SourceMediaPresenceRecomputation.orderedPaths([child], roots: [root])
        #expect(applying(ancestors, summaries: summaries, initial: initial) == result)
    }

    @Test func incompleteUnreadableAndMissingSummariesCannotEstablishAbsence() {
        let root = "/Media"
        let child = root + "/Child"
        let rootSummary = Summary(hasDirectMedia: false, children: [child],
                                  isComplete: true, isReadable: true)
        let uncertain: [Summary?] = [
            nil,
            Summary(hasDirectMedia: false, children: [], isComplete: false, isReadable: true),
            Summary(hasDirectMedia: false, children: [], isComplete: true, isReadable: false),
        ]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths([child], roots: [root])
        for summary in uncertain {
            var summaries = [root: rootSummary]
            summaries[child] = summary
            let result = applying(ordered, summaries: summaries,
                                  initial: [root: false, child: false, "/Unrelated": true])
            #expect(result == ["/Unrelated": true])
        }

        let absent = Summary(hasDirectMedia: false, children: [], isComplete: true, isReadable: true)
        #expect(applying(ordered, summaries: [root: rootSummary, child: absent], initial: [:])
                == [root: false, child: false])
    }

    @Test func positiveEvidencePropagatesThroughIncompleteUnreadableAncestors() {
        let root = "/Media"
        let child = root + "/Child"
        let summaries = [
            root: Summary(hasDirectMedia: false, children: [child], isComplete: false, isReadable: false),
            child: Summary(hasDirectMedia: true, children: [], isComplete: false, isReadable: false),
        ]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths([child], roots: [root])
        #expect(applying(ordered, summaries: summaries, initial: [:]) == [root: true, child: true])
    }

    @Test func missingChangedSummariesClearStaleValuesWithoutTouchingOtherTrees() {
        let root = "/Media"
        let child = root + "/Child"
        let missing = child + "/Removed"
        let summaries = [
            root: Summary(hasDirectMedia: false, children: [child], isComplete: true, isReadable: true),
            child: Summary(hasDirectMedia: false, children: [missing], isComplete: true, isReadable: true),
        ]
        let initial = [root: true, child: true, missing: true, "/Archive/Unchanged": false]
        let ordered = SourceMediaPresenceRecomputation.orderedPaths(
            [missing, "/Unwatched/Missing"], roots: [root]
        )
        #expect(applying(ordered, summaries: summaries, initial: initial) == ["/Archive/Unchanged": false])
    }

    @Test func seededValidTreesMatchThePreviousAncestorWalk() {
        var random = Generator(seed: 0x53_6F_75_72_63_65_73)
        for scenario in 0..<1_024 {
            var paths = ["/", "/Media", "/Media/Shows", "/Media2", "/Archive",
                         "/Volumes", "/Volumes/外部"]
            var children: [String: Set<String>] = [
                "/": ["/Media", "/Media2", "/Archive", "/Volumes"],
                "/Media": ["/Media/Shows"],
                "/Volumes": ["/Volumes/外部"],
            ]
            for index in 0..<random.choose(58) {
                let parent = paths[random.choose(paths.count)]
                let name = index.isMultiple(of: 7) ? "节目-\(index)" : "Folder-\(index)"
                let path = (parent == "/" ? "" : parent) + "/" + name
                children[parent, default: []].insert(path)
                paths.append(path)
            }

            let roots: [String]
            switch scenario % 8 {
            case 0: roots = ["/"]
            case 1: roots = ["/Media"]
            case 2: roots = ["/Media", "/Media/Shows", "/Archive"]
            case 3: roots = ["/Media/Shows", "/Volumes/外部"]
            case 4: roots = [paths[random.choose(paths.count)], paths[random.choose(paths.count)]]
            case 5: roots = []
            case 6: roots = ["/Unwatched"]
            default: roots = ["/Media2", "/Archive"]
            }

            var summaries: [String: Summary] = [:]
            for path in paths where random.choose(7) != 0 {
                summaries[path] = random.summary(children: children[path, default: []])
            }
            // Start from a consistent tri-state cache, then remove selected
            // entries as invalidation can do before a publication arrives.
            var initial = applying(paths.sorted { $0.count > $1.count },
                                   summaries: summaries, initial: [:])
            for path in paths where random.choose(9) == 0 { initial[path] = nil }

            var changed: [String] = []
            for path in paths where random.choose(4) == 0 {
                changed.append(path)
                if random.choose(3) == 0 { changed.append(path) }
                if random.choose(6) == 0 {
                    summaries[path] = nil
                } else {
                    summaries[path] = random.summary(children: children[path, default: []])
                }
            }
            if scenario.isMultiple(of: 3) {
                // Removed and unwatched keys can remain in buffered batches.
                changed += ["/Media/Removed", "/Unwatched/Missing"]
                initial["/Media/Removed"] = true
            }
            // Vary arrival order without relying on system randomness.
            if changed.count > 1 {
                for index in stride(from: changed.count - 1, through: 1, by: -1) {
                    changed.swapAt(index, random.choose(index + 1))
                }
            }

            let ordered = SourceMediaPresenceRecomputation.orderedPaths(changed, roots: roots)
            let expectedPaths = ancestorOracle(changed, roots: roots)
            #expect(Set(ordered) == expectedPaths, "scenario \(scenario)")
            #expect(ordered.count == expectedPaths.count, "scenario \(scenario)")
            #expect(isChildBeforeParent(ordered), "scenario \(scenario)")
            let expected = previousAncestorWalk(changed, roots: roots,
                                                summaries: summaries, initial: initial)
            let actual = applying(ordered, summaries: summaries, initial: initial)
            #expect(actual == expected, "scenario \(scenario)")
        }
    }

    private struct Summary {
        let hasDirectMedia: Bool
        let children: Set<String>
        let isComplete: Bool
        let isReadable: Bool
    }

    /// The scanner's observable tri-state evaluation, without filesystem I/O,
    /// scheduling, revision acceptance, or Observation substitutions.
    private func evaluate(_ path: String, summaries: [String: Summary], results: inout [String: Bool]) {
        if let summary = summaries[path] {
            if summary.hasDirectMedia || summary.children.contains(where: { results[$0] == true }) {
                results[path] = true
            } else if summary.isComplete && summary.isReadable
                        && summary.children.allSatisfy({ results[$0] == false }) {
                results[path] = false
            } else {
                results[path] = nil
            }
        } else {
            results[path] = nil
        }
    }

    private func applying(_ ordered: [String], summaries: [String: Summary],
                          initial: [String: Bool]) -> [String: Bool] {
        var results = initial
        for path in ordered { evaluate(path, summaries: summaries, results: &results) }
        return results
    }

    /// The former publication order and ancestor walk. This intentionally uses
    /// Foundation's parent traversal, independently of orderedPaths.
    private func previousAncestorWalk(_ folders: [String], roots: [String],
                                      summaries: [String: Summary], initial: [String: Bool]) -> [String: Bool] {
        var results = initial
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            var path = folder
            while roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? $0 : $0 + "/") }) {
                evaluate(path, summaries: summaries, results: &results)
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                guard parent != path else { break }
                path = parent
            }
        }
        return results
    }

    /// Independent set oracle: enumerate every component prefix, then retain
    /// those inside any root. No early-stop or incremental union traversal.
    private func ancestorOracle(_ folders: [String], roots: [String]) -> Set<String> {
        let rootComponents = roots.map { $0.split(separator: "/").map(String.init) }
        var expected: Set<String> = []
        for folder in folders {
            let components = folder.split(separator: "/").map(String.init)
            for length in 0...components.count {
                let prefix = Array(components.prefix(length))
                if rootComponents.contains(where: { root in
                    root.count <= prefix.count && Array(prefix.prefix(root.count)) == root
                }) {
                    expected.insert("/" + prefix.joined(separator: "/"))
                }
            }
        }
        return expected
    }

    private func isChildBeforeParent(_ paths: [String]) -> Bool {
        var offsets: [String: Int] = [:]
        for (index, path) in paths.enumerated() {
            guard offsets.updateValue(index, forKey: path) == nil else { return false }
        }
        for (index, path) in paths.enumerated() {
            let components = path.split(separator: "/")
            for length in 0..<components.count {
                let ancestor = "/" + components.prefix(length).joined(separator: "/")
                if let ancestorIndex = offsets[ancestor], ancestorIndex <= index { return false }
            }
        }
        return true
    }

    private struct Generator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func choose(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(upperBound))
        }
        mutating func summary(children: Set<String>) -> Summary {
            Summary(hasDirectMedia: choose(5) == 0, children: children,
                    isComplete: choose(3) != 0, isReadable: choose(4) != 0)
        }
    }
}
