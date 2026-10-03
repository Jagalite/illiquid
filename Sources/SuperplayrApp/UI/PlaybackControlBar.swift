import AVKit
import AppKit
import SwiftUI
import SuperplayrCore

struct PlaybackControlBar: View {
    @Bindable var model: AppModel
    @State private var isVolumePopoverPresented = false
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerTheme) private var theme

    var body: some View {
        controlRow
        .dynamicPlayerTextStyle(contrastRegion: .bottom)
        .onChange(of: isVolumePopoverPresented) { _, _ in
            model.setChromePin(.volumePopover, active: isVolumePopoverPresented)
            model.setTransientPresentation(isVolumePopoverPresented, owner: "legacy-volume")
        }
        .onDisappear {
            if isVolumePopoverPresented {
                model.setChromePin(.volumePopover, active: false)
                model.setTransientPresentation(false, owner: "legacy-volume")
            }
            model.setChromePin(.pointerOverChrome, active: false)
            model.setChromePin(.transientPresentation, active: false)
        }
        .environment(\.colorScheme, theme.preferredColorScheme)
    }

    private var controlRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 0) {
                PlaybackTimeline(model: model)

                utilityIsland
                    .padding(.trailing, 6)
                    .dynamicPlayerTextStyle()
            }
            .frame(height: 56)
            .playerGlassGroup(
                id: .timelineControls,
                namespace: glassNamespace,
                cornerRadius: 24
            )
        }
        .frame(maxWidth: 940)
    }

    private var utilityIsland: some View {
        HStack(spacing: 0) {
            Button {
                isVolumePopoverPresented.toggle()
            } label: {
                compactMenuLabel(
                    model.state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: "Volume",
                    animatesSymbolReplacement: true
                )
            }
            .buttonStyle(.borderless)
            .help("Volume")
            .accessibilityLabel("Volume")
            .popover(isPresented: $isVolumePopoverPresented, arrowEdge: .bottom) {
                VolumePopover(model: model)
                    .background(PopoverDismissalBoundary { isVolumePopoverPresented = false })
            }

            Menu {
                if model.state.audioTracks.isEmpty {
                    Text("No audio tracks")
                } else {
                    ForEach(model.state.audioTracks) { track in
                        Button {
                            model.selectAudioTrackFromUser(track)
                        } label: {
                            trackLabel(track, selected: track.id == model.state.selectedAudioTrack?.id)
                        }
                    }
                }
            } label: {
                compactMenuLabel("waveform", title: "Audio Track")
            }
            .buttonStyle(.borderless)
            .help("Audio Track")
            .accessibilityLabel("Audio Track")

            Menu {
                Button {
                    model.selectSubtitleTrackFromUser(nil)
                } label: {
                    menuSelectionLabel("Off", selected: model.state.selectedSubtitleTrack == nil)
                }
                Divider()
                ForEach(model.state.subtitleTracks) { track in
                    Button {
                        model.selectSubtitleTrackFromUser(track)
                    } label: {
                        trackLabel(track, selected: track.id == model.state.selectedSubtitleTrack?.id)
                    }
                }
                Divider()
                Section("Timing for This Video") {
                    Text("Current: \(SubtitleDelayInput.displayText(for: model.state.subtitleDelay))")
                    Button("Set Subtitle Delay…", action: model.openSubtitleDelayPanel)
                    Button("Reset Subtitle Delay") {
                        model.setSubtitleDelayFromUser(0)
                    }
                    .disabled(abs(model.state.subtitleDelay) < 0.001)
                }
                Divider()
                Button("Load External Subtitle…", action: model.openSubtitlePanel)
            } label: {
                compactMenuLabel("captions.bubble", title: "Subtitles")
                    .playbackControlSelectionTint(
                        SubtitleControlVisualState(
                            selectedTrack: model.state.selectedSubtitleTrack
                        ).usesAccentTint,
                        accent: theme.accentColor
                    )
            }
            .buttonStyle(.borderless)
            .help("Subtitles")
            .accessibilityLabel("Subtitles")
            .accessibilityValue(SubtitleControlVisualState(
                selectedTrack: model.state.selectedSubtitleTrack
            ).accessibilityValue)

            iconButton(
                SidebarToggleControlPolicy.title(
                    isSidebarVisible: model.isSidebarPresented
                ),
                systemImage: "sidebar.left"
            ) {
                model.toggleSidebar()
            }
            .disabled(!model.isSidebarAvailable)
            .help(model.isSidebarAvailable ? "Sources" : "Widen the window to show Sources")

            if model.canTogglePictureInPicture {
                iconButton(
                    model.state.pictureInPicture.isActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture",
                    image: Image(nsImage: model.state.pictureInPicture.isActive
                        ? AVPictureInPictureController.pictureInPictureButtonStopImage
                        : AVPictureInPictureController.pictureInPictureButtonStartImage)
                ) {
                    model.togglePictureInPicture()
                }
            }

            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .frame(width: 30, height: 38)
                    .contentShape(Circle())
                    .playerIconHoverEffect(
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                        highlightInsets: PlayerControlHoverPolicy.bottomIslandHighlightInsets
                    )
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")

            Menu {
                if !model.state.chapters.isEmpty {
                    Section("Chapters") {
                        ForEach(model.state.chapters) { chapter in
                            Button {
                                model.player.selectChapter(chapter)
                            } label: {
                                menuSelectionLabel(
                                    chapter.title ?? "Chapter \(chapter.id + 1)",
                                    selected: chapter.id == model.state.currentChapterID
                                )
                            }
                        }
                    }
                    Divider()
                }

                Button("Fit Window to Video", action: model.fitWindowToVideo)
                    .disabled(!model.canFitWindowToVideo)

                if model.player.supports(.saveScreenshot) {
                    Button("Save Screenshot…", action: model.saveScreenshot)
                        .disabled(model.state.currentSource == nil)
                }

                Button("Playback Inspector…") {
                    model.isInspectorPresented = true
                }

                Divider()

                if model.player.supports(.changePlaybackSpeed) {
                    Section("Playback Speed") {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                            Button {
                                model.player.setPlaybackSpeed(speed)
                            } label: {
                                menuSelectionLabel(
                                    String(format: "%g×", speed),
                                    selected: abs(model.state.playbackSpeed - speed) < 0.001
                                )
                            }
                        }
                    }
                }

                Section("Track Sync") {
                    if model.player.supports(.changeAudioDelay) {
                        Button("Audio −0.1 s") {
                            model.player.setAudioDelay(model.state.audioDelay - 0.1)
                        }
                        Button("Reset Audio Delay") {
                            model.player.setAudioDelay(0)
                        }
                        .disabled(abs(model.state.audioDelay) < 0.001)
                        Button("Audio +0.1 s") {
                            model.player.setAudioDelay(model.state.audioDelay + 0.1)
                        }

                        Divider()
                    }

                    if model.player.supports(.changeSubtitleDelay) {
                        Text(
                            "Subtitle Delay: \(SubtitleDelayInput.displayText(for: model.state.subtitleDelay))"
                        )
                        Button("Set Subtitle Delay…", action: model.openSubtitleDelayPanel)
                        Button("Reset Subtitle Delay") {
                            model.setSubtitleDelayFromUser(0)
                        }
                        .disabled(abs(model.state.subtitleDelay) < 0.001)
                    }
                }
            } label: {
                compactMenuLabel("ellipsis", title: "More Playback Controls")
            }
            .buttonStyle(.borderless)
            .help("More Playback Controls")
            .accessibilityLabel("More Playback Controls")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: 46)
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        iconButton(
            title,
            image: Image(systemName: systemImage),
            action: action
        )
    }

    private func iconButton(
        _ title: String,
        image: Image,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            image
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 17, height: 17)
                .frame(width: 30, height: 38)
                .contentShape(Circle())
                .playerIconHoverEffect(
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                    highlightInsets: PlayerControlHoverPolicy.bottomIslandHighlightInsets
                )
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private func compactMenuLabel(
        _ systemImage: String,
        title: String,
        animatesSymbolReplacement: Bool = false
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .contentTransition(
                animatesSymbolReplacement ? .symbolEffect(.replace) : .identity
            )
            .animation(
                animatesSymbolReplacement
                    ? PlatinumMotion.stateMorph(reduceMotion: reduceMotion)
                    : nil,
                value: systemImage
            )
            .frame(width: 30, height: 38)
            .contentShape(Rectangle())
            .playerIconHoverEffect(
                in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                highlightInsets: PlayerControlHoverPolicy.bottomIslandHighlightInsets
            )
            .accessibilityLabel(title)
    }

    private func trackLabel(_ track: MediaTrack, selected: Bool) -> some View {
        menuSelectionLabel(track.displayName, selected: selected)
    }

    private func menuSelectionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Image(systemName: "checkmark")
                .opacity(selected ? 1 : 0)
            Text(title)
        }
    }
}

enum SidebarToggleControlPolicy {
    static func title(isSidebarVisible: Bool) -> String {
        isSidebarVisible ? "Hide Sources" : "Show Sources"
    }
}

enum SubtitleControlVisualState: Equatable {
    case off
    case active

    init(selectedTrack: MediaTrack?) {
        self = selectedTrack == nil ? .off : .active
    }

    var usesAccentTint: Bool { self == .active }

    var accessibilityValue: String {
        switch self {
        case .off: "Off"
        case .active: "On"
        }
    }
}

private struct PlaybackControlSelectionTintModifier: ViewModifier {
    let isSelected: Bool
    let accent: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .foregroundStyle(accent)
                .tint(accent)
        } else {
            content
        }
    }
}

extension View {
    func playbackControlSelectionTint(
        _ isSelected: Bool,
        accent: Color
    ) -> some View {
        modifier(PlaybackControlSelectionTintModifier(
            isSelected: isSelected,
            accent: accent
        ))
    }
}

/// Owns the only high-frequency playback-position dependency in the visible
/// chrome. Position ticks update this leaf without rebuilding the transport,
/// utility, or enclosing glass-container view graphs.
private struct PlaybackTimeline: View {
    let model: AppModel

    @State private var isScrubbing = false
    @Environment(\.playerTheme) private var theme

    var body: some View {
        PlaybackTimelineContent(
            model: model,
            isScrubbing: $isScrubbing,
            theme: theme
        )
        .padding(.horizontal, 14)
        .frame(minWidth: 260, maxWidth: .infinity)
        .frame(height: 56)
        .layoutPriority(1)
    }
}

/// Hosts the complete timeline content in one persistent AppKit leaf. Passive
/// position samples update the native label and slider directly, so the 5 Hz
/// display cadence does not open a SwiftUI/AttributeGraph transaction across
/// the surrounding Liquid Glass chrome.
@MainActor
private struct PlaybackTimelineContent: NSViewRepresentable {
    let model: AppModel
    @Binding var isScrubbing: Bool
    let theme: PlayerTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, isScrubbing: $isScrubbing)
    }

    func makeNSView(context: Context) -> PlaybackTimelineNativeView {
        let timeline = PlaybackTimelineNativeView()
        timeline.delegate = context.coordinator
        timeline.configure(
            source: model.state.currentSource,
            duration: model.state.duration,
            phase: model.state.phase,
            chapters: model.state.chapters,
            bufferStatus: model.state.bufferStatus,
            isObservationActive: model.isUIObservationActive,
            theme: theme
        )
        return timeline
    }

    func updateNSView(_ timeline: PlaybackTimelineNativeView, context: Context) {
        timeline.delegate = context.coordinator
        timeline.configure(
            source: model.state.currentSource,
            duration: model.state.duration,
            phase: model.state.phase,
            chapters: model.state.chapters,
            bufferStatus: model.state.bufferStatus,
            isObservationActive: model.isUIObservationActive,
            theme: theme
        )
    }

    static func dismantleNSView(
        _ timeline: PlaybackTimelineNativeView,
        coordinator: Coordinator
    ) {
        _ = coordinator
        timeline.shutdown()
    }

    @MainActor
    final class Coordinator: NSObject, PlaybackTimelineNativeViewDelegate {
        let model: AppModel
        let isScrubbing: Binding<Bool>

        init(model: AppModel, isScrubbing: Binding<Bool>) {
            self.model = model
            self.isScrubbing = isScrubbing
        }

        var currentPosition: Double {
            model.state.position
        }

        func timelineDidChangeScrubbing(_ editing: Bool) {
            isScrubbing.wrappedValue = editing
            model.setChromePin(.scrubbing, active: editing)
        }

        func timelinePreviewSeek(to position: Double) {
            model.player.previewSeek(to: position)
        }

        func timelineCommitSeek(to position: Double) {
            model.player.seek(to: position)
            model.registerUserActivity()
        }
    }
}

@MainActor
private protocol PlaybackTimelineNativeViewDelegate: AnyObject {
    var currentPosition: Double { get }
    func timelineDidChangeScrubbing(_ editing: Bool)
    func timelinePreviewSeek(to position: Double)
    func timelineCommitSeek(to position: Double)
}

@MainActor
enum PlaybackTimelineStyle {
    static let progressColor = NSColor(
        srgbRed: 0.78,
        green: 0.80,
        blue: 0.82,
        alpha: 1
    )

    static func progressColor(for theme: PlayerTheme) -> NSColor {
        theme == .liquidGlass ? progressColor : theme.appKitAccentColor
    }
}

@MainActor
private final class PlaybackTimelineNativeView: NSView {
    weak var delegate: PlaybackTimelineNativeViewDelegate?

    private let elapsedLabel = FixedTimelineTimeLabel(alignment: .left)
    private let durationLabel = FixedTimelineTimeLabel(alignment: .right)
    private let bufferLayer = CALayer()
    private var chapterLayers: [CALayer] = []
    private var chapterMarkerTimes: [Double] = []
    private let hoverGlassView = NSGlassEffectView()
    private let hoverLabel = FixedTimelineTimeLabel(alignment: .center)
    private lazy var slider: TrackingNSSlider = {
        let slider = TrackingNSSlider(
            value: 0,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(sliderValueChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.setAccessibilityLabel("Playback position")
        slider.onEditingChanged = { [weak self] editing in
            self?.handleEditingChanged(editing)
        }
        slider.onScroll = { [weak self] event in
            self?.handleTimelineScroll(event)
        }
        return slider
    }()

    private var source: MediaSource?
    private var duration: Double = 0
    private var phase: PlaybackPhase = .idle
    private var chapters: [Chapter] = []
    private var bufferStatus: BufferStatus = .empty
    private var isObservationActive = true
    private var theme = PlayerTheme.liquidGlass
    private var showsRemainingDuration = false
    private var isScrubbing = false
    private var hoverTransitionGeneration = 0
    private var emphasizedChapterIndex: Int?
    private var lastHoverX: CGFloat?
    private var timelineTrackingArea: NSTrackingArea?
    private var positionRefreshTask: Task<Void, Never>?
    private var scrubSeekTask: Task<Void, Never>?
    private var pendingScrubPosition: Double?
    private var scrollTarget: Double?
    private var scrollPointRemainder: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopPositionRefresh()
            cancelScrubbing()
        } else {
            startPositionRefresh()
        }
    }

    func configure(
        source: MediaSource?,
        duration: Double,
        phase: PlaybackPhase,
        chapters: [Chapter],
        bufferStatus: BufferStatus,
        isObservationActive: Bool,
        theme: PlayerTheme
    ) {
        let sourceChanged = self.source != source
        let chaptersChanged = self.chapters != chapters
        let bufferChanged = self.bufferStatus != bufferStatus
        let themeChanged = self.theme != theme
        self.source = source
        self.duration = duration
        self.phase = phase
        self.chapters = chapters
        self.bufferStatus = bufferStatus
        self.isObservationActive = isObservationActive
        self.theme = theme

        let upperBound = max(1, duration)
        if slider.maxValue != upperBound {
            slider.maxValue = upperBound
        }
        let isEnabled = duration > 0
        if slider.isEnabled != isEnabled {
            slider.setPlaybackEnabled(isEnabled)
        }

        if themeChanged {
            applyTheme()
        }
        refreshDisplayedPosition()
        if sourceChanged || chaptersChanged || bufferChanged || themeChanged {
            needsLayout = true
        }
        if PlaybackTimelineInteraction.shouldRefreshContinuously(
            phase: phase,
            isObservationActive: isObservationActive
        ), window != nil {
            startPositionRefresh()
        } else {
            stopPositionRefresh()
        }
    }

    func shutdown() {
        stopPositionRefresh()
        cancelScrubbing()
        delegate = nil
    }

    private func configureViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        bufferLayer.backgroundColor = PlaybackTimelineStyle.progressColor(for: theme)
            .withAlphaComponent(0.22).cgColor
        bufferLayer.cornerRadius = 1
        bufferLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
        ]
        layer?.addSublayer(bufferLayer)

        let labelFont = Self.timelineFont()
        for label in [elapsedLabel, durationLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = labelFont
            label.textColor = theme.appKitSecondaryColor
        }
        slider.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.onPress = { [weak self] in
            guard let self else { return }
            showsRemainingDuration.toggle()
            refreshDisplayedPosition()
        }
        durationLabel.setAccessibilityHelp("Press to toggle total and remaining time")

        hoverGlassView.translatesAutoresizingMaskIntoConstraints = true
        hoverGlassView.style = .regular
        hoverGlassView.cornerRadius = 10
        hoverGlassView.isHidden = true
        hoverGlassView.setAccessibilityElement(false)

        hoverLabel.translatesAutoresizingMaskIntoConstraints = false
        hoverLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hoverLabel.textColor = theme.appKitPrimaryColor
        hoverLabel.setAccessibilityElement(false)
        hoverGlassView.contentView = hoverLabel

        addSubview(elapsedLabel)
        addSubview(slider)
        addSubview(durationLabel)
        addSubview(hoverGlassView)
        applyTheme()

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            elapsedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 52),
            slider.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 12),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            durationLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 12),
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func applyTheme() {
        let progressColor = PlaybackTimelineStyle.progressColor(for: theme)
        bufferLayer.backgroundColor = progressColor.withAlphaComponent(0.22).cgColor
        elapsedLabel.textColor = theme.appKitSecondaryColor
        durationLabel.textColor = theme.appKitSecondaryColor
        hoverLabel.textColor = theme.appKitPrimaryColor
        slider.applyTheme(theme)
        for marker in chapterLayers {
            marker.backgroundColor = theme.appKitPrimaryColor
                .withAlphaComponent(0.48).cgColor
        }
    }

    override func updateTrackingAreas() {
        if let timelineTrackingArea {
            removeTrackingArea(timelineTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        timelineTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        updateBufferLayer()
        updateChapterLayers()
    }

    override func mouseMoved(with event: NSEvent) {
        guard duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastHoverX = point.x
        let position = PlaybackTimelineInteraction.position(
            forX: point.x,
            sliderFrame: slider.frame,
            duration: duration
        )
        let chapterTitle = PlaybackTimelineInteraction.chapterTitle(
            at: position,
            chapters: chapters
        )
        hoverLabel.stringValue = [
            TimecodeFormatter.string(from: position),
            chapterTitle,
        ].compactMap(\.self).joined(separator: "  •  ")
        let labelWidth = hoverLabel.cell?.cellSize.width ?? 40
        let width = min(max(labelWidth + 14, 54), max(54, bounds.width))
        let targetFrame = CGRect(
            x: min(max(point.x - width / 2, 0), max(0, bounds.width - width)),
            y: slider.frame.maxY + 1,
            width: width,
            height: 20
        )
        let wasHidden = hoverGlassView.isHidden
        updateEmphasizedChapter(at: point.x)
        revealHoverLabelIfNeeded(targetFrame: targetFrame)
        if !wasHidden {
            hoverGlassView.frame = targetFrame
        }
    }

    override func mouseExited(with event: NSEvent) {
        lastHoverX = nil
        updateEmphasizedChapter(at: nil)
        dismissHoverLabel()
        super.mouseExited(with: event)
    }

    private func revealHoverLabelIfNeeded(targetFrame: CGRect) {
        guard hoverGlassView.isHidden else { return }
        hoverTransitionGeneration += 1
        hoverGlassView.isHidden = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hoverGlassView.alphaValue = 0
        hoverGlassView.frame = reduceMotion
            ? targetFrame
            : targetFrame.offsetBy(dx: 0, dy: -4)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PlatinumMotion.Duration.control
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverGlassView.animator().alphaValue = 1
            if !reduceMotion {
                hoverGlassView.animator().frame = targetFrame
            }
        }
    }

    private func dismissHoverLabel() {
        guard !hoverGlassView.isHidden else { return }
        hoverTransitionGeneration += 1
        let generation = hoverTransitionGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            hoverGlassView.alphaValue = 0
            hoverGlassView.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PlatinumMotion.Duration.quietExit
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverGlassView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hoverTransitionGeneration == generation else {
                    return
                }
                self.hoverGlassView.isHidden = true
            }
        }
    }

    private func updateEmphasizedChapter(at x: CGFloat?) {
        let newIndex: Int?
        if let x, slider.frame.width > 0, duration > 0 {
            newIndex = chapterMarkerTimes.indices.min { lhs, rhs in
                let lhsX = slider.frame.minX
                    + slider.frame.width * CGFloat(chapterMarkerTimes[lhs] / duration)
                let rhsX = slider.frame.minX
                    + slider.frame.width * CGFloat(chapterMarkerTimes[rhs] / duration)
                return abs(lhsX - x) < abs(rhsX - x)
            }.flatMap { index in
                let markerX = slider.frame.minX
                    + slider.frame.width * CGFloat(chapterMarkerTimes[index] / duration)
                return abs(markerX - x) <= 7 ? index : nil
            }
        } else {
            newIndex = nil
        }
        guard newIndex != emphasizedChapterIndex else { return }
        emphasizedChapterIndex = newIndex
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        for (index, marker) in chapterLayers.enumerated() {
            let emphasized = index == newIndex
            let opacity: Float = emphasized ? 0.9 : 0.48
            let transform = emphasized && !reduceMotion
                ? CATransform3DMakeScale(1.8, 1.15, 1)
                : CATransform3DIdentity
            if !reduceMotion {
                let opacityAnimation = CABasicAnimation(keyPath: "opacity")
                opacityAnimation.fromValue = marker.presentation()?.opacity ?? marker.opacity
                opacityAnimation.toValue = opacity
                opacityAnimation.duration = PlatinumMotion.Duration.micro
                marker.add(opacityAnimation, forKey: "chapterOpacity")

                let scaleAnimation = CABasicAnimation(keyPath: "transform")
                scaleAnimation.fromValue = marker.presentation()?.transform ?? marker.transform
                scaleAnimation.toValue = transform
                scaleAnimation.duration = PlatinumMotion.Duration.micro
                marker.add(scaleAnimation, forKey: "chapterScale")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            marker.opacity = opacity
            marker.transform = transform
            CATransaction.commit()
        }
    }

    private static func timelineFont() -> NSFont {
        let system = NSFont.systemFont(ofSize: 14, weight: .regular)
        let roundedDescriptor = system.fontDescriptor.withDesign(.rounded)
            ?? system.fontDescriptor
        let monospacedDigits = roundedDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]
        ])
        return NSFont(descriptor: monospacedDigits, size: 14) ?? system
    }

    private func startPositionRefresh() {
        guard PlaybackTimelineInteraction.shouldRefreshContinuously(
            phase: phase,
            isObservationActive: isObservationActive
        ) else { return }
        guard positionRefreshTask == nil else { return }
        refreshDisplayedPosition()
        positionRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlaybackChromeRefreshPolicy.timelinePositionInterval)
                guard !Task.isCancelled, let self else { return }
                self.refreshDisplayedPosition()
            }
        }
    }

    private func stopPositionRefresh() {
        positionRefreshTask?.cancel()
        positionRefreshTask = nil
    }

    private func refreshDisplayedPosition() {
        guard !isScrubbing, let position = delegate?.currentPosition else { return }
        if slider.passiveValue != position {
            slider.setPassiveValue(position)
        }
        updateElapsedLabel(position)
        updateDurationLabel(position)
    }

    @objc
    private func sliderValueChanged(_ sender: TrackingNSSlider) {
        let position = sender.doubleValue
        updateElapsedLabel(position)
        if sender.isTrackingMouse {
            scheduleScrubSeek(to: position)
        } else {
            handleEditingChanged(true)
            scheduleScrubSeek(to: position)
            handleEditingChanged(false)
        }
    }

    private func handleEditingChanged(_ editing: Bool) {
        guard editing != isScrubbing else { return }
        isScrubbing = editing
        delegate?.timelineDidChangeScrubbing(editing)
        guard !editing else { return }

        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubPosition = nil
        delegate?.timelineCommitSeek(to: slider.doubleValue)
    }

    private func cancelScrubbing() {
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubPosition = nil
        scrollTarget = nil
        scrollPointRemainder = 0
        guard isScrubbing else { return }
        isScrubbing = false
        delegate?.timelineDidChangeScrubbing(false)
    }

    private func scheduleScrubSeek(to position: Double) {
        pendingScrubPosition = position
        guard scrubSeekTask == nil else { return }

        sendPendingScrubSeek()
        scrubSeekTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // The backend coalesces preview requests until a frame is
                // available. A 30 Hz cadence tracks the pointer closely while
                // avoiding needless main-actor and demux pressure.
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self else { return }
                guard self.pendingScrubPosition != nil else {
                    self.scrubSeekTask = nil
                    return
                }
                self.sendPendingScrubSeek()
            }
        }
    }

    private func handleTimelineScroll(_ event: NSEvent) {
        guard duration > 0 else { return }
        if event.momentumPhase != [], scrollTarget == nil {
            return
        }

        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        let threshold = event.hasPreciseScrollingDeltas ? 8.0 : 1.0
        scrollPointRemainder += delta
        let steps = (scrollPointRemainder / threshold).rounded(.towardZero)
        if steps != 0 {
            scrollPointRemainder.formTruncatingRemainder(dividingBy: threshold)
            if scrollTarget == nil {
                isScrubbing = true
                delegate?.timelineDidChangeScrubbing(true)
                scrollTarget = delegate?.currentPosition ?? slider.passiveValue
            }
            let target = min(max((scrollTarget ?? 0) + steps * 5, 0), duration)
            scrollTarget = target
            slider.setPassiveValue(target)
            updateElapsedLabel(target)
            delegate?.timelinePreviewSeek(to: target)
        }

        let isDiscrete = event.phase == [] && event.momentumPhase == []
        let didEnd = event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
        guard isDiscrete || didEnd, let target = scrollTarget else { return }
        scrollTarget = nil
        scrollPointRemainder = 0
        isScrubbing = false
        delegate?.timelineDidChangeScrubbing(false)
        delegate?.timelineCommitSeek(to: target)
    }

    private func sendPendingScrubSeek() {
        guard let position = pendingScrubPosition else { return }
        pendingScrubPosition = nil
        delegate?.timelinePreviewSeek(to: position)
    }

    private func updateElapsedLabel(_ position: Double) {
        let value = TimecodeFormatter.string(from: position)
        if elapsedLabel.stringValue != value {
            elapsedLabel.stringValue = value
        }
    }

    private func updateDurationLabel(_ position: Double) {
        let value = PlaybackTimelineInteraction.durationLabel(
            position: position,
            duration: duration,
            showsRemaining: showsRemainingDuration
        )
        if durationLabel.stringValue != value {
            durationLabel.stringValue = value
        }
        durationLabel.setAccessibilityLabel(
            showsRemainingDuration ? "Time remaining" : "Total duration"
        )
    }

    private func updateBufferLayer() {
        let fraction = PlaybackTimelineInteraction.bufferFraction(bufferStatus)
        bufferLayer.isHidden = fraction <= 0 || duration <= 0
        bufferLayer.frame = CGRect(
            x: slider.frame.minX,
            y: slider.frame.midY - 1,
            width: slider.frame.width * CGFloat(fraction),
            height: 2
        )
    }

    private func updateChapterLayers() {
        chapterLayers.forEach { $0.removeFromSuperlayer() }
        chapterLayers.removeAll(keepingCapacity: true)
        chapterMarkerTimes.removeAll(keepingCapacity: true)
        emphasizedChapterIndex = nil
        guard duration > 0, slider.frame.width > 0 else { return }

        for chapter in chapters where chapter.startTime > 0 && chapter.startTime < duration {
            let marker = CALayer()
            marker.backgroundColor = theme.appKitPrimaryColor
                .withAlphaComponent(0.48).cgColor
            marker.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "opacity": NSNull(),
                "transform": NSNull(),
            ]
            marker.frame = CGRect(
                x: slider.frame.minX
                    + slider.frame.width * CGFloat(chapter.startTime / duration),
                y: slider.frame.midY - 3,
                width: 1,
                height: 6
            )
            layer?.addSublayer(marker)
            chapterLayers.append(marker)
            chapterMarkerTimes.append(chapter.startTime)
        }
        if let lastHoverX {
            updateEmphasizedChapter(at: lastHoverX)
        }
    }
}

@MainActor
private final class FixedTimelineTimeLabel: NSTextField {
    var onPress: (() -> Void)?

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        stringValue = "0:00"
        self.alignment = alignment
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 52, height: super.intrinsicContentSize.height)
    }

    override func invalidateIntrinsicContentSize() {
        // Width and font are fixed by the timeline contract. A new timecode
        // therefore cannot affect layout and must not dirty window constraints.
    }

    override func mouseDown(with event: NSEvent) {
        if let onPress {
            onPress()
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class TrackingNSSlider: NSSlider {
    enum PresentationMode: Equatable {
        case native
        case passive
    }

    private enum RedrawPolicy: Equatable {
        case deferredLayout
        case immediateInteraction
    }

    private struct PassivePresentationAssets {
        let emptyTrack: CGImage
        let fullTrack: CGImage
        let knob: CGImage
        let knobFrame: NSRect
    }

    var onEditingChanged: ((Bool) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    private(set) var isTrackingMouse = false
    private(set) var passiveValue: Double = 0
    private(set) var presentationMode = PresentationMode.native

    private var presentationWidth: Double = 0
    private weak var nativeHostView: NSView?
    private var passivePresentation: PassiveTimelineSliderPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackFillColor = PlaybackTimelineStyle.progressColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        trackFillColor = PlaybackTimelineStyle.progressColor
    }

    func applyTheme(_ theme: PlayerTheme) {
        let color = PlaybackTimelineStyle.progressColor(for: theme)
        guard trackFillColor != color else { return }
        resetPassivePresentation()
        trackFillColor = color
        needsDisplay = true
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        resetPassivePresentation()
        isEnabled = enabled
    }

    func setPassiveValue(_ value: Double) {
        let clamped = min(maxValue, max(minValue, value))
        let valueChanged = passiveValue != clamped
        passiveValue = clamped
        if window?.firstResponder === self {
            // Preserve the native focus ring and keyboard/accessibility
            // presentation while the timeline itself is actively focused.
            if presentationMode == .passive {
                resetPassivePresentation(redrawPolicy: .immediateInteraction)
            }
            super.doubleValue = clamped
            return
        }
        guard valueChanged || presentationMode != .passive else { return }
        guard preparePassivePresentation() else {
            super.doubleValue = clamped
            return
        }
        updatePassivePresentationFraction()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            resetPassivePresentation(redrawPolicy: .immediateInteraction)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            restorePassivePresentation()
        }
        return resignedFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        synchronizeBackingValueForInteraction()
        isTrackingMouse = true
        onEditingChanged?(true)
        super.mouseDown(with: event)
        synchronizePassiveValueAfterInteraction()
        onEditingChanged?(false)
        isTrackingMouse = false
    }

    override func keyDown(with event: NSEvent) {
        synchronizeBackingValueForInteraction()
        super.keyDown(with: event)
        synchronizePassiveValueAfterInteraction()
    }

    override func scrollWheel(with event: NSEvent) {
        if isEnabled, let onScroll {
            onScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isTrackingMouse ? super.doubleValue : passiveValue)
    }

    override func accessibilityPerformIncrement() -> Bool {
        synchronizeBackingValueForInteraction()
        let performed = super.accessibilityPerformIncrement()
        synchronizePassiveValueAfterInteraction()
        return performed
    }

    override func accessibilityPerformDecrement() -> Bool {
        synchronizeBackingValueForInteraction()
        let performed = super.accessibilityPerformDecrement()
        synchronizePassiveValueAfterInteraction()
        return performed
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard isEnabled, let number = accessibilityValue as? NSNumber else {
            super.setAccessibilityValue(accessibilityValue)
            return
        }
        let value = min(maxValue, max(minValue, number.doubleValue))
        guard value != passiveValue else { return }

        synchronizeBackingValueForInteraction()
        super.doubleValue = value
        synchronizePassiveValueAfterInteraction()
        _ = sendAction(action, to: target)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if bounds.size != newSize {
            // Geometry changes run inside AppKit's constraint/layout pass.
            // Invalidating the passive snapshot is safe here, but forcing a
            // synchronous display re-enters layout and recursively calls
            // setFrameSize until the main-thread stack overflows.
            resetPassivePresentation()
        }
        super.setFrameSize(newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resetPassivePresentation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resetPassivePresentation()
    }

    private func preparePassivePresentation() -> Bool {
        if presentationWidth == bounds.width,
           presentationMode == .passive,
           passivePresentation?.superview === self,
           nativeHostView?.isHidden == true {
            return true
        }

        resetPassivePresentation()
        guard bounds.width > 20, maxValue > minValue else { return false }

        // Keep the live control at the authoritative playback position. A
        // separate offscreen slider produces the endpoint artwork so AppKit
        // can never retain a full-track cache on the interactive control.
        super.doubleValue = passiveValue
        layoutSubtreeIfNeeded()
        guard let hostView = subviews.first,
              let assets = makePassivePresentationAssets() else {
            return false
        }

        let presentation = PassiveTimelineSliderPresentation(
            frame: bounds,
            emptyTrack: assets.emptyTrack,
            fullTrack: assets.fullTrack,
            knob: assets.knob,
            knobFrame: assets.knobFrame
        )
        presentation.autoresizingMask = [.width, .height]
        addSubview(presentation, positioned: .above, relativeTo: hostView)
        hostView.isHidden = true

        presentationWidth = bounds.width
        nativeHostView = hostView
        passivePresentation = presentation
        presentationMode = .passive
        return true
    }

    private func makePassivePresentationAssets() -> PassivePresentationAssets? {
        let snapshotWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: bounds.size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        snapshotWindow.appearance = effectiveAppearance

        let snapshotSlider = NSSlider(
            value: minValue,
            minValue: minValue,
            maxValue: maxValue,
            target: nil,
            action: nil
        )
        snapshotSlider.frame = NSRect(origin: .zero, size: bounds.size)
        snapshotSlider.controlSize = controlSize
        snapshotSlider.isEnabled = isEnabled
        snapshotSlider.isContinuous = isContinuous
        snapshotSlider.trackFillColor = trackFillColor
        snapshotWindow.contentView?.addSubview(snapshotSlider)
        snapshotWindow.contentView?.layoutSubtreeIfNeeded()
        snapshotSlider.layoutSubtreeIfNeeded()

        guard let hostView = snapshotSlider.subviews.first,
              let knobView = hostView.subviews.first else {
            return nil
        }
        knobView.isHidden = true
        guard let emptyTrack = Self.snapshot(
            view: snapshotSlider,
            rect: snapshotSlider.bounds
        ) else {
            return nil
        }

        snapshotSlider.doubleValue = maxValue
        snapshotSlider.layoutSubtreeIfNeeded()
        guard let fullTrack = Self.snapshot(
            view: snapshotSlider,
            rect: snapshotSlider.bounds
        ) else {
            return nil
        }
        knobView.isHidden = false
        guard let knob = Self.snapshot(view: knobView, rect: knobView.bounds) else {
            return nil
        }

        return PassivePresentationAssets(
            emptyTrack: emptyTrack,
            fullTrack: fullTrack,
            knob: knob,
            knobFrame: knobView.frame
        )
    }

    private func resetPassivePresentation(
        redrawPolicy: RedrawPolicy = .deferredLayout
    ) {
        passivePresentation?.removeFromSuperview()
        super.doubleValue = min(maxValue, max(minValue, passiveValue))
        let cachedHostView = nativeHostView
        let currentHostView = subviews.first
        cachedHostView?.isHidden = false
        cachedHostView?.needsDisplay = true
        if currentHostView !== cachedHostView {
            // AppKit can replace NSSlider's private host while SwiftUI detaches
            // and remounts the playback chrome. The passive presentation hid
            // the previous host, so always recover the current one as well or
            // the track can return with no native knob.
            currentHostView?.isHidden = false
            currentHostView?.needsDisplay = true
        }
        if cachedHostView != nil || currentHostView != nil {
            needsDisplay = true
        }
        presentationWidth = 0
        nativeHostView = nil
        passivePresentation = nil
        presentationMode = .native

        // Interaction and focus changes occur outside constraint layout and
        // must reveal a fully current native control immediately. Geometry
        // invalidation deliberately stays deferred to avoid re-entering
        // setFrameSize from AppKit's display/layout machinery.
        if redrawPolicy == .immediateInteraction {
            displayIfNeeded()
        }
    }

    private func synchronizeBackingValueForInteraction() {
        super.doubleValue = passiveValue
        resetPassivePresentation(redrawPolicy: .immediateInteraction)
    }

    private func synchronizePassiveValueAfterInteraction() {
        passiveValue = super.doubleValue
        resetPassivePresentation(redrawPolicy: .immediateInteraction)
        if window?.firstResponder !== self {
            restorePassivePresentation()
        }
    }

    private func restorePassivePresentation() {
        guard isEnabled, preparePassivePresentation() else { return }
        updatePassivePresentationFraction()
    }

    private func updatePassivePresentationFraction() {
        let range = maxValue - minValue
        let fraction = range > 0 ? (passiveValue - minValue) / range : 0
        passivePresentation?.setFraction(fraction)
    }

    private static func snapshot(view: NSView, rect: NSRect) -> CGImage? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: rect) else {
            return nil
        }
        view.cacheDisplay(in: rect, to: representation)
        return representation.cgImage
    }
}

@MainActor
private final class PassiveTimelineSliderPresentation: NSView {
    private let emptyTrackLayer = CALayer()
    private let fullTrackLayer = CALayer()
    private let knobLayer = CALayer()
    private let knobSize: NSSize
    private let knobY: Double

    init(
        frame: NSRect,
        emptyTrack: CGImage,
        fullTrack: CGImage,
        knob: CGImage,
        knobFrame: NSRect
    ) {
        knobSize = knobFrame.size
        knobY = knobFrame.origin.y
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = false
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        for (imageLayer, image) in [
            (emptyTrackLayer, emptyTrack),
            (fullTrackLayer, fullTrack),
            (knobLayer, knob),
        ] {
            imageLayer.contents = image
            imageLayer.contentsScale = scale
            imageLayer.contentsGravity = .resize
            imageLayer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "contentsRect": NSNull(),
            ]
        }
        emptyTrackLayer.frame = bounds
        fullTrackLayer.frame = bounds
        knobLayer.frame = knobFrame
        layer?.addSublayer(emptyTrackLayer)
        layer?.addSublayer(fullTrackLayer)
        layer?.addSublayer(knobLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        emptyTrackLayer.frame = bounds
    }

    func setFraction(_ value: Double) {
        let fraction = min(1, max(0, value))
        let knobX = fraction * max(0, bounds.width - knobSize.width)
        let fillWidth = knobX + knobSize.width / 2
        fullTrackLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: fillWidth,
            height: bounds.height
        )
        fullTrackLayer.contentsRect = CGRect(
            x: 0,
            y: 0,
            width: bounds.width > 0 ? fillWidth / bounds.width : 0,
            height: 1
        )
        knobLayer.frame = CGRect(
            x: knobX,
            y: knobY,
            width: knobSize.width,
            height: knobSize.height
        )
    }

}

enum PlaybackChromeRefreshPolicy {
    static let timelinePositionInterval = Duration.milliseconds(200)
    static let sourceProgressInterval = Duration.seconds(1)
}

enum PlaybackTimelineInteraction {
    static func shouldRefreshContinuously(
        phase: PlaybackPhase,
        isObservationActive: Bool
    ) -> Bool {
        isObservationActive && phase == .playing
    }

    static func position(forX x: CGFloat, sliderFrame: CGRect, duration: Double) -> Double {
        guard sliderFrame.width > 0, duration > 0 else { return 0 }
        let fraction = min(max((x - sliderFrame.minX) / sliderFrame.width, 0), 1)
        return duration * Double(fraction)
    }

    static func chapterTitle(at position: Double, chapters: [Chapter]) -> String? {
        chapters.last(where: { $0.startTime <= position })?.title
    }

    static func durationLabel(
        position: Double,
        duration: Double,
        showsRemaining: Bool
    ) -> String {
        guard showsRemaining else { return TimecodeFormatter.string(from: duration) }
        return "−" + TimecodeFormatter.string(from: max(0, duration - position))
    }

    static func bufferFraction(_ status: BufferStatus) -> Double {
        min(max((status.cachePercent ?? 0) / 100, 0), 1)
    }
}

struct PlaybackInspectorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    value("Phase", model.state.phase.rawValue)
                    value("Source", model.state.currentURL?.absoluteString ?? "None")
                    value("Source origin", model.state.currentSourceOrigin?.rawValue ?? "None")
                    value("Position", TimecodeFormatter.string(from: model.state.position))
                    value("Duration", TimecodeFormatter.string(from: model.state.duration))
                }

                Section("Video") {
                    let video = model.state.videoOutputStatus
                    value("Codec", video.codec ?? "Unknown")
                    value("Pixel format", video.pixelFormat ?? "Unknown")
                    value("Dimensions", dimensions(video))
                    value("Decoder", model.state.hardwareDecodingStatus.activeDecoder ?? "None")
                    value("Hardware decoded", video.isHardwareDecoded ? "Yes" : "No")
                    value("HDR", video.isHDR ? "Yes" : "No")
                    value("Primaries", video.colorPrimaries ?? "Unknown")
                    value("Transfer", video.transferFunction ?? "Unknown")
                    value(
                        "Filters",
                        model.state.activeVideoFilters.isEmpty
                            ? "None"
                            : model.state.activeVideoFilters.map(\.displayName).joined(separator: ", ")
                    )
                }

                Section("Display") {
                    let display = model.state.displayOutputStatus
                    value("Display", display.name ?? "Unknown")
                    value("Refresh ceiling", display.maximumFramesPerSecond.map { "\($0) fps" } ?? "Unknown")
                    value("Color space", display.colorSpaceName ?? "Unknown")
                    value("Potential EDR", String(format: "%.2f×", display.maximumPotentialEDR))
                    value("EDR headroom available", display.isEDREnabled ? "Yes" : "No")
                }

                Section("Buffer and Audio") {
                    let buffer = model.state.bufferStatus
                    value("Buffering", buffer.isBuffering ? "Yes" : "No")
                    value("Cache ahead", String(format: "%.1f s", buffer.cacheDuration))
                    value("Cache fill", buffer.cachePercent.map { String(format: "%.0f%%", $0) } ?? "Unknown")
                    value("Read speed", byteRate(buffer.bytesPerSecond))
                    value("Audio output", model.state.audioOutputDevice?.name ?? "System Default")
                    value("Audio tracks", "\(model.state.audioTracks.count)")
                    value("Subtitle tracks", "\(model.state.subtitleTracks.count)")
                    value("Chapters", "\(model.state.chapters.count)")
                }

                Section("Recent Diagnostics") {
                    if model.state.recentDiagnosticMessages.isEmpty {
                        Text("No warnings or errors recorded.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(
                            Array(model.state.recentDiagnosticMessages.enumerated()),
                            id: \.offset
                        ) { _, message in
                            Text(message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Playback Inspector")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosticReport, forType: .string)
                    }
                    .help("Copy the complete session report and recent diagnostics")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    private var diagnosticReport: String {
        let state = model.state
        let video = state.videoOutputStatus
        let display = state.displayOutputStatus
        let buffer = state.bufferStatus
        return [
            "Illiquid Playback Diagnostics — \(Date().ISO8601Format())",
            "Phase: \(state.phase.rawValue)",
            "Source: \(state.currentURL?.absoluteString ?? "None")",
            "Source origin: \(state.currentSourceOrigin?.rawValue ?? "None")",
            "Position: \(state.position) s / \(state.duration) s",
            "Video: \(video.codec ?? "Unknown"), \(video.pixelFormat ?? "Unknown"), \(dimensions(video))",
            "Decoder: \(state.hardwareDecodingStatus.activeDecoder ?? "None")",
            "Hardware decoded: \(video.isHardwareDecoded); HDR: \(video.isHDR)",
            "Primaries: \(video.colorPrimaries ?? "Unknown"); transfer: \(video.transferFunction ?? "Unknown")",
            "Filters: \(state.activeVideoFilters.map(\.displayName).joined(separator: ", "))",
            "Display: \(display.name ?? "Unknown"); refresh ceiling: \(display.maximumFramesPerSecond.map(String.init) ?? "Unknown") fps",
            "Color space: \(display.colorSpaceName ?? "Unknown")",
            "Potential EDR: \(display.maximumPotentialEDR); EDR available: \(display.isEDREnabled)",
            "Buffering: \(buffer.isBuffering); cache ahead: \(buffer.cacheDuration) s; cache fill: \(buffer.cachePercent.map { String($0) } ?? "Unknown")%",
            "Read speed: \(byteRate(buffer.bytesPerSecond))",
            "Audio output: \(state.audioOutputDevice?.name ?? "System Default")",
            "Audio track: \(state.selectedAudioTrack?.displayName ?? "Off") (\(state.audioTracks.count) available)",
            "Subtitle track: \(state.selectedSubtitleTrack?.displayName ?? "Off") (\(state.subtitleTracks.count) available)",
            "Subtitle delay: \(state.subtitleDelay) s",
            "Chapters: \(state.chapters.count)",
            "", "Recent Diagnostics:",
            state.recentDiagnosticMessages.isEmpty ? "No warnings or errors recorded."
                : state.recentDiagnosticMessages.joined(separator: "\n")
        ].joined(separator: "\n")
    }

    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled) }
    }

    private func dimensions(_ video: VideoOutputStatus) -> String {
        guard let width = video.pixelWidth, let height = video.pixelHeight else { return "Unknown" }
        return "\(width) × \(height)"
    }

    private func byteRate(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s"
    }
}

struct VolumePopover: View {
    @Bindable var model: AppModel
    @Environment(\.playerTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Volume")
                    .font(.headline)
                Spacer()
                Text("\(Int(model.state.volume.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    model.toggleMuteFromUser()
                } label: {
                    Image(systemName: model.state.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(model.state.isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { model.state.volume },
                        set: { model.setVolumeFromUser($0) }
                    ),
                    in: 0...100
                )
                .tint(theme.accentColor)
                .accessibilityLabel("Volume")
            }
        }
        .padding(14)
        .frame(width: 220)
        .dynamicPlayerTextStyle(contrastRegion: .bottom)
        .environment(\.colorScheme, theme.preferredColorScheme)
    }
}

enum TimecodeFormatter {
    static func string(from interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let totalSeconds = Int(interval.rounded(.down))
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
