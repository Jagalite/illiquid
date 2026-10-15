import IlliquidCore
import IlliquidPlayer
import SwiftUI

struct CaptionNavigationView: View {
    let player: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index: CaptionIndex?
    @State private var indexedSource: CaptionSourceRequest?
    @State private var results: [CaptionCue] = []
    @State private var message: String?
    @State private var loading = false
    @State private var revision = 0

    private var source: CaptionSourceRequest? { player.captionSourceRequest }
    private var isCurrent: Bool { indexedSource != nil && indexedSource == source }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Caption Navigation").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Search the selected subtitle track and jump to a line.")
                .foregroundStyle(.secondary)
            TextField("Search captions", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search captions")
            HStack {
                Button("Replay Previous Cue") { replay(sentence: false) }
                    .disabled(loading || !isCurrent)
                Button("Replay Previous Sentence") { replay(sentence: true) }
                    .disabled(loading || !isCurrent)
                    .help("Groups up to eight neighboring subtitle cues using punctuation and timing. This is a subtitle heuristic, not speech recognition.")
                Spacer()
                Button("Reload") { revision += 1 }
                    .disabled(loading || source == nil)
            }
            if loading { ProgressView("Reading captions…") }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let index, !index.isComplete {
                Text("Partial index: the bounded scan reached its time, storage, text, or cue limit. Only indexed captions are searchable.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            List(results) { cue in
                Button {
                    guard let index, let indexedSource else { return }
                    _ = player.jumpToCaption(cue.id, in: index, source: indexedSource)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(timestamp(cue.start)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .trailing)
                        Text(cue.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(!isCurrent)
                .accessibilityLabel("Jump to \(timestamp(cue.start)): \(cue.text)")
            }
            .overlay {
                if results.isEmpty, !loading {
                    Text(index == nil ? "Select a text subtitle track to begin." : "No matching captions.")
                        .foregroundStyle(.secondary)
                }
            }
            if let index {
                Text("\(index.cues.count) indexed cues · showing up to 500 results · timestamps are before subtitle delay")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 600)
        .task(id: LoadKey(source: source, revision: revision)) { await load() }
        .task(id: SearchKey(query: query, source: indexedSource, revision: revision)) { await search() }
    }

    private func load() async {
        index = nil
        indexedSource = nil
        results = []
        message = nil
        guard let source else { loading = false; return }
        loading = true
        do {
            let result = try await player.readCaptions(for: source)
            try Task.checkCancellation()
            guard player.captionSourceRequest == source else { return }
            index = result
            indexedSource = source
            loading = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription
            loading = false
        }
    }

    private func search() async {
        guard let index, let indexedSource else { return }
        let query = query
        do {
            try await Task.sleep(for: .milliseconds(120))
            let work = Task.detached(priority: .userInitiated) {
                index.search(query, isCancelled: { Task.isCancelled })
            }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard source == indexedSource, self.query == query else { return }
            results = found
        } catch {}
    }

    private func replay(sentence: Bool) {
        guard let index, let indexedSource else { return }
        _ = player.replayPreviousCaption(in: index, source: indexedSource, sentence: sentence)
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds)
        return [value / 3_600, (value / 60) % 60, value % 60]
            .map { $0 < 10 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    private struct LoadKey: Hashable { let source: CaptionSourceRequest?; let revision: Int }
    private struct SearchKey: Hashable { let query: String; let source: CaptionSourceRequest?; let revision: Int }
}

struct MediaPlaybackPreferencesView: View {
    let player: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MediaPlaybackSettings()
    @State private var audioLanguage = ""
    @State private var subtitleLanguage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Preferences for This File").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(player.viewStore.currentURL?.lastPathComponent ?? "No local file is open")
                .font(.headline).lineLimit(2).textSelection(.enabled)
            Text(player.remembersPlaybackHistory
                ? "Explicit file choices override global defaults. Reset a row to inherit its default."
                : "Playback history is off. Changes apply only to this open session and are not saved.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Audio", selection: Binding(get: { audioChoice }, set: { setAudioChoice($0) })) {
                    Text("Inherit global preference").tag("inherit")
                    if let language = settings.audioLanguage { Text("Language: \(language)").tag("language") }
                    if audioChoice == "saved" { Text("Saved choice unavailable").tag("saved") }
                    ForEach(player.viewStore.audioTracks) { track in
                        Text(track.displayName).tag(String(track.id))
                    }
                }
                HStack {
                    TextField("Audio language (for example ja)", text: $audioLanguage)
                    Button("Use Language") { player.setMediaLanguage(audioLanguage, kind: .audio); refresh() }
                        .disabled(TrackSelectionPreferences.normalizedLanguage(audioLanguage) == nil)
                }
                Picker("Subtitles", selection: Binding(get: { subtitleChoice }, set: { setSubtitleChoice($0) })) {
                    Text("Inherit global preference").tag("inherit")
                    Text("Off for this file").tag("off")
                    if let language = settings.subtitleLanguage { Text("Language: \(language)").tag("language") }
                    if subtitleChoice == "saved" { Text("Saved choice unavailable").tag("saved") }
                    if settings.externalSubtitleURL != nil, settings.subtitleTrack == nil {
                        Text("Loaded external subtitle").tag("external")
                    }
                    ForEach(player.viewStore.subtitleTracks) { track in
                        Text(track.displayName).tag(String(track.id))
                    }
                }
                HStack {
                    TextField("Subtitle language (for example en)", text: $subtitleLanguage)
                    Button("Use Language") { player.setMediaLanguage(subtitleLanguage, kind: .subtitle); refresh() }
                        .disabled(TrackSelectionPreferences.normalizedLanguage(subtitleLanguage) == nil)
                }
                scalarRow("Playback speed", field: .playbackSpeed,
                    value: settings.playbackSpeed ?? player.viewStore.playbackSpeed,
                    range: 0.25...4, step: 0.05, unit: "×", update: { player.setPlaybackSpeed($0) })
                scalarRow("Audio delay", field: .audioDelay,
                    value: settings.audioDelay ?? player.viewStore.audioDelay,
                    range: -10...10, step: 0.05, unit: "s", update: { player.setAudioDelay($0) })
                scalarRow("Subtitle delay", field: .subtitleDelay,
                    value: settings.overrides(.subtitleDelay) ? settings.subtitleDelay : player.viewStore.subtitleDelay,
                    range: -10...10, step: 0.05, unit: "s", update: { player.setSubtitleDelay($0) })
            }
            .formStyle(.grouped)
            .disabled(!player.canEditCurrentMediaSettings)
            HStack {
                Text("Missing languages use the available media/default track; they do not change another file's settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset This File to Defaults") { player.resetCurrentMediaSettings(); refresh() }
                    .disabled(!player.canEditCurrentMediaSettings || settings.isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 630, idealWidth: 700, minHeight: 550)
        .onAppear { refresh() }
        .onChange(of: player.viewStore.currentSource) { _, _ in refresh() }
        .onChange(of: player.viewStore.phase) { _, _ in refresh() }
        .onChange(of: player.viewStore.selectedAudioTrack) { _, _ in refresh() }
        .onChange(of: player.viewStore.selectedSubtitleTrack) { _, _ in refresh() }
        .onChange(of: player.viewStore.playbackSpeed) { _, _ in refresh() }
        .onChange(of: player.viewStore.audioDelay) { _, _ in refresh() }
        .onChange(of: player.viewStore.subtitleDelay) { _, _ in refresh() }
    }

    private func scalarRow(_ title: String, field: MediaPlaybackSetting, value: Double,
                           range: ClosedRange<Double>, step: Double, unit: String,
                           update: @escaping @MainActor (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(settings.overrides(field) ? "This file" : "Inherited").foregroundStyle(.secondary)
            Stepper(value: Binding(get: { value }, set: { update($0); refresh() }), in: range, step: step) {
                Text("\(value.formatted(.number.precision(.fractionLength(2)))) \(unit)").monospacedDigit()
            }
            .frame(width: 142)
            Button("Reset") { player.resetCurrentMediaSetting(field); refresh() }
                .disabled(!settings.overrides(field))
        }
    }

    private var audioChoice: String {
        if !settings.overrides(.audio) { return "inherit" }
        if settings.audioLanguage != nil { return "language" }
        return settings.audioTrack?.bestMatch(in: player.viewStore.audioTracks).map { String($0.id) } ?? "saved"
    }

    private var subtitleChoice: String {
        if !settings.overrides(.subtitles) { return "inherit" }
        if !settings.areSubtitlesVisible { return "off" }
        if settings.subtitleLanguage != nil { return "language" }
        if settings.externalSubtitleURL != nil, settings.subtitleTrack == nil { return "external" }
        return settings.subtitleTrack?.bestMatch(in: player.viewStore.subtitleTracks).map { String($0.id) } ?? "saved"
    }

    private func setAudioChoice(_ choice: String) {
        if choice == "inherit" { player.resetCurrentMediaSetting(.audio) }
        else if let id = Int64(choice), let track = player.viewStore.audioTracks.first(where: { $0.id == id }) {
            player.selectAudioTrack(track)
        }
        refresh()
    }

    private func setSubtitleChoice(_ choice: String) {
        if choice == "inherit" { player.resetCurrentMediaSetting(.subtitles) }
        else if choice == "off" { player.selectSubtitleTrack(nil) }
        else if let id = Int64(choice), let track = player.viewStore.subtitleTracks.first(where: { $0.id == id }) {
            player.selectSubtitleTrack(track)
        }
        refresh()
    }

    private func refresh() {
        settings = player.mediaSettingsForCurrentFile
        audioLanguage = settings.audioLanguage ?? ""
        subtitleLanguage = settings.subtitleLanguage ?? ""
    }
}
