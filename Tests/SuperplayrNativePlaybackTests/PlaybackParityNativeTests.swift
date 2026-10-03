import AppKit
import CoreMedia
import SuperplayrPlayback
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import SuperplayrCore
@testable import SuperplayrNativePlayback

@Suite("Native playback parity tools", .serialized)
struct PlaybackParityNativeTests {
    @Test func frameStepsFollowIrregularPresentationTimes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("variable-frame-rate.mkv")
        let reader = NativeFrameStepReader()
        // Independently recorded ffprobe presentation timestamps for this fixture:
        // 0, .233, .367, .467, .700, .733, .933, 1.100 ...
        let forward = try await reader.target(url: url, position: 0.467, direction: 1)
        let back = try await reader.target(url: url, position: 0.700, direction: -1)
        #expect(abs(try #require(forward) - 0.700) < 0.0001)
        #expect(abs(try #require(back) - 0.467) < 0.0001)
        #expect(try await reader.target(url: url, position: 0, direction: -1) == nil)
    }

    @Test func screenshotIncludesSubtitleMaskAtTheExpectedPixels() throws {
        var optional: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &optional) == kCVReturnSuccess)
        let buffer = try #require(optional)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let region = ASSRenderedRegion(bitmap: Data(repeating: 255, count: 4), color: 0xff000000,
            frame: CGRect(x: 2, y: 1, width: 2, height: 2), stride: 2)
        let capture = NativeScreenshot(buffer: buffer, displaySize: CGSize(width: 8, height: 8),
            rotation: 0, mirrored: false, size: CGSize(width: 8, height: 8),
            adjustments: .standard, regions: [region])
        let data = try capture.png()
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 8 && image.height == 8)
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect((0..<64).filter { pixels[$0 * 4] > 240 && pixels[$0 * 4 + 1] < 10 }.count == 4)
    }
    @Test @MainActor func pausedRendererProvidesCaptureAndFrameStepIdentity() async throws {
        guard ProcessInfo.processInfo.environment["SUPERPLAYR_PARITY_SHOW_WINDOW"] == "1",
              let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let runtime = try NativePlaybackRuntime()
        runtime.setMuted(true)
        let surface = try runtime.makeSurfaceHost()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface.view
        surface.view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        surface.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("h264-aac.mp4")
        let source = MediaSource.localFile(url)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        do {
            try runtime.load(PlaybackRuntimeLoadRequest(media: request,
                identity: PlayerSessionIdentity(source: source, generation: 1)))
            for _ in 0..<300 {
                if runtime.sessionSnapshotForDiagnostics?.isPrerolled == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            surface.view.layoutSubtreeIfNeeded()
            runtime.play()
            try await Task.sleep(for: .milliseconds(250))
            runtime.pause()
            try await Task.sleep(for: .milliseconds(100))
            let target = try await runtime.frameStepTarget(direction: 1)
            #expect(target != nil)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("parity-capture-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: destination) }
            try await runtime.execute(.screenshot(destination, includeSubtitles: true))
            let data = try Data(contentsOf: destination)
            #expect(data.count > 100)
            await runtime.shutdown()
            window.close()
        } catch {
            await runtime.shutdown()
            window.close()
            throw error
        }
    }

    @Test @MainActor func repeatedVFRStepsReachTheExpectedDisplayedFrames() async throws {
        guard ProcessInfo.processInfo.environment["SUPERPLAYR_PARITY_SHOW_WINDOW"] == "1",
              let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let runtime = try NativePlaybackRuntime()
        runtime.setMuted(true)
        let surface = try runtime.makeSurfaceHost()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface.view
        surface.view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        surface.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        let source = MediaSource.localFile(URL(fileURLWithPath: directory).appendingPathComponent("variable-frame-rate.mkv"))
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        do {
            try runtime.load(.init(media: request, identity: .init(source: source, generation: 1)))
            try #require(try await waitFor { runtime.sessionSnapshotForDiagnostics?.isPrerolled == true })
            runtime.pause()
            runtime.seek(to: 0, mode: .absoluteExact)
            try #require(try await waitFor { displayedTime(runtime).map { abs($0) < 0.0001 } == true })
            // Independent ffprobe PTS, including unequal adjacent durations.
            let sequence: [(Int, Double)] = [(1, 0.233), (1, 0.367), (1, 0.467), (1, 0.700),
                (-1, 0.467), (-1, 0.367), (-1, 0.233), (-1, 0)]
            for cycle in 0..<2 {
                for (direction, expected) in sequence {
                    let start = ContinuousClock.now
                    let target = try #require(try await runtime.frameStepTarget(direction: direction))
                    #expect(abs(target - expected) < 0.0001)
                    runtime.seek(to: target, mode: .absoluteExact)
                    try #require(try await waitFor {
                        displayedTime(runtime).map { abs($0 - expected) < 0.0001 } == true
                    })
                    #expect(runtime.presentation.rate == 0)
                    let duration = start.duration(to: .now).components
                    let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                    print("[parity-visible-step] cycle=\(cycle) direction=\(direction) pts=\(expected) milliseconds=\(milliseconds)")
                }
            }
            await runtime.shutdown()
            window.close()
        } catch {
            await runtime.shutdown()
            window.close()
            throw error
        }
    }

    @MainActor private func displayedTime(_ runtime: NativePlaybackRuntime) -> Double? {
        guard let session = runtime.sessionSnapshotForDiagnostics,
              session.seekTimings?.milliseconds[.prerollCompleted] != nil,
              let buffer = runtime.presentation.video.renderer.displayedPixelBuffer(),
              let identity = runtime.presentation.video.identity(for: buffer),
              identity.generation == session.generation else { return nil }
        return identity.time
    }

    @MainActor private func waitFor(_ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

}
