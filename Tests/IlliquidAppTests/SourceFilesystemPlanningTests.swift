import Foundation
import Testing

@testable import IlliquidApp

@Suite("Source filesystem planning path semantics")
struct SourceFilesystemPlanningTests {
    private let root = URL(fileURLWithPath: "/media/library", isDirectory: true)

    @Test func normalizesRelativeRootsAndEventDotSegmentsBeforeMatching() throws {
        let base = URL(fileURLWithPath: "/media/anchor/", isDirectory: true)
        let relativeRoot = try #require(URL(string: "../library/", relativeTo: base))
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/library/Season 1/../Season 2/./New.mkv", flags: [.created])],
            roots: [relativeRoot, root, URL(fileURLWithPath: "/media/library/../library/")])

        #expect(plan == SourceFilesystemInvalidationPlan(directoriesToReload: ["/media/library/Season 2"]))
        #expect(plan.affectsAny([relativeRoot]))
    }

    @Test(arguments: [
        "/media/library/Season 2/",
        "/media/library/Season 2/.",
        "/media/library/Old/../Season 2",
    ], [
        SourceFilesystemEvent.Flags([.directory, .removed]),
        [.directory, .renamed],
        [.directory, .created, .removed, .renamed],
    ])
    func normalizedDirectoryRemovalStillReloadsItsParent(
        _ path: String, _ flags: SourceFilesystemEvent.Flags
    ) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: path, flags: flags)], roots: [root])

        #expect(plan == SourceFilesystemInvalidationPlan(
            directoriesToReload: ["/media/library"],
            treesToInvalidate: ["/media/library/Season 2"]))
    }

    @Test(arguments: ["/media/library/", "/media/library/."])
    func normalizedRootRemovalCannotReloadAnUnwatchedParent(_ path: String) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: path, flags: [.directory, .removed])], roots: [root])

        #expect(plan == SourceFilesystemInvalidationPlan(
            directoriesToReload: ["/media/library"], treesToInvalidate: ["/media/library"]))
    }

    @Test(arguments: ["100% Movies", "literal%2Fname", "what?now#again", "映画 Café", "Cafe\u{0301}"])
    func eventPathsRemainLiteralFilesystemNames(_ folder: String) {
        let parent = "/media/library/" + folder
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: parent + "/Episode.NfO", flags: [])], roots: [root])

        #expect(plan == SourceFilesystemInvalidationPlan(directoriesToReload: [parent]))
        // Foundation may normalize Unicode path bytes on macOS. Preserve
        // the literal filename and Swift's canonical string equality; the
        // differential harness separately compares exact old/new outputs.
    }

    @Test(arguments: ["映画.nFo", "Cafe\u{0301}.NFO", ".plexmatch", ".plexmatch/", "tvshow.NFO/."])
    func metadataWritesClassifyTheNormalizedFilename(_ name: String) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/library/Season 1/" + name, flags: [])], roots: [root])

        #expect(plan == SourceFilesystemInvalidationPlan(directoriesToReload: ["/media/library/Season 1"]))
    }

    @Test(arguments: [".PLEXMATCH", "x.plexmatch", "episode.nfo.bak", "episode.ＮＦＯ", "episode.nfο", "episode%2Enfo"])
    func metadataLookalikesDoNotTriggerContentOnlyReloads(_ name: String) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/library/Season 1/" + name, flags: [])], roots: [root])

        #expect(plan.isEmpty)
    }

    @Test(arguments: ["plain.mkv", ".plexmatch", "episode.NFO", "episode.ＮＦＯ"], [
        SourceFilesystemEvent.Flags.created,
        .removed,
        .renamed,
        [.created, .removed, .renamed],
    ])
    func structuralFileEventsReloadRegardlessOfMetadataClassification(
        _ name: String, _ flags: SourceFilesystemEvent.Flags
    ) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/media/library/Season 1/" + name, flags: flags)], roots: [root])

        #expect(plan == SourceFilesystemInvalidationPlan(directoriesToReload: ["/media/library/Season 1"]))
    }

    @Test func existingDirectoriesDoNotOverrideTheEventFlagsOrMetadataNamePolicy() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("filesystem-planning-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }

        let ordinaryFile = fixture.appendingPathComponent("Episode.mkv", isDirectory: false)
        let sidecarFile = fixture.appendingPathComponent("Episode.NFO", isDirectory: false)
        try Data().write(to: ordinaryFile)
        try Data("<movie><title>Fixture</title></movie>".utf8).write(to: sidecarFile)
        let plainDirectory = fixture.appendingPathComponent("Season 1", isDirectory: true)
        let plexDirectory = fixture.appendingPathComponent(".plexmatch", isDirectory: true)
        let nfoDirectory = fixture.appendingPathComponent("folder.nfo", isDirectory: true)
        let bareNfoDirectory = fixture.appendingPathComponent(".nfo", isDirectory: true)
        for directory in [plainDirectory, plexDirectory, nfoDirectory, bareNfoDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let directoryLink = fixture.appendingPathComponent("linked.nfo", isDirectory: false)
        try manager.createSymbolicLink(at: directoryLink, withDestinationURL: plainDirectory)

        let parentPath = fixture.absoluteURL.standardized.path
        let parentReload = SourceFilesystemInvalidationPlan(directoriesToReload: [parentPath])
        // A URL initializer may infer directory status from these real entries.
        // Planning is governed by event flags and names, including when a
        // directory or its symlink happens to have a metadata filename.
        for suffix in ["", "/"] {
            for ordinary in [ordinaryFile, plainDirectory, bareNfoDirectory] {
                #expect(SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: ordinary.path + suffix, flags: [])], roots: [fixture]).isEmpty)
            }
            for metadata in [sidecarFile, plexDirectory, nfoDirectory, directoryLink] {
                #expect(SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: metadata.path + suffix, flags: [])], roots: [fixture]) == parentReload)
            }
            for file in [ordinaryFile, sidecarFile, directoryLink] {
                for flags in [SourceFilesystemEvent.Flags.created, .removed, .renamed] {
                    #expect(SourceFilesystemInvalidationPlanner.plan(
                        events: [.init(path: file.path + suffix, flags: flags)], roots: [fixture]) == parentReload)
                }
            }
            for directory in [plainDirectory, plexDirectory, nfoDirectory, bareNfoDirectory, directoryLink] {
                let path = directory.path
                #expect(SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: path + suffix, flags: [.directory])], roots: [fixture])
                    == SourceFilesystemInvalidationPlan(directoriesToReload: [path]))
                #expect(SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: path + suffix, flags: [.directory, .created])], roots: [fixture])
                    == parentReload)
                for flags in [SourceFilesystemEvent.Flags([.directory, .removed]), [.directory, .renamed]] {
                    #expect(SourceFilesystemInvalidationPlanner.plan(
                        events: [.init(path: path + suffix, flags: flags)], roots: [fixture])
                        == SourceFilesystemInvalidationPlan(
                            directoriesToReload: [parentPath], treesToInvalidate: [path]))
                }
            }
        }
    }

    @Test func combinedLocalRecoveryFlagsSupersedeOnlyTheirMatchingRoots() {
        let sibling = URL(fileURLWithPath: "/media/library2", isDirectory: true)
        let nested = URL(fileURLWithPath: "/media/library/Season 1", isDirectory: true)
        let targeted: [SourceFilesystemEvent] = [
            .init(path: "/media/library/Season 1/.plexmatch", flags: []),
            .init(path: "/media/library/Season 2/", flags: [.directory, .removed]),
            .init(path: "/media/library2/New.mkv", flags: [.created]),
        ]
        let recovery = SourceFilesystemEvent(
            path: "/media/library/Season 1/..",
            flags: [.rootChanged, .mustScanSubdirectories, .eventIDsWrapped, .directory, .removed])

        for events in [targeted + [recovery], [recovery] + targeted] {
            let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: [root, nested, sibling])
            #expect(plan == SourceFilesystemInvalidationPlan(
                directoriesToReload: ["/media/library2"],
                rootsToRescan: ["/media/library", "/media/library/Season 1"]))
        }
    }

    @Test func normalizedSiblingAndAncestorPrefixesStayOutsideTheSource() {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [
                .init(path: "/media/library/../library2/.plexmatch", flags: []),
                .init(path: "/media/library-old/", flags: [.directory, .removed]),
                .init(path: "/media/lib/.", flags: [.rootChanged, .mustScanSubdirectories]),
            ], roots: [root])

        #expect(plan.isEmpty)
    }
}
