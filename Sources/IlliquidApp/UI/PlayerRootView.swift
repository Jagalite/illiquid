import AppKit
import Observation
import SwiftUI
import IlliquidCore

struct PlayerRootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var sidebarState = SourcesSidebarState.restored()
    @State private var sidebarLayout = SourcesSidebarLayoutState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(model: model)
                .ignoresSafeArea()
                .onHover { isHovering in
                    model.setPointerRegion(isHovering ? .video : .outside)
                }
            chrome.scaledPlayerInterface()
        }
    }

    private var chrome: some View {
        GeometryReader { geometry in
            let maximumSidebarWidth = SourcesSidebarSizing.maximumWidth(
                for: geometry.size.width
            )

            ZStack(alignment: .leading) {
                PlayerPane(
                    model: model,
                    reduceMotion: reduceMotion,
                    sidebarLayout: sidebarLayout
                )

                SourcesSidebarPresentation(
                    model: model,
                    maximumWidth: maximumSidebarWidth,
                    state: $sidebarState,
                    layout: sidebarLayout
                )
            }
            .coordinateSpace(name: PlayerTextSamplingCoordinateSpace.name)
            .onChange(of: SourcesSidebarSizing.isAvailable(in: geometry.size.width), initial: true) { _, _ in
                model.updateSidebarAvailability(containerWidth: geometry.size.width)
            }
            .environment(\.playerTextSamplingViewportSize, geometry.size)
            .environment(\.playerTextSamplingVideoClipRect,
                VideoPresentationGeometry(
                    sourceSize: CGSize(width: model.state.videoAspectRatio ?? 1, height: 1),
                    bounds: CGRect(origin: .zero, size: geometry.size),
                    adjustments: model.state.videoAdjustments
                ).clipRect)
            .environment(
                \.playerTextSamplingVideoContentRect,
                VideoPresentationGeometry(
                    sourceSize: CGSize(width: model.state.videoAspectRatio ?? 1, height: 1),
                    bounds: CGRect(origin: .zero, size: geometry.size),
                    adjustments: model.state.videoAdjustments
                ).imageRect
            )
        }
        .overlay(alignment: .top) {
            PlaybackRecoveryView(player: model.player)
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
            model.setChromePin(.accessibilityInteraction, active: enabled)
        }
        .onDisappear {
            model.setChromePin(.accessibilityInteraction, active: false)
        }
        .onChange(of: model.state.currentSource) { _, _ in model.clearLoop() }
        .sheet(isPresented: $model.isGoToTimePresented) { GoToTimeView(model: model).scaledPlayerInterface() }
        .onChange(of: model.isGoToTimePresented) { _, shown in
            model.setTransientPresentation(shown, owner: "go-to-time")
        }
        .sheet(isPresented: $model.isInspectorPresented) {
            PlaybackInspectorView(model: model).scaledPlayerInterface()
        }
        .onChange(of: model.isInspectorPresented) { _, isPresented in
            model.setTransientPresentation(isPresented, owner: "inspector")
        }
        .sheet(isPresented: $model.isShortcutSettingsPresented) { ShortcutSettingsView(model: model).scaledPlayerInterface() }
        .onChange(of: model.isShortcutSettingsPresented) { _, shown in
            model.setTransientPresentation(shown, owner: "shortcut-settings")
        }
        .sheet(isPresented: $model.isShortcutHelpPresented) {
            ShortcutHelpView(supportsFrameStep: model.player.supports(.stepFrame),
                             supportsPictureInPicture: model.player.supports(.pictureInPicture),
                             bindings: model.shortcutBindings)
                .scaledPlayerInterface()
        }
        .onChange(of: model.isShortcutHelpPresented) { _, isPresented in
            model.setTransientPresentation(isPresented, owner: "shortcuts")
        }
        .sheet(isPresented: $model.isMessageHistoryPresented) {
            PlaybackMessageHistoryView(presenter: model.osdPresenter).scaledPlayerInterface()
        }
        .onChange(of: model.isMessageHistoryPresented) { _, isPresented in
            model.setTransientPresentation(isPresented, owner: "messages")
        }
    }
}

private struct PlayerPane: View {
    @Bindable var model: AppModel
    let reduceMotion: Bool
    let sidebarLayout: SourcesSidebarLayoutState

    private var playbackControlBarImplementation: PlaybackControlBarImplementation {
        PlaybackControlBarFeatureGate.implementation()
    }

    var body: some View {
        ZStack {
            PlaybackChromeHorizontalPlacement(layout: sidebarLayout, fillsAvailableHeight: true) {
                EmptyPlayerPresentation(model: model)
            }

            BufferingIndicator(
                isActive: (
                    model.state.isLoading || model.state.bufferStatus.isBuffering
                ),
                label: model.player.pendingOperationLabel,
                cancel: model.player.stop,
                reduceMotion: reduceMotion
            )

            PlaybackOSDView(
                presenter: model.osdPresenter,
                showHistory: { model.isMessageHistoryPresented = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 20)
            .padding(.trailing, 24)
            .environment(\.playerTheme, PlayerTheme.liquidGlass)

            if PlaybackChromeMountPolicy.shouldMount(
                hasSource: model.state.currentSource != nil,
                isVisible: model.isPlaybackChromeMounted,
                isPictureInPictureActive: model.state.pictureInPicture.isActive
            ) {
                PlaybackChromeHorizontalPlacement(
                    layout: sidebarLayout,
                    fillsAvailableHeight: true
                ) {
                    CenterTransportControls(
                        model: model,
                        sidebarOccupiedWidth: sidebarLayout.occupiedWidth
                    )
                        .opacity(model.isPlaybackChromeVisible ? 1 : 0)
                        .scaleEffect(
                            model.isPlaybackChromeVisible
                                ? 1
                                : IlliquidMotion.scale(0.985, reduceMotion: reduceMotion)
                        )
                        .allowsHitTesting(model.isPlaybackChromeVisible)
                        .accessibilityHidden(!model.isPlaybackChromeVisible)
                        .animation(
                            model.isPlaybackChromeVisible
                                ? IlliquidMotion.panelEntrance(reduceMotion: reduceMotion)
                                : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
                            value: model.isPlaybackChromeVisible
                        )
                }
            }

            if playbackControlBarImplementation == .elastic,
               PlaybackChromeMountPolicy.shouldMount(
                   hasSource: model.state.currentSource != nil,
                   isVisible: model.isPlaybackChromeMounted,
                   isPictureInPictureActive: model.state.pictureInPicture.isActive
               ) {
                PlaybackControlBarHost(
                    model: model,
                    implementation: .elastic,
                    sidebarOccupiedWidth: sidebarLayout.occupiedWidth
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(model.isPlaybackChromeVisible ? 1 : 0)
                    .offset(
                        y: model.isPlaybackChromeVisible
                            ? 0
                            : IlliquidMotion.offset(
                                IlliquidMotion.Distance.bottomChrome,
                                reduceMotion: reduceMotion
                            )
                    )
                    .allowsHitTesting(model.isPlaybackChromeVisible)
                    .accessibilityHidden(!model.isPlaybackChromeVisible)
                    .animation(
                        model.isPlaybackChromeVisible
                            ? IlliquidMotion.panelEntrance(reduceMotion: reduceMotion)
                            : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
                        value: model.isPlaybackChromeVisible
                    )
            }

            VStack(spacing: 12) {
                Spacer()

                if playbackControlBarImplementation == .legacy,
                   PlaybackChromeMountPolicy.shouldMount(
                    hasSource: model.state.currentSource != nil,
                    isVisible: model.isPlaybackChromeMounted,
                    isPictureInPictureActive: model.state.pictureInPicture.isActive
                ) {
                    PlaybackChromeHorizontalPlacement(layout: sidebarLayout) {
                        PlaybackControlBarHost(model: model, implementation: .legacy)
                            .padding(.horizontal, 18)
                            .opacity(model.isPlaybackChromeVisible ? 1 : 0)
                            .offset(
                                y: model.isPlaybackChromeVisible
                                    ? 0
                                    : IlliquidMotion.offset(
                                        IlliquidMotion.Distance.bottomChrome,
                                        reduceMotion: reduceMotion
                                    )
                            )
                            .allowsHitTesting(model.isPlaybackChromeVisible)
                            .accessibilityHidden(!model.isPlaybackChromeVisible)
                            .animation(
                                model.isPlaybackChromeVisible
                                    ? IlliquidMotion.panelEntrance(reduceMotion: reduceMotion)
                                    : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
                                value: model.isPlaybackChromeVisible
                            )
                            .onHover { isHovering in
                                model.setPointerRegion(isHovering ? .chrome : .video)
                                model.setChromePin(.pointerOverChrome, active: isHovering)
                            }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            if !isHovering {
                model.pointerExitedWindow()
            }
        }
    }
}

@MainActor
@Observable
final class SourcesSidebarLayoutState {
    private(set) var occupiedWidth: CGFloat = 0

    func setSidebarWidth(_ sidebarWidth: CGFloat) {
        let width = SourcesSidebarLayoutPolicy.occupiedWidth(
            forSidebarWidth: sidebarWidth
        )
        if occupiedWidth != width {
            occupiedWidth = width
        }
    }

    func clear() {
        if occupiedWidth != 0 {
            occupiedWidth = 0
        }
    }
}

private struct PlaybackChromeHorizontalPlacement<Content: View>: View {
    let layout: SourcesSidebarLayoutState
    let fillsAvailableHeight: Bool
    let content: Content

    init(
        layout: SourcesSidebarLayoutState,
        fillsAvailableHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.layout = layout
        self.fillsAvailableHeight = fillsAvailableHeight
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: layout.occupiedWidth, height: 0)
                .allowsHitTesting(false)

            content
                .frame(
                    maxWidth: .infinity,
                    maxHeight: fillsAvailableHeight ? .infinity : nil
                )
        }
    }
}

enum CenterTransportControlPolicy {
    static let seekInterval: TimeInterval = 10
    static let groupWidth: CGFloat = 296
    static let edgeInset: CGFloat = 16

    static func horizontalCompensation(sidebarOccupiedWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        // Stay centered on the video when there is room, but never offset a
        // transport control behind the source panel in a compact window.
        let availableOffset = max(0, (availableWidth - groupWidth) / 2 - edgeInset)
        return -min(max(0, sidebarOccupiedWidth) / 2, availableOffset)
    }
}

private struct CenterTransportControls: View {
    @Bindable var model: AppModel
    let sidebarOccupiedWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            buttons
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: CenterTransportControlPolicy.horizontalCompensation(
                    sidebarOccupiedWidth: sidebarOccupiedWidth,
                    availableWidth: geometry.size.width
                ))
        }
    }

    private var buttons: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 24) {
                transportButton(
                    "Seek Backward 10 Seconds",
                    systemImage: "gobackward.10",
                    diameter: 74,
                    symbolSize: 34,
                    isEnabled: canSeek
                ) {
                    model.performRelativeSeek(-CenterTransportControlPolicy.seekInterval)
                }

                transportButton(
                    model.state.isPauseDesired ? "Play" : "Pause",
                    systemImage: model.state.isPauseDesired ? "play.fill" : "pause.fill",
                    diameter: 100,
                    symbolSize: model.state.isPauseDesired ? 46 : 40,
                    isEnabled: model.state.currentSource != nil
                ) {
                    model.togglePauseFromPlaybackButton()
                }

                transportButton(
                    "Seek Forward 10 Seconds",
                    systemImage: "goforward.10",
                    diameter: 74,
                    symbolSize: 34,
                    isEnabled: canSeek
                ) {
                    model.performRelativeSeek(CenterTransportControlPolicy.seekInterval)
                }
            }
        }
    }

    private var canSeek: Bool {
        model.state.currentSource != nil && model.player.supports(.seekRelative)
    }

    private func transportButton(
        _ title: String,
        systemImage: String,
        diameter: CGFloat,
        symbolSize: CGFloat,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .contentTransition(.symbolEffect(.replace))
                .animation(
                    IlliquidMotion.stateMorph(reduceMotion: reduceMotion),
                    value: systemImage
                )
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerThemedControlButtonStyle())
        .playbackFocusVisibility(model)
        .playerCircularGlassControl()
        .playerIconHoverEffect(
            in: Circle(),
            highlightOpacity: PlayerControlHoverPolicy.circularHighlightOpacity,
            scale: PlayerControlHoverPolicy.circularScale,
            isEnabled: isEnabled
        )
        .dynamicPlayerTextStyle(
            opacity: isEnabled ? 0.96 : 0.42
        )
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

enum PlaybackChromeMountPolicy {
    static func shouldMount(
        hasSource: Bool,
        isVisible: Bool,
        isPictureInPictureActive: Bool
    ) -> Bool {
        hasSource && isVisible && !isPictureInPictureActive
    }
}

struct SourcesSidebarState {
    var searchText = ""
    var expandedFolderIDs: Set<String> = []
    var knownSourceFolderIDs: Set<String> = []
    var hasInitializedExpansion = false

    static func restored(defaults: UserDefaults = .standard) -> Self {
        guard let snapshot = SourcesSidebarExpansionStore.restore(
            from: defaults.data(forKey: SourcesSidebarExpansionStore.defaultsKey)
        ) else {
            return Self()
        }
        return Self(
            expandedFolderIDs: snapshot.expandedFolderIDs,
            knownSourceFolderIDs: snapshot.knownSourceFolderIDs,
            hasInitializedExpansion: true
        )
    }
}

private struct SourcesSidebarPresentation: View {
    @Bindable var model: AppModel
    let maximumWidth: CGFloat
    @Binding var state: SourcesSidebarState
    let layout: SourcesSidebarLayoutState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if SourcesSidebarMountPolicy.shouldMountShell(
                isSidebarVisible: model.isSidebarPresented
            ) {
                SourcesSidebarChromePresentation(
                    model: model,
                    maximumWidth: maximumWidth,
                    state: $state,
                    layout: layout
                )
                .transition(
                    IlliquidMotionTransition.sidebar(reduceMotion: reduceMotion)
                )
            }
        }
        .animation(
            model.isSidebarPresented
                ? IlliquidMotion.panelEntrance(reduceMotion: reduceMotion)
                : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
            value: model.isSidebarPresented
        )
    }
}

private struct SourcesSidebarChromePresentation: View {
    @Bindable var model: AppModel
    let maximumWidth: CGFloat
    @Binding var state: SourcesSidebarState
    let layout: SourcesSidebarLayoutState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if SourcesSidebarMountPolicy.shouldMountContent(
                isSidebarVisible: model.isSidebarPresented
            ) {
                SourcesSidebar(
                    model: model,
                    maximumWidth: maximumWidth,
                    searchText: $state.searchText,
                    expandedFolderIDs: $state.expandedFolderIDs,
                    knownSourceFolderIDs: $state.knownSourceFolderIDs,
                    hasInitializedExpansion: $state.hasInitializedExpansion,
                    layout: layout
                )
                .padding(SourcesSidebarLayoutPolicy.outerPadding)
                .opacity(model.isPlaybackChromeVisible ? 1 : 0)
                .allowsHitTesting(model.isPlaybackChromeVisible)
                .accessibilityHidden(!model.isPlaybackChromeVisible)
            }
        }
        .animation(
            model.isPlaybackChromeVisible
                ? IlliquidMotion.softEntrance(reduceMotion: reduceMotion)
                : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
            value: model.isPlaybackChromeVisible
        )
    }
}

enum SourcesSidebarMountPolicy {
    static func shouldMountShell(isSidebarVisible: Bool) -> Bool {
        isSidebarVisible
    }

    static func shouldMountContent(
        isSidebarVisible: Bool
    ) -> Bool {
        isSidebarVisible
    }
}

private struct BufferingIndicator: View {
    let isActive: Bool
    let label: String
    let cancel: () -> Void
    let reduceMotion: Bool
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.callout)
                    Button("Stop", action: cancel).buttonStyle(.borderless)
                }
                    .controlSize(.regular)
                    .padding(13)
                    .playerOverlaySurface(cornerRadius: 999, role: .status)
                    .help(label)
                    .accessibilityLabel(label)
                    .transition(
                        IlliquidMotionTransition.compactEntrance(
                            reduceMotion: reduceMotion
                        )
                    )
            }
        }
        .animation(
            isVisible
                ? IlliquidMotion.softEntrance(reduceMotion: reduceMotion)
                : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
            value: isVisible
        )
        .task(id: isActive) {
            guard isActive else {
                isVisible = false
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, isActive else { return }
            isVisible = true
        }
    }
}

private struct EmptyPlayerView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerTheme) private var theme
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .opacity(hasAppeared ? 1 : 0)
                .offset(
                    y: hasAppeared
                        ? 0
                        : IlliquidMotion.offset(4, reduceMotion: reduceMotion)
                )
                .animation(
                    IlliquidMotion.softEntrance(reduceMotion: reduceMotion),
                    value: hasAppeared
                )
            VStack(spacing: 5) {
                Text("Open a video or add a folder")
                    .font(.title2.weight(.semibold))
                Text("MKV, MP4, MOV, M4V, WebM, AVI, TS, and M2TS")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(hasAppeared ? 1 : 0)
            .animation(
                IlliquidMotion.panelEntrance(
                    reduceMotion: reduceMotion,
                    delay: reduceMotion ? 0 : 0.035
                ),
                value: hasAppeared
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { openButtons }
                VStack(spacing: 10) { openButtons }
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(
                IlliquidMotion.panelEntrance(
                    reduceMotion: reduceMotion,
                    delay: reduceMotion ? 0 : 0.065
                ),
                value: hasAppeared
            )
        }
        .padding(30)
        .foregroundStyle(theme.primaryColor)
        .onAppear {
            hasAppeared = true
        }
    }

    @ViewBuilder private var openButtons: some View {
        Button(action: model.openFilePanel) {
            Text("Open File…").playerProminentButtonTextStyle()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        Button("Add Folder…", action: model.addSourceFoldersPanel)
            .buttonStyle(.bordered)
    }
}

private struct EmptyPlayerPresentation: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.state.currentSource == nil {
                EmptyPlayerView(model: model)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(model.state.currentSource == nil)
        .animation(
            IlliquidMotion.majorContext(reduceMotion: reduceMotion),
            value: model.state.currentSource == nil
        )
    }
}

struct PlaybackTitlebarAccessoryView: View {
    @Bindable var model: AppModel
    @Bindable var themeStore: PlayerThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        model.isPlaybackChromeVisible
    }

    private var sourceTitle: String {
        model.state.currentSource?.url.deletingPathExtension().lastPathComponent ?? ""
    }

    private var chapterTitle: String? {
        guard let chapterID = model.state.currentChapterID else { return nil }
        return model.state.chapters.first(where: { $0.id == chapterID })?.title
    }

    private var identity: String {
        [
            model.openVideoTabs.selectedID?.uuidString ?? "",
            model.openVideoTabs.items.map { "\($0.id):\($0.title)" }.joined(separator: "|"),
            sourceTitle,
            chapterTitle ?? "",
            model.activeSourceTabID ?? "",
            model.sourceTabs.map {
                "\($0.id):\($0.displayName):\($0.items.count)"
            }.joined(separator: "|"),
            model.isSidebarPresented ? "sidebar-visible" : "sidebar-hidden",
        ].joined(separator: "|")
    }

    var body: some View {
        HStack(spacing: 10) {
            if !model.openVideoTabs.items.isEmpty {
                OpenVideoTabBar(model: model)
                    .background {
                        TitlebarInteractiveRegion().accessibilityHidden(true)
                    }
            } else if model.state.currentSource != nil {
                HStack(spacing: 6) {
                    Text(sourceTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)

                    if let chapterTitle, !chapterTitle.isEmpty {
                        Text("— \(chapterTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        // The native title bar is an opaque dark surface, not part of the video.
        .foregroundStyle(themeStore.selection.primaryColor,
            themeStore.selection.secondaryColor, themeStore.selection.secondaryColor)
        .environment(\.playerTheme, themeStore.selection)
        .environment(\.playerTextColorMode, themeStore.textColorMode)
        .environment(\.playerRainbowPalette, themeStore.rainbowPalette)
        .environment(\.colorScheme, themeStore.selection.preferredColorScheme)
        .tint(themeStore.selection.accentColor)
        .opacity(
            isVisible ? 1 : 0
        )
        .offset(
            y: isVisible
                ? 0
                : IlliquidMotion.offset(
                    -IlliquidMotion.Distance.topChrome,
                    reduceMotion: reduceMotion
                )
        )
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(
            IlliquidMotion.softEntrance(reduceMotion: reduceMotion),
            value: identity
        )
        .animation(
            isVisible
                ? IlliquidMotion.panelEntrance(reduceMotion: reduceMotion, delay: 0.015)
                : IlliquidMotion.quietExit(reduceMotion: reduceMotion),
            value: isVisible
        )
        .accessibilityElement(children: .contain)
    }
}
