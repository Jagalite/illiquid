import Foundation

/// Host-clock observations for one native seek. Renderer submission and clock
/// advancement are deliberately separate from unmeasured visible/audible output.
struct SeekPerformanceTimings: Equatable, Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case demuxStarted, demuxCompleted, targetVideoDecoded
        case videoEnqueued, audioEnqueued, prerollCompleted, rendererClockAdvanced
    }

    let generation: Int
    let requestedUptime: TimeInterval
    private(set) var milliseconds: [Stage: Double] = [:]

    mutating func record(_ stage: Stage, generation: Int, at uptime: TimeInterval) {
        guard generation == self.generation, milliseconds[stage] == nil,
              uptime.isFinite, uptime >= requestedUptime else { return }
        milliseconds[stage] = (uptime - requestedUptime) * 1_000
    }

    var summary: String {
        Stage.allCases.map { stage in
            let value = milliseconds[stage].map { String(format: "%.3f", $0) } ?? "unobserved"
            return "\(stage.rawValue)-ms=\(value)"
        }.joined(separator: " ")
    }
}
