// Appended to PlaybackCoordinatorTests.swift by the benchmark runner so this
// probe uses the existing coordinator fixture and fake playback runtime.
import Darwin

extension PlaybackCoordinatorTests {
    @Test func restoreSessionMemoryProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["ILLIQUID_RESTORE_PROBE_OUTPUT"] else { return }
        let count = try #require(environment["ILLIQUID_RESTORE_PROBE_COUNT"].flatMap(Int.init))
        let mode = try #require(environment["ILLIQUID_RESTORE_PROBE_MODE"])
        try #require(count > 0 && count <= 100_000)
        try #require(mode == "folder" || mode == "direct")

        let fixture = try CoordinatorFixture()
        let folder = try fixture.createDirectory("media")
        let first = try fixture.createFile("episode-0.mkv", in: folder)
        // The helper frame and autorelease pool end before any sample. Neither
        // the generated playlist nor a loaded record is retained by the probe.
        let savedRecordBytes = try autoreleasepool {
            try saveRestoreProbeSession(fixture, folder: folder, first: first, count: count, mode: mode)
        }
        try await settleRestoreProbe(fixture)
        let initial = try sampleRestoreProbe(fixture.coordinator)

        try #require(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        try #require(!fixture.coordinator.isPreparingSource)
        try #require(fixture.runtime.loads.count == 1)
        try #require(fixture.runtime.loads.last?.identity.source == .localFile(first))
        try #require(try retainedPreparedRestorePlaylistCount(fixture.coordinator) == count)
        try await settleRestoreProbe(fixture)
        let prepared = try sampleRestoreProbe(fixture.coordinator)

        // No load request or reflected record crosses a measurement boundary.
        try autoreleasepool { try finishRestoreProbeLoad(fixture, expectedSource: .localFile(first), restoring: true) }
        try await waitForPreparation(fixture.coordinator)
        try await settleRestoreProbe(fixture)
        try autoreleasepool {
            try verifyRestoredProbePlaylist(fixture, folder: folder, first: first, count: count, mode: mode)
        }
        let committed = try sampleRestoreProbe(fixture.coordinator)

        if mode == "direct" {
            // Only the fake runtime sees this URL; the probe never performs a
            // network request. Replacement removes the active queue's ownership
            // of the old decoded items, exposing stale snapshot retention.
            let replacement = try #require(URL(string: "https://example.invalid/restore-lifetime-control.mkv"))
            fixture.coordinator.openRemoteStream(url: replacement)
            try await waitForPreparation(fixture.coordinator)
            try #require(fixture.runtime.loads.count == 2)
            try autoreleasepool {
                try finishRestoreProbeLoad(fixture, expectedSource: .remoteStream(replacement), restoring: false)
            }
            try await settleRestoreProbe(fixture)
            try autoreleasepool {
                try #require(fixture.coordinator.state.currentSource == .remoteStream(replacement))
                try #require(fixture.coordinator.state.currentSourceOrigin == .userSelected)
                try #require(fixture.coordinator.state.currentFolder == nil)
                try #require(fixture.coordinator.state.playlist.map(\.url) == [replacement])
                try #require(fixture.coordinator.state.playlist[0].externalSubtitleURLs.isEmpty)
                try #require(fixture.coordinator.state.currentPlaylistIndex == 0)
                try #require(fixture.coordinator.state.position == 0)
                // The replacement must not inherit the restored position.
                try #require(fixture.runtime.seeks.count == 1)
            }
        }
        // The folder case already has a newly discovered single-item playlist;
        // the direct case now owns only the replacement remote-stream item.
        try await settleRestoreProbe(fixture)
        let final = try sampleRestoreProbe(fixture.coordinator)
        try #require(final.activePlaylistCount == 1)
        try #require(final.activeSubtitleURLCount == 0)

        let report: [String: Any] = [
            "schema_version": 1,
            "mode": mode,
            "item_count": count,
            "saved_record_bytes": savedRecordBytes,
            "subtitle_urls_per_saved_item": 2,
            "restore_position": 42,
            "restored_paused": true,
            "resume_seek_count": 1,
            "final_source_kind": mode == "folder" ? "localFile" : "remoteStream",
            "final_source_origin": mode == "folder" ? "restoredSession" : "userSelected",
            "snapshots": [
                "initial": initial.json,
                "prepared": prepared.json,
                "committed": committed.json,
                "final": final.json,
            ],
            "metric": "malloc_zone_statistics(NULL).size_in_use",
            "runtime": "CoordinatorFakeBackend; no native media decoding or network I/O",
        ]
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
        // Measure while the coordinator remains usable. Its eventual teardown
        // must not hide storage retained throughout the active application.
        await fixture.coordinator.shutdown()
        try #require(fixture.coordinator.shutdownPersistenceError == nil)
    }
}

@MainActor
@inline(never)
private func saveRestoreProbeSession(
    _ fixture: CoordinatorFixture, folder: URL, first: URL, count: Int, mode: String
) throws -> Int {
    let items = (0..<count).map { index in
        FolderPlaylistItem(
            url: folder.appendingPathComponent("episode-\(index).mkv"),
            externalSubtitleURLs: [
                folder.appendingPathComponent("episode-\(index).en.ass"),
                folder.appendingPathComponent("episode-\(index).ja.ass"),
            ],
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
    try fixture.sessionStore.save(PlaybackSessionRecord(
        source: .localFile(first), collectionFolder: mode == "folder" ? folder : nil,
        playlistItems: items, playlistIndex: 0, position: 42, wasPaused: true,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let store = try #require(fixture.sessionStore as? AtomicPlaybackSessionStore)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    return try #require(attributes[.size] as? NSNumber).intValue
}

@MainActor
private func finishRestoreProbeLoad(
    _ fixture: CoordinatorFixture, expectedSource: MediaSource, restoring: Bool
) throws {
    let load = try #require(fixture.runtime.loads.last)
    try #require(load.identity.source == expectedSource)
    fixture.runtime.emit(.loaded, identity: load.identity)
    if restoring {
        try #require(fixture.runtime.seeks.last == SeekRecord(value: 42, mode: .absoluteExact))
        fixture.runtime.emit(.seekCompleted, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
    } else {
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
    }
}

@MainActor
private func verifyRestoredProbePlaylist(
    _ fixture: CoordinatorFixture, folder: URL, first: URL, count: Int, mode: String
) throws {
    try #require(fixture.coordinator.state.currentSource == .localFile(first))
    try #require(fixture.coordinator.state.currentSourceOrigin == .restoredSession)
    try #require(fixture.coordinator.state.currentFolder == (mode == "folder" ? folder : nil))
    try #require(fixture.coordinator.state.currentPlaylistIndex == 0)
    try #require(fixture.coordinator.state.isPauseDesired)
    try #require(fixture.coordinator.state.position == 42)
    try #require(fixture.runtime.seeks.count == 1)
    if mode == "folder" {
        try #require(fixture.coordinator.state.playlist.map(\.url) == [first])
        try #require(fixture.coordinator.state.playlist[0].externalSubtitleURLs.isEmpty)
    } else {
        try #require(fixture.coordinator.state.playlist.count == count)
        for (index, item) in fixture.coordinator.state.playlist.enumerated() {
            try #require(item.url == folder.appendingPathComponent("episode-\(index).mkv"))
            try #require(item.externalSubtitleURLs == [
                folder.appendingPathComponent("episode-\(index).en.ass"),
                folder.appendingPathComponent("episode-\(index).ja.ass"),
            ])
        }
    }
}

// Reflection returns only the task handle, not the coordinator's other fields.
// Awaiting it waits for both real persistence writers and the coordinator's
// debounce task to finish. The helper frame then releases the handle before
// any allocator sample; no benchmark-only production accessors are required.
@MainActor
private func restoreProbeCheckpointTask(_ coordinator: PlaybackCoordinator) throws -> Task<Void, Never>? {
    let field = try #require(Mirror(reflecting: coordinator).children.first { $0.label == "checkpointFlushTask" })
    let optional = Mirror(reflecting: field.value)
    try #require(optional.displayStyle == .optional)
    guard let value = optional.children.first else { return nil }
    return try #require(value.value as? Task<Void, Never>)
}

@MainActor
private func settleRestoreProbe(_ fixture: CoordinatorFixture) async throws {
    // There should be one task. Bound retries so an unexpected rescheduling
    // loop fails the experiment instead of silently sampling unsettled state.
    for _ in 0..<8 {
        if let task = try restoreProbeCheckpointTask(fixture.coordinator) { await task.value }
        try await fixture.persistence.flush().get()
        for _ in 0..<8 { await Task.yield() }
        if try restoreProbeCheckpointTask(fixture.coordinator) == nil {
            try #require(!fixture.coordinator.isPreparingSource)
            try #require(fixture.coordinator.state.shellError == nil)
            return
        }
    }
    try #require(try restoreProbeCheckpointTask(fixture.coordinator) == nil)
}

private struct RestoreProbeSample {
    let liveMallocBytes: UInt64
    let liveMallocBlocks: UInt64
    let retainedPlaylistCount: Int?
    let activePlaylistCount: Int
    let activeSubtitleURLCount: Int

    var json: [String: Any] {
        [
            "live_malloc_bytes": liveMallocBytes,
            "live_malloc_blocks": liveMallocBlocks,
            "retained_playlist_count": retainedPlaylistCount.map { $0 as Any } ?? NSNull(),
            "active_playlist_count": activePlaylistCount,
            "active_subtitle_url_count": activeSubtitleURLCount,
        ]
    }
}

@MainActor
private func sampleRestoreProbe(_ coordinator: PlaybackCoordinator) throws -> RestoreProbeSample {
    // Drain reflection and Observation temporaries before reading allocator
    // statistics. Only integer counts cross this autorelease-pool boundary.
    let counts = try autoreleasepool {
        (
            try retainedPreparedRestorePlaylistCount(coordinator),
            coordinator.state.playlist.count,
            coordinator.state.playlist.reduce(0) { $0 + $1.externalSubtitleURLs.count }
        )
    }
    return autoreleasepool {
        var statistics = malloc_statistics_t()
        // Apple's API sums all zones when passed NULL. This reports allocator
        // live bytes and blocks for the process, not resident or peak memory.
        malloc_zone_statistics(nil, &statistics)
        return RestoreProbeSample(
            liveMallocBytes: UInt64(statistics.size_in_use),
            liveMallocBlocks: UInt64(statistics.blocks_in_use),
            retainedPlaylistCount: counts.0,
            activePlaylistCount: counts.1,
            activeSubtitleURLCount: counts.2
        )
    }
}
