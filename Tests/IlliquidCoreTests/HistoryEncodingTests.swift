import Foundation
import XCTest
@testable import IlliquidCore

final class HistoryEncodingTests: XCTestCase {
    private let historyKey = "HistoryEncoding.playback-state.v1"
    private let preferencesKey = "HistoryEncoding.playback-preferences.v1"

    func testHistoryOmitsOptionalSlashEscapesButPreservesRequiredEscapes() throws {
        try withStore { store, defaults in
            let fixture = RichHistory()
            fixture.populate(store)
            store.flushSynchronously()

            let data = try XCTUnwrap(defaults.data(forKey: historyKey))
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(json.contains("/synthetic/history/"))
            XCTAssertFalse(json.contains(#"\/"#))
            for escape in [#"\""#, #"\\"#, #"\t"#, #"\n"#, #"\r"#, #"\u0001"#] {
                XCTAssertTrue(json.contains(escape), "Required JSON escape missing: \(escape)")
            }

            let reloaded = PlaybackPersistenceStore(userDefaults: defaults, namespace: "HistoryEncoding")
            fixture.assertRestored(by: reloaded)
        }
    }

    func testLegacyEscapedHistoryRewritesWithoutChangingSchemaOrValues() throws {
        try withStore { store, defaults in
            let fixture = RichHistory()
            fixture.populate(store)
            store.flushSynchronously()

            // Use the complete production payload, including replacement history,
            // rather than a second hand-maintained copy of the persisted schema.
            let currentData = try XCTUnwrap(defaults.data(forKey: historyKey))
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? NSDictionary)
            let legacyData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
            XCTAssertTrue(String(decoding: legacyData, as: UTF8.self).contains(#"\/"#))
            defaults.set(legacyData, forKey: historyKey)

            let legacyStore = PlaybackPersistenceStore(userDefaults: defaults, namespace: "HistoryEncoding")
            defer { legacyStore.flushSynchronously() }
            fixture.assertRestored(by: legacyStore)

            // Schedule a real write while restoring the exact original value.
            // The coalesced snapshot must retain every other persisted field.
            legacyStore.setLastOpenedMedia(.folder(fixture.folder))
            legacyStore.setLastOpenedMedia(.file(fixture.file))
            legacyStore.flushSynchronously()

            let rewritten = try XCTUnwrap(defaults.data(forKey: historyKey))
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? NSDictionary)
            XCTAssertEqual(actual, expected)
            XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains(#"\/"#))
            fixture.assertRestored(by: PlaybackPersistenceStore(
                userDefaults: defaults, namespace: "HistoryEncoding"
            ))
        }
    }

    func testEmptyHistoryKeepsSeparatePreferencesEncodingAndReloads() throws {
        try withStore { store, defaults in
            store.setPreferredAudioOutputDeviceID("device/output/1")
            store.setPlaybackPosition(20, for: URL(fileURLWithPath: "/synthetic/history/movie.mkv"))
            var preferences = store.loadPreferences()
            preferences.remembersPlaybackHistory = false
            store.savePreferences(preferences)
            store.clearPlaybackHistory()
            store.flushSynchronously()

            let historyData = try XCTUnwrap(defaults.data(forKey: historyKey))
            let preferencesData = try XCTUnwrap(defaults.data(forKey: preferencesKey))
            XCTAssertTrue(String(decoding: historyData, as: UTF8.self).contains("device/output/1"))
            XCTAssertTrue(String(decoding: preferencesData, as: UTF8.self).contains(#"device\/output\/1"#))
            XCTAssertEqual(try JSONDecoder().decode(PlaybackPreferences.self, from: preferencesData), preferences)

            let history = try XCTUnwrap(JSONSerialization.jsonObject(with: historyData) as? [String: Any])
            for key in ["playbackPositions", "playbackDurations", "lastWatchedFiles",
                        "mediaSettings", "mediaVersions", "replacedHistory"] {
                XCTAssertEqual(try XCTUnwrap(history[key] as? [String: Any]).count, 0, key)
            }
            XCTAssertEqual(try XCTUnwrap(history["completedFiles"] as? [String]), [])
            XCTAssertNil(history["lastOpenedMedia"])

            let reloaded = PlaybackPersistenceStore(userDefaults: defaults, namespace: "HistoryEncoding")
            XCTAssertFalse(reloaded.hasUnreadableHistory)
            XCTAssertEqual(reloaded.loadPreferences(), preferences)
            XCTAssertNil(reloaded.lastOpenedMedia())
        }
    }

    private func withStore(
        _ body: (PlaybackPersistenceStore, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "IlliquidHistoryEncodingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "HistoryEncoding")
        defer { store.flushSynchronously() }
        try body(store, defaults)
    }

    private struct RichHistory {
        let folder = URL(fileURLWithPath: "/synthetic/history/映画/café", isDirectory: true)
        var file: URL { folder.appendingPathComponent("Episode \"one\"\\mix.mkv") }
        let completed = URL(fileURLWithPath: "/synthetic/history/完了.mkv")
        let oldVersion = MediaContentVersion(
            fileIdentifier: 1, byteCount: 12_345, modificationSeconds: 100,
            modificationNanoseconds: 123, creationSeconds: 90, creationNanoseconds: 456
        )
        let newVersion = MediaContentVersion(
            fileIdentifier: 2, byteCount: 67_890, modificationSeconds: 200,
            modificationNanoseconds: 789, creationSeconds: 190, creationNanoseconds: 123
        )
        let settings = MediaPlaybackSettings(
            audioTrack: MediaTrackPreference(track: MediaTrack(
                id: 7, kind: .audio,
                title: "音声 / \"quoted\" \\ alternate\tline\nreturn\rcontrol\u{0001} end",
                languageCode: "ja", codec: "aac"
            )),
            subtitleTrack: MediaTrackPreference(track: MediaTrack(
                id: 8, kind: .subtitle, title: "字幕 / Français", languageCode: "fr", codec: "ass",
                isExternal: true, externalFilename: "/synthetic/subtitles/字幕 \"quoted\"\\alternate.ass"
            )),
            areSubtitlesVisible: false,
            subtitleDelay: 1.25
        )

        func populate(_ store: PlaybackPersistenceStore) {
            XCTAssertEqual(store.acceptMediaVersion(oldVersion, for: file), .firstObservation)
            XCTAssertTrue(store.setPlaybackProgress(position: 25.5, duration: 100, for: file))
            store.setMediaSettings(settings, for: file)
            XCTAssertEqual(store.acceptMediaVersion(newVersion, for: file), .changed)
            XCTAssertTrue(store.setPlaybackProgress(position: 30.25, duration: 120, for: file))
            store.setMediaSettings(settings, for: file)
            XCTAssertTrue(store.setPlaybackProgress(position: 95, duration: 100, for: completed))
            store.setLastWatchedFile(file, for: folder)
            XCTAssertTrue(store.setLastOpenedMedia(.file(file)))
        }

        func assertRestored(by store: PlaybackPersistenceStore, file testFile: StaticString = #filePath,
                            line: UInt = #line) {
            XCTAssertFalse(store.hasUnreadableHistory, file: testFile, line: line)
            XCTAssertEqual(store.playbackProgress(for: file),
                           MediaPlaybackProgress(position: 30.25, duration: 120, isCompleted: false),
                           file: testFile, line: line)
            XCTAssertEqual(store.playbackProgress(for: completed),
                           MediaPlaybackProgress(position: 100, duration: 100, isCompleted: true),
                           file: testFile, line: line)
            XCTAssertNil(store.playbackPosition(for: completed), file: testFile, line: line)
            XCTAssertEqual(store.mediaSettings(for: file), settings, file: testFile, line: line)
            XCTAssertEqual(store.mediaVersion(for: file), newVersion, file: testFile, line: line)
            XCTAssertEqual(store.lastWatchedFile(for: folder), file, file: testFile, line: line)
            XCTAssertEqual(store.lastOpenedMedia(), .file(file), file: testFile, line: line)
            XCTAssertEqual(store.replacedMediaHistory(for: file), [ReplacedMediaHistory(
                version: oldVersion, position: 25.5, duration: 100,
                isCompleted: false, mediaSettings: settings
            )], file: testFile, line: line)
        }
    }
}
