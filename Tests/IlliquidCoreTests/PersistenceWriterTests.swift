import Foundation
import Testing
@testable import IlliquidCore

@Suite("Coalesced persistence")
struct PersistenceWriterTests {
    private static func wait(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }
    private final class Writes: @unchecked Sendable {
        let lock = NSLock()
        var values: [Int] = []
        func append(_ value: Int) { lock.withLock { values.append(value) } }
        var snapshot: [Int] { lock.withLock { values } }
    }

    @Test func retainsOnlyTheLatestPendingValueAndFlushesIt() async throws {
        let writes = Writes()
        let writer = CoalescingPersistenceWriter<Int>(label: "test.coalesce", delay: 60) {
            writes.append($0)
        }
        for value in 0..<1000 { writer.submit(value) }
        try await writer.flush().get()
        #expect(writes.snapshot == [999])
    }

    @Test func flushWaitsForTheActiveWriteAndPreservesOrder() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writes = Writes()
        let writer = CoalescingPersistenceWriter<Int>(label: "test.order", delay: 0) { value in
            if value == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            writes.append(value)
        }
        writer.submit(1)
        #expect(await Task.detached { Self.wait(started) }.value)
        writer.submit(2)
        writer.submit(3)
        release.signal()
        try await writer.flush().get()
        #expect(writes.snapshot == [1, 3])
    }

    @Test func reportsStorageFailureAndRecoversOnNextWrite() async throws {
        let writer = CoalescingPersistenceWriter<Int>(label: "test.error", delay: 60) { value in
            if value == 1 { throw CocoaError(.fileWriteNoPermission) }
        }
        writer.submit(1)
        if case .success = await writer.flush() { Issue.record("Failed write was acknowledged") }
        writer.submit(2)
        try await writer.flush().get()
    }

    @Test func preferenceChangesDoNotRewriteHistoryAndMigrateLegacyPreferences() async throws {
        let suite = "IlliquidWriterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try JSONSerialization.data(withJSONObject: [
            "playbackPositions": ["/tmp/video.mkv": 12],
            "preferences": ["volume": 37]
        ])
        defaults.set(legacy, forKey: "Review.playback-state.v1")
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Review")
        #expect(store.loadPreferences().volume == 37)
        store.setVolume(81)
        try await store.flush().get()
        #expect(defaults.data(forKey: "Review.playback-state.v1") == legacy)
        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Review")
        #expect(restored.loadPreferences().volume == 81)
        #expect(restored.playbackPosition(for: URL(fileURLWithPath: "/tmp/video.mkv")) == 12)
    }
}
