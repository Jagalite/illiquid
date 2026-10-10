import SwiftUI
import IlliquidCore

@main
@MainActor
struct IlliquidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var offersDefaultPlayer = false
    @State private var showsDefaultPlayerResult = false
    @State private var themeStore: PlayerThemeStore
    @State private var interfaceScale: PlayerInterfaceScaleStore

    init() {
        let timing = LifecyclePerformance.begin("app-init")
        defer { LifecyclePerformance.end("app-init", since: timing) }
        if Bundle.main.bundleIdentifier == LegacyPreferencesMigration.bundleIdentifier {
            LegacyPreferencesMigration.migrateIfNeeded(
                destinationDomain: LegacyPreferencesMigration.bundleIdentifier
            )
        }
        _themeStore = State(initialValue: PlayerThemeStore.shared)
        _interfaceScale = State(initialValue: PlayerInterfaceScaleStore.shared)
    }

    var body: some Scene {
        Window("Illiquid", id: "player") {
            Group {
                if let model {
                    playerView(model)
                } else {
                    StartupView()
                        .frame(minWidth: 720, minHeight: 440)
                        .background {
                            if LifecyclePerformance.isEnabled {
                                WindowAccessor { _ in LifecyclePerformance.mark("startup-shell-attached") }
                            }
                        }
                        .task { model = await AppModel.loadShared() }
                }
            }
            .windowFullScreenBehavior(.enabled)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 760)
        .commands {
            UpdateCommands()
            if let model { PlayerCommands(model: model) }
        }

        Settings {
            if let model {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        SettingsView(model: model, themeStore: themeStore)
                            .frame(
                                width: max(820, geometry.size.width / interfaceScale.factor),
                                height: max(600, geometry.size.height / interfaceScale.factor)
                            )
                            .scaledPlayerInterface()
                    }
                }
                .frame(minWidth: 820, minHeight: 600)
            } else {
                StartupView()
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
                    model.thumbnailScheduler.observeVisibility(of: window)
                    model.configure(window: window)
                }
                PlayerWindowSceneBridge(model: model)
            }
            // AppKit owns the minimum window frame. Its title bar can leave
            // less content height, so chrome must accept the actual proposal.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                guard ProcessInfo.processInfo.environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] != "1" else { return }
                offersDefaultPlayer = DefaultVideoPlayer.shared.takeLaunchOffer()
            }
            .alert("Make Illiquid your default video player?", isPresented: $offersDefaultPlayer) {
                Button("Make Default") {
                    Task {
                        await DefaultVideoPlayer.shared.makeDefault()
                        showsDefaultPlayerResult = true
                    }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Open supported video files in Illiquid when you double-click them in Finder. You can turn off this launch reminder or make Illiquid the default later in Settings → Behavior.")
            }
            .alert("Default Video Player", isPresented: $showsDefaultPlayerResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(DefaultVideoPlayer.shared.result ?? "")
            }
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

private struct StartupView: View {
    @State private var isSlow = false
    var body: some View {
        VStack(spacing: 16) {
            ProgressView("Starting Illiquid…")
            if isSlow {
                Text("Startup is taking longer than usual. You can keep waiting or quit and try again. Your saved history will not be cleared.")
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Quit Illiquid") { NSApp.terminate(nil) }
            }
        }
        .task {
            do { try await Task.sleep(for: .seconds(3)); isSlow = true } catch { }
        }
    }
}

private struct UpdateCommands: Commands {
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
    }
}
