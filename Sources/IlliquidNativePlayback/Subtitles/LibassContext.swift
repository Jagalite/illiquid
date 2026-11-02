import CLibass
import CoreGraphics
import CryptoKit
import Foundation

struct ASSRenderedRegion: Sendable {
    let bitmap: Data
    let color: UInt32
    let frame: CGRect
    let stride: Int
    let bitmapSize: CGSize?
    let isPremultipliedBGRA: Bool
    let memoryLease: SubtitleMemoryBudget.Lease?

    init(
        bitmap: Data,
        color: UInt32,
        frame: CGRect,
        stride: Int,
        bitmapSize: CGSize? = nil,
        isPremultipliedBGRA: Bool = false,
        memoryLease: SubtitleMemoryBudget.Lease? = nil
    ) {
        self.bitmap = bitmap
        self.color = color
        self.frame = frame
        self.stride = stride
        self.bitmapSize = bitmapSize
        self.isPremultipliedBGRA = isPremultipliedBGRA
        self.memoryLease = memoryLease
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ASSRenderedRegion {
        ASSRenderedRegion(
            bitmap: bitmap,
            color: color,
            frame: frame.offsetBy(dx: dx, dy: dy),
            stride: stride,
            bitmapSize: bitmapSize,
            isPremultipliedBGRA: isPremultipliedBGRA,
            memoryLease: memoryLease
        )
    }
}

/// Identity belongs to the render stream, not the native context's lifetime.
/// A caller-held snapshot must not retain libass or allow a recycled object
/// address to make a snapshot from a destroyed context current again.
fileprivate final class ASSRenderIdentity: Sendable {}

/// Swift-owned masks from one render. The token and admission limits can only
/// be created by this file; callers may translate geometry without replacing
/// the masks associated with that token.
struct ASSReusableRenderSnapshot: Sendable {
    fileprivate let identity: ASSRenderIdentity
    fileprivate let sequence: UInt64
    fileprivate let maximumImageCount: Int
    fileprivate let maximumBitmapBytes: Int
    let regions: [ASSRenderedRegion]

    fileprivate init(
        identity: ASSRenderIdentity,
        sequence: UInt64,
        maximumImageCount: Int,
        maximumBitmapBytes: Int,
        regions: [ASSRenderedRegion]
    ) {
        self.identity = identity
        self.sequence = sequence
        self.maximumImageCount = maximumImageCount
        self.maximumBitmapBytes = maximumBitmapBytes
        self.regions = regions
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        guard dx != 0 || dy != 0 else { return self }
        return Self(
            identity: identity,
            sequence: sequence,
            maximumImageCount: maximumImageCount,
            maximumBitmapBytes: maximumBitmapBytes,
            regions: regions.map { $0.offsetBy(dx: dx, dy: dy) }
        )
    }
}

struct ASSRenderResult: Sendable {
    let regions: [ASSRenderedRegion]?
    let change: Int32
    let bitmapCopies: Int
    let imageCount: Int
    let maskBytes: Int
    let resourceLimitExceeded: Bool
    let renderNanoseconds: UInt64
    let copyNanoseconds: UInt64
    let reusableSnapshot: ASSReusableRenderSnapshot?

    init(
        regions: [ASSRenderedRegion]?,
        change: Int32,
        bitmapCopies: Int,
        imageCount: Int,
        maskBytes: Int,
        resourceLimitExceeded: Bool,
        renderNanoseconds: UInt64,
        copyNanoseconds: UInt64,
        reusableSnapshot: ASSReusableRenderSnapshot? = nil
    ) {
        self.regions = regions
        self.change = change
        self.bitmapCopies = bitmapCopies
        self.imageCount = imageCount
        self.maskBytes = maskBytes
        self.resourceLimitExceeded = resourceLimitExceeded
        self.renderNanoseconds = renderNanoseconds
        self.copyNanoseconds = copyNanoseconds
        self.reusableSnapshot = reusableSnapshot
    }
}

final class LibassContext {
    private struct FontIdentity: Hashable {
        let filename: String
        let byteCount: Int
        let contentDigest: Data
    }

    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private(set) var registeredFonts: [String] = []
    private var registeredFontIdentities: Set<FontIdentity> = []
    private var configuredFrameSize: CGSize?
    private var configuredStorageSize: CGSize?
    // Only token metadata lives here. Masks remain owned by render callers.
    private var renderIdentity = ASSRenderIdentity()
    private var renderSequence: UInt64 = 0

    var configuredGeometry: (frame: CGSize?, storage: CGSize?) {
        (configuredFrameSize, configuredStorageSize)
    }

    init(
        bitmapCacheMegabytes: Int32 = LibassContext.bitmapCacheMegabytes()
    ) throws {
        guard let library = ass_library_init() else {
            throw PresentationError("ass_library_init failed")
        }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            throw PresentationError("ass_renderer_init failed")
        }
        guard let track = ass_new_track(library) else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            throw PresentationError("ass_new_track failed")
        }
        self.library = library
        self.renderer = renderer
        self.track = track
        // Animated ASS can otherwise retain a very large bitmap cache at 4K.
        // Keep the native runtime's cache explicit so memory behavior is measurable.
        ass_set_cache_limits(
            renderer,
            10_000,
            bitmapCacheMegabytes
        )
        ass_set_fonts(
            renderer,
            nil,
            "sans-serif",
            Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue),
            nil,
            1
        )
    }

    static func bitmapCacheMegabytes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        guard environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1",
              let rawValue = environment[
                "ILLIQUID_BENCHMARK_ASS_BITMAP_CACHE_MB"
              ],
              let value = Int32(rawValue),
              (1...128).contains(value)
        else {
            return 32
        }
        return value
    }

    deinit {
        if let track { ass_free_track(track) }
        if let renderer { ass_renderer_done(renderer) }
        if let library { ass_library_done(library) }
    }

    func reset() throws {
        advanceRenderSequence()
        if let track { ass_free_track(track) }
        guard let library, let replacement = ass_new_track(library) else {
            track = nil
            throw PresentationError("ass_new_track failed while resetting subtitles")
        }
        track = replacement
    }

    @discardableResult
    func configure(frameSize: CGSize, storageSize: CGSize) -> Bool {
        guard let renderer,
              let frameWidth = Self.validatedDimension(frameSize.width),
              let frameHeight = Self.validatedDimension(frameSize.height),
              let storageWidth = Self.validatedDimension(storageSize.width),
              let storageHeight = Self.validatedDimension(storageSize.height)
        else { return false }
        guard configuredFrameSize != frameSize || configuredStorageSize != storageSize else {
            return false
        }
        advanceRenderSequence()
        ass_set_frame_size(renderer, frameWidth, frameHeight)
        ass_set_storage_size(renderer, storageWidth, storageHeight)
        configuredFrameSize = frameSize
        configuredStorageSize = storageSize
        if ProcessInfo.processInfo.environment["ILLIQUID_ASS_PROFILE"] == "1" {
            FileHandle.standardError.write(Data(
                (
                    "[ass-profile-geometry] frame="
                        + "\(Int(frameSize.width))x\(Int(frameSize.height)) "
                        + "storage=\(Int(storageSize.width))x\(Int(storageSize.height))\n"
                ).utf8
            ))
        }
        return true
    }

    func register(_ attachment: FontAttachment) -> Bool {
        guard attachment.isSupportedFont, let library else { return false }
        let identity = FontIdentity(
            filename: attachment.filename,
            byteCount: attachment.data.count,
            contentDigest: Data(SHA256.hash(data: attachment.data))
        )
        if registeredFontIdentities.contains(identity) { return true }
        attachment.data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return }
            attachment.filename.withCString { name in
                ass_add_font(library, name, base, Int32(bytes.count))
            }
        }
        registeredFontIdentities.insert(identity)
        registeredFonts.append(attachment.filename)
        return true
    }

    func processCodecPrivate(_ data: Data) {
        guard let track else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return }
            ass_process_codec_private(track, base, Int32(bytes.count))
        }
    }

    func processChunk(_ data: Data, start: Double, duration: Double) {
        guard let track else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return }
            ass_process_chunk(
                track,
                base,
                Int32(bytes.count),
                Int64((start * 1_000).rounded()),
                Int64((duration * 1_000).rounded())
            )
        }
    }

    func pruneEvents(before seconds: Double) {
        guard let track, seconds.isFinite, seconds > 0,
              seconds < Double(Int64.max) / 1_000 else { return }
        ass_prune_events(track, Int64((seconds * 1_000).rounded()))
    }

    func loadExternal(data: Data, codePage: String? = nil) throws {
        guard let library else { return }
        advanceRenderSequence()
        let loaded: UnsafeMutablePointer<ASS_Track>? = data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return nil }
            return ass_read_memory(
                library,
                UnsafeMutablePointer(mutating: base),
                bytes.count,
                codePage
            )
        }
        guard let loaded else {
            throw PresentationError("libass could not parse the subtitle file")
        }
        if let track { ass_free_track(track) }
        track = loaded
    }

    func render(
        at seconds: Double,
        copyIfUnchanged: Bool = true,
        maximumImageCount: Int = 256,
        maximumBitmapBytes: Int = 64 * 1_024 * 1_024,
        reusing previous: ASSReusableRenderSnapshot? = nil
    ) -> ASSRenderResult {
        guard let renderer,
              let track,
              seconds.isFinite,
              seconds >= Double(Int64.min) / 1_000,
              seconds <= Double(Int64.max) / 1_000
        else {
            advanceRenderSequence()
            return ASSRenderResult(
                regions: [],
                change: 0,
                bitmapCopies: 0,
                imageCount: 0,
                maskBytes: 0,
                resourceLimitExceeded: false,
                renderNanoseconds: 0,
                copyNanoseconds: 0
            )
        }
        let boundedImageCount = max(0, maximumImageCount)
        let boundedBitmapBytes = max(0, maximumBitmapBytes)
        let reusablePrevious: ASSReusableRenderSnapshot?
        if let previous,
           previous.identity === renderIdentity,
           previous.sequence == renderSequence,
           previous.maximumImageCount == boundedImageCount,
           previous.maximumBitmapBytes == boundedBitmapBytes {
            reusablePrevious = previous
        } else {
            reusablePrevious = nil
        }
        advanceRenderSequence()
        var changed: Int32 = 0
        let renderStart = DispatchTime.now().uptimeNanoseconds
        var image = ass_render_frame(
            renderer,
            track,
            Int64((seconds * 1_000).rounded()),
            &changed
        )
        let renderNanoseconds = DispatchTime.now().uptimeNanoseconds - renderStart
        // The returned ASS_Image list belongs to libass and remains valid only
        // until its next render. When libass says neither position nor content
        // changed, the pipeline can retain its existing Swift-owned bitmaps
        // instead of copying every row.
        guard changed != 0 || copyIfUnchanged else {
            return ASSRenderResult(
                regions: nil,
                change: changed,
                bitmapCopies: 0,
                imageCount: 0,
                maskBytes: 0,
                resourceLimitExceeded: false,
                renderNanoseconds: renderNanoseconds,
                copyNanoseconds: 0,
                reusableSnapshot: reusablePrevious.map {
                    ASSReusableRenderSnapshot(
                        identity: renderIdentity,
                        sequence: renderSequence,
                        maximumImageCount: boundedImageCount,
                        maximumBitmapBytes: boundedBitmapBytes,
                        regions: $0.regions
                    )
                }
            )
        }
        // libass reports 1 only when positions may have changed; bitmap
        // content, colors, dimensions and list order still match its preceding
        // render. A caller token proves that its owned masks are that output.
        // The full validation pass also checks the admitted subset before any
        // masks can be shared.
        var canReuseMasks = changed == 1 && reusablePrevious != nil
        var inspectedImage = image
        var retainedImageCount = 0
        var retainedMaskBytes = 0
        var resourceLimitExceeded = false
        while let current = inspectedImage {
            let value = current.pointee
            if value.w > 0, value.h > 0, value.bitmap != nil {
                let width = Int(value.w)
                let height = Int(value.h)
                let (nextImageCount, imageCountOverflow) = retainedImageCount
                    .addingReportingOverflow(1)
                guard let layout = ASSBitmapCopyLayout(
                    width: width, height: height, sourceStride: Int(value.stride)
                ),
                      !imageCountOverflow
                else {
                    return ASSRenderResult(
                        regions: [],
                        change: changed,
                        bitmapCopies: 0,
                        imageCount: 0,
                        maskBytes: 0,
                        resourceLimitExceeded: true,
                        renderNanoseconds: renderNanoseconds,
                        copyNanoseconds: 0
                    )
                }
                // Charge only the owned visible pixels. Source padding is not
                // copied, so more regions may fit without increasing this limit.
                let (nextMaskBytes, maskBytesOverflow) = retainedMaskBytes
                    .addingReportingOverflow(layout.byteCount)
                if !maskBytesOverflow,
                   nextImageCount <= boundedImageCount,
                   nextMaskBytes <= boundedBitmapBytes
                {
                    if canReuseMasks, let previous = reusablePrevious {
                        if retainedImageCount < previous.regions.count {
                            let prior = previous.regions[retainedImageCount]
                            canReuseMasks = prior.frame.size == CGSize(width: width, height: height)
                                && prior.color == value.color
                                && prior.stride == width
                                && prior.bitmap.count == layout.byteCount
                        } else {
                            canReuseMasks = false
                        }
                    }
                    retainedImageCount = nextImageCount
                    retainedMaskBytes = nextMaskBytes
                } else {
                    // Validate the complete native list before copying, but
                    // retain a deterministic bounded subset instead of
                    // blanking an otherwise valid complex subtitle frame.
                    resourceLimitExceeded = true
                }
            }
            inspectedImage = value.next
        }
        if let previous = reusablePrevious, retainedImageCount != previous.regions.count {
            canReuseMasks = false
        }
        let copyStart = DispatchTime.now().uptimeNanoseconds
        var output: [ASSRenderedRegion] = []
        output.reserveCapacity(retainedImageCount)
        var bitmapCopies = 0
        var maskBytes = 0
        while let current = image {
            let value = current.pointee
            if value.w > 0, value.h > 0, let bitmap = value.bitmap {
                let width = Int(value.w)
                let height = Int(value.h)
                // The complete list was validated before any copies. Keep the
                // checked layout here as well so pointer arithmetic stays local.
                guard let layout = ASSBitmapCopyLayout(
                    width: width, height: height, sourceStride: Int(value.stride)
                ) else {
                    image = value.next
                    continue
                }
                let (nextMaskBytes, maskBytesOverflow) = maskBytes
                    .addingReportingOverflow(layout.byteCount)
                guard !maskBytesOverflow,
                      output.count < boundedImageCount,
                      nextMaskBytes <= boundedBitmapBytes
                else {
                    image = value.next
                    continue
                }
                let frame = CGRect(
                    x: Int(value.dst_x),
                    y: Int(value.dst_y),
                    width: width,
                    height: height
                )
                // Preserve top-to-bottom row order without retaining padding
                // or reading past libass's potentially unpadded final row.
                let bytes: Data
                if canReuseMasks, let previous = reusablePrevious {
                    bytes = previous.regions[output.count].bitmap
                } else {
                    bytes = layout.copy(from: bitmap)
                    bitmapCopies += 1
                }
                output.append(ASSRenderedRegion(
                    bitmap: bytes,
                    color: value.color,
                    frame: frame,
                    stride: width
                ))
                maskBytes = nextMaskBytes
            }
            image = value.next
        }
        return ASSRenderResult(
            regions: output,
            change: changed,
            bitmapCopies: bitmapCopies,
            imageCount: output.count,
            maskBytes: maskBytes,
            resourceLimitExceeded: resourceLimitExceeded,
            renderNanoseconds: renderNanoseconds,
            copyNanoseconds: DispatchTime.now().uptimeNanoseconds - copyStart,
            reusableSnapshot: ASSReusableRenderSnapshot(
                identity: renderIdentity,
                sequence: renderSequence,
                maximumImageCount: boundedImageCount,
                maximumBitmapBytes: boundedBitmapBytes,
                regions: output
            )
        )
    }

    private func advanceRenderSequence() {
        if renderSequence == UInt64.max {
            // A new identity keeps every outstanding token unambiguous even
            // if this context exhausts its sequence space.
            renderIdentity = ASSRenderIdentity()
            renderSequence = 0
        } else {
            renderSequence += 1
        }
    }

    private static func validatedDimension(_ value: CGFloat) -> Int32? {
        guard value.isFinite,
              value > 0,
              value <= CGFloat(Int32.max)
        else { return nil }
        return Int32(value.rounded(.toNearestOrAwayFromZero))
    }
}
