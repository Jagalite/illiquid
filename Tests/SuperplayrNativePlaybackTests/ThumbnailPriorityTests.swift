import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Thumbnail request priority", .serialized)
struct ThumbnailPriorityTests {
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.withLock { values.append(value) } }
        func snapshot() -> [Bool] { lock.withLock { values } }
    }
    private static func wait(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 5) == .success
    }

    @Test func pendingHoverGetsForegroundPriorityAfterBackgroundNativeOwnershipEnds() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let observations = Observations()
        let expected = try #require(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let worker = TimelineThumbnailWorker(requestTimeout: 10, prioritizesForeground: true) { input, _ in
            observations.append(qos_class_self() == (input.background ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED))
            if input.background {
                entered.signal()
                _ = Self.wait(release)
            }
            return expected
        }
        let url = URL(fileURLWithPath: "/unused-thumbnail.mkv"), size = CGSize(width: 2, height: 2)
        let background = Task { await worker.image(for: .init(url: url, seconds: 0, size: size, background: true)) }
        #expect(await Task.detached { Self.wait(entered) }.value)
        let foreground = Task { await worker.image(for: .init(url: url, seconds: 1, size: size)) }
        for _ in 0..<500 where worker.pendingPosition != 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(worker.pendingPosition == 1)
        #expect(observations.snapshot().count == 1)
        release.signal()
        #expect(await background.value == nil)
        #expect(await foreground.value === expected)
        #expect(observations.snapshot() == [true, true])
    }
}
