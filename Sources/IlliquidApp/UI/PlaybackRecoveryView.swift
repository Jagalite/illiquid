import AppKit
import IlliquidCore
import IlliquidPlayer
import SwiftUI

struct PlaybackRecoveryView: View {
    let player: PlaybackCoordinator

    var body: some View {
        if let issue = player.viewStore.recoveryIssue {
            VStack(alignment: .leading, spacing: 10) {
                Text(issue.message).font(.callout).textSelection(.enabled)
                if let source = issue.source {
                    Text(source.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(source.path)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions(issue) }
                    VStack(alignment: .leading) { actions(issue) }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: 540, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3)))
            .padding(.horizontal, 20)
            .padding(.top, 56)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Playback recovery")
        }
    }

    @ViewBuilder private func actions(_ issue: PlaybackRecoveryIssue) -> some View {
        switch issue.kind {
        case .message: EmptyView()
        case .unavailableRestore(let isFolder):
            Button("Retry") { player.retryRecovery() }
            Button("Locate…") { locate(isFolder: isFolder) }
            Button("Forget Session") { player.forgetUnavailableSession() }
                .help("Forget the unavailable launch session. Playback history is kept.")
        case .failedSource(let canSkip):
            Button("Retry") { player.retryRecovery() }
            if canSkip { Button("Skip") { player.skipFailedSource() } }
            Button("Stop") { player.stop() }
        }
        Button("Copy Details") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(issue.diagnosticText, forType: .string)
        }
        Button("Dismiss") { player.dismissRecovery() }
    }

    private func locate(isFolder: Bool) {
        let panel = NSOpenPanel()
        panel.title = isFolder ? "Locate Previous Folder" : "Locate Previous File"
        panel.canChooseDirectories = isFolder
        panel.canChooseFiles = !isFolder
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            player.locateUnavailableSession(at: url)
        }
    }
}
