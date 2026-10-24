import Foundation
import Dispatch
#if os(macOS)
import CoreMedia
import CoreVideo
#endif

// Identity objects stay alive throughout the experiment. Their allocation and
// pixel storage precede the heap checkpoint; no pixel data is measured as ledger
// storage. Native buffers are real but deliberately tiny, not playback surfaces.
private func makeBuffer() -> CVPixelBuffer {
    #if os(macOS)
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer) == kCVReturnSuccess)
    return buffer!
    #else
    return CVPixelBuffer()
    #endif
}

private func scopedPool<T>(_ operation: () -> T) -> T {
    #if os(macOS)
    return autoreleasepool(invoking: operation)
    #else
    return operation()
    #endif
}

// Returning from this separate producer scope releases the real ARC token.
// Each subsequent checkout begins with no application or renderer owner alive.
@inline(never)
private func checkoutAndRelease(_ buffer: CVPixelBuffer, ledger: PlanarBufferOwnershipLedger) {
    let token = ledger.checkout(generation: 1, pixelBuffer: buffer)
    withExtendedLifetime(token) {}
}

private func validate(_ snapshot: PlanarBufferOwnershipSnapshot, count: Int, passes: Int) {
    precondition(snapshot.totalCheckouts == count * passes)
    precondition(snapshot.distinctBufferIdentitiesSeen == count)
    precondition(snapshot.reuseCheckouts == count * (passes - 1))
    precondition(snapshot.reuseWhileKnownOwned == 0)
    precondition(snapshot.applicationFrames == 0 && snapshot.rendererSampleAttachments == 0)
    precondition(snapshot.knownOutstandingBuffers == 0 && snapshot.oldGenerationKnownOutstandingBuffers == 0)
    precondition(snapshot.peakApplicationFrames == 1 && snapshot.peakKnownOutstandingBuffers == 1)
    precondition(snapshot.peakRendererSampleAttachments == 0)
}

private struct LiveResult {
    let afterPopulate: PlanarBufferOwnershipSnapshot
    let afterReuse: PlanarBufferOwnershipSnapshot
    let heapAfterPopulateBytes: UInt64
    let heapAfterReuseBytes: UInt64
    let populateNanoseconds: UInt64
    let populateCPUNanoseconds: UInt64
    let reuseNanoseconds: UInt64
    let reuseCPUNanoseconds: UInt64
}

@inline(never)
private func measureLedger(_ buffers: [CVPixelBuffer]) -> LiveResult {
    let ledger = PlanarBufferOwnershipLedger()
    let populateCPUStart = planar_history_cpu_nanoseconds()
    let populateStart = DispatchTime.now().uptimeNanoseconds
    scopedPool {
        for buffer in buffers { checkoutAndRelease(buffer, ledger: ledger) }
    }
    let populateElapsed = DispatchTime.now().uptimeNanoseconds - populateStart
    let populateCPU = planar_history_cpu_nanoseconds() - populateCPUStart
    let populatedHeap = withExtendedLifetime(ledger) { planar_history_heap_bytes() }
    let populated = ledger.snapshot(activeGeneration: 1)
    validate(populated, count: buffers.count, passes: 1)

    let reuseCPUStart = planar_history_cpu_nanoseconds()
    let reuseStart = DispatchTime.now().uptimeNanoseconds
    scopedPool {
        for buffer in buffers { checkoutAndRelease(buffer, ledger: ledger) }
    }
    let reuseElapsed = DispatchTime.now().uptimeNanoseconds - reuseStart
    let reuseCPU = planar_history_cpu_nanoseconds() - reuseCPUStart
    let reusedHeap = withExtendedLifetime(ledger) { planar_history_heap_bytes() }
    let reused = ledger.snapshot(activeGeneration: 1)
    validate(reused, count: buffers.count, passes: 2)
    // Both returned snapshots contain scalar counters and absent optional clock
    // records. They retain no token, ledger, buffer, or historical collection.
    return LiveResult(afterPopulate: populated, afterReuse: reused,
        heapAfterPopulateBytes: populatedHeap, heapAfterReuseBytes: reusedHeap,
        populateNanoseconds: populateElapsed, populateCPUNanoseconds: populateCPU,
        reuseNanoseconds: reuseElapsed, reuseCPUNanoseconds: reuseCPU)
}

private struct Snapshot: Encodable {
    let totalCheckouts, distinctBufferIdentitiesSeen, reuseCheckouts, reuseWhileKnownOwned: Int
    let applicationFrames, peakApplicationFrames, decodedFrames, framesWaitingForQueue: Int
    let queuedFrames, presentingFrames, submittedApplicationFrames: Int
    let rendererSampleAttachments, peakRendererSampleAttachments: Int
    let knownOutstandingBuffers, peakKnownOutstandingBuffers, oldGenerationKnownOutstandingBuffers: Int
    let poolThresholdWaits, poolTimeouts: Int

    init(_ value: PlanarBufferOwnershipSnapshot) {
        totalCheckouts = value.totalCheckouts; distinctBufferIdentitiesSeen = value.distinctBufferIdentitiesSeen
        reuseCheckouts = value.reuseCheckouts; reuseWhileKnownOwned = value.reuseWhileKnownOwned
        applicationFrames = value.applicationFrames; peakApplicationFrames = value.peakApplicationFrames
        decodedFrames = value.decodedFrames; framesWaitingForQueue = value.framesWaitingForQueue
        queuedFrames = value.queuedFrames; presentingFrames = value.presentingFrames
        submittedApplicationFrames = value.submittedApplicationFrames
        rendererSampleAttachments = value.rendererSampleAttachments
        peakRendererSampleAttachments = value.peakRendererSampleAttachments
        knownOutstandingBuffers = value.knownOutstandingBuffers
        peakKnownOutstandingBuffers = value.peakKnownOutstandingBuffers
        oldGenerationKnownOutstandingBuffers = value.oldGenerationKnownOutstandingBuffers
        poolThresholdWaits = value.poolThresholdWaits; poolTimeouts = value.poolTimeouts
    }
}

private struct Measurement: Encodable {
    let count: Int
    let heapMetric: String
    let heapBeforeBytes, heapAfterPopulateBytes, heapAfterReuseBytes, heapAfterDestroyBytes: UInt64
    let populateNanoseconds, populateCPUNanoseconds, reuseNanoseconds, reuseCPUNanoseconds: UInt64
    let peakRSSBytes: UInt64
    let afterPopulate, afterReuse: Snapshot
}

@main
private struct Harness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(arguments.count == 2 && arguments[0] == "bench", "Use bench COUNT")
        let count = Int(arguments[1])!
        precondition((1...65_536).contains(count))
        let buffers = scopedPool { (0..<count).map { _ in makeBuffer() } }
        scopedPool {
            let warm = PlanarBufferOwnershipLedger()
            for _ in 0..<2 {
                for buffer in buffers.prefix(16) { checkoutAndRelease(buffer, ledger: warm) }
            }
            _ = warm.snapshot(activeGeneration: 1)
            _ = planar_history_cpu_nanoseconds()
            _ = DispatchTime.now().uptimeNanoseconds
        }
        let metric = String(cString: planar_history_heap_metric())
        precondition(metric != "unsupported")
        let measurement = withExtendedLifetime(buffers) {
            let before = planar_history_heap_bytes()
            let live = scopedPool { measureLedger(buffers) }
            // The only owner of the measured ledger was inside measureLedger.
            let destroyed = planar_history_heap_bytes()
            let peak = planar_history_peak_rss_bytes()
            return Measurement(count: count, heapMetric: metric, heapBeforeBytes: before,
                heapAfterPopulateBytes: live.heapAfterPopulateBytes,
                heapAfterReuseBytes: live.heapAfterReuseBytes, heapAfterDestroyBytes: destroyed,
                populateNanoseconds: live.populateNanoseconds, populateCPUNanoseconds: live.populateCPUNanoseconds,
                reuseNanoseconds: live.reuseNanoseconds, reuseCPUNanoseconds: live.reuseCPUNanoseconds,
                peakRSSBytes: peak, afterPopulate: Snapshot(live.afterPopulate), afterReuse: Snapshot(live.afterReuse))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(measurement), as: UTF8.self))
    }
}
