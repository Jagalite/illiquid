import Foundation
import Testing
@testable import IlliquidApp

@Suite("Agent UI guarded protocol")
@MainActor
struct AgentUIProtocolTests {
    private let environment = [
        "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1",
        "ILLIQUID_BENCHMARK_CONTROL_SESSION": "agent-run",
        "ILLIQUID_BENCHMARK_CONTROL_FILE": "/tmp/agent-run.json",
    ]

    @Test func everyGateIsRequired() {
        #expect(BenchmarkPlaybackControl.configuration(
            environment: environment, bundleIdentifier: "com.example.IlliquidBenchmark") != nil)
        for bundle in [nil, "com.example.Illiquid", "com.example.IlliquidBenchmark.other"] {
            #expect(BenchmarkPlaybackControl.configuration(environment: environment, bundleIdentifier: bundle) == nil)
        }
        for key in environment.keys {
            var missing = environment
            missing.removeValue(forKey: key)
            #expect(BenchmarkPlaybackControl.configuration(
                environment: missing, bundleIdentifier: "com.example.IlliquidBenchmark") == nil)
        }
        for (key, value) in [
            ("ILLIQUID_ENABLE_BENCHMARK_OVERRIDES", "true"),
            ("ILLIQUID_BENCHMARK_CONTROL_SESSION", "bad session"),
            ("ILLIQUID_BENCHMARK_CONTROL_SESSION", ""),
            ("ILLIQUID_BENCHMARK_CONTROL_FILE", "relative.json"),
        ] {
            var invalid = environment
            invalid[key] = value
            #expect(BenchmarkPlaybackControl.configuration(
                environment: invalid, bundleIdentifier: "com.example.IlliquidBenchmark") == nil)
        }
    }

    @Test func diagnosticsRemainSessionScopedWithoutEnablingSetupCommands() {
        for action in ["capabilities", "agent-state"] {
            let command = command(action)
            #expect(command.isAgentUIAction)
            #expect(command.playbackAction == nil)
            #expect(BenchmarkPlaybackControl.accepts(command, session: "agent-run", lifecycleEnabled: false))
            #expect(!BenchmarkPlaybackControl.accepts(command, session: "other-run", lifecycleEnabled: true))
            #expect(!BenchmarkPlaybackControl.accepts(self.command(action, id: "bad id"),
                                                     session: "agent-run", lifecycleEnabled: true))
        }
        #expect(!BenchmarkPlaybackControl.accepts(command("open"), session: "agent-run", lifecycleEnabled: false))
        #expect(BenchmarkPlaybackControl.accepts(command("open"), session: "agent-run", lifecycleEnabled: true))
        for action in ["eval", "shell", "agent-state;open", "CAPABILITIES", "delete"] {
            #expect(!BenchmarkPlaybackControl.accepts(command(action), session: "agent-run", lifecycleEnabled: true))
        }
    }

    @Test func snapshotsAreCorrelatedSingleJSONLinesAndPreserveUnknownValues() throws {
        let line = try AgentUIStateDiagnostic.line(command: command("agent-state"), data: [
            "source": ["url": "file:///tmp/a\n[agent-ui-state] fake.mkv", "revision": UInt64(17)],
            "readiness": ["presentation_observed": NSNull()],
            "position": AgentUIStateDiagnostic.finite(.nan),
        ], monotonicNanoseconds: 123)
        let text = try #require(String(data: line, encoding: .utf8))
        #expect(text.hasPrefix(AgentUIStateDiagnostic.prefix))
        #expect(text.filter { $0 == "\n" }.count == 1)
        let payload = Data(text.dropFirst(AgentUIStateDiagnostic.prefix.count).utf8)
        let envelope = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(envelope["schema_version"] as? Int == 1)
        #expect(envelope["session"] as? String == "agent-run")
        #expect(envelope["id"] as? String == "state-1")
        #expect(envelope["action"] as? String == "agent-state")
        #expect(envelope["monotonic_ns"] as? UInt64 == 123)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["position"] is NSNull)
        #expect(AgentUIStateDiagnostic.finite(.infinity) is NSNull)
        #expect(AgentUIStateDiagnostic.finite(-.infinity) is NSNull)
        #expect(AgentUIStateDiagnostic.finite(0) as? Double == 0)
        let readiness = try #require(data["readiness"] as? [String: Any])
        #expect(readiness["presentation_observed"] is NSNull)
    }

    @Test func diagnosticRequestsUseTheExistingDeduplicationBoundary() {
        var deduplicator = BenchmarkPlaybackControlDeduplicator()
        let first = deduplicator.accepts(session: "agent-run", id: "state-1")
        let duplicate = deduplicator.accepts(session: "agent-run", id: "state-1")
        let next = deduplicator.accepts(session: "agent-run", id: "state-2")
        #expect(first)
        #expect(!duplicate)
        #expect(next)
    }

    @Test func targetGeometryRetainsItsObservedSourceRevision() throws {
        let bounds = CGRect(x: 20, y: 30, width: 24, height: 40)
        let observation = try #require(AgentUITargetGeometry.Observation(bounds: bounds, sourceRevision: 17))
        #expect(observation.bounds == bounds)
        #expect(observation.isCurrent(for: 17))
        #expect(!observation.isCurrent(for: 18))
        // Identical geometry from a new observation is valid for the new source.
        let replacement = try #require(AgentUITargetGeometry.Observation(bounds: bounds, sourceRevision: 18))
        #expect(replacement != observation)
        #expect(replacement.isCurrent(for: 18))
    }

    @Test func invalidTargetGeometryIsNotPublished() {
        for bounds in [CGRect.null, .infinite, .zero,
                       CGRect(x: CGFloat.nan, y: 0, width: 24, height: 40),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40),
                       CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                              width: CGFloat.greatestFiniteMagnitude, height: 40),
                       CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude,
                              width: 24, height: CGFloat.greatestFiniteMagnitude)] {
            #expect(AgentUITargetGeometry.Observation(bounds: bounds, sourceRevision: 17) == nil)
        }
    }

    private func command(_ action: String, id: String = "state-1") -> BenchmarkPlaybackControlCommand {
        .init(session: "agent-run", id: id, action: action, targetSeconds: nil, sourcePath: nil)
    }
}
