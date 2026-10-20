import Testing
import IlliquidPlaybackCore

@testable import IlliquidNativePlayback

@Suite("Runtime lease release history")
struct RuntimeLeaseHistoryTests {
    @Test
    func completedHistoryRemainsBoundedAcrossManySessionReplacements() {
        let directory = PlaybackRuntimeMetadataDirectory()
        for _ in 0..<4_096 {
            let session = directory.beginSession()
            directory.leases.supersede(authority: session.authority)
            directory.leases.requestRelease(session.workerLease)
            #expect(directory.leases.observePhysicalRelease(session.workerLease))
        }

        let snapshots = directory.leases.snapshots()
        #expect(snapshots.count == 128)
        #expect(snapshots.map(\.leaseID.rawValue) == Array(UInt64(3_969)...4_096))
        #expect(snapshots.allSatisfy {
            $0.disposition == .released && $0.activeBorrows.isEmpty
        })
    }

    @Test
    func historyPressureNeverEvictsUnresolvedLeasesOrTheirBorrows() throws {
        let ledger = RuntimeResourceLeaseLedger()
        var expected: [RuntimeLeaseSnapshot] = []
        // Keep more unresolved leases than the released-history limit. Cover
        // each unresolved disposition, including a requested release that has
        // no borrows but has not received physical completion yet.
        for index in 0..<320 {
            let provenance = historyTestProvenance(UInt64(index + 1))
            let lease = ledger.acquire(provenance: provenance)
            let borrow = try #require(ledger.borrow(lease))
            let disposition: RuntimeResourceDisposition
            var borrows: Set<ResourceBorrowID> = [borrow]
            switch index % 4 {
            case 0:
                disposition = .current
            case 1:
                ledger.supersede(authority: provenance.authority)
                disposition = .superseded
            default:
                ledger.requestRelease(lease)
                #expect(!ledger.observePhysicalRelease(lease))
                disposition = .releaseRequested
                if index % 4 == 3 {
                    ledger.returnBorrow(borrow, from: lease)
                    borrows = []
                }
            }
            expected.append(RuntimeLeaseSnapshot(
                leaseID: lease, provenance: provenance,
                disposition: disposition, activeBorrows: borrows
            ))
        }

        for index in 0..<1_024 {
            let provenance = historyTestProvenance(UInt64(index + 10_000))
            let lease = ledger.acquire(provenance: provenance)
            ledger.supersede(authority: provenance.authority)
            ledger.requestRelease(lease)
            #expect(ledger.observePhysicalRelease(lease))
        }

        let snapshots = ledger.snapshots()
        #expect(snapshots.count == expected.count + 128)
        #expect(snapshots.filter { $0.disposition != .released } == expected)
        for snapshot in expected {
            ledger.requestRelease(snapshot.leaseID)
            for borrow in snapshot.activeBorrows {
                ledger.returnBorrow(borrow, from: snapshot.leaseID)
            }
            #expect(ledger.observePhysicalRelease(snapshot.leaseID))
        }
        #expect(ledger.snapshots().count == 128)
        #expect(ledger.snapshots().map(\.leaseID) == expected.suffix(128).map(\.leaseID))
        #expect(ledger.snapshots().allSatisfy { $0.disposition == .released })
    }

    @Test
    func outOfOrderCompletionsRetainMostRecentReleasesRatherThanLargestIDs() {
        let ledger = RuntimeResourceLeaseLedger()
        let leases = (1...260).map {
            ledger.acquire(provenance: historyTestProvenance(UInt64($0)))
        }
        for lease in leases.reversed() {
            ledger.requestRelease(lease)
            #expect(ledger.observePhysicalRelease(lease))
        }

        let snapshots = ledger.snapshots()
        #expect(snapshots.count == 128)
        #expect(snapshots.map(\.leaseID) == Array(leases.prefix(128)))
        #expect(snapshots.map(\.provenance) == (1...128).map {
            historyTestProvenance(UInt64($0))
        })
    }

    @Test
    func snapshotsPreserveFullProvenanceAndSortLiveAndReleasedEvidence() throws {
        let ledger = RuntimeResourceLeaseLedger()
        let revisions = PlaybackRevisionSet(
            track: TrackRevisionID(rawValue: 11),
            decoder: DecoderRevisionID(rawValue: 12),
            videoFormat: MediaFormatRevisionID(rawValue: 13),
            audioFormat: MediaFormatRevisionID(rawValue: 14),
            presentation: PresentationRevisionID(rawValue: 15),
            presentationGraph: PresentationGraphRevisionID(rawValue: 16),
            presentationMembership: PresentationMembershipRevisionID(rawValue: 17),
            subtitle: SubtitleRevisionID(rawValue: 18),
            overlay: OverlayRevisionID(rawValue: 19),
            surface: SurfaceRevisionID(rawValue: 20)
        )
        let authority = PlaybackAuthority.playback(
            sessionID: PlaybackSessionID(rawValue: 41),
            generation: PlaybackGenerationID(rawValue: 7),
            revisions: revisions
        )
        let provenance = RuntimeResourceProvenance(
            kind: .decoder, authority: authority,
            creatorContext: PlaybackEffectContext(
                authority: authority,
                operationID: PlaybackOperationID(rawValue: 101),
                effectID: PlaybackEffectID(rawValue: 202),
                streamID: PlaybackStreamID(kind: .video, demuxIndex: 3),
                trackID: PlaybackTrackID(kind: .audio, mediaTrackID: 9)
            ),
            storageExecutor: .videoDecode
        )
        let first = ledger.acquire(provenance: provenance)
        let liveProvenance = historyTestProvenance(
            2, authority: .application(ApplicationEpochID(rawValue: 77))
        )
        let live = ledger.acquire(provenance: liveProvenance)
        let borrow = try #require(ledger.borrow(live))
        let lastProvenance = historyTestProvenance(3)
        let last = ledger.acquire(provenance: lastProvenance)
        for lease in [last, first] {
            ledger.requestRelease(lease)
            #expect(ledger.observePhysicalRelease(lease))
        }

        #expect(ledger.snapshots() == [
            RuntimeLeaseSnapshot(
                leaseID: first, provenance: provenance,
                disposition: .released, activeBorrows: []
            ),
            RuntimeLeaseSnapshot(
                leaseID: live, provenance: liveProvenance,
                disposition: .current, activeBorrows: [borrow]
            ),
            RuntimeLeaseSnapshot(
                leaseID: last, provenance: lastProvenance,
                disposition: .released, activeBorrows: []
            ),
        ])
    }

    @Test
    func supersessionMatchesCompleteAuthorityAndKeepsRequestedReleasesPending() {
        let ledger = RuntimeResourceLeaseLedger()
        let authorities: [PlaybackAuthority] = [
            .application(ApplicationEpochID(rawValue: 1)),
            .playback(sessionID: PlaybackSessionID(rawValue: 1),
                      generation: PlaybackGenerationID(rawValue: 1),
                      revisions: PlaybackRevisionSet()),
            .playback(sessionID: PlaybackSessionID(rawValue: 1),
                      generation: PlaybackGenerationID(rawValue: 2),
                      revisions: PlaybackRevisionSet()),
            .playback(sessionID: PlaybackSessionID(rawValue: 1),
                      generation: PlaybackGenerationID(rawValue: 1),
                      revisions: PlaybackRevisionSet(track: TrackRevisionID(rawValue: 1))),
        ]
        let leases = authorities.enumerated().map { index, authority in
            ledger.acquire(provenance: historyTestProvenance(UInt64(index), authority: authority))
        }
        let pending = ledger.acquire(provenance: historyTestProvenance(5, authority: authorities[1]))
        ledger.requestRelease(pending)
        ledger.supersede(authority: authorities[1])
        ledger.supersede(authority: authorities[1])

        #expect(ledger.snapshots().map(\.disposition) == [
            .current, .superseded, .current, .current, .releaseRequested,
        ])
        #expect(ledger.borrow(leases[1]) == nil)
        #expect(ledger.borrow(pending) == nil)
        #expect(!ledger.observePhysicalRelease(leases[1]))
        #expect(ledger.observePhysicalRelease(pending))
    }

    @Test
    func wrongDuplicateAndExpiredCallbacksNeverChangeCustodyOrRefreshHistory() throws {
        let ledger = RuntimeResourceLeaseLedger()
        let provenance = historyTestProvenance(1)
        let lease = ledger.acquire(provenance: provenance)
        let borrow = try #require(ledger.borrow(lease))
        let secondBorrow = try #require(ledger.borrow(lease))
        let currentEvidence = ledger.snapshots()
        let unknown = ResourceLeaseID(rawValue: UInt64.max)
        let wrongBorrow = ResourceBorrowID(rawValue: UInt64.max)
        #expect(!ledger.observePhysicalRelease(lease))
        ledger.requestRelease(lease)
        ledger.returnBorrow(wrongBorrow, from: lease)
        #expect(!ledger.observePhysicalRelease(lease))
        #expect(ledger.snapshots().first?.activeBorrows == [borrow, secondBorrow])
        ledger.returnBorrow(borrow, from: unknown)
        #expect(!ledger.observePhysicalRelease(lease))
        ledger.returnBorrow(borrow, from: lease)
        ledger.returnBorrow(borrow, from: lease)
        #expect(!ledger.observePhysicalRelease(lease))
        ledger.returnBorrow(secondBorrow, from: lease)
        #expect(ledger.observePhysicalRelease(lease))
        let releasedEvidence = ledger.snapshots()

        for index in 0..<129 {
            let beforeCallbacks = ledger.snapshots()
            for target in [lease, unknown] {
                #expect(ledger.borrow(target) == nil)
                ledger.requestRelease(target)
                ledger.returnBorrow(borrow, from: target)
                #expect(!ledger.observePhysicalRelease(target))
            }
            ledger.supersede(authority: provenance.authority)
            #expect(ledger.snapshots() == beforeCallbacks)
            let next = ledger.acquire(provenance: historyTestProvenance(UInt64(index + 2)))
            ledger.requestRelease(next)
            #expect(ledger.observePhysicalRelease(next))
        }
        #expect(!ledger.snapshots().contains { $0.leaseID == lease })
        #expect(ledger.snapshots().count == 128)
        // Published snapshots remain immutable across both custody changes
        // and overwriting their former history slots.
        #expect(currentEvidence.first?.disposition == .current)
        #expect(currentEvidence.first?.activeBorrows == [borrow, secondBorrow])
        #expect(releasedEvidence == [RuntimeLeaseSnapshot(
            leaseID: lease, provenance: provenance,
            disposition: .released, activeBorrows: []
        )])
    }

    @Test
    func seededOperationsAgreeWithAnUnboundedReferenceCustodyModel() {
        let ledger = RuntimeResourceLeaseLedger()
        var random = LeaseHistoryRandom(state: 0xD3A5_1E45_E128_2026)
        var reference: [ResourceLeaseID: ReferenceLease] = [:]
        var leases: [ResourceLeaseID] = []
        var returnedCandidates: [(ResourceLeaseID, ResourceBorrowID)] = []
        var completed: [ResourceLeaseID] = []
        var nextBorrow: UInt64 = 1
        let authorities = (1...8).map {
            historyTestProvenance(UInt64($0)).authority
        }

        for step in 0..<8_000 {
            let operation = random.next() % 8
            let lease = leases.isEmpty || random.next() % 17 == 0
                ? ResourceLeaseID(rawValue: UInt64.max)
                : leases[Int(random.next() % UInt64(leases.count))]
            switch operation {
            case 0, 6:
                let provenance = historyTestProvenance(
                    UInt64(leases.count + 1),
                    authority: authorities[Int(random.next() % UInt64(authorities.count))]
                )
                let created = ledger.acquire(provenance: provenance)
                #expect(created.rawValue == UInt64(leases.count + 1))
                leases.append(created)
                reference[created] = ReferenceLease(provenance: provenance)
                if operation == 6 {
                    ledger.requestRelease(created)
                    #expect(ledger.observePhysicalRelease(created))
                    reference[created]?.disposition = .released
                    completed.append(created)
                }
            case 1:
                let actual = ledger.borrow(lease)
                if reference[lease]?.disposition == .current {
                    let expected = ResourceBorrowID(rawValue: nextBorrow)
                    nextBorrow += 1
                    #expect(actual == expected)
                    reference[lease]?.borrows.insert(expected)
                    returnedCandidates.append((lease, expected))
                } else {
                    #expect(actual == nil)
                }
            case 2:
                if !returnedCandidates.isEmpty {
                    let candidate = returnedCandidates[
                        Int(random.next() % UInt64(returnedCandidates.count))
                    ]
                    let target = random.next() % 5 == 0 ? lease : candidate.0
                    ledger.returnBorrow(candidate.1, from: target)
                    reference[target]?.borrows.remove(candidate.1)
                }
            case 3:
                let authority = authorities[Int(random.next() % UInt64(authorities.count))]
                ledger.supersede(authority: authority)
                for id in reference.keys {
                    if reference[id]?.provenance.authority == authority,
                       reference[id]?.disposition == .current
                    {
                        reference[id]?.disposition = .superseded
                    }
                }
            case 4:
                ledger.requestRelease(lease)
                if let record = reference[lease], record.disposition != .released {
                    reference[lease]?.disposition = .releaseRequested
                }
            case 5:
                let expected = reference[lease]?.disposition == .releaseRequested
                    && reference[lease]?.borrows.isEmpty == true
                #expect(ledger.observePhysicalRelease(lease) == expected)
                if expected {
                    reference[lease]?.disposition = .released
                    completed.append(lease)
                }
            default:
                break
            }

            if step % 37 == 0 || step == 7_999 {
                // The oracle keeps the entire lifetime history and selects a
                // suffix at inspection time; it has no circular-buffer logic.
                let recent = Set(completed.suffix(128))
                let expected = reference.compactMap { id, record -> RuntimeLeaseSnapshot? in
                    guard record.disposition != .released || recent.contains(id) else { return nil }
                    return RuntimeLeaseSnapshot(
                        leaseID: id, provenance: record.provenance,
                        disposition: record.disposition, activeBorrows: record.borrows
                    )
                }.sorted { $0.leaseID < $1.leaseID }
                #expect(ledger.snapshots() == expected, "After operation \(step)")
            }
        }
        #expect(completed.count > 128)
        #expect(reference.values.contains { $0.disposition != .released })
    }
}

private func historyTestProvenance(
    _ seed: UInt64,
    authority: PlaybackAuthority? = nil
) -> RuntimeResourceProvenance {
    let resolved = authority ?? .playback(
        sessionID: PlaybackSessionID(rawValue: seed),
        generation: PlaybackGenerationID(rawValue: 1),
        revisions: PlaybackRevisionSet()
    )
    return RuntimeResourceProvenance(
        kind: .playbackSessionWorkers, authority: resolved,
        creatorContext: PlaybackEffectContext(
            authority: resolved,
            operationID: PlaybackOperationID(rawValue: seed * 2 + 1),
            effectID: PlaybackEffectID(rawValue: seed * 2 + 2)
        ),
        storageExecutor: .resource
    )
}

private struct ReferenceLease {
    let provenance: RuntimeResourceProvenance
    var disposition: RuntimeResourceDisposition = .current
    var borrows: Set<ResourceBorrowID> = []
}

private struct LeaseHistoryRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        // Use high bits so successive small modulo choices do not follow the
        // short low-bit cycle of the generator.
        return state >> 16
    }
}
