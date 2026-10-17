import Foundation
import Testing
import IlliquidCore

@Suite("NFO episode field scope")
struct NFOEpisodeScopeRegressionTests {
    private static let showFields = "<title>Canonical Show</title><year>2010</year><uniqueid type='tvdb'>1234</uniqueid>"
    private static let totals = "<season>5</season><episode>62</episode>"

    @Test(arguments: ["tvshow", "movie"], [0, 1, 5, 999])
    func nonEpisodeNumbersAreNotIdentity(_ root: String, _ count: Int) throws {
        let xml = "<\(root)>\(Self.showFields)<season>\(count)</season><episode>\(count)</episode></\(root)>"
        let hints = try #require(NFOMetadataHints.parse(Data(xml.utf8)))
        #expect(hints.content == (root == "tvshow" ? .show : .movie))
        #expect(hints.title == "Canonical Show")
        #expect(hints.year == 2010)
        #expect(hints.catalogIDs == ["tvdb-1234"])
        #expect(hints.season == nil)
        #expect(hints.episode == nil)
        #expect(hints.sources == ["NFO"])
    }

    @Test(arguments: ["tvshow", "movie"], ["<season>5</season>", "<episode>62</episode>", totals])
    func ignoredNumbersAloneDoNotProduceHints(_ root: String, _ fields: String) {
        #expect(NFOMetadataHints.parse(Data("<\(root)>\(fields)</\(root)>".utf8)) == nil)
    }

    @Test(arguments: [0, 1, 999], [0, 1, 62, 9999])
    func explicitEpisodeNumbersStillWork(_ season: Int, _ episode: Int) throws {
        let xml = "<episodedetails><season>\(season)</season><episode>\(episode)</episode></episodedetails>"
        let hints = try #require(NFOMetadataHints.parse(Data(xml.utf8)))
        #expect(hints.content == .episode)
        #expect(hints.season == season)
        #expect(hints.episode == episode)
    }

    @Test func caseCDATAAndNestedFieldsRespectScope() throws {
        let show = try #require(NFOMetadataHints.parse(Data("""
            <TVSHOW><TITLE><![CDATA[Show & Friends]]></TITLE>
            <SEASON><![CDATA[5]]></SEASON><EPISODE>62</EPISODE></TVSHOW>
            """.utf8)))
        #expect(show.title == "Show & Friends")
        #expect(show.season == nil)
        #expect(show.episode == nil)
        let episode = try #require(NFOMetadataHints.parse(Data("""
            <EPISODEDETAILS><TITLE>Pilot</TITLE><SEASON><![CDATA[0]]></SEASON><EPISODE>2</EPISODE>
            <actor><season>8</season><episode>9</episode><title>Not the title</title></actor></EPISODEDETAILS>
            """.utf8)))
        #expect(episode.episodeTitle == "Pilot")
        #expect(episode.season == 0)
        #expect(episode.episode == 2)
    }

    @Test(arguments: [
        "<season>-1</season><episode>-2</episode>",
        "<season>1000</season><episode>10000</episode>",
        "<season>５</season><episode>٦٢</episode>",
        "<season>1x</season><episode>2.5</episode>"
    ])
    func invalidEpisodeNumbersStayIgnored(_ fields: String) throws {
        let hints = try #require(NFOMetadataHints.parse(Data("<episodedetails><title>Pilot</title>\(fields)</episodedetails>".utf8)))
        #expect(hints.season == nil)
        #expect(hints.episode == nil)
        #expect(hints.episodeTitle == "Pilot")
    }

    @Test func showTotalsPreserveFilenameIdentityAndClassification() throws {
        try withLibrary { root in
            let filenames = [
                "Old Show - S01E02 - Pilot.mkv",
                "Old Show - S02E18-E19 - Finale.1080p.mkv",
                "Specials/S00E01.mkv",
                "News - 2024-02-29 - Headlines.mkv",
                "News - 29.02.2024 - Headlines.mkv",
                "S03E04.mkv",
                "unrelated.mkv",
                "Film (2020).mkv",
                "clip-trailer.mp4"
            ]
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Specials", isDirectory: true), withIntermediateDirectories: true)
            try writeShow(at: root, totals: false)
            let before = MediaSidecarReader()
            let expected = try filenames.map { try before.recognize(root.appendingPathComponent($0), within: root) }
            #expect(expected[0].displayName == "S01E02 · Pilot")
            #expect(expected[1].lastEpisode == 19)
            #expect(expected[2].season == 0)
            #expect(expected[3].airDate == "2024-02-29")
            #expect(expected[5].episode == 4)
            #expect(expected[6].kind == .unknown)
            #expect(expected[7].kind == .movie)
            #expect(expected[8].kind == .extra)
            try writeShow(at: root, totals: true)
            let after = MediaSidecarReader()
            for (index, filename) in filenames.enumerated() {
                let actual = try after.recognize(root.appendingPathComponent(filename), within: root)
                #expect(actual == expected[index], "Show totals changed \(filename)")
                #expect(actual.section == expected[index].section)
                #expect(actual.displayName == expected[index].displayName)
            }
            #expect(before.filesRead == 1)
            #expect(after.filesRead == 1)
        }
    }

    @Test func implicitPlexMappingsUseDirectoryOrDefaultSeasonNotTotals() throws {
        try withLibrary { root in
            for directory in ["Season 2", "Specials"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
            }
            try writeShow(at: root, totals: true)
            try write("ep: 7: Season 2/opaque.mkv\nep: 8: Specials/bonus.mkv\nep: 9: root.mkv", to: root.appendingPathComponent(".plexmatch"))
            let reader = MediaSidecarReader()
            for (path, season, number) in [("Season 2/opaque.mkv", 2, 7), ("Specials/bonus.mkv", 0, 8), ("root.mkv", 1, 9)] {
                let result = try reader.recognize(root.appendingPathComponent(path), within: root)
                #expect(result.title == "Canonical Show")
                #expect(result.season == season)
                #expect(result.episode == number)
            }
        }
    }

    @Test func childShowTotalsDoNotOverrideExplicitPlexSeasonOrRange() throws {
        try withLibrary { root in
            let child = root.appendingPathComponent("Season 2", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try write("title: Plex Show\nseason: 7\nep: 3-4: Season 2/opaque.mkv", to: root.appendingPathComponent(".plexmatch"))
            try writeShow(at: child, totals: true)
            let result = try MediaSidecarReader().recognize(child.appendingPathComponent("opaque.mkv"), within: root)
            #expect(result.title == "Canonical Show")
            #expect(result.season == 7)
            #expect(result.episode == 3)
            #expect(result.lastEpisode == 4)
            #expect(result.metadataSources == [".plexmatch", "NFO"])
        }
    }

    @Test func titleOnlyEpisodeSidecarPreservesRangeAndDate() throws {
        try withLibrary { root in
            try writeShow(at: root, totals: true)
            for filename in ["Show - S02E03-E04.mkv", "News - 2024-02-29.mkv"] {
                let file = root.appendingPathComponent(filename)
                try write("<episodedetails><title>Explicit title</title></episodedetails>", to: file.deletingPathExtension().appendingPathExtension("nfo"))
                let expected = MediaNameRecognition.recognize(relativePath: file.path)
                let actual = try MediaSidecarReader().recognize(file, within: root)
                #expect(actual.season == expected.season)
                #expect(actual.episode == expected.episode)
                #expect(actual.lastEpisode == expected.lastEpisode)
                #expect(actual.airDate == expected.airDate)
                #expect(actual.title == "Canonical Show")
                #expect(actual.episodeTitle == "Explicit title")
            }
        }
    }

    @Test func explicitEpisodeSidecarStillOverridesFilenameRangeAndDate() throws {
        try withLibrary { root in
            try writeShow(at: root, totals: true)
            for filename in ["Show - S02E03-E04.mkv", "News - 2024-02-29.mkv"] {
                let file = root.appendingPathComponent(filename)
                try write("<episodedetails><title>Special</title><season>0</season><episode>9</episode></episodedetails>", to: file.deletingPathExtension().appendingPathExtension("nfo"))
                let actual = try MediaSidecarReader().recognize(file, within: root)
                #expect(actual.season == 0)
                #expect(actual.episode == 9)
                #expect(actual.lastEpisode == nil)
                #expect(actual.airDate == nil)
                #expect(actual.displayName == "S00E09 · Special")
            }
        }
    }

    @Test(arguments: ["tvshow", "movie", "episodedetails"])
    func malformedFileCannotReplaceFilename(_ rootName: String) throws {
        try withLibrary { root in
            let file = root.appendingPathComponent("Show (2010) - S02E03 - Pilot.mkv")
            let expected = try MediaSidecarReader().recognize(file, within: root)
            let sidecar = rootName == "tvshow" ? root.appendingPathComponent("tvshow.nfo")
                : file.deletingPathExtension().appendingPathExtension("nfo")
            // A complete title followed by an unfinished document must not leak hints.
            try write("<\(rootName)><title>Wrong title</title><season>5</season><episode>62</episode>", to: sidecar)
            let reader = MediaSidecarReader()
            let actual = try reader.recognize(file, within: root)
            #expect(reader.filesRead == 1)
            #expect(actual == expected)
        }
    }

    @Test(arguments: ["tvshow", "movie", "episodedetails"])
    func everyIncompleteDocumentPrefixIsRejected(_ rootName: String) {
        let bytes = Array("<\(rootName)><title>Complete title</title><season>1</season><episode>2</episode></\(rootName)>".utf8)
        for length in 0..<bytes.count {
            #expect(NFOMetadataHints.parse(Data(bytes.prefix(length))) == nil,
                    "Accepted truncated \(rootName) at byte \(length)")
        }
    }

    @Test func validDocumentsAtTheLimitsStillParse() throws {
        let title = String(repeating: "x", count: 4096)
        let hints = try #require(NFOMetadataHints.parse(Data("<tvshow><title>\(title)</title></tvshow>".utf8)))
        #expect(hints.title == title)
        let start = "<tvshow><title>Valid</title>"
        let end = "</tvshow>"
        let exactLimit = start + String(repeating: " ", count: 128 * 1024 - start.utf8.count - end.utf8.count) + end
        #expect(exactLimit.utf8.count == 128 * 1024)
        #expect(NFOMetadataHints.parse(Data(exactLimit.utf8))?.title == "Valid")
        let declaredUTF8 = "\u{feff}<?xml version='1.0' encoding='UTF-8'?><tvshow><title>世界 &amp; Friends</title></tvshow>"
        #expect(NFOMetadataHints.parse(Data(declaredUTF8.utf8))?.title == "世界 & Friends")
    }

    @Test func parserLimitsAndMalformedInputRemainRejected() {
        let rejected = [
            "<tvshow><title>Valid</title>" + Self.totals,
            "<tvshow><title>Valid</title></tvshow><episodedetails><episode>1</episode></episodedetails>",
            "<!DOCTYPE tvshow><tvshow><title>Valid</title></tvshow>",
            "<!ENTITY x 'Valid'><tvshow><title>Valid</title></tvshow>",
            "<tvshow><title>" + String(repeating: "x", count: 4097) + "</title></tvshow>",
            "<tvshow><title>Valid</title>" + String(repeating: "<x>", count: 33) + String(repeating: "</x>", count: 33) + "</tvshow>",
            "<tvshow><title>Valid</title>" + String(repeating: " ", count: 128 * 1024) + "</tvshow>"
        ]
        for xml in rejected {
            #expect(NFOMetadataHints.parse(Data(xml.utf8)) == nil, "Accepted malformed/bounded input: \(xml.prefix(80))")
        }
        #expect(NFOMetadataHints.parse(Data([0xff, 0xfe, 0x80])) == nil)
    }

    private func withLibrary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nfo-scope-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writeShow(at root: URL, totals: Bool) throws {
        try write("<tvshow>\(Self.showFields)\(totals ? Self.totals : "")</tvshow>", to: root.appendingPathComponent("tvshow.nfo"))
    }

    private func write(_ text: String, to file: URL) throws {
        try Data(text.utf8).write(to: file)
    }
}
