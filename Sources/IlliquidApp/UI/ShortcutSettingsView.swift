import SwiftUI

struct ShortcutSettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingID = "play"
    @State private var input = ""
    @State private var error: String?

    private var definitions: [PlayerShortcutDefinition] {
        PlayerShortcutDefinition.all.filter {
            if case .stepFrame = $0.action { return model.player.supports(.stepFrame) }
            return true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Playback Shortcuts").font(.title2)
            Text("Change playback keys here. Command shortcuts in app menus and Escape retain their standard actions.")
            Picker("Action", selection: $editingID) {
                ForEach(definitions) { Text($0.title).tag($0.id) }
            }.onChange(of: editingID) { _, _ in load() }
            TextField("Shortcut (for example, Shift+K)", text: $input)
            if let error { Text(error).foregroundStyle(.secondary) }
            HStack {
                Button("Reset All") { model.shortcutBindings.reset(); load() }
                Spacer()
                Button("Save Shortcut") {
                    guard let definition = definitions.first(where: { $0.id == editingID }) else { return }
                    error = model.shortcutBindings.set(input, for: definition)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            List(definitions) { definition in
                LabeledContent(definition.title, value: model.shortcutBindings.key(for: definition))
            }.frame(height: 300)
        }.padding(24).frame(width: 540).onAppear { load() }
    }
    private func load() {
        error = nil
        if let definition = definitions.first(where: { $0.id == editingID }) {
            input = model.shortcutBindings.key(for: definition)
        }
    }
}
