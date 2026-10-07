import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Illiquid \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                .font(.headline)
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            ))
            .disabled(updates.unavailableReason != nil)
            Text("Check about once a day. You choose when to download and install an update.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include prerelease updates", isOn: $updates.includesPrereleases)
            Text("Prereleases may contain unfinished features. Turning this off keeps your current version and checks for future stable releases.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
            if let reason = updates.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
