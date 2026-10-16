import Foundation
import XCTest
@testable import IlliquidCore

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult func update<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }; return body(&storage)
    }
}
private enum TestWriteError: Error { case injected }

final class DeferredPersistenceWriterTests: XCTestCase {
    func testOnlyNewestFactoryIsCapturedAndEagerSubmissionStillWorks() throws {
        let captured = Locked([Int]()), written = Locked([Int]())
        let writer = CoalescingPersistenceWriter<Int>(label: "test.lazy.coalescing", delay: 60) { value in
            written.update { $0.append(value) }
        }
        for revision in 0..<1_000 {
            writer.submitSnapshot { captured.update { $0.append(revision) }; return revision }
        }
        XCTAssertTrue(captured.read().isEmpty)
        try writer.flushSynchronously().get()
        XCTAssertEqual(captured.read(), [999])
        XCTAssertEqual(written.read(), [999])
        writer.submitSnapshot { XCTFail("superseded factory ran"); return -1 }
        writer.submit(1_000)
        try writer.flushSynchronously().get()
        XCTAssertEqual(written.read(), [999, 1_000])
    }

    func testFactoryDoesNotHoldWriterLockAndNewSubmissionIsNotLost() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let written = Locked([Int]())
        let writer = CoalescingPersistenceWriter<Int>(label: "test.factory.lock", delay: 0) { value in
            written.update { $0.append(value) }
        }
        writer.submitSnapshot {
            entered.signal()
            precondition(release.wait(timeout: .now() + 10) == .success)
            return 1
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { writer.submit(2); submitted.signal() }
        let submitResult = submitted.wait(timeout: .now() + 5)
        release.signal() // release even when the assertion would fail
        XCTAssertEqual(submitResult, .success)
        try writer.flushSynchronously().get()
        XCTAssertEqual(written.read(), [1, 2])
    }

    func testBlockedWriterRetainsImmutableSnapshotAndFlushWaitsForLatest() throws {
        let state = Locked(["position": 1])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let flushed = DispatchSemaphore(value: 0)
        let written = Locked([[String: Int]]())
        let writer = CoalescingPersistenceWriter<[String: Int]>(label: "test.blocked", delay: 0) { snapshot in
            if snapshot["position"] == 1 {
                entered.signal()
                precondition(release.wait(timeout: .now() + 10) == .success)
            }
            written.update { $0.append(snapshot) }
        }
        writer.submitSnapshot { state.read() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for value in 2...1_000 {
            state.update { $0["position"] = value }
            writer.submitSnapshot { state.read() }
        }
        DispatchQueue.global().async { _ = writer.flushSynchronously(); flushed.signal() }
        XCTAssertEqual(flushed.wait(timeout: .now() + 0.02), .timedOut)
        release.signal()
        XCTAssertEqual(flushed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(written.read(), [["position": 1], ["position": 1_000]])
    }

    func testFailureIsReportedAndLaterSuccessRecovers() throws {
        let writer = CoalescingPersistenceWriter<Int>(label: "test.errors", delay: 60) { value in
            if value == 1 { throw TestWriteError.injected }
        }
        writer.submitSnapshot { 1 }
        XCTAssertThrowsError(try writer.flushSynchronously().get())
        XCTAssertThrowsError(try writer.flushSynchronously().get())
        writer.submitSnapshot { 2 }
        try writer.flushSynchronously().get()
    }

    func testConcurrentSubmissionsAndFlushesPreserveFinalMarker() throws {
        let latest = Locked(-1)
        let writer = CoalescingPersistenceWriter<Int>(label: "test.concurrent", delay: 0.001) {
            value in latest.update { $0 = value }
        }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for sequence in 0..<500 {
                let value = worker * 500 + sequence
                if sequence % 2 == 0 { writer.submit(value) }
                else { writer.submitSnapshot { value } }
                if sequence % 101 == 0 { _ = writer.flushSynchronously() }
            }
        }
        writer.submitSnapshot { 42_424_242 }
        try writer.flushSynchronously().get()
        XCTAssertEqual(latest.read(), 42_424_242)
    }

    func testAsyncFlushRunsFactoryAndReturnsErrors() async throws {
        let written = Locked(0)
        let writer = CoalescingPersistenceWriter<Int>(label: "test.async.flush", delay: 60) { value in
            if value < 0 { throw TestWriteError.injected }
            written.update { $0 = value }
        }
        writer.submitSnapshot { 23 }
        try await writer.flush().get()
        XCTAssertEqual(written.read(), 23)
        writer.submitSnapshot { -1 }
        let failed = await writer.flush()
        if case .success = failed { XCTFail("failed write was reported as success") }
    }
}

final class DeferredHistoryStoreTests: XCTestCase {
    private func withStore(_ body: (PlaybackPersistenceStore, UserDefaults) throws -> Void) rethrows {
        let suite = "com.example.IlliquidDeferredTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        defer { store.flushSynchronously() }
        try body(store, defaults)
    }
    private let url = URL(fileURLWithPath: "/synthetic/episode.mkv")
    private func version(_ id: UInt64) -> MediaContentVersion {
        .init(fileIdentifier: id, byteCount: 100, modificationSeconds: 1,
              modificationNanoseconds: 0, creationSeconds: 0, creationNanoseconds: 0)
    }

    func testLatestProgressAndSettingsReloadThroughRealJSON() {
        withStore { store, defaults in
            for position in 1...500 { store.setPlaybackProgress(position: Double(position), duration: 3_600, for: url) }
            let settings = MediaPlaybackSettings(subtitleDelay: 2)
            store.setMediaSettings(settings, for: url)
            store.setLastOpenedMedia(.file(url))
            store.setLastWatchedFile(url, for: url.deletingLastPathComponent())
            store.flushSynchronously()
            let reloaded = PlaybackPersistenceStore(userDefaults: defaults)
            XCTAssertEqual(reloaded.playbackProgress(for: url)?.position, 500)
            XCTAssertEqual(reloaded.mediaSettings(for: url), settings)
            XCTAssertEqual(reloaded.lastOpenedMedia(), .file(url))
            XCTAssertEqual(reloaded.lastWatchedFile(for: url.deletingLastPathComponent()), url)
        }
    }

    func testCompletionAndContentReplacementHistoryArePreserved() {
        withStore { store, defaults in
            XCTAssertEqual(store.acceptMediaVersion(version(1), for: url), .firstObservation)
            store.setPlaybackProgress(position: 95, duration: 100, for: url)
            store.setPlaybackProgress(position: 5, duration: 100, for: url)
            XCTAssertTrue(store.playbackProgress(for: url)!.isCompleted)
            XCTAssertEqual(store.acceptMediaVersion(version(2), for: url), .changed)
            store.flushSynchronously()
            let reloaded = PlaybackPersistenceStore(userDefaults: defaults)
            XCTAssertNil(reloaded.playbackProgress(for: url))
            XCTAssertEqual(reloaded.replacedMediaHistory(for: url).count, 1)
            XCTAssertTrue(reloaded.replacedMediaHistory(for: url)[0].isCompleted)
            XCTAssertEqual(reloaded.mediaVersion(for: url), version(2))
        }
    }

    func testClearAfterPendingUpdatesDoesNotResurrectHistory() {
        withStore { store, defaults in
            store.setPlaybackProgress(position: 50, duration: 100, for: url)
            store.setMediaSettings(.init(subtitleDelay: 1), for: url)
            store.clearPlaybackHistory()
            store.flushSynchronously()
            let reloaded = PlaybackPersistenceStore(userDefaults: defaults)
            XCTAssertNil(reloaded.playbackProgress(for: url))
            XCTAssertNil(reloaded.mediaSettings(for: url))
        }
    }

    func testHistoryDisabledAndExplicitClearKeepExistingSemantics() {
        withStore { store, defaults in
            store.setPlaybackProgress(position: 10, duration: 100, for: url)
            var preferences = store.loadPreferences(); preferences.remembersPlaybackHistory = false
            store.savePreferences(preferences)
            store.setPlaybackProgress(position: 20, duration: 100, for: url)
            store.flushSynchronously()
            XCTAssertEqual(PlaybackPersistenceStore(userDefaults: defaults).playbackPosition(for: url), 10)
            store.clearPlaybackHistory()
            store.flushSynchronously()
            XCTAssertNil(PlaybackPersistenceStore(userDefaults: defaults).playbackPosition(for: url))
        }
    }

    func testUnreadableHistoryCannotBeOverwrittenWithoutExplicitReset() {
        let suite = "com.example.IlliquidUnreadableTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "Illiquid.playback-state.v1", bad = Data("{corrupt".utf8)
        defaults.set(bad, forKey: key)
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        store.setPlaybackPosition(42, for: url)
        store.setMuted(true)
        store.flushSynchronously()
        XCTAssertTrue(store.hasUnreadableHistory)
        XCTAssertEqual(defaults.data(forKey: key), bad)
        store.clearPlaybackHistory()
        store.flushSynchronously()
        XCTAssertFalse(PlaybackPersistenceStore(userDefaults: defaults).hasUnreadableHistory)
    }

    func testStoreRemainsAliveUntilItsDelayedSnapshotHasBeenWritten() {
        withStore { _, defaults in
            var owner: PlaybackPersistenceStore? = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Lifetime")
            weak var weakOwner: PlaybackPersistenceStore?
            weakOwner = owner
            owner?.setPlaybackPosition(55, for: url)
            owner = nil
            let deadline = Date().addingTimeInterval(5)
            while weakOwner != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            XCTAssertNil(weakOwner)
            XCTAssertEqual(PlaybackPersistenceStore(userDefaults: defaults, namespace: "Lifetime").playbackPosition(for: url), 55)
        }
    }
}
