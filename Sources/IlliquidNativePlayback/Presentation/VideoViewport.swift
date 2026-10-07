import CoreGraphics
import Foundation

enum VideoViewport {
    static func aspectFit(
        displaySize: CGSize,
        in bounds: CGRect
    ) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return .zero }

        let scale = min(
            bounds.width / displaySize.width,
            bounds.height / displaySize.height
        )
        let size = CGSize(
            width: displaySize.width * scale,
            height: displaySize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
