import AVFoundation
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Audio output lifecycle notifications")
struct AudioOutputNotificationTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UInt64] = []
        func append(_ fence: PresentationFence) { lock.withLock { recorded.append(fence.rawValue) } }
        var values: [UInt64] { lock.withLock { recorded } }
    }

    @Test func observesBothEventsAndRejectsRetiredRenderers() throws {
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let recorder = Recorder()
        presentation.setAudioOutputChangeHandler { fence, _ in recorder.append(fence) }
        let original = presentation.audio.renderer
        let names: [Notification.Name] = [
            .AVSampleBufferAudioRendererWasFlushedAutomatically,
            .AVSampleBufferAudioRendererOutputConfigurationDidChange,
        ]
        for name in names { NotificationCenter.default.post(name: name, object: original) }
        _ = presentation.currentFence // Barrier after queued notification handling.
        #expect(recorder.values == [0, 0])

        let fence = try presentation.recoverAudioPresentation(rebuildGraph: true)
        NotificationCenter.default.post(name: names[0], object: original)
        NotificationCenter.default.post(name: names[1], object: presentation.audio.renderer)
        _ = presentation.currentFence
        #expect(recorder.values == [0, 0, fence.rawValue])

        presentation.terminate()
        NotificationCenter.default.post(name: names[0], object: presentation.audio.renderer)
        _ = presentation.currentFence
        #expect(recorder.values.count == 3)
    }
}
