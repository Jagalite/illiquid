import CoreMedia
import Testing
@testable import IlliquidNativePlayback

@Suite("Hardware decoder capability discovery")
struct HardwareDecodeCapabilityTests {
    @Test(arguments: [true, false])
    func supplementalVP9IsDiscoveredBeforeAdmission(available: Bool) {
        var registered = false
        let supported = VideoDecoder.platformSupportsHardwareDecode(
            codecName: "VP9",
            registerSupplementalVP9: true,
            registerSupplemental: { codec in
                #expect(codec == CMVideoCodecType(0x7670_3039))
                registered = true
            },
            isSupported: { _ in registered && available }
        )
        #expect(registered)
        #expect(supported == available)
    }

    @Test func experimentRequiresBothBenchmarkIdentityAndExplicitOptIn() {
        let environment = ["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1",
                           "ILLIQUID_BENCHMARK_VP9_HARDWARE": "1"]
        #expect(VideoDecoder.supplementalVP9ExperimentEnabled(environment: environment,
            bundleIdentifier: "com.example.IlliquidBenchmark"))
        #expect(!VideoDecoder.supplementalVP9ExperimentEnabled(environment: environment,
            bundleIdentifier: "com.illiquid.app"))
        #expect(!VideoDecoder.supplementalVP9ExperimentEnabled(environment: [:],
            bundleIdentifier: "com.example.IlliquidBenchmark"))
        #expect(!VideoDecoder.supplementalVP9ExperimentEnabled(
            environment: ["ILLIQUID_BENCHMARK_VP9_HARDWARE": "1"],
            bundleIdentifier: "com.example.IlliquidBenchmark"))
        #expect(!VideoDecoder.supplementalVP9ExperimentEnabled(
            environment: ["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1"],
            bundleIdentifier: "com.example.IlliquidBenchmark"))
    }

    @Test func defaultAdmissionDoesNotOptIntoTheSupplementalDecoder() {
        #expect(!VideoDecoder.platformSupportsHardwareDecode(codecName: "vp9",
            registerSupplemental: { _ in Issue.record("Unexpected default opt-in") },
            isSupported: { _ in false }))
    }

    @Test(arguments: ["h264", "hevc", "av1"])
    func standardCodecsStillUseThePlatformAnswer(codec: String) {
        var queries = 0
        let supported = VideoDecoder.platformSupportsHardwareDecode(
            codecName: codec,
            registerSupplemental: { _ in Issue.record("Unexpected supplemental registration") },
            isSupported: { _ in queries += 1; return false }
        )
        #expect(!supported)
        #expect(queries == 1)
    }

    @Test func otherCodecsStillDeferToFFmpegCapabilityDiscovery() {
        #expect(VideoDecoder.platformSupportsHardwareDecode(
            codecName: "mpeg2video",
            registerSupplemental: { _ in Issue.record("Unexpected registration") },
            isSupported: { _ in Issue.record("Unexpected platform gate"); return false }
        ))
    }
}
