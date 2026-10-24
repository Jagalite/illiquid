import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Planar ownership identity history")
struct PlanarOwnershipHistoryTests {
    @Test func releasedIdentitiesRemainHistoricalAcrossReuseCycles() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffers = try (0..<4).map { _ in try makeBuffer() }
        // Keep every native buffer alive throughout the test so allocator
        // address recycling cannot masquerade as reuse of the same buffer.
        withExtendedLifetime(buffers) {
            for generation in 1...3 {
                var tokens = buffers.map {
                    ledger.checkout(generation: generation, pixelBuffer: $0)
                }
                let active = ledger.snapshot(activeGeneration: generation)
                expectHistory(active, total: generation * 4, distinct: 4, reuse: (generation - 1) * 4)
                #expect(active.applicationFrames == 4)
                #expect(active.knownOutstandingBuffers == 4)

                withExtendedLifetime(tokens) {}
                tokens.removeAll()
                let released = ledger.snapshot(activeGeneration: generation)
                expectHistory(released, total: generation * 4, distinct: 4, reuse: (generation - 1) * 4)
                #expect(released.applicationFrames == 0)
                #expect(released.rendererSampleAttachments == 0)
                #expect(released.knownOutstandingBuffers == 0)
                #expect(released.peakKnownOutstandingBuffers == 4)
            }
        }
    }

    @Test func flushPreservesHistoryWhenNewAndReusedIdentitiesArrive() throws {
        let ledger = PlanarBufferOwnershipLedger()
        let buffers = try (0..<3).map { _ in try makeBuffer() }
        withExtendedLifetime(buffers) {
            var tokens = buffers.prefix(2).map {
                ledger.checkout(generation: 1, pixelBuffer: $0)
            }
            withExtendedLifetime(tokens) {}
            tokens.removeAll()
            ledger.recordFlushRequested(activeGeneration: 2)
            ledger.recordVideoFlushCompleted(activeGeneration: 2)
            let emptyFlush = ledger.snapshot(activeGeneration: 2)
            expectHistory(emptyFlush, total: 2, distinct: 2, reuse: 0)
            #expect(emptyFlush.knownOutstandingBuffers == 0)
            #expect(emptyFlush.lastFlush?.oldGenerationKnownBuffersAtRequest == 0)
            #expect(emptyFlush.lastFlush?.oldGenerationKnownBuffersAtVideoCompletion == 0)
            #expect(emptyFlush.lastFlush?.oldGenerationKnownBuffersReachedZeroMilliseconds != nil)

            tokens = [buffers[0], buffers[2]].map {
                ledger.checkout(generation: 2, pixelBuffer: $0)
            }
            let next = ledger.snapshot(activeGeneration: 2)
            expectHistory(next, total: 4, distinct: 3, reuse: 1)
            #expect(next.applicationFrames == 2)
            #expect(next.knownOutstandingBuffers == 2)
            #expect(next.oldGenerationKnownOutstandingBuffers == 0)

            ledger.recordFlushRequested(activeGeneration: 3)
            ledger.recordVideoFlushCompleted(activeGeneration: 3)
            withExtendedLifetime(tokens) {}
            tokens.removeAll()
            let drained = ledger.snapshot(activeGeneration: 3)
            expectHistory(drained, total: 4, distinct: 3, reuse: 1)
            #expect(drained.knownOutstandingBuffers == 0)
            #expect(drained.lastFlush?.oldGenerationKnownBuffersAtRequest == 2)
            #expect(drained.lastFlush?.oldGenerationKnownBuffersAtVideoCompletion == 2)
            #expect(drained.lastFlush?.oldGenerationKnownBuffersReachedZeroMilliseconds != nil)

            tokens = buffers.map { ledger.checkout(generation: 3, pixelBuffer: $0) }
            expectHistory(ledger.snapshot(activeGeneration: 3), total: 7, distinct: 3, reuse: 4)
            withExtendedLifetime(tokens) {}
            tokens.removeAll()
            let finished = ledger.snapshot(activeGeneration: 3)
            expectHistory(finished, total: 7, distinct: 3, reuse: 4)
            #expect(finished.knownOutstandingBuffers == 0)
        }
    }

    private func expectHistory(_ snapshot: PlanarBufferOwnershipSnapshot,
                               total: Int, distinct: Int, reuse: Int) {
        #expect(snapshot.totalCheckouts == total)
        #expect(snapshot.distinctBufferIdentitiesSeen == distinct)
        #expect(snapshot.reuseCheckouts == reuse)
        #expect(snapshot.reuseWhileKnownOwned == 0)
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer
        ) == kCVReturnSuccess)
        return try #require(buffer)
    }
}
