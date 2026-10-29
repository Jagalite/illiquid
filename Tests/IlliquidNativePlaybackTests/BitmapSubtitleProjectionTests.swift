import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle region projection")
struct BitmapSubtitleProjectionTests {
    @Test(arguments: [false, true])
    func preservesPayloadOrderAndAllRenderedFields(forcedOnly: Bool) throws {
        let firstBytes = Data([0, 1, 127, 128, 254, 255, 2, 3])
        let middleBytes = Data([255, 0, 64, 128])
        let lastBytes = Data([9, 8, 7, 6, 5, 4, 3, 2])
        let regions = [
            NativeBitmapSubtitleRegion(pixels: firstBytes,
                frame: CGRect(x: 4, y: 5, width: 2, height: 1), isForced: true),
            NativeBitmapSubtitleRegion(pixels: middleBytes,
                frame: CGRect(x: -2, y: 10, width: 1, height: 1), isForced: false),
            NativeBitmapSubtitleRegion(pixels: lastBytes,
                frame: CGRect(x: 40, y: 20, width: 1, height: 2), isForced: true),
        ]
        let composition = projectionComposition(regions)
        let rendered = composition.renderedRegions(
            in: CGRect(x: 10, y: -20, width: 100, height: 300),
            forcedOnly: forcedOnly
        )
        #expect(rendered.count == (forcedOnly ? 2 : 3))
        let first = try #require(rendered.first)
        let last = try #require(rendered.last)
        #expect(first.bitmap == firstBytes)
        #expect(first.frame == CGRect(x: 12, y: -5, width: 1, height: 3))
        #expect(first.stride == 8)
        #expect(first.bitmapSize == CGSize(width: 2, height: 1))
        #expect(last.bitmap == lastBytes)
        #expect(last.frame == CGRect(x: 30, y: 40, width: 0.5, height: 6))
        #expect(last.stride == 4)
        #expect(last.bitmapSize == CGSize(width: 1, height: 2))
        if !forcedOnly {
            #expect(rendered[1].bitmap == middleBytes)
            #expect(rendered[1].frame == CGRect(x: 9, y: 10, width: 0.5, height: 3))
            #expect(rendered[1].stride == 4)
            #expect(rendered[1].bitmapSize == CGSize(width: 1, height: 1))
        }
        for region in rendered {
            #expect(region.color == 0)
            #expect(region.isPremultipliedBGRA)
            #expect(region.memoryLease == nil)
        }
        #expect(composition.regions.map(\.pixels) == [firstBytes, middleBytes, lastBytes])
    }

    @Test(arguments: [0, 1, 2, 64, 256])
    func forcedSelectionPreservesAllNoneAndAlternatingSubsequences(count: Int) {
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 100)
        for pattern in 0..<3 {
            let regions = (0..<count).map { index in
                NativeBitmapSubtitleRegion(
                    pixels: Data([UInt8(index & 255), UInt8(index >> 8), 128, 255]),
                    frame: CGRect(x: index, y: 0, width: 1, height: 1),
                    isForced: pattern == 0 || (pattern == 2 && index.isMultiple(of: 2))
                )
            }
            let composition = projectionComposition(regions)
            let all = composition.renderedRegions(in: viewport)
            let forced = composition.renderedRegions(in: viewport, forcedOnly: true)
            let expectedIndices = pattern == 0 ? Array(0..<count)
                : pattern == 1 ? [] : Array(stride(from: 0, to: count, by: 2))
            #expect(all.map(\.bitmap) == regions.map(\.pixels))
            #expect(forced.map(\.bitmap) == expectedIndices.map { regions[$0].pixels })
            #expect(forced.map(\.frame) == expectedIndices.map { regions[$0].frame })
            #expect(all.allSatisfy { $0.stride == 4 && $0.color == 0 && $0.isPremultipliedBGRA })
        }
    }

    @Test func fractionalRegionDimensionsKeepOriginalBitmapSizeAndTruncatedStride() throws {
        let region = NativeBitmapSubtitleRegion(
            pixels: Data([1, 2, 3, 4]),
            frame: CGRect(x: 2.5, y: 1.25, width: 1.75, height: 2.5),
            isForced: false
        )
        let rendered = try #require(projectionComposition([region]).renderedRegions(
            in: CGRect(x: -4, y: 6, width: 400, height: 50)
        ).first)
        #expect(rendered.frame == CGRect(x: 1, y: 6.625, width: 3.5, height: 1.25))
        #expect(rendered.bitmapSize == CGSize(width: 1.75, height: 2.5))
        #expect(rendered.stride == 4)
        #expect(rendered.bitmap == region.pixels)
    }

    @Test func zeroViewportSizeCollapsesGeometryWithoutDiscardingRegions() throws {
        let region = NativeBitmapSubtitleRegion(pixels: Data([1, 2, 3, 4]),
            frame: CGRect(x: 4, y: 5, width: 1, height: 1), isForced: true)
        let rendered = try #require(projectionComposition([region]).renderedRegions(
            in: CGRect(x: 7, y: -3, width: 0, height: 0)
        ).first)
        #expect(rendered.frame == CGRect(x: 7, y: -3, width: 0, height: 0))
        #expect(rendered.bitmapSize == CGSize(width: 1, height: 1))
        #expect(rendered.stride == 4)
        #expect(rendered.bitmap == region.pixels)
    }

    @Test func nonpositiveOrNaNCanvasReturnsNoRegions() {
        let region = NativeBitmapSubtitleRegion(pixels: Data([1, 2, 3, 4]),
            frame: CGRect(x: 4, y: 5, width: 1, height: 1), isForced: true)
        for invalid in [CGFloat(0), -0.0, -1, -.infinity, .nan] {
            for canvas in [CGSize(width: invalid, height: 100), CGSize(width: 200, height: invalid)] {
                let composition = projectionComposition([region], canvas: canvas)
                for forcedOnly in [false, true] {
                    #expect(composition.renderedRegions(
                        in: CGRect(x: 0, y: 0, width: 100, height: 100),
                        forcedOnly: forcedOnly
                    ).isEmpty)
                }
            }
        }
    }

    @Test func positiveInfiniteCanvasKeepsExistingPermissiveBehavior() throws {
        let region = NativeBitmapSubtitleRegion(pixels: Data([1, 2, 3, 4]),
            frame: CGRect(x: 4, y: 5, width: 1, height: 1), isForced: true)
        let viewport = CGRect(x: 10, y: -20, width: 100, height: 300)
        let cases: [(CGSize, CGRect)] = [
            (CGSize(width: CGFloat.infinity, height: 100), CGRect(x: 10, y: -5, width: 0, height: 3)),
            (CGSize(width: 200, height: CGFloat.infinity), CGRect(x: 12, y: -20, width: 0.5, height: 0)),
            (CGSize(width: CGFloat.infinity, height: CGFloat.infinity), CGRect(x: 10, y: -20, width: 0, height: 0)),
        ]
        for (canvas, expected) in cases {
            for forcedOnly in [false, true] {
                let rendered = try #require(projectionComposition([region], canvas: canvas)
                    .renderedRegions(in: viewport, forcedOnly: forcedOnly).first)
                #expect(rendered.frame == expected)
                #expect(rendered.bitmap == region.pixels)
                #expect(rendered.stride == 4)
                #expect(rendered.bitmapSize == CGSize(width: 1, height: 1))
            }
        }
    }

    @Test func nonfiniteViewportDoesNotAddANewRejectionPolicy() throws {
        let region = NativeBitmapSubtitleRegion(pixels: Data([1, 2, 3, 4]),
            frame: CGRect(x: 4, y: 5, width: 1, height: 1), isForced: true)
        for width in [CGFloat.nan, .infinity] {
            let rendered = try #require(projectionComposition([region]).renderedRegions(
                in: CGRect(x: 0, y: 0, width: width, height: 100)
            ).first)
            if width.isNaN {
                #expect(rendered.frame.size.width.isNaN)
            } else {
                #expect(rendered.frame.size.width == .infinity)
            }
            #expect(rendered.bitmap == region.pixels)
            #expect(rendered.stride == 4)
            #expect(rendered.isPremultipliedBGRA)
        }
    }

    @Test func separateCallsAndValueCopiesRemainIndependent() throws {
        let first = NativeBitmapSubtitleRegion(pixels: Data(repeating: 0x80, count: 32),
            frame: CGRect(x: 4, y: 5, width: 4, height: 2), isForced: true)
        let second = NativeBitmapSubtitleRegion(pixels: Data(repeating: 0xff, count: 32),
            frame: CGRect(x: 8, y: 10, width: 4, height: 2), isForced: false)
        let composition = projectionComposition([first, second])
        var original = composition.renderedRegions(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        let retainedCopy = original
        let forced = composition.renderedRegions(
            in: CGRect(x: 10, y: 20, width: 400, height: 200), forcedOnly: true
        )
        let again = composition.renderedRegions(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        original.removeAll()
        #expect(retainedCopy.map(\.bitmap) == [first.pixels, second.pixels])
        #expect(retainedCopy.map(\.frame) == [first.frame, second.frame])
        #expect(again.map(\.frame) == [first.frame, second.frame])
        #expect(forced.count == 1)
        #expect(forced.first?.frame == CGRect(x: 18, y: 30, width: 8, height: 4))
        var changedBytes = try #require(again.first?.bitmap)
        changedBytes[0] = 0
        #expect(first.pixels.first == 0x80)
        #expect(retainedCopy.first?.bitmap.first == 0x80)
        #expect(forced.first?.bitmap.first == 0x80)
        #expect(composition.regions.map(\.pixels) == [first.pixels, second.pixels])
    }

    @Test(arguments: [false, true])
    func projectedRegionsKeepTheOriginalLeaseUntilTheFinalCopyReleasesIt(forcedOnly: Bool) throws {
        let budget = SubtitleMemoryBudget(limitBytes: 128, ownerLimitsBytes: [:])
        var rendered = try projectWithScopedLease(budget: budget, forcedOnly: forcedOnly,
                                                 flags: [true, false, true])
        #expect(rendered.count == (forcedOnly ? 2 : 3))
        #expect(budget.snapshot.reservedBytes == 12)
        #expect(budget.snapshot.reservationsByOwner == [.bitmapEvents: 12])
        var copy = rendered
        rendered.removeAll()
        withExtendedLifetime(copy) {
            #expect(budget.snapshot.reservedBytes == 12)
        }
        copy.removeLast()
        withExtendedLifetime(copy) {
            #expect(budget.snapshot.reservedBytes == 12)
        }
        copy.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(budget.snapshot.rejectedAcquisitions == 0)
    }

    @Test func emptyAndRejectedResultsDoNotRetainTheCompositionLease() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 128, ownerLimitsBytes: [:])
        let noRegions = try projectWithScopedLease(budget: budget, forcedOnly: false, flags: [])
        #expect(noRegions.isEmpty)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        let noForcedRegions = try projectWithScopedLease(
            budget: budget, forcedOnly: true, flags: [false, false]
        )
        #expect(noForcedRegions.isEmpty)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        let invalidCanvas = try projectWithScopedLease(
            budget: budget, forcedOnly: false, flags: [true, true], canvas: .zero
        )
        #expect(invalidCanvas.isEmpty)
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(budget.snapshot.rejectedAcquisitions == 0)
    }
}

private func projectionComposition(
    _ regions: [NativeBitmapSubtitleRegion],
    canvas: CGSize = CGSize(width: 200, height: 100)
) -> NativeBitmapSubtitleComposition {
    NativeBitmapSubtitleComposition(regions: regions, canvasSize: canvas,
                                    duration: nil, memoryLease: nil)
}

// The non-inlined scope proves the source composition and its local lease are
// gone when the caller inspects the lifetime of the returned region array.
@inline(never)
private func projectWithScopedLease(
    budget: SubtitleMemoryBudget,
    forcedOnly: Bool,
    flags: [Bool],
    canvas: CGSize = CGSize(width: 200, height: 100)
) throws -> [ASSRenderedRegion] {
    let lease = try #require(budget.acquire(owner: .bitmapEvents, bytes: flags.count * 4))
    let regions = flags.enumerated().map { index, forced in
        NativeBitmapSubtitleRegion(pixels: Data([UInt8(index), 127, 128, 255]),
            frame: CGRect(x: index, y: 0, width: 1, height: 1), isForced: forced)
    }
    let composition = NativeBitmapSubtitleComposition(regions: regions, canvasSize: canvas,
        duration: 3, memoryLease: lease)
    let rendered = composition.renderedRegions(
        in: CGRect(x: 0, y: 0, width: 200, height: 100), forcedOnly: forcedOnly
    )
    #expect(rendered.allSatisfy { $0.memoryLease === lease })
    return rendered
}
