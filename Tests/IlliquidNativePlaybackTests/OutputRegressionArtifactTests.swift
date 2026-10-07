import AppKit
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import QuartzCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Native output regression artifacts", .serialized)
struct OutputRegressionArtifactTests {
    private var environment: ProcessInfo { .processInfo }

    @Test @MainActor
    func capturesVideoSubtitleAndAudioArtifacts() throws {
        guard let fixturePath = environment.environment["ILLIQUID_NATIVE_FIXTURE_DIR"],
              let artifactPath = environment.environment["ILLIQUID_OUTPUT_ARTIFACT_DIR"]
        else {
            if environment.environment["ILLIQUID_OUTPUT_REQUIRE"] == "1" {
                Issue.record(
                    "ILLIQUID_NATIVE_FIXTURE_DIR and ILLIQUID_OUTPUT_ARTIFACT_DIR are required"
                )
            }
            return
        }

        let fixtures = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let output = URL(fileURLWithPath: artifactPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        let fixtureNames = [
            "h264-aac.mp4",
            "hdr10-pq-p010.mkv",
            "hlg-p010.mkv",
            "av1-video-only.mkv",
            "embedded-srt.mkv",
            "embedded-ass-font.mkv",
            "external.ass",
            "heavy-animated.ass",
            "audio-5.1.flac",
        ]
        var fixtureHashes: [String: String] = [:]
        for name in fixtureNames {
            let url = fixtures.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("Missing output-regression fixture: \(name)")
                continue
            }
            fixtureHashes[name] = try sha256(Data(contentsOf: url))
        }
        #expect(fixtureHashes.count == fixtureNames.count)

        var video: [[String: Any]] = []
        video += try captureVideo(
            filename: "h264-aac.mp4",
            preferHardware: true,
            fixtures: fixtures,
            output: output
        )
        video += try captureVideo(
            filename: "hdr10-pq-p010.mkv",
            preferHardware: true,
            fixtures: fixtures,
            output: output
        )
        video += try captureVideo(
            filename: "hlg-p010.mkv",
            preferHardware: true,
            fixtures: fixtures,
            output: output
        )
        video += try captureVideo(
            filename: "av1-video-only.mkv",
            preferHardware: true,
            fixtures: fixtures,
            output: output
        )

        var subtitles: [[String: Any]] = []
        subtitles += try captureEmbeddedSRT(fixtures: fixtures, output: output)
        subtitles += try captureEmbeddedASS(fixtures: fixtures, output: output)
        subtitles += try captureExternalASS(fixtures: fixtures, output: output)
        subtitles += try captureAnimatedASS(fixtures: fixtures, output: output)

        let audio = [
            try captureAudio(
                filename: "h264-aac.mp4",
                fixtures: fixtures,
                output: output
            ),
            try captureAudio(
                filename: "audio-5.1.flac",
                fixtures: fixtures,
                output: output
            ),
        ]

        let manifest: [String: Any] = [
            "schema_version": 1,
            "source_revision": environment.environment["ILLIQUID_OUTPUT_SOURCE_REVISION"]
                ?? "unknown",
            "harness_revision": environment.environment["ILLIQUID_OUTPUT_HARNESS_REVISION"]
                ?? "unknown",
            "machine": machineIdentifier(),
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "fixtures": fixtureHashes,
            "video": video,
            "subtitles": subtitles,
            "audio": audio,
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try encoded.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func captureVideo(
        filename: String,
        preferHardware: Bool,
        fixtures: URL,
        output: URL
    ) throws -> [[String: Any]] {
        let demuxer = try FFmpegDemuxer(url: fixtures.appendingPathComponent(filename))
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: preferHardware,
            timelineOriginSeconds: demuxer.mediaInfo.startTime
        )
        // The AV1 fallback fixture is intentionally short. These timestamps
        // are present in every video fixture while still crossing multiple
        // decode/reorder intervals.
        let targets = [0.0, 0.25, 0.5]
        var targetIndex = 0
        var results: [[String: Any]] = []
        var packetCount = 0

        while targetIndex < targets.count, packetCount < 4_000,
              let packet = try demuxer.readPacket(generation: 1)
        {
            packetCount += 1
            guard packet.streamIndex == stream.index else { continue }
            for frame in try decoder.decode(packet) where targetIndex < targets.count {
                guard frame.presentationTime.isNumeric,
                      frame.presentationTime.seconds + 0.000_001 >= targets[targetIndex]
                else { continue }
                let normalized = try normalizedLuma(frame.pixelBuffer)
                let stem = safeStem(filename)
                    + String(format: "-video-%03d", Int((targets[targetIndex] * 1_000).rounded()))
                let pngName = stem + ".png"
                let png = try grayscalePNG(
                    bytes: normalized.bytes,
                    width: normalized.width,
                    height: normalized.height
                )
                try png.write(to: output.appendingPathComponent(pngName), options: .atomic)
                results.append([
                    "id": stem,
                    "fixture": filename,
                    "target_seconds": targets[targetIndex],
                    "actual_pts_seconds": frame.presentationTime.seconds,
                    "width": normalized.width,
                    "height": normalized.height,
                    "pixel_format": String(format: "0x%08x", normalized.pixelFormat),
                    "ffmpeg_pixel_format": frame.ffmpegPixelFormat,
                    "hardware_decoded": frame.isHardwareDecoded,
                    "luma_sha256": sha256(Data(normalized.bytes)),
                    "perceptual_hash": averageHash(
                        normalized.bytes,
                        width: normalized.width,
                        height: normalized.height
                    ),
                    "png": pngName,
                    "png_sha256": sha256(png),
                    "color_primaries": frame.colorPrimaries.map(Int.init) ?? -1,
                    "transfer_characteristic": frame.transferCharacteristic.map(Int.init) ?? -1,
                    "matrix_coefficients": frame.matrixCoefficients.map(Int.init) ?? -1,
                    "full_range": frame.isFullRange,
                    "mastering_display_metadata": frame.hasMasteringDisplayMetadata,
                    "content_light_metadata": frame.hasContentLightMetadata,
                ])
                targetIndex += 1
            }
        }
        #expect(results.count == targets.count, "Did not capture every target for \(filename)")
        return results
    }

    @MainActor
    private func captureEmbeddedSRT(fixtures: URL, output: URL) throws -> [[String: Any]] {
        let demuxer = try FFmpegDemuxer(url: fixtures.appendingPathComponent("embedded-srt.mkv"))
        let stream = try #require(demuxer.mediaInfo.subtitleStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        _ = try pipeline.configure(
            codecPrivate: demuxer.codecPrivateData(streamIndex: stream.index),
            codecName: stream.codecName,
            attachments: demuxer.mediaInfo.attachments,
            frameSize: CGSize(width: 640, height: 360),
            storageSize: CGSize(width: 640, height: 360)
        )
        for _ in 0..<500 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            for event in try decoder.decode(packet) {
                pipeline.process(event: event)
            }
        }
        return [try renderSubtitle(
            pipeline: pipeline,
            id: "embedded-srt-0800",
            fixture: "embedded-srt.mkv",
            seconds: 0.8,
            output: output
        )]
    }

    @MainActor
    private func captureEmbeddedASS(fixtures: URL, output: URL) throws -> [[String: Any]] {
        let demuxer = try FFmpegDemuxer(
            url: fixtures.appendingPathComponent("embedded-ass-font.mkv")
        )
        let stream = try #require(demuxer.mediaInfo.subtitleStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        _ = try pipeline.configure(
            codecPrivate: demuxer.codecPrivateData(streamIndex: stream.index),
            codecName: stream.codecName,
            attachments: demuxer.mediaInfo.attachments,
            frameSize: CGSize(width: 640, height: 360),
            storageSize: CGSize(width: 640, height: 360)
        )
        for _ in 0..<500 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            for event in try decoder.decode(packet) {
                pipeline.process(event: event)
            }
        }
        return [try renderSubtitle(
            pipeline: pipeline,
            id: "embedded-ass-font-1000",
            fixture: "embedded-ass-font.mkv",
            seconds: 1.0,
            output: output
        )]
    }

    @MainActor
    private func captureExternalASS(fixtures: URL, output: URL) throws -> [[String: Any]] {
        let fontContainer = try FFmpegDemuxer(
            url: fixtures.appendingPathComponent("embedded-ass-font.mkv")
        )
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        _ = try pipeline.configure(
            codecPrivate: nil,
            codecName: nil,
            attachments: fontContainer.mediaInfo.attachments,
            frameSize: CGSize(width: 640, height: 360),
            storageSize: CGSize(width: 640, height: 360)
        )
        try pipeline.loadExternal(url: fixtures.appendingPathComponent("external.ass"))
        let enabled = try renderSubtitle(
            pipeline: pipeline,
            id: "external-ass-1000",
            fixture: "external.ass",
            seconds: 1.0,
            output: output
        )
        pipeline.isEnabled = false
        let disabled = try renderSubtitle(
            pipeline: pipeline,
            id: "external-ass-disabled-1000",
            fixture: "external.ass",
            seconds: 1.0,
            output: output
        )
        #expect((enabled["nonzero_rgba_bytes"] as? Int ?? 0) > 0)
        #expect((disabled["nonzero_rgba_bytes"] as? Int ?? -1) == 0)
        return [enabled, disabled]
    }

    @MainActor
    private func captureAnimatedASS(fixtures: URL, output: URL) throws -> [[String: Any]] {
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try pipeline.loadExternal(url: fixtures.appendingPathComponent("heavy-animated.ass"))
        return try [0.25, 1.0, 1.75].map { seconds in
            try renderSubtitle(
                pipeline: pipeline,
                id: String(format: "heavy-animated-ass-%04d", Int(seconds * 1_000)),
                fixture: "heavy-animated.ass",
                seconds: seconds,
                output: output,
                width: 1_280,
                height: 720
            )
        }
    }

    @MainActor
    private func renderSubtitle(
        pipeline: SubtitlePipeline,
        id: String,
        fixture: String,
        seconds: Double,
        output: URL,
        width: Int = 640,
        height: Int = 360
    ) throws -> [String: Any] {
        let size = CGSize(width: width, height: height)
        let regions = pipeline.renderedRegions(
            at: CMTime(seconds: seconds, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: size),
            videoSize: size
        )
        let frame = try #require(ASSSubtitleFramePacker().prepare(
            regions: regions,
            canvasSize: size,
            strategy: .metalR8Atlas
        ))
        let metalPixels = try #require(MetalASSSubtitleRenderer(
            layer: CAMetalLayer()
        ).renderOffscreen(frame))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ))
        let destination = try #require(bitmap.bitmapData)
        metalPixels.withUnsafeBytes { sourceBytes in
            let source = sourceBytes.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let destinationRow = height - 1 - row
                for column in 0..<width {
                    let sourceOffset = (row * width + column) * 4
                    let destinationOffset =
                        destinationRow * bitmap.bytesPerRow + column * 4
                    destination[destinationOffset] = source[sourceOffset + 2]
                    destination[destinationOffset + 1] =
                        source[sourceOffset + 1]
                    destination[destinationOffset + 2] =
                        source[sourceOffset]
                    destination[destinationOffset + 3] =
                        source[sourceOffset + 3]
                }
            }
        }
        let byteCount = bitmap.bytesPerRow * bitmap.pixelsHigh
        let raw = Data(bytes: destination, count: byteCount)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let pngName = id + ".png"
        try png.write(to: output.appendingPathComponent(pngName), options: .atomic)
        var nonzeroBytes = 0
        raw.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in 0..<byteCount where bytes[offset] != 0 {
                nonzeroBytes += 1
            }
        }
        return [
            "id": id,
            "fixture": fixture,
            "target_seconds": seconds,
            "width": width,
            "height": height,
            "region_count": regions.count,
            "nonzero_rgba_bytes": nonzeroBytes,
            "rgba_sha256": sha256(raw),
            "png": pngName,
            "png_sha256": sha256(png),
        ]
    }

    private func captureAudio(filename: String, fixtures: URL, output: URL) throws -> [String: Any] {
        let demuxer = try FFmpegDemuxer(url: fixtures.appendingPathComponent(filename))
        let stream = try #require(demuxer.mediaInfo.audioStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try AudioDecoder(
            parameters: parameters,
            stream: stream,
            timelineOriginSeconds: demuxer.mediaInfo.startTime
        )
        let targetFrames = AudioDecoder.outputSampleRate
        let bytesPerFrame = AudioDecoder.outputChannelCount * MemoryLayout<Float>.size
        var pcm = Data()
        var sampleFrames = 0
        var firstPTS: Double?
        var packetCount = 0

        while sampleFrames < targetFrames, packetCount < 8_000,
              let packet = try demuxer.readPacket(generation: 1)
        {
            packetCount += 1
            guard packet.streamIndex == stream.index else { continue }
            for frame in try decoder.decode(packet) where sampleFrames < targetFrames {
                if firstPTS == nil, frame.presentationTime.isNumeric {
                    firstPTS = frame.presentationTime.seconds
                }
                let retained = min(frame.sampleCount, targetFrames - sampleFrames)
                pcm.append(frame.interleavedFloatPCM.prefix(retained * bytesPerFrame))
                sampleFrames += retained
            }
        }
        #expect(sampleFrames == targetFrames, "Did not capture one second of audio from \(filename)")
        let stem = safeStem(filename) + "-audio-1s"
        let rawName = stem + ".f32le"
        try pcm.write(to: output.appendingPathComponent(rawName), options: .atomic)
        let metrics = audioMetrics(pcm, channels: AudioDecoder.outputChannelCount)
        return [
            "id": stem,
            "fixture": filename,
            "sample_rate": AudioDecoder.outputSampleRate,
            "channels": AudioDecoder.outputChannelCount,
            "sample_frames": sampleFrames,
            "first_pts_seconds": firstPTS ?? -1,
            "pcm": rawName,
            "pcm_sha256": sha256(pcm),
            "peak": metrics.peak,
            "rms_left": metrics.rmsLeft,
            "rms_right": metrics.rmsRight,
            "window_rms": metrics.windowRMS,
        ]
    }

    private func normalizedLuma(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> (bytes: [UInt8], width: Int, height: Int, pixelFormat: OSType) {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw NSError(domain: "CoreVideo.CVReturn", code: Int(status))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var luma = [UInt8](repeating: 0, count: width * height)

        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            for row in 0..<height {
                if tenBit {
                    let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                    for column in 0..<width {
                        let value = Int(UInt16(littleEndian: source[column]) >> 6)
                        luma[row * width + column] = UInt8(clamping: (value * 255 + 511) / 1_023)
                    }
                } else {
                    let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                    luma.withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress?.advanced(by: row * width).update(
                            from: source,
                            count: width
                        )
                    }
                }
            }
        } else {
            let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard format == kCVPixelFormatType_32BGRA else {
                throw PresentationError(
                    "Unsupported packed output-regression pixel format \(format)"
                )
            }
            for row in 0..<height {
                let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<width {
                    let offset = column * 4
                    let blue = Int(source[offset])
                    let green = Int(source[offset + 1])
                    let red = Int(source[offset + 2])
                    luma[row * width + column] = UInt8(clamping: (77 * red + 150 * green + 29 * blue) >> 8)
                }
            }
        }
        return (luma, width, height, format)
    }

    private func grayscalePNG(bytes: [UInt8], width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceWhite,
            bytesPerRow: width,
            bitsPerPixel: 8
        ))
        let destination = try #require(bitmap.bitmapData)
        bytes.withUnsafeBytes { source in
            destination.update(from: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func averageHash(_ bytes: [UInt8], width: Int, height: Int) -> String {
        var samples = [Int](repeating: 0, count: 64)
        for sampleY in 0..<8 {
            for sampleX in 0..<8 {
                let x0 = sampleX * width / 8
                let x1 = max(x0 + 1, (sampleX + 1) * width / 8)
                let y0 = sampleY * height / 8
                let y1 = max(y0 + 1, (sampleY + 1) * height / 8)
                var total = 0
                var count = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        total += Int(bytes[y * width + x])
                        count += 1
                    }
                }
                samples[sampleY * 8 + sampleX] = count == 0 ? 0 : total / count
            }
        }
        let average = samples.reduce(0, +) / samples.count
        var hash: UInt64 = 0
        for (index, value) in samples.enumerated() where value >= average {
            hash |= UInt64(1) << UInt64(index)
        }
        return String(format: "%016llx", hash)
    }

    private func audioMetrics(
        _ data: Data,
        channels: Int
    ) -> (peak: Double, rmsLeft: Double, rmsRight: Double, windowRMS: [Double]) {
        let values: [Double] = stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return Double(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        var peak = 0.0
        var channelSquares = [Double](repeating: 0, count: channels)
        var channelCounts = [Int](repeating: 0, count: channels)
        for (index, value) in values.enumerated() {
            peak = max(peak, abs(value))
            let channel = index % channels
            channelSquares[channel] += value * value
            channelCounts[channel] += 1
        }
        let windowFrames = 960
        let totalFrames = values.count / channels
        var windows: [Double] = []
        for start in stride(from: 0, to: totalFrames, by: windowFrames) {
            let end = min(start + windowFrames, totalFrames)
            var square = 0.0
            var count = 0
            for frame in start..<end {
                for channel in 0..<channels {
                    let value = values[frame * channels + channel]
                    square += value * value
                    count += 1
                }
            }
            windows.append(count == 0 ? 0 : sqrt(square / Double(count)))
        }
        return (
            peak,
            sqrt(channelSquares[0] / Double(max(channelCounts[0], 1))),
            sqrt(channelSquares[min(1, channels - 1)] / Double(max(channelCounts[min(1, channels - 1)], 1))),
            windows
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func safeStem(_ filename: String) -> String {
        filename.replacingOccurrences(of: ".", with: "-")
    }

    private func machineIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(
            decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
