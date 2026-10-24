import Foundation
import Testing
@testable import IlliquidCore

@Suite("PlexMatch episode mapping validation")
struct PlexMatchHintsRegressionTests {
    struct ValidExample: Sendable {
        let token: String
        let season: Int
        let episode: Int
        let lastEpisode: Int?
    }

    static let validExamples: [ValidExample] = [
        .init(token: "01", season: 7, episode: 1, lastEpisode: nil),
        .init(token: "E02", season: 7, episode: 2, lastEpisode: nil),
        .init(token: "SP04", season: 0, episode: 4, lastEpisode: nil),
        .init(token: "S03E04", season: 3, episode: 4, lastEpisode: nil),
        .init(token: "01-02", season: 7, episode: 1, lastEpisode: 2),
        .init(token: "E01-E02", season: 7, episode: 1, lastEpisode: 2),
        .init(token: "S01E01-E02", season: 1, episode: 1, lastEpisode: 2),
        .init(token: "S03E12-S03E13", season: 3, episode: 12, lastEpisode: 13),
        .init(token: "SP01-E02", season: 0, episode: 1, lastEpisode: 2),
        .init(token: "SP01-S00E02", season: 0, episode: 1, lastEpisode: 2),
        .init(token: "s03e04-e05", season: 3, episode: 4, lastEpisode: 5),
        .init(token: "sp01", season: 0, episode: 1, lastEpisode: nil),
        .init(token: "S000E0000", season: 0, episode: 0, lastEpisode: nil),
        .init(token: "S999E9998-S999E9999", season: 999, episode: 9998, lastEpisode: 9999),
    ]

    // Every numeric capture is covered, including partially ASCII fields and
    // supplementary-plane digits. Unicode remains valid in titles and paths.
    static let invalidUnicodeTokens = [
        "０２", "E０２", "SP０１", "S０２E03", "S02E０３",
        "S02E03-E０５", "S02E03-S０４E05", "S02E03-S04E０５",
        "S0２E03", "S02E0３", "S02E03-E0５", "S02E03-S0４E05",
        "E٠٢", "SP٠١", "S٠٢E03", "S02E٠٣", "S02E03-E٠٥", "S02E03-S٠٤E05",
        "E०२", "S०२E03", "S02E03-E०५", "S02E03-S०४E05",
        "E𝟎𝟐", "S𝟎𝟐E03", "S02E03-E𝟎𝟓", "S02E03-S𝟎𝟒E05",
    ]

    @Test(arguments: validExamples)
    func documentedFormatsAndBoundsRemainSupported(_ example: ValidExample) throws {
        let plex = try #require(PlexMatchHints.parse("season: 7\nep: \(example.token): file.mkv"))
        let hints = plex.hints(for: "file.mkv")
        #expect(hints.season == example.season)
        #expect(hints.episode == example.episode)
        #expect(hints.lastEpisode == example.lastEpisode)
    }

    @Test(arguments: invalidUnicodeTokens)
    func invalidOnlyFileIsNotAcceptedAsSeriesMetadata(_ token: String) {
        #expect(PlexMatchHints.parse("ep: \(token): file.mkv") == nil)
    }

    @Test(arguments: invalidUnicodeTokens)
    func invalidMappingDoesNotOverrideFilenameEvidence(_ token: String) throws {
        let path = "Show - S04E06E08.mkv"
        let plex = try #require(PlexMatchHints.parse("title: Show\nep: \(token): \(path)"))
        #expect(plex.episodeHint(for: path, inheritsDescendantMappings: true) == nil)
        let filename = MediaNameRecognition.recognize(relativePath: path)
        #expect(filename.applying(plex.hints(for: path)) == filename.applying(plex.metadata))
    }

    @Test(arguments: invalidUnicodeTokens)
    func invalidLaterMappingDoesNotEraseValidEarlierMapping(_ token: String) throws {
        let valid = "title: Show\nseason: 7\nep: S04E06-E08: file.mkv"
        let expected = try #require(PlexMatchHints.parse(valid)).hints(for: "file.mkv")
        let parsed = try #require(PlexMatchHints.parse(valid + "\nep: \(token): file.mkv"))
        #expect(parsed.hints(for: "file.mkv") == expected)
    }

    @Test(arguments: [
        "S1000E01", "S01E10000", "S01E01-E10000", "S01E01-S1000E02",
        "S01E02-E01", "S01E02-E02", "S01E02-S02E03", "SP01-S01E02",
        "-1", "+1", "S-1E02", "E1.5", "E", "S01E", "S01E02suffix", "S01E02 "
    ])
    func invalidASCIIMappingsRemainRejected(_ token: String) {
        #expect(PlexMatchHints.parse("ep: \(token): file.mkv") == nil)
    }

    @Test func laterValidMappingStillReplacesAnEarlierMapping() throws {
        let plex = try #require(PlexMatchHints.parse("ep: S02E03-E05: file.mkv\nep: S04E07: file.mkv"))
        let hints = plex.hints(for: "file.mkv")
        #expect(hints.season == 4)
        #expect(hints.episode == 7)
        #expect(hints.lastEpisode == nil)
    }

    @Test func inheritedSeasonDefaultsAndExplicitSpecialsAreUnchanged() throws {
        let plex = try #require(PlexMatchHints.parse("ep: E02: regular.mkv\nep: SP03: special.mkv"))
        #expect(plex.hints(for: "regular.mkv").season == 1)
        #expect(plex.hints(for: "regular.mkv", defaultSeason: 4).season == 4)
        #expect(plex.hints(for: "special.mkv", defaultSeason: 4).season == 0)
        let explicit = try #require(PlexMatchHints.parse("season: 7\nep: E02: file.mkv"))
        #expect(explicit.hints(for: "file.mkv", defaultSeason: 4).season == 7)
    }

    @Test(arguments: [
        ("E02", nil, 2, nil),
        ("01-02", nil, 1, 2),
        ("SP04", 0, 4, nil),
        ("SP01-S00E02", 0, 1, 2),
        ("s03e04-e05", 3, 4, 5),
        ("S000E0000", 0, 0, nil),
        ("S999E9998-S999E9999", 999, 9998, 9999),
    ] as [(String, Int?, Int, Int?)])
    func rawMappingsContainOnlyExplicitEpisodeIdentity(
        _ example: (String, Int?, Int, Int?)
    ) throws {
        let (token, season, episode, lastEpisode) = example
        let plex = try #require(PlexMatchHints.parse("""
            title: Show
            year: 2019
            season: 7
            tvdbid: 42
            guid: imdb://tt123
            ep: \(token): file.mkv
            """))
        var expected = MediaMetadataHints()
        expected.content = .episode
        expected.season = season
        expected.episode = episode
        expected.lastEpisode = lastEpisode
        // A raw mapping must not carry inherited series fields or attribution.
        // In particular, an omitted season is distinct from an explicit zero.
        #expect(plex.episodeHint(for: "file.mkv", inheritsDescendantMappings: true) == expected)

        expected.title = "Show"
        expected.year = 2019
        expected.season = season ?? 7
        expected.catalogIDs = ["tvdb-42", "imdb-tt123"]
        expected.sources = [".plexmatch"]
        #expect(plex.hints(for: "file.mkv", defaultSeason: 4) == expected)
    }

    @Test func implicitReplacementClearsEarlierExplicitSeasonAndRange() throws {
        let plex = try #require(PlexMatchHints.parse("""
            season: 7
            ep: S03E04-E08: file.mkv
            ep: E06: file.mkv
            """))
        var expected = MediaMetadataHints()
        expected.content = .episode
        expected.episode = 6
        #expect(plex.episodeHint(for: "file.mkv", inheritsDescendantMappings: true) == expected)
        #expect(plex.hints(for: "file.mkv", defaultSeason: 4).season == 7)
        #expect(plex.hints(for: "file.mkv").lastEpisode == nil)
    }

    @Test func returnedHintsDoNotMutateTheIndexOrItsCopies() throws {
        let plex = try #require(PlexMatchHints.parse("""
            title: Show
            tvdbid: 42
            ep: E02: regular.mkv
            ep: SP03-E05: special.mkv
            """))
        let copied = plex
        let expectedMetadata = plex.metadata
        let expectedRaw = try #require(plex.episodeHint(for: "regular.mkv", inheritsDescendantMappings: true))
        let expectedMerged = plex.hints(for: "regular.mkv", defaultSeason: 4)
        let expectedOther = plex.hints(for: "special.mkv")

        var raw = expectedRaw
        raw.title = "Changed"
        raw.season = 99
        raw.catalogIDs.append("tmdb-1")
        raw.sources.append("caller")
        var merged = expectedMerged
        merged.episode = 100
        merged.catalogIDs.removeAll()
        merged.sources.append("caller")
        #expect(raw != expectedRaw && merged != expectedMerged)

        for index in [plex, copied] {
            #expect(index.metadata == expectedMetadata)
            #expect(index.episodeHint(for: "regular.mkv", inheritsDescendantMappings: true) == expectedRaw)
            #expect(index.hints(for: "regular.mkv", defaultSeason: 4) == expectedMerged)
            #expect(index.hints(for: "special.mkv") == expectedOther)
        }
    }

    @Test func unicodeTitlesAndPathsAreNotRestricted() throws {
        let title = "番組 À"
        let path = "季節０２/第０３話 – café 🎬: 前編.mkv"
        let plex = try #require(PlexMatchHints.parse("\u{feff}  TITLE : \(title)\r\n Episode: S02E03-E04: \(path)  \r\n"))
        let hints = plex.hints(for: path)
        #expect(hints.title == title)
        #expect(hints.season == 2)
        #expect(hints.episode == 3)
        #expect(hints.lastEpisode == 4)
    }

    @Test func descendantMappingRestrictionsAreUnchanged() throws {
        let plex = try #require(PlexMatchHints.parse("title: Show\nep: E02: Season 2/file.mkv\nep: E03: local.mkv"))
        #expect(plex.hints(for: "Season 2/file.mkv").episode == 2)
        #expect(plex.hints(for: "Season 2/file.mkv", inheritsDescendantMappings: false).episode == nil)
        #expect(plex.hints(for: "local.mkv", inheritsDescendantMappings: false).episode == 3)
    }

    @Test func fileAndDirectiveSizeLimitsAreUnchanged() throws {
        #expect(PlexMatchHints.parse(String(repeating: "#", count: 128 * 1024 + 1)) == nil)
        let text = "ep: E01: " + String(repeating: "a", count: 4096) + "\nep: E02: file.mkv"
        let plex = try #require(PlexMatchHints.parse(text))
        #expect(plex.hints(for: "file.mkv").episode == 2)
        #expect(plex.hints(for: String(repeating: "a", count: 4096)).episode == nil)
    }

    @Test func generatedNumericFieldMutationsAreRejectedAtomically() {
        let digitSets = ["０１２３４５６７８９", "٠١٢٣٤٥٦٧٨٩", "۰۱۲۳۴۵۶۷۸۹", "०१२३४५६७८९",
                         "০১২৩৪৫৬৭৮৯", "๐๑๒๓๔๕๖๗๘๙", "၀၁၂၃၄၅၆၇၈၉", "𝟎𝟏𝟐𝟑𝟒𝟓𝟔𝟕𝟖𝟗"]
        let original = Array("S02E03-S02E05")
        var checked = 0
        for digits in digitSets.map(Array.init) {
            for index in original.indices {
                guard let value = original[index].asciiValue, (48...57).contains(value) else { continue }
                var characters = original
                characters[index] = digits[Int(value - 48)]
                let token = String(characters)
                #expect(PlexMatchHints.parse("ep: \(token): file.mkv") == nil, "\(token)")
                checked += 1
            }
        }
        #expect(checked == 64)
    }
}
