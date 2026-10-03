import CoreMedia
import Foundation
import SuperplayrCore

struct SubtitlePresentationDelivery: Equatable, Sendable {
    let contentRevision: UInt64
    let requiresPresentation: Bool
}

struct SubtitlePresentationLedger: Equatable, Sendable {
    private(set) var latestContentRevision: UInt64 = 0
    private(set) var latestPresentedRevision: UInt64 = 0

    mutating func observe(renderedContentChanged: Bool) -> SubtitlePresentationDelivery {
        if renderedContentChanged {
            precondition(
                latestContentRevision < UInt64.max,
                "subtitle content revision exhausted"
            )
            latestContentRevision += 1
        }
        return SubtitlePresentationDelivery(
            contentRevision: latestContentRevision,
            requiresPresentation: latestContentRevision != latestPresentedRevision
        )
    }

    mutating func markPresented(contentRevision: UInt64) {
        latestPresentedRevision = max(latestPresentedRevision, contentRevision)
    }

    mutating func reset() {
        latestContentRevision = 0
        latestPresentedRevision = 0
    }
}

/// libass is not thread-safe. Every mutable pipeline field and every context
/// call is serialized by `lock`; the unchecked conformance is limited to that
/// explicitly enforced synchronization boundary.
final class SubtitlePipeline: @unchecked Sendable {
    private struct ProcessedPacketKey: Hashable {
        let presentationMilliseconds: Int64
        let durationMilliseconds: Int64
        let data: Data
    }

    struct PictureInPictureSubtitleSnapshot: Sendable {
        let regions: [ASSRenderedRegion]
        let changed: Bool
    }

    struct RenderCounters: Equatable, Sendable {
        var requests = 0
        var duplicateTimestampRequests = 0
        var requestsSupersededBeforeLibass = 0
        var libassFrames = 0
        var libassChangedFrames = 0
        var libassUnchangedFrames = 0
        var libassConfigurationRequests = 0
        var libassGeometryChanges = 0
        var libassRenderNanoseconds: UInt64 = 0
        var libassCopyNanoseconds: UInt64 = 0
        var resourceLimitRejections = 0
        var bitmapCopies = 0
        var assImages = 0
        var maskBytes = 0
        var resultsSupersededAfterLibass = 0
        var resultsSupersededBeforeUpload = 0
        var overlayCommits = 0
        var mainThreadSubtitleOperations = 0
        var mainThreadPresentationNanoseconds: UInt64 = 0
        var metalCopiedBytes = 0
        var metalUploadBytes = 0
        var metalTextureUploads = 0
        var metalDrawCalls = 0
        var metalCoalescedFrames = 0
        var metalPackingNanoseconds: UInt64 = 0
        var atlasReallocations = 0
        var atlasClearBytes = 0
        var maximumAtlasWidth = 0
        var maximumAtlasHeight = 0
        var quads = 0
        var metalFramesSubmitted = 0
        var metalClearsSubmitted = 0
        var metalFailures = 0
    }

    private struct RenderedFrame {
        let regions: [ASSRenderedRegion]
        let changed: Bool
        let libassChange: Int32
    }

    private struct MetalRenderRequest: Sendable {
        let sequence: UInt64
        let revision: SubtitleFenceRevision
        let time: CMTime
        let viewport: CGRect
        let videoSize: CGSize
        let canvasSize: CGSize
    }

    let overlay: SubtitleOverlayView
    private var context: LibassContext
    private let lock = NSLock()
    private let revisionFence = SubtitleRevisionFence()
    private let metalRenderQueue = DispatchQueue(
        label: "com.superplayr.native.subtitle-metal",
        qos: .userInteractive
    )
    private let compositionStrategy: SubtitleCompositionStrategy
    private let framePacker: ASSSubtitleFramePacker
    private let memoryBudget: SubtitleMemoryBudget?
    private let memoryOwner: SubtitleMemoryOwner
    private let libassMemoryLease: SubtitleMemoryBudget.Lease?
    private let presentsOverlay: Bool
    private let deduplicatesPackets: Bool
    private var pendingMetalRequest: MetalRenderRequest?
    private var metalWorkerActive = false
    private var latestMetalSequence: UInt64 = 0
    private var lastRenderedMilliseconds: Int64?
    private var lastRenderedViewport: CGRect?
    private var lastRenderedVideoSize: CGSize?
    private var lastOverlayMilliseconds: Int64?
    private var lastOverlayViewport: CGRect?
    private var lastOverlayVideoSize: CGSize?
    private var lastRegions: [ASSRenderedRegion] = []
    private var bitmapSource = false
    private var forcedBitmapEventsOnly = false
    private var bitmapTimeline = BitmapSubtitleTimeline()
    private var lastBitmapStart: Double?
    private var lastBitmapRevision: UInt64?
    var sharedMemoryBudget: SubtitleMemoryBudget? { memoryBudget }
    var forcesBitmapEventsOnly: Bool {
        get { lock.withLock { forcedBitmapEventsOnly } }
        set {
            lock.withLock {
                guard forcedBitmapEventsOnly != newValue else { return }
                forcedBitmapEventsOnly = newValue
                resetRenderCachesLocked()
            }
        }
    }
    private var presentationLedger = SubtitlePresentationLedger()
    private var renderCounters = RenderCounters()
    private var diagnosticMediaIdentity: String?
    private var lastCompositorDiagnostics: SubtitleCompositorDiagnostics
    private let profileDiagnosticsEnabled: Bool
    private var storedEventCount = 0
    private var lastEventPruneTime: Double = 0
    private var hasExternalEvents = false
    private var processedPacketKeys: Set<ProcessedPacketKey> = []
    private var storedDelay: Double = 0
    private var enabled = true
    private var presentationAuthorityEnabled = true

    var eventCount: Int {
        lock.withLock { storedEventCount }
    }

    var delay: Double {
        get { lock.withLock { storedDelay } }
        set {
            lock.withLock {
                storedDelay = newValue.isFinite ? newValue : 0
            }
        }
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            let changed = lock.withLock {
                guard enabled != newValue else { return false }
                enabled = newValue
                return true
            }
            guard changed else { return }
            if !newValue {
                clear()
            }
            guard presentsOverlay else { return }
            let hidden = !newValue
            DispatchQueue.main.async { [weak overlay] in
                overlay?.isHidden = hidden
            }
        }
    }

    @MainActor
    init(
        overlay: SubtitleOverlayView,
        presentsOverlay: Bool = true,
        deduplicatesPackets: Bool = false,
        memoryBudget: SubtitleMemoryBudget? = nil,
        memoryOwner: SubtitleMemoryOwner = .mainLibass
    ) throws {
        self.overlay = overlay
        self.presentsOverlay = presentsOverlay
        self.deduplicatesPackets = deduplicatesPackets
        self.memoryBudget = memoryBudget
        self.memoryOwner = memoryOwner
        if presentsOverlay,
           let failure = overlay.requiredMetalInitializationFailure
        {
            throw PresentationError(
                "Required Metal ASS compositor failed: \(failure.rawValue)"
            )
        }
        compositionStrategy = overlay.compositionStrategy
        let cacheMegabytes: Int32 = memoryOwner == .pictureInPictureLibass ? 16 : 32
        let cacheBytes = Int(cacheMegabytes) * 1_024 * 1_024
        let libassMemoryLease = memoryBudget?.acquire(
            owner: memoryOwner,
            bytes: cacheBytes
        )
        guard memoryBudget == nil || libassMemoryLease != nil else {
            throw PresentationError("Aggregate subtitle memory budget is exhausted")
        }
        self.libassMemoryLease = libassMemoryLease
        framePacker = ASSSubtitleFramePacker(
            maximumTextureDimension: overlay.metalMaximumTextureDimension,
            memoryBudget: memoryBudget,
            memoryOwner: memoryOwner == .pictureInPictureLibass
                ? .pictureInPictureStaging
                : .mainStaging
        )
        context = try LibassContext(bitmapCacheMegabytes: cacheMegabytes)
        lastCompositorDiagnostics = overlay.diagnosticsSnapshot()
        profileDiagnosticsEnabled = ProcessInfo.processInfo.environment[
            "SUPERPLAYR_ASS_PROFILE"
        ] == "1"
    }

    func configure(
        codecPrivate: Data?,
        codecName: String?,
        attachments: [FontAttachment],
        frameSize: CGSize,
        storageSize: CGSize
    ) throws -> [String] {
        if let codecPrivate,
           codecPrivate.count > Limits.codecPrivateBytes
        {
            throw PresentationError("Subtitle codec private data exceeds the bounded byte limit")
        }
        let eligible = try Self.validatedAttachments(attachments)
        let replacementContext = try LibassContext(
            bitmapCacheMegabytes: memoryOwner == .pictureInPictureLibass ? 16 : 32
        )
        guard replacementContext.configure(
            frameSize: frameSize,
            storageSize: storageSize
        ) else {
            throw PresentationError("Subtitle geometry exceeds the bounded renderer limits")
        }
        let replacementIsTextSubtitle = ["subrip", "srt", "text", "webvtt"].contains(
            codecName?.lowercased() ?? ""
        )
        let registered = eligible.filter {
            replacementContext.register($0)
        }.map(\.filename)
        if replacementIsTextSubtitle {
            replacementContext.processCodecPrivate(Data(Self.defaultASSHeader.utf8))
        } else if let codecPrivate {
            replacementContext.processCodecPrivate(codecPrivate)
        }

        let revision = revisionFence.beginInvalidation()
        let shouldPresentClear = lock.withLock {
            // libass retains font bytes in ASS_Library. Replacing the whole
            // source-owned context releases those bytes deterministically.
            context = replacementContext
            hasExternalEvents = false
            bitmapSource = NativeSubtitleCapability.classify(codecName: codecName ?? "") == .bitmap
            bitmapTimeline.reset(generation: 0)
            resetCachedStateLocked(resetCounters: true)
            return presentationAuthorityEnabled
        }
        framePacker.retireSource()
        _ = revisionFence.acknowledgeSourceInvalidation(revision)
        if shouldPresentClear {
            scheduleVisibleClear(revision: revision)
        }
        if profileDiagnosticsEnabled {
            // A subtitles-off benchmark never submits a subtitle frame, so it
            // has no periodic profile line. Emit the reset state once to let
            // the harness prove zero render, image, and presentation work.
            emitProfileSummary(
                counters: counters(),
                compositor: lock.withLock { lastCompositorDiagnostics }
            )
        }
        return registered
    }

    @discardableResult
    func process(
        event: NativeDecodedSubtitleEvent,
        timelineOriginSeconds: Double = 0
    ) -> Bool {
        if let composition = event.bitmapComposition {
            return lock.withLock {
                guard enabled, bitmapSource else { return true }
                guard event.generation == bitmapTimeline.generation else { return true }
                let accepted = bitmapTimeline.insert(composition, at: event.presentationSeconds - timelineOriginSeconds,
                                                     generation: event.generation)
                if accepted {
                    storedEventCount += 1
                    resetRenderCachesLocked()
                } else {
                    renderCounters.resourceLimitRejections += 1
                }
                return accepted
            }
        }
        processEventData(
            event.assData,
            start: event.presentationSeconds - timelineOriginSeconds,
            duration: event.durationSeconds
        )
        return true
    }

    private func processEventData(
        _ packetData: Data,
        start: Double,
        duration: Double
    ) {
        guard start.isFinite,
              duration.isFinite,
              packetData.count <= Limits.packetBytes
        else { return }
        lock.withLock {
            guard enabled else { return }
            let data = packetData
            if deduplicatesPackets {
                guard abs(start) <= Double(Int64.max) / 1_000,
                      duration <= Double(Int64.max) / 1_000
                else { return }
                let key = ProcessedPacketKey(
                    presentationMilliseconds: Int64((start * 1_000).rounded()),
                    durationMilliseconds: Int64((duration * 1_000).rounded()),
                    // FFmpeg assigns a monotonically increasing ReadOrder as
                    // the first ASS field. It can change when the same cue is
                    // decoded again during a seek, so it is not part of the
                    // semantic identity used by the dual-pipeline deduper.
                    data: data.firstIndex(of: UInt8(ascii: ",")).map {
                        Data(data[data.index(after: $0)...])
                    } ?? data
                )
                guard processedPacketKeys.insert(key).inserted else { return }
            }
            context.processChunk(data, start: start, duration: duration)
            storedEventCount += 1
            // Demuxing and rendering run independently. A seek can render the
            // paused target before its subtitle packet arrives, caching an
            // empty result for that timestamp. Invalidate both caches whenever
            // libass receives a new event so the next tick recomputes even if
            // the presentation clock has not advanced.
            resetRenderCachesLocked()
        }
    }

    func pruneEmbeddedEvents(before seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.withLock {
            guard !hasExternalEvents else { return }
            if bitmapSource {
                bitmapTimeline.prune(before: seconds)
                return
            }
            if seconds < lastEventPruneTime { lastEventPruneTime = seconds }
            guard seconds - lastEventPruneTime >= 5 else { return }
            lastEventPruneTime = seconds
            context.pruneEvents(before: seconds)
            let deadline = seconds * 1_000
            processedPacketKeys = processedPacketKeys.filter {
                Double($0.presentationMilliseconds) + Double($0.durationMilliseconds) >= deadline
            }
        }
    }

    func loadExternal(url: URL) throws {
        try installExternal(data: Self.prepareExternalData(url: url))
    }

    static func prepareExternalData(
        url: URL, fallbackEncoding: SubtitleFallbackEncoding = .unicodeOnly
    ) throws -> Data {
        try prepareExternalData(
            url: url,
            maximumBytes: Limits.externalSubtitleBytes,
            fallbackEncoding: fallbackEncoding
        )
    }

    static func prepareExternalData(
        url: URL,
        maximumBytes: Int,
        fallbackEncoding: SubtitleFallbackEncoding = .unicodeOnly
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw PresentationError("External subtitle byte limit is invalid")
        }
        let data = try readBoundedFile(
            url: url,
            maximumBytes: maximumBytes
        )
        let subtitleData: Data
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "srt" || fileExtension == "vtt" {
            let decoded = fileExtension == "srt"
                ? Self.decodeSRTText(data, fallbackEncoding: fallbackEncoding)
                : String(data: data, encoding: .utf8)
            guard let source = decoded else {
                throw PresentationError(fileExtension == "srt"
                    ? "SRT encoding is unsupported or invalid. Save it as UTF-8 or Unicode with a byte-order mark."
                    : "External VTT is not valid UTF-8")
            }
            let converted = try (fileExtension == "srt"
                ? Self.convertSRTToASS(source)
                : Self.convertWebVTTToASS(source))
            guard converted.utf8.count <= maximumBytes else {
                throw PresentationError(
                    "Converted external subtitle exceeds the bounded byte limit"
                )
            }
            subtitleData = Data(converted.utf8)
        } else {
            subtitleData = data
        }
        return subtitleData
    }

    /// SRT has no mandatory encoding. Honor explicit Unicode byte-order marks
    /// without guessing a legacy code page that could silently corrupt text.
    /// WebVTT remains UTF-8 as required by its format contract.
    private static func decodeSRTText(_ data: Data, fallbackEncoding: SubtitleFallbackEncoding) -> String? {
        let marks: [([UInt8], String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
        ]
        for (mark, encoding) in marks where data.starts(with: mark) {
            return String(data: data.dropFirst(mark.count), encoding: encoding)
        }
        return String(data: data, encoding: .utf8)
            ?? fallbackEncoding.stringEncoding.flatMap { String(data: data, encoding: $0) }
    }

    func installExternal(data subtitleData: Data) throws {
        guard subtitleData.count <= Limits.externalSubtitleBytes else {
            throw PresentationError("External subtitle exceeds the bounded byte limit")
        }
        let (revision, shouldPresentClear) = try lock.withLock {
            try context.loadExternal(data: subtitleData)
            hasExternalEvents = true
            bitmapSource = false
            bitmapTimeline.reset()
            let revision = revisionFence.beginInvalidation()
            resetCachedStateLocked(resetCounters: true)
            return (revision, presentationAuthorityEnabled)
        }
        framePacker.retireSource()
        _ = revisionFence.acknowledgeSourceInvalidation(revision)
        if shouldPresentClear {
            scheduleVisibleClear(revision: revision)
        }
    }

    @MainActor
    func render(at time: CMTime, viewport: CGRect, videoSize: CGSize) {
        let canPresent = lock.withLock {
            enabled && presentationAuthorityEnabled
        }
        guard canPresent else { return }
        guard time.isNumeric else {
            clear()
            return
        }
        if profileDiagnosticsEnabled {
            let snapshot = overlay.diagnosticsSnapshot()
            lock.withLock { lastCompositorDiagnostics = snapshot }
        }
        scheduleMetalRender(
            at: time,
            viewport: viewport,
            videoSize: videoSize,
            canvasSize: overlay.metalBackingPixelSize,
            backingScale: overlay.metalBackingScale
        )
    }

    /// Exposure/resize can restore a drawable while media time remains paused.
    /// Reuse cached regions but allow a fresh presentation, without polling.
    func invalidatePresentationRequest() {
        lock.withLock {
            lastOverlayMilliseconds = nil
            _ = presentationLedger.observe(renderedContentChanged: true)
        }
    }

    func renderedRegions(
        at time: CMTime,
        viewport: CGRect,
        videoSize: CGSize
    ) -> [ASSRenderedRegion] {
        renderedFrame(at: time, viewport: viewport, videoSize: videoSize).regions
    }

    func pictureInPictureSubtitleSnapshot(
        at time: CMTime,
        viewport: CGRect,
        videoSize: CGSize
    ) -> PictureInPictureSubtitleSnapshot {
        let frame = renderedFrame(
            at: time,
            viewport: viewport,
            videoSize: videoSize
        )
        return PictureInPictureSubtitleSnapshot(
            regions: frame.regions,
            changed: frame.changed
        )
    }

    private func renderedFrame(
        at time: CMTime,
        viewport: CGRect,
        videoSize: CGSize
    ) -> RenderedFrame {
        guard time.isNumeric else {
            return RenderedFrame(regions: [], changed: true, libassChange: 2)
        }
        lock.lock()
        guard enabled, presentationAuthorityEnabled else {
            lock.unlock()
            return RenderedFrame(regions: [], changed: true, libassChange: 2)
        }
        let seconds = max(0, time.seconds + storedDelay)
        guard seconds.isFinite,
              seconds <= Double(Int64.max) / 1_000
        else {
            lock.unlock()
            return RenderedFrame(regions: [], changed: true, libassChange: 2)
        }
        let milliseconds = Int64((seconds * 1_000).rounded())
        if lastRenderedMilliseconds == milliseconds,
           lastRenderedViewport == viewport,
           lastRenderedVideoSize == videoSize
        {
            let cached = lastRegions
            lock.unlock()
            return RenderedFrame(regions: cached, changed: false, libassChange: 0)
        }
        let geometryChanged = lastRenderedViewport != viewport
            || lastRenderedVideoSize != videoSize
        let hasPriorRegions = lastRenderedMilliseconds != nil
        lastRenderedMilliseconds = milliseconds
        lastRenderedViewport = viewport
        lastRenderedVideoSize = videoSize
        if bitmapSource {
            let entry = bitmapTimeline.composition(at: seconds)
            let changed = !hasPriorRegions || geometryChanged || lastBitmapStart != entry?.start
                || lastBitmapRevision != bitmapTimeline.revision
            if changed { lastRegions = entry?.value.renderedRegions(in: viewport, forcedOnly: forcedBitmapEventsOnly) ?? [] }
            lastBitmapStart = entry?.start
            lastBitmapRevision = bitmapTimeline.revision
            let regions = lastRegions
            lock.unlock()
            return RenderedFrame(regions: regions, changed: changed, libassChange: changed ? 2 : 0)
        }
        renderCounters.libassConfigurationRequests += 1
        if context.configure(frameSize: viewport.size, storageSize: videoSize) {
            renderCounters.libassGeometryChanges += 1
        }
        renderCounters.libassFrames += 1
        let result = context.render(
            at: seconds,
            copyIfUnchanged: !hasPriorRegions || geometryChanged,
            maximumImageCount: Limits.renderedRegionCount,
            maximumBitmapBytes: Limits.renderedPixelBytes
        )
        if result.resourceLimitExceeded {
            renderCounters.resourceLimitRejections += 1
        }
        if result.change != 0 {
            renderCounters.libassChangedFrames += 1
        } else {
            renderCounters.libassUnchangedFrames += 1
        }
        renderCounters.libassRenderNanoseconds &+= result.renderNanoseconds
        renderCounters.libassCopyNanoseconds &+= result.copyNanoseconds
        renderCounters.bitmapCopies += result.bitmapCopies
        renderCounters.assImages += result.imageCount
        renderCounters.maskBytes += result.maskBytes
        if profileDiagnosticsEnabled, renderCounters.libassFrames % 24 == 0 {
            // Static subtitles can render unchanged for the entire run and
            // therefore never reach the changed-frame presentation cadence.
            // Profile the render cadence independently of presentation.
            emitProfileSummary(
                counters: renderCounters,
                compositor: lastCompositorDiagnostics
            )
        }
        guard let renderedRegions = result.regions else {
            let cached = lastRegions
            lock.unlock()
            return RenderedFrame(
                regions: cached,
                changed: false,
                libassChange: result.change
            )
        }
        let regions = renderedRegions.map {
            $0.offsetBy(dx: viewport.minX, dy: viewport.minY)
        }
        lastRegions = regions
        lock.unlock()
        return RenderedFrame(
            regions: regions,
            changed: true,
            libassChange: result.change
        )
    }

    private func scheduleMetalRender(
        at time: CMTime,
        viewport: CGRect,
        videoSize: CGSize,
        canvasSize: CGSize,
        backingScale: CGFloat
    ) {
        let revision = revisionFence.current
        let scale = max(backingScale, 1)
        let scaledViewport = CGRect(
            x: viewport.minX * scale,
            y: viewport.minY * scale,
            width: viewport.width * scale,
            height: viewport.height * scale
        )
        lock.lock()
        guard enabled, presentationAuthorityEnabled else {
            lock.unlock()
            return
        }
        let seconds = time.seconds + storedDelay
        guard seconds.isFinite,
              seconds >= Double(Int64.min) / 1_000,
              seconds <= Double(Int64.max) / 1_000,
              scaledViewport.minX.isFinite,
              scaledViewport.minY.isFinite,
              scaledViewport.width.isFinite,
              scaledViewport.height.isFinite
        else {
            lock.unlock()
            return
        }
        let milliseconds = Int64((seconds * 1_000).rounded())
        renderCounters.requests += 1
        if lastOverlayMilliseconds == milliseconds,
           lastOverlayViewport == scaledViewport,
           lastOverlayVideoSize == videoSize
        {
            renderCounters.duplicateTimestampRequests += 1
            lock.unlock()
            return
        }
        lastOverlayMilliseconds = milliseconds
        lastOverlayViewport = scaledViewport
        lastOverlayVideoSize = videoSize
        precondition(latestMetalSequence < UInt64.max, "subtitle frame sequence exhausted")
        latestMetalSequence += 1
        if pendingMetalRequest != nil {
            renderCounters.metalCoalescedFrames += 1
            renderCounters.requestsSupersededBeforeLibass += 1
        }
        pendingMetalRequest = MetalRenderRequest(
            sequence: latestMetalSequence,
            revision: revision,
            time: time,
            viewport: scaledViewport,
            // libass storage size describes the source video, not the
            // backing-pixel subtitle target. Only the frame/viewport scales.
            videoSize: videoSize,
            canvasSize: canvasSize
        )
        let shouldStart = !metalWorkerActive
        metalWorkerActive = true
        lock.unlock()
        if shouldStart {
            metalRenderQueue.async { [weak self] in
                self?.consumeMetalRequest()
            }
        }
    }

    private func consumeMetalRequest() {
        let request: MetalRenderRequest? = lock.withLock {
            let request = pendingMetalRequest
            pendingMetalRequest = nil
            if request == nil { metalWorkerActive = false }
            return request
        }
        guard let request else { return }
        let frame = renderedFrame(
            at: request.time,
            viewport: request.viewport,
            videoSize: request.videoSize
        )
        let delivery = lock.withLock {
            presentationLedger.observe(renderedContentChanged: frame.changed)
        }
        let supersededAfterLibass = lock.withLock {
            request.sequence != latestMetalSequence
                || !presentationAuthorityEnabled
        }
        if supersededAfterLibass {
            lock.withLock {
                renderCounters.resultsSupersededAfterLibass += 1
            }
            metalRenderQueue.async { [weak self] in
                self?.consumeMetalRequest()
            }
            return
        }
        guard delivery.requiresPresentation else {
            metalRenderQueue.async { [weak self] in self?.consumeMetalRequest() }
            return
        }
        let packingStart = DispatchTime.now().uptimeNanoseconds
        let prepared = framePacker.prepare(
            regions: frame.regions,
            canvasSize: request.canvasSize,
            strategy: compositionStrategy
        )
        let packingNanoseconds = DispatchTime.now().uptimeNanoseconds - packingStart
        if let metrics = prepared?.metrics {
            lock.withLock {
                renderCounters.metalPackingNanoseconds &+= packingNanoseconds
                renderCounters.metalCopiedBytes += metrics.copiedBytes
                renderCounters.metalUploadBytes += metrics.uploadBytes
                if metrics.uploadBytes > 0 {
                    renderCounters.metalTextureUploads += 1
                }
                renderCounters.metalDrawCalls += metrics.drawCalls
                renderCounters.atlasReallocations += metrics.atlasReallocated ? 1 : 0
                renderCounters.atlasClearBytes += metrics.atlasClearBytes
                renderCounters.maximumAtlasWidth = max(
                    renderCounters.maximumAtlasWidth,
                    metrics.atlasWidth
                )
                renderCounters.maximumAtlasHeight = max(
                    renderCounters.maximumAtlasHeight,
                    metrics.atlasHeight
                )
                renderCounters.quads += metrics.imageCount
            }
        }
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self else { return }
            let presentationStart = DispatchTime.now().uptimeNanoseconds
            let canCommit = self.lock.withLock {
                request.sequence == self.latestMetalSequence
                    && self.presentationAuthorityEnabled
                    && self.enabled
            }
            if canCommit,
               self.revisionFence.commitOverlay(request.revision)
            {
                self.recordOverlayCommit()
                if let prepared {
                    let outcome = overlay?.present(
                        prepared,
                        revision: request.revision,
                        mediaIdentity: self.lock.withLock {
                            self.diagnosticMediaIdentity
                        }
                    ) ?? .metalFailure(.unsupportedConfiguration)
                    switch outcome {
                    case .presentedMetal:
                        self.lock.withLock {
                            self.renderCounters.metalFramesSubmitted += 1
                            self.presentationLedger.markPresented(
                                contentRevision: delivery.contentRevision
                            )
                        }
                    case .metalFailure:
                        self.lock.withLock {
                            self.renderCounters.metalFailures += 1
                        }
                    }
                    if let snapshot = overlay?.diagnosticsSnapshot() {
                        self.lock.withLock {
                            self.lastCompositorDiagnostics = snapshot
                        }
                    }
                } else {
                    let outcome = overlay?.recordFailure(
                        .stagingAllocation,
                        revision: request.revision,
                        mediaIdentity: self.lock.withLock {
                            self.diagnosticMediaIdentity
                        }
                    )
                    if case .metalFailure = outcome {
                        self.lock.withLock {
                            self.renderCounters.metalFailures += 1
                        }
                    }
                    if let snapshot = overlay?.diagnosticsSnapshot() {
                        self.lock.withLock {
                            self.lastCompositorDiagnostics = snapshot
                        }
                    }
                }
            } else if !canCommit {
                self.lock.withLock {
                    self.renderCounters.metalCoalescedFrames += 1
                    self.renderCounters.resultsSupersededBeforeUpload += 1
                }
            }
            self.lock.withLock {
                self.renderCounters.mainThreadSubtitleOperations += 1
                self.renderCounters.mainThreadPresentationNanoseconds &+=
                    DispatchTime.now().uptimeNanoseconds - presentationStart
            }
            self.metalRenderQueue.async { [weak self] in
                self?.consumeMetalRequest()
            }
        }
    }

    func counters() -> RenderCounters {
        lock.withLock { renderCounters }
    }

    func configuredLibassGeometry() -> (frame: CGSize?, storage: CGSize?) {
        lock.withLock { context.configuredGeometry }
    }

    func libassContextIdentityForTesting() -> ObjectIdentifier {
        lock.withLock { ObjectIdentifier(context) }
    }

    func setDiagnosticMediaIdentity(_ identity: String?) {
        lock.withLock { diagnosticMediaIdentity = identity }
    }

    /// Candidate sessions may prepare a private libass context before they own
    /// the shared overlay. Only the authoritative pipeline can render, clear,
    /// or commit visible output.
    @MainActor
    func setPresentationAuthorityEnabled(_ enabled: Bool) {
        let changed = lock.withLock {
            presentationAuthorityEnabled != enabled
        }
        guard changed else { return }
        let revision = revisionFence.beginInvalidation()
        lock.withLock {
            presentationAuthorityEnabled = enabled
            resetRenderCachesLocked()
            presentationLedger.reset()
            latestMetalSequence &+= 1
            pendingMetalRequest = nil
        }
        _ = revisionFence.acknowledgeSourceInvalidation(revision)
        if enabled {
            scheduleVisibleClear(revision: revision)
        }
    }

    var hasPresentationAuthorityForTesting: Bool {
        lock.withLock { presentationAuthorityEnabled }
    }

    private func recordOverlayCommit() {
        lock.withLock { renderCounters.overlayCommits += 1 }
    }

    private static func validatedAttachments(
        _ attachments: [FontAttachment]
    ) throws -> [FontAttachment] {
        try FontAttachmentValidator.validated(attachments)
    }

    private enum Limits {
        static let codecPrivateBytes = 4 * 1_024 * 1_024
        static let packetBytes = 16 * 1_024 * 1_024
        static let externalSubtitleBytes = 32 * 1_024 * 1_024
        static let renderedRegionCount = 256
        static let renderedPixelBytes = 64 * 1_024 * 1_024
    }

    func clear(generation: Int? = nil) {
        let revision = revisionFence.beginInvalidation()
        let shouldPresentClear = lock.withLock {
            if bitmapSource { bitmapTimeline.reset(generation: generation) }
            resetRenderCachesLocked()
            presentationLedger.reset()
            latestMetalSequence &+= 1
            pendingMetalRequest = nil
            return presentationAuthorityEnabled
        }
        _ = revisionFence.acknowledgeSourceInvalidation(revision)
        if shouldPresentClear {
            scheduleVisibleClear(revision: revision)
        }
    }

    func terminate() {
        let counters = counters()
        let compositor = lock.withLock { lastCompositorDiagnostics }
        FileHandle.standardError.write(Data(
            (
                "[ass-compositor-summary] selected=\(compositor.selectedCompositor.rawValue) "
                    + "metal-frames=\(counters.metalFramesSubmitted) "
                    + "metal-clears=\(compositor.metalClearsSubmitted) "
                    + "failure-count=\(compositor.failureCount) "
                    + "last-failure=\(compositor.lastFailureReason?.rawValue ?? "none") "
                    + "drawable-failures=\(compositor.drawableAcquisitionFailures) "
                    + "command-buffer-failures=\(compositor.commandBufferFailures)\n"
            ).utf8
        ))
        emitProfileSummary(counters: counters, compositor: compositor)
        lock.withLock {
            presentationAuthorityEnabled = false
            bitmapTimeline.reset()
            lastRegions = []
            latestMetalSequence &+= 1
            pendingMetalRequest = nil
        }
        framePacker.retireSource()
        revisionFence.terminate()
    }

    func fenceSnapshotForTesting() -> SubtitleFenceSnapshot {
        revisionFence.snapshot()
    }

    private func scheduleVisibleClear(revision: SubtitleFenceRevision) {
        guard lock.withLock({ presentationAuthorityEnabled }) else { return }
        guard presentsOverlay else {
            _ = revisionFence.commitVisibleClear(revision)
            return
        }
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self,
                  self.lock.withLock({ self.presentationAuthorityEnabled }),
                  self.revisionFence.commitVisibleClear(revision)
            else { return }
            let before = overlay?.diagnosticsSnapshot().metalClearsSubmitted ?? 0
            overlay?.clear(
                revision: revision,
                mediaIdentity: self.lock.withLock { self.diagnosticMediaIdentity }
            )
            let after = overlay?.diagnosticsSnapshot().metalClearsSubmitted ?? before
            if let snapshot = overlay?.diagnosticsSnapshot() {
                self.lock.withLock {
                    self.lastCompositorDiagnostics = snapshot
                }
            }
            if after > before {
                self.lock.withLock {
                    self.renderCounters.metalClearsSubmitted += after - before
                }
            }
        }
    }

    private func resetCachedStateLocked(resetCounters: Bool) {
        storedEventCount = 0
        lastEventPruneTime = 0
        processedPacketKeys = []
        resetRenderCachesLocked()
        presentationLedger.reset()
        latestMetalSequence &+= 1
        pendingMetalRequest = nil
        if resetCounters {
            renderCounters = RenderCounters()
        }
    }

    private func resetRenderCachesLocked() {
        lastBitmapStart = nil
        lastBitmapRevision = nil
        lastRenderedMilliseconds = nil
        lastRenderedViewport = nil
        lastRenderedVideoSize = nil
        lastOverlayMilliseconds = nil
        lastOverlayViewport = nil
        lastOverlayVideoSize = nil
        lastRegions = []
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private func emitProfileSummary(compositor: SubtitleCompositorDiagnostics) {
        emitProfileSummary(counters: counters(), compositor: compositor)
    }

    private func emitProfileSummary(
        counters: RenderCounters,
        compositor: SubtitleCompositorDiagnostics
    ) {
        FileHandle.standardError.write(Data(
            (
                "[ass-profile-summary] epoch=\(String(format: "%.6f", Date().timeIntervalSince1970)) "
                    + "selected=\(compositor.selectedCompositor.rawValue) "
                    + "failure-count=\(compositor.failureCount) "
                    + "requests=\(counters.requests) "
                    + "duplicate-requests=\(counters.duplicateTimestampRequests) "
                    + "superseded-before-libass=\(counters.requestsSupersededBeforeLibass) "
                    + "libass-calls=\(counters.libassFrames) "
                    + "libass-changed=\(counters.libassChangedFrames) "
                    + "libass-unchanged=\(counters.libassUnchangedFrames) "
                    + "libass-config-requests=\(counters.libassConfigurationRequests) "
                    + "libass-geometry-changes=\(counters.libassGeometryChanges) "
                    + "libass-render-ms=\(Self.milliseconds(counters.libassRenderNanoseconds)) "
                    + "libass-copy-ms=\(Self.milliseconds(counters.libassCopyNanoseconds)) "
                    + "resource-limit-rejections=\(counters.resourceLimitRejections) "
                    + "superseded-after-libass=\(counters.resultsSupersededAfterLibass) "
                    + "superseded-before-upload=\(counters.resultsSupersededBeforeUpload) "
                    + "images=\(counters.assImages) mask-bytes=\(counters.maskBytes) "
                    + "packing-ms=\(Self.milliseconds(counters.metalPackingNanoseconds)) "
                    + "atlas-reallocations=\(counters.atlasReallocations) "
                    + "atlas-clear-bytes=\(counters.atlasClearBytes) "
                    + "atlas-max=\(counters.maximumAtlasWidth)x\(counters.maximumAtlasHeight) "
                    + "uploads=\(counters.metalTextureUploads) "
                    + "upload-bytes=\(counters.metalUploadBytes) "
                    + "quads=\(counters.quads) "
                    + "metal-frames=\(counters.metalFramesSubmitted) "
                    + "metal-failures=\(counters.metalFailures) "
                    + "drawables=\(compositor.drawableAcquisitionCount) "
                    + "drawable-failures=\(compositor.drawableAcquisitionFailures) "
                    + "command-buffers=\(compositor.commandBuffersSubmitted) "
                    + "command-buffer-failures=\(compositor.commandBufferFailures) "
                    + "texture-allocation-failures=\(compositor.textureAllocationFailures) "
                    + "buffer-allocation-failures=\(compositor.bufferAllocationFailures) "
                    + "main-ops=\(counters.mainThreadSubtitleOperations) "
                    + "main-ms=\(Self.milliseconds(counters.mainThreadPresentationNanoseconds))\n"
            ).utf8
        ))
    }

    private static func readBoundedFile(
        url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
        ])
        guard values.isRegularFile != false else {
            throw PresentationError("External subtitle is not a regular file")
        }
        if let fileSize = values.fileSize,
           fileSize > maximumBytes
        {
            throw PresentationError("External subtitle exceeds the bounded byte limit")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var output = Data()
        if let fileSize = values.fileSize, fileSize > 0 {
            output.reserveCapacity(min(fileSize, maximumBytes))
        }
        while true {
            let remaining = maximumBytes - output.count
            let requestBytes = min(64 * 1_024, remaining + 1)
            guard let chunk = try handle.read(upToCount: requestBytes),
                  !chunk.isEmpty
            else { break }
            guard chunk.count <= remaining else {
                throw PresentationError("External subtitle exceeds the bounded byte limit")
            }
            output.append(chunk)
        }
        return output
    }

    private static let defaultASSHeader = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
    Style: Default,sans-serif,52,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,48,48,40,1

    [Events]
    Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    """

    private static func convertSRTToASS(_ source: String) throws -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var events: [String] = []
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard !lines.isEmpty else { continue }
            if Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil {
                lines.removeFirst()
            }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = parseSRTTimestamp(timing[0]),
                  let end = parseSRTTimestamp(timing[1]),
                  end > start
            else { continue }
            let text = lines.dropFirst(timingIndex + 1).map { line in
                line.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "{", with: "\\{")
                    .replacingOccurrences(of: "}", with: "\\}")
            }.joined(separator: "\\N")
            events.append(
                "Dialogue: 0,\(assTimestamp(start)),\(assTimestamp(end)),Default,,0,0,0,,\(text)"
            )
        }
        guard !events.isEmpty else {
            throw PresentationError("External SRT contained no valid timed cues")
        }
        return defaultASSHeader + "\n" + events.joined(separator: "\n")
    }

    private static func convertWebVTTToASS(_ source: String) throws -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.split(separator: "\n", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("WEBVTT") == true
        else {
            throw PresentationError("External WebVTT is missing its WEBVTT signature")
        }
        var events: [String] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = parseWebVTTTimestamp(timing[0]),
                  let end = parseWebVTTTimestamp(timing[1]),
                  end > start
            else { continue }
            let text = lines.dropFirst(timingIndex + 1).map { line in
                line.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "{", with: "\\{")
                    .replacingOccurrences(of: "}", with: "\\}")
            }.joined(separator: "\\N")
            events.append(
                "Dialogue: 0,\(assTimestamp(start)),\(assTimestamp(end)),Default,,0,0,0,,\(text)"
            )
        }
        guard !events.isEmpty else {
            throw PresentationError("External WebVTT contained no valid timed cues")
        }
        return defaultASSHeader + "\n" + events.joined(separator: "\n")
    }

    private static func parseWebVTTTimestamp(_ value: String) -> Double? {
        let timestamp = value.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let parts = timestamp.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) ?? 0 : 0
        let minutesIndex = parts.count == 3 ? 1 : 0
        guard let minutes = Double(parts[minutesIndex]),
              let seconds = Double(parts[minutesIndex + 1]),
              minutes < 60,
              seconds < 60
        else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func parseSRTTimestamp(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".", with: ",")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1])
        else { return nil }
        let secondsParts = parts[2].split(separator: ",", omittingEmptySubsequences: false)
        guard let seconds = Double(secondsParts[0]) else { return nil }
        let milliseconds = secondsParts.count > 1
            ? Double(secondsParts[1].prefix(3)) ?? 0
            : 0
        return hours * 3_600 + minutes * 60 + seconds + milliseconds / 1_000
    }

    private static func assTimestamp(_ seconds: Double) -> String {
        let centiseconds = max(Int((seconds * 100).rounded()), 0)
        let hours = centiseconds / 360_000
        let minutes = (centiseconds / 6_000) % 60
        let wholeSeconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, wholeSeconds, fraction)
    }
}
