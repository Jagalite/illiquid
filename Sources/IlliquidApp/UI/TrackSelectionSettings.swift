import IlliquidCore
import IlliquidPlayer
import SwiftUI

struct TrackSelectionSettings: View {
    let player: PlaybackCoordinator
    @State private var audioLanguages = ""
    @State private var subtitleLanguages = ""
    @State private var languageError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default tracks").font(.headline)
            Text("Applies when opening media. Remembered choices for a file take priority. Use language codes in preference order, such as en, ja, fr.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Audio languages", text: $audioLanguages)
                .onSubmit(saveLanguages)
            TextField("Subtitle languages", text: $subtitleLanguages)
                .onSubmit(saveLanguages)
            Button("Save Languages", action: saveLanguages)
            if let languageError {
                Text(languageError).font(.caption).foregroundStyle(.red)
            }
            Picker("Subtitles", selection: binding(\.subtitles)) {
                ForEach(AutomaticSubtitleSelection.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Avoid commentary tracks", isOn: binding(\.avoidsCommentary))
            Toggle("Prefer audio description and accessible subtitles", isOn: binding(\.prefersAccessibleTracks))
            Text("Forced only uses the subtitle languages above, or the selected audio language when the list is empty. Track flags must be present in the file.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            audioLanguages = player.viewStore.trackSelectionPreferences.audioLanguages.joined(separator: ", ")
            subtitleLanguages = player.viewStore.trackSelectionPreferences.subtitleLanguages.joined(separator: ", ")
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<TrackSelectionPreferences, Value>) -> Binding<Value> {
        Binding(get: { player.viewStore.trackSelectionPreferences[keyPath: path] }, set: { value in
            var preferences = player.viewStore.trackSelectionPreferences
            preferences[keyPath: path] = value
            player.setTrackSelectionPreferences(preferences)
        })
    }

    private func saveLanguages() {
        let audio = audioLanguages.components(separatedBy: ",")
        let subtitles = subtitleLanguages.components(separatedBy: ",")
        let invalid = (audio + subtitles).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && TrackSelectionPreferences.normalizedLanguage($0) == nil
        }
        guard invalid.isEmpty, audio.count <= 32, subtitles.count <= 32 else {
            languageError = "Enter up to 32 language codes per list, such as en, ja, fr. Unknown codes: \(invalid.joined(separator: ", "))."
            return
        }
        languageError = nil
        var preferences = player.viewStore.trackSelectionPreferences
        preferences.audioLanguages = audio
        preferences.subtitleLanguages = subtitles
        player.setTrackSelectionPreferences(preferences)
        audioLanguages = player.viewStore.trackSelectionPreferences.audioLanguages.joined(separator: ", ")
        subtitleLanguages = player.viewStore.trackSelectionPreferences.subtitleLanguages.joined(separator: ", ")
    }
}
