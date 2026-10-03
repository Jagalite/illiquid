import Foundation
import Testing
import SuperplayrCore

@Suite("Local media sidecars")
struct MediaSidecarTests {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let season = root.appendingPathComponent("Season 2")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Season 2")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("title: Show\nep: S03E04: Season 2/opaque.mkv\nep: 8: Season 2/implicit.mkv".utf8)
            .write(to: root.appendingPathComponent(".plexmatch"))
        try Data("season: 7".utf8).write(to: child.appendingPathComponent(".plexmatch"))
        #expect(try MediaSidecarReader().recognize(child.appendingPathComponent("opaque.mkv"), within: root).season == 3)
        #expect(try MediaSidecarReader().recognize(child.appendingPathComponent("implicit.mkv"), within: root).season == 7)
    }

    @Test func readerDoesNotFollowSidecarLinksOrReadAboveSourceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
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
}
