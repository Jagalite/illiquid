import Foundation

struct ASSRenderedRegion: Sendable {
    let bitmap: Data
    let color: UInt32
    let frame: CGRect
    let stride: Int
    let bitmapSize: CGSize?
    let isPremultipliedBGRA: Bool
    let memoryLease: SubtitleMemoryBudget.Lease?

    init(
        bitmap: Data,
        color: UInt32,
        frame: CGRect,
        stride: Int,
        bitmapSize: CGSize? = nil,
        isPremultipliedBGRA: Bool = false,
        memoryLease: SubtitleMemoryBudget.Lease? = nil
    ) {
        self.bitmap = bitmap
        self.color = color
        self.frame = frame
        self.stride = stride
        self.bitmapSize = bitmapSize
        self.isPremultipliedBGRA = isPremultipliedBGRA
        self.memoryLease = memoryLease
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ASSRenderedRegion {
        ASSRenderedRegion(
            bitmap: bitmap,
            color: color,
            frame: frame.offsetBy(dx: dx, dy: dy),
            stride: stride,
            bitmapSize: bitmapSize,
            isPremultipliedBGRA: isPremultipliedBGRA,
            memoryLease: memoryLease
        )
    }
}

