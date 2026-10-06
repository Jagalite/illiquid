import SwiftUI
import SuperplayrCore

struct ThumbnailSettingsCard: View {
    @Bindable var scheduler: ThumbnailBackgroundScheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thumbnail Previews").font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("Memory cache: \(scheduler.preferences.memoryMiB) MiB",
                            value: $scheduler.preferences.memoryMiB, in: 8...128, step: 8)
                    Stepper("Disk cache: \(scheduler.preferences.diskMiB) MiB",
                            value: $scheduler.preferences.diskMiB, in: 0...2048, step: 64)
                    Text("Cached previews are shared across videos. Set disk storage to zero to disable it. Decoder memory is separate from these limits.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear Thumbnail Cache") { Task { await scheduler.clearCache() } }
                    Divider()
                    Toggle("Generate thumbnails while idle", isOn: $scheduler.preferences.generatesInBackground)
                    Text("Prepares previews for nearby files and recently viewed videos while playback is paused or stopped. Suspends in Low Power Mode or when the Mac is too warm.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Also generate with the player window closed",
                               isOn: $scheduler.preferences.generatesWithWindowClosed)
                        Text("Requires keeping Illiquid running after closing the last window. Quit always stops background work.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Prioritize", selection: $scheduler.preferences.priority) {
                            Text("Balanced").tag(ThumbnailPreferences.Priority.balanced)
                            Text("Nearby files").tag(ThumbnailPreferences.Priority.nearby)
                            Text("Recent activity").tag(ThumbnailPreferences.Priority.recent)
                        }
                        Stepper("Videos per pass: \(scheduler.preferences.videosPerPass)",
                                value: $scheduler.preferences.videosPerPass, in: 1...64)
                        Stepper("Previews per video: \(scheduler.preferences.samplesPerVideo)",
                                value: $scheduler.preferences.samplesPerVideo, in: 1...64)
                        Stepper("Wait until idle: \(scheduler.preferences.idleSeconds) seconds",
                                value: $scheduler.preferences.idleSeconds, in: 1...30)
                        Stepper("Work budget per pass: \(scheduler.preferences.workSeconds) seconds",
                                value: $scheduler.preferences.workSeconds, in: 1...120)
                        Stepper("Consider recent activity: \(scheduler.preferences.recencyDays) days",
                                value: $scheduler.preferences.recencyDays, in: 1...30)
                        Text("A pass starts after navigation, preview interaction or playback state changes. It stops at its budget and does not repeat continuously. Recent activity is kept for this app session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(!scheduler.preferences.generatesInBackground)
                    Text(scheduler.status).font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }
}
