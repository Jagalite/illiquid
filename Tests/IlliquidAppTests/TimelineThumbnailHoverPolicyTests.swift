import CoreGraphics
import Testing
@testable import IlliquidApp

@Suite("Timeline hover recovery")
@MainActor
struct TimelineThumbnailHoverRecoveryTests {
    @Test func playbackRecoveryRestartsOnlyIncompletePreviewsForTheCurrentSource() {
        #expect(TimelineThumbnailHoverPolicy.shouldResumePreview(
            sourceRevision: 2, currentRevision: 2, representedPosition: nil, bucket: 10))
        #expect(TimelineThumbnailHoverPolicy.shouldResumePreview(
            sourceRevision: 2, currentRevision: 2, representedPosition: 4.5, bucket: 10))
        #expect(!TimelineThumbnailHoverPolicy.shouldResumePreview(
            sourceRevision: 2, currentRevision: 2, representedPosition: 5, bucket: 10))
        #expect(!TimelineThumbnailHoverPolicy.shouldResumePreview(
            sourceRevision: 1, currentRevision: 2, representedPosition: nil, bucket: 10))
    }

    @Test func delayedRevisionObservationKeepsANewHoverButRetiresTheOldSource() {
        #expect(TimelineThumbnailHoverPolicy.shouldRetirePreview(sourceRevision: 1, currentRevision: 2))
        #expect(!TimelineThumbnailHoverPolicy.shouldRetirePreview(sourceRevision: 2, currentRevision: 2))
        #expect(!TimelineThumbnailHoverPolicy.shouldRetirePreview(sourceRevision: nil, currentRevision: 2))
    }
    @Test func fallbackCannotFollowThePointerBeyondTheNearbyWindow() {
        #expect(TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 20, maximumDistance: 30))
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 120, maximumDistance: 30))
        // Short videos can have a smaller adaptive distance than the global cap.
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 20, maximumDistance: 5))
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: nil, for: 20, maximumDistance: 30))
    }

    @Test func movementWithinOneBucketPostponesDecodeUntilThePointerSettles() async {
        var now = ContinuousClock.now
        var movement = now
        var sleeps = 0
        let settled = await TimelineThumbnailHoverPolicy.waitUntilSettled(
            lastMovement: { movement }, now: { now }, sleep: { duration in
                sleeps += 1
                now = now.advanced(by: duration)
                // Motion can remain in one bucket; each update extends settling.
                if sleeps <= 10 { movement = now }
            })
        #expect(settled)
        #expect(sleeps == 11)
        #expect(movement.duration(to: now) == TimelineThumbnailHoverPolicy.cacheMissDelay)
    }

    @Test func cancelledMovementNeverReachesDecode() async {
        let task = Task { @MainActor in
            await TimelineThumbnailHoverPolicy.waitUntilSettled(
                lastMovement: { .now }, sleep: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        #expect(await task.value == false)
    }

    @Test func anAlreadySettledPointerDoesNotAddAnotherDecodeDelay() async {
        let now = ContinuousClock.now
        var sleeps = 0
        #expect(await TimelineThumbnailHoverPolicy.waitUntilSettled(
            lastMovement: { now.advanced(by: .seconds(-1)) }, now: { now },
            sleep: { _ in sleeps += 1 }))
        #expect(sleeps == 0)
    }

    @Test func nearbyReuseMatchesFiveSecondSamplingWithoutAcceptingDistantFrames() {
        #expect(TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 12.5,
            maximumDistance: TimelineThumbnailHoverPolicy.nearbyDistance))
        #expect(!TimelineThumbnailHoverPolicy.canRetainPreview(at: 10, for: 14,
            maximumDistance: TimelineThumbnailHoverPolicy.nearbyDistance))
    }

    @Test func ownershipLostWhileSettlingCannotStartADecode() async {
        var current = true
        var decodes = 0
        let result = await TimelineThumbnailHoverPolicy.image(
            isCurrent: { current }, prepare: { current = false; return true }
        ) { decodes += 1; return nil }
        #expect(result == nil)
        #expect(decodes == 0)
    }

    @Test func sourceChangeDuringDecodeCannotPublishOrRetry() async throws {
        let expected = try image()
        var current = true
        var decodes = 0
        let result = await TimelineThumbnailHoverPolicy.image(
            retryDelay: .zero, isCurrent: { current }
        ) { decodes += 1; current = false; return expected }
        #expect(result == nil)
        #expect(decodes == 1)
    }

    @Test func retryWaitsForMovementAfterTheFirstAttempt() async throws {
        let expected = try image()
        var now = ContinuousClock.now
        var movement = now.advanced(by: .seconds(-1))
        var decodes = 0
        var sleeps = 0
        let result = await TimelineThumbnailHoverPolicy.image(
            retryDelay: .zero,
            prepare: {
                await TimelineThumbnailHoverPolicy.waitUntilSettled(
                    lastMovement: { movement }, now: { now }, sleep: { duration in
                        sleeps += 1
                        now = now.advanced(by: duration)
                        if sleeps < 3 { movement = now }
                    })
            }
        ) {
            decodes += 1
            if decodes == 1 { movement = now; return nil }
            #expect(movement.duration(to: now) >= TimelineThumbnailHoverPolicy.cacheMissDelay)
            return expected
        }
        #expect(result === expected)
        #expect(decodes == 2)
        #expect(sleeps == 3)
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
