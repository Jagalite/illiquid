import CoreGraphics
import Darwin
import Dispatch
import Foundation
@testable import IlliquidNativePlayback

private struct Input: Sendable {
    let size: CGSize
    var aperture: CGRect? = nil
    var rotation: Double = 0
    var mirrored: Bool = false
    var displayCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    func cached(_ cache: inout PiPVideoMapping.TextureCoordinateCache) -> [SIMD2<Float>] {
        #if BASELINE
        // The timed baseline calls the original production function directly;
        // the compatibility adapter is used only by the semantic tests.
        return PiPVideoMapping.textureCoordinates(
            codedSize: size, cleanAperture: aperture,
            rotationDegrees: rotation, mirrored: mirrored, displayCrop: displayCrop
        )
        #else
        return cache.coordinates(
            codedSize: size, cleanAperture: aperture,
            rotationDegrees: rotation, mirrored: mirrored, displayCrop: displayCrop
        )
        #endif
    }

    func direct() -> [SIMD2<Float>] {
        PiPVideoMapping.textureCoordinates(
            codedSize: size, cleanAperture: aperture,
            rotationDegrees: rotation, mirrored: mirrored, displayCrop: displayCrop
        )
    }
}

private enum Workload: String, CaseIterable {
    case identity
    case croppedRotated = "cropped-rotated"
    case mirrored
    case geometryEvery120 = "geometry-every-120"
    case alternating
    case hdrIdentity = "hdr-identity"
}

private func fixtures() -> [Input] {
    [
        Input(size: CGSize(width: 1920, height: 1080)),
        Input(
            size: CGSize(width: 1920, height: 1080),
            aperture: CGRect(x: 8, y: 16, width: 1904, height: 1048),
            rotation: 90,
            displayCrop: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        ),
        Input(
            size: CGSize(width: 3840, height: 2160),
            aperture: CGRect(x: 32, y: 24, width: 3776, height: 2112),
            rotation: 270, mirrored: true,
            displayCrop: CGRect(x: 0.2, y: 0, width: 0.6, height: 1)
        ),
        Input(
            size: CGSize(width: 720, height: 576),
            aperture: CGRect(x: 8, y: 0, width: 704, height: 576),
            rotation: 17.5, mirrored: true,
            displayCrop: CGRect(x: -0.1, y: -0.2, width: 1.2, height: 1.4)
        ),
    ]
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func bits(_ coordinates: [SIMD2<Float>]) -> [UInt32] {
    coordinates.flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
}

@inline(never)
private func runLoop(
    inputs: [Input], changeEvery: Int, hdr: Bool, iterations: Int,
    cache: inout PiPVideoMapping.TextureCoordinateCache
) -> UInt64 {
    var checksum: UInt64 = 0
    for iteration in 0..<iterations {
        let coordinates: [SIMD2<Float>]
        if hdr {
            coordinates = requestHDRIdentityCoordinates()
        } else {
            let input = inputs[(iteration / changeEvery) % inputs.count]
            coordinates = input.cached(&cache)
        }
        // Consume a result without hashing or serializing inside the timer.
        // The verification mode checks all twelve Float components.
        checksum &+= UInt64(coordinates[iteration % 6].x.bitPattern)
    }
    return checksum
}

private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func verify() throws {
    var corpus = fixtures()
    let sizes = [
        CGSize(width: 1, height: 1), CGSize(width: 100, height: 80),
        CGSize(width: 3840, height: 2160),
    ]
    let angles: [Double] = [-450, -90, 0, 17.5, 90, 180, 270, 450]
    for size in sizes {
        for angle in angles {
            for mirrored in [false, true] {
                corpus.append(Input(size: size, rotation: angle, mirrored: mirrored))
            }
        }
    }
    let apertures: [CGRect?] = [
        nil, .zero, CGRect(x: 10, y: 20, width: 60, height: 40),
        CGRect(x: -10, y: -10, width: 70, height: 60),
        CGRect(x: 200, y: 200, width: 20, height: 20),
    ]
    let displayCrops = [
        CGRect(x: 0, y: 0, width: 1, height: 1),
        CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6),
        CGRect(x: -0.2, y: -0.1, width: 1.4, height: 1.2),
        CGRect(x: 0.25, y: 0.25, width: 0, height: 0),
    ]
    for aperture in apertures {
        for displayCrop in displayCrops {
            corpus.append(Input(
                size: CGSize(width: 100, height: 80), aperture: aperture,
                rotation: 90, mirrored: true, displayCrop: displayCrop
            ))
        }
    }
    corpus.append(Input(size: sizes[1], rotation: 0.0))
    corpus.append(Input(size: sizes[1], rotation: -0.0))
    corpus.append(Input(
        size: sizes[1], displayCrop: CGRect(x: -0.0, y: -0.0, width: 1, height: 1)
    ))
    corpus.append(Input(size: sizes[1]))

    var cache = PiPVideoMapping.TextureCoordinateCache()
    var receipts: [[UInt32]] = []
    for input in corpus + Array(corpus.reversed()) {
        for _ in 0..<2 {
            let actual = bits(input.cached(&cache))
            let expected = bits(input.direct())
            precondition(actual.count == 12)
            precondition(actual == expected, "Cached/direct coordinate mismatch")
            receipts.append(actual)
        }
    }
    let identity = bits(PiPVideoMapping.identityTextureCoordinates)
    precondition(identity == bits(fixtures()[0].direct()))
    try emit([
        "kind": "verification", "corpus_inputs": corpus.count,
        "requests": receipts.count, "coordinates": receipts,
        "hdr_identity": identity, "cached_matches_direct": true,
    ])
}

@main
private enum Driver {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            try emit(["cases": Workload.allCases.map(\.rawValue)])
            return
        }
        if arguments == ["--verify"] {
            try verify()
            return
        }
        precondition(arguments.count == 2, "Usage: benchmark CASE ITERATIONS")
        guard let workload = Workload(rawValue: arguments[0]),
              let iterations = Int(arguments[1]), iterations > 0 else {
            preconditionFailure("Unknown workload or invalid iteration count")
        }

        let all = fixtures()
        let inputs: [Input]
        switch workload {
        case .identity, .hdrIdentity: inputs = [all[0]]
        case .croppedRotated: inputs = [all[1]]
        case .mirrored: inputs = [all[2]]
        case .geometryEvery120: inputs = all
        case .alternating: inputs = [all[0], all[1]]
        }
        let changeEvery = workload == .geometryEvery120 ? 120 : 1
        let hdr = workload == .hdrIdentity
        var cache = PiPVideoMapping.TextureCoordinateCache()
        let warmupChecksum = runLoop(
            inputs: inputs, changeEvery: changeEvery, hdr: hdr,
            iterations: 4096, cache: &cache
        )

        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let checksum = runLoop(
            inputs: inputs, changeEvery: changeEvery, hdr: hdr,
            iterations: iterations, cache: &cache
        )
        let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuElapsed = cpuNanoseconds() - cpuStart

        let finalInput = inputs[((iterations - 1) / changeEvery) % inputs.count]
        let finalCoordinates = hdr
            ? PiPVideoMapping.identityTextureCoordinates : finalInput.cached(&cache)
        let expectedCoordinates = hdr ? all[0].direct() : finalInput.direct()
        precondition(bits(finalCoordinates) == bits(expectedCoordinates))
        try emit([
            "kind": "measurement", "case": workload.rawValue, "iterations": iterations,
            "calls_per_iteration": 1, "cpu_nanoseconds": cpuElapsed,
            "wall_nanoseconds": wallElapsed,
            "cpu_ns_per_call": Double(cpuElapsed) / Double(iterations),
            "wall_ns_per_call": Double(wallElapsed) / Double(iterations),
            "checksum": String(checksum), "warmup_checksum": String(warmupChecksum),
            "final_coordinates": bits(finalCoordinates),
        ])
    }
}
