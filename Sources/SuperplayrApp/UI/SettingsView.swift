import AppKit
import SuperplayrCore
import SuperplayrPlayer
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case playback
    case audio
    case video
    case appearance
    case sources
    case data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: "Playback"
        case .audio: "Audio & Subtitles"
        case .video: "Video"
        case .appearance: "Appearance"
        case .sources: "Sources"
        case .data: "Data & Privacy"
        }
    }

    var subtitle: String {
        switch self {
        case .playback: "Defaults and playlist behavior"
        case .audio: "Output and remembered media choices"
        case .video: "Decoding and current output status"
        case .appearance: "Themes, overlay text, and windows"
        case .sources: "Sidebar presentation and sorting"
        case .data: "Local history and stored information"
        }
    }

    var systemImage: String {
        switch self {
        case .playback: "play.circle.fill"
        case .audio: "speaker.wave.2.fill"
        case .video: "display"
        case .appearance: "paintpalette.fill"
        case .sources: "sidebar.left"
        case .data: "internaldrive.fill"
        }
    }
}

private enum SettingsClearAction: String, Identifiable {
    case playbackProgress
    case mediaChoices
    case unreadableHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playbackProgress: "Clear playback progress?"
        case .mediaChoices: "Clear remembered media choices?"
        case .unreadableHistory: "Reset unreadable history?"
        }
    }

    var message: String {
        switch self {
        case .unreadableHistory:
            "This replaces the unreadable history data and removes all playback progress and per-file choices. This cannot be undone. Media files, source tabs and app preferences stay intact."
        case .playbackProgress:
            "This removes resume positions, completed status, the last opened local media, and remembered files for folders. Recording resumes when the playback position changes or you open another file. Your preferences and source tabs stay intact."
        case .mediaChoices:
            "This removes remembered audio tracks, subtitle tracks, subtitle visibility, and subtitle delay for local media. Playback progress stays intact."
        }
    }

    var buttonTitle: String {
        switch self {
        case .playbackProgress: "Clear Playback Progress"
        case .mediaChoices: "Clear Media Choices"
        case .unreadableHistory: "Reset Unreadable History"
        }
    }
}

struct SettingsView: View {
    @Bindable private var interfaceScale = PlayerInterfaceScaleStore.shared
    @Bindable var model: AppModel
    @Bindable var themeStore: PlayerThemeStore

    @State private var selection: SettingsDestination? = .playback
    @State private var pendingClearAction: SettingsClearAction?

    @AppStorage(SourcesSidebarPreferences.widthKey)
    private var storedSidebarWidth = SourcesSidebarPreferences.defaultWidth
    @AppStorage(SourcesSidebarPreferences.nameSortKey)
    private var storedNameSortDirection = SourcesSidebarPreferences.defaultNameSort
    @AppStorage(SourcesSidebarPreferences.dateCreatedSortKey)
    private var storedDateSortDirection = SourcesSidebarPreferences.defaultDateCreatedSort
    @AppStorage(SourcesSidebarPreferences.typeSortKey)
    private var storedTypeSortDirection = SourcesSidebarPreferences.defaultTypeSort

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .navigationTitle("Illiquid")
            .navigationSplitViewColumnWidth(min: 184, ideal: 196, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    let destination = selection ?? .playback
                    SettingsPageHeader(destination: destination)
                    page(for: destination)
                }
                .frame(maxWidth: 690, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 600)
        .confirmationDialog(
            pendingClearAction?.title ?? "Clear saved data?",
            isPresented: Binding(
                get: { pendingClearAction != nil },
                set: { if !$0 { pendingClearAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingClearAction
        ) { action in
            Button(action.buttonTitle, role: .destructive) {
                performClearAction(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    @ViewBuilder
    private func page(for destination: SettingsDestination) -> some View {
        switch destination {
        case .playback:
            playbackPage
        case .audio:
            audioPage
        case .video:
            videoPage
        case .appearance:
            appearancePage
        case .sources:
            sourcesPage
        case .data:
            dataPage
        }
    }

    private var playbackPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionLabel("Controls")
            SettingsCard {
                Toggle("Always show playback controls", isOn: $model.areControlsAlwaysVisible)
                Text("Automatic hiding waits 2.5 seconds after activity. Focus and active interactions keep controls visible.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Lock controls position", isOn: $model.isControlsPositionLocked)
                Button("Reset Controls Position", action: model.resetControlsPosition)
            }
            Toggle("Restore the previous session paused", isOn: $model.restoresSessionPaused)
            Text("Files you explicitly open play automatically.").font(.caption).foregroundStyle(.secondary)
            SettingsSectionLabel("Playback Preferences")
            SettingsCard {
                SettingsRow(
                    title: "Remembered volume",
                    detail: "Changes playback now and is remembered for the next session."
                ) {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { model.state.volume },
                                set: { model.player.setVolume($0) }
                            ),
                            in: 0...100
                        )
                        .frame(width: 220)

                        Text("\(Int(model.state.volume.rounded()))%")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    title: "Muted",
                    detail: "Changes playback now. This mute state is remembered between sessions."
                ) {
                    Toggle(
                        "Muted",
                        isOn: Binding(
                            get: { model.state.isMuted },
                            set: { model.player.setMuted($0) }
                        )
                    )
                    .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(
                    title: "Default playback speed",
                    detail: model.player.supports(.changePlaybackSpeed)
                        ? "Also updates the current media."
                        : "The current playback engine uses normal speed."
                ) {
                    Picker(
                        "Default playback speed",
                        selection: Binding(
                            get: { model.state.playbackSpeed },
                            set: { model.player.setPlaybackSpeed($0) }
                        )
                    ) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                            Text(String(format: "%g×", speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                    .disabled(!model.player.supports(.changePlaybackSpeed))
                }
            }

            SettingsSectionLabel("Playlist")
            SettingsCard {
                SettingsRow(
                    title: "Repeat",
                    detail: "Choose what happens when playback reaches the end."
                ) {
                    Picker(
                        "Repeat",
                        selection: Binding(
                            get: { model.state.repeatMode },
                            set: { model.player.setRepeatMode($0) }
                        )
                    ) {
                        Text("Off").tag(PlaybackRepeatMode.off)
                        Text("All").tag(PlaybackRepeatMode.all)
                        Text("One").tag(PlaybackRepeatMode.one)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }

                SettingsDivider()

                SettingsRow(
                    title: "Shuffle",
                    detail: "Randomize the current playlist while preserving the playing item."
                ) {
                    Toggle(
                        "Shuffle",
                        isOn: Binding(
                            get: { model.state.isShuffleEnabled },
                            set: { model.player.setShuffleEnabled($0) }
                        )
                    )
                    .labelsHidden()
                }
            }
        }
    }

    private var audioPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionLabel("Output")
            SettingsCard {
                SettingsRow(
                    title: "Preferred audio output",
                    detail: audioOutputDetail
                ) {
                    audioOutputPicker
                }
            }

            SettingsSectionLabel("External Subtitles")
            SettingsCard {
                SettingsRow(title: "SRT fallback encoding",
                            detail: "Used when a subtitle is not Unicode. Applies the next time you load it; WebVTT remains UTF-8.") {
                    Picker("SRT fallback encoding", selection: Binding(
                        get: { model.state.subtitleFallbackEncoding },
                        set: { model.player.setSubtitleFallbackEncoding($0) }
                    )) {
                        ForEach(SubtitleFallbackEncoding.allCases, id: \.self) { encoding in
                            Text(encoding.title).tag(encoding)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            SettingsCard {
                TrackSelectionSettings(player: model.player)
                    .padding(16)
            }

            SettingsSectionLabel("Remembered Per Media")
            SettingsCard {
                SettingsInfoRow(
                    systemImage: "waveform.badge.checkmark",
                    title: "Audio track",
                    detail:
                        "Illiquid remembers the selected audio track for each local file and matches it by metadata when you return."
                )
                SettingsDivider()
                SettingsInfoRow(
                    systemImage: "captions.bubble.fill",
                    title: "Subtitles",
                    detail:
                        "Subtitle track, visibility, and subtitle delay are remembered independently for each local file."
                )
            }

            SettingsCard {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Forget remembered media choices")
                            .font(.body.weight(.medium))
                        Text("Playback progress and preferences are not affected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear…", role: .destructive) {
                        pendingClearAction = .mediaChoices
                    }
                }
                .padding(16)
            }
        }
    }

    private var videoPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionLabel("Decoding")
            SettingsCard {
                SettingsRow(
                    title: "Hardware decoding",
                    detail: hardwareDecodingDescription
                ) {
                    Picker(
                        "Hardware decoding",
                        selection: Binding(
                            get: { model.state.hardwareDecodingStatus.policy },
                            set: { model.player.setHardwareDecodingPolicy($0) }
                        )
                    ) {
                        Text("Automatic").tag(HardwareDecodingPolicy.automatic)
                        Text("Compatibility").tag(HardwareDecodingPolicy.compatibility)
                        Text("Off").tag(HardwareDecodingPolicy.off)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            SettingsSectionLabel("Current Output")
            SettingsCard {
                SettingsStatusRow(title: "Active decoder", value: activeDecoderDescription)
                SettingsDivider()
                SettingsStatusRow(
                    title: "Hardware decoded",
                    value: model.state.videoOutputStatus.isHardwareDecoded ? "Yes" : "No"
                )
                SettingsDivider()
                SettingsStatusRow(
                    title: "HDR",
                    value: model.state.videoOutputStatus.isHDR ? "Active" : "Inactive"
                )
                SettingsDivider()
                SettingsStatusRow(
                    title: "Video format",
                    value: videoFormatDescription
                )
            }

            HStack {
                Text(
                    "Runtime status belongs to the loaded media and may be unavailable before decoding begins."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Open Playback Inspector…") {
                    model.isInspectorPresented = true
                }
                .disabled(model.state.currentSource == nil)
            }
        }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionLabel("Interface Size")
            SettingsCard {
                SettingsRow(
                    title: "UI Scale",
                    detail: "Resize text, controls, and spacing. Use ⌘+ or ⌘− to adjust, and ⌘0 to reset."
                ) {
                    Picker("UI Scale", selection: Binding(
                        get: { interfaceScale.percentage },
                        set: { interfaceScale.select($0) }
                    )) {
                        ForEach(PlayerInterfaceScaleStore.percentages, id: \.self) { percentage in
                            Text("\(percentage)%").tag(percentage)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            SettingsSectionLabel("Theme")
            SettingsCard {
                SettingsRow(
                    title: "Interface theme",
                    detail: themeStore.selection.description
                ) {
                    Picker(
                        "Interface theme",
                        selection: Binding(
                            get: { themeStore.selection },
                            set: { themeStore.select($0) }
                        )
                    ) {
                        ForEach(PlayerTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            if themeStore.selection == .liquidGlass {
                SettingsSectionLabel("Overlay Text")
                SettingsCard {
                    SettingsRow(
                        title: "Text appearance",
                        detail: themeStore.textColorMode.description
                    ) {
                        Picker(
                            "Text appearance",
                            selection: Binding(
                                get: { themeStore.textColorMode },
                                set: { themeStore.selectTextColorMode($0) }
                            )
                        ) {
                            ForEach(PlayerTextColorMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    if themeStore.textColorMode == .dynamicRainbow {
                        SettingsDivider()
                        SettingsRow(
                            title: "Rainbow palette",
                            detail: themeStore.rainbowPalette.description
                        ) {
                            Picker(
                                "Rainbow palette",
                                selection: Binding(
                                    get: { themeStore.rainbowPalette },
                                    set: { themeStore.selectRainbowPalette($0) }
                                )
                            ) {
                                ForEach(
                                    PlayerRainbowPalette.allCases
                                ) { palette in
                                    Text(palette.displayName).tag(palette)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                }
            }

            SettingsSectionLabel("Window")
            SettingsCard {
                SettingsRow(
                    title: "Lock window to video aspect ratio",
                    detail: "Keep the player viewport proportional while resizing."
                ) {
                    Toggle(
                        "Lock window to video aspect ratio",
                        isOn: Binding(
                            get: { model.isWindowAspectLocked },
                            set: { model.setWindowAspectLocked($0) }
                        )
                    )
                    .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(
                    title: "Always on Top",
                    detail: "Keep the player above ordinary app windows."
                ) {
                    Toggle(
                        "Always on Top",
                        isOn: Binding(
                            get: { model.isAlwaysOnTop },
                            set: { model.setAlwaysOnTop($0) }
                        )
                    )
                    .labelsHidden()
                }
            }
        }
    }

    private var sourcesPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionLabel("Sidebar")
            SettingsCard {
                SettingsRow(
                    title: "Show sources sidebar",
                    detail: "Keep your source tabs visible beside the player."
                ) {
                    Toggle(
                        "Show sources sidebar",
                        isOn: Binding(
                            get: { model.state.isSidebarVisible },
                            set: { model.setSidebarVisible($0) }
                        )
                    )
                    .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(
                    title: "Sidebar width",
                    detail: "The sidebar can still be resized directly in the player."
                ) {
                    HStack(spacing: 12) {
                        Slider(value: $storedSidebarWidth, in: 300...720, step: 1)
                            .frame(width: 190)
                        Text("\(Int(storedSidebarWidth.rounded())) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            SettingsSectionLabel("Current Tab")
            SettingsCard {
                SettingsRow(
                    title: model.activeSourceTab?.displayName ?? "No source tab selected",
                    detail: "Visibility settings apply only to the current source tab."
                ) {
                    Picker(
                        "View",
                        selection: Binding(
                            get: { model.activeSourceVisibility.viewMode },
                            set: { model.setActiveSourceViewMode($0) }
                        )
                    ) {
                        ForEach(SourceVisibilityViewMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(model.activeSourceTab == nil)
                }

                SettingsDivider()

                SettingsRow(
                    title: "Show hidden items",
                    detail: sourceVisibilitySummary
                ) {
                    Toggle(
                        "Show hidden items",
                        isOn: Binding(
                            get: { model.activeSourceVisibility.showsHiddenItems },
                            set: { model.setActiveSourceShowsHiddenItems($0) }
                        )
                    )
                    .labelsHidden()
                    .disabled(model.activeSourceTab == nil)
                }

                if !model.activeSourceVisibility.isDefault {
                    SettingsDivider()
                    HStack {
                        Text(
                            "Reset view mode, hidden paths, always-show paths, and regex rules for this tab."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Current Tab") {
                            model.resetActiveSourceVisibility()
                        }
                    }
                    .padding(16)
                }
            }

            SettingsSectionLabel("Sorting")
            SettingsCard {
                sortRow(
                    title: "Name",
                    detail: "Natural filename ordering.",
                    selection: $storedNameSortDirection
                )
                SettingsDivider()
                sortRow(
                    title: "Date Created",
                    detail: "Uses file creation metadata when available.",
                    selection: $storedDateSortDirection
                )
                SettingsDivider()
                sortRow(
                    title: "Type",
                    detail: "Groups folders and media files.",
                    selection: $storedTypeSortDirection
                )
            }

            HStack {
                Text("Sort criteria combine in Type, Date Created, then Name order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Sidebar Defaults") {
                    restoreSidebarDefaults()
                }
            }
        }
    }

    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionLabel("On This Mac")
            SettingsCard {
                SettingsInfoRow(
                    systemImage: "lock.shield.fill",
                    title: "Private by design",
                    detail:
                        "Playback progress, source tabs, appearance, and remembered media choices stay in Illiquid's local app storage."
                )
                SettingsDivider()
                SettingsInfoRow(
                    systemImage: "network",
                    title: "Explicit network playback",
                    detail:
                        "Remote URLs open only when you enter them. TLS certificates are verified, and remote sessions are never reconnected automatically."
                )
            }

            if model.player.hasUnreadableHistory {
                SettingsCard {
                    Text("Saved history could not be read. It is protected from automatic replacement.")
                    Button("Reset Unreadable History…", role: .destructive) { pendingClearAction = .unreadableHistory }
                }
            }
            SettingsSectionLabel("Playback Data")
            SettingsCard {
                Toggle("Remember playback history", isOn: $model.remembersPlaybackHistory)
                Text("When off, new progress and per-file choices are not saved, and sessions are not restored. Existing history stays until you clear it. Source tabs and app preferences are still saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard {
                destructiveDataRow(
                    title: "Playback progress",
                    detail:
                        "Resume positions, completed status, last-opened media, and remembered folder files.",
                    buttonTitle: "Clear Progress…"
                ) {
                    pendingClearAction = .playbackProgress
                }

                SettingsDivider()

                destructiveDataRow(
                    title: "Remembered media choices",
                    detail:
                        "Per-file audio track, subtitles, subtitle visibility, and subtitle delay.",
                    buttonTitle: "Clear Choices…"
                ) {
                    pendingClearAction = .mediaChoices
                }
            }

            Text(
                "These actions do not remove media files, source tabs, themes, window preferences, or other Illiquid settings."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var audioOutputPicker: some View {
        let supportsSelection = model.player.supports(.selectAudioDevice)
        let preferredID = model.player.preferredAudioOutputDeviceID
        return Picker(
            "Preferred audio output",
            selection: Binding(
                get: { preferredID ?? "auto" },
                set: { id in
                    let device =
                        id == "auto"
                        ? nil
                        : model.state.audioOutputDevices.first { $0.id == id }
                    model.player.selectAudioOutputDevice(device)
                }
            )
        ) {
            Text("System Default").tag("auto")
            ForEach(model.state.audioOutputDevices.filter { $0.id != "auto" }) { device in
                Text(device.name).tag(device.id)
            }
            if let preferredID,
                !model.state.audioOutputDevices.contains(where: { $0.id == preferredID })
            {
                Text("Unavailable Device").tag(preferredID)
            }
        }
        .labelsHidden()
        .frame(width: 190)
        .disabled(!supportsSelection)
    }

    private var audioOutputDetail: String {
        if !model.player.supports(.selectAudioDevice) {
            return "The current playback engine follows the macOS system output."
        }
        if let id = model.player.preferredAudioOutputDeviceID,
            !model.state.audioOutputDevices.contains(where: { $0.id == id })
        {
            return "The preferred device is unavailable; macOS system output is in use."
        }
        return "Used whenever the device is available."
    }

    private var activeDecoderDescription: String {
        let status = model.state.hardwareDecodingStatus
        guard let decoder = status.activeDecoder else {
            return model.state.currentSource == nil
                ? "No video loaded"
                : "Not reported by current engine"
        }
        if status.didFallbackToSoftware { return "Software fallback" }
        if decoder == "no" { return "Software" }
        return decoder
    }

    private var hardwareDecodingDescription: String {
        switch model.state.hardwareDecodingStatus.policy {
        case .automatic:
            "Prefer efficient hardware decoding and fall back when necessary."
        case .compatibility:
            "Use conservative hardware formats for difficult media."
        case .off:
            "Decode video in software. This can use substantially more power."
        }
    }

    private var videoFormatDescription: String {
        let video = model.state.videoOutputStatus
        let codec = video.codec ?? "Unknown"
        guard let width = video.pixelWidth, let height = video.pixelHeight else {
            return codec
        }
        return "\(codec) · \(width) × \(height)"
    }

    private var sourceVisibilitySummary: String {
        let visibility = model.activeSourceVisibility
        let rules =
            visibility.manuallyHiddenPaths.count
            + visibility.regexRules.filter(\.isEnabled).count
        if rules == 0 { return "No active hide rules on this tab." }
        return "\(rules) active visibility rule\(rules == 1 ? "" : "s") on this tab."
    }

    private func sortRow(
        title: String,
        detail: String,
        selection: Binding<String>
    ) -> some View {
        SettingsRow(title: title, detail: detail) {
            Picker(title, selection: selection) {
                ForEach(SourceTreeSortDirection.allCases, id: \.self) { direction in
                    Text(direction.title).tag(direction.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }

    private func destructiveDataRow(
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            Button(buttonTitle, role: .destructive, action: action)
        }
        .padding(16)
    }

    private func restoreSidebarDefaults() {
        storedSidebarWidth = SourcesSidebarPreferences.defaultWidth
        storedNameSortDirection = SourcesSidebarPreferences.defaultNameSort
        storedDateSortDirection = SourcesSidebarPreferences.defaultDateCreatedSort
        storedTypeSortDirection = SourcesSidebarPreferences.defaultTypeSort
    }

    private func performClearAction(_ action: SettingsClearAction) {
        switch action {
        case .unreadableHistory:
            model.player.clearPlaybackHistory()
            model.player.dismissRecovery()
        case .playbackProgress:
            model.player.clearPlaybackProgress()
        case .mediaChoices:
            model.player.clearRememberedMediaSettings()
        }
        pendingClearAction = nil
    }
}

private struct SettingsPageHeader: View {
    let destination: SettingsDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(destination.title)
                .font(.title2.weight(.semibold))
            Text(destination.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                content
            }
        }
        .groupBoxStyle(.automatic)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            control
        }
        .padding(16)
    }
}

private struct SettingsInfoRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}
