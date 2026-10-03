import Foundation
import MediaPlayer
import SuperplayrCore
import SuperplayrPlayer

/// Publishes the active session to macOS and owns all remote-command targets.
@MainActor
final class NowPlayingCoordinator {
    private struct Registration {
        let command: MPRemoteCommand
        let target: Any
    }

    private unowned let player: PlaybackController
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var registrations: [Registration] = []
    private var lastPublishedPosition: TimeInterval = -.infinity

    init(player: PlaybackController) {
        self.player = player
    }

    func update(from snapshot: PlaybackViewSnapshot, force: Bool = false) {
        guard isActive(snapshot.phase), let source = snapshot.currentSource else {
            deactivate()
            return
        }

        if registrations.isEmpty { registerCommands() }
        updateCommandAvailability(from: snapshot)

        guard force || abs(snapshot.position - lastPublishedPosition) >= 5 else { return }
        lastPublishedPosition = snapshot.position

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: source.url.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.phase == .playing
                ? player.capabilityModel.sanitizedPlaybackSpeed(snapshot.playbackSpeed)
                : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
            MPNowPlayingInfoPropertyExternalContentIdentifier: source.url.absoluteString,
        ]
        if let chapter = snapshot.chapters.first(where: { $0.id == snapshot.currentChapterID }) {
            info[MPMediaItemPropertyAlbumTitle] = chapter.title ?? "Chapter \(chapter.id + 1)"
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = switch snapshot.phase {
        case .playing, .buffering, .loading: .playing
        case .paused, .preparing: .paused
        case .idle, .stopping, .failed, .shuttingDown: .stopped
        }
    }

    func deactivate() {
        for registration in registrations {
            registration.command.removeTarget(registration.target)
            registration.command.isEnabled = false
        }
        registrations.removeAll()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        lastPublishedPosition = -.infinity
    }

    private func registerCommands() {
        register(commandCenter.playCommand) { $0.play() }
        register(commandCenter.pauseCommand) { $0.pause() }
        register(commandCenter.togglePlayPauseCommand) { $0.togglePause() }
        register(commandCenter.nextTrackCommand) { $0.playNext() }
        register(commandCenter.previousTrackCommand) { $0.playPrevious() }
        register(commandCenter.skipForwardCommand) { $0.seek(relative: 10) }
        register(commandCenter.skipBackwardCommand) { $0.seek(relative: -10) }
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.preferredIntervals = [10]

        let positionCommand = commandCenter.changePlaybackPositionCommand
        let target = positionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .noActionableNowPlayingItem }
            Task { @MainActor [weak self] in
                self?.player.seek(to: positionEvent.positionTime)
            }
            return .success
        }
        registrations.append(Registration(command: positionCommand, target: target))
    }

    private func register(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor (PlaybackController) -> Void
    ) {
        let target = command.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self.player)
            }
            return .success
        }
        registrations.append(Registration(command: command, target: target))
    }

    private func updateCommandAvailability(from snapshot: PlaybackViewSnapshot) {
        let isPaused = snapshot.isPauseDesired
        let hasNext = snapshot.currentPlaylistIndex.map {
            snapshot.playlist.indices.contains($0 + 1)
        } ?? false
        let hasPrevious = snapshot.currentPlaylistIndex.map {
            snapshot.playlist.indices.contains($0 - 1)
        } ?? false
        commandCenter.playCommand.isEnabled = isPaused
        commandCenter.pauseCommand.isEnabled = !isPaused
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = hasNext
        commandCenter.previousTrackCommand.isEnabled = hasPrevious
        commandCenter.skipForwardCommand.isEnabled = snapshot.duration > 0
        commandCenter.skipBackwardCommand.isEnabled = snapshot.duration > 0
        commandCenter.changePlaybackPositionCommand.isEnabled = snapshot.duration > 0
    }

    private func isActive(_ phase: PlaybackPhase) -> Bool {
        switch phase {
        case .preparing, .loading, .playing, .paused, .buffering: true
        case .idle, .stopping, .failed, .shuttingDown: false
        }
    }
}
