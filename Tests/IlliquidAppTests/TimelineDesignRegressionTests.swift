import Foundation
import Testing
@testable import IlliquidApp

@Suite("Timeline design regressions")
struct TimelineDesignRegressionTests {
    @Test func straightTrackRetainsSubSamplePrecision() {
        let geometry = makeGeometry(length: 940, count: 7)
        for fraction: CGFloat in [0, 0.0001, 0.123456, 0.5033, 0.9999, 1] {
            let actual = geometry.timelineFraction(at: geometry.pointOnTrack(fraction: fraction), maximumDistance: 1)
            #expect(abs((actual ?? -1) - fraction) < 0.000001)
        }
    }

    @Test func curvedAndRotatedTracksRetainPrecision() {
        for orientation in [ElasticPlaybackControlBarOrientation.right, .down, .left, .up] {
            let geometry = ElasticPlaybackControlBarGeometry(
                containerSize: CGSize(width: 900, height: 600),
                center: CGPoint(x: 160, y: 160), utilityCount: 3,
                bendDirection: .up, orientation: orientation)
            for fraction: CGFloat in [0.001, 0.123456, 0.5033, 0.7777, 0.999] {
                let actual = geometry.timelineFraction(at: geometry.pointOnTrack(fraction: fraction), maximumDistance: 1)
                #expect(abs((actual ?? -1) - fraction) < 0.0001)
            }
        }
    }

    @Test func rejectsInvalidAndDistantPointerLocations() {
        let geometry = makeGeometry(length: 628, count: 7)
        #expect(geometry.timelineFraction(at: CGPoint(x: CGFloat.nan, y: 0), maximumDistance: 22) == nil)
        #expect(geometry.timelineFraction(at: .zero, maximumDistance: -1) == nil)
        #expect(geometry.timelineFraction(at: CGPoint(x: -1000, y: -1000), maximumDistance: 22) == nil)
    }

    @Test func everyCompactTierPreservesUsefulTrackLength() {
        let all: [ElasticPlaybackUtility] = [.volume, .audio, .subtitles, .sidebar, .pictureInPicture, .settings, .more]
        for available in [all, all.filter { $0 != .pictureInPicture }] {
            for length in 320...940 {
                let fitted = ElasticPlaybackUtility.fitting(available, length: CGFloat(length))
                let geometry = makeGeometry(length: CGFloat(length), count: fitted.count)
                #expect(abs(geometry.totalLength - CGFloat(length)) < 0.001)
                #expect(fitted.contains(.more))
                #expect(geometry.trackEndS - geometry.trackStartS >= 160 - 0.001)
                #expect(!geometry.containsDragHandle(geometry.pointOnTrack(fraction: 0)))
                if geometry.showsDurationLabel {
                    #expect(geometry.trackEndS <= geometry.durationLabelS - 38 + 0.001)
                } else {
                    #expect(geometry.trackEndS <= geometry.timelineEndS)
                }
            }
        }
    }

    @Test func gripHitAreaFollowsBarOrientation() {
        for orientation in [ElasticPlaybackControlBarOrientation.right, .down, .left, .up] {
            let geometry = ElasticPlaybackControlBarGeometry(
                containerSize: CGSize(width: 900, height: 600),
                center: CGPoint(x: 450, y: 300), utilityCount: 3,
                bendDirection: .up, orientation: orientation)
            #expect(geometry.containsDragHandle(geometry.point(at: geometry.dragHandleS)))
            #expect(!geometry.containsDragHandle(geometry.pointOnTrack(fraction: 0.5)))
            #expect(!geometry.containsDragHandle(geometry.utilityPositions.last!))
        }
    }

    private func makeGeometry(length: CGFloat, count: Int) -> ElasticPlaybackControlBarGeometry {
        let vertical = length < 420
        let size = vertical
            ? CGSize(width: 1200, height: length + ElasticPlaybackControlBarGeometry.topInset
                + ElasticPlaybackControlBarGeometry.bottomInset + ElasticPlaybackControlBarGeometry.thickness)
            : CGSize(width: length + 92, height: 1200)
        return ElasticPlaybackControlBarGeometry(containerSize: size,
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            utilityCount: count, bendDirection: .up, orientation: vertical ? .down : .right)
    }
}
