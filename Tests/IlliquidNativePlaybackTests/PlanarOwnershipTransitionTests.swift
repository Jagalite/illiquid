import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Planar ownership phase accounting")
struct PlanarOwnershipTransitionTests {
    @Test func phaseChangesPreserveOwnerCountsAndPeaks() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffer = try makeBuffer()
        let token = ledger.checkout(generation: 1, pixelBuffer: buffer)
        let checkedOut = ledger.snapshot(activeGeneration: 1)
        #expect(checkedOut.peakApplicationFrames == 1)
        #expect(checkedOut.peakKnownOutstandingBuffers == 1)
        #expect(checkedOut.peakRendererSampleAttachments == 0)
        let attachment = try #require(
            ledger.makeRendererSampleAttachment(checkoutID: token.checkoutID)
        )
        #expect(ledger.snapshot(activeGeneration: 1).peakRendererSampleAttachments == 1)
        #expect(ledger.makeRendererSampleAttachment(checkoutID: token.checkoutID) == nil)

        // The queue consumer can reach presenting before the producer records
        // queued. Equal phases are allowed; backward transitions are ignored.
        let attempts: [PlanarFrameOwnershipPhase] = [
            .decoded, .waitingForQueue, .waitingForQueue, .presenting,
            .queued, .submitted, .presenting, .submitted,
        ]
        var expectedPhase = PlanarFrameOwnershipPhase.decoded
        for phase in attempts {
            token.transition(to: phase)
            if phase.rawValue > expectedPhase.rawValue { expectedPhase = phase }
            let snapshot = ledger.snapshot(activeGeneration: 1)
            #expect(snapshot.totalCheckouts == 1)
            #expect(snapshot.applicationFrames == 1)
            #expect(snapshot.rendererSampleAttachments == 1)
            #expect(snapshot.knownOutstandingBuffers == 1)
            #expect(snapshot.peakApplicationFrames == 1)
            #expect(snapshot.peakRendererSampleAttachments == 1)
            #expect(snapshot.peakKnownOutstandingBuffers == 1)
            #expect(phaseCounts(snapshot) == (0..<5).map {
                $0 == expectedPhase.rawValue ? 1 : 0
            })
        }
        withExtendedLifetime((buffer, token, attachment)) {}
    }

    @Test func overlappingCheckoutsCountLifetimesAndDistinctBuffersSeparately() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let shared = try makeBuffer()
        let distinct = try makeBuffer()
        let first = ledger.checkout(generation: 1, pixelBuffer: shared)
        var second: PlanarFrameOwnershipToken? = ledger.checkout(
            generation: 2, pixelBuffer: shared
        )
        let third = ledger.checkout(generation: 2, pixelBuffer: distinct)
        let attachment = try #require(
            ledger.makeRendererSampleAttachment(checkoutID: first.checkoutID)
        )
        let secondID = try #require(second).checkoutID
        first.transition(to: .submitted)
        second?.transition(to: .queued)
        third.transition(to: .presenting)

        var snapshot = ledger.snapshot(activeGeneration: 2)
        #expect(snapshot.applicationFrames == 3)
        #expect(snapshot.knownOutstandingBuffers == 2)
        #expect(snapshot.oldGenerationKnownOutstandingBuffers == 1)
        #expect(snapshot.peakApplicationFrames == 3)
        #expect(snapshot.peakKnownOutstandingBuffers == 2)
        #expect(snapshot.peakRendererSampleAttachments == 1)
        #expect(snapshot.reuseWhileKnownOwned == 1)

        withExtendedLifetime(second) {}
        second = nil
        ledger.transition(secondID, to: .submitted)
        let fourth = ledger.checkout(generation: 2, pixelBuffer: shared)
        fourth.transition(to: .presenting)
        snapshot = ledger.snapshot(activeGeneration: 2)
        #expect(snapshot.applicationFrames == 3)
        #expect(snapshot.knownOutstandingBuffers == 2)
        #expect(snapshot.peakApplicationFrames == 3)
        #expect(snapshot.peakKnownOutstandingBuffers == 2)
        #expect(snapshot.reuseCheckouts == 2)
        // This diagnostic tracks the most recent checkout for each buffer.
        // The most recent shared checkout was released before the fourth.
        #expect(snapshot.reuseWhileKnownOwned == 1)
        withExtendedLifetime((shared, distinct, first, third, fourth, attachment)) {}
    }

    @Test func aReleasedApplicationFrameCannotChangePhaseOrRestoreOwnership() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffer = try makeBuffer()
        var token: PlanarFrameOwnershipToken? = ledger.checkout(
            generation: 3, pixelBuffer: buffer
        )
        let checkoutID = try #require(token).checkoutID
        var attachment: PlanarRendererSampleLifetimeAttachment? = try #require(
            ledger.makeRendererSampleAttachment(checkoutID: checkoutID)
        )
        token?.transition(to: .queued)
        token = nil
        let rendererOnly = ledger.snapshot(activeGeneration: 3)
        ledger.transition(checkoutID, to: .submitted)
        ledger.transition(UInt64.max, to: .submitted)
        #expect(ledger.snapshot(activeGeneration: 3) == rendererOnly)
        #expect(rendererOnly.applicationFrames == 0)
        #expect(rendererOnly.rendererSampleAttachments == 1)
        #expect(rendererOnly.knownOutstandingBuffers == 1)

        withExtendedLifetime(attachment) {}
        attachment = nil
        let released = ledger.snapshot(activeGeneration: 3)
        ledger.transition(checkoutID, to: .submitted)
        #expect(ledger.snapshot(activeGeneration: 3) == released)
        #expect(released.knownOutstandingBuffers == 0)
        #expect(released.peakApplicationFrames == 1)
        #expect(released.peakRendererSampleAttachments == 1)
        #expect(released.peakKnownOutstandingBuffers == 1)
        withExtendedLifetime(buffer) {}
    }

    @Test(arguments: [false, true])
    func rendererAndApplicationReleaseOrdersPreserveFlushEvidence(
        rendererReleasedFirst: Bool
    ) throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffer = try makeBuffer()
        var token: PlanarFrameOwnershipToken? = ledger.checkout(
            generation: 4, pixelBuffer: buffer
        )
        var sample: CMSampleBuffer? = try makeSample(buffer)
        token?.attachRendererSampleLifetime(to: try #require(sample))
        token?.transition(to: .submitted)
        ledger.recordFlushRequested(activeGeneration: 5)

        withExtendedLifetime((sample, token)) {}
        if rendererReleasedFirst { sample = nil } else { token = nil }
        ledger.recordVideoFlushCompleted(activeGeneration: 5)
        var snapshot = ledger.snapshot(activeGeneration: 5)
        #expect(snapshot.knownOutstandingBuffers == 1)
        #expect(snapshot.applicationFrames == (rendererReleasedFirst ? 1 : 0))
        #expect(snapshot.rendererSampleAttachments == (rendererReleasedFirst ? 0 : 1))
        #expect(snapshot.lastFlush?.oldGenerationKnownBuffersAtRequest == 1)
        #expect(snapshot.lastFlush?.oldGenerationRendererSamplesAtRequest == 1)
        #expect(snapshot.lastFlush?.oldGenerationKnownBuffersAtVideoCompletion == 1)
        #expect(snapshot.lastFlush?.oldGenerationKnownBuffersReachedZeroMilliseconds == nil)

        token?.transition(to: .submitted)
        withExtendedLifetime((sample, token)) {}
        sample = nil
        token = nil
        snapshot = ledger.snapshot(activeGeneration: 5)
        #expect(snapshot.knownOutstandingBuffers == 0)
        #expect(snapshot.peakApplicationFrames == 1)
        #expect(snapshot.peakRendererSampleAttachments == 1)
        #expect(snapshot.peakKnownOutstandingBuffers == 1)
        #expect(snapshot.lastFlush?.oldGenerationKnownBuffersReachedZeroMilliseconds != nil)
        withExtendedLifetime((buffer, sample, token)) {}
    }

    @Test func concurrentPhaseAttemptsPreservePeaksAndMonotonicPhases() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffers = try (0..<16).map { _ in try makeBuffer() }
        let tokens = buffers.map { ledger.checkout(generation: 6, pixelBuffer: $0) }
        let attachments = tokens.prefix(4).compactMap {
            ledger.makeRendererSampleAttachment(checkoutID: $0.checkoutID)
        }
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            let token = tokens[index % tokens.count]
            token.transition(to: .waitingForQueue)
            token.transition(to: .presenting)
            token.transition(to: .queued)
            token.transition(to: .submitted)
        }
        let snapshot = ledger.snapshot(activeGeneration: 6)
        #expect(snapshot.applicationFrames == 16)
        #expect(snapshot.submittedApplicationFrames == 16)
        #expect(snapshot.rendererSampleAttachments == 4)
        #expect(snapshot.peakApplicationFrames == 16)
        #expect(snapshot.peakRendererSampleAttachments == 4)
        #expect(snapshot.knownOutstandingBuffers == 16)
        #expect(snapshot.peakKnownOutstandingBuffers == 16)
        withExtendedLifetime((buffers, tokens, attachments)) {}
    }

    @Test func peakCountsIncludeMixedOwnersAndOverlappingIdentities() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffers = try (0..<4).map { _ in try makeBuffer() }
        var tokens: [PlanarFrameOwnershipToken?] = [
            ledger.checkout(generation: 1, pixelBuffer: buffers[0]),
        ]
        var attachments: [PlanarRendererSampleLifetimeAttachment?] = [
            try #require(ledger.makeRendererSampleAttachment(
                checkoutID: try #require(tokens[0]).checkoutID
            )),
        ]
        withExtendedLifetime(tokens[0]) {}
        tokens[0] = nil

        // An older renderer-only owner shares its buffer with a new checkout.
        // The other checkouts have application-only and double ownership.
        tokens.append(ledger.checkout(generation: 2, pixelBuffer: buffers[0]))
        tokens.append(ledger.checkout(generation: 2, pixelBuffer: buffers[1]))
        tokens.append(ledger.checkout(generation: 2, pixelBuffer: buffers[2]))
        for index in [1, 3] {
            attachments.append(try #require(ledger.makeRendererSampleAttachment(
                checkoutID: try #require(tokens[index]).checkoutID
            )))
        }

        var snapshot = ledger.snapshot(activeGeneration: 2)
        #expect(snapshot.applicationFrames == 3)
        #expect(snapshot.rendererSampleAttachments == 3)
        #expect(snapshot.knownOutstandingBuffers == 3)
        #expect(snapshot.peakApplicationFrames == 3)
        #expect(snapshot.peakRendererSampleAttachments == 3)
        #expect(snapshot.peakKnownOutstandingBuffers == 3)

        // Release an application owner, then trigger peak accounting with a
        // fresh identity. The renderer-only third buffer must still count.
        withExtendedLifetime(tokens[3]) {}
        tokens[3] = nil
        tokens.append(ledger.checkout(generation: 2, pixelBuffer: buffers[3]))
        attachments.append(try #require(ledger.makeRendererSampleAttachment(
            checkoutID: try #require(tokens[4]).checkoutID
        )))
        snapshot = ledger.snapshot(activeGeneration: 2)
        #expect(snapshot.applicationFrames == 3)
        #expect(snapshot.rendererSampleAttachments == 4)
        #expect(snapshot.knownOutstandingBuffers == 4)
        #expect(snapshot.peakApplicationFrames == 3)
        #expect(snapshot.peakRendererSampleAttachments == 4)
        #expect(snapshot.peakKnownOutstandingBuffers == 4)

        withExtendedLifetime((buffers, tokens, attachments)) {}
        tokens.removeAll()
        attachments.removeAll()
        snapshot = ledger.snapshot(activeGeneration: 2)
        #expect(snapshot.applicationFrames == 0)
        #expect(snapshot.rendererSampleAttachments == 0)
        #expect(snapshot.knownOutstandingBuffers == 0)

        // A lower-occupancy growth event must not reset historical peaks.
        let next = ledger.checkout(generation: 3, pixelBuffer: buffers[0])
        let nextAttachment = try #require(
            ledger.makeRendererSampleAttachment(checkoutID: next.checkoutID)
        )
        snapshot = ledger.snapshot(activeGeneration: 3)
        #expect(snapshot.applicationFrames == 1)
        #expect(snapshot.rendererSampleAttachments == 1)
        #expect(snapshot.knownOutstandingBuffers == 1)
        #expect(snapshot.peakApplicationFrames == 3)
        #expect(snapshot.peakRendererSampleAttachments == 4)
        #expect(snapshot.peakKnownOutstandingBuffers == 4)
        withExtendedLifetime((buffers, next, nextAttachment)) {}
    }

    private func phaseCounts(_ snapshot: PlanarBufferOwnershipSnapshot) -> [Int] {
        [snapshot.decodedFrames, snapshot.framesWaitingForQueue, snapshot.queuedFrames,
         snapshot.presentingFrames, snapshot.submittedApplicationFrames]
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer
        ) == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func makeSample(_ buffer: CVPixelBuffer) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &format
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr)
        return try #require(sample)
    }
}
