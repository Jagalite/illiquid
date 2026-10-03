import AppKit
import Foundation
import SuperplayrCore
import SuperplayrNativePlayback
import SuperplayrPlayback
import SuperplayrPlayer

@main
@MainActor
struct SuperplayrPlaybackStress {
    static func main() {
        do {
            let harness = try StressHarness(arguments: CommandLine.arguments)
            Task {
                await harness.run()
                NSApp.terminate(nil)
            }
            NSApp.setActivationPolicy(.prohibited)
            NSApp.run()
        } catch {
            fputs("stress initialization failed: \(error)\n", stderr)
            exit(2)
        }
    }
}

@MainActor
private final class StressHarness {
    private let runtime: NativePlaybackRuntime
    private let player: PlaybackCoordinator
    private let surface: any PlaybackSurfaceHost
    private let window: NSWindow
    private let media: URL
    private let reopenCount: Int
    private let duration: TimeInterval
    private var failure: String?

    init(arguments: [String]) throws {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
            else { return nil }
            return arguments[index + 1]
        }
        guard let mediaPath = value(after: "--media") else {
            throw StressError("--media PATH is required")
        }
        media = URL(fileURLWithPath: mediaPath)
        reopenCount = max(Int(value(after: "--reopen-count") ?? "12") ?? 12, 1)
        duration = max(Double(value(after: "--duration") ?? "8") ?? 8, 1)
        runtime = try NativePlaybackRuntime()
        player = PlaybackCoordinator(runtime: runtime)
        surface = try player.makeVideoSurfaceHost()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface.view
        window.orderBack(nil)
    }

    func run() async {
        let interval = max(duration / Double(reopenCount), 0.1)
        for index in 0..<reopenCount {
            if index > 0 { player.stop() }
            player.open(url: media)
            try? await Task.sleep(for: .seconds(interval * 0.45))
            player.previewSeek(to: Double(index % 3))
            try? await Task.sleep(for: .seconds(interval * 0.2))
            player.seek(to: Double((index + 1) % 4))
            try? await Task.sleep(for: .seconds(interval * 0.35))
            if player.viewStore.phase == .failed { failure = player.viewStore.lastError ?? "core failed" }
            if failure != nil { break }
        }
        await player.shutdown()
        window.close()
        if let failure {
            fputs("native stress failure: \(failure)\n", stderr)
            exit(1)
        }
    }

}

private struct StressError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
