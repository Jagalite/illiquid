import Foundation
import Testing
@testable import SuperplayrNativePlayback

struct SubtitleSeekRegressionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERPLAYR_SUBTITLE_REGRESSION_MEDIA"] != nil))
    func realMediaTextSubtitleSeeksRemainUsable() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SUPERPLAYR_SUBTITLE_REGRESSION_MEDIA"])
        let input = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        for target in [41.815176, 172.469333, 0, 300, 600, 1200, 41.815176] {
            _ = try input.activeSubtitlePackets(streamIndex: stream.index, at: target, generation: 0)
        }
    }
}
