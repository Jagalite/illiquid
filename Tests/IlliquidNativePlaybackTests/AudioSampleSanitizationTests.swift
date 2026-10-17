import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Audio sample sanitization")
struct AudioSampleSanitizationTests {
    private let cleanWords: [UInt32] = [
        0x0000_0000, 0x8000_0000, // Both zero signs are valid and must survive.
        0x0080_0000, 0x8080_0000, // Smallest normal values, adjacent to subnormals.
        0x0080_0001, 0x8080_0001,
        0x3e80_0000, 0xbe80_0000,
        0x3f80_0000, 0xbf80_0000,
        0x3f80_0001, 0xbf80_0001, // Finite PCM is not clipped to [-1, 1].
        0x7f7f_ffff, 0xff7f_ffff, // Largest finite values, adjacent to infinity.
    ]
    private let dirtyWords: [UInt32] = [
        0x7f80_0000, 0xff80_0000, // Infinities.
        0x7fc0_0001, 0xff80_0001, // Quiet and signaling NaNs, both signs.
        0x0000_0001, 0x8000_0001, // Smallest subnormals.
        0x007f_ffff, 0x807f_ffff, // Largest subnormals.
    ]

    @Test func ieeeBoundaryClassesHaveExactCountsAndPreserveAcceptedBits() {
        let words = cleanWords + [
            0x7f80_0000, 0xff80_0000,
            0x7fc0_0000, 0xffc0_0000,
            0x7f80_0001, 0xff80_0001,
            0x0000_0001, 0x8000_0001,
            0x007f_ffff, 0x807f_ffff,
        ]
        var data = makeData(words)
        let result = expectReferenceResult(&data, scenario: "IEEE boundaries")
        #expect(result.replacedNonFiniteSamples == 6)
        #expect(result.replacedSubnormalSamples == 4)
        #expect(result.totalReplacements == 10)

        var allClean = makeData(cleanWords + cleanWords + cleanWords)
        let cleanResult = expectReferenceResult(&allClean, scenario: "all clean blocks and tail")
        #expect(cleanResult.totalReplacements == 0)
    }

    @Test func nanPayloadFamiliesAndSignsAreReplacedWithoutChangingNeighbors() {
        var payloads: Set<UInt32> = [0x003f_ffff, 0x0040_0000, 0x0040_0001, 0x0055_5555, 0x007f_ffff]
        for bit in 0..<23 {
            payloads.insert(UInt32(1) << bit)
            payloads.insert((UInt32(1) << (bit + 1)) - 1)
            payloads.insert(0x0040_0000 | (UInt32(1) << bit))
        }
        var words: [UInt32] = []
        var signaling = 0
        var quiet = 0
        for sign: UInt32 in [0, 0x8000_0000] {
            for payload in payloads.sorted() {
                let word = sign | 0x7f80_0000 | payload
                let value = Float(bitPattern: word)
                #expect(value.isNaN)
                if value.isSignalingNaN { signaling += 1 }
                else { quiet += 1 }
                words.append(contentsOf: [0x8000_0000, word, 0x0080_0000, 0x7f7f_ffff])
            }
        }
        #expect(signaling > 0 && quiet > 0)
        var data = makeData(words)
        let result = expectReferenceResult(&data, scenario: "NaN payload families")
        #expect(result.replacedNonFiniteSamples == signaling + quiet)
        #expect(result.replacedSubnormalSamples == 0)
    }

    @Test func everyDirtyLaneAndShortTailMatchesScalarClassification() {
        for count in Array(0...17) + [31, 32, 33] {
            let clean = (0..<count).map { cleanWords[$0 % cleanWords.count] }
            var allClean = makeData(clean)
            #expect(expectReferenceResult(&allClean, scenario: "clean count-\(count)").totalReplacements == 0)
            let positions = count <= 17
                ? Array(0..<count)
                : [0, 7, 8, 15, 16, count - 1]
            for position in positions {
                for dirty in dirtyWords {
                    var words = clean
                    words[position] = dirty
                    var data = makeData(words)
                    let result = expectReferenceResult(
                        &data, scenario: "count-\(count)/lane-\(position)/bits-\(String(dirty, radix: 16))"
                    )
                    #expect(result.totalReplacements == 1)
                }
            }
        }
    }

    @Test func incompleteTrailingBytesRemainUntouched() {
        let trailing: [UInt8] = [0xff, 0x80, 0x7f]
        for count in [0, 1, 7, 8, 9, 15, 16, 17] {
            let words = (0..<count).map { index in
                index.isMultiple(of: 3) ? dirtyWords[index % dirtyWords.count] : cleanWords[index % cleanWords.count]
            }
            for remainder in 0...3 {
                var data = makeData(words, trailingBytes: Array(trailing.prefix(remainder)))
                expectReferenceResult(&data, scenario: "count-\(count)/trailing-bytes-\(remainder)")
                #expect(Array(data.suffix(remainder)) == Array(trailing.prefix(remainder)))
            }
        }
    }

    @Test func slicedDataPreservesItsIndicesAndRetainedBackingStorage() {
        let payload = makeData(
            (0..<33).map { $0.isMultiple(of: 5) ? dirtyWords[$0 % dirtyWords.count] : cleanWords[$0 % cleanWords.count] },
            trailingBytes: [0xa5, 0x5a, 0xff]
        )
        for prefixCount in [1, 2, 3, 7, 15, 31] {
            let prefix = Data(repeating: 0x5a, count: prefixCount)
            let suffix = Data(repeating: 0xa5, count: 9)
            let backing = prefix + payload + suffix
            let originalBackingBytes = Array(backing)
            var slice = backing[prefixCount..<(prefixCount + payload.count)]
            #expect(slice.startIndex == prefixCount)
            _ = withExtendedLifetime(backing) {
                expectReferenceResult(&slice, scenario: "slice-prefix-\(prefixCount)")
            }
            #expect(slice.startIndex == prefixCount)
            #expect(Array(backing) == originalBackingBytes)
        }
    }

    @Test func unalignedExternalStorageAndPartialTailMatchReference() {
        let payload = makeData(
            (0..<33).map { $0.isMultiple(of: 7) ? dirtyWords[$0 % dirtyWords.count] : cleanWords[$0 % cleanWords.count] },
            trailingBytes: [0xf1, 0xf2, 0xf3]
        )
        for offset in [1, 2, 3, 7, 15, 31] {
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: payload.count + 64, alignment: 64)
            let allocationAddress = UInt(bitPattern: allocation)
            let start = allocation.advanced(by: offset)
            payload.withUnsafeBytes { bytes in
                start.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            var data = Data(bytesNoCopy: start, count: payload.count, deallocator: .custom { _, _ in
                UnsafeMutableRawPointer(bitPattern: allocationAddress)!.deallocate()
            })
            // Check a mutable borrow, since a read-only pointer alone would
            // not rule out a Foundation copy when mutation first begins.
            let address = data.withUnsafeMutableBytes { UInt(bitPattern: $0.baseAddress!) }
            #expect(address % 64 == UInt(offset))
            expectReferenceResult(&data, scenario: "external-byte-offset-\(offset)")
        }
    }

    @Test func retainedSnapshotsStayUnchangedAndSanitizationIsIdempotent() {
        for words in [cleanWords + cleanWords, cleanWords + dirtyWords + cleanWords] {
            var data = makeData(words, trailingBytes: [0x34, 0x12])
            let snapshot = data
            let originalBytes = Array(snapshot)
            _ = withExtendedLifetime(snapshot) {
                expectReferenceResult(&data, scenario: "retained snapshot")
            }
            #expect(Array(snapshot) == originalBytes)
            let firstPassBytes = Array(data)
            let second = sanitizeInterleavedFloatPCM(&data)
            #expect(second.replacedNonFiniteSamples == 0)
            #expect(second.replacedSubnormalSamples == 0)
            #expect(Array(data) == firstPassBytes)
        }
    }

    @Test func allExponentClassesAndDeterministicWideBitCorpusMatchReference() {
        let mantissas: [UInt32] = [0, 1, 2, 0x003f_ffff, 0x0040_0000, 0x0040_0001, 0x007f_fffe, 0x007f_ffff]
        var words: [UInt32] = []
        for sign: UInt32 in [0, 0x8000_0000] {
            for exponent: UInt32 in 0...255 {
                for mantissa in mantissas {
                    words.append(sign | (exponent << 23) | mantissa)
                }
            }
        }
        var state: UInt32 = 0xA0D1_0BAD
        for _ in 0..<65_536 {
            state = state &* 1_664_525 &+ 1_013_904_223
            words.append(state)
        }
        var data = makeData(words, trailingBytes: [0x7f, 0xc0, 0x01])
        let result = expectReferenceResult(&data, scenario: "all exponents and seeded raw words")
        #expect(result.replacedNonFiniteSamples > 0)
        #expect(result.replacedSubnormalSamples > 0)
    }

    @discardableResult
    private func expectReferenceResult(_ data: inout Data, scenario: String) -> AudioSampleSanitizationResult {
        let originalStartIndex = data.startIndex
        let originalEndIndex = data.endIndex
        let expected = reference(Array(data))
        let result = sanitizeInterleavedFloatPCM(&data)
        #expect(result.replacedNonFiniteSamples == expected.nonFinite, Comment(rawValue: scenario))
        #expect(result.replacedSubnormalSamples == expected.subnormal, Comment(rawValue: scenario))
        #expect(result.totalReplacements == expected.nonFinite + expected.subnormal, Comment(rawValue: scenario))
        #expect(data.startIndex == originalStartIndex && data.endIndex == originalEndIndex, Comment(rawValue: scenario))
        let firstMismatch = zip(data, expected.bytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(firstMismatch == nil, Comment(rawValue: scenario + ": first different byte \(String(describing: firstMismatch))"))
        return result
    }

    private func makeData(_ words: [UInt32], trailingBytes: [UInt8] = []) -> Data {
        var data = words.withUnsafeBytes { Data($0) }
        data.append(contentsOf: trailingBytes)
        return data
    }

    /// Classify each original word with Float's scalar predicates. Integer
    /// loads avoid alignment assumptions; accepted words are never rewritten.
    private func reference(_ bytes: [UInt8]) -> (bytes: [UInt8], nonFinite: Int, subnormal: Int) {
        var expected = bytes
        var nonFinite = 0
        var subnormal = 0
        bytes.withUnsafeBytes { raw in
            for index in 0..<(bytes.count / MemoryLayout<UInt32>.stride) {
                let offset = index * MemoryLayout<UInt32>.stride
                let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let value = Float(bitPattern: word)
                let replace: Bool
                if !value.isFinite {
                    nonFinite += 1
                    replace = true
                } else if value.isSubnormal {
                    subnormal += 1
                    replace = true
                } else {
                    replace = false
                }
                if replace {
                    // Both invalid classes become positive zero, irrespective
                    // of source sign or NaN payload. The trailing 1–3 bytes stay.
                    for byte in offset..<(offset + MemoryLayout<UInt32>.stride) { expected[byte] = 0 }
                }
            }
        }
        return (expected, nonFinite, subnormal)
    }
}
