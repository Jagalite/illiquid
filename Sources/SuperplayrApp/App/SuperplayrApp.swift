import SwiftUI
import SuperplayrCore

@main
@MainActor
struct SuperplayrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var themeStore: PlayerThemeStore

    init() {
        if Bundle.main.bundleIdentifier == LegacyPreferencesMigration.bundleIdentifier {
            LegacyPreferencesMigration.migrateIfNeeded(
                destinationDomain: LegacyPreferencesMigration.bundleIdentifier
            )
        }
        _themeStore = State(initialValue: PlayerThemeStore.shared)
    }

    var body: some Scene {
        Window("Illiquid", id: "player") {
            Group {
                if let model {
                    playerView(model)
                } else {
                    StartupHistoryView()
                        .frame(minWidth: 720, minHeight: 440)
                        .task { model = await AppModel.loadShared() }
                }
            }
            .windowFullScreenBehavior(.enabled)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 760)
        .commands {
            if let model { PlayerCommands(model: model) }
        }

        Settings {
            if let model {
                SettingsView(model: model, themeStore: themeStore)
                    .frame(minWidth: 820, minHeight: 600)
            } else {
                StartupHistoryView()
                    .frame(minWidth: 820, minHeight: 600)
                    .task { model = await AppModel.loadShared() }
            }
        }
    }

    private func playerView(_ model: AppModel) -> some View {
        PlayerRootView(model: model)
            .environment(\.playerTheme, themeStore.selection)
            .environment(\.playerTextColorMode, themeStore.textColorMode)
            .environment(\.playerRainbowPalette, themeStore.rainbowPalette)
            .environment(
                \.playbackVideoColorStore,
                model.player.videoColorStore
            )
            .environment(
                \.colorScheme,
                themeStore.selection.preferredColorScheme
            )
            .tint(themeStore.selection.accentColor)
            .background {
                WindowAccessor { window in
                    model.configure(window: window)
                }
                PlayerWindowSceneBridge(model: model)
            }
            // AppKit owns the minimum window frame. Its title bar can leave
            // less content height, so chrome must accept the actual proposal.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                model.player.setVideoColorSamplingEnabled(
                    themeStore.usesVideoColorSampling
                )
            }
            .onChange(of: themeStore.usesVideoColorSampling) { _, enabled in
                model.player.setVideoColorSamplingEnabled(enabled)
            }
    }
}

private struct PlayerWindowSceneBridge: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                model.installPlayerWindowReopener {
                    openWindow(id: "player")
                }
            }
    }
}

private struct StartupHistoryView: View {
    @State private var isSlow = false
    var body: some View {
        VStack(spacing: 16) {
            ProgressView("Loading playback history…")
            if isSlow {
                Text("History is taking longer than usual. You can keep waiting or quit and try again. Your saved history will not be cleared.")
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Quit Illiquid") { NSApp.terminate(nil) }
            }
        }
        .task {
            do { try await Task.sleep(for: .seconds(3)); isSlow = true } catch { }
        }
    }
}
