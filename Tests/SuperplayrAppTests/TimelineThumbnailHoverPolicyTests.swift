import CoreGraphics
import Testing
@testable import SuperplayrApp

@Suite("Timeline hover recovery")
@MainActor
struct TimelineThumbnailHoverRecoveryTests {
    @Test func fallbackCannotFollowThePointerBeyondTheNearbyWindow() {
        #expect(TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 20, maximumDistance: 30))
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 120, maximumDistance: 30))
        // Short videos can have a smaller adaptive distance than the global cap.
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 20, maximumDistance: 5))
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: nil, for: 20, maximumDistance: 30))
    }

    private func image() throws -> CGImage {
        try #require(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }

    @Test func stationaryHoverRecoversAfterExpiredRequest() async throws {
        let expected = try image()
        var attempts = 0
        let result = await TimelineThumbnailHoverPolicy.image(retryDelay: .zero) {
            attempts += 1
            return attempts == 1 ? nil : expected
        }
        #expect(result === expected)
        #expect(attempts == 2)
    }

    @Test func successfulPreviewDoesNotDecodeAgain() async throws {
        let expected = try image()
        var attempts = 0
        let result = await TimelineThumbnailHoverPolicy.image(retryDelay: .zero) {
            attempts += 1
            return expected
        }
        #expect(result === expected)
        #expect(attempts == 1)
    }

    @Test func unsupportedMediaHasBoundedAttempts() async {
        var attempts = 0
        let result = await TimelineThumbnailHoverPolicy.image(retryDelay: .zero) {
            attempts += 1
            return nil
        }
        #expect(result == nil)
        #expect(attempts == 2)
    }

    @Test func cancelledHoverCannotRetryOrPublishLateImage() async throws {
        let expected = try image()
        var attempts = 0
        let task = Task { @MainActor in
            await TimelineThumbnailHoverPolicy.image(retryDelay: .zero) {
                attempts += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return expected
            }
        }
        #expect(await task.value == nil)
        #expect(attempts == 1)
    }
}
