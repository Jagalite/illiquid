import Foundation
import XCTest
@testable import IlliquidCore

private final class CountingHistoryDefaults: UserDefaults {
    private let counterLock = NSLock()
    private var counts: [String: Int] = [:]
    private var blockNext = false
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func blockNextHistory() { counterLock.lock(); blockNext = true; counterLock.unlock() }
    override func set(_ value: Any?, forKey key: String) {
        counterLock.lock()
        let blocked = blockNext && key.hasSuffix("playback-state.v1")
        if blocked { blockNext = false }
        counterLock.unlock()
        if blocked {
            started.signal()
            precondition(release.wait(timeout: .now() + 10) == .success)
        }
        super.set(value, forKey: key)
        counterLock.lock(); counts[key, default: 0] += 1; counterLock.unlock()
    }
    func count(_ key: String) -> Int {
        counterLock.lock(); defer { counterLock.unlock() }; return counts[key, default: 0]
    }
}

final class IdempotentPersistenceTests: XCTestCase {
    private let history = "Illiquid.playback-state.v1"
    private let preferences = "Illiquid.playback-preferences.v1"
    private let url = URL(fileURLWithPath: "/synthetic/movie.mkv")
    private let folder = URL(fileURLWithPath: "/synthetic", isDirectory: true)
    private func withStore(_ body: (PlaybackPersistenceStore, CountingHistoryDefaults) throws -> Void) rethrows {
        let suite = "com.example.IlliquidIdempotenceTests.\(UUID().uuidString)"
        let defaults = CountingHistoryDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        try body(store, defaults)
        store.flushSynchronously()
    }
    private func version(_ id: UInt64 = 1) -> MediaContentVersion {
        .init(fileIdentifier: id, byteCount: 100, modificationSeconds: 1,
              modificationNanoseconds: 2, creationSeconds: 3, creationNanoseconds: 4)
    }
    func testRepeatedProgressDoesNotWriteButNewProgressDoes() {
        withStore { store, defaults in
            XCTAssertTrue(store.setPlaybackProgress(position: 10, duration: 100, for: url))
            store.flushSynchronously(); let before = defaults.count(history)
            for _ in 0..<100 { XCTAssertTrue(store.setPlaybackProgress(position: 10, duration: 100, for: url)) }
            store.flushSynchronously(); XCTAssertEqual(defaults.count(history), before)
            store.setPlaybackProgress(position: 11, duration: 100, for: url)
            store.flushSynchronously(); XCTAssertEqual(defaults.count(history), before + 1)
            XCTAssertEqual(PlaybackPersistenceStore(userDefaults: defaults).playbackPosition(for: url), 11)
        }
    }
    func testRepeatedPositionAndMissingRemovalAreNoOps() {
        withStore { store, defaults in
            store.removePlaybackPosition(for: url)
            store.flushSynchronously(); XCTAssertEqual(defaults.count(history), 0)
            store.setPlaybackPosition(0, for: url)
            store.flushSynchronously(); XCTAssertEqual(defaults.count(history), 1)
            XCTAssertEqual(store.playbackPosition(for: url), 0) // absent != explicit zero
            store.setPlaybackPosition(0, for: url)
            store.flushSynchronously(); XCTAssertEqual(defaults.count(history), 1)
            store.removePlaybackPosition(for: url); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), 2)
            store.removePlaybackPosition(for: url); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), 2)
        }
    }
    func testCompletionThresholdAndStickyRewatchArePreserved() {
        withStore { store, defaults in
            store.setPlaybackProgress(position: 90, duration: 100, for: url)
            XCTAssertEqual(store.playbackProgress(for: url)?.isCompleted, false)
            store.setPlaybackProgress(position: 90.01, duration: 100, for: url)
            XCTAssertEqual(store.playbackProgress(for: url)?.isCompleted, true)
            XCTAssertNil(store.playbackPosition(for: url))
            store.flushSynchronously(); let before = defaults.count(history)
            store.setPlaybackProgress(position: 95, duration: 100, for: url)
            store.markPlaybackCompleted(for: url); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), before)
            store.setPlaybackProgress(position: 5, duration: 100, for: url)
            XCTAssertEqual(store.playbackPosition(for: url), 5)
            XCTAssertEqual(store.playbackProgress(for: url)?.isCompleted, true)
            store.markPlaybackCompleted(for: url); XCTAssertNil(store.playbackPosition(for: url))
        }
    }
    func testChangingDurationIsNotSkippedAndRechecksCompletion() {
        withStore { store, defaults in
            store.setPlaybackProgress(position: 50, duration: 100, for: url); store.flushSynchronously()
            let before = defaults.count(history)
            store.setPlaybackProgress(position: 50, duration: 200, for: url); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), before + 1)
            XCTAssertEqual(store.playbackProgress(for: url)?.duration, 200)
            store.setPlaybackProgress(position: 50, duration: 51, for: url)
            XCTAssertEqual(store.playbackProgress(for: url)?.isCompleted, true)
        }
    }
    func testSettingsVersionAndRestoreTargetNoOps() {
        withStore { store, defaults in
            let settings = MediaPlaybackSettings(subtitleDelay: 2)
            store.setMediaSettings(settings, for: url)
            XCTAssertEqual(store.acceptMediaVersion(version(), for: url), .firstObservation)
            store.setLastWatchedFile(url, for: folder)
            store.setLastOpenedMedia(.file(url)); store.flushSynchronously()
            let before = defaults.count(history)
            store.setMediaSettings(settings, for: url)
            XCTAssertEqual(store.acceptMediaVersion(version(), for: url), .unchanged)
            store.setLastWatchedFile(url, for: folder)
            store.setLastOpenedMedia(.file(url)); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), before)
            store.setLastOpenedMedia(.folder(url)); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), before + 1) // kind still matters
            XCTAssertEqual(store.acceptMediaVersion(version(2), for: url), .changed)
            XCTAssertEqual(store.replacedMediaHistory(for: url).first?.mediaSettings, settings)
            XCTAssertNil(store.mediaSettings(for: url))
        }
    }
    func testNilSettingsAndTargetsNoOpsButRealDeletionPersists() {
        withStore { store, defaults in
            store.setMediaSettings(nil, for: url)
            store.setLastWatchedFile(nil, for: folder)
            store.setLastOpenedMedia(nil); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), 0)
            store.setMediaSettings(.init(), for: url)
            store.setLastWatchedFile(url, for: folder)
            store.setLastOpenedMedia(.file(url)); store.flushSynchronously()
            let before = defaults.count(history)
            store.setMediaSettings(nil, for: url)
            store.setLastWatchedFile(nil, for: folder)
            store.setLastOpenedMedia(nil); store.flushSynchronously()
            XCTAssertGreaterThan(defaults.count(history), before)
            let loaded = PlaybackPersistenceStore(userDefaults: defaults)
            XCTAssertNil(loaded.mediaSettings(for: url)); XCTAssertNil(loaded.lastOpenedMedia())
            XCTAssertNil(loaded.lastWatchedFile(for: folder))
        }
    }
    func testNoOpDuringInFlightWriteDoesNotCreateSecondWrite() {
        withStore { store, defaults in
            defaults.blockNextHistory()
            store.setPlaybackProgress(position: 10, duration: 100, for: url)
            XCTAssertEqual(defaults.started.wait(timeout: .now() + 5), .success)
            for _ in 0..<100 { store.setPlaybackProgress(position: 10, duration: 100, for: url) }
            defaults.release.signal(); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), 1)
        }
    }
    func testChangeDuringInFlightWriteIsSaved() {
        withStore { store, defaults in
            defaults.blockNextHistory()
            store.setPlaybackProgress(position: 10, duration: 100, for: url)
            XCTAssertEqual(defaults.started.wait(timeout: .now() + 5), .success)
            store.setPlaybackProgress(position: 11, duration: 100, for: url)
            store.setPlaybackProgress(position: 11, duration: 100, for: url)
            defaults.release.signal(); store.flushSynchronously()
            XCTAssertEqual(defaults.count(history), 2)
            XCTAssertEqual(PlaybackPersistenceStore(userDefaults: defaults).playbackPosition(for: url), 11)
        }
    }
    func testConcurrentDistinctChangesAndDuplicatesSurviveReload() {
        withStore { store, defaults in
            DispatchQueue.concurrentPerform(iterations: 128) { i in
                let file = URL(fileURLWithPath: "/synthetic/concurrent-\(i).mkv")
                for _ in 0..<8 { store.setPlaybackProgress(position: Double(i), duration: 1000, for: file) }
            }
            store.flushSynchronously()
            let restored = PlaybackPersistenceStore(userDefaults: defaults)
            for i in 0..<128 {
                XCTAssertEqual(restored.playbackPosition(for: URL(fileURLWithPath: "/synthetic/concurrent-\(i).mkv")), Double(i))
            }
        }
    }
    func testVolumeAndSpeedPreserveHistoryOptOutAndRestorePreference() {
        withStore { store, defaults in
            var pref = store.loadPreferences()
            pref.remembersPlaybackHistory = false; pref.restoresSessionPaused = false
            pref.trackSelection = .init(audioLanguages: ["ja"], subtitleLanguages: ["en"], subtitles: .always)
            store.savePreferences(pref)
            store.setVolume(12); store.setPlaybackSpeed(1.5)
            store.setPlaybackProgress(position: 15, duration: 100, for: url)
            store.flushSynchronously()
            let loaded = PlaybackPersistenceStore(userDefaults: defaults)
            XCTAssertFalse(loaded.loadPreferences().remembersPlaybackHistory)
            XCTAssertFalse(loaded.loadPreferences().restoresSessionPaused)
            XCTAssertEqual(loaded.loadPreferences().trackSelection, pref.trackSelection)
            XCTAssertNil(loaded.playbackProgress(for: url))
            XCTAssertEqual(defaults.count(history), 0)
        }
    }
    func testPreferenceNoOpsAndSanitization() {
        withStore { store, defaults in
            store.setVolume(-1); store.setPlaybackSpeed(8); store.flushSynchronously()
            XCTAssertEqual(store.loadPreferences().volume, 0)
            XCTAssertEqual(store.loadPreferences().playbackSpeed, 4)
            let before = defaults.count(preferences)
            store.setVolume(-10); store.setPlaybackSpeed(9)
            store.savePreferences(store.loadPreferences()); store.flushSynchronously()
            XCTAssertEqual(defaults.count(preferences), before)
            store.setVolume(.nan); store.setPlaybackSpeed(.infinity)
            XCTAssertEqual(store.loadPreferences().volume, 100)
            XCTAssertEqual(store.loadPreferences().playbackSpeed, 1)
        }
    }
    func testInvalidInputDoesNotWrite() {
        withStore { store, defaults in
            XCTAssertFalse(store.setPlaybackPosition(.nan, for: url))
            XCTAssertFalse(store.setPlaybackPosition(-1, for: url))
            XCTAssertFalse(store.setPlaybackProgress(position: 0, duration: 0, for: url))
            XCTAssertFalse(store.setPlaybackProgress(position: 0, duration: .infinity, for: url))
            XCTAssertFalse(store.setPlaybackPosition(10, for: URL(string: "https://example.invalid/movie")!))
            store.flushSynchronously(); XCTAssertEqual(defaults.count(history), 0)
        }
    }
    func testUnreadableHistoryStillRequiresExplicitClear() {
        withStore { _, defaults in
            let corrupt = Data("not json".utf8)
            defaults.set(corrupt, forKey: history)
            let store = PlaybackPersistenceStore(userDefaults: defaults)
            store.setPlaybackPosition(1, for: url); store.flushSynchronously()
            XCTAssertEqual(defaults.data(forKey: history), corrupt)
            store.clearPlaybackHistory(); store.flushSynchronously()
            XCTAssertFalse(store.hasUnreadableHistory)
            XCTAssertNotEqual(defaults.data(forKey: history), corrupt)
        }
    }
    func testEncodingFailureIsNotHiddenAndValidMutationRecovers() async {
        let suite = "com.example.IlliquidIdempotenceFailure.\(UUID().uuidString)"
        let defaults = CountingHistoryDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        var settings = MediaPlaybackSettings(); settings.subtitleDelay = .infinity
        store.setMediaSettings(settings, for: url)
        if case .success = await store.flush() { XCTFail("invalid JSON must fail") }
        // Same Infinity compares equal: failure retry must not be treated as a
        // successful no-op. The callback still fails and remains reportable.
        store.setMediaSettings(settings, for: url)
        if case .success = await store.flush() { XCTFail("retry must report failure") }
        store.setMediaSettings(.init(subtitleDelay: 1), for: url)
        if case .failure = await store.flush() { XCTFail("corrected value must recover") }
        XCTAssertEqual(PlaybackPersistenceStore(userDefaults: defaults).mediaSettings(for: url)?.subtitleDelay, 1)
    }
}
