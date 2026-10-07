import AppKit
import IlliquidPlayer

enum PlayerContextMenuAction: CaseIterable, Equatable {
    case playPause
    case previous
    case next
    case seekBackward
    case seekForward
    case audioTracks
    case subtitles
    case pictureInPicture
    case fullscreen
    case alwaysOnTop
    case screenshot
    case showInFinder
    case copyPath
    case inspector
}

struct PlayerContextMenuAvailability {
    let capabilities: PlayerCapabilityModel
    let hasSource: Bool
    let isLocalSource: Bool
    let hasPrevious: Bool
    let hasNext: Bool

    var actions: [PlayerContextMenuAction] {
        guard hasSource else { return [] }
        var result: [PlayerContextMenuAction] = [.playPause]
        if hasPrevious { result.append(.previous) }
        if hasNext { result.append(.next) }
        if capabilities.supports(.seekRelative) {
            result += [.seekBackward, .seekForward]
        }
        if capabilities.supports(.selectAudioTrack) {
            result.append(.audioTracks)
        }
        if capabilities.supports(.selectSubtitleTrack) {
            result.append(.subtitles)
        }
        if capabilities.supports(.pictureInPicture) {
            result.append(.pictureInPicture)
        }
        result += [.fullscreen, .alwaysOnTop]
        if capabilities.supports(.saveScreenshot) {
            result.append(.screenshot)
        }
        if isLocalSource {
            result.append(.showInFinder)
        }
        result += [.copyPath, .inspector]
        return result
    }
}

enum SurfaceScrollAction: Equatable {
    case seek(TimeInterval)
    case volume(Double)
}

struct SurfaceScrollAccumulator {
    private var axis: Axis?
    private var pendingHorizontal: Double = 0

    private enum Axis {
        case horizontal
        case vertical
    }

    mutating func cancel() {
        axis = nil
        pendingHorizontal = 0
    }

    mutating func consume(_ event: PlaybackSurfaceScroll) -> SurfaceScrollAction? {
        if event.phase == .cancelled || event.phase == .momentumEnded {
            cancel()
            return nil
        }
        if event.phase == .began || event.phase == .discrete {
            pendingHorizontal = 0
            axis = abs(event.deltaX) > abs(event.deltaY) ? .horizontal : .vertical
        } else if axis == nil {
            // Only a fresh gesture may acquire the surface. Late changed or
            // momentum events cannot restart a cancelled transaction.
            return nil
        }

        defer {
            if event.phase == .discrete { cancel() }
        }
        // Finger lift is followed by momentum on a trackpad; retain its axis
        // until momentum ends or the surface loses ownership.
        if event.phase == .ended { return nil }

        switch axis {
        case .horizontal:
            pendingHorizontal += event.deltaX
            let threshold = event.isPrecise ? 8.0 : 1.0
            guard abs(pendingHorizontal) >= threshold else { return nil }
            let steps = (pendingHorizontal / threshold).rounded(.towardZero)
            pendingHorizontal.formTruncatingRemainder(dividingBy: threshold)
            return .seek(steps * 5)
        case .vertical:
            let scale = event.isPrecise ? 0.5 : 5
            let delta = event.deltaY * scale
            return abs(delta) >= 0.01 ? .volume(delta) : nil
        case nil:
            return nil
        }
    }
}

struct SeekInteractionAccumulator {
    private let coalescingInterval: TimeInterval
    private var sequenceOrigin: TimeInterval?
    private var pendingTarget: TimeInterval?
    private var lastInputTime: TimeInterval?

    init(coalescingInterval: TimeInterval = 0.75) {
        self.coalescingInterval = coalescingInterval
    }

    mutating func relativeTarget(
        delta: TimeInterval,
        currentPosition: TimeInterval,
        duration: TimeInterval,
        at now: TimeInterval
    ) -> TimeInterval {
        let continuesSequence = lastInputTime.map {
            now - $0 <= coalescingInterval
        } ?? false
        if !continuesSequence {
            sequenceOrigin = currentPosition
            pendingTarget = currentPosition
        }
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = min(max((pendingTarget ?? currentPosition) + delta, 0), upperBound)
        pendingTarget = target
        lastInputTime = now
        return target
    }

    mutating func undoTarget() -> TimeInterval? {
        defer { reset() }
        return sequenceOrigin
    }

    mutating func reset() {
        sequenceOrigin = nil
        pendingTarget = nil
        lastInputTime = nil
    }
}

@MainActor
final class PlayerContextMenuTarget: NSObject, NSMenuDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func menuDidClose(_ menu: NSMenu) {
        onClose()
    }

    func item(title: String, state: NSControl.StateValue = .off, action: @escaping () -> Void) -> NSMenuItem {
        let target = PlayerMenuItemTarget(action: action)
        let item = NSMenuItem(
            title: title,
            action: #selector(PlayerMenuItemTarget.invokeAction),
            keyEquivalent: ""
        )
        item.target = target
        item.state = state
        item.representedObject = target
        return item
    }
}

private final class PlayerMenuItemTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invokeAction() {
        action()
    }
}
