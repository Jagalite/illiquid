import CLeaseHeap
import Foundation
import IlliquidPlaybackCore

// This caller is compiled alongside the entire, unchanged production metadata
// file. It does not reimplement the ledger or provide platform/type stand-ins.
private struct RetainedCounts: Encodable, Equatable {
    let snapshots: Int
    let unresolved: Int
    let released: Int
    let activeBorrows: Int
}

private struct CanonicalSnapshot: Encodable {
    let leaseID: UInt64
    let kind: String
    let authority: PlaybackAuthority
    let creatorContext: PlaybackEffectContext
    let storageExecutor: String
    let disposition: String
    let activeBorrows: [UInt64]

    init(_ snapshot: RuntimeLeaseSnapshot) {
        leaseID = snapshot.leaseID.rawValue
        kind = snapshot.provenance.kind.rawValue
        authority = snapshot.provenance.authority
        creatorContext = snapshot.provenance.creatorContext
        storageExecutor = snapshot.provenance.storageExecutor.rawValue
        disposition = snapshot.disposition.rawValue
        activeBorrows = snapshot.activeBorrows.map(\.rawValue).sorted()
    }
}

private struct WorkResult: Encodable, Equatable {
    var succeededReleases = 0
    var checksum: UInt64 = 0
}

private final class Fixture {
    let directory = PlaybackRuntimeMetadataDirectory()
    var current: RuntimeSessionMetadata
    var lastReleasedID: UInt64?

    init(history: Int, pending: Int) {
        // Native presentation ownership: three long-lived graph leases, two
        // held platform borrows, and one replaceable session worker lease.
        for index in 0..<3 {
            let context = directory.makeApplicationContext()
            let lease = directory.leases.acquire(provenance: RuntimeResourceProvenance(
                kind: .applicationPresentationGraph, authority: context.authority,
                creatorContext: context, storageExecutor: .presentation
            ))
            if index < 2 { precondition(directory.leases.borrow(lease) != nil) }
        }
        // Delayed physical teardown control: these workers remain unresolved
        // and borrowed even when the completed history becomes large.
        for _ in 0..<pending {
            let session = directory.beginSession()
            precondition(directory.leases.borrow(session.workerLease) != nil)
            directory.leases.supersede(authority: session.authority)
            directory.leases.requestRelease(session.workerLease)
            precondition(!directory.leases.observePhysicalRelease(session.workerLease))
        }
        for _ in 0..<history {
            let session = directory.beginSession()
            // Skip only supersede during untimed seeding, avoiding quadratic
            // baseline setup. requestRelease and physical completion produce
            // exactly the same retained final state as a complete replacement.
            directory.leases.requestRelease(session.workerLease)
            precondition(directory.leases.observePhysicalRelease(session.workerLease))
            lastReleasedID = session.workerLease.rawValue
        }
        current = directory.beginSession()
    }

    @inline(never)
    func replaceSessions(_ count: Int) -> WorkResult {
        var result = WorkResult()
        for _ in 0..<count {
            let replacement = directory.beginSession()
            let old = current
            directory.leases.supersede(authority: old.authority)
            directory.leases.requestRelease(old.workerLease)
            precondition(directory.leases.observePhysicalRelease(old.workerLease))
            result.succeededReleases += 1
            result.checksum = (result.checksum &* 16_777_619) ^ old.workerLease.rawValue
            result.checksum = (result.checksum &* 16_777_619) ^ replacement.workerLease.rawValue
            result.checksum = (result.checksum &* 16_777_619) ^ replacement.context.operationID.rawValue
            lastReleasedID = old.workerLease.rawValue
            current = replacement
        }
        return result
    }

    @inline(never)
    func counts() -> RetainedCounts {
        let snapshots = directory.leases.snapshots()
        return RetainedCounts(
            snapshots: snapshots.count,
            unresolved: snapshots.filter { $0.disposition != .released }.count,
            released: snapshots.filter { $0.disposition == .released }.count,
            activeBorrows: snapshots.reduce(0) { $0 + $1.activeBorrows.count }
        )
    }

    @inline(never)
    func snapshotCalls(_ count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<count {
            let snapshots = directory.leases.snapshots()
            checksum = (checksum &* 16_777_619) ^ UInt64(snapshots.count)
            checksum = (checksum &* 16_777_619) ^ (snapshots.first?.leaseID.rawValue ?? 0)
            checksum = (checksum &* 16_777_619) ^ (snapshots.last?.leaseID.rawValue ?? 0)
        }
        return checksum
    }

    func canonicalSnapshots() -> [CanonicalSnapshot] {
        // Releases in this workload complete in increasing ID order. Comparing
        // the explicit contract projection does not assert lifetime-history
        // equivalence. Separate regression tests exercise out-of-order release.
        let firstRecentID = lastReleasedID.map { $0 > 127 ? $0 - 127 : 0 } ?? 0
        return directory.leases.snapshots().filter {
            $0.disposition != .released || $0.leaseID.rawValue >= firstRecentID
        }.map(CanonicalSnapshot.init)
    }
}

private struct CanonicalReceipt: Encodable {
    let schema = 1
    let history: Int
    let pending: Int
    let cycles: Int
    let work: WorkResult
    let retainedActual: RetainedCounts
    let snapshots: [CanonicalSnapshot]
}

private struct Measurement: Encodable {
    let schema = 1
    let historyStart: Int
    let historyEnd: Int
    let pending: Int
    let cycles: Int
    let snapshotCalls: Int
    let replacementWallNS: UInt64
    let replacementCPUNS: UInt64
    let snapshotWallNS: UInt64
    let snapshotCPUNS: UInt64
    let work: WorkResult
    let snapshotChecksum: UInt64
    let retainedAfter: RetainedCounts
    let allocatorMetric: String
    let allocatorBeforeFixture: UInt64
    let allocatorAfterSeed: UInt64
    let allocatorAfterCycles: UInt64
}

@main
private struct RuntimeLeaseHistoryHarness {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6,
              ["measure", "canonical"].contains(args[1]),
              let history = Int(args[2]), let pending = Int(args[3]),
              let cycles = Int(args[4]), let snapshotCalls = Int(args[5]),
              history >= 0, pending >= 0, cycles >= 0, snapshotCalls > 0,
              (args[1] == "canonical" || cycles > 0)
        else { fatalError("Usage: RuntimeLeaseHistory measure|canonical HISTORY PENDING CYCLES SNAPSHOT_CALLS") }

        // Warm generic metadata, lock, allocation, and snapshot code in a
        // separate fixture that is destroyed before the measured fixture.
        warmup()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if args[1] == "canonical" {
            let fixture = Fixture(history: history, pending: pending)
            let work = fixture.replaceSessions(cycles)
            let result = CanonicalReceipt(
                history: history, pending: pending, cycles: cycles,
                work: work, retainedActual: fixture.counts(),
                snapshots: fixture.canonicalSnapshots()
            )
            FileHandle.standardOutput.write(try encoder.encode(result))
        } else {
            let heapBeforeFixture = lease_history_allocator_bytes()
            let fixture = Fixture(history: history, pending: pending)
            let heapAfterSeed = lease_history_allocator_bytes()
            let cpuStart = lease_history_process_cpu_ns()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let work = fixture.replaceSessions(cycles)
            let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpuElapsed = lease_history_process_cpu_ns() - cpuStart
            let heapAfterCycles = lease_history_allocator_bytes()
            let after = fixture.counts()
            let snapshotCPUStart = lease_history_process_cpu_ns()
            let snapshotWallStart = DispatchTime.now().uptimeNanoseconds
            let snapshotChecksum = fixture.snapshotCalls(snapshotCalls)
            let snapshotWallElapsed = DispatchTime.now().uptimeNanoseconds - snapshotWallStart
            let snapshotCPUElapsed = lease_history_process_cpu_ns() - snapshotCPUStart
            let result = Measurement(
                historyStart: history, historyEnd: history + cycles, pending: pending,
                cycles: cycles, snapshotCalls: snapshotCalls,
                replacementWallNS: wallElapsed, replacementCPUNS: cpuElapsed,
                snapshotWallNS: snapshotWallElapsed, snapshotCPUNS: snapshotCPUElapsed,
                work: work, snapshotChecksum: snapshotChecksum,
                retainedAfter: after,
                allocatorMetric: String(cString: lease_history_allocator_metric()),
                allocatorBeforeFixture: heapBeforeFixture,
                allocatorAfterSeed: heapAfterSeed, allocatorAfterCycles: heapAfterCycles
            )
            withExtendedLifetime(fixture) {
                // Encoding follows every measured interval and heap sample.
            }
            FileHandle.standardOutput.write(try encoder.encode(result))
        }
        FileHandle.standardOutput.write(Data([10]))
    }

    @inline(never)
    private static func warmup() {
        let fixture = Fixture(history: 0, pending: 0)
        precondition(fixture.replaceSessions(32).succeededReleases == 32)
        precondition(fixture.snapshotCalls(2) != 0)
        _ = lease_history_allocator_bytes()
        _ = lease_history_process_cpu_ns()
    }
}
