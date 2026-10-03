import Foundation
import Testing
@testable import SuperplayrCore

@Suite("Playback tool geometry and time input")
struct PlaybackToolsTests {
    @Test func fitFillAndCropUseConsistentImageAndClipCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let source = CGSize(width: 1920, height: 1080)
        let fit = VideoPresentationGeometry(sourceSize: source, bounds: bounds)
        #expect(fit.imageRect == CGRect(x: 0, y: 45, width: 1440, height: 810))
        var settings = VideoAdjustmentState.standard
        settings.scaleMode = .fill
        let fill = VideoPresentationGeometry(sourceSize: source, bounds: bounds, adjustments: settings)
        #expect(fill.imageRect == CGRect(x: -80, y: 0, width: 1600, height: 900))
        #expect(fill.clipRect == bounds)
        settings.scaleMode = .fit; settings.crop = "1:1"
        let crop = VideoPresentationGeometry(sourceSize: CGSize(width: 200, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100), adjustments: settings)
        #expect(crop.imageRect == CGRect(x: -50, y: 0, width: 200, height: 100))
        #expect(crop.clipRect == CGRect(x: 0, y: 0, width: 100, height: 100))
        settings.crop = nil; settings.aspectRatio = "4:3"
        let aspect = VideoPresentationGeometry(sourceSize: source, bounds: bounds, adjustments: settings)
        #expect(aspect.imageRect.width == 1200)
        #expect(aspect.imageRect.height == 900)
    }

    @Test func parsesBoundedTimeWithoutSilentlyReinterpretingInvalidInput() {
        #expect(PlaybackTimeInput.seconds(" 1:02:03.25 ", duration: 4000) == 3723.25)
        #expect(PlaybackTimeInput.seconds("90:00", duration: 6000) == 5400)
        #expect(PlaybackTimeInput.seconds("2.5", duration: 3) == 2.5)
        for text in ["", "NaN", "inf", "1e2", "-1", "1:60", "1::2", "1.5:00", "1:00:60", "3.01", "１２"] {
            #expect(PlaybackTimeInput.seconds(text, duration: 3) == nil, "\(text)")
        }
        #expect(PlaybackTimeInput.seconds("1", duration: .infinity) == nil)
        #expect(VideoPresentationGeometry.ratio("16:0") == nil)
        #expect(VideoPresentationGeometry.ratio("nan") == nil)
    }
}
