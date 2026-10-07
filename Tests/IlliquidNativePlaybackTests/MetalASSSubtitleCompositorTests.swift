import CoreMedia
import Foundation
import QuartzCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Metal ASS subtitle compositor", .serialized)
struct MetalASSSubtitleCompositorTests {
    private enum ReferenceSampling {
        case nearest
        case linear
    }

    @Test func supersededSubtitleChangeRemainsPendingUntilPresented() {
        var ledger = SubtitlePresentationLedger()

        let changed = ledger.observe(renderedContentChanged: true)
        #expect(changed.contentRevision == 1)
        #expect(changed.requiresPresentation)

        let unchangedAfterSupersession = ledger.observe(
            renderedContentChanged: false
        )
        #expect(unchangedAfterSupersession.contentRevision == 1)
        #expect(unchangedAfterSupersession.requiresPresentation)

        ledger.markPresented(
            contentRevision: unchangedAfterSupersession.contentRevision
        )
        #expect(!ledger.observe(renderedContentChanged: false).requiresPresentation)
    }

    @Test func olderSubtitleCommitCannotAcknowledgeNewerContent() {
        var ledger = SubtitlePresentationLedger()

        let first = ledger.observe(renderedContentChanged: true)
        let second = ledger.observe(renderedContentChanged: true)
        ledger.markPresented(contentRevision: first.contentRevision)

        let pending = ledger.observe(renderedContentChanged: false)
        #expect(pending.contentRevision == second.contentRevision)
        #expect(pending.requiresPresentation)

        ledger.markPresented(contentRevision: second.contentRevision)
        #expect(!ledger.observe(renderedContentChanged: false).requiresPresentation)
    }

    @Test @MainActor func metalIsTheOnlyCompositorAndFailureCannotSwitchIt() {
        let overlay = SubtitleOverlayView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 360)
        )
        #expect(overlay.compositionStrategy == .metalR8Atlas)
        let revision = SubtitleFenceRevision(rawValue: 9)
        #expect(overlay.recordFailure(
            .textureAllocation,
            revision: revision,
            mediaIdentity: "fixture.mkv"
        ) == .metalFailure(.textureAllocation))
        #expect(overlay.compositionStrategy == .metalR8Atlas)
        let diagnostics = overlay.diagnosticsSnapshot()
        #expect(diagnostics.selectedCompositor == .metalR8Atlas)
        #expect(diagnostics.metalInitializationAttempts == 1)
        #expect(diagnostics.failureCount == 1)
        #expect(diagnostics.lastFailureReason == .textureAllocation)
        #expect(diagnostics.lastFailureRevision == 9)
        #expect(diagnostics.lastFailureMediaIdentity == "fixture.mkv")
    }

    @Test func r8AtlasPreservesTopDownRowsAndReplicatesOnePixelPadding() throws {
        let region = ASSRenderedRegion(
            bitmap: Data([1, 2, 3, 4]),
            color: 0xFFFFFF00,
            frame: CGRect(x: 10, y: 11, width: 2, height: 2),
            stride: 2
        )
        let packer = ASSSubtitleFramePacker(maximumTextureDimension: 64)
        let frame = try #require(packer.prepare(
            regions: [region],
            canvasSize: CGSize(width: 32, height: 32),
            strategy: .metalR8Atlas
        ))
        let quad = try #require(frame.quads.first)
        let x = Int(quad.source.minX)
        let y = Int(quad.source.minY)
        let stride = frame.bytesPerRow
        let bytes = Array(frame.pixels)

        #expect(bytes[y * stride + x] == 1)
        #expect(bytes[y * stride + x + 1] == 2)
        #expect(bytes[(y + 1) * stride + x] == 3)
        #expect(bytes[(y + 1) * stride + x + 1] == 4)
        #expect(bytes[y * stride + x - 1] == 1)
        #expect(bytes[y * stride + x + 2] == 2)
        #expect(bytes[(y - 1) * stride + x] == 1)
        #expect(bytes[(y + 2) * stride + x] == 3)
        #expect(quad.destination == region.frame)
        #expect(frame.metrics.copiedBytes == 4)
        #expect(frame.metrics.drawCalls == 1)
    }

    @Test func r8AtlasRejectsMalformedBitmapGeometryBeforeCopying() {
        let malformed = ASSRenderedRegion(
            bitmap: Data([1, 2, 3, 4]),
            color: 0xFFFFFF00,
            frame: CGRect(x: 0, y: 0, width: 4, height: 4),
            stride: 2
        )

        let frame = ASSSubtitleFramePacker(maximumTextureDimension: 64).prepare(
            regions: [malformed],
            canvasSize: CGSize(width: 16, height: 16),
            strategy: .metalR8Atlas
        )

        #expect(frame == nil)
    }

    @Test func r8AtlasRejectsFramesBeyondItsByteBudgetBeforeAllocating() {
        let region = ASSRenderedRegion(
            bitmap: Data(repeating: 255, count: 40 * 40),
            color: 0xFFFFFF00,
            frame: CGRect(x: 0, y: 0, width: 40, height: 40),
            stride: 40
        )
        let packer = ASSSubtitleFramePacker(
            maximumTextureDimension: 64,
            maximumBackingBytes: 1_024
        )

        #expect(packer.prepare(
            regions: [region],
            canvasSize: CGSize(width: 64, height: 64),
            strategy: .metalR8Atlas
        ) == nil)
        #expect(packer.retainedStorageByteCountForTesting == 0)
    }

    @Test func framePackerSerializesConcurrentStorageMutation() async {
        let packer = ASSSubtitleFramePacker(maximumTextureDimension: 64)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) {
            group in
            for value in UInt8(1)...UInt8(64) {
                group.addTask {
                    let region = ASSRenderedRegion(
                        bitmap: Data(repeating: value, count: 16),
                        color: 0xFFFFFF00,
                        frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                        stride: 4
                    )
                    guard let frame = packer.prepare(
                        regions: [region],
                        canvasSize: CGSize(width: 16, height: 16),
                        strategy: .metalR8Atlas
                    ), let quad = frame.quads.first
                    else { return false }
                    let offset = Int(quad.source.minY) * frame.bytesPerRow
                        + Int(quad.source.minX)
                    return frame.pixels[offset] == value
                }
            }
            var output: [Bool] = []
            for await result in group {
                output.append(result)
            }
            return output
        }

        #expect(results.count == 64)
        #expect(results.allSatisfy { $0 })
    }

    @Test func r8AtlasPacksTallMasksTogetherAndDoesNotShrinkStorage() throws {
        func region(width: Int, height: Int, x: Int) -> ASSRenderedRegion {
            ASSRenderedRegion(
                bitmap: Data(repeating: 255, count: width * height),
                color: 0xFFFFFF00,
                frame: CGRect(x: x, y: 0, width: width, height: height),
                stride: width
            )
        }

        let packer = ASSSubtitleFramePacker(maximumTextureDimension: 128)
        let packed = try #require(packer.prepare(
            regions: [
                region(width: 20, height: 40, x: 0),
                region(width: 20, height: 2, x: 20),
                region(width: 20, height: 40, x: 40),
                region(width: 20, height: 2, x: 60),
            ],
            canvasSize: CGSize(width: 80, height: 40),
            strategy: .metalR8Atlas
        ))

        #expect(packed.textureSize == CGSize(width: 64, height: 64))
        #expect(packed.quads.map(\.destination.minX) == [0, 20, 40, 60])
        #expect(packed.metrics.atlasReallocated)

        let smaller = try #require(packer.prepare(
            regions: [region(width: 1, height: 1, x: 0)],
            canvasSize: CGSize(width: 1, height: 1),
            strategy: .metalR8Atlas
        ))
        #expect(smaller.textureSize == CGSize(width: 32, height: 32))
        #expect(!smaller.metrics.atlasReallocated)
        #expect(smaller.pixels.count == packed.pixels.count)

        packer.retireSource()
        #expect(packer.retainedStorageByteCountForTesting == 0)
    }

    @Test func bgraSurfaceUsesInvertedAlphaPremultiplicationAndLinkedListOrder() throws {
        let red = ASSRenderedRegion(
            bitmap: Data([255]),
            color: 0xFF00007F,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            stride: 1
        )
        let blue = ASSRenderedRegion(
            bitmap: Data([255]),
            color: 0x0000FF7F,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            stride: 1
        )
        let packer = ASSSubtitleFramePacker(maximumTextureDimension: 16)
        let frame = try #require(packer.prepare(
            regions: [red, blue],
            canvasSize: CGSize(width: 1, height: 1),
            strategy: .metalBGRA
        ))
        #expect(Array(frame.pixels) == [128, 0, 63, 191])

        let reversed = try #require(packer.prepare(
            regions: [blue, red],
            canvasSize: CGSize(width: 1, height: 1),
            strategy: .metalBGRA
        ))
        #expect(Array(reversed.pixels) == [63, 0, 128, 191])
    }

    @Test @MainActor func singleMetalDrawPreservesOverlappingImageOrder() throws {
        let red = ASSRenderedRegion(
            bitmap: Data([255]),
            color: 0xFF00007F,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            stride: 1
        )
        let blue = ASSRenderedRegion(
            bitmap: Data([255]),
            color: 0x0000FF7F,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            stride: 1
        )
        let packer = ASSSubtitleFramePacker(maximumTextureDimension: 64)
        let frame = try #require(packer.prepare(
            regions: [red, blue],
            canvasSize: CGSize(width: 1, height: 1),
            strategy: .metalR8Atlas
        ))
        let renderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())
        let pixels = try #require(renderer.renderOffscreen(frame))
        #expect(Array(pixels) == [128, 0, 64, 192])
    }

    @Test @MainActor func coverageRampIdentifiesSamplingColorAndAlphaTransforms() throws {
        let logicalSize = CGSize(width: 10, height: 3)
        let region = ASSRenderedRegion(
            bitmap: Data([0, 32, 64, 128, 192, 255]),
            color: 0xFFFFFF00,
            frame: CGRect(x: 2, y: 1, width: 6, height: 1),
            stride: 6
        )
        let variants: [(String, MetalASSRenderConfiguration, Int)] = [
            ("baseline-linear-edge-straight", .production, 1),
            ("nearest", .init(sampler: .nearest), 1),
            ("texel-centers", .init(textureCoordinates: .texelCenters), 1),
            ("offset-minus-half", .init(quadOffsetPixels: -0.5), 1),
            ("offset-plus-half", .init(quadOffsetPixels: 0.5), 1),
            ("srgb-drawable", .init(drawableEncoding: .sRGB), 1),
            ("premultiplied-fragment", .init(fragmentAlpha: .premultiplied), 1),
            ("padding-two", .production, 2),
        ]

        for scale in [CGFloat(1), CGFloat(2)] {
            let targetSize = CGSize(
                width: logicalSize.width * scale,
                height: logicalSize.height * scale
            )
            let cpuLinear = Self.renderCPUReferenceBGRA(
                regions: [region],
                logicalSize: logicalSize,
                outputScale: scale,
                sampling: .linear
            )
            let cpuNearest = Self.renderCPUReferenceBGRA(
                regions: [region],
                logicalSize: logicalSize,
                outputScale: scale,
                sampling: .nearest
            )
            for (name, configuration, padding) in variants {
                let packer = ASSSubtitleFramePacker(
                    maximumTextureDimension: 64,
                    atlasPadding: padding
                )
                let frame = try #require(packer.prepare(
                    regions: [region],
                    canvasSize: logicalSize,
                    strategy: .metalR8Atlas
                ))
                let renderer = try MetalASSSubtitleRenderer(
                    layer: CAMetalLayer(),
                    configuration: configuration
                )
                let metal = try #require(renderer.renderOffscreen(
                    frame,
                    targetSize: targetSize
                ))
                let linearDifference = Self.difference(metal, cpuLinear)
                let nearestDifference = Self.difference(metal, cpuNearest)
                print(
                    "metal ASS diagnostic variant=\(name) scale=\(scale) "
                        + "linearMax=\(linearDifference.maximum) "
                        + "linearBytes=\(linearDifference.count) "
                        + "nearestMax=\(nearestDifference.maximum) "
                        + "nearestBytes=\(nearestDifference.count)"
                )
            }
        }

        let frame = try #require(ASSSubtitleFramePacker(
            maximumTextureDimension: 64
        ).prepare(
            regions: [region],
            canvasSize: logicalSize,
            strategy: .metalR8Atlas
        ))
        let metal = try #require(MetalASSSubtitleRenderer(
            layer: CAMetalLayer()
        ).renderOffscreen(frame))
        let reference = Self.renderCPUReferenceBGRA(
            regions: [region],
            logicalSize: logicalSize,
            outputScale: 1,
            sampling: .nearest
        )
        #expect(Self.difference(metal, reference).maximum <= 1)
    }

    @Test @MainActor func urgentClearRejectsAnInFlightMetalFrame() async throws {
        let size = CGSize(width: 640, height: 360)
        let overlay = SubtitleOverlayView(
            frame: CGRect(origin: .zero, size: size),
            compositionStrategy: .metalR8Atlas
        )
        overlay.updateDrawableSize(backingScale: 1)
        let pipeline = try SubtitlePipeline(overlay: overlay)
        try pipeline.installExternal(data: Data(Self.featureMatrix.utf8))

        pipeline.render(
            at: CMTime(seconds: 1.25, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: size),
            videoSize: size
        )
        pipeline.clear()
        try await Task.sleep(for: .milliseconds(100))

        #expect(pipeline.counters().overlayCommits == 0)
    }

    @Test @MainActor
    func concurrentDelayToggleRenderAndReadOperationsShareOneLockBoundary() throws {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        try pipeline.installExternal(data: Data(Self.minimalGlyph.utf8))

        let workerCount = 4
        let iterations = 64
        let ready = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let queue = DispatchQueue(
            label: "com.illiquid.tests.subtitle-pipeline-concurrency",
            qos: .userInitiated,
            attributes: .concurrent
        )

        for worker in 0..<workerCount {
            ready.enter()
            finished.enter()
            queue.async {
                ready.leave()
                start.wait()
                defer { finished.leave() }

                for iteration in 0..<iterations {
                    switch worker {
                    case 0:
                        pipeline.delay = Double((iteration % 9) - 4) / 100
                        _ = pipeline.delay
                    case 1:
                        pipeline.isEnabled = iteration.isMultiple(of: 2)
                        _ = pipeline.isEnabled
                    case 2:
                        _ = pipeline.renderedRegions(
                            at: CMTime(
                                value: CMTimeValue(900 + iteration),
                                timescale: 1_000
                            ),
                            viewport: CGRect(x: 0, y: 0, width: 320, height: 180),
                            videoSize: CGSize(width: 320, height: 180)
                        )
                    default:
                        _ = pipeline.eventCount
                        _ = pipeline.counters()
                        _ = pipeline.configuredLibassGeometry()
                        if iteration.isMultiple(of: 8) {
                            _ = pipeline.pictureInPictureSubtitleSnapshot(
                                at: CMTime(
                                    value: CMTimeValue(900 + iteration),
                                    timescale: 1_000
                                ),
                                viewport: CGRect(
                                    x: 0,
                                    y: 0,
                                    width: 320,
                                    height: 180
                                ),
                                videoSize: CGSize(width: 320, height: 180)
                            )
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.000_1)
                }
            }
        }

        #expect(ready.wait(timeout: .now() + 2) == .success)
        for _ in 0..<workerCount {
            start.signal()
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)

        pipeline.delay = 0
        pipeline.isEnabled = true
        let finalRegions = pipeline.renderedRegions(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 320, height: 180),
            videoSize: CGSize(width: 320, height: 180)
        )

        #expect(pipeline.delay == 0)
        #expect(pipeline.isEnabled)
        #expect(!finalRegions.isEmpty)
        #expect(pipeline.counters().libassFrames > 0)
    }

    @Test @MainActor func minimalGlyphAtBackingResolutionMatchesIndependentReference() throws {
        let backingSize = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try pipeline.installExternal(data: Data(Self.minimalGlyph.utf8))
        let regions = pipeline.renderedRegions(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: backingSize),
            videoSize: backingSize
        )
        #expect(!regions.isEmpty)
        let frame = try #require(ASSSubtitleFramePacker().prepare(
            regions: regions,
            canvasSize: backingSize,
            strategy: .metalR8Atlas
        ))
        let metal = try #require(MetalASSSubtitleRenderer(
            layer: CAMetalLayer()
        ).renderOffscreen(frame))
        let cpu = Self.renderCPUReferenceBGRA(
            regions: regions,
            logicalSize: backingSize,
            outputScale: 1,
            sampling: .nearest
        )
        let difference = Self.difference(metal, cpu)
        print(
            "metal ASS minimal logical=320x180 backing=640x360 "
                + "regions=\(regions.count) maxDifference=\(difference.maximum) "
                + "differentBytes=\(difference.count)"
        )
        #expect(frame.canvasSize == backingSize)
        #expect(difference.maximum <= 1)
    }

    @Test @MainActor func retinaCoordinateContractUsesBackingPixelsEndToEnd() async throws {
        let logicalSize = CGSize(width: 640, height: 360)
        let overlay = SubtitleOverlayView(
            frame: CGRect(origin: .zero, size: logicalSize),
            compositionStrategy: .metalR8Atlas
        )
        overlay.updateDrawableSize(backingScale: 2)
        #expect(overlay.bounds.size == logicalSize)
        #expect(overlay.metalBackingScale == 2)
        #expect(overlay.metalBackingPixelSize == CGSize(width: 1_280, height: 720))

        let pipeline = try SubtitlePipeline(overlay: overlay)
        try pipeline.installExternal(data: Data(Self.minimalGlyph.utf8))
        pipeline.render(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: logicalSize),
            videoSize: logicalSize
        )
        for _ in 0..<100 where overlay.lastPreparedCanvasSize == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(overlay.lastPreparedCanvasSize == CGSize(width: 1_280, height: 720))
        let geometry = pipeline.configuredLibassGeometry()
        #expect(geometry.frame == CGSize(width: 1_280, height: 720))
        #expect(geometry.storage == logicalSize)
        #expect(pipeline.counters().libassFrames == 1)
        #expect(pipeline.counters().metalFailures == 0)
    }

    @Test @MainActor func backingResolutionLibassMatchesIndependentCPUReference() throws {
        let logicalSize = CGSize(width: 640, height: 360)
        let backingSize = CGSize(width: 1_280, height: 720)
        let logicalPipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let backingPipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try logicalPipeline.installExternal(data: Data(Self.featureMatrix.utf8))
        try backingPipeline.installExternal(data: Data(Self.featureMatrix.utf8))
        let packer = ASSSubtitleFramePacker()
        let renderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())

        for seconds in [0.25, 0.75, 1.25, 1.75, 2.5] {
            let logicalRegions = logicalPipeline.renderedRegions(
                at: CMTime(seconds: seconds, preferredTimescale: 1_000),
                viewport: CGRect(origin: .zero, size: logicalSize),
                videoSize: logicalSize
            )
            let backingRegions = backingPipeline.renderedRegions(
                at: CMTime(seconds: seconds, preferredTimescale: 1_000),
                viewport: CGRect(origin: .zero, size: backingSize),
                videoSize: backingSize
            )
            let logicalFrame = try #require(packer.prepare(
                regions: logicalRegions,
                canvasSize: logicalSize,
                strategy: .metalR8Atlas
            ))
            let logicalMetal = try #require(renderer.renderOffscreen(
                logicalFrame,
                targetSize: backingSize
            ))
            let backingFrame = try #require(packer.prepare(
                regions: backingRegions,
                canvasSize: backingSize,
                strategy: .metalR8Atlas
            ))
            let backingMetal = try #require(renderer.renderOffscreen(backingFrame))
            let independentCPU = Self.renderCPUReferenceBGRA(
                regions: backingRegions,
                logicalSize: backingSize,
                outputScale: 1,
                sampling: .nearest
            )
            let referenceDifference = Self.difference(backingMetal, independentCPU)
            let logicalDifference = Self.difference(backingMetal, logicalMetal)
            print(
                "metal ASS backing t=\(seconds) logicalImages=\(logicalRegions.count) "
                    + "backingImages=\(backingRegions.count) "
                    + "cpuMax=\(referenceDifference.maximum) "
                    + "cpuBytes=\(referenceDifference.count) "
                    + "logicalScaledMax=\(logicalDifference.maximum) "
                    + "logicalScaledBytes=\(logicalDifference.count)"
            )
            #expect(referenceDifference.maximum <= 3)
        }
    }

    @Test @MainActor func assFeatureMatrixRecordsBGRAQuantizationDifference() throws {
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try pipeline.installExternal(data: Data(Self.featureMatrix.utf8))
        let size = CGSize(width: 640, height: 360)
        let viewport = CGRect(origin: .zero, size: size)
        let r8Packer = ASSSubtitleFramePacker()
        let bgraPacker = ASSSubtitleFramePacker()
        let r8Renderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())
        let bgraRenderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())

        for seconds in [0.25, 0.75, 1.25, 1.75, 2.5] {
            let regions = pipeline.renderedRegions(
                at: CMTime(seconds: seconds, preferredTimescale: 1_000),
                viewport: viewport,
                videoSize: size
            )
            #expect(!regions.isEmpty)
            let r8 = try #require(r8Packer.prepare(
                regions: regions,
                canvasSize: size,
                strategy: .metalR8Atlas
            ))
            let bgra = try #require(bgraPacker.prepare(
                regions: regions,
                canvasSize: size,
                strategy: .metalBGRA
            ))
            let r8Pixels = try #require(r8Renderer.renderOffscreen(r8))
            let bgraPixels = try #require(bgraRenderer.renderOffscreen(bgra))
            let difference = Self.difference(r8Pixels, bgraPixels)
            print(
                "metal ASS matrix t=\(seconds) regions=\(regions.count) "
                    + "maxDifference=\(difference.maximum) "
                    + "differentBytes=\(difference.count)"
            )
            // The premultiplied CPU path follows mpv's integer division,
            // while the R8 path blends normalized values in the render target.
            // Keep the observed gap bounded, but do not call it byte parity.
            #expect(difference.maximum <= 4)
            #expect(difference.count > 0)
        }
    }

    @Test @MainActor func heavyAnimatedFixtureCostsAreRecorded() throws {
        guard ProcessInfo.processInfo.environment["ILLIQUID_METAL_ASS_BENCHMARK"] == "1",
              let fixtureDirectory = ProcessInfo.processInfo.environment[
                "ILLIQUID_NATIVE_FIXTURE_DIR"
              ]
        else { return }
        let fixture = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("heavy-animated.ass")
        let size = CGSize(width: 1_280, height: 720)
        let viewport = CGRect(origin: .zero, size: size)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try pipeline.loadExternal(url: fixture)

        var regionFrames: [[ASSRenderedRegion]] = []
        var logicalLibassMilliseconds: [Double] = []
        let libassClock = ContinuousClock()
        for index in 0..<45 {
            let start = libassClock.now
            regionFrames.append(pipeline.renderedRegions(
                at: CMTime(seconds: Double(index) / 20, preferredTimescale: 1_000),
                viewport: viewport,
                videoSize: size
            ))
            logicalLibassMilliseconds.append(
                Double(start.duration(to: libassClock.now).components.attoseconds) / 1e15
            )
        }
        logicalLibassMilliseconds.sort()
        let imageCounts = regionFrames.map(\.count).sorted()
        let logicalMaskBytes = regionFrames.reduce(0) { total, regions in
            total + regions.reduce(0) { $0 + $1.bitmap.count }
        }
        print(
            "metal ASS imagesMean="
                + "\(Self.mean(imageCounts.map(Double.init))) "
                + "imagesP95=\(Self.percentile95(imageCounts.map(Double.init))) "
                + "libassMeanMs=\(Self.mean(logicalLibassMilliseconds)) "
                + "libassP95Ms=\(Self.percentile95(logicalLibassMilliseconds)) "
                + "maskBytes=\(logicalMaskBytes)"
        )

        for strategy in [
            SubtitleCompositionStrategy.metalR8Atlas,
            .metalBGRA,
        ] {
            let packer = ASSSubtitleFramePacker()
            let renderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())
            var cpuMilliseconds: [Double] = []
            var gpuMilliseconds: [Double] = []
            var copiedBytes = 0
            var uploadBytes = 0
            let clock = ContinuousClock()
            for regions in regionFrames {
                let start = clock.now
                let frame = try #require(packer.prepare(
                    regions: regions,
                    canvasSize: size,
                    strategy: strategy
                ))
                cpuMilliseconds.append(
                    Double(start.duration(to: clock.now).components.attoseconds) / 1e15
                )
                _ = try #require(renderer.renderOffscreen(frame))
                if let duration = renderer.lastOffscreenGPUDurationSeconds {
                    gpuMilliseconds.append(duration * 1_000)
                }
                copiedBytes += frame.metrics.copiedBytes
                uploadBytes += frame.metrics.uploadBytes
            }
            cpuMilliseconds.sort()
            gpuMilliseconds.sort()
            print(
                "metal ASS strategy=\(strategy.rawValue) frames=\(regionFrames.count) "
                    + "cpuMeanMs=\(Self.mean(cpuMilliseconds)) "
                    + "cpuP95Ms=\(Self.percentile95(cpuMilliseconds)) "
                    + "gpuMeanMs=\(Self.mean(gpuMilliseconds)) "
                    + "gpuP95Ms=\(Self.percentile95(gpuMilliseconds)) "
                + "copiedBytes=\(copiedBytes) uploadBytes=\(uploadBytes) drawCalls=45"
            )
        }

        let backingSize = CGSize(width: size.width * 2, height: size.height * 2)
        let backingViewport = CGRect(origin: .zero, size: backingSize)
        let backingPipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try backingPipeline.loadExternal(url: fixture)
        let backingPacker = ASSSubtitleFramePacker()
        let backingRenderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())
        var backingLibassMilliseconds: [Double] = []
        var backingPrepareMilliseconds: [Double] = []
        var backingGPUMilliseconds: [Double] = []
        var backingMaskBytes = 0
        var backingUploadBytes = 0
        for index in 0..<45 {
            let renderStart = libassClock.now
            let regions = backingPipeline.renderedRegions(
                at: CMTime(seconds: Double(index) / 20, preferredTimescale: 1_000),
                viewport: backingViewport,
                videoSize: backingSize
            )
            backingLibassMilliseconds.append(
                Double(
                    renderStart.duration(to: libassClock.now).components.attoseconds
                ) / 1e15
            )
            backingMaskBytes += regions.reduce(0) { $0 + $1.bitmap.count }
            let prepareStart = libassClock.now
            let frame = try #require(backingPacker.prepare(
                regions: regions,
                canvasSize: backingSize,
                strategy: .metalR8Atlas
            ))
            backingPrepareMilliseconds.append(
                Double(
                    prepareStart.duration(to: libassClock.now).components.attoseconds
                ) / 1e15
            )
            _ = try #require(backingRenderer.renderOffscreen(frame))
            if let duration = backingRenderer.lastOffscreenGPUDurationSeconds {
                backingGPUMilliseconds.append(duration * 1_000)
            }
            backingUploadBytes += frame.metrics.uploadBytes
        }
        backingLibassMilliseconds.sort()
        backingPrepareMilliseconds.sort()
        backingGPUMilliseconds.sort()
        print(
            "metal ASS strategy=retina-backing-r8 frames=45 "
                + "libassMeanMs=\(Self.mean(backingLibassMilliseconds)) "
                + "libassP95Ms=\(Self.percentile95(backingLibassMilliseconds)) "
                + "cpuMeanMs=\(Self.mean(backingPrepareMilliseconds)) "
                + "cpuP95Ms=\(Self.percentile95(backingPrepareMilliseconds)) "
                + "gpuMeanMs=\(Self.mean(backingGPUMilliseconds)) "
                + "gpuP95Ms=\(Self.percentile95(backingGPUMilliseconds)) "
                + "maskBytes=\(backingMaskBytes) uploadBytes=\(backingUploadBytes)"
        )
    }

    private static func difference(_ lhs: Data, _ rhs: Data) -> (maximum: Int, count: Int) {
        guard lhs.count == rhs.count else { return (255, max(lhs.count, rhs.count)) }
        var maximum = 0
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            let delta = abs(Int(left) - Int(right))
            maximum = max(maximum, delta)
            if delta != 0 { count += 1 }
        }
        return (maximum, count)
    }

    private static func renderCPUReferenceBGRA(
        regions: [ASSRenderedRegion],
        logicalSize: CGSize,
        outputScale: CGFloat,
        sampling: ReferenceSampling
    ) -> Data {
        let width = Int((logicalSize.width * outputScale).rounded())
        let height = Int((logicalSize.height * outputScale).rounded())
        var output = Data(count: width * height * 4)
        output.withUnsafeMutableBytes { outputBytes in
            guard let destination = outputBytes.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for region in regions {
                let red = Int((region.color >> 24) & 0xff)
                let green = Int((region.color >> 16) & 0xff)
                let blue = Int((region.color >> 8) & 0xff)
                let baseAlpha = Int(255 - UInt8(region.color & 0xff))
                region.bitmap.withUnsafeBytes { regionBytes in
                    guard let source = regionBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    let x0 = max(0, Int(floor(region.frame.minX * outputScale)))
                    let x1 = min(width, Int(ceil(region.frame.maxX * outputScale)))
                    let y0 = max(0, Int(floor(region.frame.minY * outputScale)))
                    let y1 = min(height, Int(ceil(region.frame.maxY * outputScale)))
                    for outputY in y0..<y1 {
                        let logicalY = (CGFloat(outputY) + 0.5) / outputScale
                        for outputX in x0..<x1 {
                            let logicalX = (CGFloat(outputX) + 0.5) / outputScale
                            guard logicalX >= region.frame.minX,
                                  logicalX < region.frame.maxX,
                                  logicalY >= region.frame.minY,
                                  logicalY < region.frame.maxY
                            else { continue }
                            let sourceX = (
                                (logicalX - region.frame.minX) / region.frame.width
                            ) * region.frame.width - 0.5
                            let sourceY = (
                                (logicalY - region.frame.minY) / region.frame.height
                            ) * region.frame.height - 0.5
                            let coverage = sampleCoverage(
                                source,
                                width: Int(region.frame.width),
                                height: Int(region.frame.height),
                                stride: region.stride,
                                x: sourceX,
                                y: sourceY,
                                sampling: sampling
                            )
                            compositeReferencePixel(
                                destination,
                                offset: (outputY * width + outputX) * 4,
                                red: red,
                                green: green,
                                blue: blue,
                                alpha: baseAlpha,
                                coverage: coverage
                            )
                        }
                    }
                }
            }
        }
        return output
    }

    private static func sampleCoverage(
        _ source: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        x: CGFloat,
        y: CGFloat,
        sampling: ReferenceSampling
    ) -> Int {
        func value(_ x: Int, _ y: Int) -> Int {
            let clampedX = min(max(x, 0), width - 1)
            let clampedY = min(max(y, 0), height - 1)
            return Int(source[clampedY * stride + clampedX])
        }
        switch sampling {
        case .nearest:
            return value(Int(floor(x + 0.5)), Int(floor(y + 0.5)))
        case .linear:
            let x0 = Int(floor(x))
            let y0 = Int(floor(y))
            let fractionX = x - CGFloat(x0)
            let fractionY = y - CGFloat(y0)
            let top = CGFloat(value(x0, y0)) * (1 - fractionX)
                + CGFloat(value(x0 + 1, y0)) * fractionX
            let bottom = CGFloat(value(x0, y0 + 1)) * (1 - fractionX)
                + CGFloat(value(x0 + 1, y0 + 1)) * fractionX
            return Int((top * (1 - fractionY) + bottom * fractionY).rounded())
        }
    }

    private static func compositeReferencePixel(
        _ destination: UnsafeMutablePointer<UInt8>,
        offset: Int,
        red: Int,
        green: Int,
        blue: Int,
        alpha: Int,
        coverage: Int
    ) {
        let sourceAlpha = alpha * coverage
        let inverseAlpha = 255 * 255 - sourceAlpha
        let oldBlue = Int(destination[offset])
        let oldGreen = Int(destination[offset + 1])
        let oldRed = Int(destination[offset + 2])
        let oldAlpha = Int(destination[offset + 3])
        destination[offset] = UInt8(
            (blue * sourceAlpha + oldBlue * inverseAlpha) / (255 * 255)
        )
        destination[offset + 1] = UInt8(
            (green * sourceAlpha + oldGreen * inverseAlpha) / (255 * 255)
        )
        destination[offset + 2] = UInt8(
            (red * sourceAlpha + oldRed * inverseAlpha) / (255 * 255)
        )
        destination[offset + 3] = UInt8(
            (sourceAlpha * 255 + oldAlpha * inverseAlpha) / (255 * 255)
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values[min(values.count - 1, Int((Double(values.count) * 0.95).rounded(.up)) - 1)]
    }

    private static let featureMatrix = #"""
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
    Style: Default,sans-serif,30,&H00FFFFFF,&H0000FFFF,&H00101010,&H70000000,0,0,0,0,100,100,0,0,1,3,2,2,20,20,20,1

    [Events]
    Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(320,330)}Plain dialogue
    Dialogue: 1,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(180,55)\1c&H0000FF&\bord4\shad3\blur1.5}Color outline shadow blur
    Dialogue: 2,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(180,55)\1c&H00FF00&\alpha&H60&}Ordered overlap
    Dialogue: 3,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(460,55)\k20\k20\k20}Ka ra oke
    Dialogue: 4,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\move(80,150,560,150)\fad(300,500)\t(0,3000,\fscx160\fscy70\frz35)}Move fade transform
    Dialogue: 4,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(320,185)\fade(255,0,255,0,500,2500,3500)}Complex fade
    Dialogue: 5,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(180,230)\clip(100,200,260,260)}Clipped
    Dialogue: 6,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(460,230)\iclip(400,200,520,260)}Inverse clip
    Dialogue: 7,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(320,280)\p1\1c&HFF8000&}m 0 0 l 80 0 80 30 0 30{\p0}
    Dialogue: 8,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\move(110.5,105.5,530.5,105.5)\p1\1c&H00A0FF&\t(0,3000,\frz180\fscx140\fscy80)}m -20 -10 l 20 -10 20 10 -20 10{\p0}
    """#

    private static let minimalGlyph = #"""
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
    Style: Default,sans-serif,32,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

    [Events]
    Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\pos(80,60)}A
    """#
}
