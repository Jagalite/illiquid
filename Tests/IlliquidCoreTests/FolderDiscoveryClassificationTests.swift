import Foundation
import Testing
@testable import IlliquidCore

@Suite("Folder discovery classification")
struct FolderDiscoveryClassificationTests {
    @Test func mixedListingsPreserveTargetTypesDuplicatesAndMetadata() throws {
        let fixture = try ClassificationFixture()
        let fileManagers: [FileManager]
        #if canImport(Darwin)
        fileManagers = [ClassificationListingFileManager(entries: fixture.entries),
                        ClassificationListingFileManager(entries: Array(fixture.entries.reversed()))]
        #else
        // Corelibs Foundation cannot override this listing method. Exercise
        // the real directory once; explicit order injection is native-only.
        fileManagers = [FileManager.default]
        #endif
        for fileManager in fileManagers {
            let actual = try FolderPlaylistDiscovery.discover(in: fixture.folder, fileManager: fileManager)
            let expected = try originalDiscover(in: fixture.folder, fileManager: fileManager)
            #expect(actual == expected)
            #expect(actual.items.map { $0.url.lastPathComponent } == ["Episode 2.MKV", "Episode 10.MP4"])
            let first = try #require(actual.items.first)
            let expectedSubtitle = try #require(NormalizedFileURL.resolveFilesystemIdentity(fixture.englishSubtitle))
            let expectedFrench = try #require(NormalizedFileURL.resolveFilesystemIdentity(fixture.frenchSubtitle))
            #expect(first.externalSubtitleURLs == [expectedSubtitle, expectedSubtitle, expectedFrench])
            for item in actual.items {
                #expect(item.dateAdded == FolderPlaylistItem.metadataDate(for: item.url))
                #expect(item.dateAdded != nil)
            }
        }
    }

    @Test func everySupportedSuffixKeepsCaseInsensitiveClassification() throws {
        let directory = try TemporaryDirectory()
        var entries: [URL] = []
        for (index, suffix) in MediaFileSupport.videoFileExtensions.sorted().enumerated() {
            entries.append(try directory.createFile("Feature \(index).\(suffix.uppercased())"))
        }
        for suffix in MediaFileSupport.subtitleFileExtensions.sorted() {
            entries.append(try directory.createFile("Feature 0.en.\(suffix.uppercased())"))
        }
        let fileManager = classificationFileManager(entries: entries)
        let probe = ClassificationCancellationProbe()
        let actual = try FolderPlaylistDiscovery.discover(in: directory.url,
            fileManager: fileManager, checkCancellation: { try probe.check() })
        let expected = try originalDiscover(in: directory.url, fileManager: fileManager)
        #expect(actual == expected)
        #expect(actual.count == MediaFileSupport.videoFileExtensions.count)
        #expect(actual.items.first?.externalSubtitleURLs.count == MediaFileSupport.subtitleFileExtensions.count)
        #expect(probe.count == 4 + 2 * entries.count)
    }

    @Test func cancellationPreservesEveryOriginalCheckpoint() throws {
        let fixture = try ClassificationFixture()
        let fileManager = classificationFileManager(entries: fixture.entries)
        // Two initial checks, two final checks, and entry checks: unsupported
        // ordinary file/folder entries have one; the other eleven have two.
        let expectedChecks = 4 + 2 + 11 * 2
        for stopAt in 1...expectedChecks {
            let actualProbe = ClassificationCancellationProbe(stopAt: stopAt)
            #expect(throws: ClassificationCancellation.stop) {
                try FolderPlaylistDiscovery.discover(in: fixture.folder, fileManager: fileManager,
                    checkCancellation: { try actualProbe.check() })
            }
            let originalProbe = ClassificationCancellationProbe(stopAt: stopAt)
            #expect(throws: ClassificationCancellation.stop) {
                try originalDiscover(in: fixture.folder, fileManager: fileManager,
                    checkCancellation: { try originalProbe.check() })
            }
            #expect(actualProbe.count == stopAt)
            #expect(originalProbe.count == stopAt)
        }
        let actualProbe = ClassificationCancellationProbe(stopAt: expectedChecks + 1)
        let originalProbe = ClassificationCancellationProbe(stopAt: expectedChecks + 1)
        let actual = try FolderPlaylistDiscovery.discover(in: fixture.folder, fileManager: fileManager,
            checkCancellation: { try actualProbe.check() })
        let expected = try originalDiscover(in: fixture.folder, fileManager: fileManager,
            checkCancellation: { try originalProbe.check() })
        #expect(actual == expected)
        #expect(actualProbe.count == expectedChecks)
        #expect(originalProbe.count == expectedChecks)
    }

    @Test func unsupportedOnlyListingsKeepTheEarlyRejectionPath() throws {
        let directory = try TemporaryDirectory()
        let entries = try ["readme.txt", "movie.nfo", "poster.JPG", "captions.zip"].map {
            try directory.createFile($0)
        }
        let fileManager = classificationFileManager(entries: entries)
        let probe = ClassificationCancellationProbe()
        let actual = try FolderPlaylistDiscovery.discover(in: directory.url, fileManager: fileManager,
            checkCancellation: { try probe.check() })
        #expect(actual.isEmpty)
        #expect(actual == (try originalDiscover(in: directory.url, fileManager: fileManager)))
        #expect(probe.count == 4 + entries.count)
    }

    // Frozen discovery pipeline from ea2ff568. It retains the old compactMap
    // and both independent filters as an oracle for outputs and checkpoints.
    private func originalDiscover(
        in folderURL: URL,
        fileManager: FileManager,
        checkCancellation: @Sendable () throws -> Void = {}
    ) throws -> FolderPlaylist {
        try checkCancellation()
        let folderURL = NormalizedFileURL.resolveFilesystemIdentity(folderURL) ?? folderURL
        try checkCancellation()
        let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw FolderPlaylistDiscoveryError.notDirectory(folderURL)
        }
        let directChildren = try fileManager.contentsOfDirectory(at: folderURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var metadataDates: [URL: Date] = [:]
        let regularFiles = try directChildren.compactMap { originalURL -> URL? in
            try checkCancellation()
            if !MediaFileSupport.isSupportedMediaFile(originalURL),
               !MediaFileSupport.isSupportedSubtitleFile(originalURL),
               (try? originalURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
                return nil
            }
            let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) ?? originalURL
            try checkCancellation()
            let isMedia = MediaFileSupport.isSupportedMediaFile(url)
            guard isMedia || MediaFileSupport.isSupportedSubtitleFile(url) else { return nil }
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            if regular, isMedia, let date = FolderPlaylistItem.metadataDate(for: url) {
                metadataDates[NormalizedFileURL.normalize(url) ?? url] = date
            }
            return regular ? url : nil
        }
        try checkCancellation()
        let playlist = FolderPlaylistDiscovery.makePlaylist(folderURL: folderURL,
            mediaURLs: regularFiles.filter(MediaFileSupport.isSupportedMediaFile),
            subtitleURLs: regularFiles.filter(MediaFileSupport.isSupportedSubtitleFile), metadataDates: metadataDates)
        try checkCancellation()
        return playlist
    }
}

private func classificationFileManager(entries: [URL]) -> FileManager {
    #if canImport(Darwin)
    return ClassificationListingFileManager(entries: entries)
    #else
    // Every entry belongs to the real fixture directory on both platforms.
    // Linux keeps output and checkpoint coverage using its actual enumeration.
    return FileManager.default
    #endif
}

#if canImport(Darwin)
private final class ClassificationListingFileManager: FileManager, @unchecked Sendable {
    let entries: [URL]
    init(entries: [URL]) {
        self.entries = entries
        super.init()
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        entries
    }
}
#endif

private enum ClassificationCancellation: Error, Equatable { case stop }

private final class ClassificationCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let stopAt: Int?
    private var calls = 0

    init(stopAt: Int? = nil) { self.stopAt = stopAt }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls == stopAt { throw ClassificationCancellation.stop }
    }
}

private final class ClassificationFixture {
    let directory: TemporaryDirectory
    let folder: URL
    let entries: [URL]
    let englishSubtitle: URL
    let frenchSubtitle: URL

    init() throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.createDirectory("selected")
        let video = try directory.createFile("targets/Episode 2.MKV")
        let english = try directory.createFile("targets/Episode 2.en.SRT")
        let french = try directory.createFile("targets/Episode 2.fr.ass")
        let unsupported = try directory.createFile("targets/notes.txt")
        func link(_ name: String, to target: URL) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }
        var entries = [
            try directory.createFile("selected/Episode 10.MP4"),
            try directory.createFile("selected/Episode 10.en.vtt"),
            try link("feature.VTT", to: video),
            try link("shortcut", to: video),
            try link("captions.MKV", to: english),
            try link("captions-copy.txt", to: english),
            try link("french", to: french),
            try directory.createFile("selected/notes.nfo"),
            try link("looks.MKV", to: unsupported),
        ]
        try directory.createFile("selected/collection.MKV/Nested.mp4")
        entries.append(folder.appendingPathComponent("collection.MKV", isDirectory: true))
        entries.append(try link("missing.MP4", to: directory.url.appendingPathComponent("absent.mp4")))
        try directory.createFile("selected/documents/Nested.mp4")
        entries.append(folder.appendingPathComponent("documents", isDirectory: true))
        entries.append(try link("linkedCollection.MKV", to: video.deletingLastPathComponent()))
        self.directory = directory
        self.folder = folder
        self.entries = entries
        englishSubtitle = english
        frenchSubtitle = french
    }
}
