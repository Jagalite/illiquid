import AppKit
import Foundation
import SuperplayrCore

enum PlaybackChromePhase: Equatable {
    case hidden
    case revealing
    case visible
    case hiding
    case pinned

    var isMounted: Bool { self != .hidden }
    var isOpaque: Bool { self != .hidden && self != .hiding }
}

enum PlaybackChromePinReason: CaseIterable, Hashable {
    case noMedia
    case alwaysVisible
    case playbackFocus
    case loading
    case pointerOverChrome
    case pointerOverSidebar
    case scrubbing
    case volumePopover
    case sourceVisibilityPopover
    case sidebarResize
    case windowResize
    case chromeFocus
    case transientPresentation
    case accessibilityInteraction
    case chromeDrag
    case manipulation
    case benchmark
}

struct KeyboardSeekChromeSuppression {
    private(set) var source: MediaSource?
    private(set) var hasObservedLoading = false

    mutating func begin(for source: MediaSource) {
        if self.source != source {
            self.source = source
            hasObservedLoading = false
        }
    }

    mutating func loadingPinIsActive(
        source currentSource: MediaSource?,
        isLoading: Bool
    ) -> Bool {
        guard let source, source == currentSource else {
            reset()
            return isLoading
        }

        if isLoading {
            hasObservedLoading = true
            return false
        }

        if hasObservedLoading {
            reset()
        }
        return false
    }

    mutating func expireIfAwaiting(for source: MediaSource) {
        guard self.source == source, !hasObservedLoading else { return }
        reset()
    }

    private mutating func reset() {
        source = nil
        hasObservedLoading = false
    }
}

enum PlaybackChromeDeadline: Equatable {
    case autoHide(TimeInterval)
    case finishHiding(TimeInterval)

    var instant: TimeInterval {
        switch self {
        case let .autoHide(instant), let .finishHiding(instant):
            instant
        }
    }
}

struct PlaybackChromeStateMachine {
    static let defaultAutoHideInterval: TimeInterval = 2.5
    static let defaultFadeDuration: TimeInterval = PlatinumMotion.Duration.panel

    let autoHideInterval: TimeInterval
    let fadeDuration: TimeInterval

    private(set) var phase: PlaybackChromePhase = .visible
    private(set) var pinReasons: Set<PlaybackChromePinReason> = []
    private(set) var deadline: PlaybackChromeDeadline?
    private(set) var isPointerOutside = false

    init(
        autoHideInterval: TimeInterval = Self.defaultAutoHideInterval,
        fadeDuration: TimeInterval = Self.defaultFadeDuration
    ) {
        self.autoHideInterval = autoHideInterval
        self.fadeDuration = fadeDuration
    }

    mutating func setPin(
        _ reason: PlaybackChromePinReason,
        active: Bool,
        now: TimeInterval
    ) {
        if active {
            pinReasons.insert(reason)
        } else {
            pinReasons.remove(reason)
        }

        if !pinReasons.isEmpty {
            phase = .pinned
            deadline = nil
        } else if phase == .pinned {
            if isPointerOutside {
                phase = .hidden
                deadline = nil
            } else {
                phase = .visible
                deadline = .autoHide(now + autoHideInterval)
            }
        }
    }

    mutating func registerActivity(at now: TimeInterval) {
        guard !isPointerOutside else {
            phase = pinReasons.isEmpty ? .hidden : .pinned
            deadline = nil
            return
        }
        guard pinReasons.isEmpty else {
            phase = .pinned
            deadline = nil
            return
        }
        phase = phase == .hidden || phase == .hiding ? .revealing : .visible
        deadline = .autoHide(now + autoHideInterval)
    }

    mutating func revealForKeyboardNavigation(at now: TimeInterval) {
        phase = pinReasons.isEmpty ? .revealing : .pinned
        deadline = pinReasons.isEmpty ? .autoHide(now + autoHideInterval) : nil
    }

    mutating func registerPointerActivity(at now: TimeInterval) {
        isPointerOutside = false
        registerActivity(at: now)
    }

    mutating func revealForLaunch(at now: TimeInterval) {
        registerActivity(at: now)
    }

    mutating func settleReveal() {
        guard phase == .revealing else { return }
        phase = pinReasons.isEmpty ? .visible : .pinned
    }

    mutating func hideImmediately(reducedMotion: Bool, now: TimeInterval) {
        guard pinReasons.isEmpty else { return }
        if reducedMotion || fadeDuration <= 0 {
            phase = .hidden
            deadline = nil
        } else {
            phase = .hiding
            deadline = .finishHiding(now + fadeDuration)
        }
    }

    mutating func handleSurfaceClick(reducedMotion: Bool, now: TimeInterval) {
        if phase == .hidden || phase == .hiding {
            registerPointerActivity(at: now)
            return
        }

        pinReasons.remove(.pointerOverChrome)
        pinReasons.remove(.pointerOverSidebar)
        pinReasons.remove(.chromeFocus)
        hideImmediately(reducedMotion: reducedMotion, now: now)
    }

    mutating func hideImmediatelyForKeyboardPlay() {
        hideImmediatelyClearingPassivePins()
    }

    mutating func hideImmediatelyForPictureInPictureStart() {
        hideImmediatelyClearingPassivePins()
    }

    mutating func hideForPointerExit(reducedMotion: Bool, now: TimeInterval) {
        isPointerOutside = true
        pinReasons.remove(.pointerOverChrome)
        pinReasons.remove(.pointerOverSidebar)
        pinReasons.remove(.chromeFocus)
        hideImmediately(reducedMotion: reducedMotion, now: now)
    }

    private mutating func hideImmediatelyClearingPassivePins() {
        let passivePins: Set<PlaybackChromePinReason> = [
            .pointerOverChrome,
            .pointerOverSidebar,
            .chromeFocus,
        ]
        guard pinReasons.isSubset(of: passivePins) else { return }
        pinReasons.removeAll()
        phase = .hidden
        deadline = nil
    }

    mutating func deadlineReached(at now: TimeInterval, reducedMotion: Bool) {
        guard let deadline, now >= deadline.instant else { return }
        switch deadline {
        case .autoHide:
            hideImmediately(reducedMotion: reducedMotion, now: now)
        case .finishHiding:
            phase = pinReasons.isEmpty ? .hidden : .pinned
            self.deadline = nil
        }
    }
}

@MainActor
final class PlaybackChromeDeadlineScheduler {
    private var timer: Timer?
    private let now: () -> TimeInterval
    private let onDeadline: () -> Void

    init(
        now: @escaping () -> TimeInterval,
        onDeadline: @escaping () -> Void
    ) {
        self.now = now
        self.onDeadline = onDeadline
    }

    func schedule(_ deadline: PlaybackChromeDeadline?) {
        guard let deadline else {
            timer?.invalidate()
            timer = nil
            return
        }

        let interval = max(0, deadline.instant - now())
        if let timer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: interval)
            return
        }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timer = nil
                self.onDeadline()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

enum PlaybackCursorRegion: Equatable {
    case video
    case chrome
    case sidebar
    case titlebar
    case transientUI
    case outside
}

struct PlaybackCursorPolicy {
    var hasMedia: Bool
    var isWindowActive: Bool
    var isFullscreen: Bool
    var chromePhase: PlaybackChromePhase
    var region: PlaybackCursorRegion
    var hasTransientPresentation: Bool

    var shouldPreventSystemAutoHide: Bool {
        !isFullscreen
    }

    var shouldHide: Bool {
        hasMedia
            && isWindowActive
            && isFullscreen
            && chromePhase == .hidden
            && (region == .video || region == .chrome)
            && !hasTransientPresentation
    }
}

@MainActor
final class PlaybackCursorCoordinator {
    private(set) var isCursorHidden = false

    func apply(_ policy: PlaybackCursorPolicy) {
        if policy.shouldPreventSystemAutoHide {
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        if policy.shouldHide, !isCursorHidden {
            NSCursor.hide()
            isCursorHidden = true
        } else if !policy.shouldHide, isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
    }

    /// AppKit can reveal a hidden cursor for a click. Balance the existing hide
    /// before reapplying so repeated clicks never grow the global hide count.
    func reapplyAfterClick(if policy: PlaybackCursorPolicy) {
        guard policy.shouldHide, isCursorHidden else { return }
        NSCursor.unhide()
        NSCursor.hide()
    }

    func restore() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }
}
