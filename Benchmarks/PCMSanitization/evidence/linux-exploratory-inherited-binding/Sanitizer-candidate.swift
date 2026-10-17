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
        let blockWidth = SIMD8<UInt32>.scalarCount
        let blockEnd = samples.count - samples.count % blockWidth
        var index = 0
        while index < blockEnd {
            // Most decoded PCM contains only finite normal values and signed
            // zero. Classify eight samples together before the scalar repair
            // path. Unaligned loads also support sliced Data storage.
            let bits = bytes.loadUnaligned(
                fromByteOffset: index * MemoryLayout<Float>.stride,
                as: SIMD8<UInt32>.self
            )
            let magnitude = bits & SIMD8<UInt32>(repeating: 0x7fff_ffff)
            let isZero = magnitude .== .zero
            let isNormal = (magnitude .>= SIMD8<UInt32>(repeating: 0x0080_0000))
                .& (magnitude .< SIMD8<UInt32>(repeating: 0x7f80_0000))
            if all(isZero .| isNormal) {
                index += blockWidth
                continue
            }
            for lane in index..<(index + blockWidth) {
                let sample = samples[lane]
                if !sample.isFinite {
                    samples[lane] = 0
                    nonFinite += 1
                } else if sample.isSubnormal {
                    samples[lane] = 0
                    subnormal += 1
                }
            }
            index += blockWidth
        }
        for tailIndex in index..<samples.count {
            let sample = samples[tailIndex]
            if !sample.isFinite {
                samples[tailIndex] = 0
                nonFinite += 1
            } else if sample.isSubnormal {
                samples[tailIndex] = 0
                subnormal += 1
            }
        }
    }
    return AudioSampleSanitizationResult(
        replacedNonFiniteSamples: nonFinite,
        replacedSubnormalSamples: subnormal
    )
}
