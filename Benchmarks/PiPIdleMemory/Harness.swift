import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal
import Testing
@testable import IlliquidNativePlayback

// Staged by run.py into the native test target for the experiment only.
// This drives the real compositor and awaits real Metal command completion.
@Suite("PiP idle resource research", .serialized)
struct PiPIdleResourceResearchTests {
    private final class WeakProbe: @unchecked Sendable {
        weak var object: AnyObject?
        let bytes: Int
        init(_ object: AnyObject, bytes: Int = 0) {
            self.object = object
            self.bytes = bytes
        }
    }

    private struct Probes: Sendable {
        let pool: WeakProbe?
        let texture: WeakProbe?
    }

    @Test @MainActor
    func recordOwnershipAndRestartLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let receipt = environment["ILLIQUID_PIP_IDLE_RECEIPT"],
              let variant = environment["ILLIQUID_PIP_IDLE_VARIANT"]
        else { throw ResearchError.missingEnvironment }
        guard ["baseline", "candidate"].contains(variant),
              let iterations = Int(environment["ILLIQUID_PIP_IDLE_ITERATIONS"] ?? "6"),
              iterations > 0
        else { throw ResearchError.invalidEnvironment }

        let metalDevice = try #require(MTLCreateSystemDefaultDevice())
        var rows: [[String: Any]] = []
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for hdr in [false, true] {
                for count in [1, 12] {
                    rows.append(try await measure(
                        width: width, height: height, hdr: hdr, count: count,
                        iterations: iterations, variant: variant))
                }
            }
        }
        let result: [String: Any] = [
            "variant": variant,
            "iterations": iterations,
            "scope": "real compositor output ownership and component resource recreation latency; direct composition excludes production worker scheduling, presenter enqueue, AVKit UI, shader initialization, and source setup; not process RSS",
            "metal_device": [
                "name": metalDevice.name,
                "registry_id": String(metalDevice.registryID),
            ],
            "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receipt), options: .atomic)
    }

    @MainActor private func measure(
        width: Int, height: Int, hdr: Bool, count: Int,
        iterations: Int, variant: String
    ) async throws -> [String: Any] {
        let size = CGSize(width: width, height: height)
        let source = try makeSource(width: width, height: height, hdr: hdr)
        let frame = NativeDecodedVideoFrame(
            pixelBuffer: source, planarOwnershipToken: nil,
            presentationTime: .zero, duration: CMTime(value: 1, timescale: 30),
            generation: 0, codedSize: size, displaySize: size,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0,
            colorPrimaries: hdr ? 9 : 1, transferCharacteristic: hdr ? 16 : 1,
            matrixCoefficients: hdr ? 9 : nil, isFullRange: !hdr,
            hasMasteringDisplayMetadata: false, hasContentLightMetadata: false,
            sourceComponentDepth: hdr ? 10 : 8,
            ffmpegPixelFormat: hdr ? "p010le" : "bgra",
            isHardwareDecoded: false, isCopiedHardwarePath: false, isNearZeroCopy: false)
        let compositor = try PiPSubtitleCompositor()
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })

        // This helper's scope drops every strong output owner before the idle
        // snapshots. All N buffers were simultaneously alive when probed.
        let (reference, buffers) = try await fillPool(compositor, frame: frame, count: count)
        let resources = await compositor.withOutputResourcesForTesting { pool, texture in
            Probes(pool: pool.map { WeakProbe($0) },
                   texture: texture.map { WeakProbe($0, bytes: $0.allocatedSize) })
        }
        let active = await compositor.outputResourceSnapshotForTesting()
        #expect(active.hasPool && active.hasPoolObserver)
        #expect(active.observedBufferCount == count)
        #expect((active.hdrTextureBytes > 0) == hdr)
        #expect(resources.pool?.object != nil)
        if hdr { #expect(resources.texture?.object != nil) }
        let beforeBufferBytes = buffers.filter { $0.object != nil }.reduce(0) { $0 + $1.bytes }
        let beforeBufferCount = buffers.filter { $0.object != nil }.count

        let expectedRetained = variant == "baseline"
        compositor.stop()
        let idle = try await stoppedSnapshot(compositor, poolRetained: expectedRetained)
        #expect(!idle.active && !idle.workerActive)
        #expect(idle.hasPool == expectedRetained)
        #expect(idle.hasPoolObserver == expectedRetained)
        #expect((resources.pool?.object != nil) == expectedRetained)
        #expect(idle.hdrTextureBytes == (expectedRetained ? active.hdrTextureBytes : 0))
        if hdr { #expect((resources.texture?.object != nil) == expectedRetained) }
        let afterBufferBytes = buffers.filter { $0.object != nil }.reduce(0) { $0 + $1.bytes }
        let afterBufferCount = buffers.filter { $0.object != nil }.count

        var timings: [UInt64] = []
        for _ in 0..<iterations {
            let (elapsed, output) = try await restart(compositor, frame: frame)
            #expect(output == reference)
            timings.append(elapsed)
            compositor.stop()
            _ = try await stoppedSnapshot(compositor, poolRetained: expectedRetained)
        }
        return [
            "case": "\(width)x\(height)-\(hdr ? "hdr-pq" : "bgra")-\(count)-outputs",
            "width": width, "height": height, "hdr": hdr,
            "simultaneously_held_outputs": count,
            "semantic": reference,
            "before": [
                "pool_owned": active.hasPool, "observer_owned": active.hasPoolObserver,
                "hdr_texture_allocated_bytes": active.hdrTextureBytes,
                "weak_live_output_buffers": beforeBufferCount,
                "weak_live_output_payload_bytes": beforeBufferBytes,
            ],
            "idle": [
                "pool_owned": idle.hasPool, "observer_owned": idle.hasPoolObserver,
                "hdr_texture_allocated_bytes": idle.hdrTextureBytes,
                "weak_live_output_buffers": afterBufferCount,
                "weak_live_output_payload_bytes": afterBufferBytes,
            ],
            "restart_to_gpu_completion_ns": timings,
        ]
    }

    @MainActor private func stoppedSnapshot(
        _ compositor: PiPSubtitleCompositor, poolRetained: Bool
    ) async throws -> PiPSubtitleCompositor.OutputResourceSnapshot {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        repeat {
            let snapshot = await compositor.outputResourceSnapshotForTesting()
            if !snapshot.active && !snapshot.workerActive && snapshot.hasPool == poolRetained {
                return snapshot
            }
            await Task.yield()
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw ResearchError.stopDidNotDrain
    }

    @MainActor private func fillPool(
        _ compositor: PiPSubtitleCompositor, frame: NativeDecodedVideoFrame, count: Int
    ) async throws -> ([String: String], [WeakProbe]) {
        var outputs: [CVPixelBuffer] = []
        for _ in 0..<count {
            outputs.append(try await compositor.composedPixelBufferForTesting(frame))
        }
        let first = try #require(outputs.first)
        let reference = try fingerprint(first)
        let probes = outputs.map { WeakProbe($0, bytes: CVPixelBufferGetDataSize($0)) }
        #expect(probes.allSatisfy { $0.object != nil })
        return (reference, probes)
    }

    @MainActor private func restart(
        _ compositor: PiPSubtitleCompositor, frame: NativeDecodedVideoFrame
    ) async throws -> (UInt64, [String: String]) {
        // This seam leaves latestFrame nil and workerActive false. The timed
        // interval includes output-resource recreation and GPU composition, but
        // excludes normal worker scheduling, presenter enqueue, and AVKit UI.
        let begin = DispatchTime.now().uptimeNanoseconds
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        let output = try await compositor.composedPixelBufferForTesting(frame)
        let elapsed = DispatchTime.now().uptimeNanoseconds - begin
        return (elapsed, try fingerprint(output))
    }

    private func fingerprint(_ buffer: CVPixelBuffer) throws -> [String: String] {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else { throw ResearchError.pixelBuffer(status) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var hash = SHA256()
        let planes = CVPixelBufferGetPlaneCount(buffer)
        if planes == 0 {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            for row in 0..<CVPixelBufferGetHeight(buffer) {
                hash.update(data: Data(bytes: base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)),
                                       count: CVPixelBufferGetWidth(buffer) * 4))
            }
        } else {
            for plane in 0..<planes {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                let logicalBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 2 : 4)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    hash.update(data: Data(
                        bytes: base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)),
                        count: logicalBytes))
                }
            }
        }
        var result = [
            "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
            "format": String(CVPixelBufferGetPixelFormatType(buffer)),
            "width": String(CVPixelBufferGetWidth(buffer)),
            "height": String(CVPixelBufferGetHeight(buffer)),
        ]
        for (name, key) in [
            ("primaries", kCVImageBufferColorPrimariesKey),
            ("transfer", kCVImageBufferTransferFunctionKey),
            ("matrix", kCVImageBufferYCbCrMatrixKey),
        ] {
            result[name] = CVBufferCopyAttachment(buffer, key, nil) as? String ?? ""
        }
        return result
    }

    private func makeSource(width: Int, height: Int, hdr: Bool) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true,
             kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &result)
        guard status == kCVReturnSuccess else { throw ResearchError.pixelBuffer(status) }
        let buffer = try #require(result)
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else { throw ResearchError.pixelBuffer(lockStatus) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if hdr {
            for plane in 0..<2 {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        row[x] = UInt16((plane == 0 ? 200 + (x + y) % 600 : 512) << 6)
                    }
                }
            }
        } else {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            for y in 0..<height {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4] = UInt8(x % 200)
                    row[x * 4 + 1] = UInt8(y % 200)
                    row[x * 4 + 2] = 96
                    row[x * 4 + 3] = 255
                }
            }
        }
        return buffer
    }

    private enum ResearchError: Error {
        case missingEnvironment
        case invalidEnvironment
        case stopDidNotDrain
        case pixelBuffer(CVReturn)
    }
}
