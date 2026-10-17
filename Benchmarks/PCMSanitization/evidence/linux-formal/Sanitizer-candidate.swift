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
        let sampleCount = bytes.count / MemoryLayout<Float>.stride
        let blockWidth = SIMD8<UInt32>.scalarCount
        let blockEnd = sampleCount - sampleCount % blockWidth
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
                let byteOffset = lane * MemoryLayout<Float>.stride
                let sample = Float(bitPattern: bytes.loadUnaligned(
                    fromByteOffset: byteOffset,
                    as: UInt32.self
                ))
                if !sample.isFinite {
                    bytes.storeBytes(of: UInt32(0), toByteOffset: byteOffset, as: UInt32.self)
                    nonFinite += 1
                } else if sample.isSubnormal {
                    bytes.storeBytes(of: UInt32(0), toByteOffset: byteOffset, as: UInt32.self)
                    subnormal += 1
                }
            }
            index += blockWidth
        }
        for tailIndex in index..<sampleCount {
            let byteOffset = tailIndex * MemoryLayout<Float>.stride
            let sample = Float(bitPattern: bytes.loadUnaligned(
                fromByteOffset: byteOffset,
                as: UInt32.self
            ))
            if !sample.isFinite {
                bytes.storeBytes(of: UInt32(0), toByteOffset: byteOffset, as: UInt32.self)
                nonFinite += 1
            } else if sample.isSubnormal {
                bytes.storeBytes(of: UInt32(0), toByteOffset: byteOffset, as: UInt32.self)
                subnormal += 1
            }
        }
    }
    return AudioSampleSanitizationResult(
        replacedNonFiniteSamples: nonFinite,
        replacedSubnormalSamples: subnormal
    )
}
