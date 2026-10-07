import CFFmpeg
import Foundation

/// Public PGS composition metadata omitted from FFmpeg's AVSubtitleRect output.
/// The pinned decoder emits one full object rectangle per composition reference,
/// in order. Pixel decoding remains entirely in FFmpeg.
struct PGSSubtitlePresentation {
    struct Crop {
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32
    }
    struct Object {
        let x: Int32
        let y: Int32
        let crop: Crop?
    }
    let objects: [Object]

    static func update(in data: Data) throws -> Self? {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func word(_ offset: Int) -> Int32 { Int32(bytes[offset]) * 256 + Int32(bytes[offset + 1]) }
            var offset = 0
            var latest: Self?
            while offset < bytes.count {
                guard bytes.count - offset >= 3 else { throw invalid() }
                let kind = bytes[offset]
                let length = Int(word(offset + 1))
                offset += 3
                guard length <= bytes.count - offset else { throw invalid() }
                let end = offset + length
                if kind == 0x16 {
                    guard length >= 11 else { throw invalid() }
                    let width = word(offset), height = word(offset + 2)
                    guard width > 0, height > 0, width <= 8_192, height <= 8_192 else { throw invalid() }
                    let count = Int(bytes[offset + 10])
                    guard count <= 2 else { throw invalid() } // PGS / pinned decoder object-reference limit.
                    var cursor = offset + 11
                    var objects: [Object] = []
                    for _ in 0..<count {
                        guard end - cursor >= 8 else { throw invalid() }
                        let cropped = bytes[cursor + 3] & 0x80 != 0
                        let x = word(cursor + 4), y = word(cursor + 6)
                        guard x <= width, y <= height else { throw invalid() }
                        cursor += 8
                        var crop: Crop?
                        if cropped {
                            guard end - cursor >= 8 else { throw invalid() }
                            crop = Crop(x: word(cursor), y: word(cursor + 2), width: word(cursor + 4), height: word(cursor + 6))
                            cursor += 8
                        }
                        objects.append(Object(x: x, y: y, crop: crop))
                    }
                    latest = Self(objects: objects)
                }
                offset = end
            }
            return latest
        }
    }

    /// Returns a borrowed palette rectangle. Its backing storage remains owned
    /// by AVSubtitle; callers copy it before the next decoder operation.
    func rectangle(_ source: AVSubtitleRect, index: Int, count: Int) throws -> AVSubtitleRect {
        guard objects.count == count, objects.indices.contains(index) else { throw Self.invalid() }
        let object = objects[index]
        guard let crop = object.crop else { return source }
        guard source.type == SUBTITLE_BITMAP, source.x == object.x, source.y == object.y,
              source.w > 0, source.h > 0, source.linesize.0 >= source.w,
              crop.x <= source.w, crop.y <= source.h,
              crop.width <= source.w - crop.x, crop.height <= source.h - crop.y else {
            throw Self.invalid()
        }
        var result = source
        result.w = crop.width
        result.h = crop.height
        if crop.width > 0, crop.height > 0 {
            guard let pixels = source.data.0 else { throw Self.invalid() }
            result.data.0 = pixels.advanced(by: Int(crop.y) * Int(source.linesize.0) + Int(crop.x))
        }
        return result
    }

    private static func invalid() -> FFmpegError {
        FFmpegError(operation: "Read PGS composition geometry", code: illiquid_averror_invaliddata())
    }
}
