// TEST ONLY. The production cache body is unchanged apart from platform imports.
// These doubles validate actor/policy/ownership logic, NOT CoreGraphics, CryptoKit,
// ImageIO, real disk I/O, or the full macOS application.
import Foundation
final class CGImage: @unchecked Sendable {
    let bytesPerRow: Int
    let height: Int
    let token: Int
    init(bytesPerRow: Int, height: Int, token: Int = 0) {
        self.bytesPerRow = bytesPerRow; self.height = height; self.token = token
    }
}
enum SHA256 {
    static func hash(data: Data) -> [UInt8] { Array(0..<32) }
}
struct NativeFileContentVersion {
    let fileIdentifier: Int = 0, byteCount: Int = 0
    let modificationSeconds: Int = 0, modificationNanoseconds: Int = 0
    let creationSeconds: Int = 0, creationNanoseconds: Int = 0
    static func read(_ url: URL) -> Self? { nil }
}
actor ThumbnailBlockingReader<Value: Sendable> {
    func read(_ operation: @Sendable () -> Value?) async -> Value? { operation() }
}
actor NativeThumbnailDiskCache {
    init(directory: URL?, encode: (@Sendable (CGImage) async -> Data?)? = nil) {}
    func configure(_ value: ThumbnailPreferences) {}
    func image(for key: NativeThumbnailCache.Key, background: Bool) -> CGImage? { nil }
    // Disk-free v1 bookkeeping tests do not exercise queued promotions. The
    // follow-up suite separately runs the actual disk actor and mailbox.
    nonisolated func enqueuePromotion(_ key: NativeThumbnailCache.Key, epoch: UInt64) -> Bool { true }
    func flushPromotions() {}
    func promote(_ key: NativeThumbnailCache.Key, epoch: UInt64) {}
    func insert(_ image: CGImage, for key: NativeThumbnailCache.Key, background: Bool, epoch: UInt64) {}
    func clear(epoch: UInt64) -> Bool { true }
    func bytes() -> Int { 0 }
}
