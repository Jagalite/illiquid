import CFFmpeg
import IlliquidCore

extension FFmpegStreamInfo {
    var selectionCandidate: TrackSelectionCandidate? {
        let trackKind: MediaTrackKind
        switch kind {
        case .audio: trackKind = .audio
        case .subtitle where subtitleCapability?.isPlayable == true: trackKind = .subtitle
        default: return nil
        }
        return TrackSelectionCandidate(
            track: MediaTrack(id: NativeTrackIDMapping.trackID(for: index), kind: trackKind,
                              title: title, languageCode: language, codec: codecName,
                              isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
                              isForced: disposition & AV_DISPOSITION_FORCED != 0),
            isCommentary: disposition & AV_DISPOSITION_COMMENT != 0,
            isAccessible: disposition & (AV_DISPOSITION_HEARING_IMPAIRED | AV_DISPOSITION_VISUAL_IMPAIRED) != 0,
            canFilterForcedEvents: subtitleCapability == .bitmap
        )
    }
}

extension FFmpegMediaInfo {
    func preferredTrackIndex(_ kind: MediaTrackKind, preferences: TrackSelectionPreferences,
                             audioLanguage: String? = nil) -> Int32? {
        let fallback = kind == .audio ? selectedAudioIndex : selectedSubtitleIndex
        return preferences.select(in: streams.compactMap(\.selectionCandidate), kind: kind,
                                  fallbackID: fallback.map(NativeTrackIDMapping.trackID),
                                  audioLanguage: audioLanguage)
            .flatMap(NativeTrackIDMapping.streamIndex)
    }
}
