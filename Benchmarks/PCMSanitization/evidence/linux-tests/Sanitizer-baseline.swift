import Foundation

struct AudioSampleSanitizationResult: Equatable, Sendable {
    let replacedNonFiniteSamples: Int
    let replacedSubnormalSamples: Int

    var totalReplacements: Int {
        replacedNonFiniteSamples + replacedSubnormalSamples
    }
}

@discardableResult
func sanitizeInterleavedFloatPCM(_ data: inout Data) -> AudioSampleSanitizationResult {
    var nonFinite = 0
    var subnormal = 0
    data.withUnsafeMutableBytes { bytes in
        let samples = bytes.bindMemory(to: Float.self)
        for index in samples.indices {
            let sample = samples[index]
            if !sample.isFinite {
                samples[index] = 0
                nonFinite += 1
            } else if sample.isSubnormal {
                samples[index] = 0
                subnormal += 1
            }
        }
    }
    return AudioSampleSanitizationResult(
        replacedNonFiniteSamples: nonFinite,
        replacedSubnormalSamples: subnormal
    )
}
