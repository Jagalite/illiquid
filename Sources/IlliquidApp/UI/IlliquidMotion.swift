import SwiftUI

/// Illiquid's event-driven motion language.
///
/// These tokens are intentionally limited to low-frequency interface state.
/// Playback position, buffering ranges, decoded frames, subtitle timing, and
/// authoritative media state must never be driven by these animations.
enum IlliquidMotion {
    enum Duration {
        static let micro = 0.10
        static let control = 0.15
        static let panel = 0.225
        static let major = 0.30
        static let quietExit = 0.14
    }

    enum Distance {
        static let bottomChrome: CGFloat = 8
        static let topChrome: CGFloat = 5
        static let sidebar: CGFloat = 12
        static let compactEntrance: CGFloat = 5
        static let rowEntrance: CGFloat = 4
    }

    static let usesContinuousAnimation = false

    static func crispHover(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: Duration.micro)
    }

    static func softEntrance(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .timingCurve(0.18, 0.86, 0.28, 1, duration: Duration.control)
    }

    static func tactilePress(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .spring(duration: Duration.control, bounce: 0.12)
    }

    static func stateMorph(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .spring(duration: Duration.control, bounce: 0.08)
    }

    static func panelEntrance(
        reduceMotion: Bool,
        delay: TimeInterval = 0
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        return .timingCurve(0.16, 0.84, 0.22, 1, duration: Duration.panel)
            .delay(delay)
    }

    static func quietExit(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: Duration.quietExit)
    }

    static func majorContext(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .spring(duration: Duration.major, bounce: 0.06)
    }

    static func offset(_ distance: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : distance
    }

    static func scale(_ scale: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : scale
    }
}

enum IlliquidMotionTransition {
    static func compactEntrance(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(
                with: .offset(y: IlliquidMotion.Distance.compactEntrance)
            ),
            removal: .opacity.combined(with: .scale(scale: 0.985))
        )
    }

    static func calmError(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)),
            removal: .opacity
        )
    }

    static func sidebar(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(
                with: .offset(x: -IlliquidMotion.Distance.sidebar)
            ),
            removal: .opacity.combined(
                with: .offset(x: -IlliquidMotion.Distance.sidebar * 0.65)
            )
        )
    }
}
