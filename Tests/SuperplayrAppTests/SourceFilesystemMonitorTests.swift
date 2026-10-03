import Foundation
import Testing

@testable import SuperplayrApp

@Suite("Source filesystem synchronization")
struct SourceFilesystemMonitorTests {
    private let root = URL(fileURLWithPath: "/media/library", isDirectory: true)

    @Test func createdFileReloadsItsContainingDirectory() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/library/Season 1/Episode.mkv",
                    flags: [.created]
                )
            ],
            roots: [root]
        )

        #expect(plan.directoriesToReload == ["/media/library/Season 1"])
        #expect(plan.treesToInvalidate.isEmpty)
        #expect(plan.rootsToRescan.isEmpty)
    }

    @Test func fileContentAndMetadataChangesDoNotReloadTheListing() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/library/Season 1/Episode.mkv",
                    flags: []
                )
            ],
            roots: [root]
        )

        #expect(plan.isEmpty)
    }

    @Test(arguments: [".plexmatch", "tvshow.nfo", "movie.nfo", "Episode.NFO"])
    func sidecarContentWritesReloadTheirDirectory(_ name: String) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/library/Season 1/" + name, flags: [])], roots: [root])
        #expect(plan.directoriesToReload == ["/media/library/Season 1"])
        #expect(plan.affectsAny([root]))
    }

    @Test func createdDirectoryReloadsItsParent() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/library/Season 2",
                    flags: [.directory, .created]
                )
            ],
            roots: [root]
        )

        #expect(plan.directoriesToReload == ["/media/library"])
        #expect(plan.treesToInvalidate.isEmpty)
    }

    @Test func removedDirectoryDropsItsSubtreeAndReloadsItsParent() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/library/Season 1",
                    flags: [.directory, .removed]
                )
            ],
            roots: [root]
        )

        #expect(plan.directoriesToReload == ["/media/library"])
        #expect(plan.treesToInvalidate == ["/media/library/Season 1"])
        #expect(plan.rootsToRescan.isEmpty)
    }

    @Test func removedRootIsReloadedSoUnavailableStateCanAppear() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/library",
                    flags: [.directory, .removed]
                )
            ],
            roots: [root]
        )

        #expect(plan.directoriesToReload == ["/media/library"])
        #expect(plan.treesToInvalidate == ["/media/library"])
    }

    @Test func droppedEventRescansEveryMatchingRoot() {
        let nestedRoot = URL(
            fileURLWithPath: "/media/library/Season 1",
            isDirectory: true
        )
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/library/Season 1/Episode.mkv",
                    flags: [.eventsDropped]
                )
            ],
            roots: [root, nestedRoot]
        )

        #expect(plan.directoriesToReload.isEmpty)
        #expect(plan.treesToInvalidate.isEmpty)
        #expect(
            plan.rootsToRescan == [
                "/media/library",
                "/media/library/Season 1",
            ])
    }

    @Test func changesOutsideSourceRootsAreIgnored() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                SourceFilesystemEvent(
                    path: "/media/other/Movie.mkv",
                    flags: []
                )
            ],
            roots: [root]
        )

        #expect(plan.isEmpty)
        #expect(!plan.affectsAny([root]))
    }

    @Test func activeRootImpactIncludesAncestorRescans() {
        let nestedRoot = URL(
            fileURLWithPath: "/media/library/Season 1",
            isDirectory: true
        )
        let plan = SourceFilesystemInvalidationPlan(
            rootsToRescan: ["/media/library"]
        )

        #expect(plan.affectsAny([nestedRoot]))
    }
}
