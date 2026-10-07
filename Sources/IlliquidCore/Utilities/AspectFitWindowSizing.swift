import Foundation

public enum AspectFitWindowSizing {
    /// Returns the largest video viewport with the requested aspect ratio that
    /// fits inside the current viewport without enlarging the window. The
    /// non-video portion of the window (including a visible sidebar) is kept.
    public static func fittedWindowSize(
        currentWindowSize: CGSize,
        currentVideoViewportSize: CGSize,
        minimumWindowSize: CGSize,
        videoAspectRatio: Double
    ) -> CGSize? {
        guard currentWindowSize.width > 0,
              currentWindowSize.height > 0,
              currentVideoViewportSize.width > 0,
              currentVideoViewportSize.height > 0,
              videoAspectRatio.isFinite,
              videoAspectRatio > 0
        else { return nil }

        let horizontalOverhead = max(0, currentWindowSize.width - currentVideoViewportSize.width)
        let verticalOverhead = max(0, currentWindowSize.height - currentVideoViewportSize.height)
        let maximumScale = min(
            currentVideoViewportSize.width / videoAspectRatio,
            currentVideoViewportSize.height
        )

        let minimumViewportWidth = max(0, minimumWindowSize.width - horizontalOverhead)
        let minimumViewportHeight = max(0, minimumWindowSize.height - verticalOverhead)
        let minimumScale = max(
            minimumViewportWidth / videoAspectRatio,
            minimumViewportHeight
        )

        guard maximumScale + 0.5 >= minimumScale else { return nil }

        return CGSize(
            width: horizontalOverhead + videoAspectRatio * maximumScale,
            height: verticalOverhead + maximumScale
        )
    }
}
