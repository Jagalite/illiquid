import Foundation

@_silgen_name("pcm_live_heap") func liveHeap() -> UInt64
@_silgen_name("pcm_clock_ns") func clockNS(_ cpu: Int32) -> UInt64

// Allocation functions and the complete sanitizer are extracted from AudioDecoder.swift.
struct DrainMetadata { let channelCount: Int }

@inline(never)
func allocate(_ path: String, _ capacity: Int, _ channels: Int) -> Data {
    path == "convert"
        ? allocateConvert(Int32(capacity), channels)
        : allocateDrain(Int32(capacity), DrainMetadata(channelCount: channels))
}

let dirtyBits: [UInt32] = [0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00123,
                          1, 0x80000001, 0x3f800000, 0xbf800000]

@inline(never)
func fill(_ data: inout Data, _ samples: Int, _ dirty: Bool) {
    data.withUnsafeMutableBytes { bytes in
        for index in 0..<samples {
            let bits = dirty ? dirtyBits[index % dirtyBits.count] : 0x3f000000 | UInt32(index % 4096)
            bytes.storeBytes(of: bits, toByteOffset: index * 4, as: UInt32.self)
        }
    }
}

@inline(never)
func make(_ path: String, _ capacity: Int, _ channels: Int, _ actual: Int) -> Data {
    var data = allocate(path, capacity, channels)
    fill(&data, actual * channels, false)
    data.count = actual * channels * 4
    precondition(sanitizeInterleavedFloatPCM(&data).totalReplacements == 0)
    return data
}

@inline(never)
func consume(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { bytes in
        UInt64(bytes.count) &+ (bytes.isEmpty ? 0 : UInt64(bytes[0]) &+ UInt64(bytes[bytes.count - 1]))
    }
}

func verify(_ path: String, _ capacity: Int, _ channels: Int, _ actual: Int) -> [String: Any] {
    // Check the unique-storage path used by the timed and retained-buffer workloads.
    let unique = make(path, capacity, channels, actual)
    var uniqueHash: UInt64 = 14695981039346656037
    unique.withUnsafeBytes { bytes in
        precondition(bytes.count == actual * channels * 4)
        for index in 0..<(actual * channels) {
            let expected: UInt32 = 0x3f000000 | UInt32(index % 4096)
            precondition(bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) == expected)
        }
        for byte in bytes { uniqueHash = (uniqueHash ^ UInt64(byte)) &* 1099511628211 }
    }
    // Separately check invalid-value repair and the public copy-on-write contract.
    var data = allocate(path, capacity, channels)
    precondition(data.count == capacity * channels * 4 && data.allSatisfy { $0 == 0 })
    let original = data
    fill(&data, actual * channels, true)
    data.count = actual * channels * 4
    let replacements = sanitizeInterleavedFloatPCM(&data)
    precondition(original.allSatisfy { $0 == 0 }, "CoW changed the original value")
    var expectedNonFinite = 0, expectedSubnormal = 0
    var hash: UInt64 = 14695981039346656037
    data.withUnsafeBytes { bytes in
        for index in 0..<(actual * channels) {
            let bits = dirtyBits[index % dirtyBits.count]
            let sample = Float(bitPattern: bits)
            let expected: UInt32
            if !sample.isFinite { expected = 0; expectedNonFinite += 1 }
            else if sample.isSubnormal { expected = 0; expectedSubnormal += 1 }
            else { expected = bits }
            precondition(bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) == expected)
        }
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    }
    precondition(replacements.replacedNonFiniteSamples == expectedNonFinite)
    precondition(replacements.replacedSubnormalSamples == expectedSubnormal)
    return ["bytes": data.count, "initial_zero_fill": true, "full_byte_parity": true,
            "cow_preserved": true, "non_finite_replacements": expectedNonFinite,
            "subnormal_replacements": expectedSubnormal, "fnv1a64": String(hash, radix: 16),
            "unique_full_byte_parity": true, "unique_fnv1a64": String(uniqueHash, radix: 16)]
}

@inline(never)
func retainFrames(_ held: inout [Data], _ path: String, _ capacity: Int, _ channels: Int,
                  _ actual: Int, _ count: Int) {
    for _ in 0..<count { held.append(make(path, capacity, channels, actual)) }
}

func measure(_ path: String, _ capacity: Int, _ channels: Int, _ actual: Int,
             _ iterations: Int, _ frames: Int) -> [String: Any] {
    var checksum: UInt64 = 0
    for _ in 0..<32 { checksum &+= consume(make(path, capacity, channels, actual)) }
    var held: [Data] = []
    held.reserveCapacity(frames)
    // Warm array insertion/iteration/release metadata before observing live bytes.
    retainFrames(&held, path, capacity, channels, actual, frames)
    for data in held { checksum &+= consume(data) }
    held.removeAll(keepingCapacity: true)
    _ = liveHeap(); _ = clockNS(0); _ = clockNS(1)
    let before = liveHeap()
    retainFrames(&held, path, capacity, channels, actual, frames)
    let retained = liveHeap()
    for data in held { checksum &+= consume(data) }
    withExtendedLifetime(held) {}
    held.removeAll(keepingCapacity: true)
    let released = liveHeap()
    let wallStart = clockNS(0), cpuStart = clockNS(1)
    for _ in 0..<iterations { checksum &+= consume(make(path, capacity, channels, actual)) }
    let cpu = clockNS(1) - cpuStart, wall = clockNS(0) - wallStart
    withExtendedLifetime(held) {}
    return ["iterations": iterations, "retained_frames": frames, "payload_bytes_per_frame": actual * channels * 4,
            "capacity_bytes_per_frame": capacity * channels * 4,
            "heap_before_bytes": before, "heap_retained_bytes": retained, "heap_released_bytes": released,
            "retained_heap_delta_bytes": Int64(retained) - Int64(before),
            "released_heap_delta_bytes": Int64(released) - Int64(before),
            "wall_ns_per_call": Double(wall) / Double(iterations),
            "cpu_ns_per_call": Double(cpu) / Double(iterations), "checksum": String(checksum)]
}

let args = CommandLine.arguments
precondition(args.count == 8)
let mode = args[1], path = args[2], capacity = Int(args[3])!, channels = Int(args[4])!
let actual = Int(args[5])!, iterations = Int(args[6])!, frames = Int(args[7])!
precondition(["convert", "drain"].contains(path) && capacity > 0 && channels > 0)
precondition(actual >= 0 && actual <= capacity && iterations > 0 && frames > 0)
let result = mode == "verify" ? verify(path, capacity, channels, actual)
    : measure(path, capacity, channels, actual, iterations, frames)
let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
