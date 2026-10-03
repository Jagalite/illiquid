import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Synchronization

enum SubtitleCompositionStrategy: String, Sendable {
    case metalR8Atlas = "metal-r8"
    case metalBGRA = "metal-bgra"
}

enum MetalASSFailureReason: String, Error, Sendable {
    case deviceInitialization = "device-initialization"
    case pipelineCreation = "pipeline-creation"
    case invalidBackingGeometry = "invalid-backing-geometry"
    case drawableAcquisition = "drawable-acquisition"
    case textureAllocation = "texture-allocation"
    case bufferAllocation = "buffer-allocation"
    case stagingAllocation = "staging-allocation"
    case commandBufferCreation = "command-buffer-creation"
    case commandEncoderCreation = "command-encoder-creation"
    case commandBufferExecution = "command-buffer-execution"
    case requiredClearSubmission = "required-clear-submission"
    case unsupportedConfiguration = "unsupported-configuration"
}

struct MetalASSRendererError: Error, LocalizedError, Sendable {
    let reason: MetalASSFailureReason
    let detail: String

    var errorDescription: String? { "\(reason.rawValue): \(detail)" }
}

enum MetalASSSamplerMode: String, Sendable {
    case nearest
    case linear
}

enum MetalASSTextureCoordinateMode: String, Sendable {
    case rectangleEdges
    case texelCenters
}

enum MetalASSFragmentAlphaMode: String, Sendable {
    case straight
    case premultiplied
}

enum MetalASSDrawableEncoding: String, Sendable {
    case linear
    case sRGB

    var pixelFormat: MTLPixelFormat {
        switch self {
        case .linear: .bgra8Unorm
        case .sRGB: .bgra8Unorm_srgb
        }
    }
}

struct MetalASSRenderConfiguration: Equatable, Sendable {
    var sampler: MetalASSSamplerMode = .linear
    var textureCoordinates: MetalASSTextureCoordinateMode = .rectangleEdges
    var fragmentAlpha: MetalASSFragmentAlphaMode = .straight
    var drawableEncoding: MetalASSDrawableEncoding = .linear
    /// Diagnostic offset in physical output pixels, not libass coordinates.
    var quadOffsetPixels: Float = 0

    static let production = Self()
}

struct ASSAtlasQuad: Equatable, Sendable {
    let source: CGRect
    let destination: CGRect
    let color: UInt32
}

struct ASSCompositionMetrics: Equatable, Sendable {
    let imageCount: Int
    let copiedBytes: Int
    let uploadBytes: Int
    let drawCalls: Int
    let atlasWidth: Int
    let atlasHeight: Int
    let atlasReallocated: Bool
    let atlasClearBytes: Int

    init(
        imageCount: Int,
        copiedBytes: Int,
        uploadBytes: Int,
        drawCalls: Int,
        atlasWidth: Int = 0,
        atlasHeight: Int = 0,
        atlasReallocated: Bool = false,
        atlasClearBytes: Int = 0
    ) {
        self.imageCount = imageCount
        self.copiedBytes = copiedBytes
        self.uploadBytes = uploadBytes
        self.drawCalls = drawCalls
        self.atlasWidth = atlasWidth
        self.atlasHeight = atlasHeight
        self.atlasReallocated = atlasReallocated
        self.atlasClearBytes = atlasClearBytes
    }
}

struct ASSPreparedSubtitleFrame: Sendable {
    let strategy: SubtitleCompositionStrategy
    let canvasSize: CGSize
    let textureSize: CGSize
    let bytesPerRow: Int
    let pixels: Data
    let quads: [ASSAtlasQuad]
    let metrics: ASSCompositionMetrics
    var usesBitmapAtlas: Bool = false
}

/// CPU preparation shared by the Metal overlay and the correctness harness.
/// The buffers grow as needed and are reused within one subtitle source. A
/// prepared frame holds a value-semantic Data snapshot, while the private
/// reusable storage is serialized by `state`.
final class ASSSubtitleFramePacker: Sendable {
    private struct Placement {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private struct ValidatedRegion {
        let value: ASSRenderedRegion
        let width: Int
        let height: Int
        let stride: Int
        let sourceByteCount: Int
    }

    private struct State: Sendable {
        var atlasStorage = [Data(), Data()]
        var bgraStorage = [Data(), Data()]
        var nextAtlasStorageIndex = 0
        var nextBGRAStorageIndex = 0
    }

    private let maximumTextureDimension: Int
    private let atlasPadding: Int
    private let maximumBackingBytes: Int
    private let maximumRegionCount: Int
    private let memoryLease: SubtitleMemoryBudget.Lease?
    private let state = Mutex(State())

    init(
        maximumTextureDimension: Int = 8_192,
        atlasPadding: Int = 1,
        maximumBackingBytes: Int = 128 * 1_024 * 1_024,
        maximumRegionCount: Int = 256,
        memoryBudget: SubtitleMemoryBudget? = nil,
        memoryOwner: SubtitleMemoryOwner = .mainStaging
    ) {
        self.maximumTextureDimension = max(1, maximumTextureDimension)
        self.atlasPadding = min(
            max(1, atlasPadding),
            max(1, self.maximumTextureDimension / 4)
        )
        self.maximumBackingBytes = max(1, maximumBackingBytes)
        self.maximumRegionCount = max(1, maximumRegionCount)
        memoryLease = memoryBudget?.acquire(owner: memoryOwner, bytes: 0)
    }

    func prepare(
        regions: [ASSRenderedRegion],
        canvasSize: CGSize,
        strategy: SubtitleCompositionStrategy
    ) -> ASSPreparedSubtitleFrame? {
        state.withLock { state in
            if regions.contains(where: \.isPremultipliedBGRA) {
                guard regions.allSatisfy(\.isPremultipliedBGRA) else { return nil }
                return prepareAtlas(regions: regions, canvasSize: canvasSize, state: &state, bytesPerPixel: 4)
            }
            switch strategy {
            case .metalR8Atlas:
                return prepareAtlas(
                    regions: regions,
                    canvasSize: canvasSize,
                    state: &state
                )
            case .metalBGRA:
                return prepareBGRA(
                    regions: regions,
                    canvasSize: canvasSize,
                    state: &state
                )
            }
        }
    }

    /// Releases grow-only staging storage when a subtitle source is retired.
    /// Source-local frame-to-frame reuse remains unchanged.
    func retireSource() {
        state.withLock {
            $0.atlasStorage = [Data(), Data()]
            $0.bgraStorage = [Data(), Data()]
            $0.nextAtlasStorageIndex = 0
            $0.nextBGRAStorageIndex = 0
            _ = memoryLease?.resize(to: 0)
        }
    }

    var retainedStorageByteCountForTesting: Int {
        state.withLock {
            $0.atlasStorage.reduce(0) { $0 + $1.count }
                + $0.bgraStorage.reduce(0) { $0 + $1.count }
        }
    }

    private func prepareAtlas(
        regions: [ASSRenderedRegion],
        canvasSize: CGSize,
        state: inout State,
        bytesPerPixel: Int = 1
    ) -> ASSPreparedSubtitleFrame? {
        guard validCanvas(canvasSize),
              let nonempty = validate(regions)
        else { return nil }
        guard !nonempty.isEmpty else {
            return emptyFrame(strategy: .metalR8Atlas, canvasSize: canvasSize)
        }

        guard let packed = pack(nonempty) else { return nil }
        let (byteCount, byteCountOverflow) = (packed.width * bytesPerPixel).multipliedReportingOverflow(
            by: packed.height
        )
        guard !byteCountOverflow, byteCount <= maximumBackingBytes else { return nil }
        let storageIndex = state.nextAtlasStorageIndex
        state.nextAtlasStorageIndex =
            (state.nextAtlasStorageIndex + 1) % state.atlasStorage.count
        let previousMaximumStorage = state.atlasStorage.map(\.count).max() ?? 0
        let requestedStorage = max(byteCount, previousMaximumStorage)
        let projectedStorageBytes = state.atlasStorage.enumerated().reduce(0) {
            $0 + ($1.offset == storageIndex ? requestedStorage : $1.element.count)
        } + state.bgraStorage.reduce(0) { $0 + $1.count }
        guard memoryLease?.resize(to: projectedStorageBytes) ?? true else {
            return nil
        }
        _ = resizeAndClear(
            &state.atlasStorage[storageIndex],
            byteCount: requestedStorage
        )
        let atlasReallocated = byteCount > previousMaximumStorage

        var copiedBytes = 0
        state.atlasStorage[storageIndex].withUnsafeMutableBytes { destinationBytes in
            guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for (region, placement) in zip(nonempty, packed.placements) {
                let width = placement.width
                let height = placement.height
                copiedBytes += width * height * bytesPerPixel
                region.value.bitmap.withUnsafeBytes { sourceBytes in
                    guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    for row in 0..<height {
                        let sourceStart = source.advanced(by: row * region.stride)
                        let destinationStart = destination.advanced(
                            by: ((placement.y + row) * packed.width + placement.x) * bytesPerPixel
                        )
                        destinationStart.update(from: sourceStart, count: width * bytesPerPixel)
                    }
                }
                replicateAtlasPadding(
                    destination,
                    textureWidth: packed.width,
                    placement: placement,
                    padding: atlasPadding,
                    bytesPerPixel: bytesPerPixel
                )
            }
        }

        let quads = zip(nonempty, packed.placements).map { region, placement in
            ASSAtlasQuad(
                source: CGRect(
                    x: placement.x,
                    y: placement.y,
                    width: placement.width,
                    height: placement.height
                ),
                destination: region.value.frame,
                color: region.value.color
            )
        }
        return ASSPreparedSubtitleFrame(
            strategy: bytesPerPixel == 4 ? .metalBGRA : .metalR8Atlas,
            canvasSize: canvasSize,
            textureSize: CGSize(width: packed.width, height: packed.height),
            bytesPerRow: packed.width * bytesPerPixel,
            pixels: state.atlasStorage[storageIndex],
            quads: quads,
            metrics: ASSCompositionMetrics(
                imageCount: nonempty.count,
                copiedBytes: copiedBytes,
                uploadBytes: byteCount,
                drawCalls: 1,
                atlasWidth: packed.width,
                atlasHeight: packed.height,
                atlasReallocated: atlasReallocated,
                atlasClearBytes: byteCount
            ),
            usesBitmapAtlas: bytesPerPixel == 4
        )
    }

    private func prepareBGRA(
        regions: [ASSRenderedRegion],
        canvasSize: CGSize,
        state: inout State
    ) -> ASSPreparedSubtitleFrame? {
        guard let width = checkedTextureDimension(canvasSize.width),
              let height = checkedTextureDimension(canvasSize.height),
              let validated = validate(regions)
        else { return nil }

        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow,
              !byteOverflow,
              byteCount <= maximumBackingBytes
        else { return nil }
        let storageIndex = state.nextBGRAStorageIndex
        state.nextBGRAStorageIndex =
            (state.nextBGRAStorageIndex + 1) % state.bgraStorage.count
        let previousMaximumStorage = state.bgraStorage.map(\.count).max() ?? 0
        let requestedStorage = max(byteCount, previousMaximumStorage)
        let projectedStorageBytes = state.bgraStorage.enumerated().reduce(0) {
            $0 + ($1.offset == storageIndex ? requestedStorage : $1.element.count)
        } + state.atlasStorage.reduce(0) { $0 + $1.count }
        guard memoryLease?.resize(to: projectedStorageBytes) ?? true else {
            return nil
        }
        _ = resizeAndClear(
            &state.bgraStorage[storageIndex],
            byteCount: requestedStorage
        )
        let atlasReallocated = byteCount > previousMaximumStorage

        var copiedBytes = 0
        state.bgraStorage[storageIndex].withUnsafeMutableBytes { destinationBytes in
            guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for region in validated {
                copiedBytes += region.width * region.height
                composite(
                    region,
                    into: destination,
                    destinationWidth: width,
                    destinationHeight: height
                )
            }
        }

        return ASSPreparedSubtitleFrame(
            strategy: .metalBGRA,
            canvasSize: canvasSize,
            textureSize: CGSize(width: width, height: height),
            bytesPerRow: width * 4,
            pixels: state.bgraStorage[storageIndex],
            quads: [ASSAtlasQuad(
                source: CGRect(x: 0, y: 0, width: width, height: height),
                destination: CGRect(x: 0, y: 0, width: width, height: height),
                color: 0
            )],
            metrics: ASSCompositionMetrics(
                imageCount: validated.count,
                copiedBytes: copiedBytes,
                uploadBytes: byteCount,
                drawCalls: 1,
                atlasWidth: width,
                atlasHeight: height,
                atlasReallocated: atlasReallocated,
                atlasClearBytes: byteCount
            )
        )
    }

    private func emptyFrame(
        strategy: SubtitleCompositionStrategy,
        canvasSize: CGSize
    ) -> ASSPreparedSubtitleFrame {
        ASSPreparedSubtitleFrame(
            strategy: strategy,
            canvasSize: canvasSize,
            textureSize: .zero,
            bytesPerRow: 0,
            pixels: Data(),
            quads: [],
            metrics: ASSCompositionMetrics(
                imageCount: 0,
                copiedBytes: 0,
                uploadBytes: 0,
                drawCalls: 1
            )
        )
    }

    private func pack(
        _ regions: [ValidatedRegion]
    ) -> (width: Int, height: Int, placements: [Placement])? {
        let padding = atlasPadding
        let (doublePadding, paddingOverflow) = padding.multipliedReportingOverflow(by: 2)
        guard !paddingOverflow else { return nil }
        var widest = 1
        var totalArea = 0
        for region in regions {
            let (paddedWidth, widthOverflow) = region.width.addingReportingOverflow(
                doublePadding
            )
            let (paddedHeight, heightOverflow) = region.height.addingReportingOverflow(
                doublePadding
            )
            let (area, areaOverflow) = paddedWidth.multipliedReportingOverflow(
                by: paddedHeight
            )
            let (nextArea, totalOverflow) = totalArea.addingReportingOverflow(area)
            guard !widthOverflow,
                  !heightOverflow,
                  !areaOverflow,
                  !totalOverflow,
                  paddedWidth <= maximumTextureDimension,
                  paddedHeight <= maximumTextureDimension,
                  nextArea <= maximumBackingBytes
            else { return nil }
            widest = max(widest, paddedWidth)
            totalArea = nextArea
        }
        guard let initialWidth = nextPowerOfTwo(
            max(widest, Int(Double(totalArea).squareRoot()))
        ) else { return nil }
        var textureWidth = initialWidth
        textureWidth = max(32, textureWidth)

        let packingOrder = regions.indices.sorted { lhs, rhs in
            let leftHeight = regions[lhs].height
            let rightHeight = regions[rhs].height
            if leftHeight != rightHeight { return leftHeight > rightHeight }
            let leftWidth = regions[lhs].width
            let rightWidth = regions[rhs].width
            if leftWidth != rightWidth { return leftWidth > rightWidth }
            return lhs < rhs
        }

        while textureWidth <= maximumTextureDimension {
            var cursorX = padding
            var cursorY = padding
            var rowHeight = 0
            var placements = Array<Placement?>(repeating: nil, count: regions.count)

            for index in packingOrder {
                let region = regions[index]
                let width = region.width
                let height = region.height
                let (rightEdge, rightEdgeOverflow) = cursorX.addingReportingOverflow(
                    width + padding
                )
                guard !rightEdgeOverflow else { return nil }
                if rightEdge > textureWidth {
                    cursorX = padding
                    let (nextRow, rowOverflow) = cursorY.addingReportingOverflow(
                        rowHeight + doublePadding
                    )
                    guard !rowOverflow else { return nil }
                    cursorY = nextRow
                    rowHeight = 0
                }
                placements[index] = Placement(
                    x: cursorX,
                    y: cursorY,
                    width: width,
                    height: height
                )
                let (nextCursorX, cursorOverflow) = cursorX.addingReportingOverflow(
                    width + doublePadding
                )
                guard !cursorOverflow else { return nil }
                cursorX = nextCursorX
                rowHeight = max(rowHeight, height)
            }

            let (rowBottom, rowBottomOverflow) = cursorY.addingReportingOverflow(rowHeight)
            let (usedHeight, usedHeightOverflow) = rowBottom.addingReportingOverflow(padding)
            guard !rowBottomOverflow,
                  !usedHeightOverflow,
                  let roundedHeight = nextPowerOfTwo(usedHeight)
            else { return nil }
            let textureHeight = max(32, roundedHeight)
            if textureHeight <= maximumTextureDimension {
                let (byteCount, byteCountOverflow) = textureWidth.multipliedReportingOverflow(
                    by: textureHeight
                )
                guard !byteCountOverflow, byteCount <= maximumBackingBytes else {
                    return nil
                }
                return (
                    textureWidth,
                    textureHeight,
                    placements.compactMap { $0 }
                )
            }
            let (nextWidth, widthOverflow) = textureWidth.multipliedReportingOverflow(by: 2)
            guard !widthOverflow, nextWidth > textureWidth else { return nil }
            textureWidth = nextWidth
        }
        return nil
    }

    private func replicateAtlasPadding(
        _ bytes: UnsafeMutablePointer<UInt8>,
        textureWidth: Int,
        placement: Placement,
        padding: Int,
        bytesPerPixel: Int = 1
    ) {
        let x = placement.x
        let y = placement.y
        let width = placement.width
        let height = placement.height
        for row in 0..<height {
            let offset = ((y + row) * textureWidth + x) * bytesPerPixel
            for inset in 1...padding {
                for channel in 0..<bytesPerPixel {
                    bytes[offset - inset * bytesPerPixel + channel] = bytes[offset + channel]
                    bytes[offset + (width - 1 + inset) * bytesPerPixel + channel] = bytes[offset + (width - 1) * bytesPerPixel + channel]
                }
            }
        }
        let paddedWidth = (width + 2 * padding) * bytesPerPixel
        let first = (y * textureWidth + x - padding) * bytesPerPixel
        let last = ((y + height - 1) * textureWidth + x - padding) * bytesPerPixel
        for inset in 1...padding {
            let top = ((y - inset) * textureWidth + x - padding) * bytesPerPixel
            bytes.advanced(by: top).update(
                from: bytes.advanced(by: first),
                count: paddedWidth
            )
            let bottom = ((y + height - 1 + inset) * textureWidth + x - padding) * bytesPerPixel
            bytes.advanced(by: bottom).update(
                from: bytes.advanced(by: last),
                count: paddedWidth
            )
        }
    }

    private func composite(
        _ region: ValidatedRegion,
        into destination: UnsafeMutablePointer<UInt8>,
        destinationWidth: Int,
        destinationHeight: Int
    ) {
        let sourceWidth = region.width
        let sourceHeight = region.height
        let destinationX = Int(region.value.frame.minX)
        let destinationY = Int(region.value.frame.minY)
        let red = Int((region.value.color >> 24) & 0xff)
        let green = Int((region.value.color >> 16) & 0xff)
        let blue = Int((region.value.color >> 8) & 0xff)
        let alpha = 255 - Int(region.value.color & 0xff)

        region.value.bitmap.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for sourceY in 0..<sourceHeight {
                let targetY = destinationY + sourceY
                guard targetY >= 0, targetY < destinationHeight else { continue }
                for sourceX in 0..<sourceWidth {
                    let targetX = destinationX + sourceX
                    guard targetX >= 0, targetX < destinationWidth else { continue }
                    let coverage = Int(source[sourceY * region.stride + sourceX])
                    let sourceAlpha = alpha * coverage
                    let destinationOffset = (targetY * destinationWidth + targetX) * 4
                    let inverseAlpha = 255 * 255 - sourceAlpha
                    let oldBlue = Int(destination[destinationOffset])
                    let oldGreen = Int(destination[destinationOffset + 1])
                    let oldRed = Int(destination[destinationOffset + 2])
                    let oldAlpha = Int(destination[destinationOffset + 3])
                    destination[destinationOffset] = UInt8(
                        (blue * sourceAlpha + oldBlue * inverseAlpha) / (255 * 255)
                    )
                    destination[destinationOffset + 1] = UInt8(
                        (green * sourceAlpha + oldGreen * inverseAlpha) / (255 * 255)
                    )
                    destination[destinationOffset + 2] = UInt8(
                        (red * sourceAlpha + oldRed * inverseAlpha) / (255 * 255)
                    )
                    destination[destinationOffset + 3] = UInt8(
                        (sourceAlpha * 255 + oldAlpha * inverseAlpha) / (255 * 255)
                    )
                }
            }
        }
    }

    private func resizeAndClear(_ data: inout Data, byteCount: Int) -> Bool {
        if data.count < byteCount {
            data = Data(count: byteCount)
            return true
        } else {
            data.resetBytes(in: 0..<byteCount)
            return false
        }
    }

    private func validate(
        _ regions: [ASSRenderedRegion]
    ) -> [ValidatedRegion]? {
        guard regions.count <= maximumRegionCount else { return nil }
        var validated: [ValidatedRegion] = []
        validated.reserveCapacity(regions.count)
        var retainedSourceBytes = 0
        for region in regions {
            let frame = region.frame
            guard frame.minX.isFinite,
                  frame.minY.isFinite,
                  frame.maxX.isFinite,
                  frame.maxY.isFinite,
                  frame.minX >= CGFloat(Int32.min),
                  frame.minY >= CGFloat(Int32.min),
                  frame.maxX <= CGFloat(Int32.max),
                  frame.maxY <= CGFloat(Int32.max),
                  frame.width.isFinite,
                  frame.height.isFinite
            else { return nil }
            if frame.width <= 0 || frame.height <= 0 || region.bitmap.isEmpty {
                continue
            }
            let bitmapSize = region.bitmapSize ?? frame.size
            guard let width = checkedRegionDimension(bitmapSize.width),
                  let height = checkedRegionDimension(bitmapSize.height),
                  region.stride >= width * (region.isPremultipliedBGRA ? 4 : 1)
            else { return nil }
            let (sourceByteCount, sourceOverflow) = region.stride
                .multipliedReportingOverflow(by: height)
            let (nextRetainedBytes, totalOverflow) = retainedSourceBytes
                .addingReportingOverflow(region.bitmap.count)
            guard !sourceOverflow,
                  !totalOverflow,
                  sourceByteCount <= region.bitmap.count,
                  sourceByteCount <= maximumBackingBytes,
                  nextRetainedBytes <= maximumBackingBytes
            else { return nil }
            retainedSourceBytes = nextRetainedBytes
            validated.append(ValidatedRegion(
                value: region,
                width: width,
                height: height,
                stride: region.stride,
                sourceByteCount: sourceByteCount
            ))
        }
        return validated
    }

    private func validCanvas(_ size: CGSize) -> Bool {
        checkedTextureDimension(size.width) != nil
            && checkedTextureDimension(size.height) != nil
    }

    private func checkedTextureDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite,
              value > 0,
              value <= CGFloat(maximumTextureDimension)
        else { return nil }
        let rounded = value.rounded(.up)
        guard rounded <= CGFloat(maximumTextureDimension) else { return nil }
        return Int(rounded)
    }

    private func checkedRegionDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite,
              value > 0,
              value <= CGFloat(maximumTextureDimension),
              value.rounded(.towardZero) == value
        else { return nil }
        return Int(value)
    }

    private func nextPowerOfTwo(_ value: Int) -> Int? {
        guard value > 1 else { return 1 }
        let shift = Int.bitWidth - (value - 1).leadingZeroBitCount
        guard shift < Int.bitWidth - 1 else { return nil }
        return 1 << shift
    }
}

@MainActor
final class MetalASSSubtitleRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
        var color: SIMD4<UInt8>
    }

    private final class FrameResources: @unchecked Sendable {
        var texture: (any MTLTexture)?
        var vertexBuffer: (any MTLBuffer)?
        var vertexCapacity = 0
    }

    private final class ResourcePool: @unchecked Sendable {
        private let lock = NSLock()
        private var available: [FrameResources] = []

        func acquire() -> FrameResources {
            lock.withLock { available.popLast() ?? FrameResources() }
        }

        func release(_ resources: FrameResources) {
            lock.withLock { available.append(resources) }
        }
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let r8Pipeline: any MTLRenderPipelineState
    private let bgraPipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private let configuration: MetalASSRenderConfiguration
    private let resourcePool = ResourcePool()
    private(set) var failureEvents = 0
    private(set) var submittedFrames = 0
    private(set) var submittedUploadBytes = 0
    private(set) var drawableAcquisitionCount = 0
    private(set) var drawableAcquisitionFailures = 0
    private(set) var commandBufferFailures = 0
    private(set) var textureAllocationFailures = 0
    private(set) var bufferAllocationFailures = 0
    private(set) var commandBuffersSubmitted = 0
    private(set) var lastOffscreenGPUDurationSeconds: Double?
    private var synchronousFailure: MetalASSFailureReason?
    /// Metal-capable macOS GPU families support 16,384-wide 2D textures.
    ///
    /// Metal exposes this limit through the macOS GPU-family capability table,
    /// not as an `MTLDevice` property in every supported SDK.
    var maximumTextureDimension2D: Int { 16_384 }

    init(
        layer: CAMetalLayer,
        configuration: MetalASSRenderConfiguration = .production
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalASSRendererError(
                reason: .deviceInitialization,
                detail: "MTLCreateSystemDefaultDevice returned nil"
            )
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalASSRendererError(
                reason: .deviceInitialization,
                detail: "Metal command queue creation returned nil"
            )
        }
        self.device = device
        self.commandQueue = commandQueue
        self.configuration = configuration
        layer.device = device
        layer.pixelFormat = configuration.drawableEncoding.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.backgroundColor = nil
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = true

        let library: any MTLLibrary
        do {
            library = try NativeMetalShaderLibrary.load(device: device)
        } catch {
            throw MetalASSRendererError(
                reason: .pipelineCreation,
                detail: "shader library creation failed: \(error.localizedDescription)"
            )
        }
        guard let vertex = library.makeFunction(name: "ass_vertex"),
              let r8StraightFragment = library.makeFunction(name: "ass_r8_fragment"),
              let r8PremultipliedFragment = library.makeFunction(
                name: "ass_r8_premultiplied_fragment"
              ),
              let bgraFragment = library.makeFunction(name: "ass_bgra_fragment")
        else {
            throw MetalASSRendererError(
                reason: .pipelineCreation,
                detail: "required Metal ASS shader function is unavailable"
            )
        }
        let r8Fragment = configuration.fragmentAlpha == .straight
            ? r8StraightFragment
            : r8PremultipliedFragment

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar4Normalized
        vertexDescriptor.attributes[2].offset = 16
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        do {
            r8Pipeline = try Self.makePipeline(
                device: device,
                vertex: vertex,
                fragment: r8Fragment,
                vertexDescriptor: vertexDescriptor,
                premultiplied: configuration.fragmentAlpha == .premultiplied,
                pixelFormat: configuration.drawableEncoding.pixelFormat
            )
            bgraPipeline = try Self.makePipeline(
                device: device,
                vertex: vertex,
                fragment: bgraFragment,
                vertexDescriptor: vertexDescriptor,
                premultiplied: true,
                pixelFormat: configuration.drawableEncoding.pixelFormat
            )
        } catch {
            throw MetalASSRendererError(
                reason: .pipelineCreation,
                detail: "render pipeline creation failed: \(error.localizedDescription)"
            )
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = configuration.sampler == .linear
            ? .linear
            : .nearest
        samplerDescriptor.minFilter = filter
        samplerDescriptor.magFilter = filter
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalASSRendererError(
                reason: .pipelineCreation,
                detail: "sampler creation returned nil"
            )
        }
        self.sampler = sampler
    }

    func draw(
        _ frame: ASSPreparedSubtitleFrame,
        in layer: CAMetalLayer,
        asynchronousFailure: (@MainActor @Sendable (MetalASSFailureReason) -> Void)? = nil
    ) -> Result<Void, MetalASSFailureReason> {
        guard layer.drawableSize.width.isFinite,
              layer.drawableSize.height.isFinite,
              layer.drawableSize.width > 0,
              layer.drawableSize.height > 0
        else {
            failureEvents += 1
            return .failure(.invalidBackingGeometry)
        }
        drawableAcquisitionCount += 1
        guard let drawable = layer.nextDrawable() else {
            failureEvents += 1
            drawableAcquisitionFailures += 1
            return .failure(.drawableAcquisition)
        }
        let resources = resourcePool.acquire()
        synchronousFailure = nil
        guard encode(
            frame,
            target: drawable.texture,
            present: drawable,
            resources: resources,
            completion: { [resourcePool] in resourcePool.release(resources) },
            asynchronousFailure: asynchronousFailure
        ) else {
            resourcePool.release(resources)
            failureEvents += 1
            return .failure(synchronousFailure ?? .commandBufferCreation)
        }
        submittedFrames += 1
        submittedUploadBytes += frame.metrics.uploadBytes
        return .success(())
    }

    func drawLegacy(_ frame: ASSPreparedSubtitleFrame, in layer: CAMetalLayer) -> Bool {
        if case .success = draw(frame, in: layer) { return true }
        return false
    }

    func renderOffscreen(
        _ frame: ASSPreparedSubtitleFrame,
        targetSize: CGSize? = nil
    ) -> Data? {
        let targetSize = targetSize ?? frame.canvasSize
        let width = max(1, Int(targetSize.width.rounded(.up)))
        let height = max(1, Int(targetSize.height.rounded(.up)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: configuration.drawableEncoding.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        let resources = resourcePool.acquire()
        guard encode(
            frame,
            target: target,
            resources: resources,
            waitUntilCompleted: true
        ) else {
            resourcePool.release(resources)
            return nil
        }
        resourcePool.release(resources)
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            target.getBytes(
                base,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func encode(
        _ frame: ASSPreparedSubtitleFrame,
        target: any MTLTexture,
        present drawable: (any CAMetalDrawable)? = nil,
        resources: FrameResources,
        completion: (@Sendable () -> Void)? = nil,
        asynchronousFailure: (@MainActor @Sendable (MetalASSFailureReason) -> Void)? = nil,
        waitUntilCompleted: Bool = false
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            synchronousFailure = .commandBufferCreation
            commandBufferFailures += 1
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        if !frame.quads.isEmpty {
            guard upload(frame, resources: resources),
                  let texture = resources.texture
            else { return false }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                synchronousFailure = .commandEncoderCreation
                commandBufferFailures += 1
                return false
            }
            let vertices = makeVertices(
                frame,
                texture: texture,
                targetSize: CGSize(width: target.width, height: target.height)
            )
            guard uploadVertices(vertices, resources: resources),
                  let vertexBuffer = resources.vertexBuffer
            else { return false }
            var viewport = SIMD2<Float>(
                Float(max(frame.canvasSize.width, 1)),
                Float(max(frame.canvasSize.height, 1))
            )
            encoder.setRenderPipelineState(
                frame.strategy == .metalR8Atlas ? r8Pipeline : bgraPipeline
            )
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
        } else {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                synchronousFailure = .commandEncoderCreation
                commandBufferFailures += 1
                return false
            }
            encoder.endEncoding()
        }

        if let drawable { commandBuffer.present(drawable) }
        if let completion {
            commandBuffer.addCompletedHandler { _ in completion() }
        }
        if let asynchronousFailure {
            commandBuffer.addCompletedHandler { commandBuffer in
                guard commandBuffer.status == .error else { return }
                Task { @MainActor in
                    asynchronousFailure(.commandBufferExecution)
                }
            }
        }
        commandBuffer.commit()
        commandBuffersSubmitted += 1
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
            let duration = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
            lastOffscreenGPUDurationSeconds = duration.isFinite && duration >= 0
                ? duration
                : nil
            return commandBuffer.status != .error
        }
        // Completion owns resource release after commit. Asynchronous GPU
        // errors are not a synchronous encode failure and must not cause the
        // same resource set to be returned to the pool twice.
        return true
    }

    private func upload(
        _ frame: ASSPreparedSubtitleFrame,
        resources: FrameResources
    ) -> Bool {
        let width = Int(frame.textureSize.width)
        let height = Int(frame.textureSize.height)
        guard width > 0, height > 0 else { return true }
        let pixelFormat: MTLPixelFormat = frame.strategy == .metalR8Atlas
            ? .r8Unorm
            : .bgra8Unorm
        if resources.texture == nil
            || resources.texture!.pixelFormat != pixelFormat
            || resources.texture!.width < width
            || resources.texture!.height < height
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            resources.texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = resources.texture else {
            synchronousFailure = .textureAllocation
            textureAllocationFailures += 1
            return false
        }
        frame.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: frame.bytesPerRow
            )
        }
        return true
    }

    private func makeVertices(
        _ frame: ASSPreparedSubtitleFrame,
        texture: any MTLTexture,
        targetSize: CGSize
    ) -> [Vertex] {
        var vertices: [Vertex] = []
        vertices.reserveCapacity(frame.quads.count * 6)
        for quad in frame.quads {
            let color = SIMD4<UInt8>(
                UInt8((quad.color >> 24) & 0xff),
                UInt8((quad.color >> 16) & 0xff),
                UInt8((quad.color >> 8) & 0xff),
                255 - UInt8(quad.color & 0xff)
            )
            let xOffset = configuration.quadOffsetPixels
                * Float(frame.canvasSize.width / max(targetSize.width, 1))
            let yOffset = configuration.quadOffsetPixels
                * Float(frame.canvasSize.height / max(targetSize.height, 1))
            let x0 = Float(quad.destination.minX) + xOffset
            let y0 = Float(quad.destination.minY) + yOffset
            let x1 = Float(quad.destination.maxX) + xOffset
            let y1 = Float(quad.destination.maxY) + yOffset
            let texelInset: Float = configuration.textureCoordinates == .texelCenters
                ? 0.5
                : 0
            let u0 = (Float(quad.source.minX) + texelInset) / Float(texture.width)
            let v0 = (Float(quad.source.minY) + texelInset) / Float(texture.height)
            let u1 = (Float(quad.source.maxX) - texelInset) / Float(texture.width)
            let v1 = (Float(quad.source.maxY) - texelInset) / Float(texture.height)
            let topLeft = Vertex(
                position: SIMD2(x0, y0), textureCoordinate: SIMD2(u0, v0), color: color
            )
            let bottomLeft = Vertex(
                position: SIMD2(x0, y1), textureCoordinate: SIMD2(u0, v1), color: color
            )
            let topRight = Vertex(
                position: SIMD2(x1, y0), textureCoordinate: SIMD2(u1, v0), color: color
            )
            let bottomRight = Vertex(
                position: SIMD2(x1, y1), textureCoordinate: SIMD2(u1, v1), color: color
            )
            vertices += [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
        }
        return vertices
    }

    private func uploadVertices(
        _ vertices: [Vertex],
        resources: FrameResources
    ) -> Bool {
        let required = vertices.count * MemoryLayout<Vertex>.stride
        if resources.vertexBuffer == nil || resources.vertexCapacity < required {
            resources.vertexCapacity = max(
                required,
                max(resources.vertexCapacity * 2, 4_096)
            )
            resources.vertexBuffer = device.makeBuffer(
                length: resources.vertexCapacity,
                options: .storageModeShared
            )
        }
        guard let vertexBuffer = resources.vertexBuffer else {
            synchronousFailure = .bufferAllocation
            bufferAllocationFailures += 1
            return false
        }
        vertices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            vertexBuffer.contents().copyMemory(from: base, byteCount: required)
        }
        return true
    }

    private static func makePipeline(
        device: any MTLDevice,
        vertex: any MTLFunction,
        fragment: any MTLFunction,
        vertexDescriptor: MTLVertexDescriptor,
        premultiplied: Bool,
        pixelFormat: MTLPixelFormat
    ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

}
