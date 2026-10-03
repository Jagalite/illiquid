import CFFmpeg
import Foundation
import SuperplayrCore
import Testing
@testable import SuperplayrNativePlayback

@Suite("Native track selection metadata")
struct NativeTrackSelectionTests {
    @Test func flagsAreMappedAndUnsupportedSubtitlesNeverParticipate() throws {
        func stream(_ index: Int32, codec: String, flags: Int32) -> FFmpegStreamInfo {
            FFmpegStreamInfo(index: index, kind: .subtitle, codecID: 0, codecName: codec,
                             title: nil, language: "eng", timeBase: .init(numerator: 1, denominator: 1_000),
                             duration: nil, disposition: flags, codedSize: nil, pixelAspectRatio: nil,
                             averageFrameRate: nil, sampleRate: nil, channelCount: nil, channelLayout: nil,
                             rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive)
        }
        let bitmap = stream(1, codec: "xsub", flags: AV_DISPOSITION_DEFAULT)
        let accessible = stream(2, codec: "ass", flags: AV_DISPOSITION_HEARING_IMPAIRED | AV_DISPOSITION_FORCED)
        let commentary = stream(3, codec: "subrip", flags: AV_DISPOSITION_COMMENT)
        #expect(bitmap.selectionCandidate == nil)
        let candidate = try #require(accessible.selectionCandidate)
        #expect(candidate.isAccessible)
        #expect(candidate.track.isForced)
        #expect(candidate.track.id == 3)
        #expect(commentary.selectionCandidate?.isCommentary == true)
        let info = FFmpegMediaInfo(url: URL(fileURLWithPath: "/fixture.mkv"), containerName: "matroska",
                                   duration: 1, startTime: 0, durationStatus: .valid(1), startTimeStatus: .valid(0),
                                   streams: [bitmap, accessible, commentary], chapters: [], attachments: [],
                                   selectedVideoIndex: nil, selectedAudioIndex: nil, selectedSubtitleIndex: 1)
        #expect(info.preferredTrackIndex(.subtitle,
                                        preferences: .init(subtitleLanguages: ["en"], subtitles: .forcedOnly)) == 2)
        #expect(info.preferredTrackIndex(.subtitle, preferences: .init(subtitles: .off)) == nil)
    }
}
