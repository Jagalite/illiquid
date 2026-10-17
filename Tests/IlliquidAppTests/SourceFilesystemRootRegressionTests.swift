import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source filesystem root boundaries")
struct SourceFilesystemRootRegressionTests {
    private let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)

    @Test(arguments: [
        SourceFilesystemEvent.Flags.created,
        .removed,
        .renamed,
    ])
    func fileChangesBelowFilesystemRootReloadTheirParent(_ flags: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/Season 1/Episode.mkv", flags: flags)],
            roots: [filesystemRoot])

        #expect(plan.directoriesToReload == ["/Movies/Season 1"])
        #expect(plan.treesToInvalidate.isEmpty)
        #expect(plan.rootsToRescan.isEmpty)
        #expect(plan.affectsAny([filesystemRoot]))
    }

    @Test(arguments: [
        SourceFilesystemEvent.Flags.mustScanSubdirectories,
        .eventsDropped,
        .eventIDsWrapped,
        .rootChanged,
    ])
    func ancestorRescanAtFilesystemRootReachesEverySource(_ flags: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/", flags: flags)],
            roots: [URL(fileURLWithPath: "/Movies"), URL(fileURLWithPath: "/Volumes/Media/TV")])

        #expect(plan.rootsToRescan == ["/Movies", "/Volumes/Media/TV"])
        #expect(plan.directoriesToReload.isEmpty)
        #expect(plan.treesToInvalidate.isEmpty)
    }

    @Test func removedDirectoryBelowFilesystemRootInvalidatesItsTree() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/Season 1", flags: [.directory, .removed])],
            roots: [filesystemRoot])

        #expect(plan.directoriesToReload == ["/Movies"])
        #expect(plan.treesToInvalidate == ["/Movies/Season 1"])
        #expect(plan.rootsToRescan.isEmpty)
    }

    @Test(arguments: [".plexmatch", "movie.nfo", "Episode.NFO"])
    func metadataWritesBelowFilesystemRootReloadTheirParent(_ name: String) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/" + name, flags: [])], roots: [filesystemRoot])

        #expect(plan.directoriesToReload == ["/Movies"])
    }

    @Test func filesystemRootRescanSubsumesNarrowerInvalidationsInEitherEventOrder() {
        let events: [SourceFilesystemEvent] = [
            .init(path: "/Movies/Episode.mkv", flags: [.created]),
            .init(path: "/Movies/Old Season", flags: [.directory, .removed]),
            .init(path: "/", flags: [.eventsDropped]),
        ]
        for orderedEvents in [events, Array(events.reversed())] {
            let plan = SourceFilesystemInvalidationPlanner.plan(
                events: orderedEvents, roots: [filesystemRoot, URL(fileURLWithPath: "/Movies")])

            #expect(plan.rootsToRescan == ["/", "/Movies"])
            #expect(plan.directoriesToReload.isEmpty)
            #expect(plan.treesToInvalidate.isEmpty)
        }
    }

    @Test func impactDetectionHandlesFilesystemRootInBothDirections() {
        let reload = SourceFilesystemInvalidationPlan(directoriesToReload: ["/Movies"])
        let removal = SourceFilesystemInvalidationPlan(treesToInvalidate: ["/Movies"])
        let rescan = SourceFilesystemInvalidationPlan(rootsToRescan: ["/"])

        #expect(reload.affectsAny([filesystemRoot]))
        #expect(removal.affectsAny([filesystemRoot]))
        #expect(rescan.affectsAny([URL(fileURLWithPath: "/Movies/Season 1")]))
        #expect(rescan.affectsAny([filesystemRoot]))
        #expect(!rescan.affectsAny([]))
        #expect(!SourceFilesystemInvalidationPlan().affectsAny([filesystemRoot]))
    }

    @Test func containmentStillRespectsSiblingPathComponents() {
        let root = URL(fileURLWithPath: "/Movies")
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                .init(path: "/Movies2/Film.mkv", flags: [.created]),
                .init(path: "/Movies-old", flags: [.directory, .removed]),
                .init(path: "/Movie", flags: [.rootChanged]),
            ], roots: [root])

        #expect(plan.isEmpty)
        #expect(!SourceFilesystemInvalidationPlan(rootsToRescan: ["/Movies2"]).affectsAny([root]))
        #expect(!SourceFilesystemInvalidationPlan(rootsToRescan: ["/Movie"]).affectsAny([root]))
    }

    @Test func lexicalNormalizationAndUnrelatedContentWritesKeepTheirPolicy() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/Season/../Film.mkv", flags: [.created])],
            roots: [URL(fileURLWithPath: "/Movies/..", isDirectory: true)])
        #expect(plan.directoriesToReload == ["/Movies"])

        #expect(SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/Film.mkv", flags: [])], roots: [filesystemRoot]).isEmpty)
        #expect(SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/", flags: [.eventsDropped])], roots: []).isEmpty)
    }
}

@Suite("Source filesystem containment invariants")
struct SourceFilesystemContainmentInvariantTests {
    /// Moving the same tree below an ordinary directory must not change event
    /// policy. Check every combination of the eight event flags, without I/O.
    @Test func translatingAnAbsoluteTreePreservesPlans() {
        let rootSets = [["/"], ["/Movies"], ["/", "/Movies"], ["/Movies", "/Other"]]
        let eventPaths = ["/", "/Movies", "/Movies/Episode.mkv", "/Movies/.plexmatch", "/Movies/Episode.nfo", "/Other/Film.mkv"]
        var checked = 0
        for roots in rootSets {
            for path in eventPaths {
                for rawFlags in UInt16(0)...UInt16(255) {
                    let flags = SourceFilesystemEvent.Flags(rawValue: rawFlags)
                    let original = SourceFilesystemInvalidationPlanner.plan(
                        events: [.init(path: path, flags: flags)],
                        roots: roots.map { URL(fileURLWithPath: $0, isDirectory: true) })
                    let translated = SourceFilesystemInvalidationPlanner.plan(
                        events: [.init(path: translate(path), flags: flags)],
                        roots: roots.map { URL(fileURLWithPath: translate($0), isDirectory: true) })
                    let expected = SourceFilesystemInvalidationPlan(
                        directoriesToReload: Set(original.directoriesToReload.map(translate)),
                        treesToInvalidate: Set(original.treesToInvalidate.map(translate)),
                        rootsToRescan: Set(original.rootsToRescan.map(translate)))
                    // Stop at the first counterexample so a regression remains readable.
                    guard translated == expected else {
                        Issue.record("Translation changed plan for roots \(roots), path \(path), flags \(rawFlags)")
                        return
                    }
                    checked += 1
                }
            }
        }
        #expect(checked == 6_144)
    }

    @Test func impactMatchesAPathComponentOracle() {
        let paths = ["/", "/Movies", "/Movies/Season", "/Movies2", "/Movie", "/Other", "/映画/第 1 話", "/100% Movies"]
        var checked = 0
        for affected in paths {
            for root in paths {
                let left = affected.split(separator: "/")
                let right = root.split(separator: "/")
                let expected = left.starts(with: right) || right.starts(with: left)
                let plans = [
                    SourceFilesystemInvalidationPlan(directoriesToReload: [affected]),
                    SourceFilesystemInvalidationPlan(treesToInvalidate: [affected]),
                    SourceFilesystemInvalidationPlan(rootsToRescan: [affected]),
                ]
                for plan in plans {
                    #expect(plan.affectsAny([URL(fileURLWithPath: root, isDirectory: true)]) == expected)
                    checked += 1
                }
            }
        }
        #expect(checked == 192)
    }

    private func translate(_ path: String) -> String {
        path == "/" ? "/scope" : "/scope" + path
    }
}
