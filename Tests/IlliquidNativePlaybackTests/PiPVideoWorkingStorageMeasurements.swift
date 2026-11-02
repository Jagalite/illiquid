import AppKit
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Metal
import Testing
@testable import IlliquidNativePlayback

/// Opt-in observations of the real compositor on a native Metal device.
/// The runner uses this identical test in the candidate and matched control.
@Suite("PiP video working storage measurements", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_PIP_STORAGE_MEASURE"] == "1"))
struct PiPVideoWorkingStorageMeasurements {
    private struct Workload {
        let name: String
        let width: Int
        let height: Int
        let isHDR: Bool
        let heldOutputs = 4

        var size: CGSize { CGSize(width: width, height: height) }
        var pixelFormat: OSType {
            isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_32BGRA
        }
    }

    private struct MeasurementFailure: Error, CustomStringConvertible {
        let description: String
    }

    private struct OutputFingerprint: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let sha256: String
        let captionComponent: Int
        let backgroundComponent: Int

        var json: [String: Any] {
            [
                "width": width, "height": height, "pixel_format": pixelFormat,
                "sha256": sha256, "caption_component": captionComponent,
                "background_component": backgroundComponent,
            ]
        }
    }

    private final class FirstSampleReceipt: @unchecked Sendable {
        struct Snapshot: Sendable {
            let succeeded: Bool
            let elapsedNanoseconds: UInt64
            let error: String?
        }

        private let lock = NSLock()
        private let started = DispatchTime.now().uptimeNanoseconds
        private var value: Snapshot?

        func finish(_ result: Result<Void, Error>) {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            lock.withLock {
                guard value == nil else { return }
                switch result {
                case .success:
                    value = Snapshot(succeeded: true, elapsedNanoseconds: elapsed, error: nil)
                case let .failure(error):
                    value = Snapshot(succeeded: false, elapsedNanoseconds: elapsed,
                                     error: String(describing: error))
                }
            }
        }

        var snapshot: Snapshot? { lock.withLock { value } }
    }

    @Test @MainActor
    func recordWorkingStorageRetirement() async throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = try #require(environment["ILLIQUID_PIP_STORAGE_MODE"])
        let pass = try #require(environment["ILLIQUID_PIP_STORAGE_PASS"])
        let workload: Workload
        switch mode {
        case "sdr-1080p":
            workload = Workload(name: mode, width: 1_920, height: 1_080, isHDR: false)
        case "pq-4k":
            workload = Workload(name: mode, width: 3_840, height: 2_160, isHDR: true)
        default:
            throw MeasurementFailure(description: "Unknown measurement mode: \(mode)")
        }

        // Absence of native Metal is a failed qualification, never a skip.
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = NSApplication.shared
        let pipeline = try makePipeline(size: workload.size)
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        defer { compositor.stop() }
        let source = try autoreleasepool { try makeSource(workload) }
        let frame = makeFrame(source: source, workload: workload)
        compositor.receive(frame)

        let before = try await sample(compositor, device: device, label: "before-start")
        let firstStart = try await startAndWait(compositor)

        // A queue snapshot follows the production completion handler, so the
        // worker has relinquished admission before the direct test seam runs.
        _ = await compositor.videoWorkingStorageSnapshotForTesting()
        let output = try await populatePoolAndReleaseOutputs(
            compositor, frame: frame, workload: workload)
        try await Task.sleep(for: .milliseconds(100))
        let active = try await sample(compositor, device: device, label: "active-populated")
        let activeState = await compositor.videoWorkingStorageSnapshotForTesting()
        try #require(compositor.isActive)
        try #require(activeState.hasOutputPool && activeState.hasOutputPoolObserver)
        try #require(activeState.hasHDRTexture == workload.isHDR)
        try #require(activeState.hasPreparedSubtitleFrame)
        try #require(activeState.observedOutputBufferCount >= workload.heldOutputs)
        try #require(activeState.latestFrameSeconds == 1)
        if workload.isHDR {
            try #require(activeState.hdrTextureAllocatedBytes >= workload.width * workload.height * 8)
        }

        let stopRequested = DispatchTime.now().uptimeNanoseconds
        compositor.stop()
        var idle: [[String: Any]] = []
        for (label, delay) in [("after-stop", 0), ("idle-100ms", 100), ("idle-300ms", 200)] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            var observed = try await sample(compositor, device: device, label: label)
            observed["since_stop_ns"] = DispatchTime.now().uptimeNanoseconds - stopRequested
            idle.append(observed)
        }
        try #require(!compositor.isActive)

        // Same cached frame and caption; no receive() call precedes restart.
        let reentry = try await startAndWait(compositor)
        _ = await compositor.videoWorkingStorageSnapshotForTesting()
        let reentryOutput = try await composeFingerprint(compositor, frame: frame)
        try #require(reentryOutput == output)
        let reentryMetrics = compositor.metricsSnapshot()
        try #require(reentryMetrics.composedFrames == 1)
        try #require(reentryMetrics.immediatelyDisplayedFrames == 1)
        try #require(reentryMetrics.subtitleVisibleFrames >= 1)
        let reentered = try await sample(compositor, device: device, label: "reentered")

        compositor.stop()
        let secondStop = try await sample(compositor, device: device, label: "second-stop")
        let record: [String: Any] = [
            "schema_version": 1,
            "mode": mode,
            "pass": pass,
            "width": workload.width,
            "height": workload.height,
            "is_hdr": workload.isHDR,
            "temporarily_held_outputs": workload.heldOutputs,
            "metal_device": device.name,
            "metal_registry_id": device.registryID,
            "unified_memory": device.hasUnifiedMemory,
            "first_start_sample_ns": firstStart,
            "reentry_first_sample_ns": reentry,
            "output": output.json,
            "reentry_output": reentryOutput.json,
            "reentry_subtitle_texture_uploads": reentryMetrics.subtitleTextureUploads,
            "reentry_subtitle_resource_reuses": reentryMetrics.subtitleResourceReuses,
            "before": before,
            "active": active,
            "idle": idle,
            "reentered": reentered,
            "second_stop": secondStop,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("PIP_VIDEO_WORKING_STORAGE_MEASUREMENT " + String(decoding: data, as: UTF8.self))
        withExtendedLifetime(source) {}
        withExtendedLifetime(compositor) {}
    }

    @MainActor
    private func startAndWait(_ compositor: PiPSubtitleCompositor) async throws -> UInt64 {
        let receipt = FirstSampleReceipt()
        compositor.start(onFirstSample: { receipt.finish($0) },
                         onFailure: { receipt.finish(.failure($0)) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let value = receipt.snapshot {
                guard value.succeeded else {
                    throw MeasurementFailure(description: value.error ?? "PiP first sample failed")
                }
                return value.elapsedNanoseconds
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw MeasurementFailure(description: "Native PiP first sample did not complete within 15 seconds")
    }

    @MainActor
    private func sample(
        _ compositor: PiPSubtitleCompositor, device: any MTLDevice, label: String
    ) async throws -> [String: Any] {
        // The snapshot is also a workQueue barrier. It owns only scalar values.
        let state = await compositor.videoWorkingStorageSnapshotForTesting()
        return try autoreleasepool {
            [
                "label": label,
                "monotonic_ns": DispatchTime.now().uptimeNanoseconds,
                "physical_footprint_bytes": try physicalFootprint(),
                "metal_current_allocated_bytes": device.currentAllocatedSize,
                "has_output_pool": state.hasOutputPool,
                "has_output_pool_observer": state.hasOutputPoolObserver,
                "has_hdr_texture": state.hasHDRTexture,
                "hdr_texture_allocated_bytes": state.hdrTextureAllocatedBytes,
                "observed_output_buffers": state.observedOutputBufferCount,
                "has_prepared_subtitle_frame": state.hasPreparedSubtitleFrame,
                "latest_frame_seconds": state.latestFrameSeconds.map { $0 as Any } ?? NSNull(),
            ]
        }
    }

    @MainActor @inline(never)
    private func populatePoolAndReleaseOutputs(
        _ compositor: PiPSubtitleCompositor,
        frame: NativeDecodedVideoFrame,
        workload: Workload
    ) async throws -> OutputFingerprint {
        // Holding four completed outputs exercises real pool storage without
        // issuing concurrent GPU work or exceeding the production 12-buffer cap.
        var outputs: [CVPixelBuffer] = []
        for _ in 0..<workload.heldOutputs {
            outputs.append(try await compositor.composedPixelBufferForTesting(frame))
        }
        let result = try autoreleasepool { try fingerprint(try #require(outputs.first)) }
        try #require(result.width == workload.width && result.height == workload.height)
        try #require(result.pixelFormat == workload.pixelFormat)
        try #require(result.captionComponent > result.backgroundComponent)
        autoreleasepool { outputs.removeAll(keepingCapacity: false) }
        // Returning only scalar/checksum data makes the input/output ownership
        // boundary explicit before the caller samples retained working storage.
        return result
    }

    @MainActor @inline(never)
    private func composeFingerprint(
        _ compositor: PiPSubtitleCompositor, frame: NativeDecodedVideoFrame
    ) async throws -> OutputFingerprint {
        let output = try await compositor.composedPixelBufferForTesting(frame)
        return try autoreleasepool { try fingerprint(output) }
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw MeasurementFailure(description: "task_info(TASK_VM_INFO) failed: \(status)")
        }
        return info.phys_footprint
    }

    private func fingerprint(_ buffer: CVPixelBuffer) throws -> OutputFingerprint {
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        let planes = planar ? CVPixelBufferGetPlaneCount(buffer) : 1
        var hash = SHA256()
        for plane in 0..<planes {
            let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
            let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
            let base = try #require(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                                           : CVPixelBufferGetBaseAddress(buffer))
            let rowBytes = width * (planar && plane == 0 ? 2 : 4)
            for y in 0..<height {
                hash.update(bufferPointer: UnsafeRawBufferPointer(
                    start: base.advanced(by: y * stride), count: rowBytes))
            }
        }
        let base = try #require(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
                                       : CVPixelBufferGetBaseAddress(buffer))
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                            : CVPixelBufferGetBytesPerRow(buffer)
        let caption: Int
        let background: Int
        if planar {
            caption = Int(base.advanced(by: 32 * stride).assumingMemoryBound(to: UInt16.self)[32] >> 6)
            background = Int(base.assumingMemoryBound(to: UInt16.self)[0] >> 6)
        } else {
            caption = Int(base.assumingMemoryBound(to: UInt8.self)[32 * stride + 32 * 4])
            background = Int(base.assumingMemoryBound(to: UInt8.self)[0])
        }
        return OutputFingerprint(
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer),
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            captionComponent: caption, backgroundComponent: background)
    }

    @MainActor
    private func makePipeline(size: CGSize) throws -> SubtitlePipeline {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle",
                                   attachments: [], frameSize: size, storageSize: size)
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: Data(repeating: 255, count: 64 * 32 * 4),
                            frame: CGRect(x: 16, y: 16, width: 64, height: 32), isForced: false)],
            canvasSize: size, duration: 10, memoryLease: nil)
        try #require(pipeline.process(event: .init(
            assData: Data(), presentationSeconds: 0, durationSeconds: 10,
            generation: 0, bitmapComposition: composition)))
        return pipeline
    }

    private func makeSource(_ workload: Workload) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, workload.width, workload.height, workload.pixelFormat,
            attributes as CFDictionary, &pixelBuffer)
        try #require(result == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if workload.isHDR {
            for plane in 0..<2 {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                    .assumingMemoryBound(to: UInt16.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
                let code: UInt16 = plane == 0 ? 64 << 6 : 512 << 6
                for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    for x in 0..<workload.width { base[y * stride + x] = code }
                }
            }
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        } else {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, 0, stride * workload.height)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<workload.height {
                for x in 0..<workload.width { bytes[y * stride + x * 4 + 3] = 255 }
            }
        }
        return buffer
    }

    private func makeFrame(source: CVPixelBuffer, workload: Workload) -> NativeDecodedVideoFrame {
        NativeDecodedVideoFrame(
            pixelBuffer: source, planarOwnershipToken: nil,
            presentationTime: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(value: 1, timescale: 30), generation: 0,
            codedSize: workload.size, displaySize: workload.size,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0,
            colorPrimaries: workload.isHDR ? 9 : nil,
            transferCharacteristic: workload.isHDR ? 16 : nil,
            matrixCoefficients: workload.isHDR ? 9 : nil,
            isFullRange: !workload.isHDR,
            hasMasteringDisplayMetadata: false, hasContentLightMetadata: false,
            sourceComponentDepth: workload.isHDR ? 10 : 8,
            ffmpegPixelFormat: workload.isHDR ? "p010le" : "bgra",
            isHardwareDecoded: false, isCopiedHardwarePath: false, isNearZeroCopy: false)
    }
}
