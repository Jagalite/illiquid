import SwiftUI
import SuperplayrCore

struct PlayerCommands: Commands {
    let model: AppModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts…") { model.isShortcutHelpPresented = true }
            Button("Customize Playback Shortcuts…") { model.isShortcutSettingsPresented = true }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab", action: model.createSourceTab)
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Open File…", action: model.openFilePanel)
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Files to Sources…", action: model.addSourceFilesPanel)
            Button("Add Folder to Sources…", action: model.addSourceFoldersPanel)
                .keyboardShortcut("o", modifiers: [.command, .shift])
            if model.player.supports(.openRemoteStream) {
                Button("Open Location…", action: model.openLocationPanel)
                    .keyboardShortcut("l", modifiers: .command)
            }
            Divider()
            if model.player.supports(.loadExternalSubtitle) {
                Button("Load External Subtitle…", action: model.openSubtitlePanel)
                    .disabled(model.state.currentSource == nil)
            }
        }

        CommandMenu("Playback") {
            Button(model.state.isPauseDesired ? "Play" : "Pause") {
                model.togglePauseFromUser()
            }
            .disabled(model.state.currentSource == nil)

            Button("Seek Backward 5 Seconds") {
                model.performRelativeSeek(-5)
            }
            .disabled(model.state.currentSource == nil)

            Button("Seek Forward 5 Seconds") {
                model.performRelativeSeek(5)
            }
            .disabled(model.state.currentSource == nil)

            Divider()

            Button("Previous File", action: model.playPreviousFromUser)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!model.state.hasPreviousItem)
            Button("Next File", action: model.playNextFromUser)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!model.state.hasNextItem)

            Divider()

            if model.player.supports(.stepFrame) {
                Button("Step One Frame Forward", action: model.player.stepFrameForward)
                    .disabled(model.state.currentSource == nil)
                Button("Step One Frame Backward", action: model.player.stepFrameBackward)
                    .disabled(model.state.currentSource == nil)
            }
            Button("Go to Time…") { model.isGoToTimePresented = true }
                .keyboardShortcut(voiceOverEnabled ? nil : model.shortcutBindings.menuShortcut(for: .goToTime))
                .disabled(model.state.currentSource == nil || model.state.duration <= 0)
            if model.player.supports(.changePlaybackSpeed) {
                Menu("Playback Speed") {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button((model.state.playbackSpeed == speed ? "✓ " : "") + "\(speed.formatted())×") {
                            model.player.setPlaybackSpeed(speed)
                        }
                    }
                }
            }
            Menu("A–B Loop") {
                Button(model.loopStart.map { "A: \($0.formatted(.number.precision(.fractionLength(2))) + " s") — Set Again" } ?? "Set Start (A)", action: model.setLoopStart)
                Button(model.loopEnd.map { "B: \($0.formatted(.number.precision(.fractionLength(2))) + " s") — Set Again" } ?? "Set End (B)", action: model.setLoopEnd)
                    .disabled(!(model.loopStart.map { model.state.position > $0 } ?? false))
                Button("Clear Loop", action: model.clearLoop).disabled(model.loopStart == nil)
            }.disabled(model.state.currentSource == nil)
            if model.player.supports(.saveScreenshot) {
                Button("Save Screenshot…", action: model.saveScreenshot)
                    .keyboardShortcut(voiceOverEnabled ? nil : model.shortcutBindings.menuShortcut(for: .screenshot))
                    .disabled(model.state.currentSource == nil)
            }
            Button("Stop", action: model.player.stop)
                .disabled(model.state.currentSource == nil)

            Button(model.state.isMuted ? "Unmute" : "Mute") {
                model.toggleMuteFromUser()
            }
            .keyboardShortcut(voiceOverEnabled ? nil : model.shortcutBindings.menuShortcut(for: .toggleMute))
            .disabled(model.state.currentSource == nil)
        }

        CommandGroup(after: .toolbar) {
            Button(model.isSidebarPresented ? "Hide Sources" : "Show Sources") {
                model.toggleSidebar()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!model.isSidebarAvailable)

            Divider()

            Button("Previous Source Tab") {
                model.selectAdjacentSourceTab(.previous)
            }
            .disabled(model.sourceTabs.count < 2)

            Button("Next Source Tab") {
                model.selectAdjacentSourceTab(.next)
            }
            .disabled(model.sourceTabs.count < 2)

            Divider()

            Toggle("Always Show Controls", isOn: Binding(get: { model.areControlsAlwaysVisible }, set: { model.areControlsAlwaysVisible = $0 }))
            Toggle("Lock Controls Position", isOn: Binding(get: { model.isControlsPositionLocked }, set: { model.isControlsPositionLocked = $0 }))
            Button("Reset Controls Position", action: model.resetControlsPosition)
            Divider()
            Button("Playback Message History") {
                model.isMessageHistoryPresented = true
            }
            .disabled(model.osdPresenter.messages.isEmpty)
        }

        CommandMenu("Video") {
            if model.player.supports(.changeVideoGeometry) {
                Picker("Sizing", selection: Binding(get: { model.state.videoAdjustments.scaleMode ?? .fit }, set: { model.player.setVideoScaleMode($0) })) {
                    Text("Fit — Show Entire Image").tag(VideoScaleMode.fit)
                    Text("Fill — Crop to Window").tag(VideoScaleMode.fill)
                }
                Menu("Aspect Ratio") {
                    Button("Automatic") { model.player.setVideoAspect(nil) }
                    ForEach(["4:3", "16:9", "16:10", "2.35:1"], id: \.self) { ratio in
                        Button(ratio) { model.player.setVideoAspect(ratio) }
                    }
                }
                .disabled(model.state.pictureInPicture.isActive)
                .help("Choose the aspect ratio before entering Picture in Picture.")
                Menu("Crop") {
                    Button("None") { model.player.setVideoCrop(nil) }
                    ForEach(["1:1", "4:3", "16:9", "2.35:1"], id: \.self) { ratio in
                        Button(ratio) { model.player.setVideoCrop(ratio) }
                    }
                }
                .disabled(model.state.pictureInPicture.isActive)
                .help("Choose the crop before entering Picture in Picture.")
                Button("Reset Video Sizing", action: model.player.resetVideoGeometry)
                    .disabled(model.state.pictureInPicture.isActive)
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Fit Window to Video", action: model.fitWindowToVideo)
                .disabled(!model.canFitWindowToVideo)

            Divider()

            Button("Toggle Fullscreen", action: model.toggleFullscreen)
                .keyboardShortcut("f", modifiers: .command)

            Toggle(
                "Always on Top",
                isOn: Binding(
                    get: { model.isAlwaysOnTop },
                    set: { _ in model.toggleAlwaysOnTop() }
                )
            )
            .keyboardShortcut("t", modifiers: [.command, .option])

            if model.player.supports(.pictureInPicture) {
                Button(
                    model.state.pictureInPicture.isActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture"
                ) {
                    model.togglePictureInPicture()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.canTogglePictureInPicture)
            }
        }
    }
}
