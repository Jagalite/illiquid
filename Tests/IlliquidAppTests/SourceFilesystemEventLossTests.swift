import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source filesystem event-loss recovery")
struct SourceFilesystemEventLossTests {
    private let roots = [
        URL(fileURLWithPath: "/media/movies", isDirectory: true),
        URL(fileURLWithPath: "/media/shows", isDirectory: true),
        URL(fileURLWithPath: "/Volumes/External/Library", isDirectory: true),
    ]

    @Test(arguments: [
        "/media/movies/Movie.mkv", "/media", "/outside/watched/roots", "/",
    ], [
        SourceFilesystemEvent.Flags.eventsDropped,
        [.eventsDropped, .mustScanSubdirectories],
    ])
    func droppedEventsRescanEveryWatchedRoot(
        _ path: String, _ flags: SourceFilesystemEvent.Flags
    ) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: path, flags: flags)], roots: roots)

        #expect(plan.rootsToRescan == Set(roots.map(\.path)))
        #expect(plan.directoriesToReload.isEmpty)
        #expect(plan.treesToInvalidate.isEmpty)
        for root in roots {
            #expect(plan.affectsAny([root]))
        }
    }

    @Test(arguments: [false, true])
    func eventLossSupersedesTargetedWorkRegardlessOfOrder(_ lossFirst: Bool) {
        let loss = SourceFilesystemEvent(
            path: "/outside/watched/roots", flags: [.eventsDropped, .mustScanSubdirectories])
        let targeted: [SourceFilesystemEvent] = [
            .init(path: "/media/movies/New.mkv", flags: [.created]),
            .init(path: "/media/shows/Season 1", flags: [.directory, .removed]),
            .init(path: "/media/movies", flags: [.mustScanSubdirectories]),
        ]
        let events = lossFirst ? [loss] + targeted : targeted + [loss]
        let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: roots)

        #expect(plan == SourceFilesystemInvalidationPlan(rootsToRescan: Set(roots.map(\.path))))
    }

    @Test func eventLossWithNoWatchedRootsProducesNoWork() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/", flags: [.eventsDropped])], roots: [])
        #expect(plan.isEmpty)
    }

    @Test(arguments: [
        SourceFilesystemEvent.Flags.mustScanSubdirectories, .rootChanged, .eventIDsWrapped,
    ])
    func pathLocalRecoveryStaysLocalWithoutDroppedEvents(_ flags: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/movies", flags: flags)], roots: roots)
        #expect(plan.rootsToRescan == ["/media/movies"])
        #expect(!plan.affectsAny([roots[1], roots[2]]))
    }

    @Test(arguments: [
        SourceFilesystemEvent.Flags.created, .removed, .renamed, [.directory, .renamed],
    ])
    func ordinaryEventsForOldRootsDoNotAffectReplacementRoots(_ flags: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/old/Movie.mkv", flags: flags)], roots: roots)
        #expect(plan.isEmpty)
    }

    @Test(arguments: [
        SourceFilesystemEvent.Flags.created, .mustScanSubdirectories, .rootChanged,
    ])
    func similarPathPrefixesAreNotDescendants(_ flags: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/movies2/Movie.mkv", flags: flags)], roots: roots)
        #expect(plan.isEmpty)
        #expect(!SourceFilesystemInvalidationPlan(rootsToRescan: ["/media/movies2"]).affectsAny(roots))
    }

    @Test func eventLossDeduplicatesNormalizedRoots() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/outside", flags: [.eventsDropped])],
            roots: [
                roots[0],
                URL(fileURLWithPath: "/media/movies/", isDirectory: true),
                URL(fileURLWithPath: "/media/movies/../movies", isDirectory: true),
            ])
        #expect(plan.rootsToRescan == ["/media/movies"])
    }
}
