import CoreGraphics
import Foundation

enum SubtitleGeometry {
    static func scale(
        point: CGPoint,
        storageSize: CGSize,
        viewport: CGRect
    ) -> CGPoint {
        guard storageSize.width > 0, storageSize.height > 0 else {
            return viewport.origin
        }
        return CGPoint(
            x: viewport.minX + point.x * viewport.width / storageSize.width,
            y: viewport.minY + point.y * viewport.height / storageSize.height
        )
    }
}
