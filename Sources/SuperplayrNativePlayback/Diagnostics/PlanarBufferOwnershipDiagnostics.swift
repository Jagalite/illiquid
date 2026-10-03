import CoreMedia
import CoreVideo
import Foundation
import os.signpost

enum PlanarFrameOwnershipPhase: Int, Sendable {
    case decoded
    case waitingForQueue
    case queued
    case presenting
    case submitted
}

struct PlanarPoolTimeoutOwnershipSnapshot: Equatable, Sendable {
    let generation: Int
    let knownOutstandingBuffers: Int
    let applicationFrames: Int
    let queuedFrames: Int
    let presentingFrames: Int
    let submittedApplicationFrames: Int
    let rendererSampleAttachments: Int
    let oldestRendererSampleMilliseconds: Double
}

struct PlanarFlushOwnershipSnapshot: Equatable, Sendable {
    let activeGeneration: Int
    let oldGenerationKnownBuffersAtRequest: Int
    let oldGenerationRendererSamplesAtRequest: Int
    let videoFlushCompleted: Bool
    let oldGenerationKnownBuffersAtVideoCompletion: Int?
    let oldGenerationRendererSamplesAtVideoCompletion: Int?
    let videoFlushCompletionMilliseconds: Double?
    let oldGenerationKnownBuffersReachedZeroMilliseconds: Double?
}

struct PlanarBufferOwnershipSnapshot: Equatable, Sendable {
    var totalCheckouts = 0
    var distinctBufferIdentitiesSeen = 0
    var reuseCheckouts = 0
    var reuseWhileKnownOwned = 0
    var applicationFrames = 0
    var peakApplicationFrames = 0
    var decodedFrames = 0
    var framesWaitingForQueue = 0
    var queuedFrames = 0
    var presentingFrames = 0
    var submittedApplicationFrames = 0
    var rendererSampleAttachments = 0
    var peakRendererSampleAttachments = 0
    var knownOutstandingBuffers = 0
    var peakKnownOutstandingBuffers = 0
    var oldGenerationKnownOutstandingBuffers = 0
    var poolThresholdWaits = 0
    var poolTimeouts = 0
    var lastTimeout: PlanarPoolTimeoutOwnershipSnapshot?
    var lastFlush: PlanarFlushOwnershipSnapshot?
}

/// Tracks only ownership that Superplayr can prove. A renderer sample
/// attachment proves the submitted CMSampleBuffer remains alive; it does not
/// prove that Apple has not separately retained or copied its CVPixelBuffer.
final class PlanarBufferOwnershipLedger: @unchecked Sendable {
    private struct Checkout {
        let generation: Int
        let bufferIdentity: UInt
        var phase: PlanarFrameOwnershipPhase
        var applicationFrameAlive = true
        var rendererSampleAttachmentAlive = false
        var rendererSampleAttachedUptime: TimeInterval?
    }

    private struct FlushObservation {
        let activeGeneration: Int
        let requestedUptime: TimeInterval
        let oldGenerationKnownBuffersAtRequest: Int
        let oldGenerationRendererSamplesAtRequest: Int
        var videoFlushCompletedUptime: TimeInterval?
        var oldGenerationKnownBuffersAtVideoCompletion: Int?
        var oldGenerationRendererSamplesAtVideoCompletion: Int?
        var oldGenerationKnownBuffersReachedZeroUptime: TimeInterval?
    }

    private let lock = NSLock()
    private var nextCheckoutID: UInt64 = 1
    private var checkouts: [UInt64: Checkout] = [:]
    private var lastCheckoutByBuffer: [UInt: UInt64] = [:]
    private var seenBufferIdentities: Set<UInt> = []
    private var totalCheckouts = 0
    private var reuseCheckouts = 0
    private var reuseWhileKnownOwned = 0
    private var peakApplicationFrames = 0
    private var peakRendererSampleAttachments = 0
    private var peakKnownOutstandingBuffers = 0
    private var poolThresholdWaits = 0
    private var poolTimeouts = 0
    private var lastTimeout: PlanarPoolTimeoutOwnershipSnapshot?
    private var lastFlush: FlushObservation?

    func checkout(
        generation: Int,
        pixelBuffer: CVPixelBuffer
    ) -> PlanarFrameOwnershipToken {
        let identity = UInt(bitPattern: Unmanaged
            .passUnretained(pixelBuffer)
            .toOpaque())
        let checkoutID = lock.withLock { () -> UInt64 in
            let checkoutID = nextCheckoutID
            nextCheckoutID &+= 1
            totalCheckouts += 1
            if seenBufferIdentities.insert(identity).inserted == false {
                reuseCheckouts += 1
            }
            if let previous = lastCheckoutByBuffer[identity],
               checkouts[previous] != nil
            {
                reuseWhileKnownOwned += 1
            }
            lastCheckoutByBuffer[identity] = checkoutID
            checkouts[checkoutID] = Checkout(
                generation: generation,
                bufferIdentity: identity,
                phase: .decoded
            )
            updatePeaksLocked()
            return checkoutID
        }
        return PlanarFrameOwnershipToken(checkoutID: checkoutID, ledger: self)
    }

    func transition(_ checkoutID: UInt64, to phase: PlanarFrameOwnershipPhase) {
        lock.withLock {
            guard var checkout = checkouts[checkoutID], checkout.applicationFrameAlive else {
                return
            }
            guard phase.rawValue >= checkout.phase.rawValue else { return }
            checkout.phase = phase
            checkouts[checkoutID] = checkout
            updatePeaksLocked()
        }
    }

    func makeRendererSampleAttachment(
        checkoutID: UInt64
    ) -> PlanarRendererSampleLifetimeAttachment? {
        let attached = lock.withLock { () -> Bool in
            guard var checkout = checkouts[checkoutID],
                  !checkout.rendererSampleAttachmentAlive
            else { return false }
            checkout.rendererSampleAttachmentAlive = true
            checkout.rendererSampleAttachedUptime = ProcessInfo.processInfo.systemUptime
            checkouts[checkoutID] = checkout
            updatePeaksLocked()
            return true
        }
        return attached
            ? PlanarRendererSampleLifetimeAttachment(
                checkoutID: checkoutID,
                ledger: self
            )
            : nil
    }

    func releaseApplicationFrame(checkoutID: UInt64) {
        lock.withLock {
            guard var checkout = checkouts[checkoutID] else { return }
            checkout.applicationFrameAlive = false
            checkouts[checkoutID] = checkout
            removeIfReleasedLocked(checkoutID)
            updateFlushZeroLocked()
        }
    }

    func releaseRendererSampleAttachment(checkoutID: UInt64) {
        lock.withLock {
            guard var checkout = checkouts[checkoutID] else { return }
            checkout.rendererSampleAttachmentAlive = false
            checkout.rendererSampleAttachedUptime = nil
            checkouts[checkoutID] = checkout
            removeIfReleasedLocked(checkoutID)
            updateFlushZeroLocked()
        }
    }

    func recordFlushRequested(activeGeneration: Int) {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            lastFlush = FlushObservation(
                activeGeneration: activeGeneration,
                requestedUptime: now,
                oldGenerationKnownBuffersAtRequest:
                    oldGenerationKnownBufferCountLocked(activeGeneration: activeGeneration),
                oldGenerationRendererSamplesAtRequest:
                    oldGenerationRendererSampleCountLocked(activeGeneration: activeGeneration)
            )
            updateFlushZeroLocked(now: now)
        }
    }

    func recordVideoFlushCompleted(activeGeneration: Int) {
        lock.withLock {
            guard var flush = lastFlush,
                  flush.activeGeneration == activeGeneration,
                  flush.videoFlushCompletedUptime == nil
            else { return }
            let now = ProcessInfo.processInfo.systemUptime
            flush.videoFlushCompletedUptime = now
            flush.oldGenerationKnownBuffersAtVideoCompletion =
                oldGenerationKnownBufferCountLocked(activeGeneration: activeGeneration)
            flush.oldGenerationRendererSamplesAtVideoCompletion =
                oldGenerationRendererSampleCountLocked(activeGeneration: activeGeneration)
            lastFlush = flush
            updateFlushZeroLocked(now: now)
        }
    }

    func recordPoolThresholdWait(generation: Int) {
        lock.withLock { poolThresholdWaits += 1 }
    }

    func recordPoolTimeout(generation: Int) {
        let timeout = lock.withLock { () -> PlanarPoolTimeoutOwnershipSnapshot in
            poolTimeouts += 1
            let timeout = timeoutSnapshotLocked(generation: generation)
            lastTimeout = timeout
            return timeout
        }
        os_signpost(
            .event,
            log: nativeVideoSignpostLog,
            name: "PlanarPoolTimeoutOwnership",
            "gen=%d known=%d app=%d queued=%d presenting=%d submitted=%d samples=%d oldest-sample-ms=%.3f",
            timeout.generation,
            timeout.knownOutstandingBuffers,
            timeout.applicationFrames,
            timeout.queuedFrames,
            timeout.presentingFrames,
            timeout.submittedApplicationFrames,
            timeout.rendererSampleAttachments,
            timeout.oldestRendererSampleMilliseconds
        )
    }

    func snapshot(activeGeneration: Int) -> PlanarBufferOwnershipSnapshot {
        lock.withLock { snapshotLocked(activeGeneration: activeGeneration) }
    }

    private func snapshotLocked(activeGeneration: Int) -> PlanarBufferOwnershipSnapshot {
        var snapshot = PlanarBufferOwnershipSnapshot(
            totalCheckouts: totalCheckouts,
            distinctBufferIdentitiesSeen: seenBufferIdentities.count,
            reuseCheckouts: reuseCheckouts,
            reuseWhileKnownOwned: reuseWhileKnownOwned,
            peakApplicationFrames: peakApplicationFrames,
            peakRendererSampleAttachments: peakRendererSampleAttachments,
            peakKnownOutstandingBuffers: peakKnownOutstandingBuffers,
            poolThresholdWaits: poolThresholdWaits,
            poolTimeouts: poolTimeouts,
            lastTimeout: lastTimeout,
            lastFlush: flushSnapshotLocked()
        )
        var outstandingIdentities: Set<UInt> = []
        var oldGenerationIdentities: Set<UInt> = []
        for checkout in checkouts.values {
            guard checkout.applicationFrameAlive || checkout.rendererSampleAttachmentAlive else {
                continue
            }
            outstandingIdentities.insert(checkout.bufferIdentity)
            if checkout.generation != activeGeneration {
                oldGenerationIdentities.insert(checkout.bufferIdentity)
            }
            if checkout.applicationFrameAlive {
                snapshot.applicationFrames += 1
                switch checkout.phase {
                case .decoded: snapshot.decodedFrames += 1
                case .waitingForQueue: snapshot.framesWaitingForQueue += 1
                case .queued: snapshot.queuedFrames += 1
                case .presenting: snapshot.presentingFrames += 1
                case .submitted: snapshot.submittedApplicationFrames += 1
                }
            }
            if checkout.rendererSampleAttachmentAlive {
                snapshot.rendererSampleAttachments += 1
            }
        }
        snapshot.knownOutstandingBuffers = outstandingIdentities.count
        snapshot.oldGenerationKnownOutstandingBuffers = oldGenerationIdentities.count
        return snapshot
    }

    private func timeoutSnapshotLocked(
        generation: Int
    ) -> PlanarPoolTimeoutOwnershipSnapshot {
        let current = snapshotLocked(activeGeneration: generation)
        let now = ProcessInfo.processInfo.systemUptime
        let oldest = checkouts.values.compactMap { checkout -> TimeInterval? in
            guard checkout.rendererSampleAttachmentAlive else { return nil }
            return checkout.rendererSampleAttachedUptime
        }.min()
        return PlanarPoolTimeoutOwnershipSnapshot(
            generation: generation,
            knownOutstandingBuffers: current.knownOutstandingBuffers,
            applicationFrames: current.applicationFrames,
            queuedFrames: current.queuedFrames,
            presentingFrames: current.presentingFrames,
            submittedApplicationFrames: current.submittedApplicationFrames,
            rendererSampleAttachments: current.rendererSampleAttachments,
            oldestRendererSampleMilliseconds: oldest.map {
                max(0, now - $0) * 1_000
            } ?? 0
        )
    }

    private func updatePeaksLocked() {
        let applicationFrames = checkouts.values.reduce(0) {
            $0 + ($1.applicationFrameAlive ? 1 : 0)
        }
        let rendererSamples = checkouts.values.reduce(0) {
            $0 + ($1.rendererSampleAttachmentAlive ? 1 : 0)
        }
        let knownBuffers = Set(checkouts.values.compactMap { checkout in
            checkout.applicationFrameAlive || checkout.rendererSampleAttachmentAlive
                ? checkout.bufferIdentity : nil
        }).count
        peakApplicationFrames = max(peakApplicationFrames, applicationFrames)
        peakRendererSampleAttachments = max(
            peakRendererSampleAttachments,
            rendererSamples
        )
        peakKnownOutstandingBuffers = max(peakKnownOutstandingBuffers, knownBuffers)
    }

    private func oldGenerationKnownBufferCountLocked(activeGeneration: Int) -> Int {
        Set<UInt>(checkouts.values.compactMap { checkout in
            guard checkout.generation != activeGeneration,
                  checkout.applicationFrameAlive || checkout.rendererSampleAttachmentAlive
            else { return nil }
            return checkout.bufferIdentity
        }).count
    }

    private func oldGenerationRendererSampleCountLocked(activeGeneration: Int) -> Int {
        checkouts.values.reduce(0) { result, checkout in
            result + (
                checkout.generation != activeGeneration
                    && checkout.rendererSampleAttachmentAlive ? 1 : 0
            )
        }
    }

    private func updateFlushZeroLocked(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard var flush = lastFlush,
              flush.oldGenerationKnownBuffersReachedZeroUptime == nil,
              oldGenerationKnownBufferCountLocked(
                  activeGeneration: flush.activeGeneration
              ) == 0
        else { return }
        flush.oldGenerationKnownBuffersReachedZeroUptime = now
        lastFlush = flush
    }

    private func flushSnapshotLocked() -> PlanarFlushOwnershipSnapshot? {
        guard let flush = lastFlush else { return nil }
        return PlanarFlushOwnershipSnapshot(
            activeGeneration: flush.activeGeneration,
            oldGenerationKnownBuffersAtRequest:
                flush.oldGenerationKnownBuffersAtRequest,
            oldGenerationRendererSamplesAtRequest:
                flush.oldGenerationRendererSamplesAtRequest,
            videoFlushCompleted: flush.videoFlushCompletedUptime != nil,
            oldGenerationKnownBuffersAtVideoCompletion:
                flush.oldGenerationKnownBuffersAtVideoCompletion,
            oldGenerationRendererSamplesAtVideoCompletion:
                flush.oldGenerationRendererSamplesAtVideoCompletion,
            videoFlushCompletionMilliseconds: flush.videoFlushCompletedUptime.map {
                max(0, $0 - flush.requestedUptime) * 1_000
            },
            oldGenerationKnownBuffersReachedZeroMilliseconds:
                flush.oldGenerationKnownBuffersReachedZeroUptime.map {
                    max(0, $0 - flush.requestedUptime) * 1_000
                }
        )
    }

    private func removeIfReleasedLocked(_ checkoutID: UInt64) {
        guard let checkout = checkouts[checkoutID],
              !checkout.applicationFrameAlive,
              !checkout.rendererSampleAttachmentAlive
        else { return }
        checkouts.removeValue(forKey: checkoutID)
    }
}

final class PlanarFrameOwnershipToken: @unchecked Sendable {
    let checkoutID: UInt64
    private let ledger: PlanarBufferOwnershipLedger

    fileprivate init(checkoutID: UInt64, ledger: PlanarBufferOwnershipLedger) {
        self.checkoutID = checkoutID
        self.ledger = ledger
    }

    deinit { ledger.releaseApplicationFrame(checkoutID: checkoutID) }

    func transition(to phase: PlanarFrameOwnershipPhase) {
        ledger.transition(checkoutID, to: phase)
    }

    func attachRendererSampleLifetime(to sampleBuffer: CMSampleBuffer) {
        guard let attachment = ledger.makeRendererSampleAttachment(
            checkoutID: checkoutID
        ) else { return }
        CMSetAttachment(
            sampleBuffer,
            key: "com.superplayr.native.planar-renderer-sample-lifetime" as CFString,
            value: attachment,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
    }
}

final class PlanarRendererSampleLifetimeAttachment: NSObject, @unchecked Sendable {
    private let checkoutID: UInt64
    private let ledger: PlanarBufferOwnershipLedger

    fileprivate init(checkoutID: UInt64, ledger: PlanarBufferOwnershipLedger) {
        self.checkoutID = checkoutID
        self.ledger = ledger
    }

    deinit { ledger.releaseRendererSampleAttachment(checkoutID: checkoutID) }
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
