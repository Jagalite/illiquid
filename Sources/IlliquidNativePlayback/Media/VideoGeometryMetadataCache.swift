import CoreVideo
import Foundation

/// Reuses immutable attachment values while still applying them to every buffer.
/// VideoDecoder owns this bounded cache on its decode worker.
final class VideoGeometryMetadataCache {
    private var pixelAspectCache: (size: CGSize, attachment: CFDictionary)?
    private var cleanApertureCache: (key: CleanApertureKey, attachment: CFDictionary)?

    private struct CleanApertureKey: Equatable {
        let width: Int
        let height: Int
        let horizontalOffsetBits: UInt64
        let verticalOffsetBits: UInt64

        init(width: Int, height: Int, horizontalOffset: Double, verticalOffset: Double) {
            self.width = width
            self.height = height
            // Preserve the exact numeric values, including signed zero, rather
            // than letting floating-point equality merge distinct bit patterns.
            horizontalOffsetBits = horizontalOffset.bitPattern
            verticalOffsetBits = verticalOffset.bitPattern
        }
    }

    func applyPixelAspectMetadata(pixelBuffer: CVPixelBuffer, pixelAspect: CGSize) {
        guard pixelAspect.width.isFinite, pixelAspect.height.isFinite,
              pixelAspect.width > 0, pixelAspect.height > 0
        else {
            return
        }
        let attachment: CFDictionary
        if let cached = pixelAspectCache, cached.size == pixelAspect {
            attachment = cached.attachment
        } else {
            let value: [CFString: Any] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(pixelAspect.width.rounded()),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(pixelAspect.height.rounded()),
            ]
            attachment = value as CFDictionary
            pixelAspectCache = (pixelAspect, attachment)
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            attachment,
            .shouldPropagate
        )
    }

    func applyCleanApertureMetadata(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        horizontalOffset: Double,
        verticalOffset: Double
    ) {
        let key = CleanApertureKey(
            width: width,
            height: height,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
        let attachment: CFDictionary
        if let cached = cleanApertureCache, cached.key == key {
            attachment = cached.attachment
        } else {
            let aperture: [CFString: Any] = [
                kCVImageBufferCleanApertureWidthKey: width,
                kCVImageBufferCleanApertureHeightKey: height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: horizontalOffset,
                kCVImageBufferCleanApertureVerticalOffsetKey: verticalOffset,
            ]
            attachment = aperture as CFDictionary
            cleanApertureCache = (key, attachment)
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCleanApertureKey,
            attachment,
            .shouldPropagate
        )
    }
}
