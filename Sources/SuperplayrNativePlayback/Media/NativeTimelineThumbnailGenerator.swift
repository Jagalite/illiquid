import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import OSLog

/// Produces timeline previews from an independent FFmpeg decode path so hover
/// never seeks, pauses, or otherwise mutates the active playback session.
public actor NativeTimelineThumbnailGenerator {
    private static let logger = Logger(subsystem: "com.superplayr.thumbnail", category: "decode")
    private final class ImageRenderer: @unchecked Sendable {
        // CIContext is expensive to construct and supports concurrent rendering.
        private let context = CIContext(options: [.cacheIntermediates: false])

        func makeImage(
            from image: CIImage,
            colorSpace: CGColorSpace?
        ) -> CGImage? {
            context.createCGImage(
                image,
                from: image.extent.integral,
                format: .BGRA8,
                colorSpace: colorSpace
            )
        }
    }

    private struct CacheKey: Hashable {
        let url: URL
        let halfSecond: Int
        let maximumWidth: Int
        let maximumHeight: Int
    }

    private static let maximumCachedImages = 48
    private static let imageRenderer = ImageRenderer()

    private var cache: [CacheKey: CGImage] = [:]
    private var cacheOrder: [CacheKey] = []

    // The decode context is confined to the worker's serial queue.
    private final class DecoderStorage: @unchecked Sendable {
        let observe: (@Sendable (ThumbnailDecodeObservation) -> Void)?
        let optimized: Bool
        let maximumPackets: Int
        init(optimized: Bool = true, maximumPackets: Int = 1_500,
             observe: (@Sendable (ThumbnailDecodeObservation) -> Void)?) {
            self.optimized = optimized
            self.maximumPackets = max(1, min(maximumPackets, 1_500))
            self.observe = observe
        }
        var context: DecodeContext?
        var nextToken: UInt64 = 0
        var cacheRevision: UInt64?
        func decode(_ input: TimelineThumbnailWorker.Input,
                    cancellation: FFmpegInputCancellationSignal) -> CGImage? {
            let started = ProcessInfo.processInfo.systemUptime
            var observation = ThumbnailDecodeObservation(target: input.seconds)
            defer {
                observation.totalMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                observation.cancelled = cancellation.cancellationRequested
                NativeTimelineThumbnailGenerator.logger.info("Thumbnail \(observation.summary, privacy: .public)")
                observe?(observation)
            }
            if cacheRevision != input.cacheRevision {
                context = nil
                cacheRevision = input.cacheRevision
            }
            nextToken &+= 1
            do {
                let image = try NativeTimelineThumbnailGenerator.decodeThumbnail(
                    from: input.url, at: input.seconds, maximumPixelSize: input.size,
                    cancellation: cancellation, context: &context,
                    token: FFmpegInputEffectToken(rawValue: nextToken), optimized: optimized,
                    maximumPackets: maximumPackets,
                    observation: &observation
                )
                observation.imageCreated = image != nil
                return image
            } catch {
                observation.failure = (error as? FFmpegError).map { "\($0.operation):\($0.code)" }
                    ?? String(describing: type(of: error))
                context = nil
                if !cancellation.cancellationRequested {
                    if let error = error as? FFmpegError {
                        NativeTimelineThumbnailGenerator.logger.error("Thumbnail \(error.operation, privacy: .public) failed with FFmpeg code \(error.code)")
                    } else {
                        NativeTimelineThumbnailGenerator.logger.error("Thumbnail decode failed: \(String(describing: error), privacy: .private)")
                    }
                }
                return nil
            }
        }
    }

    private final class DecodeContext {
        let url: URL
        let interrupt: FFmpegInterruptState
        let demuxer: FFmpegDemuxer
        let stream: FFmpegStreamInfo
        let decoder: VideoDecoder
        var lastDecodedSeconds: Double?
        var reachedEOF = false
        var forwardContinuationIsSafe = true
        init(url: URL, interrupt: FFmpegInterruptState) throws {
            self.url = url
            self.interrupt = interrupt
            let opened = try FFmpegDemuxer(url: url, interruptState: interrupt)
            demuxer = opened
            guard let stream = opened.mediaInfo.videoStreams.first(where: {
                $0.index == opened.mediaInfo.selectedVideoIndex
            }), let parameters = opened.codecParameters(streamIndex: stream.index)
            else { throw CocoaError(.fileReadCorruptFile) }
            self.stream = stream
            decoder = try VideoDecoder(
                parameters: parameters, stream: stream, preferHardware: false,
                timelineOriginSeconds: demuxer.mediaInfo.startTime,
                softwareOutputMode: .bgra, softwareDecoderThreadCount: 2,
                softwarePlanarOutputMaximumBufferCount: 2
            )
        }
    }

    private let worker: TimelineThumbnailWorker
    private var cacheRevision: UInt64 = 0
    private var latestSourceRevision: UInt64?

    public init() {
        let storage = DecoderStorage(observe: nil)
        worker = TimelineThumbnailWorker { input, cancellation in
            storage.decode(input, cancellation: cancellation)
        }
    }

    init(optimized: Bool = true, maximumPackets: Int = 1_500,
         observe: @escaping @Sendable (ThumbnailDecodeObservation) -> Void) {
        let storage = DecoderStorage(optimized: optimized, maximumPackets: maximumPackets, observe: observe)
        worker = TimelineThumbnailWorker { input, cancellation in
            storage.decode(input, cancellation: cancellation)
        }
    }

    public func thumbnail(
        for url: URL,
        at seconds: TimeInterval,
        maximumPixelSize: CGSize,
        delayBeforeDecoding: Duration = .zero,
        sourceRevision: UInt64? = nil
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let sourceRevision {
            invalidate(for: sourceRevision)
            guard latestSourceRevision == sourceRevision else { return nil }
        }
        let revision = cacheRevision
        guard let key = Self.cacheKey(
            for: url,
            at: seconds,
            maximumPixelSize: maximumPixelSize
        ) else { return nil }
        if let cached = cachedImage(for: key) { return cached }

        if delayBeforeDecoding > .zero {
            do {
                try await Task.sleep(for: delayBeforeDecoding)
            } catch {
                return nil
            }
            guard !Task.isCancelled, revision == cacheRevision else { return nil }
            if let cached = cachedImage(for: key) { return cached }
        }

        let image = await worker.image(for: .init(
            url: key.url, seconds: Double(key.halfSecond) / 2,
            size: maximumPixelSize, cacheRevision: revision
        ))
        guard !Task.isCancelled, revision == cacheRevision, let image else { return nil }

        cache[key] = image
        touch(key)
        while cacheOrder.count > Self.maximumCachedImages {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return image
    }

    /// A source owner can invalidate synchronously in its own state and send
    /// this message asynchronously. Late messages cannot retire a newer source.
    public func invalidate(for sourceRevision: UInt64) {
        guard latestSourceRevision.map({ sourceRevision > $0 }) ?? true else { return }
        latestSourceRevision = sourceRevision
        removeAllCachedThumbnails()
    }

    public func removeAllCachedThumbnails() {
        cacheRevision &+= 1
        worker.cancelAll()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    private func touch(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func cachedImage(for key: CacheKey) -> CGImage? {
        guard let cached = cache[key] else { return nil }
        touch(key)
        return cached
    }

    private nonisolated static func cacheKey(
        for url: URL,
        at seconds: TimeInterval,
        maximumPixelSize: CGSize
    ) -> CacheKey? {
        guard url.isFileURL,
              seconds.isFinite,
              seconds >= 0,
              maximumPixelSize.width > 0,
              maximumPixelSize.height > 0,
              let halfSecond = Int(exactly: (seconds * 2).rounded()),
              let maximumWidth = Int(exactly: maximumPixelSize.width.rounded()),
              let maximumHeight = Int(exactly: maximumPixelSize.height.rounded()),
              maximumWidth > 0, maximumHeight > 0
        else { return nil }
        return CacheKey(
            url: url.standardizedFileURL,
            halfSecond: halfSecond,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight
        )
    }

    private nonisolated static func decodeThumbnail(
        from url: URL,
        at target: TimeInterval,
        maximumPixelSize: CGSize,
        cancellation: FFmpegInputCancellationSignal,
        context: inout DecodeContext?,
        token: FFmpegInputEffectToken,
        optimized: Bool,
        maximumPackets: Int,
        observation: inout ThumbnailDecodeObservation
    ) throws -> CGImage? {
        let interrupt = context?.url == url ? context!.interrupt : FFmpegInterruptState()
        interrupt.begin(token)
        let registration = cancellation.register { _ = interrupt.cancel(token) }
        defer {
            cancellation.unregister(registration)
            interrupt.end(token)
            if cancellation.cancellationRequested { context = nil }
        }
        try cancellation.checkCancellation()
        let openStarted = ProcessInfo.processInfo.systemUptime
        observation.reusedContext = context?.url == url
        do {
            defer { observation.openMilliseconds = (ProcessInfo.processInfo.systemUptime - openStarted) * 1_000 }
            if context?.url != url {
                context = try DecodeContext(url: url, interrupt: interrupt)
            }
        }
        try cancellation.checkCancellation()
        guard let current = context else { return nil }
        let demuxer = current.demuxer
        let decoder = current.decoder
        let stream = current.stream
        let seekStarted = ProcessInfo.processInfo.systemUptime
        // Keep codec references and demux position for nearby forward hovers.
        // No frame history or compressed-packet cache is added. Backward jumps,
        // EOF, cancellation and source invalidation always take the seek path.
        let continuesForward = optimized && current.forwardContinuationIsSafe && !current.reachedEOF &&
            current.lastDecodedSeconds.map { target > $0 && target - $0 <= 2 } == true
        observation.continuedForward = continuesForward
        do {
            defer { observation.seekMilliseconds = (ProcessInfo.processInfo.systemUptime - seekStarted) * 1_000 }
            if !continuesForward {
                decoder.flush()
                current.lastDecodedSeconds = nil
                current.reachedEOF = false
                try demuxer.seek(to: target + demuxer.mediaInfo.startTime, exact: false)
            }
        }
        decoder.retainsSeekPrerollFallback = optimized
        decoder.seekOutputFloor = optimized ? (1, target) : nil
        let discardedAtStart = decoder.discardedSeekPrerollFrames

        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            observation.discardedBeforeOutput = decoder.discardedSeekPrerollFrames - discardedAtStart
            observation.decodeMilliseconds = max(0,
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000 - observation.imageMilliseconds)
        }
        var nearestFrame: NativeDecodedVideoFrame?
        var packetCount = 0
        var reachedTarget = false
        func receive(_ frame: NativeDecodedVideoFrame) {
            observation.frames += 1
            current.lastDecodedSeconds = frame.presentationTime.seconds
            if frame.usesDeinterlacingFilter || frame.beginsTimelineDiscontinuity {
                // Filter history after random access need not match a fresh
                // keyframe seek. Keep those sources on the established path.
                current.forwardContinuationIsSafe = false
            }
            guard !reachedTarget else { return }
            nearestFrame = frame
            reachedTarget = frame.presentationTime.seconds + 0.001 >= target
        }
        while packetCount < maximumPackets,
              ProcessInfo.processInfo.systemUptime - startedAt < 1.5,
              !cancellation.cancellationRequested
        {
            guard let packet = try demuxer.readPacket(generation: 1) else {
                current.reachedEOF = true
                // Frame threading and reordered codecs may retain the only
                // frame of a short clip until EOF. Keep draining bounded by
                // the same deadline and hold only the nearest output frame.
                try decoder.drain(generation: 1, while: {
                    !cancellation.cancellationRequested &&
                        ProcessInfo.processInfo.systemUptime - startedAt < 1.5
                }, emit: receive)
                break
            }
            packetCount += 1
            observation.packets = packetCount
            guard packet.streamIndex == stream.index else { continue }
            try decoder.decode(
                packet,
                while: { !cancellation.cancellationRequested },
                emit: receive
            )
            if reachedTarget { break }
        }

        observation.decodeMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        // A budget limit is not EOF. Do not cache an arbitrary earlier image
        // under a target we never reached merely because the timer ran late.
        guard reachedTarget || current.reachedEOF else {
            if let progress = decoder.seekPrerollFallbackProgress {
                current.lastDecodedSeconds = progress.seconds
                if progress.filtered || progress.discontinuity {
                    current.forwardContinuationIsSafe = false
                }
            }
            observation.failure = "decode-budget-exhausted"
            return nil
        }
        if nearestFrame == nil, current.reachedEOF, optimized {
            nearestFrame = try decoder.takeSeekPrerollFallback(generation: 1,
                while: { !cancellation.cancellationRequested })
            if nearestFrame != nil {
                observation.frames += 1
                observation.usedEOFFallback = true
            }
        }
        guard !cancellation.cancellationRequested, let nearestFrame else { return nil }
        observation.selectedFrameSeconds = nearestFrame.presentationTime.seconds
        let imageStarted = ProcessInfo.processInfo.systemUptime
        defer { observation.imageMilliseconds = (ProcessInfo.processInfo.systemUptime - imageStarted) * 1_000 }
        return makeImage(
            nearestFrame,
            isHorizontallyMirrored: stream.isMirrored,
            maximumPixelSize: maximumPixelSize
        )
    }

    private nonisolated static func makeImage(
        _ frame: NativeDecodedVideoFrame,
        isHorizontallyMirrored: Bool,
        maximumPixelSize: CGSize
    ) -> CGImage? {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)

        if let aperture = frame.cleanAperture,
           aperture.width > 0,
           aperture.height > 0
        {
            let ciCrop = CGRect(
                x: aperture.minX,
                y: image.extent.height - aperture.maxY,
                width: aperture.width,
                height: aperture.height
            ).intersection(image.extent)
            if !ciCrop.isEmpty {
                image = image.cropped(to: ciCrop)
                    .transformed(by: CGAffineTransform(
                        translationX: -ciCrop.minX,
                        y: -ciCrop.minY
                    ))
            }
        }

        let pixelAspect = frame.pixelAspectRatio
        if pixelAspect.width > 0,
           pixelAspect.height > 0,
           abs(pixelAspect.width - pixelAspect.height) > 0.001
        {
            image = image.transformed(by: CGAffineTransform(
                scaleX: pixelAspect.width / pixelAspect.height,
                y: 1
            ))
        }

        let radians = CGFloat(frame.rotationDegrees * .pi / 180)
        if abs(radians) > 0.001 || isHorizontallyMirrored {
            var transform = CGAffineTransform(rotationAngle: radians)
            if isHorizontallyMirrored {
                transform = transform.scaledBy(x: -1, y: 1)
            }
            image = image.transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            ))
        }

        let scale = min(
            maximumPixelSize.width / max(image.extent.width, 1),
            maximumPixelSize.height / max(image.extent.height, 1),
            1
        )
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return imageRenderer.makeImage(from: image, colorSpace: colorSpace)
    }
}
