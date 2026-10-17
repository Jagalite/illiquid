import Foundation
import Testing
@testable import IlliquidCore

@Suite("Persistence request lifetimes")
struct PersistenceWriterLifetimeTests {
    private final class Locked<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func read() -> Value { lock.withLock { value } }
        func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
    }

    private final class OnRelease: Sendable {
        let action: @Sendable () -> Void
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }
        deinit { action() }
    }

    private struct Payload: Sendable {
        let revision: Int
        let onRelease: OnRelease?
        init(_ revision: Int, onRelease: OnRelease? = nil) {
            self.revision = revision
            self.onRelease = onRelease
        }
    }

    enum Kind: CaseIterable, Sendable { case value, snapshot }

    private func submit(
        _ kind: Kind,
        to writer: CoalescingPersistenceWriter<Payload>,
        revision: Int,
        captures: Locked<[Int]>,
        onRelease: OnRelease? = nil
    ) {
        let payload = Payload(revision, onRelease: onRelease)
        switch kind {
        case .value: writer.submit(payload)
        case .snapshot:
            writer.submitSnapshot {
                captures.update { $0.append(revision) }
                return payload
            }
        }
    }

    // Use a separate dispatch thread and a bounded wait, rather than hanging the
    // test process on a same-thread recursive NSLock acquisition. On the old
    // implementation the wait times out; teardown then lets the worker finish.
    @Test(arguments: Kind.allCases, Kind.allCases)
    func supersededRequestIsReleasedOutsideWriterLock(old: Kind, replacement: Kind) throws {
        let writes = Locked([Int]()), captures = Locked([Int]())
        let released = Locked(0), releasedOutsideLock = Locked(false)
        let reentered = DispatchGroup()
        let queue = DispatchQueue(label: "test.persistence.release-reentry")
        let writer = CoalescingPersistenceWriter<Payload>(label: "test.persistence.lifetime", delay: 60) {
            payload in writes.update { $0.append(payload.revision) }
        }
        submit(old, to: writer, revision: 1, captures: captures, onRelease: OnRelease {
            released.update { $0 += 1 }
            reentered.enter()
            queue.async {
                writer.submit(Payload(3))
                reentered.leave()
            }
            let completed = reentered.wait(timeout: .now() + 2) == .success
            releasedOutsideLock.update { $0 = completed }
        })
        submit(replacement, to: writer, revision: 2, captures: captures)
        #expect(released.read() == 1)
        #expect(releasedOutsideLock.read(), "Superseded request was destroyed while the writer lock was held")
        try #require(reentered.wait(timeout: .now() + 5) == .success)
        try writer.flushSynchronously().get()
        #expect(writes.read() == [3], "Cleanup's newer submission must not be overwritten by the outer enqueue")
        #expect(captures.read().isEmpty, "Neither superseded snapshot factory should run")
    }

    @Test(arguments: Kind.allCases)
    func supersededCleanupCanFlushTheReplacement(_ kind: Kind) throws {
        let writes = Locked([Int]()), captures = Locked([Int]())
        let flushed = DispatchGroup(), releasedOutsideLock = Locked(false)
        let flushSucceeded = Locked(false)
        let queue = DispatchQueue(label: "test.persistence.release-flush")
        let writer = CoalescingPersistenceWriter<Payload>(label: "test.persistence.flush-reentry", delay: 60) {
            payload in writes.update { $0.append(payload.revision) }
        }
        submit(kind, to: writer, revision: 1, captures: captures, onRelease: OnRelease {
            flushed.enter()
            queue.async {
                if case .success = writer.flushSynchronously() {
                    flushSucceeded.update { $0 = true }
                }
                flushed.leave()
            }
            let completed = flushed.wait(timeout: .now() + 2) == .success
            releasedOutsideLock.update { $0 = completed }
        })
        submit(.snapshot, to: writer, revision: 2, captures: captures)
        #expect(releasedOutsideLock.read())
        try #require(flushed.wait(timeout: .now() + 5) == .success)
        #expect(flushSucceeded.read())
        #expect(writes.read() == [2])
        #expect(captures.read() == [2])
    }

    @Test(arguments: Kind.allCases)
    func supersededRequestsAreReleasedWithoutWaitingForDrain(_ kind: Kind) throws {
        let releases = Locked(0), writes = Locked([Int]()), captures = Locked([Int]())
        let writer = CoalescingPersistenceWriter<Payload>(label: "test.persistence.release-count", delay: 60) {
            payload in writes.update { $0.append(payload.revision) }
        }
        for revision in 0..<1_000 {
            submit(kind, to: writer, revision: revision, captures: captures, onRelease: OnRelease {
                releases.update { $0 += 1 }
            })
        }
        #expect(releases.read() == 999)
        #expect(writes.read().isEmpty)
        #expect(captures.read().isEmpty)
        try writer.flushSynchronously().get()
        #expect(releases.read() == 1_000)
        #expect(writes.read() == [999])
        #expect(captures.read() == (kind == .snapshot ? [999] : []))
    }

    @Test(arguments: Kind.allCases)
    func activeWriteDoesNotPreventPendingRequestCleanup(_ kind: Kind) throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let reentered = DispatchGroup(), releasedOutsideLock = Locked(false)
        let writes = Locked([Int]()), captures = Locked([Int]())
        let callbackTimedOut = Locked(false)
        let queue = DispatchQueue(label: "test.persistence.active-reentry")
        let writer = CoalescingPersistenceWriter<Payload>(label: "test.persistence.active", delay: 0) { payload in
            if payload.revision == 0 {
                entered.signal()
                if release.wait(timeout: .now() + 10) != .success {
                    callbackTimedOut.update { $0 = true }
                }
            }
            writes.update { $0.append(payload.revision) }
        }
        defer { release.signal() }
        writer.submit(Payload(0))
        try #require(entered.wait(timeout: .now() + 5) == .success)
        submit(kind, to: writer, revision: 1, captures: captures, onRelease: OnRelease {
            reentered.enter()
            queue.async {
                writer.submit(Payload(3))
                reentered.leave()
            }
            let completed = reentered.wait(timeout: .now() + 2) == .success
            releasedOutsideLock.update { $0 = completed }
        })
        writer.submit(Payload(2))
        #expect(releasedOutsideLock.read())
        try #require(reentered.wait(timeout: .now() + 5) == .success)
        release.signal()
        try writer.flushSynchronously().get()
        #expect(!callbackTimedOut.read())
        #expect(writes.read() == [0, 3])
        #expect(captures.read().isEmpty)
    }

    @Test func failedFlushStaysFailedUntilANewerWriteSucceeds() async throws {
        let writes = Locked([Int]())
        let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.error-contract", delay: 60) { value in
            if value == 1 { throw CocoaError(.fileWriteNoPermission) }
            writes.update { $0.append(value) }
        }
        writer.submitSnapshot { 1 }
        if case .success = writer.flushSynchronously() { Issue.record("Failed write was acknowledged") }
        if case .success = await writer.flush() { Issue.record("Empty flush erased the previous failure") }
        writer.submitSnapshot { 2 }
        try await writer.flush().get()
        try writer.flushSynchronously().get()
        #expect(writes.read() == [2])
    }

    @Test func newerPendingSnapshotSupersedesAnInFlightWriteFailure() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempts = Locked([Int]()), callbackTimedOut = Locked(false)
        let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.latest-result", delay: 0) { value in
            attempts.update { $0.append(value) }
            if value == 1 {
                entered.signal()
                if release.wait(timeout: .now() + 10) != .success {
                    callbackTimedOut.update { $0 = true }
                }
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        defer { release.signal() }
        writer.submit(1)
        try #require(entered.wait(timeout: .now() + 5) == .success)
        writer.submitSnapshot { 2 }
        release.signal()
        try writer.flushSynchronously().get()
        #expect(!callbackTimedOut.read())
        #expect(attempts.read() == [1, 2])
    }

    @Test func snapshotFactoryCanSubmitWithoutHoldingWriterLock() throws {
        let writes = Locked([Int]())
        let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.factory-reentry", delay: 60) {
            value in writes.update { $0.append(value) }
        }
        writer.submitSnapshot {
            writer.submit(2)
            return 1
        }
        try writer.flushSynchronously().get()
        #expect(writes.read() == [1, 2])
    }

    @Test func concurrentReplacementAndFlushPreserveFinalMarker() throws {
        let releases = Locked(0), latest = Locked(-1), captures = Locked([Int]())
        let writer = CoalescingPersistenceWriter<Payload>(label: "test.persistence.concurrent-lifetimes", delay: 0.001) {
            payload in latest.update { $0 = payload.revision }
        }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for sequence in 0..<500 {
                let revision = worker * 500 + sequence
                submit(sequence.isMultiple(of: 2) ? .value : .snapshot,
                       to: writer, revision: revision, captures: captures, onRelease: OnRelease {
                    releases.update { $0 += 1 }
                })
                if sequence.isMultiple(of: 101) { _ = writer.flushSynchronously() }
            }
        }
        writer.submit(Payload(42_424_242))
        try writer.flushSynchronously().get()
        #expect(latest.read() == 42_424_242)
        #expect(releases.read() == 4_000)
    }
}
