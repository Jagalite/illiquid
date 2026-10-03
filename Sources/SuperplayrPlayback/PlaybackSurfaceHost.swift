import AppKit
import Foundation
import SuperplayrCore

public enum PlaybackSurfaceScrollPhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case cancelled
    case momentum
    case momentumEnded
    case discrete
}

public struct PlaybackSurfaceScroll: Equatable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    public let isPrecise: Bool
    public let phase: PlaybackSurfaceScrollPhase

    public init(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        phase: PlaybackSurfaceScrollPhase
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.phase = phase
    }
}

public enum PlaybackSurfaceInteraction: Equatable, Sendable {
    case pointerEntered
    case pointerMoved(CGPoint)
    case pointerExited(CGPoint)
    case primaryClick
    case doubleClick
    case togglePause
    case seekRelative(TimeInterval)
    case auxiliaryButton(Int)
    case scroll(PlaybackSurfaceScroll)
}

@MainActor
public protocol PlaybackSurfaceHost: AnyObject {
    var view: NSView { get }
    var videoViewportSize: CGSize { get }
    var onOpenURLs: (([URL], PlaylistOpenMode) -> Void)? { get set }
    var onUserActivity: (() -> Void)? { get set }
    var onInteraction: ((PlaybackSurfaceInteraction) -> Void)? { get set }
    var contextMenuProvider: (() -> NSMenu?)? { get set }

    func updateDisplay(screen: NSScreen?)
    func setPlaybackPhase(_ phase: PlaybackPhase)
    func shutdown()
}
