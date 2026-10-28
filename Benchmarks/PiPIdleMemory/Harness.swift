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

    private final class FirstSampleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt64, Error>?

        init(_ continuation: CheckedContinuation<UInt64, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<UInt64, Error>) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(with: result)
        }
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
        let extendedSettle = environment["ILLIQUID_PIP_IDLE_LONG_SETTLE"] == "1"
        // Run the production-worker probe before direct composition/readbacks so
        // its per-cycle changes cannot be caused by the companion fingerprinting.
        var productionRows: [[String: Any]] = []
        for (width, height, hdr) in [(1920, 1080, false), (3840, 2160, true)] {
            productionRows.append(try await productionCycles(
                width: width, height: height, hdr: hdr, device: metalDevice,
                variant: variant, extendedSettle: extendedSettle))
        }
        var rows: [[String: Any]] = []
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for hdr in [false, true] {
                for count in [1, 12] {
                    rows.append(try await measure(
                        width: width, height: height, hdr: hdr, count: count,
                        iterations: iterations, variant: variant, device: metalDevice))
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
            "production_cycles": productionRows,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receipt), options: .atomic)
    }

    @MainActor private func measure(
        width: Int, height: Int, hdr: Bool, count: Int,
        iterations: Int, variant: String, device: any MTLDevice
    ) async throws -> [String: Any] {
        let beforeSetupDeviceBytes = device.currentAllocatedSize
        let size = CGSize(width: width, height: height)
        let source = try makeSource(width: width, height: height, hdr: hdr)
        let frame = decodedFrame(source: source, size: size, hdr: hdr)
        let compositor = try PiPSubtitleCompositor()
        let beforeComposeDeviceBytes = device.currentAllocatedSize
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
        let populatedDeviceBytes = device.currentAllocatedSize

        let expectedRetained = variant == "baseline"
        compositor.stop()
        let stopRequestedDeviceBytes = device.currentAllocatedSize
        let idle = try await stoppedSnapshot(compositor, poolRetained: expectedRetained)
        #expect(!idle.active && !idle.workerActive)
        #expect(idle.hasPool == expectedRetained)
        #expect(idle.hasPoolObserver == expectedRetained)
        #expect((resources.pool?.object != nil) == expectedRetained)
        #expect(idle.hdrTextureBytes == (expectedRetained ? active.hdrTextureBytes : 0))
        if hdr { #expect((resources.texture?.object != nil) == expectedRetained) }
        let afterBufferBytes = buffers.filter { $0.object != nil }.reduce(0) { $0 + $1.bytes }
        let afterBufferCount = buffers.filter { $0.object != nil }.count
        let firstStoppedDeviceBytes = device.currentAllocatedSize

        var timings: [UInt64] = []
        var deviceSamples: [[String: Any]] = []
        for iteration in 0..<iterations {
            let (elapsed, output) = try await restart(compositor, frame: frame)
            #expect(output == reference)
            timings.append(elapsed)
            let afterCompose = device.currentAllocatedSize
            compositor.stop()
            let afterStopRequest = device.currentAllocatedSize
            _ = try await stoppedSnapshot(compositor, poolRetained: expectedRetained)
            deviceSamples.append([
                "iteration": iteration + 1,
                "after_compose_device_bytes": afterCompose,
                "stop_requested_device_bytes": afterStopRequest,
                "stopped_barrier_device_bytes": device.currentAllocatedSize,
            ])
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
            "device_allocations": [
                "before_setup_bytes": beforeSetupDeviceBytes,
                "before_initial_compose_bytes": beforeComposeDeviceBytes,
                "populated_bytes": populatedDeviceBytes,
                "first_stop_requested_bytes": stopRequestedDeviceBytes,
                "first_stopped_barrier_bytes": firstStoppedDeviceBytes,
                "restart_samples": deviceSamples,
                "final_stopped_barrier_bytes": device.currentAllocatedSize,
            ],
        ]
    }

    @MainActor private func productionCycles(
        width: Int, height: Int, hdr: Bool, device: any MTLDevice,
        variant: String, extendedSettle: Bool
    ) async throws -> [String: Any] {
        let beforeSetup = device.currentAllocatedSize
        let size = CGSize(width: width, height: height)
        let source = try makeSource(width: width, height: height, hdr: hdr)
        let frame = decodedFrame(source: source, size: size, hdr: hdr)
        let compositor = try PiPSubtitleCompositor()
        let beforeCompose = device.currentAllocatedSize
        var cycles: [[String: Any]] = []
        for cycle in 1...8 {
            // receive() runs while inactive; start() must consume the real cached
            // frame, finish GPU work, and enqueue it through the presenter.
            compositor.receive(frame)
            let firstSampleNS = try await waitForFirstSample(compositor)
            let afterFirstSample = device.currentAllocatedSize
            let active = await compositor.outputResourceSnapshotForTesting()
            let metrics = compositor.metricsSnapshot()
            #expect(metrics.composedFrames == 1)
            #expect(metrics.enqueueFailures == 0)
            #expect(metrics.unsupportedFrames == 0)
            #expect(active.active && active.hasPool)
            compositor.stop()
            let afterStopRequest = device.currentAllocatedSize
            let stopped = try await stoppedSnapshot(compositor, poolRetained: variant == "baseline")
            let afterDrain = device.currentAllocatedSize
            let settleBegin = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(nanoseconds: 150_000_000)
            let settleElapsed = DispatchTime.now().uptimeNanoseconds - settleBegin
            cycles.append([
                "cycle": cycle,
                "start_to_first_sample_ns": firstSampleNS,
                "after_first_sample_device_bytes": afterFirstSample,
                "stop_requested_device_bytes": afterStopRequest,
                "stopped_barrier_device_bytes": afterDrain,
                "post_settle_device_bytes": device.currentAllocatedSize,
                "settle_requested_ns": 150_000_000,
                "settle_elapsed_ns": settleElapsed,
                "composed_frames": metrics.composedFrames,
                "stopped_pool_owned": stopped.hasPool,
                "stopped_observer_owned": stopped.hasPoolObserver,
                "stopped_hdr_texture_allocated_bytes": stopped.hdrTextureBytes,
            ])
        }
        let finalBegin = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let finalElapsed = DispatchTime.now().uptimeNanoseconds - finalBegin
        var result: [String: Any] = [
            "case": "\(width)x\(height)-\(hdr ? "hdr-pq" : "bgra")-production-cycles",
            "before_setup_device_bytes": beforeSetup,
            "before_initial_compose_device_bytes": beforeCompose,
            "cycles": cycles,
            "final_settle_requested_ns": 1_000_000_000,
            "final_settle_elapsed_ns": finalElapsed,
            "final_settled_device_bytes": device.currentAllocatedSize,
            "scope": "real receive/start/first-sample presenter callback/stop; no output pixel-buffer readbacks or retained output probes; device allocation counter is not RSS",
        ]
        if extendedSettle {
            let extendedBegin = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(nanoseconds: 5_000_000_000)
            result["extended_settle_requested_ns"] = 5_000_000_000 as UInt64
            result["extended_settle_elapsed_ns"] = DispatchTime.now().uptimeNanoseconds - extendedBegin
            result["extended_settled_device_bytes"] = device.currentAllocatedSize
        }
        // Keep the stopped compositor alive across both settling intervals.
        let finalState = await compositor.outputResourceSnapshotForTesting()
        #expect(!finalState.active && !finalState.workerActive)
        #expect(finalState.hasPool == (variant == "baseline"))
        result["final_pool_owned"] = finalState.hasPool
        result["final_hdr_texture_allocated_bytes"] = finalState.hdrTextureBytes
        return result
    }

    @MainActor private func waitForFirstSample(_ compositor: PiPSubtitleCompositor) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt64, Error>) in
            let gate = FirstSampleGate(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                gate.finish(.failure(ResearchError.firstSampleTimeout))
            }
            let begin = DispatchTime.now().uptimeNanoseconds
            compositor.start(
                onFirstSample: { result in
                    gate.finish(result.map { _ in DispatchTime.now().uptimeNanoseconds - begin })
                },
                onFailure: { gate.finish(.failure($0)) })
        }
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
        withExtendedLifetime(outputs) {
            #expect(probes.allSatisfy { $0.object != nil })
        }
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

    private func decodedFrame(source: CVPixelBuffer, size: CGSize, hdr: Bool) -> NativeDecodedVideoFrame {
        NativeDecodedVideoFrame(
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
        case firstSampleTimeout
        case pixelBuffer(CVReturn)
    }
}
