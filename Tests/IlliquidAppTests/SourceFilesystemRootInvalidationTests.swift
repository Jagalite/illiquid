import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source filesystem root and volume boundaries")
struct SourceFilesystemRootInvalidationTests {
    private func folder(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test(arguments: [SourceFilesystemEvent.Flags.created, .removed, .renamed])
    func filesystemRootReceivesDescendantFileChanges(_ flags: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Volumes/Media/Movies/Film.mkv", flags: flags)],
            roots: [folder("/")])
        #expect(plan.directoriesToReload == ["/Volumes/Media/Movies"])
        #expect(plan.treesToInvalidate.isEmpty)
        #expect(plan.rootsToRescan.isEmpty)
        #expect(plan.affectsAny([folder("/")]))
    }

    @Test(arguments: [SourceFilesystemEvent.Flags.removed, .renamed])
    func filesystemRootReceivesDescendantDirectoryRemoval(_ change: SourceFilesystemEvent.Flags) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Volumes/Media/Movies", flags: [.directory, change])],
            roots: [folder("/")])
        #expect(plan.directoriesToReload == ["/Volumes/Media"])
        #expect(plan.treesToInvalidate == ["/Volumes/Media/Movies"])
    }

    @Test func topLevelDirectoryCreationReloadsFilesystemRoot() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Media", flags: [.directory, .created])],
            roots: [folder("/")])
        #expect(plan.directoriesToReload == ["/"])
        #expect(plan.treesToInvalidate.isEmpty)
    }

    @Test(arguments: [SourceFilesystemEvent.Flags.mustScanSubdirectories,
                      .eventsDropped, .eventIDsWrapped, .rootChanged])
    func filesystemWideEventRescansEveryWatchedRoot(_ flag: SourceFilesystemEvent.Flags) {
        let paths = ["/Volumes/Media/Movies", "/Users/viewer/Videos"]
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/", flags: flag)], roots: paths.map(folder))
        #expect(plan.rootsToRescan == Set(paths))
        #expect(plan.directoriesToReload.isEmpty)
        #expect(plan.treesToInvalidate.isEmpty)
    }

    @Test func filesystemRootRescanSubsumesDescendantInvalidations() {
        let events: [SourceFilesystemEvent] = [
            .init(path: "/Volumes/Media/Movies/Film.mkv", flags: [.created]),
            .init(path: "/Volumes/Media/Shows", flags: [.directory, .removed]),
            .init(path: "/", flags: [.rootChanged]),
        ]
        for batch in [events, Array(events.reversed())] {
            let plan = SourceFilesystemInvalidationPlanner.plan(events: batch, roots: [folder("/")])
            #expect(plan.rootsToRescan == ["/"])
            #expect(plan.directoriesToReload.isEmpty)
            #expect(plan.treesToInvalidate.isEmpty)
        }
    }

    @Test func rootImpactWorksForEveryInvalidationKind() {
        let nested = "/Volumes/Media/Movies"
        let descendantPlans = [
            SourceFilesystemInvalidationPlan(directoriesToReload: [nested]),
            SourceFilesystemInvalidationPlan(treesToInvalidate: [nested]),
            SourceFilesystemInvalidationPlan(rootsToRescan: [nested]),
        ]
        for plan in descendantPlans {
            #expect(plan.affectsAny([folder("/")]))
            #expect(!plan.affectsAny([folder("/Volumes/Media2")]))
        }
        let rootPlans = [
            SourceFilesystemInvalidationPlan(directoriesToReload: ["/"]),
            SourceFilesystemInvalidationPlan(treesToInvalidate: ["/"]),
            SourceFilesystemInvalidationPlan(rootsToRescan: ["/"]),
        ]
        for plan in rootPlans {
            #expect(plan.affectsAny([folder(nested)]))
            #expect(!plan.affectsAny([]))
        }
    }

    @Test func volumeChangesIncludeAncestorExactAndDescendantRoots() {
        let paths = ["/", "/Volumes", "/Volumes/Media", "/Volumes/Media/Movies",
                     "/Volumes/Media2/Movies", "/Users/viewer/Videos"]
        let roots = paths.map(folder)
        let affected = SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
            at: "/Volumes/Media", roots: roots)
        #expect(affected == Array(roots.prefix(4)))
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: affected.map { .init(path: $0.path, flags: [.rootChanged]) }, roots: roots)
        #expect(plan.affectsAny([folder("/Volumes/Media/Movies")]))
    }

    @Test func volumeChangeAtFilesystemRootIncludesAllSources() {
        let roots = ["/", "/Volumes/Media/Movies", "/Users/viewer/Videos"].map(folder)
        #expect(SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
            at: "/", roots: roots) == roots)
    }

    @Test func volumeChangeIgnoresUnrelatedSourcesAndEmptyWatchLists() {
        let roots = ["/Volumes/Media2", "/Users/viewer/Videos"].map(folder)
        #expect(SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
            at: "/Volumes/Media", roots: roots).isEmpty)
        #expect(SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
            at: "/Volumes/Media", roots: []).isEmpty)
    }

    @Test func volumeChangeUsesLexicalPathsAndPreservesOriginalURLs() {
        // Deliberately absent: routing must also work while a drive is disconnected.
        let root = folder("/Volumes/Illiquid-Missing-Drive/Movies/../Shows")
        #expect(SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
            at: "/Volumes/Illiquid-Missing-Drive", roots: [root]) == [root])
    }

    @Test func normalizedPathMatrixMatchesComponentAncestry() {
        let paths = ["/", "/Volumes", "/Volumes/Media", "/Volumes/Media/Movies",
                     "/Volumes/Media2", "/Volumes/Media2/Movies", "/Users/viewer/Videos",
                     "/Volumes/Media Extra", "/Volumes/映画", "/Volumes/Media/../Other",
                     "/Volumes/Media/./Movies/"]
        for rootPath in paths {
            let root = folder(rootPath)
            for eventPath in paths {
                let eventURL = folder(eventPath)
                // Independent oracle: compare components, not string prefixes.
                let rootParts = root.absoluteURL.standardized.pathComponents
                let eventParts = eventURL.absoluteURL.standardized.pathComponents
                let eventWithinRoot = eventParts.starts(with: rootParts)
                let rootWithinEvent = rootParts.starts(with: eventParts)
                let related = eventWithinRoot || rootWithinEvent
                let context = Comment(rawValue: "root=\(rootPath), event=\(eventPath)")

                let plan = SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: eventPath, flags: [.rootChanged])], roots: [root])
                #expect(!plan.isEmpty == related, context)
                #expect(plan.affectsAny([root]) == related, context)
                let affected = SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
                    at: eventURL.absoluteURL.standardized.path, roots: [root])
                #expect(!affected.isEmpty == related, context)

                let listing = SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: eventPath, flags: [.directory])], roots: [root])
                #expect(!listing.isEmpty == eventWithinRoot, context)
            }
        }
    }
}
