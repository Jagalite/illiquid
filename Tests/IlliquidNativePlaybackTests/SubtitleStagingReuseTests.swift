import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle staging storage reuse")
struct SubtitleStagingReuseTests {
    private struct Input {
        var regions: [ASSRenderedRegion]
        var canvasSize = CGSize(width: 512, height: 512)
        var strategy: SubtitleCompositionStrategy = .metalR8Atlas
    }

    private struct Snapshot {
        let frame: ASSPreparedSubtitleFrame
        let expectedPixels: Data
    }

    @Test(arguments: [false, true])
    func atlasSnapshotsMatchFreshPackingAcrossSizeAndPixelFormatChanges(
        retainSnapshots: Bool
    ) throws {
        let inputs = [
            Input(regions: [region(width: 244, height: 120, value: 9)]),
            Input(regions: [region(width: 7, height: 5, value: 71)]),
            Input(regions: [region(width: 1, height: 1, value: 103)]),
            Input(regions: [region(width: 60, height: 28, value: 37, bitmap: true)]),
            Input(regions: [region(width: 28, height: 60, value: 13)]),
            Input(regions: [region(width: 244, height: 244, value: 91, bitmap: true)]),
            Input(regions: [
                region(width: 20, height: 40, value: 5),
                region(width: 20, height: 2, value: 53, x: 20),
                region(width: 20, height: 40, value: 109, x: 40),
            ]),
            Input(regions: [region(width: 5, height: 7, value: 131, bitmap: true)]),
            Input(regions: [region(width: 1, height: 1, value: 3)]),
            Input(regions: [region(width: 1, height: 1, value: 193)]),
            Input(regions: [region(width: 1, height: 1, value: 239)]),
        ]

        try verifySequence(inputs, retainSnapshots: retainSnapshots)
    }

    @Test(arguments: [false, true])
    func bgraSnapshotsMatchFreshPackingThroughClippingOverlapsAndEmptyFrames(
        retainSnapshots: Bool
    ) throws {
        let overlapping = [
            region(width: 47, height: 35, value: 37, x: -3, y: -2, color: 0xFF00007F),
            region(width: 23, height: 17, value: 89, x: 5, y: 4, color: 0x0000FF7F),
        ]
        let inputs = [
            Input(regions: overlapping, canvasSize: CGSize(width: 128, height: 96), strategy: .metalBGRA),
            Input(regions: overlapping, canvasSize: CGSize(width: 32, height: 24), strategy: .metalBGRA),
            Input(regions: overlapping, canvasSize: CGSize(width: 8, height: 6), strategy: .metalBGRA),
            Input(regions: [], canvasSize: CGSize(width: 3, height: 2), strategy: .metalBGRA),
            Input(regions: overlapping, canvasSize: CGSize(width: 256, height: 128), strategy: .metalBGRA),
            Input(regions: [], canvasSize: CGSize(width: 5, height: 7), strategy: .metalBGRA),
            Input(regions: overlapping.reversed(), canvasSize: CGSize(width: 1, height: 1), strategy: .metalBGRA),
            Input(regions: overlapping, canvasSize: CGSize(width: 1, height: 1), strategy: .metalBGRA),
            Input(regions: [], canvasSize: CGSize(width: 1, height: 1), strategy: .metalBGRA),
        ]

        try verifySequence(inputs, retainSnapshots: retainSnapshots)
    }

    @Test func emptyAndInvalidAtlasCallsPreserveReusableSnapshots() throws {
        let packer = makePacker()
        let large = Input(regions: [region(width: 124, height: 124, value: 79)])
        let small = Input(regions: [region(width: 1, height: 1, value: 151)])
        var snapshots: [Snapshot] = []
        var highWaterBytes = 0
        for _ in 0..<2 {
            snapshots.append(try checkedPrepare(large, packer: packer, highWaterBytes: &highWaterBytes))
        }
        let retainedBeforeFailures = packer.retainedStorageByteCountForTesting

        let empty = try #require(packer.prepare(
            regions: [], canvasSize: large.canvasSize, strategy: .metalR8Atlas
        ))
        #expect(empty.pixels.isEmpty)
        #expect(empty.metrics.atlasClearBytes == 0)

        let malformed = ASSRenderedRegion(
            bitmap: Data([1]), color: 0xFFFFFF00,
            frame: CGRect(x: 0, y: 0, width: 4, height: 4), stride: 4
        )
        #expect(packer.prepare(
            regions: [malformed], canvasSize: large.canvasSize, strategy: .metalR8Atlas
        ) == nil)
        #expect(packer.prepare(
            regions: small.regions + [region(width: 1, height: 1, value: 1, bitmap: true)],
            canvasSize: large.canvasSize, strategy: .metalR8Atlas
        ) == nil)
        #expect(packer.prepare(
            regions: small.regions, canvasSize: CGSize(width: CGFloat.nan, height: 512),
            strategy: .metalR8Atlas
        ) == nil)
        #expect(packer.retainedStorageByteCountForTesting == retainedBeforeFailures)

        for _ in 0..<4 {
            snapshots.append(try checkedPrepare(small, packer: packer, highWaterBytes: &highWaterBytes))
        }
        for snapshot in snapshots {
            #expect(snapshot.frame.pixels == snapshot.expectedPixels)
        }
    }

    @Test(arguments: [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA])
    func rejectedGrowthDoesNotCorruptTheNextReuseOrBudget(
        strategy: SubtitleCompositionStrategy
    ) throws {
        let initial = sizedInput(strategy: strategy, large: false)
        let growth = sizedInput(strategy: strategy, large: true)
        let small = tinyInput(strategy: strategy)
        let initialReference = try #require(prepare(initial, using: makePacker()))
        let initialBytes = initialReference.metrics.uploadBytes
        let budget = SubtitleMemoryBudget(limitBytes: 3 * initialBytes, ownerLimitsBytes: [:])
        let packer = makePacker(memoryBudget: budget)
        var highWaterBytes = 0
        var snapshots: [Snapshot] = []
        for _ in 0..<2 {
            snapshots.append(try checkedPrepare(initial, packer: packer, highWaterBytes: &highWaterBytes))
        }
        #expect(packer.retainedStorageByteCountForTesting == 2 * initialBytes)
        let blocker = try #require(budget.acquire(owner: .bitmapEvents, bytes: initialBytes))

        #expect(prepare(growth, using: packer) == nil)
        #expect(budget.snapshot.rejectedAcquisitions == 1)
        #expect(budget.snapshot.reservedBytes == 3 * initialBytes)
        #expect(packer.retainedStorageByteCountForTesting == 2 * initialBytes)
        for _ in 0..<4 {
            snapshots.append(try checkedPrepare(small, packer: packer, highWaterBytes: &highWaterBytes))
        }

        #expect(blocker.resize(to: 0))
        snapshots.append(try checkedPrepare(growth, packer: packer, highWaterBytes: &highWaterBytes))
        #expect(budget.snapshot.reservedBytes == packer.retainedStorageByteCountForTesting)
        #expect(budget.snapshot.rejectedAcquisitions == 1)
        for snapshot in snapshots {
            #expect(snapshot.frame.pixels == snapshot.expectedPixels)
        }
    }

    @Test func sourceRetirementReleasesBothPoolsAndPreservesPublishedSnapshots() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 1_024 * 1_024, ownerLimitsBytes: [:])
        let packer = makePacker(memoryBudget: budget)
        var snapshots: [Snapshot] = []
        for strategy in [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA] {
            var highWaterBytes = 0
            for _ in 0..<2 {
                snapshots.append(try checkedPrepare(
                    sizedInput(strategy: strategy, large: true),
                    packer: packer, highWaterBytes: &highWaterBytes
                ))
            }
        }
        #expect(budget.snapshot.reservedBytes == packer.retainedStorageByteCountForTesting)
        #expect(budget.snapshot.reservedBytes > 0)

        packer.retireSource()
        #expect(packer.retainedStorageByteCountForTesting == 0)
        #expect(budget.snapshot.reservedBytes == 0)
        for strategy in [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA] {
            var highWaterBytes = 0
            for _ in 0..<3 {
                snapshots.append(try checkedPrepare(
                    tinyInput(strategy: strategy),
                    packer: packer, highWaterBytes: &highWaterBytes
                ))
            }
        }
        for snapshot in snapshots {
            #expect(snapshot.frame.pixels == snapshot.expectedPixels)
        }
    }

    @Test(arguments: [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA])
    func clearMetricsIncludeThePreviousDirtyPrefixOnlyOnItsFirstReuse(
        strategy: SubtitleCompositionStrategy
    ) throws {
        let packer = makePacker()
        let large = sizedInput(strategy: strategy, large: true)
        let small = tinyInput(strategy: strategy)
        let largeBytes = try #require(prepare(large, using: makePacker())).metrics.uploadBytes
        let smallBytes = try #require(prepare(small, using: makePacker())).metrics.uploadBytes
        #expect(largeBytes > smallBytes)

        // A previously untouched slot allocates the historical high-water size,
        // even when the current frame is small. Both slots must be cleaned once.
        let inputs = [large, small, small, small, small]
        let expectedClears = [largeBytes, largeBytes, largeBytes, smallBytes, smallBytes]
        let expectedGrowth = [true, false, false, false, false]
        for index in inputs.indices {
            let frame = try #require(prepare(inputs[index], using: packer))
            #expect(frame.pixels.count == largeBytes)
            #expect(frame.metrics.atlasClearBytes == expectedClears[index])
            #expect(frame.metrics.atlasReallocated == expectedGrowth[index])
            #expect(frame.metrics.uploadBytes == (index == 0 ? largeBytes : smallBytes))
        }
        #expect(packer.retainedStorageByteCountForTesting == 2 * largeBytes)
    }

    private func verifySequence(_ inputs: [Input], retainSnapshots: Bool) throws {
        let packer = makePacker()
        var highWaterBytes = 0
        var snapshots: [Snapshot] = []
        for input in inputs {
            let snapshot = try checkedPrepare(input, packer: packer, highWaterBytes: &highWaterBytes)
            if retainSnapshots {
                snapshots.append(snapshot)
            }
        }
        for snapshot in snapshots {
            #expect(snapshot.frame.pixels == snapshot.expectedPixels)
        }
    }

    /// A fresh packer provides current-frame pixels without any prior contents.
    /// Appending zeros expresses the full grow-only snapshot contract without
    /// duplicating the storage-reuse algorithm under test.
    private func checkedPrepare(
        _ input: Input,
        packer: ASSSubtitleFramePacker,
        highWaterBytes: inout Int
    ) throws -> Snapshot {
        let reference = try #require(prepare(input, using: makePacker()))
        let frame = try #require(prepare(input, using: packer))
        highWaterBytes = max(highWaterBytes, reference.pixels.count)
        var expectedPixels = reference.pixels
        expectedPixels.append(Data(count: highWaterBytes - expectedPixels.count))

        #expect(frame.strategy == reference.strategy)
        #expect(frame.canvasSize == reference.canvasSize)
        #expect(frame.textureSize == reference.textureSize)
        #expect(frame.bytesPerRow == reference.bytesPerRow)
        #expect(frame.quads == reference.quads)
        #expect(frame.usesBitmapAtlas == reference.usesBitmapAtlas)
        #expect(frame.metrics.imageCount == reference.metrics.imageCount)
        #expect(frame.metrics.copiedBytes == reference.metrics.copiedBytes)
        #expect(frame.metrics.uploadBytes == reference.metrics.uploadBytes)
        #expect(frame.metrics.drawCalls == reference.metrics.drawCalls)
        #expect(frame.pixels == expectedPixels)
        return Snapshot(frame: frame, expectedPixels: expectedPixels)
    }

    private func prepare(_ input: Input, using packer: ASSSubtitleFramePacker) -> ASSPreparedSubtitleFrame? {
        packer.prepare(regions: input.regions, canvasSize: input.canvasSize, strategy: input.strategy)
    }

    private func makePacker(memoryBudget: SubtitleMemoryBudget? = nil) -> ASSSubtitleFramePacker {
        ASSSubtitleFramePacker(
            maximumTextureDimension: 512, atlasPadding: 2, memoryBudget: memoryBudget
        )
    }

    private func sizedInput(strategy: SubtitleCompositionStrategy, large: Bool) -> Input {
        switch strategy {
        case .metalR8Atlas:
            Input(regions: [region(width: large ? 92 : 60, height: 60, value: 83)])
        case .metalBGRA:
            Input(
                regions: [region(width: 31, height: 31, value: 107)],
                canvasSize: CGSize(width: large ? 64 : 32, height: 32), strategy: strategy
            )
        }
    }

    private func tinyInput(strategy: SubtitleCompositionStrategy) -> Input {
        Input(
            regions: [region(width: 1, height: 1, value: 199)],
            canvasSize: CGSize(width: 8, height: 8), strategy: strategy
        )
    }

    private func region(
        width: Int,
        height: Int,
        value: UInt8,
        bitmap: Bool = false,
        x: Int = 0,
        y: Int = 0,
        color: UInt32 = 0xFFFFFF00
    ) -> ASSRenderedRegion {
        let bytesPerPixel = bitmap ? 4 : 1
        let stride = width * bytesPerPixel + 5
        var bytes = Data(repeating: 0xFE, count: stride * height)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * stride + column * bytesPerPixel
                for channel in 0..<bytesPerPixel {
                    bytes[offset + channel] = channel == 3 ? 255 : UInt8(
                        truncatingIfNeeded: Int(value) + row * 11 + column * 7 + channel * 13
                    )
                }
            }
        }
        return ASSRenderedRegion(
            bitmap: bytes, color: color,
            frame: CGRect(x: x, y: y, width: width, height: height), stride: stride,
            isPremultipliedBGRA: bitmap
        )
    }
}
