import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source media presence repair snapshots")
struct SourceMediaPresenceSnapshotTests {
    @Test func narrowRepairKeepsItsRootAndDescendantsButNotAncestorsOrPrefixSiblings() {
        let results = [
            "/": true,
            "/Library": true,
            "/Library/Show": true,
            "/Library/Show/Season 1": true,
            "/Library/Show/Season 2": false,
            "/Library/Show/Season 2/Extras": false,
            "/Library/Showcase": true,
            "/Library/Show-old/Season 1": false,
            "/Library/Other": true,
            "/Archive/Show": false,
        ]
        var examined: [String] = []
        let snapshot = SourceMediaPresenceSnapshot.reusableResults(
            under: "/Library/Show", results: results
        ) { path in
            examined.append(path)
            return true
        }
        let expected = [
            "/Library/Show": true,
            "/Library/Show/Season 1": true,
            "/Library/Show/Season 2": false,
            "/Library/Show/Season 2/Extras": false,
        ]
        #expect(snapshot == expected)
        #expect(Set(examined) == Set(expected.keys))
        #expect(examined.count == expected.count)
    }

    @Test func onlyCompleteReadableSummariesCanSupplyCachedPresenceOrAbsence() {
        let root = "/Library/Repair"
        let results = [
            root: true,
            root + "/Present": true,
            root + "/Absent": false,
            root + "/IncompletePresent": true,
            root + "/IncompleteAbsent": false,
            root + "/UnreadablePresent": true,
            root + "/UnreadableAbsent": false,
            root + "/MissingSummary": false,
            "/Library/Unrelated": true,
        ]
        let complete: Set<String> = [
            root + "/Present", root + "/Absent",
            root + "/UnreadablePresent", root + "/UnreadableAbsent",
            "/Library/Unrelated",
        ]
        let readable: Set<String> = [
            root, root + "/Present", root + "/Absent",
            root + "/IncompletePresent", root + "/IncompleteAbsent",
            "/Library/Unrelated",
        ]
        var examined: [String] = []
        let snapshot = SourceMediaPresenceSnapshot.reusableResults(
            under: root, results: results
        ) { path in
            examined.append(path)
            return complete.contains(path) && readable.contains(path)
        }
        #expect(snapshot == [root + "/Present": true, root + "/Absent": false])
        #expect(Set(examined) == Set(results.keys).subtracting(["/Library/Unrelated"]))
        #expect(examined.count == results.count - 1)
    }

    @Test func filesystemRootIncludesEveryAbsoluteCachedPathAndStillAppliesEligibility() {
        let results = [
            "/": false,
            "/Library": true,
            "/Library/Show": false,
            "/Volumes/外部/映画": true,
            "/Unreadable": false,
        ]
        var examined: [String] = []
        let snapshot = SourceMediaPresenceSnapshot.reusableResults(
            under: "/", results: results
        ) { path in
            examined.append(path)
            return path != "/Unreadable"
        }
        #expect(snapshot == [
            "/": false, "/Library": true, "/Library/Show": false,
            "/Volumes/外部/映画": true,
        ])
        #expect(Set(examined) == Set(results.keys))
        #expect(examined.count == results.count)
    }

    @Test func emptyOrUnrelatedCachesDoNotConsultSummaryState() {
        let fixtures: [[String: Bool]] = [[:], ["/Archive": true, "/Library-old/Show": false]]
        for results in fixtures {
            var calls = 0
            let snapshot = SourceMediaPresenceSnapshot.reusableResults(
                under: "/Library", results: results
            ) { _ in calls += 1; return true }
            #expect(snapshot.isEmpty)
            #expect(calls == 0)
        }
    }

    @Test func unicodePathsPreserveCanonicalIdentityWithoutCaseOrSeparatorCollisions() {
        let root = "/Volumes/Café/动画"
        let equivalentRoot = "/Volumes/Cafe\u{301}/动画"
        let present = equivalentRoot + "/👩🏽‍💻/100% complete/#1"
        let absent = root + "/字幕"
        let results = [
            equivalentRoot: false,
            present: true,
            absent: false,
            root + "集/Unrelated": true,
            "/Volumes/CAFÉ/动画/Unrelated": true,
            "/Volumes/Café/动画-extra": false,
        ]
        #expect(SourceMediaPresenceSnapshot.reusableResults(
            under: root, results: results, isReusable: { _ in true }
        ) == [root: false, present: true, absent: false])
    }

    @Test func treeMembershipMatchesAnIndependentComponentAncestryOracle() {
        // Components, rather than textual prefixes, define the test oracle.
        // All inputs are absolute identities, as supplied by the scanner.
        let names = ["Show", "Showcase", "Show-old", "S", "s", "动画", "Café", "👩🏽‍💻"]
        var paths = ["/", "/Library", "/Library2", "/Archive"]
        for name in names {
            paths.append("/Library/" + name)
            paths.append("/Library/" + name + "/Season 1")
            paths.append("/Library/" + name + "/Season 1/Extras")
            paths.append("/Library2/" + name)
            paths.append("/Archive/" + name)
        }
        let results = Dictionary(uniqueKeysWithValues: paths.enumerated().map {
            ($0.element, $0.offset.isMultiple(of: 2))
        })
        for (rootIndex, root) in paths.enumerated() {
            let rootComponents = root.split(separator: "/")
            let contained = paths.filter { path in
                let components = path.split(separator: "/")
                return components.count >= rootComponents.count
                    && zip(rootComponents, components).allSatisfy { $0.0 == $0.1 }
            }
            // Vary eligibility independently of both ancestry and presence.
            let reusable = Set(paths.enumerated().compactMap {
                ($0.offset + rootIndex).isMultiple(of: 3) ? nil : $0.element
            })
            let expected = Dictionary(uniqueKeysWithValues: contained.compactMap { path in
                reusable.contains(path) ? (path, results[path]!) : nil
            })
            var examined: [String] = []
            let actual = SourceMediaPresenceSnapshot.reusableResults(
                under: root, results: results
            ) { path in
                examined.append(path)
                return reusable.contains(path)
            }
            #expect(actual == expected, Comment(rawValue: root))
            #expect(Set(examined) == Set(contained), Comment(rawValue: root))
            #expect(examined.count == contained.count, Comment(rawValue: root))
        }
    }

    @Test func snapshotRetainsItsValuesAcrossLaterCacheMutations() {
        var results = ["/Library/Present": true, "/Library/Absent": false, "/Archive": true]
        let snapshot = SourceMediaPresenceSnapshot.reusableResults(
            under: "/Library", results: results, isReusable: { _ in true }
        )
        results["/Library/Present"] = false
        results["/Library/Absent"] = nil
        results["/Library/New"] = true
        #expect(snapshot == ["/Library/Present": true, "/Library/Absent": false])
        #expect(results["/Archive"] == true)
    }
}
