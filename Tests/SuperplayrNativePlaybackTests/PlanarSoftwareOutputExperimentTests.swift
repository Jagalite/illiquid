import AppKit
import AVFoundation
import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import SuperplayrCore
import SuperplayrPlayback
import Testing
@testable import SuperplayrNativePlayback

@Suite("Planar software output experiment", .serialized)
struct PlanarSoftwareOutputExperimentTests {
    private var fixtures: URL? {
        if let path = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TestFixtures/Generated", isDirectory: true)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private var experimentFixtures: URL {
        if let path = ProcessInfo.processInfo.environment[
            "SUPERPLAYR_PLANAR_EXPERIMENT_FIXTURE_DIR"
        ] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                "Benchmarks/NativeAppleVsIINA/fixtures/planar-experiment",
                isDirectory: true
            )
    }

    @Test func rendererRecommendationsMergeWithRequiredPlanarAttributes() throws {
        let presenter = SampleBufferVideoPresenter()
        let recommended = rendererAttributes(presenter)
        #expect(recommended[kCVPixelBufferIOSurfacePropertiesKey as String] != nil)

        let pool = try SoftwarePlanarOutputPool(
            generation: 1,
            width: 64,
            height: 64,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            rendererAttributes: recommended,
            maximumBufferCount: 2,
            waitTimeoutMilliseconds: 0
        )
        let buffer = try pool.makePixelBuffer()
        #expect(CVPixelBufferGetPixelFormatType(buffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetPlaneCount(buffer) == 2)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
    }

    @Test func planarPoolBoundsWaitsAndCancellation() throws {
        let pool = try SoftwarePlanarOutputPool(
            generation: 1,
            width: 64,
            height: 64,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            rendererAttributes: [:],
            maximumBufferCount: 2,
            waitTimeoutMilliseconds: 0
        )
        let first = try pool.makePixelBuffer()
        let second = try pool.makePixelBuffer()
        #expect(throws: SoftwarePixelBufferPoolError.exhausted) {
            try pool.makePixelBuffer()
        }
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try pool.makePixelBuffer(while: { false })
        }
        let diagnostics = pool.diagnostics
        #expect(diagnostics.checkouts == 2)
        #expect(diagnostics.uniqueBuffers == 2)
        #expect(diagnostics.peakInUseUpperBound == 2)
        #expect(diagnostics.thresholdWaits == 1)
        #expect(diagnostics.timeouts == 1)
        #expect(diagnostics.cancellations == 1)
        withExtendedLifetime((first, second)) {}
    }

    @Test func planarPoolReportsDistinctLiveBuffersWithoutInventingReuse() throws {
        let pool = try SoftwarePlanarOutputPool(
            generation: 1,
            width: 64,
            height: 64,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            rendererAttributes: [:],
            maximumBufferCount: 2,
            waitTimeoutMilliseconds: 0
        )
        let first = try pool.makePixelBuffer()
        let firstIdentity = UInt(bitPattern: Unmanaged
            .passUnretained(first)
            .toOpaque())
        let second = try pool.makePixelBuffer()
        let secondIdentity = UInt(bitPattern: Unmanaged
            .passUnretained(second)
            .toOpaque())
        let diagnostics = pool.diagnostics
        #expect(secondIdentity != firstIdentity)
        #expect(diagnostics.checkouts == 2)
        #expect(diagnostics.uniqueBuffers == 2)
        #expect(diagnostics.reusedCheckouts == 0)
        #expect(diagnostics.bytesPerBuffer > 0)
        #expect(diagnostics.maximumBufferCount == 2)
        withExtendedLifetime((first, second)) {}
    }

    @Test func planarOwnershipSeparatesApplicationAndRendererSampleLifetimes() throws {
        let ledger = PlanarBufferOwnershipLedger()
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        var token: PlanarFrameOwnershipToken? = ledger.checkout(
            generation: 7,
            pixelBuffer: buffer
        )
        token?.transition(to: .queued)

        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: try #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr)
        token?.attachRendererSampleLifetime(to: try #require(sample))
        token?.transition(to: .submitted)

        var snapshot = ledger.snapshot(activeGeneration: 7)
        #expect(snapshot.applicationFrames == 1)
        #expect(snapshot.submittedApplicationFrames == 1)
        #expect(snapshot.rendererSampleAttachments == 1)
        #expect(snapshot.knownOutstandingBuffers == 1)

        token = nil
        snapshot = ledger.snapshot(activeGeneration: 7)
        #expect(snapshot.applicationFrames == 0)
        #expect(snapshot.rendererSampleAttachments == 1)
        #expect(snapshot.knownOutstandingBuffers == 1)

        sample = nil
        snapshot = ledger.snapshot(activeGeneration: 7)
        #expect(snapshot.rendererSampleAttachments == 0)
        #expect(snapshot.knownOutstandingBuffers == 0)
    }

    @Test func planarTimeoutCapturesGenerationScopedKnownOwners() throws {
        let ledger = PlanarBufferOwnershipLedger()
        var firstBuffer: CVPixelBuffer?
        var secondBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &firstBuffer
        ) == kCVReturnSuccess)
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &secondBuffer
        ) == kCVReturnSuccess)
        let old = ledger.checkout(
            generation: 1,
            pixelBuffer: try #require(firstBuffer)
        )
        old.transition(to: .queued)
        let current = ledger.checkout(
            generation: 2,
            pixelBuffer: try #require(secondBuffer)
        )
        current.transition(to: .presenting)
        ledger.recordPoolThresholdWait(generation: 2)
        ledger.recordPoolTimeout(generation: 2)

        let snapshot = ledger.snapshot(activeGeneration: 2)
        #expect(snapshot.oldGenerationKnownOutstandingBuffers == 1)
        #expect(snapshot.poolThresholdWaits == 1)
        #expect(snapshot.poolTimeouts == 1)
        #expect(snapshot.lastTimeout?.knownOutstandingBuffers == 2)
        #expect(snapshot.lastTimeout?.applicationFrames == 2)
        #expect(snapshot.lastTimeout?.queuedFrames == 1)
        #expect(snapshot.lastTimeout?.presentingFrames == 1)
        withExtendedLifetime((old, current)) {}
    }

    @Test func planarFlushSeparatesRequestCompletionAndOldOwnerRelease() throws {
        let ledger = PlanarBufferOwnershipLedger()
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess)
        var token: PlanarFrameOwnershipToken? = ledger.checkout(
            generation: 4,
            pixelBuffer: try #require(pixelBuffer)
        )
        var sampleAttachment: PlanarRendererSampleLifetimeAttachment? =
            ledger.makeRendererSampleAttachment(
                checkoutID: try #require(token).checkoutID
            )

        ledger.recordFlushRequested(activeGeneration: 5)
        var flush = try #require(
            ledger.snapshot(activeGeneration: 5).lastFlush
        )
        #expect(flush.oldGenerationKnownBuffersAtRequest == 1)
        #expect(flush.oldGenerationRendererSamplesAtRequest == 1)
        #expect(!flush.videoFlushCompleted)

        token = nil
        ledger.recordVideoFlushCompleted(activeGeneration: 5)
        flush = try #require(ledger.snapshot(activeGeneration: 5).lastFlush)
        #expect(flush.videoFlushCompleted)
        #expect(flush.oldGenerationKnownBuffersAtVideoCompletion == 1)
        #expect(flush.oldGenerationRendererSamplesAtVideoCompletion == 1)
        #expect(flush.videoFlushCompletionMilliseconds != nil)
        #expect(flush.oldGenerationKnownBuffersReachedZeroMilliseconds == nil)

        sampleAttachment = nil
        flush = try #require(ledger.snapshot(activeGeneration: 5).lastFlush)
        #expect(flush.oldGenerationKnownBuffersReachedZeroMilliseconds != nil)
        withExtendedLifetime(sampleAttachment) {}
    }

    @Test func av1NV12MatchesBGRABytesMetadataAndTiming() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let comparison = try compareRoutes(
            url: url,
            rendererAttributes: rendererAttributes(presenter),
            frameCount: 3
        )
        #expect(comparison.planarFormat
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(comparison.maximumByteDelta == 0)
        #expect(comparison.differingBytes == 0)
        #expect(comparison.metadataAndTimingMatch)
        #expect(comparison.chromaLocation == nil)
    }

    @Test func softwareHDRP010MatchesBGRAWithinMeasuredQuantization() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("hdr10-pq-p010.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let comparison = try compareRoutes(
            url: url,
            rendererAttributes: rendererAttributes(presenter),
            frameCount: 3
        )
        #expect(comparison.planarFormat
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        // A planar round trip must not introduce more than one 8-bit code
        // value relative to the current direct software-BGRA conversion.
        #expect(comparison.maximumByteDelta <= 1)
        #expect(comparison.metadataAndTimingMatch)
        #expect(comparison.hasMasteringDisplayMetadata)
        #expect(comparison.hasContentLightMetadata)
        #expect(comparison.chromaLocation
            == kCVImageBufferChromaLocation_Left as String)
    }

    @Test func av1TenBitUsesP010WithExactCanonicalOutput() throws {
        let url = experimentFixtures.appendingPathComponent("av1-10bit.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let comparison = try compareRoutes(
            url: url,
            rendererAttributes: rendererAttributes(presenter),
            frameCount: 3
        )
        #expect(comparison.planarFormat
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(comparison.maximumByteDelta == 0)
        #expect(comparison.differingBytes == 0)
        #expect(comparison.metadataAndTimingMatch)
        #expect(comparison.chromaLocation
            == kCVImageBufferChromaLocation_Left as String)
    }

    @Test func preferredModePreservesLimitedAndFullRangeTenBit()
        throws
    {
        guard let fixtures else { return }
        let presenter = SampleBufferVideoPresenter()
        let attributes = rendererAttributes(presenter)
        let nv12URL = fixtures.appendingPathComponent("av1-video-only.mkv")
        let p010URL = experimentFixtures.appendingPathComponent("av1-10bit.mkv")
        let fullRangeURL = experimentFixtures.appendingPathComponent(
            "av1-10bit-full-range.mkv"
        )
        guard FileManager.default.fileExists(atPath: nv12URL.path),
              FileManager.default.fileExists(atPath: p010URL.path),
              FileManager.default.fileExists(atPath: fullRangeURL.path)
        else { return }

        let nv12 = try decode(
            url: nv12URL,
            mode: .planarPreferred(rendererAttributes: attributes),
            frameCount: 1
        )
        #expect(nv12.frames.first.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(nv12.decoder.planarOutputDiagnostics?.bgraFallbacks == 0)

        let p010 = try decode(
            url: p010URL,
            mode: .planarPreferred(rendererAttributes: attributes),
            frameCount: 1
        )
        #expect(p010.frames.first.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(p010.decoder.planarOutputDiagnostics?.bgraFallbacks == 0)

        let fullRange = try decode(
            url: fullRangeURL,
            mode: .planarPreferred(rendererAttributes: attributes),
            frameCount: 1
        )
        #expect(fullRange.frames.first.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
            == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(fullRange.frames.first?.isFullRange == true)
        #expect(fullRange.decoder.planarOutputDiagnostics?.bgraFallbacks == 0)
    }

    @Test func unsupported444RetainsBGRAFallback() throws {
        let url = experimentFixtures.appendingPathComponent("unsupported-444.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            #expect(ProcessInfo.processInfo.environment["SUPERPLAYR_PLANAR_EXPERIMENT_FIXTURE_DIR"] == nil,
                    "Regenerate the planar fixtures to include unsupported-444.mkv")
            return
        }
        let presenter = SampleBufferVideoPresenter()
        let result = try decode(url: url,
            mode: .planarPreferred(rendererAttributes: rendererAttributes(presenter)), frameCount: 3)
        #expect(result.frames.count == 3)
        #expect(result.frames.allSatisfy { CVPixelBufferGetPixelFormatType($0.pixelBuffer) == kCVPixelFormatType_32BGRA })
        #expect(result.frames.allSatisfy { $0.ffmpegPixelFormat == "yuv444p" })
        #expect(result.decoder.planarOutputDiagnostics?.bgraFallbacks == result.frames.count)
    }

    @Test func incrementalDecodeCancellationEmitsNoFrame() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            softwareOutputMode: .planarPreferred(
                rendererAttributes: rendererAttributes(presenter)
            )
        )
        let packet = try #require(try demuxer.readPacket(generation: 41))
        var emitted = 0
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder.decode(packet, while: { false }) { _ in emitted += 1 }
        }
        #expect(emitted == 0)
        #expect(decoder.planarOutputDiagnostics?.cancellations == 1)
    }

    @Test func softwareOutputReservationLivesWithDecodedFrame() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            softwareOutputMode: .bgra
        )
        let gate = VideoFrameCapacityGate(capacity: 1)
        var heldFrame: NativeDecodedVideoFrame?
        var shouldContinue = true
        while heldFrame == nil,
              let packet = try demuxer.readPacket(generation: 42)
        {
            guard packet.streamIndex == stream.index else { continue }
            do {
                try decoder.decode(
                    packet,
                    while: { shouldContinue },
                    reserveSoftwareOutput: {
                        gate.acquire(while: { shouldContinue })
                    }
                ) { frame in
                    heldFrame = frame
                    shouldContinue = false
                }
            } catch SoftwarePixelBufferPoolError.cancelled {
                #expect(heldFrame != nil)
            }
        }

        #expect(try #require(heldFrame).isHardwareDecoded == false)
        #expect(heldFrame?.pipelineCapacityPermit != nil)
        #expect(gate.snapshot.inUse == 1)
        heldFrame = nil
        #expect(gate.snapshot.inUse == 0)
    }

    @Test func hardwareOutputDoesNotConsumeSoftwareCapacity() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("h264-aac.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: true,
            softwareOutputMode: .bgra
        )
        guard decoder.hardwareWasConfigured else { return }

        let gate = VideoFrameCapacityGate(capacity: 1)
        var reservationCalls = 0
        var hardwareFrame: NativeDecodedVideoFrame?
        while hardwareFrame == nil,
              let packet = try demuxer.readPacket(generation: 43)
        {
            guard packet.streamIndex == stream.index else { continue }
            try decoder.decode(
                packet,
                while: { true },
                reserveSoftwareOutput: {
                    reservationCalls += 1
                    return gate.acquire(while: { true })
                }
            ) { frame in
                if frame.isHardwareDecoded { hardwareFrame = frame }
            }
        }

        let frame = try #require(hardwareFrame)
        #expect(frame.pipelineCapacityPermit == nil)
        #expect(reservationCalls == 0)
        #expect(gate.snapshot.inUse == 0)
    }

    @Test func fullRangeAnamorphicMetadataAndOutputAreExact() throws {
        let url = experimentFixtures.appendingPathComponent("full-range-anamorphic.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let comparison = try compareRoutes(
            url: url,
            rendererAttributes: rendererAttributes(presenter),
            frameCount: 3
        )
        #expect(comparison.planarFormat
            == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(comparison.maximumByteDelta == 0)
        #expect(comparison.differingBytes == 0)
        #expect(comparison.metadataAndTimingMatch)
        #expect(comparison.pixelAspectHorizontal == 4)
        #expect(comparison.pixelAspectVertical == 3)
        #expect(comparison.chromaLocation
            == kCVImageBufferChromaLocation_Center as String)
    }

    @Test func rotationMetadataDoesNotChangePlanarBytesOrTiming() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("rotated-90.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let comparison = try compareRoutes(
            url: url,
            rendererAttributes: rendererAttributes(presenter),
            frameCount: 3
        )
        #expect(comparison.maximumByteDelta == 0)
        #expect(comparison.differingBytes == 0)
        #expect(comparison.metadataAndTimingMatch)
    }

    @Test func midstreamResolutionChangeRecreatesThePlanarPool() throws {
        let url = experimentFixtures.appendingPathComponent("resolution-transition.ts")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            softwareOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presenter)
            )
        )
        var observedSizes: Set<String> = []
        var packets = 0
        while observedSizes.count < 2, packets < 1_000,
              let packet = try demuxer.readPacket(generation: 1)
        {
            packets += 1
            guard packet.streamIndex == stream.index else { continue }
            for frame in try decoder.decode(packet) {
                observedSizes.insert("\(Int(frame.codedSize.width))x\(Int(frame.codedSize.height))")
            }
        }
        #expect(observedSizes.contains("640x360"))
        #expect(observedSizes.contains("960x540"))
        #expect(decoder.planarExperimentDiagnostics?.uniqueBuffers ?? 0 > 0)
    }

    @Test func seekFlushRecreatesPoolAndRejectsOldGenerationAtBoundary() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            softwareOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presenter)
            )
        )
        let old = try decodeFrames(
            demuxer: demuxer,
            decoder: decoder,
            streamIndex: stream.index,
            generation: 1,
            count: 1
        )
        #expect(old.first?.generation == 1)
        #expect(decoder.planarExperimentDiagnostics != nil)
        try demuxer.seek(to: 0, exact: false)
        decoder.flush()
        #expect(decoder.planarExperimentDiagnostics == nil)
        let fresh = try decodeFrames(
            demuxer: demuxer,
            decoder: decoder,
            streamIndex: stream.index,
            generation: 2,
            count: 1
        )
        #expect(fresh.first?.generation == 2)
        #expect(old.first?.generation != fresh.first?.generation)
    }

    @Test @MainActor func appleRendererAcceptsNV12AndP010Samples() throws {
        guard let fixtures else { return }
        let cases = [
            (fixtures.appendingPathComponent("av1-video-only.mkv"), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (fixtures.appendingPathComponent("hdr10-pq-p010.mkv"), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            (experimentFixtures.appendingPathComponent("av1-10bit-full-range.mkv"), kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
        ]
        for (url, expectedFormat) in cases {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let presenter = SampleBufferVideoPresenter()
            let window = makeRendererWindow(presenter: presenter)
            defer { retireRendererWindow(window) }
            let frame = try firstPlanarFrame(
                url: url,
                rendererAttributes: rendererAttributes(presenter)
            )
            #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == expectedFormat)
            try presenter.enqueue(frame, displayImmediately: true)
            let deadline = Date().addingTimeInterval(1)
            var displayed = presenter.renderer.displayedPixelBuffer()
            while displayed == nil, Date() < deadline,
                  presenter.failureDescription == nil
            {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                displayed = presenter.renderer.displayedPixelBuffer()
            }
            #expect(presenter.renderer.status == .rendering)
            #expect(presenter.failureDescription == nil)
            let displayedOutput = try #require(displayed)
            #expect(CVPixelBufferGetPixelFormatType(displayedOutput) == expectedFormat)
            #expect(CVPixelBufferGetWidth(displayedOutput) == CVPixelBufferGetWidth(frame.pixelBuffer))
            #expect(CVPixelBufferGetHeight(displayedOutput) == CVPixelBufferGetHeight(frame.pixelBuffer))
            #expect(attachments(displayedOutput) == attachments(frame.pixelBuffer))
            // The renderer API proves a pixel buffer reached its displayed
            // output, but this is still not a physical-display photometry test.
        }
    }

    @Test @MainActor
    func rendererFlushTeardownAndReplacementDisplayFreshPlanarOutput() throws {
        guard let fixtures else { return }
        let firstURL = fixtures.appendingPathComponent("av1-video-only.mkv")
        let replacementURL = fixtures.appendingPathComponent("hdr10-pq-p010.mkv")
        guard FileManager.default.fileExists(atPath: firstURL.path),
              FileManager.default.fileExists(atPath: replacementURL.path)
        else { return }

        let presenter = SampleBufferVideoPresenter()
        let window = makeRendererWindow(presenter: presenter)
        let attributes = rendererAttributes(presenter)
        let first = try firstPlanarFrame(url: firstURL, rendererAttributes: attributes)
        try presenter.enqueue(first, displayImmediately: true)
        let displayedFirst = try #require(waitForDisplayed(presenter))
        #expect(CVPixelBufferGetPixelFormatType(displayedFirst)
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let flush = LockedFlag()
        presenter.flush(removeDisplayedImage: true) { flush.set() }
        let flushDeadline = Date().addingTimeInterval(1)
        while !flush.value, Date() < flushDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(flush.value)
        // `displayedPixelBuffer()` may continue returning the last copied
        // image after a remove-image flush completes. Do not infer renderer
        // queue state or stale resubmission from that retained snapshot.
        retireRendererWindow(window)

        // File replacement in production installs a new renderer generation;
        // mirror that lifecycle instead of reusing a flushed renderer.
        let replacementPresenter = SampleBufferVideoPresenter()
        let replacementWindow = makeRendererWindow(presenter: replacementPresenter)
        defer { retireRendererWindow(replacementWindow) }
        let replacement = try firstPlanarFrame(
            url: replacementURL,
            rendererAttributes: rendererAttributes(replacementPresenter)
        )
        try replacementPresenter.enqueue(replacement, displayImmediately: true)
        let displayedReplacement = try #require(waitForDisplayed(
            replacementPresenter,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ))
        #expect(CVPixelBufferGetPixelFormatType(displayedReplacement)
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(attachments(displayedReplacement) == attachments(replacement.pixelBuffer))
        #expect(replacementPresenter.failureDescription == nil)
    }

    @Test func softwareRecoveryUsesFreshPlanarPool() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("h264-aac.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: true,
            softwareOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presenter)
            )
        )
        guard decoder.hardwareWasConfigured else { return }
        #expect(try decoder.switchToSoftware())
        #expect(decoder.planarExperimentDiagnostics == nil)
        let recovered = try decodeFrames(
            demuxer: demuxer,
            decoder: decoder,
            streamIndex: stream.index,
            generation: 7,
            count: 1
        )
        let frame = try #require(recovered.first)
        #expect(frame.generation == 7)
        #expect(!frame.isHardwareDecoded)
        #expect(CVPixelBufferIsPlanar(frame.pixelBuffer))
        #expect(decoder.planarExperimentDiagnostics?.uniqueBuffers == 1)
    }

    @Test func planarEOFDrainAndTeardownAreBounded() throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presenter = SampleBufferVideoPresenter()
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            softwareOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presenter)
            )
        )
        var frames = 0
        while let packet = try demuxer.readPacket(generation: 9) {
            guard packet.streamIndex == stream.index else { continue }
            let decoded = try decoder.decode(packet)
            #expect(decoded.count <= 1)
            #expect(decoded.allSatisfy { $0.generation == 9 })
            frames += decoded.count
        }
        let drained = try decoder.drain(generation: 9)
        #expect(drained.allSatisfy { $0.generation == 9 })
        frames += drained.count
        #expect(frames > 0)
        #expect(decoder.planarExperimentDiagnostics?.timeouts == 0)
        #expect(decoder.planarExperimentDiagnostics?.uniqueBuffers ?? 0
            <= SoftwareBGRAOutputPool.qualifiedMaximumBufferCount)
        decoder.flush()
        #expect(decoder.planarExperimentDiagnostics == nil)
    }

    @Test @MainActor
    func mediaSessionPlanarExperimentUsesOutputAcrossRapidSeeks() async throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let session = try MediaSession(
            url: url,
            presentation: presentation,
            subtitles: subtitles,
            preferHardware: false,
            softwareVideoOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presentation.video)
            ),
            videoFrameQueueCapacity: 12,
            reservesVideoPipelineCapacity: true,
            usesFairDemuxDispatch: true
        )
        session.start(rate: 0)
        for index in 0..<100 {
            session.seek(
                // The NV12 fixture is one second long; keep every target
                // inside its decodable range so final-generation output is a
                // meaningful requirement rather than a seek-past-EOF case.
                to: Double(index % 8) / 10,
                exact: index.isMultiple(of: 2),
                resumeRate: 0
            )
            try await Task.sleep(for: .milliseconds(2))
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var snapshot = session.snapshot()
        while (snapshot.pixelBufferFormat != "420v"
                || snapshot.softwarePoolAllocatedBuffers == 0
                || snapshot.softwareOwnershipLastFlush?.activeGeneration != 100
                || snapshot.softwareOwnershipLastFlush?.videoFlushCompleted != true),
              clock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = session.snapshot()
        }
        #expect(snapshot.generation == 100)
        #expect(snapshot.seekCount == 100)
        #expect(snapshot.rendererFailure == nil)
        #expect(snapshot.pixelBufferFormat == "420v")
        #expect(snapshot.softwarePoolAllocatedBuffers > 0)
        #expect(snapshot.softwarePoolTimeouts == 0)
        #expect(snapshot.peakTemporaryDecodedVideoFrames <= 1)
        #expect(snapshot.videoPipelineCapacity == 7)
        #expect(snapshot.peakVideoPipelineCapacityInUse <= 7)
        #expect(snapshot.peakVideoFrameQueueDepth <= 7)
        #expect(snapshot.peakDemuxDeferredPacketDepth <= 8)
        #expect(snapshot.softwareOwnershipLastFlush?.activeGeneration == 100)
        #expect(snapshot.softwareOwnershipLastFlush?.videoFlushCompleted == true)
        session.stop()
        #expect(session.waitForShutdown(timeout: .now() + 3))
    }

    @Test @MainActor
    func mediaSessionP010ReservationUsesOutputAcrossRapidSeeks() async throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("hdr10-pq-p010.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let session = try MediaSession(
            url: url,
            presentation: presentation,
            subtitles: subtitles,
            preferHardware: false,
            softwareVideoOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presentation.video)
            ),
            videoFrameQueueCapacity: 12,
            reservesVideoPipelineCapacity: true,
            usesFairDemuxDispatch: true
        )
        session.start(rate: 0)
        for index in 0..<100 {
            session.seek(
                to: Double(index % 20) / 10,
                exact: index.isMultiple(of: 2),
                resumeRate: 0
            )
            try await Task.sleep(for: .milliseconds(2))
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var snapshot = session.snapshot()
        while (snapshot.pixelBufferFormat != "x420"
                || snapshot.softwarePoolAllocatedBuffers == 0
                || snapshot.softwareOwnershipLastFlush?.activeGeneration != 100
                || snapshot.softwareOwnershipLastFlush?.videoFlushCompleted != true),
              clock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = session.snapshot()
        }
        #expect(snapshot.generation == 100)
        #expect(snapshot.seekCount == 100)
        #expect(snapshot.rendererFailure == nil)
        #expect(snapshot.pixelBufferFormat == "x420")
        #expect(snapshot.softwarePoolAllocatedBuffers > 0)
        #expect(snapshot.softwarePoolTimeouts == 0)
        #expect(snapshot.peakTemporaryDecodedVideoFrames <= 1)
        #expect(snapshot.videoPipelineCapacity == 7)
        #expect(snapshot.peakVideoPipelineCapacityInUse <= 7)
        #expect(snapshot.peakVideoFrameQueueDepth <= 7)
        #expect(snapshot.peakDemuxDeferredPacketDepth <= 8)
        #expect(snapshot.softwareOwnershipLastFlush?.activeGeneration == 100)
        #expect(snapshot.softwareOwnershipLastFlush?.videoFlushCompleted == true)
        session.stop()
        #expect(session.waitForShutdown(timeout: .now() + 3))
    }

    @Test @MainActor
    func activePlanarSeekRecordsPostFlushOldOwnerLifetime() async throws {
        guard let fixtures else { return }
        let url = fixtures.appendingPathComponent("av1-video-only.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presentation = try NativePresentationCoordinator()
        let window = makeRendererWindow(presenter: presentation.video)
        defer { retireRendererWindow(window) }
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let session = try MediaSession(
            url: url,
            presentation: presentation,
            subtitles: subtitles,
            preferHardware: false,
            softwareVideoOutputMode: .planarExperiment(
                rendererAttributes: rendererAttributes(presentation.video)
            )
        )
        session.start(rate: 1)
        let clock = ContinuousClock()
        let ownershipDeadline = clock.now.advanced(by: .seconds(3))
        var beforeSeek = session.snapshot()
        while beforeSeek.softwareOwnershipKnownOutstandingBuffers == 0,
              clock.now < ownershipDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
            beforeSeek = session.snapshot()
        }
        #expect(beforeSeek.softwareOwnershipKnownOutstandingBuffers > 0)

        session.seek(to: 0.5, exact: true, resumeRate: 1)
        let flushDeadline = clock.now.advanced(by: .seconds(3))
        var afterSeek = session.snapshot()
        while afterSeek.softwareOwnershipLastFlush?.videoFlushCompleted != true,
              clock.now < flushDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
            afterSeek = session.snapshot()
        }
        let flush = try #require(afterSeek.softwareOwnershipLastFlush)
        #expect(flush.activeGeneration == 1)
        #expect(flush.oldGenerationKnownBuffersAtRequest > 0)
        #expect(flush.videoFlushCompleted)
        #expect(flush.videoFlushCompletionMilliseconds != nil)

        let releaseDeadline = clock.now.advanced(by: .seconds(3))
        var released = afterSeek
        while released.softwareOwnershipLastFlush?
            .oldGenerationKnownBuffersReachedZeroMilliseconds == nil,
            clock.now < releaseDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
            released = session.snapshot()
        }
        #expect(released.softwareOwnershipLastFlush?
            .oldGenerationKnownBuffersReachedZeroMilliseconds != nil)
        #expect(released.softwareOwnershipOldGenerationKnownBuffers == 0)
        session.stop()
        #expect(session.waitForShutdown(timeout: .now() + 3))
    }

    @Test(
        "Format-changing replacement requires generation-scoped renderer clock advancement",
        arguments: [
            NativeSoftwareVideoOutputPolicy.bgra,
            NativeSoftwareVideoOutputPolicy.planarPreferred,
        ]
    )
    @MainActor
    func formatChangingReplacementAdvancesRendererClock(
        policy: NativeSoftwareVideoOutputPolicy
    ) async throws {
        let eightBit = experimentFixtures.appendingPathComponent("av1-8bit-1080p.mkv")
        let tenBit = experimentFixtures.appendingPathComponent("av1-10bit.mkv")
        guard FileManager.default.fileExists(atPath: eightBit.path),
              FileManager.default.fileExists(atPath: tenBit.path)
        else { return }

        let backend = try NativePlaybackRuntime(
            softwareVideoOutputPolicy: policy,
            reservesVideoPipelineCapacity: true,
            usesFairDemuxDispatch: true
        )
        _ = try backend.makeSurfaceHost()
        for index in 0..<10 {
            let url = index.isMultiple(of: 2) ? eightBit : tenBit
            let source = MediaSource.localFile(url)
            let request = try #require(
                MediaLoadRequest(source: source, origin: .userSelected)
            )
            try backend.load(PlaybackRuntimeLoadRequest(
                media: request,
                identity: PlayerSessionIdentity(
                    source: source,
                    generation: UInt64(index + 1)
                )
            ))
            #expect(await waitForDiagnostic(timeout: .seconds(5), backend: backend) {
                $0.sourcePath == url.path
                    && $0.hasInstalledMediaSession
                    && $0.lifecycleStage == (
                        index == 0
                            ? "media-session-started"
                            : "candidate-preroll-committed-old-session-retired"
                    )
            })
            backend.play()
            #expect(await waitForDiagnostic(timeout: .seconds(5), backend: backend) {
                $0.sourcePath == url.path
                    && $0.rendererClockAdvanced
                    && $0.rendererRate > 0
                    && $0.rendererMediaTimeSeconds
                        >= $0.rendererClockEpochBaselineSeconds + 0.03
                    && $0.failureCode == nil
                    && $0.rendererFailure == nil
            })
        }
        await backend.shutdown()
    }

    @MainActor
    private func waitForDiagnostic(
        timeout: Duration,
        backend: NativePlaybackRuntime,
        predicate: (NativePlaybackDiagnosticSnapshot) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let snapshot = backend.diagnosticSnapshot, predicate(snapshot) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return backend.diagnosticSnapshot.map(predicate) ?? false
    }

    private struct RouteComparison {
        let planarFormat: OSType
        let maximumByteDelta: Int
        let differingBytes: Int
        let metadataAndTimingMatch: Bool
        let hasMasteringDisplayMetadata: Bool
        let hasContentLightMetadata: Bool
        let chromaLocation: String?
        let pixelAspectHorizontal: Int?
        let pixelAspectVertical: Int?
    }

    private func compareRoutes(
        url: URL,
        rendererAttributes: [String: Any],
        frameCount: Int
    ) throws -> RouteComparison {
        let bgra = try decode(url: url, mode: .bgra, frameCount: frameCount)
        let planar = try decode(
            url: url,
            mode: .planarExperiment(rendererAttributes: rendererAttributes),
            frameCount: frameCount
        )
        #expect(bgra.frames.count == frameCount)
        #expect(planar.frames.count == frameCount)

        var maximumByteDelta = 0
        var differingBytes = 0
        var metadataAndTimingMatch = true
        for (reference, candidate) in zip(bgra.frames, planar.frames) {
            #expect(CVBufferCopyAttachment(
                reference.pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil
            ) == nil)
            let referenceBytes = try bgraBytes(reference.pixelBuffer)
            let candidateBytes = try bgraBytes(candidate.pixelBuffer)
            #expect(referenceBytes.count == candidateBytes.count)
            for (lhs, rhs) in zip(referenceBytes, candidateBytes) {
                let delta = abs(Int(lhs) - Int(rhs))
                maximumByteDelta = max(maximumByteDelta, delta)
                if delta != 0 { differingBytes += 1 }
            }
            metadataAndTimingMatch = metadataAndTimingMatch
                && reference.presentationTime == candidate.presentationTime
                && reference.duration == candidate.duration
                && reference.codedSize == candidate.codedSize
                && reference.displaySize == candidate.displaySize
                && reference.pixelAspectRatio == candidate.pixelAspectRatio
                && reference.rotationDegrees == candidate.rotationDegrees
                && reference.colorPrimaries == candidate.colorPrimaries
                && reference.transferCharacteristic == candidate.transferCharacteristic
                && reference.matrixCoefficients == candidate.matrixCoefficients
                && reference.isFullRange == candidate.isFullRange
                && reference.hasMasteringDisplayMetadata
                    == candidate.hasMasteringDisplayMetadata
                && reference.hasContentLightMetadata
                    == candidate.hasContentLightMetadata
        }
        let first = try #require(planar.frames.first)
        let chroma = CVBufferCopyAttachment(
            first.pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            nil
        ) as? String
        let pixelAspect = CVBufferCopyAttachment(
            first.pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            nil
        ) as? [CFString: Any]
        let formatName = String(
            format: "0x%08x",
            CVPixelBufferGetPixelFormatType(first.pixelBuffer)
        )
        print(
            "PLANAR_ROUTE_RESULT fixture=\(url.lastPathComponent) "
                + "format=\(formatName) "
                + "max_byte_delta=\(maximumByteDelta) differing_bytes=\(differingBytes) "
                + "metadata_timing_match=\(metadataAndTimingMatch)"
        )
        return RouteComparison(
            planarFormat: CVPixelBufferGetPixelFormatType(first.pixelBuffer),
            maximumByteDelta: maximumByteDelta,
            differingBytes: differingBytes,
            metadataAndTimingMatch: metadataAndTimingMatch,
            hasMasteringDisplayMetadata: first.hasMasteringDisplayMetadata,
            hasContentLightMetadata: first.hasContentLightMetadata,
            chromaLocation: chroma,
            pixelAspectHorizontal: pixelAspect?[
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
            ] as? Int,
            pixelAspectVertical: pixelAspect?[
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
            ] as? Int
        )
    }

    private func decode(
        url: URL,
        mode: SoftwareVideoOutputMode,
        frameCount: Int
    ) throws -> (decoder: VideoDecoder, frames: [NativeDecodedVideoFrame]) {
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: mode
        )
        let frames = try decodeFrames(
            demuxer: demuxer,
            decoder: decoder,
            streamIndex: stream.index,
            generation: 1,
            count: frameCount
        )
        return (decoder, frames)
    }

    private func firstPlanarFrame(
        url: URL,
        rendererAttributes: [String: Any]
    ) throws -> NativeDecodedVideoFrame {
        try #require(decode(
            url: url,
            mode: .planarExperiment(rendererAttributes: rendererAttributes),
            frameCount: 1
        ).frames.first)
    }

    private func decodeFrames(
        demuxer: FFmpegDemuxer,
        decoder: VideoDecoder,
        streamIndex: Int32,
        generation: Int,
        count: Int
    ) throws -> [NativeDecodedVideoFrame] {
        var frames: [NativeDecodedVideoFrame] = []
        var packets = 0
        while frames.count < count, packets < 4_000,
              let packet = try demuxer.readPacket(generation: generation)
        {
            packets += 1
            guard packet.streamIndex == streamIndex else { continue }
            frames += try decoder.decode(packet)
        }
        return Array(frames.prefix(count))
    }

    private func rendererAttributes(
        _ presenter: SampleBufferVideoPresenter
    ) -> [String: Any] {
        presenter.renderer.recommendedPixelBufferAttributes.rawAttributes.reduce(into: [:]) {
            $0[$1.key] = $1.value
        }
    }

    private func attachments(_ pixelBuffer: CVPixelBuffer) -> [String: String] {
        let keys = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferPixelAspectRatioKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey,
        ]
        return keys.reduce(into: [:]) { result, key in
            if let value = CVBufferCopyAttachment(pixelBuffer, key, nil) {
                result[key as String] = String(describing: value)
            }
        }
    }

    @MainActor
    private func waitForDisplayed(
        _ presenter: SampleBufferVideoPresenter,
        pixelFormat: OSType? = nil,
        timeout: TimeInterval = 1
    ) -> CVPixelBuffer? {
        let deadline = Date().addingTimeInterval(timeout)
        var displayed = presenter.renderer.displayedPixelBuffer()
        while (displayed == nil || pixelFormat.map {
            displayed.map(CVPixelBufferGetPixelFormatType) != $0
        } == true), Date() < deadline,
              presenter.failureDescription == nil
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            displayed = presenter.renderer.displayedPixelBuffer()
        }
        return displayed
    }

    @MainActor
    private func makeRendererWindow(
        presenter: SampleBufferVideoPresenter
    ) -> NSWindow {
        let frame = NSRect(x: 20, y: 20, width: 640, height: 360)
        let view = NSView(frame: frame)
        view.wantsLayer = true
        presenter.displayLayer.frame = view.bounds
        view.layer?.addSublayer(presenter.displayLayer)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    @MainActor
    private func retireRendererWindow(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        window.contentView = nil
        window.close()
        CATransaction.flush()
    }

    private func bgraBytes(_ pixelBuffer: CVPixelBuffer) throws -> [UInt8] {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bgra: CVPixelBuffer
        var converted: CVPixelBuffer?
        var conversionContext: UnsafeMutablePointer<SwsContext>?
        defer { superplayr_free_sws_context(conversionContext) }
        if format == kCVPixelFormatType_32BGRA {
            bgra = pixelBuffer
        } else {
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &converted
            )
            guard status == kCVReturnSuccess, let converted else {
                throw SoftwarePixelBufferPoolError.creation(status)
            }
            try checkFFmpeg(
                superplayr_copy_biplanar_pixel_buffer_to_bgra(
                    pixelBuffer,
                    converted,
                    &conversionContext
                ),
                operation: "Canonicalize planar experiment frame"
            )
            bgra = converted
        }

        let lock = CVPixelBufferLockBaseAddress(bgra, .readOnly)
        guard lock == kCVReturnSuccess else {
            throw SoftwarePixelBufferPoolError.allocation(lock)
        }
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(bgra))
        let stride = CVPixelBufferGetBytesPerRow(bgra)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            bytes.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.advanced(by: row * width * 4).update(
                    from: base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self),
                    count: width * 4
                )
            }
        }
        return bytes
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
