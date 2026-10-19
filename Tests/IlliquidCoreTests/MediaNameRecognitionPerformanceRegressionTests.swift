import Foundation
import Testing
import IlliquidCore

@Suite("Media naming context and cleanup regressions")
struct MediaNameRecognitionPerformanceRegressionTests {
    @Test(arguments: [
        "River Station (2020)/S02E03 - The Door.mkv",
        "TV/River Station (2020)/Season 02/S02E03 - The Door.mkv",
        "TV/River Station (2020)/Season 02/River.Station.S02E03.The.Door.mkv"
    ])
    func folderYearIdentifiesEpisodes(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .episode)
        #expect(media.title == "River Station")
        #expect(media.year == 2020)
        #expect(media.season == 2)
        #expect(media.episode == 3)
        #expect(media.episodeTitle == "The Door")
    }

    @Test(arguments: [
        "S01E02.mkv",
        "River Station/S01E02.mkv",
        "Season 01/S01E02.mkv",
        "Specials/S00E01.mkv",
        "TV/{Archive}/Season 01/S01E02.mkv",
        "River Station (20２４)/S01E02.mkv"
    ])
    func isolatedEpisodeMarkersNeedIdentifyingFolderEvidence(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .unknown)
        #expect(media.title == ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        #expect(media.year == nil)
        #expect(media.season == nil)
        #expect(media.episode == nil)
    }

    @Test func aSeasonFolderAllowsAYearlessSeries() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/River Station/Season 02/S02E03 - The Door.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "River Station")
        #expect(media.year == nil)
        #expect(media.season == 2)
        #expect(media.episode == 3)
        #expect(media.episodeTitle == "The Door")
    }

    @Test func specialsRetainSeriesYearAndSeasonZero() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/River Station (2020)/Specials/S00E01 - Pilot.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "River Station")
        #expect(media.year == 2020)
        #expect(media.season == 0)
        #expect(media.episode == 1)
        #expect(media.episodeTitle == "Pilot")
        #expect(media.section == "TV Shows · River Station (2020) · Specials")
    }

    @Test func aDifferentNamedPrefixDoesNotInheritTheFolderYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Other Show (1999)/Season 04/River.Station.S04E07.The.Return.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "River Station")
        #expect(media.year == nil)
        #expect(media.season == 4)
        #expect(media.episode == 7)
        #expect(media.episodeTitle == "The Return")
    }

    @Test func matchingPrefixUsesFolderSpellingWhenInheritingYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/RIVER STATION (2020)/Season 01/river.station.S01E02.Home.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "RIVER STATION")
        #expect(media.year == 2020)
        #expect(media.episodeTitle == "Home")
    }

    @Test func anExplicitPrefixYearKeepsItsOwnIdentity() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/River Station (2020)/Season 01/River.Station.(2021).S01E02.Home.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "River Station")
        #expect(media.year == 2021)
        #expect(media.episodeTitle == "Home")
    }

    @Test(arguments: [
        "River Station [Archive] (2020)",
        "River Station [[Archive]] (2020)",
        "River Station {source-[Archive]} (2020)"
    ])
    func bracketedFolderMetadataDoesNotEnterTheSeriesTitle(_ folder: String) {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/" + folder + "/Season 01/S01E02 - Home.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "River Station")
        #expect(media.year == 2020)
        #expect(media.episodeTitle == "Home")
    }

    @Test func permissiveTagCleanupPreservesUnmatchedText() {
        let unclosed = MediaNameRecognition.recognize(relativePath:
            "TV/River Station [Archive (2020)/Season 01/S01E02.mkv")
        #expect(unclosed.kind == .episode)
        #expect(unclosed.title == "River Station [Archive")
        #expect(unclosed.year == 2020)

        let crossed = MediaNameRecognition.recognize(relativePath:
            "TV/River Station {[x}y] (2020)/Season 01/S01E02.mkv")
        #expect(crossed.kind == .episode)
        #expect(crossed.title == "River Station y")
        #expect(crossed.year == 2020)

        let reversed = MediaNameRecognition.recognize(relativePath:
            "TV/River Station [{x]y} (2020)/Season 01/S01E02.mkv")
        #expect(reversed.kind == .episode)
        #expect(reversed.title == "River Station y}")
        #expect(reversed.year == 2020)
    }

    @Test func taggedMovieFolderStillIdentifiesAGenericFilename() {
        let media = MediaNameRecognition.recognize(relativePath:
            "Movies/River Station [[Archive]] (2020)/movie.mkv")
        #expect(media.kind == .movie)
        #expect(media.title == "River Station")
        #expect(media.year == 2020)
        #expect(media.displayName == "River Station (2020)")
    }

    @Test func unicodeTitlesAndCombiningMarksSurviveFolderInference() {
        let title = "🛰 Cafe\u{301} 世界"
        let episodeTitle = "Nin\u{303}o の帰還"
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/" + title + " (2021)/Season 02/S02E05 - " + episodeTitle + ".mkv")
        #expect(media.kind == .episode)
        #expect(media.title == title)
        #expect(Array(media.title.utf8) == Array(title.utf8))
        #expect(media.year == 2021)
        #expect(media.season == 2)
        #expect(media.episode == 5)
        #expect(media.episodeTitle == episodeTitle)
        #expect(media.displayName == "S02E05 · " + episodeTitle)
    }
}
