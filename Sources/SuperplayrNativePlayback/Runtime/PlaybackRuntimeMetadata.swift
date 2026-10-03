import Foundation
import SuperplayrPlaybackCore

enum RuntimeResourceKind: String, Sendable {
    case applicationPresentationGraph
    case playbackSessionWorkers
    case surface
    case pictureInPicture
    case input
    case decoder
    case subtitle
}

enum RuntimeResourceDisposition: String, Sendable {
    case current
    case superseded
    case releaseRequested
    case released
}

struct RuntimeResourceProvenance: Sendable, Equatable {
    let kind: RuntimeResourceKind
    let authority: PlaybackAuthority
    let creatorContext: PlaybackEffectContext
    let storageExecutor: ExecutorKind
}

struct RuntimeLeaseSnapshot: Sendable, Equatable {
    let leaseID: ResourceLeaseID
    let provenance: RuntimeResourceProvenance
    let disposition: RuntimeResourceDisposition
    let activeBorrows: Set<ResourceBorrowID>
}

/// Runtime mirror of the core's logical lease ledger. It never owns policy:
/// callers request/supersede/release leases and physical executors report the
/// final release only after their workers or platform borrows have settled.
final class RuntimeResourceLeaseLedger: @unchecked Sendable {
    private struct Record {
        let provenance: RuntimeResourceProvenance
        var disposition: RuntimeResourceDisposition
        var activeBorrows: Set<ResourceBorrowID>
    }

    private let lock = NSLock()
    private var records: [ResourceLeaseID: Record] = [:]
    private var nextLease: UInt64 = 1
    private var nextBorrow: UInt64 = 1

    func acquire(provenance: RuntimeResourceProvenance) -> ResourceLeaseID {
        lock.withLock {
            let id = ResourceLeaseID(rawValue: nextLease)
            nextLease &+= 1
            records[id] = Record(
                provenance: provenance,
                disposition: .current,
                activeBorrows: []
            )
            return id
        }
    }

    func borrow(_ leaseID: ResourceLeaseID) -> ResourceBorrowID? {
        lock.withLock {
            guard var record = records[leaseID], record.disposition == .current else {
                return nil
            }
            let id = ResourceBorrowID(rawValue: nextBorrow)
            nextBorrow &+= 1
            record.activeBorrows.insert(id)
            records[leaseID] = record
            return id
        }
    }

    func returnBorrow(_ borrowID: ResourceBorrowID, from leaseID: ResourceLeaseID) {
        lock.withLock {
            guard var record = records[leaseID] else { return }
            record.activeBorrows.remove(borrowID)
            records[leaseID] = record
        }
    }

    func supersede(authority: PlaybackAuthority) {
        lock.withLock {
            for id in records.keys {
                guard var record = records[id], record.provenance.authority == authority,
                      record.disposition == .current
                else { continue }
                record.disposition = .superseded
                records[id] = record
            }
        }
    }

    func requestRelease(_ leaseID: ResourceLeaseID) {
        lock.withLock {
            guard var record = records[leaseID], record.disposition != .released else { return }
            record.disposition = .releaseRequested
            records[leaseID] = record
        }
    }

    @discardableResult
    func observePhysicalRelease(_ leaseID: ResourceLeaseID) -> Bool {
        lock.withLock {
            guard var record = records[leaseID],
                  record.disposition == .releaseRequested,
                  record.activeBorrows.isEmpty
            else { return false }
            record.disposition = .released
            records[leaseID] = record
            return true
        }
    }

    func snapshots() -> [RuntimeLeaseSnapshot] {
        lock.withLock {
            records.map { id, record in
                RuntimeLeaseSnapshot(
                    leaseID: id,
                    provenance: record.provenance,
                    disposition: record.disposition,
                    activeBorrows: record.activeBorrows
                )
            }.sorted { $0.leaseID.rawValue < $1.leaseID.rawValue }
        }
    }
}

enum PostTerminalCallbackDisposition: Equatable, Sendable {
    case forward
    case cleanupOnly
    case drop
}

/// Installed before final quiescence is acknowledged. Resource-bearing late
/// callbacks may only settle custody; ordinary callbacks are dropped.
final class PostTerminalCallbackTombstone: @unchecked Sendable {
    private let lock = NSLock()
    private let epoch: ApplicationEpochID
    private var terminated = false

    init(epoch: ApplicationEpochID) {
        self.epoch = epoch
    }

    func install() {
        lock.withLock { terminated = true }
    }

    func disposition(
        for callbackEpoch: ApplicationEpochID,
        carriesResourceCustody: Bool
    ) -> PostTerminalCallbackDisposition {
        lock.withLock {
            guard callbackEpoch == epoch, !terminated else {
                return carriesResourceCustody ? .cleanupOnly : .drop
            }
            return .forward
        }
    }
}

struct RuntimeSessionMetadata: Sendable, Equatable {
    let authority: PlaybackAuthority
    let context: PlaybackEffectContext
    let workerLease: ResourceLeaseID
}

/// One deterministic ID directory for the native runtime adapter. The pure
/// core remains authoritative; this directory carries its identity shape to
/// final executor commit points while the coarse adapter is being dismantled.
final class PlaybackRuntimeMetadataDirectory: @unchecked Sendable {
    let applicationEpoch: ApplicationEpochID
    let leases = RuntimeResourceLeaseLedger()
    let callbackTombstone: PostTerminalCallbackTombstone

    private let lock = NSLock()
    private var nextSession: UInt64 = 1
    private var nextOperation: UInt64 = 1
    private var nextEffect: UInt64 = 1

    init(applicationEpoch: ApplicationEpochID = ApplicationEpochID(rawValue: 1)) {
        self.applicationEpoch = applicationEpoch
        callbackTombstone = PostTerminalCallbackTombstone(epoch: applicationEpoch)
    }

    func beginSession() -> RuntimeSessionMetadata {
        lock.withLock {
            let sessionID = PlaybackSessionID(rawValue: nextSession)
            nextSession &+= 1
            let operationID = PlaybackOperationID(rawValue: nextOperation)
            nextOperation &+= 1
            let effectID = PlaybackEffectID(rawValue: nextEffect)
            nextEffect &+= 1
            let authority = PlaybackAuthority.playback(
                sessionID: sessionID,
                generation: PlaybackGenerationID(rawValue: 1),
                revisions: PlaybackRevisionSet()
            )
            let context = PlaybackEffectContext(
                authority: authority,
                operationID: operationID,
                effectID: effectID
            )
            let lease = leases.acquire(provenance: RuntimeResourceProvenance(
                kind: .playbackSessionWorkers,
                authority: authority,
                creatorContext: context,
                storageExecutor: .resource
            ))
            return RuntimeSessionMetadata(
                authority: authority,
                context: context,
                workerLease: lease
            )
        }
    }

    func makeApplicationContext() -> PlaybackEffectContext {
        lock.withLock {
            let context = PlaybackEffectContext(
                authority: .application(applicationEpoch),
                operationID: PlaybackOperationID(rawValue: nextOperation),
                effectID: PlaybackEffectID(rawValue: nextEffect)
            )
            nextOperation &+= 1
            nextEffect &+= 1
            return context
        }
    }
}
