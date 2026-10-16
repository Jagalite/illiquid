import Foundation
@testable import IlliquidCore

@MainActor enum StateDifferential {
    static let urls = (0..<16).map { URL(fileURLWithPath: "/synthetic/日本語/Episode \($0).mkv") }
    static let items = urls.map { FolderPlaylistItem(url: $0) }
    static let chapters = (0..<32).map { Chapter(id: Int64($0), title: "Chapter \($0)", startTime: Double($0) * 30) }
    static let tracks = (0..<16).map { MediaTrack(id: Int64($0), kind: $0.isMultiple(of: 2) ? .audio : .subtitle,
                                               title: "Track \($0)", languageCode: $0.isMultiple(of: 3) ? "ja" : "en") }
    static func apply(_ action: Int, _ value: Int, state: PlaybackState) {
        switch action {
        case 0: state.setVolume(Double(value % 150 - 20))
        case 1: state.setMuted(value.isMultiple(of: 2))
        case 2: state.setPlaybackSpeed(Double(value % 5))
        case 3: state.setFullscreen(value.isMultiple(of: 2))
        case 4: state.setSidebarVisible(value.isMultiple(of: 2))
        case 5: state.setRepeatMode([.off,.one,.all][value % 3])
        case 6: state.setShuffleEnabled(value.isMultiple(of: 2))
        case 7: state.updatePictureInPicture(.init(isPossible: value.isMultiple(of: 2),isActive: value.isMultiple(of: 3)))
        case 8: state.updateChapters(value.isMultiple(of: 2) ? chapters : Array(chapters.reversed()),currentID: Int64(value % 40))
        case 9: state.updateTrackCatalog(value.isMultiple(of: 2) ? tracks : Array(tracks.reversed()))
        case 10: state.recordDiagnostic(value.isMultiple(of: 20) ? "" : "diagnostic-\(value % 4)")
        case 11: state.setShellError(value.isMultiple(of: 3) ? nil : "error-\(value % 4)")
        case 12: state.setRecoveryIssue(value.isMultiple(of: 3) ? nil : .init(kind: .unavailableRestore(isFolder: value.isMultiple(of: 2)),message: "unavailable",source: urls[value % urls.count]))
        case 13: state.updateVideoAdjustments { $0.gamma = Double(value % 5); $0.scaleMode = value.isMultiple(of: 2) ? .fit : .fill }
        case 14: state.setVideoFilter([.deband,.denoise,.sharpen][value % 3],enabled: value.isMultiple(of: 2))
        case 15: state.setAudioDelay(value.isMultiple(of: 5) ? .nan : Double(value % 10 - 5))
        case 16: state.updateVideoAspectRatio([nil,-1,0,1,2,.infinity][value % 6])
        case 17: state.updateDisplayOutput(.init(name: "display-\(value % 3)",maximumFramesPerSecond: value % 120))
        case 18: state.updateAudioOutputDevices((0..<4).map { AudioOutputDevice(id: "device-\($0)",name: "Device \($0)",isDefault: $0 == 0,isSelected: $0 == value % 5) })
        case 19: state.updateBufferTelemetry(cacheDuration: Double(value % 20 - 5),cachePercent: value.isMultiple(of: 2) ? nil : Double(value % 150))
        case 20: state.setHardwareDecodingPolicy([.automatic,.compatibility,.off][value % 3])
        case 21: state.updateActiveDecoder(value.isMultiple(of: 2) ? "decoder" : nil,isHardwareDecoded: value.isMultiple(of: 3),didFallbackToSoftware: value.isMultiple(of: 5))
        case 22: state.setSubtitleFallbackEncoding([.unicodeOnly,.windows1252,.windows1251,.shiftJIS,.isoLatin1][value % 5])
        case 23: state.setTrackSelectionPreferences(.init(audioLanguages: value.isMultiple(of: 2) ? ["EN","ja","bad-code","en"] : ["ja"],subtitleLanguages: ["en"],subtitles: value.isMultiple(of: 3) ? .off : .automatic))
        case 24: state.configurePlaylist(folder: value.isMultiple(of: 2) ? urls[0].deletingLastPathComponent() : nil,items: value.isMultiple(of: 3) ? [] : items,selectedIndex: value % 20)
        case 25: state.clearMediaMetadata()
        case 26:
            if let request = MediaLoadRequest(source: .localFile(urls[value % urls.count]),origin: value.isMultiple(of: 2) ? .userSelected : .restoredSession) {
                state.prepareLoadMetadata(request: request,playlistIndex: value % 20)
            }
        case 27: state.updateVideoOutput { $0.codec = "codec-\(value % 4)"; $0.pixelWidth = value % 3840 }
        case 28: state.applyAuthorityProjection(.init(phase: PlaybackPhase.allCases[value % PlaybackPhase.allCases.count],position: value.isMultiple(of: 9) ? .nan : Double(value % 10_000),duration: value.isMultiple(of: 7) ? -1 : 3600,isBuffering: value.isMultiple(of: 2),selectedAudioID: Int64(value % 20),selectedSubtitleID: Int64(value % 17),subtitleDelay: value.isMultiple(of: 5) ? .infinity : 2,failureCode: value.isMultiple(of: 11) ? "nativeSeekFailed" : nil,isPauseDesired: value.isMultiple(of: 2)))
        case 29: state.updateChapters(state.chapters,currentID: state.currentChapterID)
        case 30: state.setVolume(state.volume)
        default: state.updateVideoAdjustments { _ in }
        }
    }
    static func applyLegacy(_ action: Int, _ value: Int, state: LegacyPlaybackState) {
        switch action {
        case 0: state.setVolume(Double(value % 150 - 20))
        case 1: state.setMuted(value.isMultiple(of: 2))
        case 2: state.setPlaybackSpeed(Double(value % 5))
        case 3: state.setFullscreen(value.isMultiple(of: 2))
        case 4: state.setSidebarVisible(value.isMultiple(of: 2))
        case 5: state.setRepeatMode([.off,.one,.all][value % 3])
        case 6: state.setShuffleEnabled(value.isMultiple(of: 2))
        case 7: state.updatePictureInPicture(.init(isPossible: value.isMultiple(of: 2),isActive: value.isMultiple(of: 3)))
        case 8: state.updateChapters(value.isMultiple(of: 2) ? chapters : Array(chapters.reversed()),currentID: Int64(value % 40))
        case 9: state.updateTrackCatalog(value.isMultiple(of: 2) ? tracks : Array(tracks.reversed()))
        case 10: state.recordDiagnostic(value.isMultiple(of: 20) ? "" : "diagnostic-\(value % 4)")
        case 11: state.setShellError(value.isMultiple(of: 3) ? nil : "error-\(value % 4)")
        case 12: state.setRecoveryIssue(value.isMultiple(of: 3) ? nil : .init(kind: .unavailableRestore(isFolder: value.isMultiple(of: 2)),message: "unavailable",source: urls[value % urls.count]))
        case 13: state.updateVideoAdjustments { $0.gamma = Double(value % 5); $0.scaleMode = value.isMultiple(of: 2) ? .fit : .fill }
        case 14: state.setVideoFilter([.deband,.denoise,.sharpen][value % 3],enabled: value.isMultiple(of: 2))
        case 15: state.setAudioDelay(value.isMultiple(of: 5) ? .nan : Double(value % 10 - 5))
        case 16: state.updateVideoAspectRatio([nil,-1,0,1,2,.infinity][value % 6])
        case 17: state.updateDisplayOutput(.init(name: "display-\(value % 3)",maximumFramesPerSecond: value % 120))
        case 18: state.updateAudioOutputDevices((0..<4).map { AudioOutputDevice(id: "device-\($0)",name: "Device \($0)",isDefault: $0 == 0,isSelected: $0 == value % 5) })
        case 19: state.updateBufferTelemetry(cacheDuration: Double(value % 20 - 5),cachePercent: value.isMultiple(of: 2) ? nil : Double(value % 150))
        case 20: state.setHardwareDecodingPolicy([.automatic,.compatibility,.off][value % 3])
        case 21: state.updateActiveDecoder(value.isMultiple(of: 2) ? "decoder" : nil,isHardwareDecoded: value.isMultiple(of: 3),didFallbackToSoftware: value.isMultiple(of: 5))
        case 22: state.setSubtitleFallbackEncoding([.unicodeOnly,.windows1252,.windows1251,.shiftJIS,.isoLatin1][value % 5])
        case 23: state.setTrackSelectionPreferences(.init(audioLanguages: value.isMultiple(of: 2) ? ["EN","ja","bad-code","en"] : ["ja"],subtitleLanguages: ["en"],subtitles: value.isMultiple(of: 3) ? .off : .automatic))
        case 24: state.configurePlaylist(folder: value.isMultiple(of: 2) ? urls[0].deletingLastPathComponent() : nil,items: value.isMultiple(of: 3) ? [] : items,selectedIndex: value % 20)
        case 25: state.clearMediaMetadata()
        case 26:
            if let request = MediaLoadRequest(source: .localFile(urls[value % urls.count]),origin: value.isMultiple(of: 2) ? .userSelected : .restoredSession) {
                state.prepareLoadMetadata(request: request,playlistIndex: value % 20)
            }
        case 27: state.updateVideoOutput { $0.codec = "codec-\(value % 4)"; $0.pixelWidth = value % 3840 }
        case 28: state.applyAuthorityProjection(.init(phase: PlaybackPhase.allCases[value % PlaybackPhase.allCases.count],position: value.isMultiple(of: 9) ? .nan : Double(value % 10_000),duration: value.isMultiple(of: 7) ? -1 : 3600,isBuffering: value.isMultiple(of: 2),selectedAudioID: Int64(value % 20),selectedSubtitleID: Int64(value % 17),subtitleDelay: value.isMultiple(of: 5) ? .infinity : 2,failureCode: value.isMultiple(of: 11) ? "nativeSeekFailed" : nil,isPauseDesired: value.isMultiple(of: 2)))
        case 29: state.updateChapters(state.chapters,currentID: state.currentChapterID)
        case 30: state.setVolume(state.volume)
        default: state.updateVideoAdjustments { _ in }
        }
    }

    static func run() throws -> [String:Any] {
        let candidate = PlaybackState(), baseline = LegacyPlaybackState()
        let cv = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: candidate))
        let bv = PlaybackViewStore(snapshot: PlaybackViewSnapshot(baseline: baseline))
        var candidateCalls = 0, baselineCalls = 0, comparisons = 0
        candidate.onMutation = { [weak candidate,weak cv] in
            guard let candidate else { return }; candidateCalls += 1; cv?.publish(PlaybackViewSnapshot(state: candidate))
        }
        baseline.onMutation = { [weak baseline,weak bv] in
            guard let baseline else { return }; baselineCalls += 1; bv?.publish(PlaybackViewSnapshot(baseline: baseline))
        }
        var rng: UInt64 = 0x51F07E5D
        var receipts: [[String:Int]] = []
        for step in 0..<20_000 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let action = Int((rng >> 32) % 32), value = Int((rng >> 8) % 10_000)
            apply(action,value,state: candidate); applyLegacy(action,value,state: baseline)
            let current = PlaybackViewSnapshot(state: candidate), old = PlaybackViewSnapshot(baseline: baseline)
            guard current == old else { throw PlaybackStatePublicationChecks.Failure(description: "state differential step \(step), action \(action), value \(value)") }
            guard cv.snapshot == current, bv.snapshot == old else { throw PlaybackStatePublicationChecks.Failure(description: "stale view snapshot at step \(step)") }
            comparisons += 3
            if step.isMultiple(of: 100) { receipts.append(["step":step,"candidate_callbacks":candidateCalls,"baseline_callbacks":baselineCalls]) }
        }
        return ["kind":"differential","operations":20_000,"comparisons":comparisons,"candidate_callbacks":candidateCalls,"baseline_callbacks":baselineCalls,"receipts":receipts]
    }
}
