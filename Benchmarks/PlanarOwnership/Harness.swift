import Foundation
import Dispatch
#if os(macOS)
import CoreMedia
import CoreVideo
import Darwin
#else
import Glibc
#endif

private func makePixelBuffer() -> CVPixelBuffer {
    #if os(macOS)
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(
        kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil, &buffer
    ) == kCVReturnSuccess)
    return buffer!
    #else
    return CVPixelBuffer()
    #endif
}

// This deliberately does not inspect allocation addresses, dictionary order,
// or wall-clock values. Every integer field, flag, and timing *presence* stays
// in the differential comparison. The native tests qualify actual CM lifetime
// attachments; timed workloads call the unchanged ledger attachment method.
private func normalized(_ s: PlanarBufferOwnershipSnapshot) -> [String: Any] {
    var result: [String: Any] = [
        "totalCheckouts": s.totalCheckouts,
        "distinctBufferIdentitiesSeen": s.distinctBufferIdentitiesSeen,
        "reuseCheckouts": s.reuseCheckouts,
        "reuseWhileKnownOwned": s.reuseWhileKnownOwned,
        "applicationFrames": s.applicationFrames,
        "peakApplicationFrames": s.peakApplicationFrames,
        "decodedFrames": s.decodedFrames,
        "framesWaitingForQueue": s.framesWaitingForQueue,
        "queuedFrames": s.queuedFrames,
        "presentingFrames": s.presentingFrames,
        "submittedApplicationFrames": s.submittedApplicationFrames,
        "rendererSampleAttachments": s.rendererSampleAttachments,
        "peakRendererSampleAttachments": s.peakRendererSampleAttachments,
        "knownOutstandingBuffers": s.knownOutstandingBuffers,
        "peakKnownOutstandingBuffers": s.peakKnownOutstandingBuffers,
        "oldGenerationKnownOutstandingBuffers": s.oldGenerationKnownOutstandingBuffers,
        "poolThresholdWaits": s.poolThresholdWaits,
        "poolTimeouts": s.poolTimeouts,
        "lastTimeout": NSNull(), "lastFlush": NSNull(),
    ]
    if let timeout = s.lastTimeout {
        precondition(timeout.oldestRendererSampleMilliseconds.isFinite
            && timeout.oldestRendererSampleMilliseconds >= 0)
        result["lastTimeout"] = [
            "generation": timeout.generation,
            "knownOutstandingBuffers": timeout.knownOutstandingBuffers,
            "applicationFrames": timeout.applicationFrames,
            "queuedFrames": timeout.queuedFrames,
            "presentingFrames": timeout.presentingFrames,
            "submittedApplicationFrames": timeout.submittedApplicationFrames,
            "rendererSampleAttachments": timeout.rendererSampleAttachments,
            "oldestRendererSampleMilliseconds": "nonnegative finite clock value",
        ]
    }
    if let flush = s.lastFlush {
        for elapsed in [flush.videoFlushCompletionMilliseconds,
                        flush.oldGenerationKnownBuffersReachedZeroMilliseconds].compactMap({ $0 }) {
            precondition(elapsed.isFinite && elapsed >= 0)
        }
        result["lastFlush"] = [
            "activeGeneration": flush.activeGeneration,
            "oldGenerationKnownBuffersAtRequest": flush.oldGenerationKnownBuffersAtRequest,
            "oldGenerationRendererSamplesAtRequest": flush.oldGenerationRendererSamplesAtRequest,
            "videoFlushCompleted": flush.videoFlushCompleted,
            "oldGenerationKnownBuffersAtVideoCompletion":
                flush.oldGenerationKnownBuffersAtVideoCompletion.map { $0 as Any } ?? NSNull(),
            "oldGenerationRendererSamplesAtVideoCompletion":
                flush.oldGenerationRendererSamplesAtVideoCompletion.map { $0 as Any } ?? NSNull(),
            "videoFlushCompletionMillisecondsPresent": flush.videoFlushCompletionMilliseconds != nil,
            "oldGenerationKnownBuffersReachedZeroMillisecondsPresent":
                flush.oldGenerationKnownBuffersReachedZeroMilliseconds != nil,
        ]
    }
    return result
}

private struct Random {
    var value: UInt64
    mutating func next() -> UInt64 {
        value = value &* 6364136223846793005 &+ 1442695040888963407
        return value
    }
}

private struct TraceSlot {
    var id: UInt64 = 0
    var token: PlanarFrameOwnershipToken?
    var attachment: PlanarRendererSampleLifetimeAttachment?
}

private func trace(seed: UInt64, steps: Int) -> [String: Any] {
    let ledger = PlanarBufferOwnershipLedger()
    let buffers = (0..<8).map { _ in makePixelBuffer() }
    var slots = Array(repeating: TraceSlot(), count: 32)
    var random = Random(value: seed)
    var maximumID: UInt64 = 0
    var snapshots: [[String: Any]] = []
    snapshots.reserveCapacity(steps + 1)
    for step in 0..<steps {
        // Use upper bits: the low bits of this LCG have short cycles.
        let slot = Int((random.next() >> 32) % UInt64(slots.count))
        let operation = Int((random.next() >> 32) % 15)
        let generation = Int((random.next() >> 32) % 4) + 1
        let id = slots[slot].id
        switch operation {
        case 0, 14:
            slots[slot].token = nil
            slots[slot].attachment = nil
            let buffer = Int((random.next() >> 32) % UInt64(buffers.count))
            let token = ledger.checkout(generation: generation, pixelBuffer: buffers[buffer])
            slots[slot].id = token.checkoutID
            slots[slot].token = token
            maximumID = max(maximumID, token.checkoutID)
        case 1:
            let phase = PlanarFrameOwnershipPhase(rawValue: Int((random.next() >> 32) % 5))!
            ledger.transition(id, to: phase)
        case 2:
            if let attachment = ledger.makeRendererSampleAttachment(checkoutID: id) {
                slots[slot].attachment = attachment
            }
        case 3:
            ledger.releaseApplicationFrame(checkoutID: id)
        case 4:
            ledger.releaseRendererSampleAttachment(checkoutID: id)
        case 5:
            slots[slot].token = nil
        case 6:
            slots[slot].attachment = nil
        case 7:
            ledger.recordFlushRequested(activeGeneration: generation)
        case 8:
            ledger.recordVideoFlushCompleted(activeGeneration: generation)
        case 9:
            ledger.recordPoolThresholdWait(generation: generation)
        case 10:
            ledger.recordPoolTimeout(generation: generation)
        case 11:
            break
        case 12:
            ledger.transition(id, to: .submitted)
            ledger.transition(id, to: .submitted)
            ledger.transition(id, to: .decoded)
        default:
            let unknown = maximumID + 17
            ledger.transition(unknown, to: .queued)
            ledger.releaseApplicationFrame(checkoutID: unknown)
            ledger.releaseRendererSampleAttachment(checkoutID: unknown)
        }
        snapshots.append([
            "step": step, "operation": operation,
            "snapshot": normalized(ledger.snapshot(activeGeneration: generation)),
        ])
    }
    // Drop both real ARC owners. Explicit stale callbacks above deliberately
    // coexist with real deinit callbacks, and must remain harmless.
    for index in slots.indices {
        slots[index].token = nil
        slots[index].attachment = nil
    }
    let final = ledger.snapshot(activeGeneration: 1)
    precondition(final.applicationFrames == 0 && final.rendererSampleAttachments == 0
        && final.knownOutstandingBuffers == 0)
    snapshots.append(["step": steps, "operation": "release-all", "snapshot": normalized(final)])
    withExtendedLifetime(buffers) {}
    return ["seed": seed, "steps": steps, "snapshots": snapshots]
}

private protocol Workload: AnyObject {
    var ledger: PlanarBufferOwnershipLedger { get }
    var configuration: [String: Any] { get }
    func run(_ count: Int)
}

private func queuedToken(
    ledger: PlanarBufferOwnershipLedger, buffer: CVPixelBuffer
) -> PlanarFrameOwnershipToken {
    let token = ledger.checkout(generation: 1, pixelBuffer: buffer)
    token.transition(to: .waitingForQueue)
    token.transition(to: .queued)
    return token
}

private func present(
    _ token: PlanarFrameOwnershipToken, ledger: PlanarBufferOwnershipLedger
) -> PlanarRendererSampleLifetimeAttachment {
    token.transition(to: .presenting)
    let sample = ledger.makeRendererSampleAttachment(checkoutID: token.checkoutID)!
    token.transition(to: .submitted)
    return sample
}

// One full steady-state frame service: retire a renderer-held sample, present
// an older queued frame, then recycle the released identity into a new queued
// frame. No pixel-buffer object is allocated inside the timed interval.
private final class PipelineWorkload: Workload {
    let ledger = PlanarBufferOwnershipLedger()
    private let buffers: [CVPixelBuffer]
    private var queue: [PlanarFrameOwnershipToken?]
    private var samples: [PlanarRendererSampleLifetimeAttachment?]
    private var queueIdentities: [Int]
    private var sampleIdentities: [Int]
    private var queueCursor = 0
    private var sampleCursor = 0

    init(occupancy: Int) {
        let queued = min(7, occupancy)
        let rendered = occupancy - queued
        buffers = (0..<occupancy).map { _ in makePixelBuffer() }
        queue = Array(repeating: nil, count: queued)
        samples = Array(repeating: nil, count: rendered)
        queueIdentities = Array(0..<queued)
        sampleIdentities = Array(queued..<occupancy)
        for index in queue.indices {
            queue[index] = queuedToken(ledger: ledger, buffer: buffers[index])
        }
        for index in samples.indices {
            samples[index] = present(
                queuedToken(ledger: ledger, buffer: buffers[queued + index]), ledger: ledger
            )
        }
        let snapshot = ledger.snapshot(activeGeneration: 1)
        precondition(snapshot.applicationFrames == queued
            && snapshot.rendererSampleAttachments == rendered
            && snapshot.knownOutstandingBuffers == occupancy)
    }

    var configuration: [String: Any] {
        ["queued_application_owners": queue.count,
         "retained_renderer_only_owners": samples.count,
         "release_order": "application then renderer",
         "unit": "full steady-state frame service"]
    }

    func run(_ count: Int) {
        for _ in 0..<count {
            let completedIdentity = queueIdentities[queueCursor]
            let recycledIdentity: Int
            if !samples.isEmpty {
                recycledIdentity = sampleIdentities[sampleCursor]
                samples[sampleCursor] = nil
            } else {
                recycledIdentity = completedIdentity
            }
            var sample: PlanarRendererSampleLifetimeAttachment? = present(
                queue[queueCursor]!, ledger: ledger
            )
            queue[queueCursor] = nil
            if !samples.isEmpty {
                samples[sampleCursor] = sample
                sampleIdentities[sampleCursor] = completedIdentity
                sampleCursor = (sampleCursor + 1) % samples.count
            }
            sample = nil
            queue[queueCursor] = queuedToken(ledger: ledger, buffer: buffers[recycledIdentity])
            queueIdentities[queueCursor] = recycledIdentity
            queueCursor = (queueCursor + 1) % queue.count
        }
    }
}

private struct Survivor {
    var application: PlanarFrameOwnershipToken?
    var renderer: PlanarRendererSampleLifetimeAttachment?
}

// Supplementary lifetime-order control: each slot retains exactly one owner;
// retired slots alternate application-first and renderer-first release.
private final class MixedLifetimeWorkload: Workload {
    let ledger = PlanarBufferOwnershipLedger()
    private let buffers: [CVPixelBuffer]
    private var survivors: [Survivor]
    private var cursor = 0
    private var applicationFirst = false

    init(occupancy: Int) {
        buffers = (0..<occupancy).map { _ in makePixelBuffer() }
        survivors = Array(repeating: Survivor(), count: occupancy)
        for index in survivors.indices {
            survivors[index] = makeSurvivor(buffer: buffers[index], applicationFirst: index % 2 == 0)
        }
    }

    private func makeSurvivor(buffer: CVPixelBuffer, applicationFirst: Bool) -> Survivor {
        var token: PlanarFrameOwnershipToken? = queuedToken(ledger: ledger, buffer: buffer)
        var sample: PlanarRendererSampleLifetimeAttachment? = present(token!, ledger: ledger)
        if applicationFirst {
            token = nil
            return Survivor(application: nil, renderer: sample)
        }
        sample = nil
        return Survivor(application: token, renderer: nil)
    }

    var configuration: [String: Any] {
        ["retained_single_owners": survivors.count,
         "release_order": "alternating application-first and renderer-first",
         "unit": "full frame lifecycle; delayed survivor retired on reuse"]
    }

    func run(_ count: Int) {
        for _ in 0..<count {
            survivors[cursor] = Survivor()
            survivors[cursor] = makeSurvivor(
                buffer: buffers[cursor], applicationFirst: applicationFirst
            )
            applicationFirst.toggle()
            cursor = (cursor + 1) % survivors.count
        }
    }
}

// Deliberate diagnostic stress: several checkouts alias two identities.
// The record-count bound exceeds the true identity peak, so the candidate
// must retain its exact set calculation. This is not healthy pool reuse.
private final class AliasedWorkload: Workload {
    let ledger = PlanarBufferOwnershipLedger()
    private let buffers: [CVPixelBuffer]
    private var tokens: [PlanarFrameOwnershipToken?]
    private var cursor = 0

    init(occupancy: Int) {
        precondition(occupancy >= 4)
        buffers = (0..<2).map { _ in makePixelBuffer() }
        tokens = Array(repeating: nil, count: occupancy)
        for index in tokens.indices {
            tokens[index] = queuedToken(ledger: ledger, buffer: buffers[index % 2])
        }
    }

    var configuration: [String: Any] {
        ["retained_application_owners": tokens.count,
         "distinct_buffer_identities": 2,
         "unit": "aliased checkout, attachment and renderer release; fallback control"]
    }

    func run(_ count: Int) {
        for _ in 0..<count {
            tokens[cursor] = nil
            let token = queuedToken(ledger: ledger, buffer: buffers[cursor % 2])
            var sample: PlanarRendererSampleLifetimeAttachment? = present(token, ledger: ledger)
            withExtendedLifetime(sample) {}
            sample = nil
            tokens[cursor] = token
            cursor = (cursor + 1) % tokens.count
        }
    }
}

private func validateWorkloadSnapshot(
    _ snapshot: PlanarBufferOwnershipSnapshot, name: String, occupancy: Int
) {
    if name == "aliased" {
        precondition(snapshot.applicationFrames == occupancy
            && snapshot.rendererSampleAttachments == 0
            && snapshot.knownOutstandingBuffers == 2
            && snapshot.peakKnownOutstandingBuffers == 2
            && snapshot.reuseWhileKnownOwned > 0)
    } else {
        precondition(snapshot.knownOutstandingBuffers == occupancy
            && snapshot.reuseWhileKnownOwned == 0)
    }
}

private final class PhaseWorkload: Workload {
    let ledger = PlanarBufferOwnershipLedger()
    private let buffers: [CVPixelBuffer]
    private var tokens: [PlanarFrameOwnershipToken] = []
    private var cursor = 0
    init(occupancy: Int) {
        buffers = (0..<occupancy).map { _ in makePixelBuffer() }
        tokens = buffers.map { buffer in
            let token = queuedToken(ledger: ledger, buffer: buffer)
            token.transition(to: .submitted)
            return token
        }
    }
    var configuration: [String: Any] {
        ["retained_application_owners": tokens.count,
         "unit": "one accepted equal-phase transition; ablation only"]
    }
    func run(_ count: Int) {
        for _ in 0..<count {
            tokens[cursor].transition(to: .submitted)
            cursor = (cursor + 1) % tokens.count
        }
    }
}

private func makeWorkload(_ name: String, occupancy: Int) -> any Workload {
    switch name {
    case "pipeline": return PipelineWorkload(occupancy: occupancy)
    case "lifecycle-mixed": return MixedLifetimeWorkload(occupancy: occupancy)
    case "phase": return PhaseWorkload(occupancy: occupancy)
    case "aliased": return AliasedWorkload(occupancy: occupancy)
    default: fatalError("Unknown workload: \(name)")
    }
}

private struct AllocatorMeter {
    typealias Action = @convention(c) () -> Void
    typealias Read = @convention(c) () -> UInt64
    let begin: Action
    let end: Action
    let requests: Read
    let bytes: Read
    init?(_ enabled: Bool) {
        guard enabled else { return nil }
        guard let a = dlsym(nil, "meter_begin"), let b = dlsym(nil, "meter_end"),
              let c = dlsym(nil, "meter_requests"), let d = dlsym(nil, "meter_bytes")
        else { fatalError("--meter requires the Linux allocation interposer") }
        begin = unsafeBitCast(a, to: Action.self)
        end = unsafeBitCast(b, to: Action.self)
        requests = unsafeBitCast(c, to: Read.self)
        bytes = unsafeBitCast(d, to: Read.self)
    }
}

@main private struct Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func argument(_ key: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count
            else { return fallback }
            return arguments[index + 1]
        }
        let mode = argument("--mode", default: "trace")
        let result: [String: Any]
        if mode == "trace" {
            result = trace(
                seed: UInt64(argument("--seed", default: "1"))!,
                steps: Int(argument("--steps", default: "2000"))!
            )
        } else if mode == "smoke" {
            var cases: [[String: Any]] = []
            for name in ["pipeline", "lifecycle-mixed", "phase", "aliased"] {
                for occupancy in (name == "aliased" ? [11] : [1, 7, 11, 16, 32]) {
                    let workload = makeWorkload(name, occupancy: occupancy)
                    workload.run(1001)
                    let snapshot = workload.ledger.snapshot(activeGeneration: 1)
                    validateWorkloadSnapshot(snapshot, name: name, occupancy: occupancy)
                    if name == "pipeline" {
                        precondition(snapshot.applicationFrames == min(7, occupancy)
                            && snapshot.queuedFrames == min(7, occupancy)
                            && snapshot.rendererSampleAttachments == max(0, occupancy - 7))
                    }
                    cases.append(["workload": name, "occupancy": occupancy,
                                  "configuration": workload.configuration,
                                  "snapshot": normalized(snapshot)])
                    withExtendedLifetime(workload) {}
                }
            }
            result = ["untimed_workload_correctness": cases]
        } else {
            let occupancy = Int(argument("--occupancy", default: "11"))!
            let iterations = Int(argument("--iterations", default: "100000"))!
            let warmup = Int(argument("--warmup", default: "10000"))!
            precondition(occupancy > 0 && iterations > 0 && warmup >= 0)
            let name = argument("--workload", default: "pipeline")
            let workload = makeWorkload(name, occupancy: occupancy)
            workload.run(warmup)
            let meter = AllocatorMeter(arguments.contains("--meter"))
            meter?.begin()
            let start = DispatchTime.now().uptimeNanoseconds
            workload.run(iterations)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            meter?.end()
            let snapshot = workload.ledger.snapshot(activeGeneration: 1)
            validateWorkloadSnapshot(snapshot, name: name, occupancy: occupancy)
            var row: [String: Any] = [
                "workload": name, "occupancy": occupancy, "iterations": iterations,
                "warmup": warmup, "configuration": workload.configuration,
                "elapsed_nanoseconds": elapsed,
                "nanoseconds_per_unit": Double(elapsed) / Double(iterations),
                "allocator_instrumented": meter != nil,
                "snapshot": normalized(snapshot),
            ]
            if let meter {
                row["allocation_requests"] = meter.requests()
                row["allocation_requested_bytes"] = meter.bytes()
            }
            result = row
            withExtendedLifetime(workload) {}
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
