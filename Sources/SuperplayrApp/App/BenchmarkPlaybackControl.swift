import Darwin
import Foundation
import SuperplayrCore
import SuperplayrPlayer

struct BenchmarkPlaybackControlCommand: Decodable, Equatable {
    let session: String
    let id: String
    let action: String
    let targetSeconds: TimeInterval?
    let sourcePath: String?

    var isApplicationAction: Bool {
        ["ping", "open", "close-window", "reopen-window", "toggle-sidebar", "resize-window", "window-animation",
         "hover-preview", "clear-previews", "source-query", "memory-pressure"].contains(action)
    }

    var playbackAction: PlaybackBenchmarkControlAction? {
        switch action {
        case "play": .play
        case "pause": .pause
        case "seek-exact":
            targetSeconds.map(PlaybackBenchmarkControlAction.seekExact)
        case "snapshot": .snapshot
        case "renderer-metrics": .rendererMetrics
        default: nil
        }
    }
}

struct BenchmarkTimelineHover: Equatable {
    let id: String
    let seconds: Double
}

struct BenchmarkPlaybackControlDeduplicator {
    private let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    mutating func accepts(session: String, id: String) -> Bool {
        let key = session + "\u{1f}" + id
        guard members.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }
}

@MainActor
final class BenchmarkPlaybackControl {
    struct Configuration: Equatable {
        let session: String
        let commandFileURL: URL
    }

    private static let maximumCommandBytes = 4_096

    private let player: PlaybackController
    private let configuration: Configuration
    private let source: DispatchSourceSignal
    private var isInvalidated = false
    private var deduplicator = BenchmarkPlaybackControlDeduplicator()
    var applicationCommand: ((BenchmarkPlaybackControlCommand) -> Bool)?
    private var heartbeat: DispatchSourceTimer?
    private var lastHeartbeat: UInt64 = 0

    static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Configuration? {
        guard bundleIdentifier == "com.example.SuperplayrBenchmark",
              environment["SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES"] == "1",
              let session = environment["SUPERPLAYR_BENCHMARK_CONTROL_SESSION"],
              isValidToken(session),
              let path = environment["SUPERPLAYR_BENCHMARK_CONTROL_FILE"],
              path.hasPrefix("/")
        else { return nil }
        return Configuration(
            session: session,
            commandFileURL: URL(fileURLWithPath: path, isDirectory: false).absoluteURL.standardized
        )
    }

    static func isValidToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func install(
        player: PlaybackController,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> BenchmarkPlaybackControl? {
        guard let configuration = configuration(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        ) else { return nil }
        return BenchmarkPlaybackControl(player: player, configuration: configuration)
    }

    private init(player: PlaybackController, configuration: Configuration) {
        self.player = player
        self.configuration = configuration
        Darwin.signal(SIGUSR1, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.consumeCommand() }
        }
        source.resume()
        if LifecyclePerformance.isEnabled,
           ProcessInfo.processInfo.environment["SUPERPLAYR_BENCHMARK_HEARTBEAT"] != "0" {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if self.lastHeartbeat != 0, now - self.lastHeartbeat > 20_000_000 {
                        LifecyclePerformance.end("main-queue-gap", since: self.lastHeartbeat)
                    }
                    self.lastHeartbeat = now
                }
            }
            heartbeat = timer
            timer.resume()
        }
        writeDiagnostic("session=\(configuration.session) phase=ready")
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        source.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        applicationCommand = nil
    }

    private func consumeCommand() {
        guard !isInvalidated else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: configuration.commandFileURL.path
            )
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0, byteCount <= Self.maximumCommandBytes else {
                writeDiagnostic(
                    "session=\(configuration.session) phase=rejected reason=invalid-size"
                )
                return
            }
            let data = try Data(contentsOf: configuration.commandFileURL)
            let command = try JSONDecoder().decode(BenchmarkPlaybackControlCommand.self, from: data)
            guard command.session == configuration.session,
                  Self.isValidToken(command.id),
                  command.playbackAction != nil || (LifecyclePerformance.isEnabled && command.isApplicationAction)
            else {
                writeDiagnostic(
                    "session=\(configuration.session) phase=rejected reason=invalid-command"
                )
                return
            }
            guard deduplicator.accepts(session: command.session, id: command.id) else {
                writeDiagnostic(
                    "session=\(configuration.session) id=\(command.id) "
                        + "phase=ignored reason=duplicate"
                )
                return
            }
            if let action = command.playbackAction {
                _ = player.executeBenchmarkControl(session: command.session, id: command.id, action: action)
            } else {
                let accepted = applicationCommand?(command) == true
                writeDiagnostic("session=\(command.session) id=\(command.id) phase=completed accepted=\(accepted ? "yes" : "no")")
            }
        } catch {
            writeDiagnostic(
                "session=\(configuration.session) phase=rejected reason=read-or-decode"
            )
        }
    }

    private func writeDiagnostic(_ fields: String) {
        FileHandle.standardError.write(
            Data(("[benchmark-control-channel] \(fields)\n").utf8)
        )
    }

    deinit {
        source.cancel()
        heartbeat?.cancel()
    }
}
