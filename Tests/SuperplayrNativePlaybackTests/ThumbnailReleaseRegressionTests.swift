import CoreGraphics
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Release thumbnail decoding", .serialized)
struct ThumbnailReleaseRegressionTests {
    @Test(arguments: ["h264-long-gop.mp4", "hevc10-long-gop.mkv"])
    func stableHoverDecodesPastKeyframe(filename: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_FIXTURES"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        let generator = NativeTimelineThumbnailGenerator()
        for target in [3.5, 1.5, 0.0] {
            let image = try #require(await generator.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208)))
            #expect(image.width > 0 && image.width <= 368)
            #expect(image.height > 0 && image.height <= 208)
            let cached = await generator.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208))
            #expect(cached === image)
        }
    }
}
