import Foundation
import Testing
@testable import IlliquidCore

@Suite("Local media sidecars")
struct MediaSidecarTests {
    @Test func sidecarIdentifiersMergeWithoutErasingOtherProviders() throws {
        var hints = MediaMetadataHints()
        hints.content = .movie
        hints.catalogIDs = ["imdb-tt999"]
        let movie = MediaNameRecognition.recognize(relativePath: "Movie {tmdb-123}.mkv")
        let resolved = movie.applying(hints)
        #expect(resolved.catalogIDs.contains("imdb-tt999"))
        #expect(resolved.catalogIDs.contains("tmdb-123"))
    }

    @Test func plexMappingsAndPrecedence() throws {
        let plex = try #require(PlexMatchHints.parse("""
            # Explicit identities, including filenames with colons
            TITLE: Correct Show
            Year: 2019
            Season: 2
            tvdbid: 1234
            guid: imdb://tt123456
            ep: 03: Pilot: Part 1.mkv
            episode: S03E04-E05: Season 3/Finale.mkv
            ep: SP01: Bonus.mkv
            ep: S03E04-S04E05: invalid.mkv
            ep: 99: ../escape.mkv
            """))
        let mapped = plex.hints(for: "Pilot: Part 1.mkv")
        #expect(mapped.title == "Correct Show")
        #expect(mapped.year == 2019)
        #expect(mapped.season == 2)
        #expect(mapped.episode == 3)
        #expect(mapped.catalogIDs.contains("tvdb-1234"))
        #expect(mapped.catalogIDs.contains("imdb-tt123456"))
        let range = plex.hints(for: "Season 3/Finale.mkv")
        #expect(range.season == 3)
        #expect(range.lastEpisode == 5)
        #expect(plex.hints(for: "Bonus.mkv").season == 0)
        #expect(plex.hints(for: "invalid.mkv").episode == nil)
        #expect(plex.hints(for: "../escape.mkv").episode == nil)
        #expect(plex.hints(for: "Season 3/Finale.mkv", inheritsDescendantMappings: false).episode == nil)
        #expect(try #require(PlexMatchHints.parse("ep: 2: file.mkv")).hints(for: "file.mkv", defaultSeason: 4).season == 4)
        #expect(PlexMatchHints.parse("pattern: unsupported {ep}.mkv") == nil)
    }

    @Test func nfoMovieAndEpisodeFieldsAreScoped() throws {
        let movie = try #require(NFOMetadataHints.parse(Data("""
            <movie><title>Amélie &amp; Friends</title><year>2001</year>
            <uniqueid type="imdb">tt0211915</uniqueid>
            <actor><name>A Person</name><title>Wrong title</title></actor></movie>
            """.utf8)))
        #expect(movie.title == "Amélie & Friends")
        #expect(movie.year == 2001)
        #expect(movie.catalogIDs == ["imdb-tt0211915"])
        let episode = try #require(NFOMetadataHints.parse(Data("""
            <episodedetails><title><![CDATA[Pilot & Part 1]]></title><showtitle>The Show</showtitle>
            <season>0</season><episode>2</episode><year>2025</year><uniqueid type="tvdb">333</uniqueid></episodedetails>
            """.utf8)))
        #expect(episode.title == "The Show")
        #expect(episode.episodeTitle == "Pilot & Part 1")
        #expect(episode.season == 0)
        #expect(episode.episode == 2)
        #expect(episode.year == nil) // Episode air year is not the series release year.
        #expect(episode.catalogIDs.isEmpty) // Episode IDs are not series IDs.
    }

    @Test(arguments: [
        "<movie><title>Broken", "<unexpected><title>Wrong root</title></unexpected>",
        "<!DOCTYPE movie [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><movie><title>&x;</title></movie>",
        "<movie><year>-1</year><uniqueid type='imdb'>bad</uniqueid></movie>"
    ])
    func malformedNFOIsIgnored(_ text: String) {
        #expect(NFOMetadataHints.parse(Data(text.utf8)) == nil)
    }

    @Test func readersBoundSizeAndCacheSharedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("title: Correct Show\nseason: 4\nep: 1: opaque.mkv".utf8).write(to: root.appendingPathComponent(".plexmatch"))
        let reader = MediaSidecarReader()
        let file = root.appendingPathComponent("opaque.mkv")
        let first = try reader.recognize(file, within: root)
        #expect(first.title == "Correct Show")
        #expect(first.kind == .episode)
        #expect(first.season == 4)
        #expect(first.episode == 1)
        #expect(first.metadataSources == [".plexmatch"])
        _ = try reader.recognize(file, within: root)
        #expect(reader.filesRead == 1)
        try Data(repeating: 65, count: MediaSidecarReader.maximumFileBytes + 1).write(to: root.appendingPathComponent("opaque.nfo"))
        #expect(try MediaSidecarReader().recognize(file, within: root) == first)
        #expect(NFOMetadataHints.parse(Data(repeating: 65, count: 128 * 1024 + 1)) == nil)
    }

    @Test func filenameNFOOverridesSeriesHintsAndNewScanSeesEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let season = root.appendingPathComponent("Season 2", isDirectory: true)
        try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
        try Data("<tvshow><title>The Series</title><year>2010</year></tvshow>".utf8).write(to: root.appendingPathComponent("tvshow.nfo"))
        try Data("season: 3\nep: 7: Season 2/opaque.mkv".utf8).write(to: root.appendingPathComponent(".plexmatch"))
        let own = season.appendingPathComponent("opaque.nfo")
        try Data("<episodedetails><title>Finale</title><season>2</season><episode>9</episode></episodedetails>".utf8).write(to: own)
        let file = season.appendingPathComponent("opaque.mkv")
        let result = try MediaSidecarReader().recognize(file, within: root)
        #expect(result.title == "The Series")
        #expect(result.year == 2010)
        #expect(result.season == 2)
        #expect(result.episode == 9)
        #expect(result.episodeTitle == "Finale")
        #expect(result.metadataSources == [".plexmatch", "NFO"])
        try Data("<episodedetails><title>Changed</title><season>2</season><episode>10</episode></episodedetails>".utf8).write(to: own)
        #expect(try MediaSidecarReader().recognize(file, within: root).episode == 10)
        let trailer = try MediaSidecarReader().recognize(season.appendingPathComponent("clip-trailer.mp4"), within: root)
        #expect(trailer.kind == .extra)
    }

    @Test func hintsIdentifyNumberedFilesWithOpaqueFolderNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("title: Real Show\nyear: 2020".utf8).write(to: root.appendingPathComponent(".plexmatch"))
        let media = try MediaSidecarReader().recognize(root.appendingPathComponent("S01E02.mkv"), within: root)
        #expect(media.kind == .episode)
        #expect(media.title == "Real Show")
        #expect(media.episode == 2)
        #expect(try MediaSidecarReader().recognize(root.appendingPathComponent("unrelated.mkv"), within: root).kind == .unknown)
    }

    @Test func explicitMappedSeasonWinsOverGeneralChildHint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Season 2", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("title: Show\nep: S03E04: Season 2/opaque.mkv\nep: 8: Season 2/implicit.mkv".utf8)
            .write(to: root.appendingPathComponent(".plexmatch"))
        try Data("season: 7".utf8).write(to: child.appendingPathComponent(".plexmatch"))
        #expect(try MediaSidecarReader().recognize(child.appendingPathComponent("opaque.mkv"), within: root).season == 3)
        #expect(try MediaSidecarReader().recognize(child.appendingPathComponent("implicit.mkv"), within: root).season == 7)
    }

    @Test func readerDoesNotFollowSidecarLinksOrReadAboveSourceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.nfo")
        try Data("<movie><title>Wrong Movie</title></movie>".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("opaque.nfo"), withDestinationURL: outside)
        try Data("title: Wrong Series\nep: 1: child/opaque.mkv".utf8).write(to: root.appendingPathComponent(".plexmatch"))
        let file = child.appendingPathComponent("opaque.mkv")
        #expect(try MediaSidecarReader().recognize(file, within: child).kind == .unknown)
        #expect(try MediaSidecarReader().recognize(file, within: root).title == "Wrong Series")
        #expect(throws: CancellationError.self) {
            try MediaSidecarReader().recognize(file, within: root) { throw CancellationError() }
        }
    }

    @Test(arguments: [false, true])
    func movieSidecarsPreservePrecedenceWithinFilesystemRoot(_ filesystemRoot: Bool) throws {
        let fixture = try temporarySidecarDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let folder = fixture.appendingPathComponent("Movies/Film", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Film.mkv")
        let fallback = folder.appendingPathComponent("Other.mkv")
        try Data().write(to: file)
        try Data().write(to: fallback)
        try Data("<movie><title>Folder Film</title><year>2001</year></movie>".utf8)
            .write(to: folder.appendingPathComponent("movie.nfo"))
        try Data("<movie><title>Per-file Film</title></movie>".utf8)
            .write(to: folder.appendingPathComponent("Film.nfo"))
        let root = filesystemRoot ? URL(fileURLWithPath: "/", isDirectory: true) : fixture
        let reader = MediaSidecarReader()
        let own = try reader.recognize(file, within: root)
        #expect(own.kind == .movie)
        #expect(own.title == "Per-file Film")
        #expect(own.year == 2001)
        #expect(own.metadataSources == ["NFO"])
        let shared = try reader.recognize(fallback, within: root)
        #expect(shared.kind == .movie)
        #expect(shared.title == "Folder Film")
        #expect(shared.year == 2001)
        #expect(shared.metadataSources == ["NFO"])
        let reads = reader.filesRead
        #expect(reads == 2)
        #expect(try reader.recognize(file, within: root) == own)
        #expect(try reader.recognize(fallback, within: root) == shared)
        #expect(reader.filesRead == reads)
        #expect(throws: CancellationError.self) {
            try reader.recognize(file, within: root) { throw CancellationError() }
        }
    }

    @Test(arguments: [false, true])
    func nestedPlexMappingsPreserveEntirePathWithinFilesystemRoot(_ filesystemRoot: Bool) throws {
        let fixture = try temporarySidecarDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let nestedPath = "Épisodes 🦊/Season 2"
        let folder = fixture.appendingPathComponent(nestedPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mappedFile = folder.appendingPathComponent("opaque.mkv")
        let overriddenFile = folder.appendingPathComponent("overridden.mkv")
        try Data().write(to: mappedFile)
        try Data().write(to: overriddenFile)
        try Data("<tvshow><title>NFO Series</title><year>2010</year></tvshow>".utf8)
            .write(to: fixture.appendingPathComponent("tvshow.nfo"))
        try Data("""
            title: Plex Series
            ep: S04E06-E08: \(nestedPath)/opaque.mkv
            ep: S04E09: \(nestedPath)/overridden.mkv
            ep: S09E99: opaque.mkv
            ep: S09E98: pisodes 🦊/Season 2/opaque.mkv
            """.utf8).write(to: fixture.appendingPathComponent(".plexmatch"))
        try Data("season: 7".utf8).write(to: folder.appendingPathComponent(".plexmatch"))
        try Data("""
            <episodedetails><showtitle>Per-file Series</showtitle><title>Finale</title>
            <season>2</season><episode>10</episode></episodedetails>
            """.utf8).write(to: folder.appendingPathComponent("overridden.nfo"))
        let root = filesystemRoot ? URL(fileURLWithPath: "/", isDirectory: true) : fixture
        let reader = MediaSidecarReader()
        let mapped = try reader.recognize(mappedFile, within: root)
        #expect(mapped.kind == .episode)
        #expect(mapped.title == "Plex Series")
        #expect(mapped.year == 2010)
        #expect(mapped.season == 4)
        #expect(mapped.episode == 6)
        #expect(mapped.lastEpisode == 8)
        #expect(mapped.metadataSources == [".plexmatch", "NFO"])
        let overridden = try reader.recognize(overriddenFile, within: root)
        #expect(overridden.title == "Per-file Series")
        #expect(overridden.season == 2)
        #expect(overridden.episode == 10)
        #expect(overridden.lastEpisode == nil)
        #expect(overridden.episodeTitle == "Finale")
        #expect(overridden.metadataSources == [".plexmatch", "NFO"])
        #expect(reader.filesRead == 4)
        #expect(try reader.recognize(mappedFile, within: root) == mapped)
        #expect(reader.filesRead == 4)
    }

    @Test func siblingPrefixDoesNotReadSidecars() throws {
        let fixture = try temporarySidecarDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Library", isDirectory: true)
        let sibling = fixture.appendingPathComponent("Library-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("Film.mkv")
        try Data().write(to: file)
        try Data("title: Wrong Series\nep: 7: Film.mkv".utf8)
            .write(to: sibling.appendingPathComponent(".plexmatch"))
        try Data("<movie><title>Wrong Folder Film</title></movie>".utf8)
            .write(to: sibling.appendingPathComponent("movie.nfo"))
        try Data("<movie><title>Wrong Per-file Film</title></movie>".utf8)
            .write(to: sibling.appendingPathComponent("Film.nfo"))
        let reader = MediaSidecarReader()
        #expect(try reader.recognize(file, within: root) == MediaNameRecognition.recognize(relativePath: file.path))
        #expect(reader.filesRead == 0)
    }

    @Test func filesystemRootMappingKeyKeepsItsFirstComponent() throws {
        let fixture = try temporarySidecarDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let folder = fixture.appendingPathComponent("Épisodes 🦊/Season 2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("opaque.mkv")
        try Data().write(to: file)
        let expected = file.pathComponents.dropFirst().joined(separator: "/")
        let sidecar = fixture.appendingPathComponent(".plexmatch")
        // Store a root-relative mapping in the fixture instead of writing /.plexmatch.
        try Data("""
            title: Root Series
            ep: S03E05: \(expected)
            ep: S09E99: \(expected.dropFirst())
            """.utf8).write(to: sidecar)
        let relative = try #require(MediaSidecarReader.relativePath(file.path, within: "/"))
        #expect(relative == expected)
        let plex = try #require(PlexMatchHints.parse(String(contentsOf: sidecar, encoding: .utf8)))
        let hints = plex.hints(for: relative)
        #expect(hints.season == 3)
        #expect(hints.episode == 5)
        #expect(MediaSidecarReader.relativePath("/", within: "/") == "")
        #expect(MediaSidecarReader.relativePath("/Library-other/Film.mkv", within: "/Library") == nil)
    }

    private func temporarySidecarDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
