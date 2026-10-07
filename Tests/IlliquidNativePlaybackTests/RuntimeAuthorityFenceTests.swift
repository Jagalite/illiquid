import Foundation
import Testing
import IlliquidPlaybackCore

@testable import IlliquidNativePlayback

@Suite("Native runtime authority fences")
struct RuntimeAuthorityFenceTests {
    @Test
    func supersededOperationsRemainBoundedWhenNativeCallbacksNeverArrive() throws {
        var ledger = NativeOperationLedger()
        let sessionID = PlaybackSessionID(rawValue: 41)
        for n in UInt64(1)...1_000 {
            let transaction = nativeSeekTransaction(effectID: n, operationID: n, generation: n)
            _ = ledger.begin(transaction, supersessionCode: "seekSuperseded")
            _ = ledger.correlate(effectID: transaction.effectID,
                                 nativeSessionID: sessionID, nativeGeneration: Int(n))
        }
        #expect(ledger.activeCount == 1)
        #expect(ledger.retainedCount == 1)
        // A very late callback cannot complete or remove the newest seek.
        #expect(ledger.take(nativeSessionID: sessionID, nativeGeneration: 1) == nil)
        let completed = ledger.take(nativeSessionID: sessionID, nativeGeneration: 1_000)
        let latest = try #require(completed)
        #expect(latest.effectID == PlaybackEffectID(rawValue: 1_000))
        #expect(ledger.retainedCount == 0)
        #expect(ledger.take(nativeSessionID: sessionID, nativeGeneration: 999) == nil)
    }

    @Test
    func cancelledOperationRetiresWithoutCallbackAndCannotBeRecorrelated() {
        var ledger = NativeOperationLedger()
        let transaction = nativeSeekTransaction(effectID: 1, operationID: 1, generation: 1)
        let sessionID = PlaybackSessionID(rawValue: 41)
        _ = ledger.begin(transaction, supersessionCode: "seekSuperseded")
        _ = ledger.correlate(effectID: transaction.effectID,
                             nativeSessionID: sessionID, nativeGeneration: 7)
        #expect(ledger.cancel(effectID: transaction.effectID, code: "nativeOperationTimedOut") != nil)
        #expect(ledger.activeCount == 0)
        #expect(ledger.retainedCount == 0)
        #expect(ledger.cancel(effectID: transaction.effectID, code: "duplicate") == nil)
        #expect(ledger.correlate(effectID: transaction.effectID,
                                nativeSessionID: sessionID, nativeGeneration: 8) == nil)
        #expect(ledger.take(effectID: transaction.effectID) == nil)
        #expect(ledger.take(nativeSessionID: sessionID, nativeGeneration: 7) == nil)
        #expect(ledger.take(nativeSessionID: sessionID, nativeGeneration: 8) == nil)
    }

    @Test
    func explicitSubtitleSourceNeverConflatesExternalOffAndAutomaticIngress() {
        let externalURL = URL(fileURLWithPath: "/tmp/subtitle.ass")
        #expect(NativeSubtitleSource.automaticEmbedded.acceptsEmbeddedPackets)
        #expect(NativeSubtitleSource.embedded(streamIndex: 7).acceptsEmbeddedPackets)
        #expect(!NativeSubtitleSource.off.acceptsEmbeddedPackets)
        #expect(!NativeSubtitleSource.external(url: externalURL).acceptsEmbeddedPackets)
        #expect(
            NativeSubtitleSource.external(url: externalURL)
                != NativeSubtitleSource.automaticEmbedded
        )
    }

    @Test
    func nativeOperationLedgerCorrelatesSupersededPreviewCallbacksExactly() throws {
        var ledger = NativeOperationLedger()
        let first = nativeSeekTransaction(effectID: 1, operationID: 1, generation: 1)
        let second = nativeSeekTransaction(effectID: 2, operationID: 2, generation: 2)

        #expect(ledger.begin(first, supersessionCode: "seekSuperseded") == nil)
        _ = ledger.correlate(
            effectID: first.effectID,
            nativeSessionID: PlaybackSessionID(rawValue: 41),
            nativeGeneration: 7
        )
        let supersededCandidate = ledger.begin(
            second,
            supersessionCode: "seekSuperseded"
        )
        let superseded = try #require(supersededCandidate)
        #expect(superseded.effectID == first.effectID)
        _ = ledger.correlate(
            effectID: second.effectID,
            nativeSessionID: PlaybackSessionID(rawValue: 41),
            nativeGeneration: 8
        )

        #expect(ledger.take(
            kind: .seek,
            nativeSessionID: PlaybackSessionID(rawValue: 41),
            nativeGeneration: 7
        ) == nil)
        #expect(ledger.take(
            kind: .seek,
            nativeSessionID: PlaybackSessionID(rawValue: 41),
            nativeGeneration: 8
        )?.effectID == second.effectID)
        #expect(ledger.retainedCount == 0)
    }

    @Test
    func nativeOperationLedgerRejectsCallbackFromAnotherNativeSession() {
        var ledger = NativeOperationLedger()
        let transaction = nativeSeekTransaction(
            effectID: 3,
            operationID: 3,
            generation: 3
        )
        _ = ledger.begin(transaction, supersessionCode: "seekSuperseded")
        _ = ledger.correlate(
            effectID: transaction.effectID,
            nativeSessionID: PlaybackSessionID(rawValue: 50),
            nativeGeneration: 9
        )

        #expect(ledger.take(
            kind: .seek,
            nativeSessionID: PlaybackSessionID(rawValue: 49),
            nativeGeneration: 9
        ) == nil)
        #expect(ledger.take(
            kind: .seek,
            nativeSessionID: PlaybackSessionID(rawValue: 50),
            nativeGeneration: 9
        )?.effectID == transaction.effectID)
    }

    @Test
    func flushAcknowledgmentsAreScopedDuplicateSafeAndPostTerminalSafe() {
        let ledger = PresentationFlushAcknowledgmentLedger()
        let first = PresentationFence(rawValue: 1)
        let second = PresentationFence(rawValue: 2)
        ledger.install(first)
        #expect(ledger.observe(fence: first, component: .audio) == .accepted)
        #expect(ledger.observe(fence: first, component: .audio) == .duplicate)

        // A missing video callback cannot block installation of the next
        // control fence. If it arrives later, it is stale and cleanup-only.
        ledger.install(second)
        #expect(ledger.snapshot().fence == second)
        #expect(ledger.observe(fence: first, component: .video) == .stale)
        #expect(ledger.observe(fence: second, component: .video) == .accepted)
        ledger.terminate()
        #expect(ledger.observe(fence: second, component: .video)
          == .droppedAfterTermination)
    }

    @Test
    func supersededLeaseCannotBeBorrowedAndReleasesOnlyAfterBorrowReturns() throws {
        let directory = PlaybackRuntimeMetadataDirectory()
        let session = directory.beginSession()
        let borrow = try #require(directory.leases.borrow(session.workerLease))
        directory.leases.supersede(authority: session.authority)
        #expect(directory.leases.borrow(session.workerLease) == nil)
        directory.leases.requestRelease(session.workerLease)
        #expect(!directory.leases.observePhysicalRelease(session.workerLease))
        directory.leases.returnBorrow(borrow, from: session.workerLease)
        #expect(directory.leases.observePhysicalRelease(session.workerLease))
        #expect(directory.leases.snapshots().first?.disposition == .released)
    }

    @Test
    func tombstoneSeparatesResourceCleanupFromOrdinaryCallbacks() {
        let epoch = ApplicationEpochID(rawValue: 7)
        let tombstone = PostTerminalCallbackTombstone(epoch: epoch)
        #expect(tombstone.disposition(for: epoch, carriesResourceCustody: false) == .forward)
        tombstone.install()
        #expect(tombstone.disposition(for: epoch, carriesResourceCustody: false) == .drop)
        #expect(tombstone.disposition(for: epoch, carriesResourceCustody: true) == .cleanupOnly)
        #expect(tombstone.disposition(
            for: ApplicationEpochID(rawValue: 6),
            carriesResourceCustody: false
        ) == .drop)
    }

    @Test
    func subtitleFinalCommitRejectsPreInvalidationWork() {
        let fence = SubtitleRevisionFence()
        let old = fence.current
        let current = fence.beginInvalidation()
        #expect(!fence.commitOverlay(old))
        #expect(fence.acknowledgeSourceInvalidation(current))
        #expect(fence.commitVisibleClear(current))
        #expect(fence.commitOverlay(current))
        #expect(fence.snapshot().rejectedOverlayCommits == 1)
    }

    @Test
    func rendererMembershipSerializesEveryMediaModeAndRapidReadd() {
        var video = RendererMembershipLedger(attached: true)
        var audio = RendererMembershipLedger(attached: true)
        let videoOnly = PresentationFence(rawValue: 1)
        #expect(video.request(true, fence: videoOnly) == .none)
        #expect(audio.request(false, fence: videoOnly) == .remove(videoOnly))
        #expect(audio.observeRemoval(fence: videoOnly) == .none)
        #expect(video.snapshot.attached)
        #expect(!audio.snapshot.attached)

        let audioOnly = PresentationFence(rawValue: 2)
        #expect(video.request(false, fence: audioOnly) == .remove(audioOnly))
        #expect(audio.request(true, fence: audioOnly) == .add)
        #expect(video.observeRemoval(fence: audioOnly) == .none)
        #expect(!video.snapshot.attached)
        #expect(audio.snapshot.attached)

        let zeroOutput = PresentationFence(rawValue: 3)
        #expect(audio.request(false, fence: zeroOutput) == .remove(zeroOutput))
        let audioVideo = PresentationFence(rawValue: 4)
        #expect(video.request(true, fence: audioVideo) == .add)
        // The re-add is deferred until the old asynchronous removal settles.
        #expect(audio.request(true, fence: audioVideo) == .none)
        #expect(audio.observeRemoval(fence: zeroOutput) == .add)
        #expect(video.snapshot.attached && video.snapshot.desired)
        #expect(audio.snapshot.attached && audio.snapshot.desired)
    }

    @Test
    func rendererDemandGateConsumesCallbackGrantsWithoutPolling() {
        let gate = RendererDemandGate()
        let epoch = gate.beginEpoch()
        gate.offer(epoch: epoch)
        #expect(gate.consume(while: { true }))
        gate.close()
        #expect(!gate.consume(while: { true }))
    }

    @Test
    func rendererDemandGateRejectsGrantsFromRevokedEOFGeneration() {
        let gate = RendererDemandGate()
        let endedEpoch = gate.beginEpoch()
        gate.revoke()
        let replayEpoch = gate.beginEpoch()

        gate.offer(epoch: endedEpoch)
        gate.offer(epoch: replayEpoch)
        #expect(gate.consume(while: { true }))
        gate.close()
    }

    @Test
    func rendererDemandLifecycleSuspendsAndRearmsOncePerEOFCycle() {
        var lifecycle = EndOfStreamDemandLifecycle()
        let firstSuspend = lifecycle.suspendIfNeeded()
        let duplicateSuspend = lifecycle.suspendIfNeeded()
        #expect(firstSuspend)
        #expect(!duplicateSuspend)
        #expect(lifecycle.isSuspended)
        let firstResume = lifecycle.resumeIfNeeded()
        let duplicateResume = lifecycle.resumeIfNeeded()
        #expect(firstResume)
        #expect(!duplicateResume)
        #expect(!lifecycle.isSuspended)
        let secondSuspend = lifecycle.suspendIfNeeded()
        #expect(secondSuspend)
    }

    @Test
    func deterministicCommitBarriersForceEveryRequiredStaleInterleaving() throws {
        let barrier = DifferentialCommitBarrier()
        let kinds: [DifferentialCommitKind] = [
            .video, .audio, .subtitle, .rateChange, .endOfStream, .hardwareFailure,
        ]
        let oldTokens = kinds.map { kind in
            barrier.arm(kind)
            return barrier.arrive(kind: kind, epoch: 1)
        }
        #expect(barrier.pendingCount == kinds.count)
        for optionalToken in oldTokens {
            let token = try #require(optionalToken)
            #expect(barrier.release(
                token,
                currentEpoch: 2,
                terminated: false,
                carriesResourceCustody: false
            ) == .stale)
        }

        barrier.arm(.inputRead)
        let blockedRead = try #require(barrier.arrive(kind: .inputRead, epoch: 2))
        #expect(barrier.release(
            blockedRead,
            currentEpoch: 2,
            terminated: true,
            carriesResourceCustody: true
        ) == .cleanupOnly)
        #expect(barrier.release(
            blockedRead,
            currentEpoch: 2,
            terminated: true,
            carriesResourceCustody: true
        ) == .duplicate)
        #expect(barrier.pendingCount == 0)
    }

    @Test
    func deterministicRaceReportExecutesEveryPlannedInterleaving() {
        let report = DifferentialRaceQualification.run()
        #expect(report.passed)
        #expect(Set(report.outcomes.map(\.scenario)) == Set(DifferentialRaceScenarioID.allCases))
        #expect(report.outcomes.allSatisfy { $0.passed })
    }

    private func nativeSeekTransaction(
        effectID: UInt64,
        operationID: UInt64,
        generation: UInt64
    ) -> NativeOperationTransaction {
        let target = MediaTimestamp.valid(
            ValidMediaTime(value: Int64(generation), timescale: 1)!
        )
        let effect = PlaybackEffect(
            executor: .input,
            context: PlaybackEffectContext(
                authority: .playback(
                    sessionID: PlaybackSessionID(rawValue: 1),
                    generation: PlaybackGenerationID(rawValue: generation),
                    revisions: PlaybackRevisionSet()
                ),
                operationID: PlaybackOperationID(rawValue: operationID),
                effectID: PlaybackEffectID(rawValue: effectID)
            ),
            kind: .seekPipeline(target: target, mode: .preview)
        )
        return NativeOperationTransaction(
            effect: effect,
            kind: .seek,
            requestedState: .seek(target: target, mode: .preview),
            deadline: ContinuousClock().now.advanced(by: .seconds(100))
        )
    }
}
