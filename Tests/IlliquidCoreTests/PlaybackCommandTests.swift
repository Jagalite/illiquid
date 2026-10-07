import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playback commands")
struct PlaybackCommandTests {
    @Test func modelsLoadAndSubtitleIntentsWithoutBackendEncoding() {
        let video = URL(fileURLWithPath: "/Media/Episode 01.mkv")
        let subtitle = URL(fileURLWithPath: "/Media/Episode 01.eng.ass")

        #expect(PlaybackCommand.load(.localFile(video)) == .load(.localFile(video)))
        #expect(PlaybackCommand.addSubtitle(subtitle, select: true) == .addSubtitle(subtitle, select: true))
    }

    @Test func acceptsLocalAndHTTPSMediaSources() {
        let local = URL(fileURLWithPath: "/Media/movie.mkv")
        let remote = URL(string: "https://media.example/movie.m3u8")!

        #expect(MediaSource(url: local) == .localFile(local))
        #expect(MediaSource(url: remote) == .remoteStream(remote))
        #expect(MediaSource(url: URL(string: "ftp://example.invalid/movie")!) == nil)
    }

    @Test func transportCommandsRemainBackendIndependent() {
        #expect(PlaybackCommand.stop == .stop)
        #expect(PlaybackCommand.frameStepForward == .frameStepForward)
        #expect(PlaybackCommand.frameStepBackward == .frameStepBackward)
    }
}
