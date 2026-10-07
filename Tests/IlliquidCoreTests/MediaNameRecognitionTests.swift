import Foundation
import Testing
import IlliquidCore

@Suite("Local media naming recognition")
struct MediaNameRecognitionTests {
    @Test(arguments: [
        "TV/The Office (2005)/Season 01/The.Office.S01E02.Diversity.Day.1080p.WEB-DL.mkv",
        "TV/The Office (2005)/Season 01/S01E02 - Diversity Day.mkv",
        "The Office (2005) - 1x02 - Diversity Day.mp4"
    ])
    func episodes(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .episode)
        #expect(media.title == "The Office")
        #expect(media.year == 2005)
        #expect(media.season == 1)
        #expect(media.episode == 2)
        #expect(media.episodeTitle == "Diversity Day")
    }

    @Test func multiEpisodeSpecialAndDate() {
        let multi = MediaNameRecognition.recognize(relativePath: "Show - s02e18-e19 - Finale.mkv")
        #expect(multi.lastEpisode == 19)
        #expect(multi.displayName == "S02E18–E19 · Finale")
        let special = MediaNameRecognition.recognize(relativePath: "Show (2020)/Specials/S00E01.mkv")
        #expect(special.year == 2020)
        #expect(special.section == "TV Shows · Show (2020) · Specials")
        for name in ["News - 2024-02-29 - Headlines.mkv", "News - 29.02.2024 - Headlines.mkv"] {
            let media = MediaNameRecognition.recognize(relativePath: name)
            #expect(media.airDate == "2024-02-29")
            #expect(media.episodeTitle == "Headlines")
        }
        #expect(MediaNameRecognition.recognize(relativePath: "News - 2023-02-29.mkv").kind == .unknown)
    }

    @Test func moviesEditionsAndVersions() {
        let media = MediaNameRecognition.recognize(relativePath:
            "Movies/Blade Runner (1982) {imdb-tt0083658}/Blade.Runner.1982.{edition-Final Cut}.part2.2160p.HEVC.mkv")
        #expect(media.kind == .movie)
        #expect(media.title == "Blade Runner")
        #expect(media.year == 1982)
        #expect(media.edition == "Final Cut")
        #expect(media.catalogIDs == ["imdb-tt0083658"])
        #expect(media.variant?.contains("part2") == true)
        #expect(media.variant?.contains("2160p") == true)
        let remaster = MediaNameRecognition.recognize(relativePath: "Film (1995) {edition-2020 Remaster}.mkv")
        #expect(remaster.year == 1995)
        #expect(remaster.title == "Film")
        #expect(MediaNameRecognition.recognize(relativePath: "2001 A Space Odyssey (1968).mkv").title == "2001 A Space Odyssey")
        #expect(MediaNameRecognition.recognize(relativePath: "七人の侍 (1954).mkv").title == "七人の侍")
    }

    @Test func folderEvidenceMustRelateToTheFile() {
        for file in ["movie.mkv", "Arrival.1080p.mkv"] {
            let media = MediaNameRecognition.recognize(relativePath: "Arrival (2016)/" + file)
            #expect(media.kind == .movie)
            #expect(media.title == "Arrival")
            #expect(media.year == 2016)
        }
        #expect(MediaNameRecognition.recognize(relativePath: "Arrival (2016) {imdb-tt2543164}/random.mkv").kind == .unknown)
        #expect(MediaNameRecognition.recognize(relativePath: "Show {tvdb-1234}.mkv").kind == .unknown)
        #expect(MediaNameRecognition.recognize(relativePath: "Arrival {imdb-tt2543164}.mkv").kind == .movie)
    }

    @Test(arguments: ["Movie (2020)-trailer.mp4", "Movie (2020)/Behind The Scenes/Making of.mkv", "Show S01E01-deleted.mkv"])
    func extrasTakePriority(_ path: String) {
        #expect(MediaNameRecognition.recognize(relativePath: path).kind == .extra)
    }

    @Test(arguments: ["vacation.mp4", "Anime - 012 [1080p].mkv", "S01E01.mkv", "clip1920x1080.mp4", "2024.mp4", "family.mov"])
    func ambiguousNamesStayIntact(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .unknown)
        #expect(media.displayName == (path as NSString).deletingPathExtension)
    }
}
