
// MARK: - Settled recovery, sparse overrides and caption navigation

extension PlaybackCoordinator {
    private var hasSettledPlaybackPosition: Bool {
        guard hasLoadedCurrentSource, hasCurrentPlaybackAuthority,
              let snapshot = runtimeDriver?.currentSnapshot else { return false }
        switch snapshot.phase {
        case .playing, .paused, .ready, .buffering, .draining, .ended:
            return state.position.isFinite && state.position >= 0
        default: return false
        }
    }

    private var canCheckpointCurrentPosition: Bool {
        hasSettledPlaybackPosition && automationCheckpointOwner == nil && !hasUnsettledNativeReplacement
            && pendingPositionRestore == nil
            && pendingMediaSettingFields.isEmpty && pendingExternalInstallURL == nil
            && pendingRestoredAudioDelay == nil
            && runtimeDriver?.hasPendingTrackSelection != true
    }

    private func flushSettledCheckpoint() {
        if historyCheckpointWhenSettled { saveCurrentProgress() }
        else { checkpointSession() }
    }

    private func observeSettledProductState(_ snapshot: PlaybackUISnapshot) {
        observeAcknowledgedExternalSubtitle()
        if hasSettledPlaybackPosition, pendingPositionRestore == nil {
            if lastSettledSession?.source == state.currentSource {
                lastSettledSession?.position = state.position
                lastSettledSession?.wasPaused = state.isPauseDesired
            } else if let source = state.currentSource, !source.isRemote {
                lastSettledSession = PlaybackSessionRecord(source: source,
                    collectionFolder: state.currentFolder, playlistItems: state.playlist,
                    playlistIndex: state.currentPlaylistIndex, position: state.position,
                    wasPaused: state.isPauseDesired)
            }
        }
        if snapshot.phase == .failed, failedSourceTransaction == nil,
           interruptedRecoverySession == nil, var saved = lastSettledSession {
            // The failed runtime may reset its projection. Recover from the last
            // accepted clock, not its failure/seek placeholder. Queue edits are
            // copied once here, not deduplicated on every high-frequency tick.
            saved.playlistItems = state.playlist
            saved.playlistIndex = state.currentPlaylistIndex
            saved.collectionFolder = state.currentFolder
            interruptedRecoverySession = saved
            state.setRecoveryIssue(PlaybackRecoveryIssue(kind: .interruptedSource,
                message: "Playback was interrupted. Check the file and its drive, then retry or locate the file. Your last settled position is retained.",
                source: saved.source.url, diagnosticCode: snapshot.failureCode))
        }
        if checkpointWhenSettled, canCheckpointCurrentPosition { flushSettledCheckpoint() }
        scheduleMediaRestoreDrain()
    }

    private func scheduleMediaRestoreDrain() {
        guard restoreDrainTask == nil, !isDrainingMediaRestore, !isShuttingDown,
              !pendingMediaSettingFields.isEmpty || pendingPositionRestore != nil
                || pendingExternalInstallURL != nil || pendingRestoredAudioDelay != nil
                || pendingExternalSubtitleRestore != nil else { return }
        let generation = playbackGeneration
        restoreDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            restoreDrainTask = nil
            guard !Task.isCancelled, generation == playbackGeneration, !isShuttingDown else { return }
            drainMediaRestore()
        }
    }

    /// The core accepts a single track transaction at a time. Keep the product's
    /// remaining explicit fields until acknowledgement, and restore position
    /// last so a track replacement cannot retire an in-flight resume seek.
    private func drainMediaRestore() {
        guard !isDrainingMediaRestore, !isShuttingDown, hasLoadedCurrentSource,
              hasCurrentPlaybackAuthority, pendingSourceTransaction == nil,
              runtimeDriver?.currentSnapshot.phase != .seeking,
              runtimeDriver?.currentSnapshot.phase != .failed else { return }
        isDrainingMediaRestore = true
        defer { isDrainingMediaRestore = false }
        applyPendingMediaSettings()
        guard runtimeDriver?.hasPendingTrackSelection != true,
              pendingMediaSettingFields.isEmpty else { return }
        if let url = pendingExternalInstallURL {
            pendingExternalInstallURL = nil
            if runtimeDriver?.selectExternalSubtitle(url) != true {
                pendingExternalPreferenceURL = nil
            }
        }
        guard runtimeDriver?.hasPendingTrackSelection != true else { return }
        applyPendingExternalSubtitleRestore()
        guard runtimeDriver?.hasPendingTrackSelection != true else { return }
        if let restore = pendingPositionRestore {
            pendingPositionRestore = nil
            guard state.currentSource?.representsSameResource(as: restore.source) == true else { return }
            if restore.wasPaused { _ = runtimeDriver?.pause() }
            if restore.position > 1 || restore.positionIsExplicit {
                checkpointWhenSettled = true
                historyCheckpointWhenSettled = true
                _ = runtimeDriver?.seek(to: restore.position, mode: .exact)
            }
        }
        applyDeferredMediaAudioDelay()
        if checkpointWhenSettled, canCheckpointCurrentPosition { flushSettledCheckpoint() }
    }

    private func updatePendingRestoreTransport(paused: Bool) {
        func updated(_ value: PendingPlaybackRestore?) -> PendingPlaybackRestore? {
            value.map { PendingPlaybackRestore(source: $0.source, position: $0.position,
                wasPaused: paused, playlistIndex: $0.playlistIndex, positionIsExplicit: $0.positionIsExplicit) }
        }
        pendingPositionRestore = updated(pendingPositionRestore)
        pendingPlaybackRestore = updated(pendingPlaybackRestore)
    }

    public var defaultPlaybackSpeed: Double { persistence.loadPreferences().playbackSpeed }
    public var mediaSettingsForCurrentFile: MediaPlaybackSettings { currentMediaSettings }
    public var canEditCurrentMediaSettings: Bool {
        hasLoadedCurrentSource && state.currentURL?.isFileURL == true && hasCurrentPlaybackAuthority
    }

    public func setDefaultPlaybackSpeed(_ speed: Double) {
        guard speed.isFinite, supports(.changePlaybackSpeed) else { return }
        persistence.setPlaybackSpeed(speed)
        if !currentMediaSettings.overrides(.playbackSpeed) { applyCurrentMediaSpeed() }
    }

    private func applyCurrentMediaSpeed() {
        guard supports(.changePlaybackSpeed) else { return }
        let speed = currentMediaSettings.effectivePlaybackSpeed(default: defaultPlaybackSpeed)
        state.setPlaybackSpeed(speed)
        _ = runtimeDriver?.setPlaybackSpeed(speed)
        backend?.setPlaybackSpeed(speed)
    }

    private func applyDeferredMediaAudioDelay() {
        guard hasSettledPlaybackPosition, !hasUnsettledNativeReplacement, pendingPositionRestore == nil,
              pendingMediaSettingFields.isEmpty, pendingExternalInstallURL == nil,
              runtimeDriver?.hasPendingTrackSelection != true,
              let delay = pendingRestoredAudioDelay else { return }
        pendingRestoredAudioDelay = nil
        guard supports(.changeAudioDelay), !state.audioTracks.isEmpty else { return }
        backend?.setAudioDelay(delay)
    }

    private func preferredMediaTrack(language: String?, kind: MediaTrackKind) -> MediaTrack? {
        guard let language = TrackSelectionPreferences.normalizedLanguage(language) else { return nil }
        let tracks = (kind == .audio ? state.audioTracks : state.subtitleTracks).filter {
            TrackSelectionPreferences.normalizedLanguage($0.languageCode) == language
        }
        return tracks.first(where: \.isDefault) ?? tracks.min { $0.id < $1.id }
    }

    public func setMediaLanguage(_ language: String?, kind: MediaTrackKind) {
        guard canEditCurrentMediaSettings else { return }
        guard let normalized = TrackSelectionPreferences.normalizedLanguage(language) else {
            resetCurrentMediaSetting(kind == .audio ? .audio : .subtitles)
            return
        }
        let field: MediaPlaybackSetting = kind == .audio ? .audio : .subtitles
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(field)
            if kind == .audio { settings.audioLanguage = normalized; settings.audioTrack = nil }
            else {
                settings.subtitleLanguage = normalized; settings.subtitleTrack = nil
                settings.externalSubtitleURL = nil; settings.areSubtitlesVisible = true
            }
        }
        if kind == .subtitle {
            pendingExternalSubtitleRestore = nil
            pendingExternalInstallURL = nil
            pendingExternalPreferenceURL = nil
        }
        pendingMediaSettingFields.insert(field)
        drainMediaRestore()
    }

    public func resetCurrentMediaSetting(_ field: MediaPlaybackSetting) {
        guard canEditCurrentMediaSettings else { return }
        updateCurrentMediaSettings { $0.inherit(field) }
        switch field {
        case .playbackSpeed: applyCurrentMediaSpeed()
        case .audioDelay:
            pendingRestoredAudioDelay = 0
            applyDeferredMediaAudioDelay()
        case .audio, .subtitles, .subtitleDelay:
            if field == .subtitles {
                pendingExternalSubtitleRestore = nil
                pendingExternalInstallURL = nil
                pendingExternalPreferenceURL = nil
            }
            pendingMediaSettingFields.insert(field)
            drainMediaRestore()
        }
    }

    public func resetCurrentMediaSettings() {
        guard canEditCurrentMediaSettings else { return }
        updateCurrentMediaSettings { $0 = MediaPlaybackSettings() }
        pendingExternalSubtitleRestore = nil
        pendingExternalInstallURL = nil
        pendingExternalPreferenceURL = nil
        pendingMediaSettingFields = [.audio, .subtitles, .subtitleDelay]
        pendingRestoredAudioDelay = 0
        applyCurrentMediaSpeed()
        drainMediaRestore()
    }

    private func observeAcknowledgedExternalSubtitle() {
        guard let url = runtimeDriver?.acknowledgedExternalSubtitleURL else { return }
        installedExternalSubtitleURL = url
        guard pendingExternalPreferenceURL == url else { return }
        pendingExternalPreferenceURL = nil
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(.subtitles)
            settings.areSubtitlesVisible = true
            settings.externalSubtitleURL = url
            settings.subtitleLanguage = nil
            settings.subtitleTrack = nil
        }
    }

    /// An immutable source/track token. UI tasks compare it again before using an
    /// index or issuing a jump; identical names in another session are not enough.
    public var captionSourceRequest: CaptionSourceRequest? {
        guard hasLoadedCurrentSource, state.currentURL?.isFileURL == true,
              runtimeDriver?.hasPendingTrackSelection != true, pendingExternalInstallURL == nil,
              let url = state.currentURL, let track = state.selectedSubtitleTrack else { return nil }
        let externalURL = track.isExternal ? installedExternalSubtitleURL : nil
        return CaptionSourceRequest(mediaURL: url, subtitleTrack: track,
            externalURL: externalURL, fallbackEncoding: state.subtitleFallbackEncoding,
            sourceRevision: captionRevision, mediaVersion: currentContentVersion)
    }

    public func readCaptions(for request: CaptionSourceRequest) async throws -> CaptionIndex {
        guard captionSourceRequest == request else { throw PlaybackAutomationError.superseded }
        let index: CaptionIndex
        if request.subtitleTrack.isExternal, let native = backend as? NativePlaybackRuntime {
            guard let document = native.externalCaptionDocument, document.url == request.externalURL else {
                if ["idx", "dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle"].contains(request.subtitleTrack.codec ?? "") {
                    throw CaptionReadError.textTrackRequired
                }
                throw CaptionReadError.trackUnavailable
            }
            index = try await NativeCaptionReader.read(document)
        } else {
            index = try await NativeCaptionReader.read(request)
        }
        try Task.checkCancellation()
        guard captionSourceRequest == request else { throw PlaybackAutomationError.superseded }
        return index
    }

    @discardableResult
    public func jumpToCaption(_ cueID: Int, in index: CaptionIndex, source: CaptionSourceRequest) -> Bool {
        guard captionSourceRequest == source,
              let target = index.target(for: cueID, subtitleDelay: state.subtitleDelay, duration: state.duration) else { return false }
        seek(to: target)
        return true
    }

    @discardableResult
    public func replayPreviousCaption(in index: CaptionIndex, source: CaptionSourceRequest, sentence: Bool) -> Bool {
        guard captionSourceRequest == source,
              let cue = sentence ? index.previousSentence(at: state.position, subtitleDelay: state.subtitleDelay)
                : index.previousCue(at: state.position, subtitleDelay: state.subtitleDelay) else { return false }
        guard jumpToCaption(cue.id, in: index, source: source) else { return false }
        play()
        return true
    }
}

// MARK: - Acknowledged, ordered native automation

extension PlaybackCoordinator {
    private struct PreparedAutomationFile: Sendable {
        let item: FolderPlaylistItem
        let version: MediaContentVersion
    }

    /// Completes after the requested source and exact seek are acknowledged by
    /// the playback core. This is not a claim that a physical display was read.
    public func openMedia(at url: URL, position: Double, paused: Bool = false) async throws -> PlaybackReference {
        try PlaybackAutomationPolicy.validateTimestamp(position)
        let urls = try PlaybackAutomationPolicy.orderedLocalURLs([url])
        return try await automationQueue.perform { [weak self] in
            guard let self else { throw PlaybackAutomationError.noPlayback }
            return try await performAutomationOpen(urls: urls, position: position, paused: paused, expectedVersion: nil)
        }
    }

    public func openPlaybackReference(_ reference: PlaybackReference, paused: Bool = false) async throws -> PlaybackReference {
        let urls = try PlaybackAutomationPolicy.orderedLocalURLs([reference.url])
        return try await automationQueue.perform { [weak self] in
            guard let self else { throw PlaybackAutomationError.noPlayback }
            return try await performAutomationOpen(urls: urls, position: reference.position,
                paused: paused, expectedVersion: reference.contentVersion)
        }
    }

    /// Retains caller order, deduplicates by canonical local identity and does
    /// not sort by date added. If no source is loaded, the first item is opened
    /// paused so the queue has a valid, recoverable session; otherwise playback
    /// is untouched. All paths are checked before any queue mutation.
    @discardableResult
    public func enqueueOrderedMedia(_ urls: [URL]) async throws -> [URL] {
        let urls = try PlaybackAutomationPolicy.orderedLocalURLs(urls)
        return try await automationQueue.perform { [weak self] in
            guard let self, !isShuttingDown, pendingSourceTransaction == nil, !isPreparingSource else {
                throw PlaybackAutomationError.busy
            }
            let operation = UUID()
            activeAutomationID = operation
            defer { finishAutomationOwnership(operation) }
            let prepared = try await prepareAutomationFiles(urls)
            try requireAutomationOwnership(operation)
            let existing = Set(state.playlist.map(\.id))
            let additions = prepared.filter { !existing.contains($0.item.id) }
            guard !additions.isEmpty else { return [] }
            let items = PlaylistMutation.deduplicated(state.playlist + additions.map(\.item))
            finishShuffleForExplicitOrder()
            if state.currentSource == nil {
                // There may already be an idle queue; opening its first newly
                // requested file is explicit and does not reorder that queue.
                let first = additions[0]
                let index = items.firstIndex(where: { $0.id == first.item.id }) ?? 0
                pendingPlaybackRestore = PendingPlaybackRestore(source: .localFile(first.item.url),
                    position: 0, wasPaused: true, playlistIndex: index, positionIsExplicit: true)
                guard beginSourceTransaction(item: first.item, playlist: items, folder: nil,
                    playlistIndex: index, origin: .userSelected, restoreTarget: .file(first.item.url),
                    automationID: operation) else { throw PlaybackAutomationError.failed("The player rejected the queued source.") }
                do {
                    _ = try await awaitAutomationOpen(first, operation: operation, position: 0, paused: true)
                } catch {
                    if activeAutomationID == operation { stop() }
                    throw error
                }
            } else {
                finishShuffleForExplicitOrder()
                discardFailedTraversalForPlaylistChange()
                state.configurePlaylist(folder: nil, items: items,
                    selectedIndex: PlaylistMutation.indexPreservingCurrentIdentity(currentURL: state.currentURL,
                        fallbackIndex: state.currentPlaylistIndex, in: items))
                checkpointSession()
            }
            return additions.map { $0.item.url }
        }
    }

    private var hasUnsettledNativeReplacement: Bool {
        (backend as? NativePlaybackRuntime)?.hasPendingMediaReplacement == true
    }

    public func currentPlaybackReference() throws -> PlaybackReference {
        guard automationCheckpointOwner == nil else { throw PlaybackAutomationError.noPlayback }
        return try makeSettledPlaybackReference()
    }

    private func makeSettledPlaybackReference() throws -> PlaybackReference {
        guard hasSettledPlaybackPosition, !hasUnsettledNativeReplacement, pendingPositionRestore == nil,
              pendingMediaSettingFields.isEmpty, pendingExternalInstallURL == nil,
              pendingRestoredAudioDelay == nil,
              runtimeDriver?.hasPendingTrackSelection != true,
              let url = state.currentURL, url.isFileURL, let version = currentContentVersion else {
            throw PlaybackAutomationError.noPlayback
        }
        return try PlaybackReference(url: url, position: state.position, contentVersion: version)
    }

    private func performAutomationOpen(urls: [URL], position: Double, paused: Bool,
                                       expectedVersion: MediaContentVersion?) async throws -> PlaybackReference {
        guard !isShuttingDown else { throw PlaybackAutomationError.noPlayback }
        cancelFolderScans()
        let operation = UUID()
        activeAutomationID = operation
        var started = false
        defer { finishAutomationOwnership(operation) }
        do {
            let prepared = try await prepareAutomationFiles(urls)
            try requireAutomationOwnership(operation)
            guard let first = prepared.first else { throw PlaybackAutomationError.invalidFile }
            if let expectedVersion, first.version != expectedVersion { throw PlaybackAutomationError.changedFile }
            pendingPlaybackRestore = PendingPlaybackRestore(source: .localFile(first.item.url),
                position: position, wasPaused: paused, playlistIndex: 0, positionIsExplicit: true)
            pendingLocatedHistorySource = nil
            started = beginSourceTransaction(item: first.item, playlist: prepared.map(\.item), folder: nil,
                playlistIndex: 0, origin: .userSelected, restoreTarget: .file(first.item.url), automationID: operation)
            guard started else { throw PlaybackAutomationError.failed("The player rejected the open request.") }
            return try await awaitAutomationOpen(first, operation: operation, position: position, paused: paused)
        } catch {
            // Never stop a newer UI/automation session. While this action still
            // owns the load its candidate checkpoint is suppressed, including
            // the save performed by Stop on timeout/cancellation/failure.
            if started, activeAutomationID == operation { stop() }
            throw error
        }
    }

    private func prepareAutomationFiles(_ urls: [URL]) async throws -> [PreparedAutomationFile] {
        try await sourcePreparation.perform { check in
            var result: [PreparedAutomationFile] = []
            var seen = Set<String>()
            for url in urls {
                try check()
                guard let resolved = NormalizedFileURL.resolveFilesystemIdentity(url),
                      MediaFileSupport.isSupportedMediaFile(resolved),
                      let version = NativeMediaInspection.contentVersion(of: resolved),
                      let key = NormalizedFileURL.persistenceKey(for: resolved) else {
                    throw PlaybackAutomationError.invalidFile
                }
                try check()
                if seen.insert(key).inserted {
                    result.append(PreparedAutomationFile(item: FolderPlaylistItem(url: resolved), version: version))
                }
            }
            return result
        }
    }

    private func requireAutomationOwnership(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard !isShuttingDown, activeAutomationID == operation else { throw PlaybackAutomationError.superseded }
    }

    private func awaitAutomationOpen(_ file: PreparedAutomationFile, operation: UUID,
                                     position: Double, paused: Bool) async throws -> PlaybackReference {
        let deadline = ProcessInfo.processInfo.systemUptime + automationTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireAutomationOwnership(operation)
            if let failed = failedSourceTransaction, failed.identity.generation == playbackGeneration {
                throw PlaybackAutomationError.failed(state.recoveryIssue?.message ?? "The source could not be opened.")
            }
            let snapshot = runtimeDriver?.currentSnapshot
            if snapshot?.phase == .failed {
                throw PlaybackAutomationError.failed(state.recoveryIssue?.message ?? "Playback could not be prepared.")
            }
            if hasLoadedCurrentSource, state.currentURL == file.item.url {
                guard currentContentVersion == file.version else { throw PlaybackAutomationError.changedFile }
                if state.duration > 0, position > state.duration { throw PlaybackAutomationError.invalidTimestamp }
                let transportMatches = paused ? snapshot?.actualTransport == .paused : snapshot?.actualTransport == .playing
                let phaseMatches = paused ? snapshot?.phase == .paused : snapshot?.phase == .playing
                if transportMatches, phaseMatches, state.isPauseDesired == paused, !hasUnsettledNativeReplacement,
                   pendingPositionRestore == nil, pendingMediaSettingFields.isEmpty,
                   pendingExternalInstallURL == nil, pendingRestoredAudioDelay == nil,
                   runtimeDriver?.hasPendingTrackSelection != true {
                    if !state.audioTracks.isEmpty,
                       abs(state.audioDelay - currentMediaSettings.effectiveAudioDelay) > 0.000_1 {
                        throw PlaybackAutomationError.failed("The saved audio delay could not be applied. Open the file directly to review its preferences.")
                    }
                    let reference = try makeSettledPlaybackReference()
                    // Only an acknowledged, validated action may replace the
                    // previous crash checkpoint, including explicit timestamp 0.
                    automationCheckpointOwner = nil
                    saveCurrentProgress()
                    return reference
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PlaybackAutomationError.timedOut
    }

    private func finishAutomationOwnership(_ operation: UUID) {
        if activeAutomationID == operation { activeAutomationID = nil }
        if automationCheckpointOwner == operation { automationCheckpointOwner = nil }
    }
}
