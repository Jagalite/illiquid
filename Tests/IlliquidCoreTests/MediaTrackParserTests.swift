import Testing
@testable import IlliquidCore

@Suite("Media track parsing")
struct MediaTrackParserTests {
    @Test("Parses audio and subtitle tracks while dropping malformed entries")
    func parsesSupportedTracks() {
        let tracks = MediaTrackParser.parse([
            MediaTrackDescriptor(
                id: 1,
                type: "audio",
                title: " Director Commentary ",
                language: "eng",
                codec: "aac",
                isDefault: true
            ),
            MediaTrackDescriptor(
                id: 2,
                type: "sub",
                title: "English Signs"
            ),
            MediaTrackDescriptor(
                id: 3,
                type: "subtitle",
                language: "jpn",
                codec: "ass",
                isExternal: true,
                externalFilename: "/tmp/Episode 1.ass"
            ),
            MediaTrackDescriptor(id: nil, type: "audio"),
        ])

        #expect(tracks.count == 3)
        #expect(tracks[0].kind == .audio)
        #expect(tracks[0].title == "Director Commentary")
        #expect(tracks[0].isDefault)
        #expect(tracks[1].kind == .subtitle)
        #expect(tracks[1].title == "English Signs")
        #expect(tracks[2].kind == .subtitle)
        #expect(tracks[2].isExternal)
    }
}
