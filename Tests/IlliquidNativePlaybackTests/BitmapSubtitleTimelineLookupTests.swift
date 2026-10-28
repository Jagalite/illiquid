import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle timestamp search boundaries")
struct BitmapSubtitleTimelineLookupTests {
    @Test(arguments: [0, 1, 2, 3, 7, 8, 15, 31, 32, 63, 127, 128])
    func lookupAndPruningMatchLinearBoundaries(count: Int) throws {
        let starts = (0..<count).map { Double($0) * 2 - 8 }
        var timeline = BitmapSubtitleTimeline(maximumEntries: max(1, count), maximumBytes: max(1, count * 4))
        for (index, start) in starts.enumerated() {
            let display = NativeBitmapSubtitleComposition(
                regions: [NativeBitmapSubtitleRegion(
                    pixels: Data([UInt8(index), 0, 0, 255]),
                    frame: CGRect(x: 0, y: 0, width: 1, height: 1), isForced: false
                )],
                canvasSize: CGSize(width: 1920, height: 1080), duration: nil, memoryLease: nil
            )
            try #require(timeline.insert(display, at: start, generation: 0))
        }
        var queries: [Double] = [.nan, -.infinity, .infinity, -100, -0.0, 0.0, 1_000]
        for start in starts { queries += [start.nextDown, start, start.nextUp] }
        for query in queries {
            let expected = query.isFinite ? starts.lastIndex(where: { $0 <= query }) : nil
            let selected = timeline.composition(at: query)
            #expect(selected?.start.bitPattern == expected.map { starts[$0].bitPattern })
            #expect(selected?.value.regions.first?.pixels.first == expected.map { UInt8($0) })

            var pruned = timeline
            let revision = pruned.revision
            // Pruning deliberately accepts +infinity, unlike presentation.
            let preceding = starts.lastIndex(where: { $0 <= query })
            let removed = preceding ?? 0
            pruned.prune(before: query)
            #expect(pruned.revision == revision)
            #expect(pruned.retainedBytes == (count - removed) * 4)
            for (index, start) in starts.enumerated() {
                let remaining = pruned.composition(at: start)
                if index < removed {
                    #expect(remaining == nil)
                } else {
                    #expect(remaining?.start.bitPattern == start.bitPattern)
                    #expect(remaining?.value.regions.first?.pixels.first == UInt8(index))
                }
            }
            #expect(timeline.retainedBytes == count * 4) // Pruning a value copy is isolated.
        }
    }

    @Test func expiryAndClearAtSearchBoundariesDoNotResurrectAnOlderSet() throws {
        var timeline = BitmapSubtitleTimeline()
        func display(_ marker: UInt8, duration: Double? = nil, clear: Bool = false)
            -> NativeBitmapSubtitleComposition {
            NativeBitmapSubtitleComposition(
                regions: clear ? [] : [NativeBitmapSubtitleRegion(
                    pixels: Data([marker, 0, 0, 255]),
                    frame: CGRect(x: 0, y: 0, width: 1, height: 1), isForced: false
                )],
                canvasSize: CGSize(width: 1920, height: 1080), duration: duration, memoryLease: nil
            )
        }
        for index in 0..<128 {
            let duration: Double? = index == 0 || index == 64 || index == 127 ? 0.5 : nil
            try #require(timeline.insert(display(UInt8(index), duration: duration, clear: index == 32),
                                         at: Double(index), generation: 0))
        }
        for index in [0, 64, 127] {
            let expiry = Double(index) + 0.5
            #expect(timeline.composition(at: expiry.nextDown)?.start == Double(index))
            #expect(timeline.composition(at: expiry) == nil)
            #expect(timeline.composition(at: expiry.nextUp) == nil)
        }
        #expect(timeline.composition(at: 32)?.value.regions.isEmpty == true)
        #expect(timeline.composition(at: 32.5)?.value.regions.isEmpty == true)
        #expect(timeline.composition(at: 33)?.value.regions.first?.pixels.first == 33)
    }
}
