// Standalone benchmark support only. On macOS, images and SHA256 are real
// CoreGraphics/CryptoKit types. Disk/identity services are never reached because
// every cache has directory:nil and diskMiB:0. No playback or disk-I/O claim.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import CryptoKit
import Darwin
#else
import Glibc
final class CGImage: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let token: Int
    init(width: Int, height: Int, token: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.token = token
    }
}
enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        preconditionFailure("Disk digests are outside this benchmark")
    }
}
#endif

func makeImage(width: Int = 320, height: Int = 180, token: Int) -> CGImage {
    #if canImport(CoreGraphics)
    var data = Data(repeating: 0, count: width * height * 4)
    for index in 0..<4 { data[index] = UInt8(truncatingIfNeeded: token >> (8 * index)) }
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    #else
    return CGImage(width: width, height: height, token: token)
    #endif
}

func imageToken(_ image: CGImage) -> Int {
    #if canImport(CoreGraphics)
    let data = image.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    return (0..<4).reduce(0) { $0 | (Int(bytes[$1]) << (8 * $1)) }
    #else
    return image.token
    #endif
}

func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

struct NativeFileContentVersion {
    let fileIdentifier: Int = 0, byteCount: Int = 0
    let modificationSeconds: Int = 0, modificationNanoseconds: Int = 0
    let creationSeconds: Int = 0, creationNanoseconds: Int = 0
    static func read(_ url: URL) -> Self? {
        preconditionFailure("Identity reads are outside this benchmark")
    }
}
actor ThumbnailBlockingReader<Value: Sendable> {
    func read(_ operation: @Sendable () -> Value?) async -> Value? { operation() }
}
actor NativeThumbnailDiskCache {
    init(directory: URL?, encode: (@Sendable (CGImage) async -> Data?)? = nil) {
        precondition(directory == nil)
    }
    func configure(_ value: ThumbnailPreferences) { precondition(value.diskMiB == 0) }
    func image(for key: NativeThumbnailCache.Key, background: Bool) -> CGImage? {
        preconditionFailure("Disk reads are outside this benchmark")
    }
    nonisolated func enqueuePromotion(_ key: NativeThumbnailCache.Key, epoch: UInt64) -> Bool {
        preconditionFailure("Disk promotions are outside this benchmark")
    }
    func flushPromotions() {}
    func promote(_ key: NativeThumbnailCache.Key, epoch: UInt64) {
        preconditionFailure("Disk promotions are outside this benchmark")
    }
    func insert(_ image: CGImage, for key: NativeThumbnailCache.Key, background: Bool, epoch: UInt64) {
        preconditionFailure("Disk writes are outside this benchmark")
    }
    func clear(epoch: UInt64) -> Bool { true }
    func bytes() -> Int { 0 }
}
