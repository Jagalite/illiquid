import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Where a presented video frame came from.
///
/// Synthesized frames never exist in the source file. Frame stepping,
/// screenshots and diagnostics use this to tell them apart from decoded
/// pictures.
enum VideoFrameOrigin: Equatable, Sendable {
    /// The decoder's picture, presented unchanged.
    case decoded
    /// A decoded picture after one or more spatial stages rewrote its pixels.
    case processed
    /// A picture generated between two source frames. `phase` is the
    /// position between them in `0..<1`.
    case synthesized(previousSeconds: Double, nextSeconds: Double, phase: Float)

    var isSynthesized: Bool {
        if case .synthesized = self { return true }
        return false
    }
}

/// Geometry and pixel layout that a stage consumes or produces.
struct VideoProcessingFormat: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: OSType
    /// Unrotated visible region inside the buffer, in buffer pixels.
    var cleanAperture: CGRect
    /// Horizontal:vertical pixel aspect. Square pixels are 1:1.
    var pixelAspectRatio: CGSize
    /// Container rotation that the view applies after presentation.
    var rotationDegrees: Double
    var isFullRange: Bool
    var sourceComponentDepth: Int

    /// The size the picture occupies on screen before the view's rotation.
    var unrotatedDisplaySize: CGSize {
        CGSize(
            width: cleanAperture.width * pixelAspectRatio.width
                / max(pixelAspectRatio.height, 1),
            height: cleanAperture.height
        )
    }

    /// The size the picture occupies on screen after the view's rotation.
    var displaySize: CGSize {
        let normalized = abs(rotationDegrees.truncatingRemainder(dividingBy: 180))
        let display = unrotatedDisplaySize
        return abs(normalized - 90) < 1
            ? CGSize(width: display.height, height: display.width)
            : display
    }

    var hasFullAperture: Bool {
        cleanAperture == CGRect(x: 0, y: 0, width: width, height: height)
    }

    var hasSquarePixels: Bool {
        pixelAspectRatio.width == pixelAspectRatio.height
    }
}

enum VideoFrameProcessingStageKind: Sendable {
    /// One frame in, one frame out, no history.
    case spatial
    /// Keeps history across frames and may add or remove frames.
    case temporal
}

/// One picture moving between processing stages.
struct VideoProcessingFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    var presentationTime: CMTime
    var duration: CMTime
    var origin: VideoFrameOrigin
    /// True when the buffer came from a processing pool rather than the
    /// decoder. Stages must not keep decoder buffers beyond the current call,
    /// so the decoder's capacity budget never includes frames a stage holds.
    /// Being pipeline-owned does not make a buffer acceptable to every
    /// processor: VideoToolbox and similar tools need buffers from pools built
    /// with their own attributes.
    var isPipelineOwned: Bool
}

/// A processing step between the decoder and the renderer.
///
/// Stages run on the video presentation thread, one at a time. Metal stages
/// encode into `context.commandBuffer()`; stages that hand buffers to another
/// framework (VideoToolbox, Core ML, external tools) call
/// `context.synchronize()` first so earlier GPU writes are complete.
protocol VideoFrameProcessingStage: AnyObject {
    var name: String { get }
    var kind: VideoFrameProcessingStageKind { get }

    /// Prepares for `input` and returns the format this stage emits. Called
    /// before the first frame and again whenever the input format changes.
    func configure(
        input: VideoProcessingFormat,
        context: VideoFrameProcessingContext
    ) throws -> VideoProcessingFormat

    /// Consumes one frame and emits zero or more frames in presentation order.
    func process(
        _ frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws

    /// Drops any history. Called on seek, flush, generation change and
    /// timeline discontinuity.
    func reset()

    /// Emits any frames still held at end of stream.
    func finish(
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws

    /// True while a model loads in the background; frames pass through.
    var isWarmingUp: Bool { get }
    /// Why the stage cannot do its work, when it falls back permanently.
    var unavailableReason: String? { get }
}

extension VideoFrameProcessingStage {
    var isWarmingUp: Bool { false }
    var unavailableReason: String? { nil }

    func finish(
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {}
}

enum VideoFrameProcessingError: Error, Equatable, CustomStringConvertible {
    case metalUnavailable
    case unsupportedPixelFormat(OSType)
    case textureCreation(CVReturn)
    case bufferAllocation(CVReturn)
    case cancelled
    case commandBufferFailed(String)
    case pipelineState(String)
    case processorUnavailable(String)
    case processorFailed(String)
    case processorTimedOut
    case invalidConfiguration(String)

    var description: String {
        switch self {
        case .metalUnavailable: "Metal is unavailable"
        case let .unsupportedPixelFormat(format):
            "Unsupported pixel format \(VideoProcessingPlaneLayout.fourCC(format))"
        case let .textureCreation(status): "Texture creation failed (\(status))"
        case let .bufferAllocation(status): "Buffer allocation failed (\(status))"
        case .cancelled: "Processing was cancelled"
        case let .commandBufferFailed(message): "GPU command failed: \(message)"
        case let .pipelineState(message): "Pipeline state failed: \(message)"
        case let .processorUnavailable(message): "Processor unavailable: \(message)"
        case let .processorFailed(message): "Processor failed: \(message)"
        case .processorTimedOut: "Processor timed out"
        case let .invalidConfiguration(message): "Invalid configuration: \(message)"
        }
    }
}

/// Plane textures for the pixel formats the pipeline can process.
struct VideoProcessingPlaneLayout: Equatable, Sendable {
    struct Plane: Equatable, Sendable {
        let pixelFormat: MTLPixelFormat
        /// Plane size relative to the luma plane.
        let widthDivisor: Int
        let heightDivisor: Int
    }

    let planes: [Plane]

    static func layout(for pixelFormat: OSType) -> VideoProcessingPlaneLayout? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            VideoProcessingPlaneLayout(planes: [
                Plane(pixelFormat: .r8Unorm, widthDivisor: 1, heightDivisor: 1),
                Plane(pixelFormat: .rg8Unorm, widthDivisor: 2, heightDivisor: 2),
            ])
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            VideoProcessingPlaneLayout(planes: [
                Plane(pixelFormat: .r16Unorm, widthDivisor: 1, heightDivisor: 1),
                Plane(pixelFormat: .rg16Unorm, widthDivisor: 2, heightDivisor: 2),
            ])
        case kCVPixelFormatType_32BGRA:
            VideoProcessingPlaneLayout(planes: [
                Plane(pixelFormat: .bgra8Unorm, widthDivisor: 1, heightDivisor: 1),
            ])
        case kCVPixelFormatType_64RGBAHalf:
            VideoProcessingPlaneLayout(planes: [
                Plane(pixelFormat: .rgba16Float, widthDivisor: 1, heightDivisor: 1),
            ])
        default:
            nil
        }
    }

    /// 4:2:0 layouts need even dimensions.
    var requiresEvenDimensions: Bool {
        planes.contains { $0.widthDivisor > 1 || $0.heightDivisor > 1 }
    }

    static func fourCC(_ format: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> UInt32($0)) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08X", format)
    }
}

/// An IOSurface-backed pixel buffer pool owned by a processing stage.
///
/// Allocation waits rather than failing when the renderer still holds every
/// buffer: the renderer releases buffers as it displays or flushes them, so
/// waiting is the pipeline's backpressure.
final class VideoProcessingBufferPool: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let maximumBufferCount: Int
    private let pool: CVPixelBufferPool
    private let auxiliaryAttributes: CFDictionary

    init(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        maximumBufferCount: Int,
        additionalAttributes: [String: Any] = [:]
    ) throws {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.maximumBufferCount = max(1, maximumBufferCount)
        var attributes = additionalAttributes
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: min(3, self.maximumBufferCount),
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let created else {
            throw VideoFrameProcessingError.bufferAllocation(status)
        }
        pool = created
        auxiliaryAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: self.maximumBufferCount,
        ] as CFDictionary
    }

    /// - Parameter timeout: Gives up after this long. Nil waits for the
    ///   renderer as long as `shouldContinue` allows; use a timeout for pools
    ///   only the pipeline itself drains, where waiting cannot help.
    func makeBuffer(
        while shouldContinue: () -> Bool = { true },
        timeout: TimeInterval? = nil
    ) throws -> CVPixelBuffer {
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var backoff: UInt32 = 1_000
        while true {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxiliaryAttributes,
                &buffer
            )
            if status == kCVReturnSuccess, let buffer { return buffer }
            guard status == kCVReturnWouldExceedAllocationThreshold else {
                throw VideoFrameProcessingError.bufferAllocation(status)
            }
            guard shouldContinue() else { throw VideoFrameProcessingError.cancelled }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                throw VideoFrameProcessingError.bufferAllocation(status)
            }
            usleep(backoff)
            backoff = min(backoff * 2, 20_000)
        }
    }

    func matches(width: Int, height: Int, pixelFormat: OSType) -> Bool {
        self.width == width && self.height == height && self.pixelFormat == pixelFormat
    }

    func flush() {
        CVPixelBufferPoolFlush(pool, [.excessBuffers])
    }
}

/// Shared GPU state for one pipeline: device, queue, texture cache, shader
/// library and the command buffer the current frame's stages encode into.
final class VideoFrameProcessingContext: @unchecked Sendable {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    /// When false, temporal stages pass source frames through instead of
    /// generating new ones. The pipeline clears it when processing falls
    /// behind real time.
    var allowsSynthesis = true
    /// Lets blocking work (buffer waits, external processors) stop when the
    /// session stops.
    var shouldContinue: () -> Bool = { true }

    private let textureCache: CVMetalTextureCache
    private var cachedLibrary: (any MTLLibrary)?
    private var pipelineStates: [String: any MTLComputePipelineState] = [:]
    private var pendingCommandBuffer: (any MTLCommandBuffer)?
    private var retainedUntilCompletion: [AnyObject] = []

    init(device: any MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw VideoFrameProcessingError.metalUnavailable
        }
        queue.label = "Illiquid video frame processing"
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw VideoFrameProcessingError.textureCreation(status)
        }
        self.device = device
        commandQueue = queue
        textureCache = cache
    }

    /// Whether GPU processing can run on this Mac.
    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VideoFrameProcessingError.metalUnavailable
        }
        try self.init(device: device)
    }

    func library() throws -> any MTLLibrary {
        if let cachedLibrary { return cachedLibrary }
        let library = try NativeMetalShaderLibrary.load(device: device)
        cachedLibrary = library
        return library
    }

    func computePipeline(named function: String) throws -> any MTLComputePipelineState {
        if let existing = pipelineStates[function] { return existing }
        guard let kernel = try library().makeFunction(name: function) else {
            throw VideoFrameProcessingError.pipelineState("Missing kernel \(function)")
        }
        let state = try device.makeComputePipelineState(function: kernel)
        pipelineStates[function] = state
        return state
    }

    /// The command buffer for the frame being processed. Created on demand
    /// and committed by `synchronize()`.
    func commandBuffer() throws -> any MTLCommandBuffer {
        if let pendingCommandBuffer { return pendingCommandBuffer }
        guard let buffer = commandQueue.makeCommandBuffer() else {
            throw VideoFrameProcessingError.commandBufferFailed("Command buffer unavailable")
        }
        buffer.label = "Video frame processing"
        pendingCommandBuffer = buffer
        return buffer
    }

    /// Keeps `object` alive until the pending GPU work completes.
    func retainUntilCompletion(_ object: AnyObject) {
        retainedUntilCompletion.append(object)
    }

    /// Commits pending GPU work and waits for it. Call before handing a
    /// buffer the GPU wrote to any CPU code or other framework.
    func synchronize() throws {
        defer {
            pendingCommandBuffer = nil
            retainedUntilCompletion.removeAll(keepingCapacity: true)
        }
        guard let buffer = pendingCommandBuffer else { return }
        buffer.commit()
        buffer.waitUntilCompleted()
        if buffer.status == .error {
            throw VideoFrameProcessingError.commandBufferFailed(
                buffer.error.map { String(describing: $0) } ?? "unknown"
            )
        }
    }

    /// Wraps one plane of an IOSurface-backed buffer as a texture. The
    /// texture stays valid until the next `synchronize()`.
    func texture(
        for pixelBuffer: CVPixelBuffer,
        plane: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) throws -> any MTLTexture {
        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let width = isPlanar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetHeight(pixelBuffer)
        let attributes = [
            kCVMetalTextureUsage as String: NSNumber(value: usage.rawValue),
        ] as CFDictionary
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            attributes,
            pixelFormat,
            width,
            height,
            isPlanar ? plane : 0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            throw VideoFrameProcessingError.textureCreation(status)
        }
        retainUntilCompletion(cvTexture)
        retainUntilCompletion(pixelBuffer)
        return texture
    }

    /// Encodes a GPU copy of `source` into a buffer from `pool`. The copy is
    /// complete after the next `synchronize()`.
    func copy(
        _ source: CVPixelBuffer,
        using pool: VideoProcessingBufferPool,
        timeout: TimeInterval? = nil
    ) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        guard let layout = VideoProcessingPlaneLayout.layout(for: format) else {
            throw VideoFrameProcessingError.unsupportedPixelFormat(format)
        }
        let destination = try pool.makeBuffer(while: shouldContinue, timeout: timeout)
        // Create every texture before the encoder: a throw with an encoder
        // open would leave the shared command buffer unusable.
        let planes = try layout.planes.enumerated().map { index, plane in
            (
                try texture(for: source, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderRead),
                try texture(for: destination, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderWrite)
            )
        }
        let commandBuffer = try commandBuffer()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw VideoFrameProcessingError.commandBufferFailed("Blit encoder unavailable")
        }
        blit.label = "Copy video frame"
        for (input, output) in planes {
            blit.copy(
                from: input, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(
                    width: min(input.width, output.width),
                    height: min(input.height, output.height),
                    depth: 1
                ),
                to: output, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        blit.endEncoding()
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
