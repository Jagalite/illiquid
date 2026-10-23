import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Recursive media loader regressions")
struct SourceRecursiveMediaLoaderTests {
    @Test("Nested media respects hidden entries and package descendants")
    func nestedMediaAndHiddenEntries() throws {
        let fixture = try RecursiveLoaderTestFixture()
        defer { fixture.remove() }
        var expected = try [
            fixture.file("Feature.MKV"),
            fixture.file("Season 01/Episode.mp4"),
            fixture.file("日本語/Cafe\u{301}.mov"),
        ]
        for (directory, media) in [
            ("Collection.mkv", "Collection.mkv/Inside.webm"),
            ("Bundle.app", "Bundle.app/Contents/Hidden.mkv"),
        ] {
            let nestedMedia = try fixture.file(media)
            let folder = fixture.root.appendingPathComponent(directory, isDirectory: true)
            let isPackage = try folder.resourceValues(forKeys: [.isPackageKey]).isPackage == true
            #if os(macOS)
            if directory == "Bundle.app" { #expect(isPackage) }
            #endif
            if !isPackage { expected.append(nestedMedia) }
        }
        for name in [
            "notes.txt", "Season 01/Episode.en.srt", "poster.jpg",
            ".hidden.mp4", ".Hidden/Secret.mkv",
        ] {
            try fixture.file(name)
        }

        let entries = SourceRecursiveMediaLoader.read([fixture.root])

        #expect(Set(entries.map(\.url)) == Set(expected.map(RecursiveLoaderTestFixture.resolved)))
        #expect(entries.allSatisfy { $0.kind == .media })
        #expect(entries.allSatisfy { $0.visibilityPath != nil })
        #expect(entries.allSatisfy { $0.recognizedMedia == nil })
    }

    @Test("Explicit files retain their existing admission and date behavior")
    func explicitUnsupportedAndMissingFiles() throws {
        let fixture = try RecursiveLoaderTestFixture()
        defer { fixture.remove() }
        let unsupported = try fixture.file("notes.txt")
        let missing = fixture.root.appendingPathComponent("missing.bin", isDirectory: false)

        let entries = SourceRecursiveMediaLoader.read(
            [], files: [unsupported, missing, unsupported, missing]
        )

        #expect(entries.map(\.url) == [unsupported, missing].map(RecursiveLoaderTestFixture.resolved))
        #expect(entries.allSatisfy { $0.kind == .media })
        #expect(entries.allSatisfy { $0.dateAdded == nil && $0.creationDate == nil })
        #expect(entries.allSatisfy { $0.visibilityPath != nil })
    }

    @Test("Overlapping roots and explicit duplicates retain scanned metadata")
    func overlappingRootsKeepDates() throws {
        let fixture = try RecursiveLoaderTestFixture()
        defer { fixture.remove() }
        let first = try fixture.file("First.mkv")
        let nested = try fixture.file("Season 01/Second.mp4")
        let folder = fixture.root.appendingPathComponent("Season 01", isDirectory: true)
        let original = SourceRecursiveMediaLoader.read([fixture.root])

        let overlapping = SourceRecursiveMediaLoader.read(
            [fixture.root, folder, fixture.root], files: [nested, first, nested]
        )

        #expect(original.count == 2)
        #expect(original.allSatisfy { $0.dateAdded != nil && $0.creationDate != nil })
        #expect(overlapping.sorted { $0.url.path < $1.url.path }
            == original.sorted { $0.url.path < $1.url.path })
    }

    @Test("Excluded NFO entries still provide requested media metadata")
    func sidecarMetadataRemainsAvailable() throws {
        let fixture = try RecursiveLoaderTestFixture()
        defer { fixture.remove() }
        let media = try fixture.file("opaque.mkv")
        try fixture.file("opaque.nfo", contents: """
            <movie><title>Sidecar Movie</title><year>1999</year>
            <uniqueid type="imdb">tt12345</uniqueid></movie>
            """)
        try fixture.file("poster.jpg")

        let plain = SourceRecursiveMediaLoader.read([fixture.root])
        let recognized = SourceRecursiveMediaLoader.read([fixture.root], readsMetadata: true)

        #expect(plain.count == 1)
        #expect(plain.first?.recognizedMedia == nil)
        #expect(recognized.count == 1)
        #expect(recognized.first?.url == RecursiveLoaderTestFixture.resolved(media))
        #expect(recognized.first?.recognizedMedia?.title == "Sidecar Movie")
        #expect(recognized.first?.recognizedMedia?.year == 1999)
        #expect(recognized.first?.recognizedMedia?.catalogIDs.contains("imdb-tt12345") == true)
    }

    @Test("Cancellation discards a single-root scan and explicit files", arguments: [false, true])
    func cancellationNeverReturnsPartialEntries(_ readsMetadata: Bool) throws {
        let fixture = try RecursiveLoaderTestFixture()
        defer { fixture.remove() }
        try fixture.file("Feature.mkv")
        try fixture.file("Season 01/Episode.mp4")
        try fixture.file("Season 01/Episode.nfo", contents: "<movie><title>Episode</title></movie>")
        for index in 0..<6 { try fixture.file("notes-\(index).txt") }
        let explicit = fixture.root.appendingPathComponent("missing.bin", isDirectory: false)
        let successfulProbe = RecursiveLoaderCancellationProbe()
        let successful = SourceRecursiveMediaLoader.read(
            [fixture.root], files: [explicit], readsMetadata: readsMetadata,
            checkCancellation: { try successfulProbe.check() }
        )
        #expect(successful.count == 3)
        let pollCount = successfulProbe.count
        try #require(pollCount > 0)

        // Derive checkpoints from the implementation under test. The number of
        // polls is deliberately not part of the scanner's public contract.
        for throwAt in 1...pollCount {
            let cancelled = RecursiveLoaderCancellationProbe(throwAt: throwAt)
            let entries = SourceRecursiveMediaLoader.read(
                [fixture.root], files: [explicit], readsMetadata: readsMetadata,
                checkCancellation: { try cancelled.check() }
            )
            #expect(cancelled.count >= throwAt)
            #expect(entries.isEmpty)
        }
    }

    @Test("Root aliases preserve identity without changing entry-link admission")
    func rootAndEntrySymlinks() throws {
        let fixture = try RecursiveLoaderTestFixture()
        defer { fixture.remove() }
        let root = try fixture.directory("library")
        let ordinary = try fixture.file("library/Feature.mkv")
        let target = try fixture.file("targets/Linked.MKV")
        let unsupportedTarget = try fixture.file("targets/notes.txt")
        try fixture.file("targets/HiddenThroughDirectoryLink.mp4")
        let extensionless = try fixture.link("library/shortcut", to: target)
        let misleading = try fixture.link("library/alias.txt", to: target)
        try fixture.link("library/LooksSupported.mp4", to: unsupportedTarget)
        try fixture.link("library/Broken.mkv", to: fixture.root.appendingPathComponent("absent.mkv", isDirectory: false))
        try fixture.link("library/DirectoryLink", to: target.deletingLastPathComponent())
        let rootAlias = try fixture.link("selected-root", to: root)

        // The recursive scanner has always classified the original entry's
        // regular-file key. This differs from shallow playlist discovery, which
        // classifies a resolved target; this optimization must not broaden it.
        var expected: Set<URL> = [RecursiveLoaderTestFixture.resolved(ordinary)]
        for link in [extensionless, misleading] {
            let values = try link.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                expected.insert(RecursiveLoaderTestFixture.resolved(target))
            }
        }
        let direct = SourceRecursiveMediaLoader.read([root])
        let throughAlias = SourceRecursiveMediaLoader.read([rootAlias])

        #expect(Set(direct.map(\.url)) == expected)
        #expect(throughAlias.sorted { $0.url.path < $1.url.path }
            == direct.sorted { $0.url.path < $1.url.path })
    }
}

private struct RecursiveLoaderTestFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("IlliquidRecursiveLoader-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ name: String, contents: String = "") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func link(_ name: String, to target: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    static func resolved(_ url: URL) -> URL {
        NormalizedFileURL.resolveFilesystemIdentity(url) ?? url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecursiveLoaderCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let throwAt: Int?

    init(throwAt: Int? = nil) { self.throwAt = throwAt }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if let throwAt, calls >= throwAt { throw CancellationError() }
    }
}
