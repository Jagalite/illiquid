import SwiftUI
import IlliquidCore

struct GoToTimeView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var source: MediaSource?
    @FocusState private var focused: Bool

    private var target: TimeInterval? {
        PlaybackTimeInput.seconds(input, duration: model.state.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Go to Time").font(.headline)
            Text("Enter seconds, minutes:seconds, or hours:minutes:seconds.")
            TextField("Time", text: $input).focused($focused)
                .onSubmit { submit() }
            if !input.isEmpty && target == nil {
                Text("Enter a valid time within this video's duration.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(target == nil || source != model.state.currentSource)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { source = model.state.currentSource; focused = true }
    }

    private func submit() {
        guard let target, source == model.state.currentSource else { return }
        model.player.seek(to: target)
        dismiss()
    }
}
