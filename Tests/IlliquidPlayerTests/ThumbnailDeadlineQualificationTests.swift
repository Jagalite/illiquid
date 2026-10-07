import CoreGraphics
import Foundation
import IlliquidNativePlayback
import Testing

/// Opt-in qualification of a proposed retry, deliberately not production policy.
/// Preserve misses as failures when evaluating whether this proposal is viable.
@MainActor
@Suite("Thumbnail deadline retry qualification")
struct ThumbnailDeadlineQualificationTests {
    @Test func profileStableHoverRecovery() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["ILLIQUID_THUMBNAIL_RECOVERY_FIXTURE"],
              let output = env["ILLIQUID_THUMBNAIL_RECOVERY_RESULT"] else { return }
        let generator = NativeTimelineThumbnailGenerator()
        var records: [[String: Any]] = []
        for target in [1.25, 2.25, 8.5, 18.5] {
            var attempts = 0
            let start = ProcessInfo.processInfo.systemUptime
            var result: CGImage?
            for attempt in 0..<2 {
                try Task.checkCancellation()
                attempts += 1
                result = await generator.thumbnail(for: URL(fileURLWithPath: fixture), at: target,
                    maximumPixelSize: CGSize(width: 368, height: 208))
                if result != nil { break }
                if attempt == 0 { try await Task.sleep(for: .milliseconds(150)) }
            }
            records.append(["target": target, "attempts": attempts, "available": result != nil,
                            "caller_ms": (ProcessInfo.processInfo.systemUptime - start) * 1_000])
        }
        try JSONSerialization.data(withJSONObject: ["fixture": fixture, "callers": records],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        #expect(records.allSatisfy { $0["available"] as? Bool == true })
    }
}
