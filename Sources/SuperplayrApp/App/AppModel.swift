import AppKit
import Observation
import SuperplayrCore
import SuperplayrPlayer
import SwiftUI
import UniformTypeIdentifiers

enum PlayerKeyboardAction: Equatable {
    case togglePause
    case seek(TimeInterval)
    case volume(Double)
    case stepFrame(Int)
    case chapter(Int)
    case undoSeek
    case dismiss
    case showShortcuts
    case showInspector
    case toggleFullscreen
    case toggleMute
    case goToTime
    case loopA
    case loopB
    case clearABLoop
    case screenshot

    static func resolve(
        keyCode: UInt16,
        characters: String? = nil,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Self? {
        var modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .function, .numericPad])

        // Letter/symbol shortcuts follow the active layout, matching the text
        // printed in Help. Navigation keys remain independent of layout.
        if !isRepeat {
            if characters == "?", modifiers.isSubset(of: [.shift, .option]) {
                return .showShortcuts
            }
            if modifiers.isEmpty {
                switch characters?.lowercased() {
                case "i": return .showInspector
                case "f": return .toggleFullscreen
                case "m": return .toggleMute
                default: break
                }
            }
        }

        switch keyCode {
        case 49 where modifiers.isEmpty && !isRepeat:
            return .togglePause
        case 123 where modifiers.isEmpty:
            return .seek(-5)
        case 124 where modifiers.isEmpty:
            return .seek(5)
        case 123 where modifiers == .shift:
            return .seek(-1)
        case 124 where modifiers == .shift:
            return .seek(1)
        case 123 where modifiers == .option:
            return .stepFrame(-1)
        case 124 where modifiers == .option:
            return .stepFrame(1)
        case 126 where modifiers.isEmpty:
            return .volume(5)
        case 125 where modifiers.isEmpty:
            return .volume(-5)
        case 126 where modifiers == .option:
            return .volume(1)
        case 125 where modifiers == .option:
            return .volume(-1)
        case 116 where modifiers.isEmpty && !isRepeat:
            return .chapter(-1)
        case 121 where modifiers.isEmpty && !isRepeat:
            return .chapter(1)
        case 116 where modifiers == .shift:
            return .seek(-600)
        case 121 where modifiers == .shift:
            return .seek(600)
        case 51 where modifiers == .shift && !isRepeat:
            return .undoSeek
        case 53 where modifiers.isEmpty && !isRepeat:
            return .dismiss
        default:
            return nil
        }
    }
}

enum PlayerKeyboardRouting {
    static func shouldDefer(
        action: PlayerKeyboardAction,
        firstResponder: NSResponder?,
        isPlaybackChromeVisible: Bool = true,
        isWindowFullscreen: Bool = false,
        isVoiceOverEnabled: Bool = false
    ) -> Bool {
        // VoiceOver navigation can forward plain keys while moving its own
        // cursor. Native accessibility actions and menu commands own that input.
        if isVoiceOverEnabled { return true }
        if action == .dismiss,
           isWindowFullscreen,
           !isPlaybackChromeVisible
        {
            return true
        }
        if firstResponder is NSTextView {
            return true
        }
        if firstResponder is NSControl, !(firstResponder is NSSlider) {
            return true
        }
        if firstResponder is NSSlider {
            switch action {
            case .seek, .volume, .stepFrame, .chapter:
                return true
            default:
                break
            }
        }
        return false
    }
}

enum PlayerKeyboardChromePolicy {
    static func shouldHideImmediately(
        action: PlayerKeyboardAction,
        isPauseDesired: Bool
    ) -> Bool {
        action == .togglePause
            && PlaybackToggleChromePolicy.shouldHideAfterActivation(
                isPauseDesired: isPauseDesired
            )
    }

    static func shouldRegisterActivity(
        action: PlayerKeyboardAction,
        areControlsVisible: Bool
    ) -> Bool {
        if case .seek = action {
            return areControlsVisible
        }
        return true
    }
}

enum PlaybackToggleChromePolicy {
    static let pointerRevealCooldown: TimeInterval = 0.25

    static func shouldHideAfterActivation(isPauseDesired: Bool) -> Bool {
        isPauseDesired
    }
}

enum SubtitleDelayInput {
    static let allowedMilliseconds = -10_000 ... 10_000

    static func seconds(fromMillisecondsText text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milliseconds = Int(trimmed),
              allowedMilliseconds.contains(milliseconds)
        else { return nil }
        return TimeInterval(milliseconds) / 1_000
    }

    static func millisecondsText(for seconds: TimeInterval) -> String {
        String(Int((seconds * 1_000).rounded()))
    }

    static func displayText(for seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1_000).rounded())
        return milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
    }
}

enum PlayerWindowPointerPolicy {
    static func isInsideWindow(
        locationInWindow: CGPoint,
        windowSize: CGSize
    ) -> Bool {
        CGRect(origin: .zero, size: windowSize).contains(locationInWindow)
    }

    static func isInsideWindow(
        mouseLocationOnScreen: CGPoint,
        windowFrame: CGRect
    ) -> Bool {
        windowFrame.contains(mouseLocationOnScreen)
    }

    static func isInsideWindow(
        locationInWindow: CGPoint,
        mouseLocationOnScreen: CGPoint,
        windowFrame: CGRect
    ) -> Bool {
        isInsideWindow(
            locationInWindow: locationInWindow,
            windowSize: windowFrame.size
        ) && isInsideWindow(
            mouseLocationOnScreen: mouseLocationOnScreen,
            windowFrame: windowFrame
        )
    }
}

@MainActor
@Observable
final class AppModel {
    private static var sharedInstance: AppModel?
    private static var sharedShutdownRequested = false
    private static var pendingStartupOpenRequests: [[URL]] = []
    private static let historyStartup = ReadOnlyStartupLoader {
        await Task.detached(priority: .userInitiated) {
            let timing = LifecyclePerformance.begin("history-load")
            defer { LifecyclePerformance.end("history-load", since: timing) }
            return PlaybackPersistenceStore()
        }.value
    }

    static func loadShared() async -> AppModel? {
        guard !sharedShutdownRequested else { return nil }
        if let sharedInstance { return sharedInstance }
        guard let persistence = await historyStartup.load(), !sharedShutdownRequested else { return nil }
        // Concurrent scene/delegate waiters share one model and native graph.
        if let sharedInstance { return sharedInstance }
        let timing = LifecyclePerformance.begin("model-init")
        let player: PlaybackController
        if LifecyclePerformance.isEnabled {
            let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_BENCHMARK_THUMBNAIL_CACHE"]
                .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            player = PlaybackController(persistence: persistence, thumbnailCacheDirectory: directory)
        } else {
            player = PlaybackController(persistence: persistence)
        }
        let model = AppModel(player: player)
        LifecyclePerformance.end("model-init", since: timing)
        sharedInstance = model
        let requests = pendingStartupOpenRequests
        pendingStartupOpenRequests.removeAll()
        for urls in requests { model.handleOpenURLs(urls) }
        return model
    }

    static func handleStartupOpenURLs(_ urls: [URL]) {
        guard !sharedShutdownRequested else { return }
        if let sharedInstance {
            sharedInstance.handleOpenURLs(urls)
            sharedInstance.reopenPlayerWindow()
        } else {
            pendingStartupOpenRequests.append(urls)
        }
    }

    static var keepsPlayingInPictureInPicture: Bool { sharedInstance?.state.pictureInPicture.isActive == true }

    static func shutdownShared() async -> String? {
        sharedShutdownRequested = true
        historyStartup.stop()
        pendingStartupOpenRequests.removeAll()
        await sharedInstance?.shutdown()
        return sharedInstance?.player.shutdownPersistenceError
    }

    let player: PlaybackController
    let thumbnailScheduler: ThumbnailBackgroundScheduler
    private let systemCoordinator: PlaybackSystemCoordinator
    private let nowPlayingCoordinator: NowPlayingCoordinator
    let osdPresenter = PlaybackOSDPresenter()
    @ObservationIgnored private let hidesSidebarForBenchmark: Bool
    private(set) var isWindowAspectLocked: Bool
    private(set) var isAlwaysOnTop: Bool
    private(set) var chromePhase: PlaybackChromePhase = .visible
    private(set) var isUIObservationActive = true
    private(set) var sourceTabs: [SourceTab] {
        didSet { sourceRootIndex.replace(tabs: sourceTabs) }
    }
    private let sourceRootIndex = SourceRootIndexStore()
    private(set) var activeSourceTabID: String?
    @ObservationIgnored var sourceNavigation = SourceNavigationState()
    var benchmarkTimelineHover: BenchmarkTimelineHover?
    var benchmarkSourceQuery: String?
    var isInspectorPresented = false
    let shortcutBindings = PlayerShortcutBindings()
    var isShortcutSettingsPresented = false
    var isShortcutHelpPresented = false
    var isGoToTimePresented = false
    var loopStart: TimeInterval?
    var loopEnd: TimeInterval?

    func setLoopStart() {
        guard state.currentSource != nil else { return }
        loopStart = state.position
        loopEnd = nil
        _ = player.setLoop(start: nil, end: nil)
    }

    func setLoopEnd() {
        guard let start = loopStart, state.position > start,
              player.setLoop(start: start, end: state.position) else { return }
        loopEnd = state.position
    }

    func clearLoop() {
        loopStart = nil; loopEnd = nil
        _ = player.setLoop(start: nil, end: nil)
    }
    var isMessageHistoryPresented = false

    @ObservationIgnored private var nowPlayingPositionTask: Task<Void, Never>?
    @ObservationIgnored private weak var playerWindow: NSWindow?
    @ObservationIgnored private weak var titlebarTitleView: NSView?
    @ObservationIgnored private var reopenPlayerWindowAction: (@MainActor () -> Void)?
    @ObservationIgnored private var pointerEventMonitor: Any?
    @ObservationIgnored private var globalPointerEventMonitor: Any?
    @ObservationIgnored private var keyboardEventMonitor: Any?
    @ObservationIgnored private var benchmarkPlaybackControl: BenchmarkPlaybackControl?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var didRestorePlaybackSession = false
    @ObservationIgnored private var pointerRevealGate = PointerRevealGate()
    @ObservationIgnored private var chromeMachine = PlaybackChromeStateMachine()
    @ObservationIgnored private var chromeScheduler: PlaybackChromeDeadlineScheduler?
    @ObservationIgnored private var cursorCoordinator = PlaybackCursorCoordinator()
    @ObservationIgnored private var cursorRegion = PlaybackCursorRegion.outside
    @ObservationIgnored private var transientOwners: Set<String> = []
    @ObservationIgnored private weak var presentationInvoker: NSResponder?
    private var hasTransientPresentation: Bool { !transientOwners.isEmpty }
    @ObservationIgnored private var playbackFocusOwners: Set<String> = []
    func setPlaybackFocus(_ active: Bool, owner: String) {
        if active { playbackFocusOwners.insert(owner) } else { playbackFocusOwners.remove(owner) }
        setChromePin(.playbackFocus, active: !playbackFocusOwners.isEmpty)
    }
    var interactionCancellationRevision: UInt64 = 0
    var controlsPositionRevision: UInt64 = 0
    var remembersPlaybackHistory: Bool {
        didSet { player.setRemembersPlaybackHistory(remembersPlaybackHistory) }
    }
    var restoresSessionPaused: Bool {
        didSet { player.setRestoresSessionPaused(restoresSessionPaused) }
    }
    var areControlsAlwaysVisible = UserDefaults.standard.bool(forKey: "Platinum.controls-always-visible") {
        didSet {
            UserDefaults.standard.set(areControlsAlwaysVisible, forKey: "Platinum.controls-always-visible")
            setChromePin(.alwaysVisible, active: areControlsAlwaysVisible)
        }
    }
    var isControlsPositionLocked = UserDefaults.standard.bool(forKey: "Platinum.controls-position-locked") {
        didSet {
            cancelActiveInteraction()
            UserDefaults.standard.set(isControlsPositionLocked, forKey: "Platinum.controls-position-locked")
        }
    }
    @ObservationIgnored private var surfaceScrollAccumulator = SurfaceScrollAccumulator()
    @ObservationIgnored private var seekInteractionAccumulator = SeekInteractionAccumulator()
    @ObservationIgnored private var keyboardSeekChromeSuppression =
        KeyboardSeekChromeSuppression()
    @ObservationIgnored private var keyboardSeekChromeSuppressionExpiryTask:
        Task<Void, Never>?
    @ObservationIgnored private var activeContextMenuTarget: PlayerContextMenuTarget?
    @ObservationIgnored private var lastObservedSource: MediaSource?
    @ObservationIgnored private var wasPictureInPictureActive = false
    @ObservationIgnored private var lastPlaybackLifecycleObservation:
        PlaybackLifecycleObservation?
    @ObservationIgnored private var launchOpenQueue = LaunchOpenQueue()
    @ObservationIgnored private var sourceItemPreparationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pictureInPictureRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var pictureInPictureRestoreGeneration = UUID()
    @ObservationIgnored private var pictureInPictureRestoreCompletion:
        (@Sendable (Bool) -> Void)?
    @ObservationIgnored private var isShuttingDown = false

    private init(player: PlaybackController) {
        self.player = player
        thumbnailScheduler = ThumbnailBackgroundScheduler(player: player)
        remembersPlaybackHistory = player.remembersPlaybackHistory
        restoresSessionPaused = player.restoresSessionPaused
        systemCoordinator = PlaybackSystemCoordinator(player: player)
        nowPlayingCoordinator = NowPlayingCoordinator(player: player)
        hidesSidebarForBenchmark = Self.benchmarkHidesSidebar()
        let defaults = UserDefaults.standard
        let legacySourceFolders = SourceFolderLibrary.restore(
            from: defaults.array(forKey: Self.sourceFoldersKey)
        )
        let restoredSourceTabs = SourceTabStore.restore(
            from: defaults.data(forKey: Self.sourceTabsKey)
        ) ?? SourceTabs.migrating(legacySourceFolders)
        sourceTabs = restoredSourceTabs
        let migratedSelection = defaults.string(forKey: Self.activeSourceFolderKey)
            .flatMap { SourceTabs.migratedTabID(forFolderID: $0) }
        activeSourceTabID = SourceTabs.resolvedSelection(
            defaults.string(forKey: Self.activeSourceTabKey) ?? migratedSelection,
            in: restoredSourceTabs
        )
        isWindowAspectLocked = defaults.object(forKey: Self.windowAspectLockKey) as? Bool
            ?? true
        isAlwaysOnTop = defaults.bool(forKey: Self.alwaysOnTopKey)
        let now = Self.currentTime()
        chromeMachine.setPin(.alwaysVisible, active: areControlsAlwaysVisible, now: now)
        chromeMachine.setPin(.noMedia, active: true, now: now)
        chromeMachine.setPin(
            .benchmark,
            active: Self.benchmarkPinsPlaybackChrome(),
            now: now
        )
        chromePhase = chromeMachine.phase
        benchmarkPlaybackControl = BenchmarkPlaybackControl.install(player: player)
        benchmarkPlaybackControl?.applicationCommand = { [weak self] command in
            guard let self else { return false }
            switch command.action {
            case "ping": break
            case "hover-preview":
                guard let target = command.targetSeconds, target.isFinite else { return false }
                self.benchmarkTimelineHover = BenchmarkTimelineHover(id: command.id, seconds: target)
            case "source-query":
                self.benchmarkSourceQuery = command.sourcePath ?? ""
            case "clear-previews":
                Task {
                    _ = await self.player.clearThumbnailCache()
                    LifecyclePerformance.mark("preview-cache-cleared")
                }
            case "memory-pressure":
                Task {
                    await self.thumbnailScheduler.handleMemoryPressure(constrained: command.targetSeconds != 0,
                        critical: command.targetSeconds == 2)
                    LifecyclePerformance.mark("preview-memory-pressure-handled")
                }
            case "open":
                guard let path = command.sourcePath, path.hasPrefix("/") else { return false }
                LifecyclePerformance.mark("open-request")
                self.handleOpenURLs([URL(fileURLWithPath: path)])
            case "close-window":
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    MainActor.assumeIsolated { self?.playerWindow?.performClose(nil) }
                }
            case "reopen-window": self.reopenPlayerWindow()
            case "toggle-sidebar": self.setSidebarVisible(!self.state.isSidebarVisible)
            case "window-animation":
                guard let window = self.playerWindow else { return false }
                window.animationBehavior = command.targetSeconds == 0 ? .none : .default
            case "resize-window":
                guard let window = self.playerWindow else { return false }
                var frame = window.frame
                frame.size = CGSize(width: command.targetSeconds ?? 960, height: 600)
                window.setFrame(frame, display: true, animate: false)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            default: return false
            }
            return true
        }
        player.setPlaybackCompletionHandler { [weak self] url in
            self?.osdPresenter.present(.mediaCompleted(Self.mediaDisplayName(for: url)))
        }
        player.thumbnailInteractionHandler = { [weak self] url, position in
            self?.thumbnailScheduler.interaction(url, position: position)
        }
        sourceRootIndex.replace(tabs: sourceTabs)
        installPlaybackLifecycleObservation(deliverCurrent: true)
        player.setPictureInPictureRestoreRequestHandler { [weak self] completion in
            guard let self else {
                completion(false)
                return
            }
            restorePlayerWindowForPictureInPicture(completion: completion)
        }
    }

    static func benchmarkPinsPlaybackChrome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == "com.example.SuperplayrBenchmark"
            && environment["SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES"] == "1"
            && environment["SUPERPLAYR_BENCHMARK_PIN_PLAYBACK_CHROME"] == "1"
    }

    static func benchmarkHidesSidebar(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == "com.example.SuperplayrBenchmark"
            && environment["SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES"] == "1"
            && environment["SUPERPLAYR_BENCHMARK_HIDE_SIDEBAR"] == "1"
    }

    var state: PlaybackViewStore { player.viewStore }

    var areControlsVisible: Bool { chromePhase.isOpaque }

    var isPlaybackChromeVisible: Bool {
        chromePhase.isOpaque
    }

    var isPlaybackChromeMounted: Bool {
        chromePhase.isMounted
    }

    private(set) var isSidebarAvailable = true

    var isSidebarPresented: Bool {
        isSidebarAvailable && !hidesSidebarForBenchmark && state.isSidebarVisible
    }

    func updateSidebarAvailability(containerWidth: CGFloat) {
        isSidebarAvailable = SourcesSidebarSizing.isAvailable(in: containerWidth)
    }

    var activeSourceTab: SourceTab? {
        SourceTabs.activeTab(selectedID: activeSourceTabID, in: sourceTabs)
    }

    var activeSourceItems: [SourceTabItem] {
        activeSourceTab?.items ?? []
    }

    func activeSourceFileItem(for url: URL) -> SourceTabItem? {
        guard sourceRootIndex.isReady, let id = activeSourceTabID,
              let path = NormalizedFileURL.persistenceKey(for: url) else { return nil }
        return sourceRoots.byTab[id]?.filesByPath[path]
    }

    var activeSourceVisibility: SourceVisibilityConfiguration {
        activeSourceTab?.visibility ?? .default
    }

    var activeSourceFolders: [URL] {
        activeSourceTabID.flatMap { sourceRoots.byTab[$0]?.folders } ?? []
    }

    var activeSourceWatchRoots: [URL] {
        activeSourceTabID.flatMap { sourceRoots.byTab[$0]?.watchRoots } ?? []
    }

    var allSourceWatchRoots: [URL] {
        sourceRoots.watchRoots
    }

    var allSourceFolders: [URL] {
        sourceRoots.folders
    }

    var areSourceRootsReady: Bool { sourceRootIndex.isReady }

    private var sourceRoots: SourceRootIndex {
        sourceRootIndex.snapshot
    }

    func openFilePanel() {
        guard !isShuttingDown else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Media Files"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = mediaContentTypes
        guard panel.runModal() == .OK, !isShuttingDown else { return }
        handleOpenURLs(panel.urls)
    }

    func addSourceFilesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Media Files to Tab"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = mediaContentTypes

        guard panel.runModal() == .OK, !isShuttingDown else { return }
        addSourceItems(panel.urls, kind: .file)
        setSidebarVisible(true)
        registerUserActivity()
    }

    func addSourceFoldersPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Media Folders"
        panel.prompt = "Add Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, !isShuttingDown else { return }
        addSourceItems(panel.urls, kind: .folder)
        setSidebarVisible(true)
        registerUserActivity()
    }

    func createSourceTab() {
        let tab = SourceTab(id: UUID().uuidString, items: [])
        sourceTabs.append(tab)
        activeSourceTabID = tab.id
        setSidebarVisible(true)
        persistSourceTabs()
        registerUserActivity()
    }

    func playSourceFile(_ url: URL) {
        player.openFileInContainingFolder(url: url)
        registerUserActivity()
    }

    func openSourceFolderTab(_ url: URL) {
        let tab = SourceTab(
            id: UUID().uuidString,
            items: []
        )
        sourceTabs.append(tab)
        activeSourceTabID = tab.id
        addSourceItems([url], kind: .folder)
        setSidebarVisible(true)
        persistSourceTabs()
        registerUserActivity()
    }

    func selectSourceTab(_ id: String) {
        guard let selectedID = SourceTabs.resolvedSelection(
            id,
            in: sourceTabs
        ), selectedID == id, activeSourceTabID != selectedID
        else {
            return
        }
        activeSourceTabID = selectedID
        setSidebarVisible(true)
        persistSourceTabs()
        registerUserActivity()
    }

    func selectAdjacentSourceTab(_ direction: SourceTabDirection) {
        guard let selectedID = SourceTabs.adjacentSelection(
            from: activeSourceTabID,
            direction: direction,
            in: sourceTabs
        ), selectedID != activeSourceTabID
        else {
            return
        }
        activeSourceTabID = selectedID
        setSidebarVisible(true)
        persistSourceTabs()
        registerUserActivity()
    }

    func closeSourceTab(_ id: String) {
        activeSourceTabID = SourceTabs.selectionAfterClosing(
            id,
            selectedID: activeSourceTabID,
            from: sourceTabs
        )
        sourceTabs.removeAll { $0.id == id }
        persistSourceTabs()
    }

    func removeSourceItem(_ item: SourceTabItem) {
        guard let tabIndex = activeSourceTabIndex else { return }
        sourceTabs[tabIndex].items.removeAll { $0 == item }
        persistSourceTabs()
    }

    func removeSourceFolder(_ url: URL) {
        guard let item = activeSourceItems.first(where: {
            $0.kind == .folder
                && NormalizedFileURL.representsSameFile($0.url, url)
        }) else {
            return
        }
        removeSourceItem(item)
    }

    func setActiveSourceViewMode(_ viewMode: SourceVisibilityViewMode) {
        updateActiveSourceVisibility { visibility in
            visibility.viewMode = viewMode
        }
    }

    func setActiveSourceShowsHiddenItems(_ showsHiddenItems: Bool) {
        updateActiveSourceVisibility { visibility in
            visibility.showsHiddenItems = showsHiddenItems
        }
    }

    func hideActiveSource(_ url: URL) {
        guard let path = SourceVisibilityPath.normalized(url) else { return }
        updateActiveSourceVisibility { visibility in
            visibility.alwaysShownPaths.remove(path)
            visibility.manuallyHiddenPaths.insert(path)
        }
    }

    func showActiveSource(_ url: URL) {
        guard let path = SourceVisibilityPath.normalized(url) else { return }
        updateActiveSourceVisibility { visibility in
            visibility.manuallyHiddenPaths.remove(path)
            visibility.alwaysShownPaths.insert(path)
        }
    }

    func unhideActiveSource(_ url: URL) {
        guard let path = SourceVisibilityPath.normalized(url) else { return }
        updateActiveSourceVisibility { visibility in
            visibility.manuallyHiddenPaths.remove(path)
            visibility.alwaysShownPaths.remove(path)
        }
    }

    func removeActiveSourceManualHide(_ path: String) {
        updateActiveSourceVisibility { visibility in
            visibility.manuallyHiddenPaths.remove(path)
        }
    }

    func removeActiveSourceAlwaysShow(_ path: String) {
        updateActiveSourceVisibility { visibility in
            visibility.alwaysShownPaths.remove(path)
        }
    }

    @discardableResult
    func addActiveSourceRegexRule(_ pattern: String) -> Bool {
        let normalizedPattern = pattern.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard SourceVisibilityRegexRule.isValid(pattern: normalizedPattern)
        else {
            return false
        }
        guard !activeSourceVisibility.regexRules.contains(where: {
            $0.pattern == normalizedPattern
        }) else {
            return false
        }
        updateActiveSourceVisibility { visibility in
            visibility.regexRules.append(SourceVisibilityRegexRule(
                id: UUID().uuidString,
                pattern: normalizedPattern,
                colorIndex: SourceVisibilityRegexRule.nextColorIndex(
                    after: visibility.regexRules
                ),
                isEnabled: true
            ))
        }
        return true
    }

    func setActiveSourceRegexRuleEnabled(_ id: String, isEnabled: Bool) {
        updateActiveSourceVisibility { visibility in
            guard let index = visibility.regexRules.firstIndex(where: {
                $0.id == id
            }) else {
                return
            }
            visibility.regexRules[index].isEnabled = isEnabled
        }
    }

    func removeActiveSourceRegexRule(_ id: String) {
        updateActiveSourceVisibility { visibility in
            visibility.regexRules.removeAll { $0.id == id }
        }
    }

    func resetActiveSourceVisibility() {
        guard let tabIndex = activeSourceTabIndex else { return }
        sourceTabs[tabIndex].visibility = nil
        persistSourceTabs()
        registerUserActivity()
    }

    @discardableResult
    func addDroppedItemsToActiveSourceTab(_ urls: [URL]) -> Bool {
        guard urls.contains(where: \.isFileURL) else { return false }
        prepareSourceItems(urls, kind: nil)
        setSidebarVisible(true)
        registerUserActivity()
        return true
    }

    func isCurrentMediaInsideSourceTab(_ tab: SourceTab) -> Bool {
        guard let currentURL = state.currentURL else { return false }
        return SourceTabs.contains(currentURL, in: tab)
    }

    func revealSourceInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLocationPanel() {
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.placeholderString = "https://example.com/video.m3u8"

        let alert = NSAlert()
        alert.messageText = "Open Network Stream"
        alert.informativeText = "Enter a direct HTTP or HTTPS media or playlist URL."
        alert.accessoryView = input
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !isShuttingDown,
              let url = URL(string: input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return }

        if scheme == "http" {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = "Open an Unencrypted Stream?"
            warning.informativeText = "HTTP traffic can be observed or modified in transit. Use HTTPS when available."
            warning.addButton(withTitle: "Open Anyway")
            warning.addButton(withTitle: "Cancel")
            guard warning.runModal() == .alertFirstButtonReturn else { return }
        }

        player.openRemoteStream(url: url)
        registerUserActivity()
    }

    func openSubtitleDelayPanel() {
        presentSubtitleDelayPanel(
            inputText: SubtitleDelayInput.millisecondsText(for: state.subtitleDelay),
            validationMessage: nil
        )
    }

    func saveScreenshot() {
        guard let sourceURL = state.currentURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        let includeSubtitles = NSButton(checkboxWithTitle: "Include subtitles", target: nil, action: nil)
        includeSubtitles.state = .on
        panel.accessoryView = includeSubtitles

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) \(formatter.string(from: Date())).png"

        guard panel.runModal() == .OK, !isShuttingDown, let destination = panel.url else { return }
        Task {
            do {
                try await player.captureScreenshot(to: destination, includeSubtitles: includeSubtitles.state == .on)
                osdPresenter.present(.status("Screenshot saved"))
            } catch {
                player.reportError(error.localizedDescription)
            }
        }
    }

    func openSubtitlePanel() {
        let panel = NSOpenPanel()
        panel.title = "Load External Subtitle"
        panel.prompt = "Load Subtitle"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = subtitleContentTypes

        guard panel.runModal() == .OK, !isShuttingDown, let subtitle = panel.url else { return }
        player.loadExternalSubtitle(subtitle)
        registerUserActivity()
    }

    func handleOpenURLs(_ urls: [URL], mode: PlaylistOpenMode = .replace) {
        guard !isShuttingDown else { return }
        for request in launchOpenQueue.receive(urls: urls, mode: mode) {
            applyOpenRequest(request)
        }
    }

    func toggleSidebar() {
        guard isSidebarAvailable else { return }
        if state.isSidebarVisible {
            player.setSidebarVisible(false)
        } else {
            player.setSidebarVisible(true)
            registerUserActivity()
        }
        updatePlaybackChromePins()
    }

    func setSidebarVisible(_ isVisible: Bool) {
        player.setSidebarVisible(isVisible)
        updatePlaybackChromePins()
    }

    func toggleFullscreen() {
        prepareForSystemOwnedTransition()
        (playerWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    func toggleWindowAspectLock() {
        setWindowAspectLocked(!isWindowAspectLocked)
    }

    func setWindowAspectLocked(_ isLocked: Bool) {
        guard isWindowAspectLocked != isLocked else { return }
        isWindowAspectLocked = isLocked
        UserDefaults.standard.set(isWindowAspectLocked, forKey: Self.windowAspectLockKey)
        if let window = playerWindow ?? NSApp.keyWindow {
            applyWindowAspectLock(to: window, resizeToVideo: true)
        }
        registerUserActivity()
    }

    func toggleAlwaysOnTop() {
        setAlwaysOnTop(!isAlwaysOnTop)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        guard isAlwaysOnTop != enabled else { return }
        isAlwaysOnTop = enabled
        UserDefaults.standard.set(isAlwaysOnTop, forKey: Self.alwaysOnTopKey)
        applyAlwaysOnTop()
        registerUserActivity()
    }

    var canFitWindowToVideo: Bool {
        playerWindow != nil
            && !state.isFullscreen
            && state.videoAspectRatio != nil
    }

    func fitWindowToVideo() {
        guard let window = playerWindow ?? NSApp.keyWindow,
              !window.styleMask.contains(.fullScreen),
              let aspectRatio = state.videoAspectRatio,
              let targetSize = AspectFitWindowSizing.fittedWindowSize(
                  currentWindowSize: window.frame.size,
                  currentVideoViewportSize: player.videoViewportSize,
                  minimumWindowSize: window.minSize,
                  videoAspectRatio: aspectRatio
              )
        else {
            NSSound.beep()
            return
        }

        var targetFrame = window.frame
        let topEdge = targetFrame.maxY
        targetFrame.size = targetSize
        targetFrame.origin.y = topEdge - targetSize.height
        window.setFrame(
            targetFrame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        registerUserActivity()
    }

    func registerUserActivity() {
        chromeMachine.registerActivity(at: Self.currentTime())
        synchronizeChrome()
    }

    func togglePauseFromUser() {
        player.togglePause()
        updatePlaybackChromePins()
        registerUserActivity()
    }

    func togglePauseFromPlaybackButton() {
        let shouldHideChrome = PlaybackToggleChromePolicy.shouldHideAfterActivation(
            isPauseDesired: state.isPauseDesired
        )
        player.togglePause()
        updatePlaybackChromePins()
        if shouldHideChrome {
            let now = Self.currentTime()
            pointerRevealGate.beginPostPlayCooldown(at: now)
            chromeMachine.handleSurfaceClick(
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                now: now
            )
            synchronizeChrome()
        } else {
            registerUserActivity()
        }
    }

    func playPreviousFromUser() {
        player.playPrevious()
        registerUserActivity()
    }

    func playNextFromUser() {
        player.playNext()
        registerUserActivity()
    }

    func performRelativeSeek(
        _ seconds: TimeInterval,
        at inputTime: TimeInterval? = nil,
        registersUserActivity: Bool = true
    ) {
        guard player.supports(.seekRelative), state.currentSource != nil else { return }
        let now = inputTime ?? Self.currentTime()
        let target = seekInteractionAccumulator.relativeTarget(
            delta: seconds,
            currentPosition: state.position,
            duration: state.duration,
            at: now
        )
        if !registersUserActivity, let source = state.currentSource {
            beginKeyboardSeekChromeSuppression(for: source)
        }
        player.seek(relative: seconds)
        osdPresenter.present(.seek(delta: seconds, target: target))
        if registersUserActivity {
            registerUserActivity()
        }
    }

    func setVolumeFromUser(_ value: Double) {
        let sanitized = min(max(value, 0), 100)
        player.setVolume(sanitized)
        osdPresenter.present(.volume(value: sanitized, isMuted: state.isMuted))
        registerUserActivity()
    }

    func toggleMuteFromUser() {
        let muted = !state.isMuted
        player.setMuted(muted)
        osdPresenter.present(.volume(value: state.volume, isMuted: muted))
        registerUserActivity()
    }

    func selectAudioTrackFromUser(_ track: MediaTrack?) {
        player.selectAudioTrack(track)
        osdPresenter.present(.audioTrack(track?.displayName ?? "Default"))
        registerUserActivity()
    }

    func selectSubtitleTrackFromUser(_ track: MediaTrack?) {
        player.selectSubtitleTrack(track)
        osdPresenter.present(.subtitle(track?.displayName ?? "Off"))
        registerUserActivity()
    }

    func setSubtitleDelayFromUser(_ delay: TimeInterval) {
        let sanitized = min(max(delay, -10), 10)
        player.setSubtitleDelay(sanitized)
        osdPresenter.present(.subtitleDelay(sanitized))
        registerUserActivity()
    }

    func cycleRepeatModeFromUser() {
        let next: PlaybackRepeatMode = switch state.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        player.setRepeatMode(next)
        let label = switch next {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
        osdPresenter.present(.status(label))
        registerUserActivity()
    }

    func toggleShuffleFromUser() {
        let enabled = !state.isShuffleEnabled
        player.setShuffleEnabled(enabled)
        osdPresenter.present(.status(enabled ? "Shuffle On" : "Shuffle Off"))
        registerUserActivity()
    }

    func setChromePin(_ reason: PlaybackChromePinReason, active: Bool) {
        if active, reason != .loading, reason != .noMedia, reason != .benchmark {
            surfaceScrollAccumulator.cancel()
        }
        chromeMachine.setPin(reason, active: active, now: Self.currentTime())
        synchronizeChrome()
    }

    func setPointerRegion(_ region: PlaybackCursorRegion) {
        cursorRegion = region
        updateCursorPolicy()
    }

    func pointerExitedPlayer() {
        surfaceScrollAccumulator.cancel()
        cursorRegion = .outside
        cursorCoordinator.restore()
        updateCursorPolicy()
    }

    func pointerExitedWindow() {
        pointerExitedPlayer()
        chromeMachine.hideForPointerExit(
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            now: Self.currentTime()
        )
        synchronizeChrome()
    }

    func setTransientPresentation(_ isPresented: Bool, owner: String) {
        guard !isShuttingDown || !isPresented else { return }
        if isPresented, transientOwners.isEmpty { presentationInvoker = playerWindow?.firstResponder }
        if isPresented { transientOwners.insert(owner) }
        else { transientOwners.remove(owner) }
        setChromePin(.transientPresentation, active: hasTransientPresentation)
        if !isPresented, transientOwners.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isShuttingDown, self.transientOwners.isEmpty,
                      let window = self.playerWindow, window.isKeyWindow, window.attachedSheet == nil else { return }
                if let view = self.presentationInvoker as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor {
                    window.makeFirstResponder(view)
                } else { window.makeFirstResponder(nil) }
                self.presentationInvoker = nil
            }
        }
    }

    @discardableResult
    func cancelActiveInteraction() -> Bool {
        let active = !chromeMachine.pinReasons.isDisjoint(with: [.scrubbing, .chromeDrag, .manipulation])
        interactionCancellationRevision &+= 1
        surfaceScrollAccumulator.cancel()
        return active
    }

    func resetControlsPosition() {
        cancelActiveInteraction()
        ElasticPlaybackControlBarPlacementStore.persist(.defaultValue)
        controlsPositionRevision &+= 1
        registerUserActivity()
    }

    func handleSurfaceInteraction(_ interaction: PlaybackSurfaceInteraction) {
        guard !isShuttingDown else { return }
        switch interaction {
        case .pointerEntered:
            setPointerRegion(.video)
        case let .pointerMoved(location):
            handlePointerActivity(at: location, isMouseMove: true)
        case .pointerExited:
            if let playerWindow,
               !PlayerWindowPointerPolicy.isInsideWindow(
                    mouseLocationOnScreen: NSEvent.mouseLocation,
                    windowFrame: playerWindow.frame
               )
            {
                pointerExitedWindow()
            } else {
                pointerExitedPlayer()
            }
        case .doubleClick:
            guard !hasTransientPresentation, playerWindow?.attachedSheet == nil else { return }
            toggleFullscreen()
        case let .doubleClickSeek(seconds):
            guard !hasTransientPresentation, playerWindow?.attachedSheet == nil else { return }
            performRelativeSeek(seconds)
        case .primaryClick:
            guard !hasTransientPresentation, playerWindow?.attachedSheet == nil else { return }
            chromeMachine.handleSurfaceClick(
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                now: Self.currentTime()
            )
            synchronizeChrome()
        case .togglePause:
            _ = togglePauseFromKeyboard()
        case let .seekRelative(seconds):
            performRelativeSeek(
                seconds,
                registersUserActivity: PlayerKeyboardChromePolicy.shouldRegisterActivity(
                    action: .seek(seconds),
                    areControlsVisible: areControlsVisible
                )
            )
        case let .auxiliaryButton(button):
            guard !hasTransientPresentation, playerWindow?.attachedSheet == nil else { return }
            if button == 3 {
                playPreviousFromUser()
            } else if button == 4 {
                playNextFromUser()
            }
        case let .scroll(event):
            guard playerWindow?.attachedSheet == nil, !hasTransientPresentation else {
                surfaceScrollAccumulator.cancel()
                return
            }
            guard let action = surfaceScrollAccumulator.consume(event) else { return }
            switch action {
            case let .seek(seconds):
                guard state.duration > 0 else { return }
                performRelativeSeek(seconds)
            case let .volume(delta):
                setVolumeFromUser(state.volume + delta)
            }
        }
    }

    func makeVideoContextMenu() -> NSMenu? {
        let isLocalSource: Bool
        if case .localFile? = state.currentSource {
            isLocalSource = true
        } else {
            isLocalSource = false
        }
        let availability = PlayerContextMenuAvailability(
            capabilities: player.capabilityModel,
            hasSource: state.currentSource != nil,
            isLocalSource: isLocalSource,
            hasPrevious: state.hasPreviousItem,
            hasNext: state.hasNextItem
        )
        guard !availability.actions.isEmpty else { return nil }

        setPointerRegion(.transientUI)
        setTransientPresentation(true, owner: "context-menu")
        let target = PlayerContextMenuTarget { [weak self] in
            self?.activeContextMenuTarget = nil
            self?.setTransientPresentation(false, owner: "context-menu")
            self?.setPointerRegion(.video)
        }
        activeContextMenuTarget = target

        let menu = NSMenu(title: "Playback")
        menu.autoenablesItems = false
        menu.delegate = target

        addContextItem(.playPause, to: menu, target: target)
        if availability.actions.contains(.previous) {
            addContextItem(.previous, to: menu, target: target)
        }
        if availability.actions.contains(.next) {
            addContextItem(.next, to: menu, target: target)
        }
        menu.addItem(.separator())
        if availability.actions.contains(.seekBackward) {
            addContextItem(.seekBackward, to: menu, target: target)
            addContextItem(.seekForward, to: menu, target: target)
        }
        if availability.actions.contains(.audioTracks) {
            menu.addItem(trackMenuItem(kind: .audio, target: target))
        }
        if availability.actions.contains(.subtitles) {
            menu.addItem(trackMenuItem(kind: .subtitle, target: target))
        }
        menu.addItem(.separator())
        for action in [
            PlayerContextMenuAction.pictureInPicture,
            .fullscreen,
            .alwaysOnTop,
            .screenshot,
        ] where availability.actions.contains(action) {
            addContextItem(action, to: menu, target: target)
        }
        menu.addItem(.separator())
        for action in [
            PlayerContextMenuAction.showInFinder,
            .copyPath,
            .inspector,
        ] where availability.actions.contains(action) {
            addContextItem(action, to: menu, target: target)
        }
        return menu
    }

    var canTogglePictureInPicture: Bool {
        player.supports(.pictureInPicture)
            && state.currentSource != nil
            && state.pictureInPicture.canToggle
    }

    func togglePictureInPicture() {
        guard canTogglePictureInPicture else {
            NSSound.beep()
            return
        }
        let isStarting = !state.pictureInPicture.isActive
        prepareForSystemOwnedTransition()
        if isStarting {
            chromeMachine.hideImmediatelyForPictureInPictureStart()
            synchronizeChrome()
        }
        player.setPictureInPictureActive(!state.pictureInPicture.isActive)
    }

    /// Fullscreen and PiP own their presentation motion. Clear local transient
    /// motion first so Platinum never layers an OSD/sidebar sequence over the
    /// AppKit or AVKit transition.
    private func prepareForSystemOwnedTransition() {
        osdPresenter.invalidate()
    }

    func playbackStateDidChange() {
        updateThumbnailScheduling()
        let pipEnded = wasPictureInPictureActive && !state.pictureInPicture.isActive
        wasPictureInPictureActive = state.pictureInPicture.isActive
        if pipEnded, playerWindow == nil, pictureInPictureRestoreCompletion == nil, !isShuttingDown {
            player.stop()
        }
        systemCoordinator.update(for: state.phase)
        nowPlayingCoordinator.update(from: state.snapshot, force: true)
        updateNowPlayingPositionUpdates()

        if state.currentSource != lastObservedSource {
            cancelActiveInteraction()
            osdPresenter.invalidate()
            surfaceScrollAccumulator.cancel()
            if let source = state.currentSource {
                osdPresenter.present(.mediaChanged(Self.mediaDisplayName(for: source.url)))
            }
            lastObservedSource = state.currentSource
        }
        updatePlaybackChromePins()
    }

    func playbackPositionDidChange() {
        nowPlayingCoordinator.update(from: state.snapshot)
    }

    func videoAspectRatioDidChange() {
        guard let window = playerWindow else { return }
        applyWindowAspectLock(to: window, resizeToVideo: true)
    }

    func installPlayerWindowReopener(_ action: @escaping @MainActor () -> Void) {
        reopenPlayerWindowAction = action
    }

    func reopenPlayerWindow() {
        guard !isShuttingDown else { return }
        if let playerWindow {
            if playerWindow.isMiniaturized {
                playerWindow.deminiaturize(nil)
            }
            playerWindow.makeKeyAndOrderFront(nil)
        } else {
            reopenPlayerWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restorePlayerWindowForPictureInPicture(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        pictureInPictureRestoreTask?.cancel()
        pictureInPictureRestoreCompletion?(false)

        let generation = UUID()
        pictureInPictureRestoreGeneration = generation
        pictureInPictureRestoreCompletion = completion
        reopenPlayerWindow()

        pictureInPictureRestoreTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while !Task.isCancelled, clock.now < deadline {
                guard let self else { return }
                let window = playerWindow
                if PlayerWindowRestoreReadiness.shouldReportSuccess(
                    windowExists: window != nil,
                    windowVisible: window?.isVisible == true,
                    windowMiniaturized: window?.isMiniaturized == true,
                    surfaceAttached: window.map(player.isVideoSurfaceAttached(to:)) == true
                ) {
                    finishPictureInPictureRestore(
                        generation: generation,
                        succeeded: true
                    )
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    break
                }
            }
            self?.finishPictureInPictureRestore(
                generation: generation,
                succeeded: false
            )
        }
    }

    private func finishPictureInPictureRestore(
        generation: UUID,
        succeeded: Bool
    ) {
        guard generation == pictureInPictureRestoreGeneration else { return }
        let completion = pictureInPictureRestoreCompletion
        pictureInPictureRestoreCompletion = nil
        pictureInPictureRestoreTask = nil
        completion?(succeeded)
        if !succeeded, playerWindow == nil, !state.pictureInPicture.isActive, !isShuttingDown { player.stop() }
    }

    func configure(window: NSWindow) {
        let timing = LifecyclePerformance.begin("window-configure")
        defer { LifecyclePerformance.end("window-configure", since: timing) }
        guard !isShuttingDown else { window.close(); return }
        if let playerWindow {
            guard playerWindow !== window else { return }
            playerWindow.makeKeyAndOrderFront(nil)
            window.close()
            return
        }
        playerWindow = window
        updateThumbnailScheduling()
        PlayerWindowControls.configure(window)
        window.minSize = NSSize(width: 720, height: 440)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.titlebarSeparatorStyle = .none
        preserveNativeWindowControls(in: window)
        installTitlebarTitle(in: window)

        let launchRequests = launchOpenQueue.markReady()
        if !didRestorePlaybackSession {
            didRestorePlaybackSession = true
            if launchRequests.isEmpty {
                _ = player.restoreLastSession()
            }
        }
        for request in launchRequests {
            applyOpenRequest(request)
        }

        if let frameString = UserDefaults.standard.string(forKey: Self.windowFrameKey) {
            let frame = NSRectFromString(frameString)
            if let reachable = PlayerWindowGeometry.restoredFrame(frame, screens: NSScreen.screens.map(\.visibleFrame)) {
                window.setFrame(reachable, display: false)
            }
        }
        applyBenchmarkWindowGeometry(to: window)
        applyWindowAspectLock(to: window)
        applyAlwaysOnTop()
        updateUIObservationActivity(for: window)
        updateNowPlayingPositionUpdates()
        if chromeScheduler == nil {
            chromeScheduler = PlaybackChromeDeadlineScheduler(
                now: Self.currentTime,
                onDeadline: { [weak self] in self?.chromeDeadlineReached() }
            )
        }
        chromeMachine.revealForLaunch(at: Self.currentTime())
        synchronizeChrome()

        if pointerEventMonitor == nil {
            pointerEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .leftMouseDown,
                    .mouseMoved,
                    .rightMouseDown,
                    .otherMouseDown,
                    .leftMouseDragged,
                    .rightMouseDragged,
                    .otherMouseDragged,
                ]
            ) { [weak self, weak window] event in
                guard let window, event.window === window else { return event }
                if event.type == .leftMouseDown {
                    let consumed = MainActor.assumeIsolated {
                        PlayerWindowControls.handleTitlebarDoubleClick(
                            event,
                            in: window,
                            accessory: self?.isPlaybackChromeVisible == true
                                ? self?.titlebarTitleView : nil
                        )
                    }
                    return consumed ? nil : event
                }
                let isMouseMove = event.type == .mouseMoved
                let location = event.locationInWindow
                let isInsideWindow = PlayerWindowPointerPolicy.isInsideWindow(
                    locationInWindow: location,
                    mouseLocationOnScreen: NSEvent.mouseLocation,
                    windowFrame: window.frame
                )
                MainActor.assumeIsolated {
                    if isInsideWindow {
                        self?.handlePointerActivity(at: location, isMouseMove: isMouseMove)
                    } else {
                        self?.pointerExitedWindow()
                    }
                }
                return event
            }
        }

        if globalPointerEventMonitor == nil {
            globalPointerEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .mouseMoved
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let self,
                          let window,
                          window === self.playerWindow,
                          !self.chromeMachine.isPointerOutside,
                          !PlayerWindowPointerPolicy.isInsideWindow(
                              mouseLocationOnScreen: NSEvent.mouseLocation,
                              windowFrame: window.frame
                          )
                    else { return }
                    self.pointerExitedWindow()
                }
            }
        }

        if keyboardEventMonitor == nil {
            keyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                if event.keyCode == 48, (event.window ?? NSApp.keyWindow) === self?.playerWindow {
                    self?.chromeMachine.revealForKeyboardNavigation(at: Self.currentTime())
                    self?.synchronizeChrome()
                }
                guard let self,
                      let window = event.window ?? NSApp.keyWindow,
                      window === self.playerWindow,
                      window.attachedSheet == nil,
                      let action = self.shortcutBindings.resolve(event)
                else { return event }
                if action == .dismiss, self.cancelActiveInteraction() { return nil }
                if action != .dismiss, !self.playbackFocusOwners.isEmpty { return event }
                guard !PlayerKeyboardRouting.shouldDefer(
                    action: action,
                    firstResponder: window.firstResponder,
                    isPlaybackChromeVisible: self.areControlsVisible,
                    isWindowFullscreen: window.styleMask.contains(.fullScreen),
                    isVoiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled
                ) else { return event }
                return self.performKeyboardAction(action, eventTime: event.timestamp)
                    ? nil
                    : event
            }
        }

        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
                guard let object = notification.object else { return }
                let owner = "menu-\(ObjectIdentifier(object as AnyObject))"
                MainActor.assumeIsolated {
                    self?.setTransientPresentation(true, owner: owner)
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
                guard let object = notification.object else { return }
                let owner = "menu-\(ObjectIdentifier(object as AnyObject))"
                MainActor.assumeIsolated {
                    self?.setTransientPresentation(false, owner: owner)
                }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
                [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window, !window.styleMask.contains(.fullScreen),
                          let frame = PlayerWindowGeometry.restoredFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
                    window.setFrame(frame, display: true)
                }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                guard let self, let window else { return }
                Task { @MainActor in self.saveFrame(of: window) }
            },
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setChromePin(.windowResize, active: self.state.phase == .paused)
                }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, !window.inLiveResize else { return }
                    if self.state.phase == .paused {
                        self.registerUserActivity()
                    }
                    self.saveFrame(of: window)
                }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.setChromePin(.windowResize, active: false)
                    self.saveFrame(of: window)
                    self.registerUserActivity()
                }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                guard let self, let window else { return }
                Task { @MainActor in self.fullscreenStateDidChange(true, in: window) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                guard let self, let window else { return }
                Task { @MainActor in self.fullscreenStateDidChange(false, in: window) }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.updateCursorPolicy() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.cancelActiveInteraction()
                    self?.cursorCoordinator.restore()
                }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    self?.cancelActiveInteraction()
                    self?.cursorCoordinator.restore()
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    self?.cancelActiveInteraction()
                    self?.cursorCoordinator.restore()
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    self?.cancelActiveInteraction()
                    self?.cursorCoordinator.restore()
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) {
                [weak self, weak window] _ in
                Task { @MainActor in
                    if let window { self?.updateUIObservationActivity(for: window) }
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.playerWindowWillClose(window)
                }
            },
        ]
    }

    private func installTitlebarTitle(in window: NSWindow) {
        guard let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebarView = zoomButton.superview
        else {
            return
        }

        titlebarTitleView?.removeFromSuperview()
        let hostingView = NSHostingView(
            rootView: PlaybackTitlebarAccessoryView(
                model: self,
                themeStore: .shared
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titlebarView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(
                equalTo: zoomButton.trailingAnchor,
                constant: 14
            ),
            hostingView.trailingAnchor.constraint(
                lessThanOrEqualTo: titlebarView.trailingAnchor,
                constant: -16
            ),
            hostingView.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            hostingView.heightAnchor.constraint(equalToConstant: 28),
        ])
        titlebarTitleView = hostingView
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        thumbnailScheduler.shutdown()
        player.thumbnailInteractionHandler = nil
        cancelActiveInteraction()
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        if let window = playerWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        activeContextMenuTarget = nil
        isInspectorPresented = false
        isShortcutHelpPresented = false
        isMessageHistoryPresented = false
        for task in sourceItemPreparationTasks.values { task.cancel() }
        sourceItemPreparationTasks.removeAll()
        player.setPictureInPictureRestoreRequestHandler(nil)
        pictureInPictureRestoreGeneration = UUID()
        let terminatingPictureInPictureRestore = pictureInPictureRestoreTask
        pictureInPictureRestoreTask = nil
        terminatingPictureInPictureRestore?.cancel()
        let restoreCompletion = pictureInPictureRestoreCompletion
        pictureInPictureRestoreCompletion = nil
        restoreCompletion?(false)
        await terminatingPictureInPictureRestore?.value
        chromeScheduler?.invalidate()
        chromeScheduler = nil
        cursorCoordinator.restore()
        osdPresenter.invalidate()
        nowPlayingPositionTask?.cancel()
        nowPlayingPositionTask = nil
        benchmarkPlaybackControl?.invalidate()
        benchmarkPlaybackControl = nil
        nowPlayingCoordinator.deactivate()
        systemCoordinator.invalidate()
        if let pointerEventMonitor {
            NSEvent.removeMonitor(pointerEventMonitor)
            self.pointerEventMonitor = nil
        }
        if let globalPointerEventMonitor {
            NSEvent.removeMonitor(globalPointerEventMonitor)
            self.globalPointerEventMonitor = nil
        }
        if let keyboardEventMonitor {
            NSEvent.removeMonitor(keyboardEventMonitor)
            self.keyboardEventMonitor = nil
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        playerWindow = nil
        reopenPlayerWindowAction = nil
        await player.shutdown()
    }

    private func installPlaybackLifecycleObservation(deliverCurrent: Bool) {
        // This observation belongs to the application model, not the mounted
        // player view, so power/Now Playing policy remains live while the
        // player window is closed and PiP continues.
        let observation = withObservationTracking {
            PlaybackLifecycleObservation(
                phase: state.phase,
                source: state.currentSource,
                isPauseDesired: state.isPauseDesired,
                videoAspectRatio: state.videoAspectRatio,
                lastError: state.lastError,
                isPictureInPictureActive: state.pictureInPicture.isActive
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.playbackLifecycleObservationDidChange()
            }
        }

        let previous = lastPlaybackLifecycleObservation
        lastPlaybackLifecycleObservation = observation
        if deliverCurrent
            || previous?.phase != observation.phase
            || previous?.source != observation.source
            || previous?.isPauseDesired != observation.isPauseDesired
            || previous?.lastError != observation.lastError
            || previous?.isPictureInPictureActive != observation.isPictureInPictureActive
        {
            if previous?.lastError != observation.lastError,
               let error = observation.lastError
            {
                osdPresenter.present(.error(error))
                if state.shellError != nil {
                    player.clearError()
                }
            }
            playbackStateDidChange()
        }
        if deliverCurrent
            || previous?.videoAspectRatio != observation.videoAspectRatio
        {
            videoAspectRatioDidChange()
        }
    }

    private func playbackLifecycleObservationDidChange() {
        guard !isShuttingDown else { return }
        installPlaybackLifecycleObservation(deliverCurrent: false)
    }

    private func updateNowPlayingPositionUpdates() {
        guard NowPlayingRefreshPolicy.shouldRefreshContinuously(phase: state.phase) else {
            nowPlayingPositionTask?.cancel()
            nowPlayingPositionTask = nil
            return
        }
        guard nowPlayingPositionTask == nil else { return }
        nowPlayingPositionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                playbackPositionDidChange()
            }
        }
    }

    private func applyOpenRequest(_ request: LaunchOpenRequest) {
        guard !isShuttingDown else { return }
        player.open(urls: request.urls, mode: request.mode) { [weak self] folders in
            guard let self, !isShuttingDown, !folders.isEmpty else { return }
            for folder in folders {
                let tab = SourceTab(id: UUID().uuidString,
                    items: SourceTabItems.merging([], with: [folder], kind: .folder))
                sourceTabs.append(tab)
                activeSourceTabID = tab.id
            }
            persistSourceTabs()
            setSidebarVisible(true)
        }
        if request.mode == .append { osdPresenter.present(.status("Adding media…")) }
        registerUserActivity()
    }

    private var activeSourceTabIndex: Int? {
        guard let activeSourceTabID else { return nil }
        return sourceTabs.firstIndex { $0.id == activeSourceTabID }
    }

    private func addSourceItems(_ urls: [URL], kind: SourceTabItem.Kind) {
        prepareSourceItems(urls, kind: kind)
    }

    private func prepareSourceItems(_ urls: [URL], kind: SourceTabItem.Kind?) {
        guard !isShuttingDown, !urls.isEmpty else { return }
        if activeSourceTabIndex == nil {
            let tab = SourceTab(id: UUID().uuidString, items: [])
            sourceTabs.append(tab)
            activeSourceTabID = tab.id
        }
        guard let targetTabID = activeSourceTabID else { return }
        let requestID = UUID()
        sourceItemPreparationTasks[requestID] = Task { @MainActor [weak self] in
            let result = await SourcePreparationExecutor.shared.result { check in
                try SourceItemPreparation.prepare(urls, kind: kind, checkCancellation: check)
            }
            guard let self else { return }
            defer { sourceItemPreparationTasks[requestID] = nil }
            guard !Task.isCancelled, !isShuttingDown,
                  let tabIndex = sourceTabs.firstIndex(where: { $0.id == targetTabID }) else { return }
            do {
                let additions = try result.get()
                guard !additions.isEmpty else {
                    player.reportError("No supported files or folders were selected.")
                    return
                }
                sourceTabs[tabIndex].items = SourceTabItems.merging(sourceTabs[tabIndex].items, with: additions)
                persistSourceTabs()
            } catch { player.reportError(error.localizedDescription) }
        }
    }

    private func updateActiveSourceVisibility(
        _ update: (inout SourceVisibilityConfiguration) -> Void
    ) {
        guard let tabIndex = activeSourceTabIndex else { return }
        var visibility = sourceTabs[tabIndex].visibility ?? .default
        update(&visibility)
        visibility.normalize()
        sourceTabs[tabIndex].visibility = visibility.isDefault ? nil : visibility
        persistSourceTabs()
        registerUserActivity()
    }

    private func persistSourceTabs() {
        let defaults = UserDefaults.standard
        defaults.set(SourceTabStore.encode(sourceTabs), forKey: Self.sourceTabsKey)
        if let activeSourceTabID {
            defaults.set(activeSourceTabID, forKey: Self.activeSourceTabKey)
        } else {
            defaults.removeObject(forKey: Self.activeSourceTabKey)
        }
    }

    private func updateThumbnailScheduling() {
        thumbnailScheduler.updatePlayback(current: state.currentURL,
            idle: !isShuttingDown && (state.phase == .idle || state.phase == .paused)
                && state.isPauseDesired,
            windowVisible: playerWindow != nil, playing: !isShuttingDown && state.phase == .playing,
            sourceRevision: player.interactionSourceRevision)
    }

    private func updateUIObservationActivity(for window: NSWindow) {
        let active = WindowUIObservationPolicy.shouldObserve(
            isApplicationActive: NSApp.isActive,
            isWindowVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOccluded: !window.occlusionState.contains(.visible)
        )
        if isUIObservationActive != active {
            isUIObservationActive = active
        }
    }

    private func saveFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.windowFrameKey)
    }

    private func playerWindowWillClose(_ window: NSWindow) {
        let timing = LifecyclePerformance.begin("window-close")
        defer { LifecyclePerformance.end("window-close", since: timing) }
        guard window === playerWindow else { return }
        setChromePin(.windowResize, active: false)
        saveFrame(of: window)
        cancelActiveInteraction()
        if !state.pictureInPicture.isActive { player.stop() }
        osdPresenter.invalidate()
        cursorCoordinator.restore()
        if let pointerEventMonitor {
            NSEvent.removeMonitor(pointerEventMonitor)
            self.pointerEventMonitor = nil
        }
        if let globalPointerEventMonitor {
            NSEvent.removeMonitor(globalPointerEventMonitor)
            self.globalPointerEventMonitor = nil
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        if let keyboardEventMonitor {
            NSEvent.removeMonitor(keyboardEventMonitor)
            self.keyboardEventMonitor = nil
        }
        transientOwners.removeAll()
        playbackFocusOwners.removeAll()
        chromeMachine.setPin(.transientPresentation, active: false, now: Self.currentTime())
        chromeMachine.setPin(.playbackFocus, active: false, now: Self.currentTime())
        chromeScheduler?.invalidate()
        titlebarTitleView?.removeFromSuperview()
        titlebarTitleView = nil
        playerWindow = nil
        updateThumbnailScheduling()
        isUIObservationActive = false
    }

    private func applyBenchmarkWindowGeometry(to window: NSWindow) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES"] == "1",
              let value = environment["SUPERPLAYR_BENCHMARK_WINDOW_SIZE"]
        else {
            return
        }
        let components = value.split(separator: "x", maxSplits: 1)
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width >= window.minSize.width,
              height >= window.minSize.height
        else {
            return
        }

        var frame = window.frame
        frame.size = CGSize(width: width, height: height)
        if let visibleFrame = window.screen?.visibleFrame {
            frame.origin.x = min(
                max(frame.origin.x, visibleFrame.minX),
                visibleFrame.maxX - frame.width
            )
            frame.origin.y = min(
                max(frame.origin.y, visibleFrame.minY),
                visibleFrame.maxY - frame.height
            )
        }
        window.setFrame(frame, display: false)
    }

    private func applyWindowAspectLock(
        to window: NSWindow,
        resizeToVideo: Bool = false
    ) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard isWindowAspectLocked else {
            window.contentAspectRatio = .zero
            return
        }
        let contentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        guard let videoAspectRatio = state.videoAspectRatio else {
            window.contentAspectRatio = contentSize
            return
        }

        window.contentAspectRatio = CGSize(width: videoAspectRatio, height: 1)
        guard resizeToVideo else { return }

        let minimumContentSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: window.minSize)
        ).size
        guard let targetContentSize = WindowAspectLockSizing.fittedContentSize(
            currentSize: contentSize,
            minimumSize: minimumContentSize,
            aspectRatio: videoAspectRatio
        ) else { return }

        var targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        )
        targetFrame.origin.x = window.frame.minX
        targetFrame.origin.y = window.frame.maxY - targetFrame.height
        window.setFrame(targetFrame, display: true)
    }

    private func applyAlwaysOnTop() {
        guard let window = playerWindow else { return }
        window.level = isAlwaysOnTop && !window.styleMask.contains(.fullScreen)
            ? .floating
            : .normal
    }

    private func handlePointerActivity(at location: CGPoint, isMouseMove: Bool) {
        if let playerWindow,
           !PlayerWindowPointerPolicy.isInsideWindow(
               mouseLocationOnScreen: NSEvent.mouseLocation,
               windowFrame: playerWindow.frame
           )
        {
            pointerExitedWindow()
            return
        }

        if !isMouseMove || areControlsVisible {
            pointerRevealGate.noteVisiblePointer(at: location)
            chromeMachine.registerPointerActivity(at: Self.currentTime())
            synchronizeChrome()
            return
        }

        let now = Self.currentTime()
        guard pointerRevealGate.shouldReveal(at: location, now: now) else { return }
        chromeMachine.registerPointerActivity(at: now)
        synchronizeChrome()
    }

    private func performKeyboardAction(
        _ action: PlayerKeyboardAction,
        eventTime: TimeInterval
    ) -> Bool {
        switch action {
        case .togglePause:
            return togglePauseFromKeyboard()
        case let .seek(seconds):
            guard state.currentSource != nil else { return false }
            performRelativeSeek(
                seconds,
                at: eventTime,
                registersUserActivity: PlayerKeyboardChromePolicy.shouldRegisterActivity(
                    action: action,
                    areControlsVisible: areControlsVisible
                )
            )
        case let .volume(delta):
            guard state.currentSource != nil else { return false }
            setVolumeFromUser(state.volume + delta)
        case let .stepFrame(direction):
            guard state.currentSource != nil, player.supports(.stepFrame) else {
                return false
            }
            direction < 0 ? player.stepFrameBackward() : player.stepFrameForward()
            osdPresenter.present(.status(direction < 0 ? "Previous frame" : "Next frame"))
            registerUserActivity()
        case let .chapter(direction):
            guard player.supports(.selectChapter), !state.chapters.isEmpty else {
                return false
            }
            let currentIndex = state.chapters.firstIndex {
                $0.id == state.currentChapterID
            } ?? (direction > 0 ? -1 : state.chapters.count)
            let targetIndex = min(max(currentIndex + direction, 0), state.chapters.count - 1)
            let chapter = state.chapters[targetIndex]
            player.selectChapter(chapter)
            osdPresenter.present(.status(chapter.title ?? "Chapter \(targetIndex + 1)"))
            registerUserActivity()
        case .undoSeek:
            guard let target = seekInteractionAccumulator.undoTarget() else { return false }
            player.seek(to: target)
            osdPresenter.present(.status("Seek undone  \(formatOSDTime(target))"))
            registerUserActivity()
        case .dismiss:
            if cancelActiveInteraction() {
                return true
            } else if isMessageHistoryPresented {
                isMessageHistoryPresented = false
            } else if isInspectorPresented {
                isInspectorPresented = false
            } else if isShortcutHelpPresented {
                isShortcutHelpPresented = false
            } else if isSidebarPresented {
                setSidebarVisible(false)
            } else if state.isFullscreen {
                toggleFullscreen()
            } else {
                return false
            }
        case .showShortcuts:
            isShortcutHelpPresented = true
        case .showInspector:
            guard state.currentSource != nil else { return false }
            isInspectorPresented = true
        case .toggleFullscreen:
            toggleFullscreen()
        case .toggleMute:
            guard state.currentSource != nil else { return false }
            toggleMuteFromUser()
        case .goToTime:
            guard state.currentSource != nil, state.duration > 0 else { return false }
            isGoToTimePresented = true
        case .loopA:
            setLoopStart()
        case .loopB:
            setLoopEnd()
        case .clearABLoop:
            clearLoop()
        case .screenshot:
            guard state.currentSource != nil, player.supports(.saveScreenshot) else { return false }
            saveScreenshot()
        }
        return true
    }

    private func togglePauseFromKeyboard() -> Bool {
        guard state.currentSource != nil else { return false }
        let shouldHideImmediately = PlayerKeyboardChromePolicy.shouldHideImmediately(
            action: .togglePause,
            isPauseDesired: state.isPauseDesired
        )
        player.togglePause()
        updatePlaybackChromePins()
        if shouldHideImmediately {
            pointerRevealGate.beginPostPlayCooldown(at: Self.currentTime())
            chromeMachine.hideImmediatelyForKeyboardPlay()
            synchronizeChrome()
        } else {
            registerUserActivity()
        }
        return true
    }

    private func formatOSDTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func mediaDisplayName(for url: URL) -> String {
        if url.isFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.host ?? url.absoluteString
    }

    private func fullscreenStateDidChange(_ isFullscreen: Bool, in window: NSWindow) {
        guard window === playerWindow else { return }
        player.setFullscreen(isFullscreen)
        applyAlwaysOnTop()
        updateCursorPolicy()
        if !isFullscreen {
            applyWindowAspectLock(to: window, resizeToVideo: true)
        }
    }

    private func updatePlaybackChromePins() {
        let now = Self.currentTime()
        chromeMachine.setPin(
            .windowResize,
            active: playerWindow?.inLiveResize == true && state.phase == .paused,
            now: now
        )
        chromeMachine.setPin(.noMedia, active: state.currentSource == nil, now: now)
        chromeMachine.setPin(
            .loading,
            active: keyboardSeekChromeSuppression.loadingPinIsActive(
                source: state.currentSource,
                isLoading: state.isLoading
            ),
            now: now
        )
        synchronizeChrome()
    }

    private func beginKeyboardSeekChromeSuppression(for source: MediaSource) {
        keyboardSeekChromeSuppression.begin(for: source)
        keyboardSeekChromeSuppressionExpiryTask?.cancel()
        keyboardSeekChromeSuppressionExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.keyboardSeekChromeSuppression.expireIfAwaiting(for: source)
        }
    }

    private func synchronizeChrome() {
        let previousPhase = chromePhase
        chromePhase = chromeMachine.phase
        if previousPhase != .hidden, chromePhase == .hidden {
            pointerRevealGate.controlsDidHide()
        }
        chromeScheduler?.schedule(chromeMachine.deadline)
        updateCursorPolicy()

        if chromePhase == .revealing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.chromeMachine.settleReveal()
                self.synchronizeChrome()
            }
        }
    }

    private func preserveNativeWindowControls(in window: NSWindow) {
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            guard let button = window.standardWindowButton(buttonType) else {
                continue
            }
            // Keep AppKit's native traffic-light rendering independent from
            // the player theme and video-derived text palette.
            button.contentTintColor = nil
        }
    }

    private func chromeDeadlineReached() {
        chromeMachine.deadlineReached(
            at: Self.currentTime(),
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        synchronizeChrome()
    }

    private func updateCursorPolicy() {
        let window = playerWindow
        cursorCoordinator.apply(PlaybackCursorPolicy(
            hasMedia: state.currentSource != nil,
            isWindowActive: window.map { $0.isKeyWindow && !$0.isMiniaturized } ?? false,
            isFullscreen: window?.styleMask.contains(.fullScreen) == true,
            chromePhase: chromePhase,
            region: cursorRegion,
            hasTransientPresentation: hasTransientPresentation
        ))
    }

    private var mediaContentTypes: [UTType] {
        let extensions = MediaFileSupport.videoFileExtensions
        let inferred = extensions.compactMap { UTType(filenameExtension: $0) }
        return Array(Set(inferred + [.movie, .mpeg4Movie, .quickTimeMovie]))
    }

    private var subtitleContentTypes: [UTType] {
        MediaFileSupport.subtitleFileExtensions.compactMap { extensionName in
            UTType(filenameExtension: extensionName)
        }
    }

    private func presentSubtitleDelayPanel(
        inputText: String,
        validationMessage: String?
    ) {
        guard let playerWindow, !isShuttingDown else { return }

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "0"
        input.stringValue = inputText

        let alert = NSAlert()
        alert.messageText = "Set Subtitle Delay"
        alert.informativeText = validationMessage
            ?? "Enter a delay in milliseconds from −10000 to +10000."
        alert.accessoryView = input
        alert.addButton(withTitle: "Set Delay")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        setTransientPresentation(true, owner: "subtitle-delay")
        alert.beginSheetModal(for: playerWindow) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response == .alertFirstButtonReturn else {
                    self.setTransientPresentation(false, owner: "subtitle-delay")
                    return
                }

                let submittedText = input.stringValue
                guard let seconds = SubtitleDelayInput.seconds(
                    fromMillisecondsText: submittedText
                ) else {
                    self.presentSubtitleDelayPanel(
                        inputText: submittedText,
                        validationMessage: "Enter a whole number from −10000 to +10000 milliseconds."
                    )
                    return
                }

                self.setTransientPresentation(false, owner: "subtitle-delay")
                self.setSubtitleDelayFromUser(seconds)
            }
        }
    }

    private func addContextItem(
        _ action: PlayerContextMenuAction,
        to menu: NSMenu,
        target: PlayerContextMenuTarget
    ) {
        let title: String
        let stateValue: NSControl.StateValue
        let handler: () -> Void
        switch action {
        case .playPause:
            title = state.isPauseDesired ? "Play" : "Pause"
            stateValue = .off
            handler = { [weak self] in self?.togglePauseFromUser() }
        case .previous:
            title = "Previous File"
            stateValue = .off
            handler = { [weak self] in self?.playPreviousFromUser() }
        case .next:
            title = "Next File"
            stateValue = .off
            handler = { [weak self] in self?.playNextFromUser() }
        case .seekBackward:
            title = "Seek Backward 5 Seconds"
            stateValue = .off
            handler = { [weak self] in
                self?.performRelativeSeek(-5)
            }
        case .seekForward:
            title = "Seek Forward 5 Seconds"
            stateValue = .off
            handler = { [weak self] in
                self?.performRelativeSeek(5)
            }
        case .pictureInPicture:
            title = state.pictureInPicture.isActive
                ? "Stop Picture in Picture"
                : "Start Picture in Picture"
            stateValue = .off
            handler = { [weak self] in self?.togglePictureInPicture() }
        case .fullscreen:
            title = state.isFullscreen ? "Exit Fullscreen" : "Enter Fullscreen"
            stateValue = .off
            handler = { [weak self] in self?.toggleFullscreen() }
        case .alwaysOnTop:
            title = "Always on Top"
            stateValue = isAlwaysOnTop ? .on : .off
            handler = { [weak self] in self?.toggleAlwaysOnTop() }
        case .screenshot:
            title = "Save Screenshot…"
            stateValue = .off
            handler = { [weak self] in self?.saveScreenshot() }
        case .showInFinder:
            title = "Show in Finder"
            stateValue = .off
            handler = { [weak self] in
                guard let url = self?.state.currentURL, url.isFileURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .copyPath:
            title = state.currentURL?.isFileURL == true ? "Copy File Path" : "Copy URL"
            stateValue = .off
            handler = { [weak self] in
                guard let url = self?.state.currentURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    url.isFileURL ? url.path : url.absoluteString,
                    forType: .string
                )
            }
        case .inspector:
            title = "Playback Inspector…"
            stateValue = .off
            handler = { [weak self] in self?.isInspectorPresented = true }
        case .audioTracks, .subtitles:
            return
        }
        menu.addItem(target.item(title: title, state: stateValue, action: handler))
    }

    private func trackMenuItem(
        kind: MediaTrackKind,
        target: PlayerContextMenuTarget
    ) -> NSMenuItem {
        let title = kind == .audio ? "Audio Track" : "Subtitles"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        if kind == .subtitle {
            submenu.addItem(target.item(
                title: "Off",
                state: state.selectedSubtitleTrack == nil ? .on : .off
            ) { [weak self] in
                self?.selectSubtitleTrackFromUser(nil)
            })
        }
        let tracks = kind == .audio ? state.audioTracks : state.subtitleTracks
        let selectedID = kind == .audio
            ? state.selectedAudioTrack?.id
            : state.selectedSubtitleTrack?.id
        if tracks.isEmpty {
            let empty = NSMenuItem(title: "No Tracks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for track in tracks {
                submenu.addItem(target.item(
                    title: track.displayName,
                    state: track.id == selectedID ? .on : .off
                ) { [weak self] in
                    if kind == .audio {
                        self?.selectAudioTrackFromUser(track)
                    } else {
                        self?.selectSubtitleTrackFromUser(track)
                    }
                })
            }
        }
        parent.submenu = submenu
        return parent
    }

    private static let windowFrameKey = "Superplayr.player-window-frame.v1"
    private static let windowAspectLockKey = "Superplayr.player-window-aspect-locked.v1"
    private static let alwaysOnTopKey = "Superplayr.player-window-always-on-top.v1"
    private static let sourceFoldersKey = "Superplayr.source-folders.v1"
    private static let activeSourceFolderKey = "Superplayr.active-source-folder.v1"
    private static let sourceTabsKey = "Superplayr.source-tabs.v1"
    private static let activeSourceTabKey = "Superplayr.active-source-tab.v1"

    private static func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

enum SourceFolderLibrary {
    static func restore(from storedValue: [Any]?) -> [URL] {
        merging(
            [],
            with: (storedValue ?? []).compactMap { value in
                guard let path = value as? String, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        )
    }

    static func merging(_ existing: [URL], with additions: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for candidate in existing + additions {
            guard candidate.isFileURL else { continue }
            let normalized = NormalizedFileURL.normalize(candidate) ?? candidate.absoluteURL.standardized
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}

struct SourceTabItem: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case folder
    }

    let kind: Kind
    let path: String

    init(kind: Kind, url: URL) {
        self.kind = kind
        path = (
            NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized
        ).path
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: kind == .folder)
    }
}

struct SourceTab: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var items: [SourceTabItem]
    var visibility: SourceVisibilityConfiguration?

    var displayName: String {
        if let folder = items.first(where: { $0.kind == .folder }) {
            return folder.url.lastPathComponent
        }
        if let file = items.first(where: { $0.kind == .file }) {
            return file.url.deletingPathExtension().lastPathComponent
        }
        return "New Tab"
    }

    init(
        id: String,
        items: [SourceTabItem],
        visibility: SourceVisibilityConfiguration? = nil
    ) {
        self.id = id
        self.items = items
        self.visibility = visibility
    }
}

enum SourceVisibilityViewMode: String, Codable, CaseIterable, Sendable {
    case tree
    case filesOnly
    case foldersOnly
    case media

    var scansRecursively: Bool { self == .filesOnly || self == .media }

    var title: String {
        switch self {
        case .tree:
            "Tree"
        case .filesOnly:
            "Files Only"
        case .foldersOnly:
            "Folders Only"
        case .media:
            "Media"
        }
    }

    var systemImage: String {
        switch self {
        case .tree:
            "list.bullet.indent"
        case .filesOnly:
            "doc"
        case .foldersOnly:
            "folder"
        case .media:
            "film.stack"
        }
    }
}

struct SourceVisibilityRegexRule: Codable, Equatable, Identifiable, Sendable {
    static let colorCount = 6

    let id: String
    let pattern: String
    let colorIndex: Int
    var isEnabled: Bool

    static func isValid(pattern: String) -> Bool {
        !pattern.isEmpty
            && pattern.count <= 512
            && (try? NSRegularExpression(pattern: pattern)) != nil
    }

    static func nextColorIndex(
        after rules: [SourceVisibilityRegexRule]
    ) -> Int {
        guard let last = rules.last else { return 0 }
        return (last.colorIndex + 1) % colorCount
    }
}

struct SourceVisibilityConfiguration: Codable, Equatable, Sendable {
    static let `default` = Self(
        viewMode: .tree,
        showsHiddenItems: false,
        manuallyHiddenPaths: [],
        alwaysShownPaths: [],
        regexRules: []
    )

    var viewMode: SourceVisibilityViewMode
    var showsHiddenItems: Bool
    var manuallyHiddenPaths: Set<String>
    var alwaysShownPaths: Set<String>
    var regexRules: [SourceVisibilityRegexRule]

    var isDefault: Bool {
        self == .default
    }

    mutating func normalize() {
        manuallyHiddenPaths = SourceVisibilityPath.normalized(
            manuallyHiddenPaths
        )
        alwaysShownPaths = SourceVisibilityPath.normalized(alwaysShownPaths)
        alwaysShownPaths.subtract(manuallyHiddenPaths)

        var seenIDs: Set<String> = []
        var seenPatterns: Set<String> = []
        regexRules = regexRules.compactMap { rule in
            let pattern = rule.pattern.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !rule.id.isEmpty,
                  seenIDs.insert(rule.id).inserted,
                  seenPatterns.insert(pattern).inserted,
                  SourceVisibilityRegexRule.isValid(pattern: pattern)
            else {
                return nil
            }
            return SourceVisibilityRegexRule(
                id: rule.id,
                pattern: pattern,
                colorIndex: min(
                    max(rule.colorIndex, 0),
                    SourceVisibilityRegexRule.colorCount - 1
                ),
                isEnabled: rule.isEnabled
            )
        }
    }
}

enum SourceVisibilityPath {
    static func normalized(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return (NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized).path
    }

    static func normalized(_ paths: Set<String>) -> Set<String> {
        Set(paths.compactMap { path in
            guard path.hasPrefix("/") else { return nil }
            return normalized(URL(fileURLWithPath: path, isDirectory: false))
        })
    }
}

enum SourceTabItems {
    /// File-heavy tabs must not compare every parent against every prior parent
    /// on the UI actor. URL normalization here is lexical, with no filesystem IO.
    static func watchRoots(for items: [SourceTabItem]) -> [URL] {
        var seen: Set<String> = []
        return items.compactMap { item in
            let root = item.kind == .folder ? item.url : item.url.deletingLastPathComponent()
            let normalized = NormalizedFileURL.normalize(root) ?? root.absoluteURL.standardized
            guard seen.insert(normalized.path).inserted else { return nil }
            return normalized
        }
    }

    static func merging(
        _ existing: [SourceTabItem],
        with additions: [URL],
        kind: SourceTabItem.Kind
    ) -> [SourceTabItem] {
        merging(
            existing,
            with: additions
                .filter(\.isFileURL)
                .map { SourceTabItem(kind: kind, url: $0) }
        )
    }

    static func merging(
        _ existing: [SourceTabItem],
        with additions: [SourceTabItem]
    ) -> [SourceTabItem] {
        var result: [SourceTabItem] = []
        var seen: Set<SourceTabItem> = []
        result.reserveCapacity(existing.count + additions.count)
        for item in existing + additions {
            guard !item.path.isEmpty else { continue }
            // Decoded items may contain noncanonical paths. Normalize once and
            // retain the first occurrence of each (kind, canonical path) pair.
            let canonical = SourceTabItem(kind: item.kind, url: item.url)
            guard seen.insert(canonical).inserted else { continue }
            result.append(canonical)
        }
        return result
    }
}

enum SourceTabStore {
    static func restore(from data: Data?) -> [SourceTab]? {
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode([SourceTab].self, from: data)
        else {
            return nil
        }
        var restored: [SourceTab] = []
        for tab in decoded {
            guard !tab.id.isEmpty,
                  !restored.contains(where: { $0.id == tab.id })
            else {
                continue
            }
            restored.append(SourceTab(
                id: tab.id,
                items: SourceTabItems.merging([], with: tab.items),
                visibility: normalizedVisibility(tab.visibility)
            ))
        }
        return restored
    }

    static func encode(_ tabs: [SourceTab]) -> Data? {
        try? JSONEncoder().encode(tabs)
    }

    private static func normalizedVisibility(
        _ stored: SourceVisibilityConfiguration?
    ) -> SourceVisibilityConfiguration? {
        guard var stored else { return nil }
        stored.normalize()
        return stored.isDefault ? nil : stored
    }
}

enum SourceTabDirection: Sendable {
    case previous
    case next
}

enum SourceTabs {
    static func migratedTabID(forFolderID folderID: String) -> String {
        "folder:\(folderID)"
    }

    static func migrating(_ folders: [URL]) -> [SourceTab] {
        folders.map { folder in
            let folderID = (
                NormalizedFileURL.normalize(folder) ?? folder.absoluteURL.standardized
            ).path
            return SourceTab(
                id: migratedTabID(forFolderID: folderID),
                items: [SourceTabItem(kind: .folder, url: folder)]
            )
        }
    }

    static func resolvedSelection(
        _ selectedID: String?,
        in tabs: [SourceTab]
    ) -> String? {
        if let selectedID,
           tabs.contains(where: { $0.id == selectedID })
        {
            return selectedID
        }
        return tabs.first?.id
    }

    static func activeTab(
        selectedID: String?,
        in tabs: [SourceTab]
    ) -> SourceTab? {
        guard let resolvedID = resolvedSelection(selectedID, in: tabs) else {
            return nil
        }
        return tabs.first { $0.id == resolvedID }
    }

    static func selectionAfterClosing(
        _ closedID: String,
        selectedID: String?,
        from tabs: [SourceTab]
    ) -> String? {
        guard let closedIndex = tabs.firstIndex(where: { $0.id == closedID })
        else {
            return resolvedSelection(selectedID, in: tabs)
        }

        let remaining = tabs.enumerated().compactMap { index, tab in
            index == closedIndex ? nil : tab
        }
        guard selectedID == closedID
                || activeTab(selectedID: selectedID, in: tabs) == nil
        else {
            return resolvedSelection(selectedID, in: remaining)
        }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(closedIndex, remaining.count - 1)].id
    }

    static func adjacentSelection(
        from selectedID: String?,
        direction: SourceTabDirection,
        in tabs: [SourceTab]
    ) -> String? {
        guard !tabs.isEmpty else { return nil }
        let resolvedID = resolvedSelection(selectedID, in: tabs)
        let currentIndex = tabs.firstIndex { $0.id == resolvedID } ?? 0
        let offset = switch direction {
        case .previous:
            tabs.count - 1
        case .next:
            1
        }
        let nextIndex = (currentIndex + offset) % tabs.count
        return tabs[nextIndex].id
    }

    static func contains(_ candidate: URL, in tab: SourceTab) -> Bool {
        tab.items.contains { item in
            switch item.kind {
            case .file:
                NormalizedFileURL.representsSameFile(candidate, item.url)
            case .folder:
                contains(candidate, inside: item.url)
            }
        }
    }

    private static func contains(_ candidate: URL, inside folder: URL) -> Bool {
        guard candidate.isFileURL, folder.isFileURL else { return false }
        let candidateComponents = (
            NormalizedFileURL.normalize(candidate) ?? candidate.absoluteURL.standardized
        ).pathComponents
        let folderComponents = (
            NormalizedFileURL.normalize(folder) ?? folder.absoluteURL.standardized
        ).pathComponents
        return candidateComponents.starts(with: folderComponents)
    }
}

private struct PlaybackLifecycleObservation: Equatable {
    let phase: PlaybackPhase
    let source: MediaSource?
    let isPauseDesired: Bool
    let videoAspectRatio: Double?
    let lastError: String?
    let isPictureInPictureActive: Bool
}

enum NowPlayingRefreshPolicy {
    static func shouldRefreshContinuously(phase: PlaybackPhase) -> Bool {
        phase == .playing
    }
}

enum WindowUIObservationPolicy {
    static func shouldObserve(
        isApplicationActive: Bool,
        isWindowVisible: Bool,
        isMiniaturized: Bool,
        isOccluded: Bool
    ) -> Bool {
        isApplicationActive && isWindowVisible && !isMiniaturized && !isOccluded
    }
}

enum PlayerWindowRestoreReadiness {
    static func shouldReportSuccess(
        windowExists: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        surfaceAttached: Bool
    ) -> Bool {
        windowExists && windowVisible && !windowMiniaturized && surfaceAttached
    }
}

enum WindowAspectLockSizing {
    static func fittedContentSize(
        currentSize: CGSize,
        minimumSize: CGSize,
        aspectRatio: Double
    ) -> CGSize? {
        guard currentSize.width > 0, currentSize.height > 0,
              aspectRatio.isFinite, aspectRatio > 0
        else { return nil }

        let preservingWidth = CGSize(
            width: currentSize.width,
            height: currentSize.width / aspectRatio
        )
        let preservingHeight = CGSize(
            width: currentSize.height * aspectRatio,
            height: currentSize.height
        )
        let widthAdjustment = abs(preservingWidth.height - currentSize.height)
        let heightAdjustment = abs(preservingHeight.width - currentSize.width)
        var result = widthAdjustment <= heightAdjustment
            ? preservingWidth
            : preservingHeight

        if result.width < minimumSize.width {
            result.width = minimumSize.width
            result.height = result.width / aspectRatio
        }
        if result.height < minimumSize.height {
            result.height = minimumSize.height
            result.width = result.height * aspectRatio
        }
        return result
    }
}

struct PointerRevealGate {
    private let revealDistance: CGFloat
    private let postPlayCooldown: TimeInterval
    private var lastLocation: CGPoint?
    private var revealOrigin: CGPoint?
    private var movementRevealSuppressedUntil: TimeInterval?

    init(
        revealDistance: CGFloat = 8,
        postPlayCooldown: TimeInterval = PlaybackToggleChromePolicy.pointerRevealCooldown
    ) {
        self.revealDistance = revealDistance
        self.postPlayCooldown = postPlayCooldown
    }

    mutating func noteVisiblePointer(at location: CGPoint) {
        lastLocation = location
        revealOrigin = nil
    }

    mutating func controlsDidHide() {
        revealOrigin = lastLocation
    }

    mutating func beginPostPlayCooldown(at now: TimeInterval) {
        movementRevealSuppressedUntil = now + postPlayCooldown
        revealOrigin = lastLocation
    }

    mutating func shouldReveal(at location: CGPoint, now: TimeInterval = 0) -> Bool {
        if let suppressedUntil = movementRevealSuppressedUntil {
            if now < suppressedUntil {
                lastLocation = location
                return false
            }
            movementRevealSuppressedUntil = nil
            lastLocation = location
            revealOrigin = location
            return false
        }

        let origin = revealOrigin ?? lastLocation ?? location
        revealOrigin = origin
        lastLocation = location

        let distance = hypot(location.x - origin.x, location.y - origin.y)
        guard distance >= revealDistance else { return false }
        revealOrigin = nil
        return true
    }
}
