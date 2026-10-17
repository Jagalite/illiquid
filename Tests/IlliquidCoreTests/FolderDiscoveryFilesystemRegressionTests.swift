import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import IlliquidCore

@Suite("Folder discovery filesystem regressions")
struct FolderDiscoveryFilesystemRegressionTests {
    @Test("Unsupported files do not change the playlist", arguments: [0, 250])
    func mixedDirectory(_ unrelatedCount: Int) throws {
        let directory = try TemporaryDirectory()
        for index in 0..<unrelatedCount { try directory.createFile("notes-\(index).txt") }
        try directory.createFile("Episode 10.MKV")
        try directory.createFile("Episode 2.mp4")
        try directory.createFile("Episode 2.en.srt")
        try directory.createFile(".hidden.mp4")
        try directory.createFile("Folder.mkv/Nested.mp4")
        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)
        #expect(playlist.mediaURLs.map(\.lastPathComponent) == ["Episode 2.mp4", "Episode 10.MKV"])
        #expect(playlist[0].externalSubtitleURLs.map(\.lastPathComponent) == ["Episode 2.en.srt"])
    }

    @Test("Symlinks are classified by their targets", arguments: ["shortcut", "alias.txt", "alias.MKV"])
    func mediaSymlinks(_ name: String) throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        let target = try targets.createFile("Feature.mkv")
        try link(directory.url.appendingPathComponent(name), to: target)
        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)
        let item = try #require(playlist.items.first)
        #expect(playlist.count == 1)
        #expect(item.url == NormalizedFileURL.resolveFilesystemIdentity(target))
        #expect(item.dateAdded == FolderPlaylistItem.metadataDate(for: target))
        #expect(item.dateAdded != nil)
    }

    @Test("Extensionless subtitle symlinks are retained", arguments: ["srt", "ass", "vtt", "ssa", "idx"])
    func subtitleSymlinks(_ ext: String) throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        try directory.createFile("Feature.mkv")
        let target = try targets.createFile("Feature.\(ext)")
        try link(directory.url.appendingPathComponent("captions"), to: target)
        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)
        let item = try #require(playlist.items.first)
        let expected = try #require(NormalizedFileURL.resolveFilesystemIdentity(target))
        #expect(item.externalSubtitleURLs == [expected])
    }

    @Test("Media-looking links to unsupported files are excluded")
    func misleadingLinkExtension() throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        let text = try targets.createFile("notes.txt")
        try link(directory.url.appendingPathComponent("Feature.mkv"), to: text)
        #expect(try FolderPlaylistDiscovery.discover(in: directory.url).isEmpty)
    }

    @Test("Directory links are not traversed")
    func directoryLinks() throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        try targets.createFile("Feature.mkv")
        try link(directory.url.appendingPathComponent("Collection.mkv"), to: targets.url)
        try link(directory.url.appendingPathComponent("collection"), to: targets.url)
        #expect(try FolderPlaylistDiscovery.discover(in: directory.url).isEmpty)
    }

    @Test("Broken links are ignored", arguments: ["missing", "missing.mkv"])
    func brokenLinks(_ name: String) throws {
        let directory = try TemporaryDirectory()
        try link(directory.url.appendingPathComponent(name), to: directory.url.appendingPathComponent("absent.mp4"))
        #expect(try FolderPlaylistDiscovery.discover(in: directory.url).isEmpty)
    }

    @Test("Hidden entries stay hidden but visible aliases retain target identity")
    func hiddenEntries() throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        let target = try targets.createFile(".Feature.mkv")
        try link(directory.url.appendingPathComponent(".hidden-alias"), to: target)
        #expect(try FolderPlaylistDiscovery.discover(in: directory.url).isEmpty)
        try link(directory.url.appendingPathComponent("visible-alias"), to: target)
        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)
        let expected = try #require(NormalizedFileURL.resolveFilesystemIdentity(target))
        #expect(playlist.mediaURLs == [expected])
    }

    @Test("Multiple media aliases keep one canonical identity")
    func duplicateMediaAliases() throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        let target = try targets.createFile("Feature.mkv")
        try link(directory.url.appendingPathComponent("first"), to: target)
        try link(directory.url.appendingPathComponent("second.mkv"), to: target)
        #expect(try FolderPlaylistDiscovery.discover(in: directory.url).count == 1)
    }

    @Test("Symlink retargeting is observed on the next discovery")
    func retargetedLink() throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        let first = try targets.createFile("First.mkv")
        let second = try targets.createFile("Second.mp4")
        let alias = directory.url.appendingPathComponent("current")
        try link(alias, to: first)
        let before = try FolderPlaylistDiscovery.discover(in: directory.url)
        try FileManager.default.removeItem(at: alias)
        try link(alias, to: second)
        let after = try FolderPlaylistDiscovery.discover(in: directory.url)
        let expectedFirst = try #require(NormalizedFileURL.resolveFilesystemIdentity(first))
        let expectedSecond = try #require(NormalizedFileURL.resolveFilesystemIdentity(second))
        #expect(before.mediaURLs == [expectedFirst])
        #expect(after.mediaURLs == [expectedSecond])
    }

    @Test("Relative and chained symlinks retain target identity")
    func relativeChainedLinks() throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.createDirectory("selected")
        let target = try directory.createFile("targets/Feature.MKV")
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("first").path,
            withDestinationPath: "../targets/Feature.MKV"
        )
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("second.txt").path,
            withDestinationPath: "first"
        )
        let playlist = try FolderPlaylistDiscovery.discover(in: folder)
        let expected = try #require(NormalizedFileURL.resolveFilesystemIdentity(target))
        #expect(playlist.mediaURLs == [expected])
    }

    @Test("Opening a symlinked folder keeps its canonical identity")
    func symlinkedFolder() throws {
        let directory = try TemporaryDirectory()
        let targets = try TemporaryDirectory()
        try targets.createFile("Feature.mkv")
        let alias = directory.url.appendingPathComponent("folder")
        try link(alias, to: targets.url)
        let playlist = try FolderPlaylistDiscovery.discover(in: alias)
        #expect(NormalizedFileURL.representsSameFile(playlist.folderURL, targets.url))
        #expect(playlist.count == 1)
    }

    @Test("Cancellation is checked before touching a missing folder")
    func cancelledBeforeFilesystemWork() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: FolderDiscoveryProbeError.cancelled) {
            try FolderPlaylistDiscovery.discover(in: directory.url.appendingPathComponent("missing")) {
                throw FolderDiscoveryProbeError.cancelled
            }
        }
    }

    @Test("Cancellation during scanning throws rather than returning partial results", arguments: [3, 4, 12, 40])
    func cancelledDuringScan(_ stopAt: Int) throws {
        let directory = try TemporaryDirectory()
        try directory.createFile("Feature.mkv")
        for index in 0..<80 { try directory.createFile("notes-\(index).txt") }
        let probe = FolderDiscoveryCancellationProbe(stopAt: stopAt)
        #expect(throws: FolderDiscoveryProbeError.cancelled) {
            try FolderPlaylistDiscovery.discover(in: directory.url, checkCancellation: { try probe.check() })
        }
    }

    @Test("Missing folder errors propagate")
    func missingFolder() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: (any Error).self) {
            try FolderPlaylistDiscovery.discover(in: directory.url.appendingPathComponent("missing"))
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test("Named pipes with media extensions are excluded without reading content")
    func namedPipe() throws {
        let directory = try TemporaryDirectory()
        let pipe = directory.url.appendingPathComponent("Feature.mkv")
        let result = pipe.path.withCString { mkfifo($0, 0o600) }
        try #require(result == 0)
        #expect(try FolderPlaylistDiscovery.discover(in: directory.url).isEmpty)
    }
    #endif

    private func link(_ alias: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    }
}

private enum FolderDiscoveryProbeError: Error, Equatable { case cancelled }

private final class FolderDiscoveryCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let stopAt: Int
    init(stopAt: Int) { self.stopAt = stopAt }
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls >= stopAt { throw FolderDiscoveryProbeError.cancelled }
    }
}
