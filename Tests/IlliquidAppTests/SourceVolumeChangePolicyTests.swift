import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source volume notification boundaries")
struct SourceVolumeChangePolicyTests {
    private func folder(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test func exactAndDescendantSourcesRemainAffected() {
        let roots = ["/Volumes/Media", "/Volumes/Media/Movies", "/Users/viewer/Videos"].map(folder)
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots)
            == Array(roots.prefix(2)))
    }

    @Test func sourceContainingMountPointIsAffected() {
        let roots = [folder("/Volumes")]
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots) == roots)
    }

    @Test func filesystemRootSourceContainsMountPoint() {
        let roots = [folder("/")]
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots) == roots)
    }

    @Test func siblingPrefixesRemainUnrelated() {
        let roots = ["/Volumes/Media2", "/Volumes/Media2/Movies", "/Volume", "/Users/viewer"].map(folder)
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots).isEmpty)
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media2", roots: [folder("/Volumes/Media")]).isEmpty)
    }

    @Test func affectedRootsPreserveOriginalOrder() {
        let roots = ["/Volumes/Media/Movies", "/Users/viewer/Videos", "/", "/Volumes", "/Volumes/Media"].map(folder)
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots)
            == [roots[0], roots[2], roots[3], roots[4]])
    }

    @Test func emptyWatchListRemainsEmpty() {
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: []).isEmpty)
    }

    @Test func rootVolumeChangeIncludesEverySource() {
        let roots = ["/", "/Volumes/Media/Movies", "/Users/viewer/Videos"].map(folder)
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/", roots: roots) == roots)
    }

    @Test func nonexistentPathsAndDotSegmentsNeedNoFilesystemResolution() {
        let root = folder("/Volumes/Illiquid-Missing-Drive/Movies/../Shows")
        #expect(SourceVolumeChangePolicy.affectedRoots(
            at: "/Volumes/Illiquid-Missing-Drive", roots: [root]) == [root])
        let ancestor = folder("/Volumes/./")
        #expect(SourceVolumeChangePolicy.affectedRoots(
            at: "/Volumes/Illiquid-Missing-Drive/../Another-Missing-Drive", roots: [ancestor]) == [ancestor])
    }

    @Test func unicodeAndSpacePathsKeepComponentBoundaries() {
        let roots = ["/Volumes/映画 Library", "/Volumes/映画 Library/Season 1",
                     "/Volumes/映画 Library2", "/Volumes/映画"].map(folder)
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/映画 Library", roots: roots)
            == Array(roots.prefix(2)))
    }

    @Test func filteringDoesNotRewriteOrDeduplicateRootURLs() {
        let root = folder("/Volumes/Media/Movies/../Shows")
        let roots = [root, root]
        #expect(SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots) == roots)
    }

    @Test func normalizedPathMatrixMatchesComponentAncestry() {
        let paths = ["/", "/Volumes", "/Volumes/Media", "/Volumes/Media/Movies",
                     "/Volumes/Media2", "/Volumes/Media2/Movies", "/Users/viewer/Videos",
                     "/Volumes/Media Extra", "/Volumes/映画", "/Volumes/Media/../Other",
                     "/Volumes/Media/./Movies/"]
        for rootPath in paths {
            let root = folder(rootPath)
            for volumePath in paths {
                let volume = folder(volumePath).absoluteURL.standardized
                // Independent oracle uses path components, not string prefixes.
                let rootParts = root.absoluteURL.standardized.pathComponents
                let volumeParts = volume.pathComponents
                let related = volumeParts.starts(with: rootParts) || rootParts.starts(with: volumeParts)
                let context = Comment(rawValue: "root=\(rootPath), volume=\(volumePath)")
                let affected = SourceVolumeChangePolicy.affectedRoots(at: volume.path, roots: [root])
                #expect(affected == (related ? [root] : []), context)
            }
        }
    }
}

#if os(macOS)
// These exercise the callback's selection -> rootChanged-event -> planner flow.
// They do not start FSEvents or post a real NSWorkspace mount notification.
@Suite("Source volume notification invalidation")
struct SourceVolumeInvalidationIntegrationTests {
    @Test(arguments: ["/", "/Volumes", "/Volumes/Media", "/Volumes/Media/Movies"])
    func affectedSourceProducesRootRescan(_ path: String) {
        let roots = [URL(fileURLWithPath: path, isDirectory: true)]
        let affected = SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots)
        let events: [SourceFilesystemEvent] = affected.map { .init(path: $0.path, flags: [.rootChanged]) }
        let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: roots)
        #expect(plan.rootsToRescan == [path])
        #expect(plan.affectsAny(roots))
    }

    @Test func standaloneSiblingVolumeProducesNoInvalidation() {
        let roots = [URL(fileURLWithPath: "/Volumes/Media2/Movies", isDirectory: true)]
        let affected = SourceVolumeChangePolicy.affectedRoots(at: "/Volumes/Media", roots: roots)
        let events: [SourceFilesystemEvent] = affected.map { .init(path: $0.path, flags: [.rootChanged]) }
        #expect(SourceFilesystemInvalidationPlanner.plan(events: events, roots: roots).isEmpty)
    }
}
#endif
