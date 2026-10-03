import CoreImage
import CoreVideo
import ImageIO
import Foundation
import SuperplayrCore
import UniformTypeIdentifiers

struct NativeScreenshot: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let displaySize: CGSize
    let rotation: Double
    let mirrored: Bool
    let size: CGSize
    let adjustments: VideoAdjustmentState
    let regions: [ASSRenderedRegion]

    /// PNG is explicitly SDR sRGB. HDR tone mapping happens before compositing
    /// SDR subtitle colors, and source HDR metadata is not copied into the file.
    func png() throws -> Data {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1, size.width <= 8192, size.height <= 8192 else {
            throw PresentationError("Screenshot dimensions are unavailable or too large.")
        }
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 33_554_432,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PresentationError("Screenshot dimensions are unavailable or too large.")
        }
        let bounds = CGRect(origin: .zero, size: size)
        let geometry = VideoPresentationGeometry(sourceSize: displaySize, bounds: bounds, adjustments: adjustments)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(bounds)
        var image = CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true])
        let clean = CVImageBufferGetCleanRect(buffer).intersection(image.extent)
        if !clean.isEmpty { image = image.cropped(to: clean) }
        var transform = CGAffineTransform(rotationAngle: rotation * .pi / 180)
        if mirrored { transform = transform.scaledBy(x: -1, y: 1) }
        image = image.transformed(by: transform)
        let renderer = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = renderer.createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: space) else { throw PresentationError("Could not read the displayed video image.") }
        context.clip(to: geometry.clipRect)
        context.draw(cgImage, in: geometry.imageRect)
        for region in regions {
            let bitmapSize = region.bitmapSize ?? region.frame.size
            guard bitmapSize.width.isFinite, bitmapSize.height.isFinite,
                  bitmapSize.width >= 1, bitmapSize.height >= 1,
                  bitmapSize.width <= 8192, bitmapSize.height <= 8192 else { continue }
            let w = Int(bitmapSize.width), h = Int(bitmapSize.height)
            guard w > 0, h > 0, w <= 8192, h <= 8192,
                  w * h <= 16_777_216,
                  region.stride >= w * (region.isPremultipliedBGRA ? 4 : 1),
                  region.stride <= region.bitmap.count / h else { continue }
            let bytes: Data
            let stride: Int
            let info: UInt32
            if region.isPremultipliedBGRA {
                bytes = region.bitmap; stride = region.stride
                info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            } else {
                var rgba = Data(count: w * h * 4)
                rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                    region.bitmap.withUnsafeBytes { (mask: UnsafeRawBufferPointer) in
                        for y in 0..<h { for x in 0..<w {
                            let a = UInt32(mask[y * region.stride + x]) * (255 - (region.color & 255)) / 255
                            let i = (y * w + x) * 4
                            out[i] = UInt8(((region.color >> 24) & 255) * a / 255)
                            out[i + 1] = UInt8(((region.color >> 16) & 255) * a / 255)
                            out[i + 2] = UInt8(((region.color >> 8) & 255) * a / 255)
                            out[i + 3] = UInt8(a)
                        } }
                    }
                }
                bytes = rgba; stride = w * 4; info = CGImageAlphaInfo.premultipliedLast.rawValue
            }
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let overlay = CGImage(width: w, height: h, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: stride, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            let rect = CGRect(x: region.frame.minX, y: size.height - region.frame.maxY,
                width: region.frame.width, height: region.frame.height)
            context.draw(overlay, in: rect)
        }
        guard let result = context.makeImage() else { throw PresentationError("Could not compose the screenshot.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PresentationError("Could not create PNG output.")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw PresentationError("Could not encode PNG output.") }
        return data as Data
    }
}
