import AppKit
import Foundation
import SuperplayrCore
import Testing
@testable import SuperplayrPlayback

@Suite("Playback runtime contract")
struct BackendContractTests {
    @Test("Source and generation reject stale events")
    func staleEventRejection() throws {
        let firstSource = try #require(MediaSource(url: URL(fileURLWithPath: "/tmp/one.mkv")))
        let secondSource = try #require(MediaSource(url: URL(fileURLWithPath: "/tmp/two.mkv")))
        let first = PlayerSessionIdentity(source: firstSource, generation: 1)
        let second = PlayerSessionIdentity(source: secondSource, generation: 2)
        var gate = PlaybackRuntimeEventGate(activeIdentity: first)

        #expect(gate.accepts(PlaybackRuntimeEvent(identity: first, payload: .positionChanged(4))))
        gate.activate(second)
        #expect(!gate.accepts(PlaybackRuntimeEvent(identity: first, payload: .positionChanged(5))))
        #expect(gate.accepts(PlaybackRuntimeEvent(identity: second, payload: .loaded)))
        #expect(gate.accepts(PlaybackRuntimeEvent(identity: nil, payload: .diagnostic("global"))))
        #expect(gate.accepts(PlaybackRuntimeEvent(
            identity: nil,
            payload: .pictureInPictureChanged(
                PictureInPictureState(isPossible: true, isActive: false)
            )
        )))
    }

    @Test("Capabilities explicitly gate optional controls")
    func capabilities() {
        let native: PlaybackCapabilities = [
            .localFiles, .exactSeeking, .previewSeeking, .nativeSampleBufferSurface,
            .pictureInPicture,
        ]
        #expect(native.contains(.exactSeeking))
        #expect(native.contains(.pictureInPicture))
        #expect(!native.contains(.screenshots))
    }
}
