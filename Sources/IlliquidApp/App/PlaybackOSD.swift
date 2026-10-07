import AppKit
import Observation
import SwiftUI

enum PlaybackOSDItem: Equatable {
    case seek(delta: TimeInterval, target: TimeInterval)
    case mediaChanged(String)
    case mediaCompleted(String)
    case volume(value: Double, isMuted: Bool)
    case audioTrack(String)
    case subtitle(String)
    case subtitleDelay(TimeInterval)
    case status(String)
    case error(String)

    var systemImage: String {
        switch self {
        case let .seek(delta, _): delta < 0 ? "gobackward" : "goforward"
        case .mediaChanged: "play.rectangle.fill"
        case .mediaCompleted: "checkmark.circle.fill"
        case let .volume(_, isMuted): isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .audioTrack: "waveform"
        case .subtitle, .subtitleDelay: "captions.bubble"
        case .status: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var text: String {
        switch self {
        case let .seek(delta, target):
            "\(delta >= 0 ? "+" : "−")\(Int(abs(delta).rounded())) s  \(formatTime(target))"
        case let .mediaChanged(name):
            "Opened \(name)"
        case let .mediaCompleted(name):
            "Finished \(name)"
        case let .volume(value, isMuted):
            isMuted ? "Muted" : "Volume \(Int(value.rounded()))%"
        case let .audioTrack(name):
            "Audio: \(name)"
        case let .subtitle(name):
            "Subtitles: \(name)"
        case let .subtitleDelay(delay):
            String(format: "Subtitle delay %+.1f s", delay)
        case let .status(message), let .error(message):
            message
        }
    }

    var isError: Bool {
        if case .error = self { true } else { false }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        let remainingSeconds = value % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

struct PlaybackMessage: Identifiable, Equatable {
    let id: Int
    var item: PlaybackOSDItem
    let date: Date
}

struct PlaybackOSDStateMachine {
    static let defaultLifetime: TimeInterval = 1

    let lifetime: TimeInterval
    private(set) var item: PlaybackOSDItem?
    private(set) var deadline: TimeInterval?

    init(lifetime: TimeInterval = Self.defaultLifetime) {
        self.lifetime = lifetime
    }

    mutating func present(_ incoming: PlaybackOSDItem, at now: TimeInterval) {
        deadlineReached(at: now)
        if case let .seek(existingDelta, _) = item,
           case let .seek(newDelta, target) = incoming
        {
            item = .seek(delta: existingDelta + newDelta, target: target)
        } else {
            item = incoming
        }
        deadline = now + lifetime
    }

    mutating func invalidate() {
        item = nil
        deadline = nil
    }

    mutating func deadlineReached(at now: TimeInterval) {
        guard let deadline, now >= deadline else { return }
        item = nil
        self.deadline = nil
    }
}

@MainActor
@Observable
final class PlaybackOSDPresenter {
    private(set) var item: PlaybackOSDItem?
    private(set) var messages: [PlaybackMessage] = []
    @ObservationIgnored private var stateMachine = PlaybackOSDStateMachine()
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var nextMessageID = 0

    private static let maximumMessageCount = 50

    func present(_ item: PlaybackOSDItem) {
        stateMachine.deadlineReached(at: Self.now())
        let existingItem = stateMachine.item
        stateMachine.present(item, at: Self.now())
        self.item = stateMachine.item
        recordMessage(replacingCurrent: shouldCoalesce(existingItem, with: item))
        scheduleDeadline()
        switch item {
        case .mediaChanged, .audioTrack, .subtitle, .error:
            if NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp.keyWindow {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                    userInfo: [.announcement: item.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        default: break
        }
    }

    func clearHistory() {
        messages.removeAll()
    }

    func invalidate() {
        deadlineTask?.cancel()
        deadlineTask = nil
        stateMachine.invalidate()
        item = nil
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = stateMachine.deadline else { return }
        let interval = max(0, deadline - Self.now())
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.deadlineTask = nil
            self.stateMachine.deadlineReached(at: Self.now())
            self.item = self.stateMachine.item
            if self.stateMachine.deadline != nil { self.scheduleDeadline() }
        }
    }

    private func recordMessage(replacingCurrent: Bool) {
        guard let item = stateMachine.item else { return }
        if replacingCurrent, !messages.isEmpty {
            messages[messages.count - 1].item = item
            return
        }
        messages.append(PlaybackMessage(id: nextMessageID, item: item, date: Date()))
        nextMessageID += 1
        if messages.count > Self.maximumMessageCount {
            messages.removeFirst(messages.count - Self.maximumMessageCount)
        }
    }

    private func shouldCoalesce(
        _ existing: PlaybackOSDItem?,
        with incoming: PlaybackOSDItem
    ) -> Bool {
        guard case .seek = existing, case .seek = incoming else { return false }
        return true
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

struct PlaybackOSDView: View {
    @Bindable var presenter: PlaybackOSDPresenter
    let showHistory: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let item = presenter.item {
                Button(action: showHistory) {
                    HStack(spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                            .contentTransition(.opacity)
                            .foregroundStyle(item.isError ? Color.yellow : Color.primary)
                            .accessibilityHidden(true)
                        Text(item.text)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .dynamicPlayerTextStyle()
                .playerOverlaySurface(cornerRadius: 10, role: .status)
                .accessibilityLabel(item.text)
                .accessibilityHint("Shows playback message history")
                .help("Show Message History")
                .frame(maxWidth: 420, alignment: .trailing)
                .transition(.opacity)
                .animation(
                    IlliquidMotion.stateMorph(reduceMotion: reduceMotion),
                    value: item
                )
            }
        }
        .animation(
            presenter.item == nil
                ? IlliquidMotion.quietExit(reduceMotion: reduceMotion)
                : IlliquidMotion.softEntrance(reduceMotion: reduceMotion),
            value: presenter.item
        )
    }
}

struct PlaybackMessageHistoryView: View {
    @Bindable var presenter: PlaybackOSDPresenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playback Messages")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !presenter.messages.isEmpty {
                    Button("Clear", action: presenter.clearHistory)
                        .buttonStyle(.borderless)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            if presenter.messages.isEmpty {
                ContentUnavailableView(
                    "No Playback Messages",
                    systemImage: "message",
                    description: Text("Playback actions and errors will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(presenter.messages.reversed()) { message in
                            HStack(alignment: .firstTextBaseline, spacing: 11) {
                                Image(systemName: message.item.systemImage)
                                    .foregroundStyle(
                                        message.item.isError ? Color.yellow : Color.primary
                                    )
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(message.item.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(message.date, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .playerOverlaySurface(cornerRadius: 18, role: .status)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .playerOverlaySurface(cornerRadius: 24, role: .status)
        .padding(18)
        .frame(width: 480, height: 440)
        .presentationBackground(.clear)
        .environment(\.playerTheme, PlayerTheme.liquidGlass)
        .preferredColorScheme(PlayerTheme.liquidGlass.preferredColorScheme)
    }
}

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    let supportsFrameStep: Bool
    let supportsPictureInPicture: Bool
    var bindings: PlayerShortcutBindings? = nil

    static func shortcuts(supportsFrameStep: Bool, supportsPictureInPicture: Bool) -> [(String, String)] {
        var entries: [(String, String)] = [
            ("Command-O", "Open a file"),
            ("Command-Shift-O", "Add a source folder"),
            ("Command-T", "New source tab"),
            ("?", "Show keyboard shortcuts"),
            ("Space", "Play or pause"),
            ("Video click / double-click", "Show or hide controls / toggle fullscreen"),
            ("Drag controls background", "Move controls; lock or reset in View"),
            ("Drag timeline", "Scrub; Escape restores the starting position"),
            ("Sources / queue", "Sources browse files; opening files creates the playback queue"),
            ("← / →", "Seek 5 seconds"),
            ("Shift-← / Shift-→", "Seek 1 second"),
            ("↑ / ↓", "Volume by 5%"),
            ("Option-↑ / Option-↓", "Volume by 1%"),
            ("Page Up / Page Down", "Previous or next chapter"),
            ("Shift-Page Up / Shift-Page Down", "Seek 10 minutes"),
            ("Shift-Delete", "Undo the latest seek sequence"),
            ("F / Command-F", "Toggle fullscreen"),
            ("M", "Mute or unmute"),
            ("I", "Playback Inspector"),
            ("Escape", "Dismiss transient UI, then fullscreen"),
            ("Command-← / Command-→", "Previous or next file"),
            ("Command-Option-P", "Show or hide sources"),
            ("Command-Option-T", "Always on top"),
        ]
        if supportsFrameStep { entries.append(("Option-← / Option-→", "Step a frame")) }
        if supportsPictureInPicture { entries.append(("Command-Shift-M", "Toggle picture in picture")) }
        return entries
    }

    private var shortcuts: [(String, String)] {
        let standard = Self.shortcuts(supportsFrameStep: supportsFrameStep, supportsPictureInPicture: supportsPictureInPicture)
        guard let bindings else { return standard }
        let effective = PlayerShortcutDefinition.all.compactMap { definition -> (String, String)? in
            if case .stepFrame = definition.action, !supportsFrameStep { return nil }
            return (bindings.key(for: definition), definition.title)
        }
        let fixed = standard.filter {
            $0.0.hasPrefix("Command") || $0.0.hasPrefix("Video") || $0.0.hasPrefix("Drag") || $0.0 == "Sources / queue" || $0.0 == "Escape"
        }
        return effective + fixed + [("Command-F", "Toggle fullscreen")]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shortcuts, id: \.0) { shortcut in
                        LabeledContent(shortcut.1) {
                            Text(shortcut.0)
                                .font(.body.monospaced())
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)

                        if shortcut.0 != shortcuts.last?.0 {
                            Divider()
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
        .playerOverlaySurface(cornerRadius: 24, role: .status)
        .padding(18)
        .frame(width: 520, height: 500)
        .presentationBackground(.clear)
        .environment(\.playerTheme, PlayerTheme.liquidGlass)
        .preferredColorScheme(PlayerTheme.liquidGlass.preferredColorScheme)
    }
}
