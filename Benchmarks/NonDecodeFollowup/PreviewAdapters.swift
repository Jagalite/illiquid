// TEST ONLY: JPEG/CoreGraphics and file-version probing are replaced here.
// Disk actor scheduling, disk inventory/trim/rename/write, resident cache logic,
// and the reservation mailbox remain the selected production implementations.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
// Generated cache files omit platform imports, which are otherwise file-scoped.
typealias SHA256 = CryptoKit.SHA256
#else
@_silgen_name("SHA256") private func opensslSHA256(_ data: UnsafeRawPointer?, _ count: Int, _ result: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8>?
enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            bytes.withUnsafeMutableBufferPointer { output in
                _ = opensslSHA256(buffer.baseAddress, buffer.count, output.baseAddress!)
            }
        }
        return bytes
    }
}
#endif
final class CGImage: @unchecked Sendable {
    let width: Int, height: Int, bytesPerRow: Int, token: Int, payloadBytes: Int
    init(width: Int = 16, height: Int = 16, token: Int = 1, payloadBytes: Int = 100) {
        self.width = width; self.height = height; bytesPerRow = width * 4
        self.token = token; self.payloadBytes = payloadBytes
    }
    func encoded() -> Data {
        let header = Data("\(width),\(height),\(token)\n".utf8)
        return header + Data(repeating: 0, count: max(0, payloadBytes - header.count))
    }
    static func decode(_ data: Data) -> CGImage? {
        guard let end = data.firstIndex(of: 10),
              let header = String(data: data[..<end], encoding: .utf8) else { return nil }
        let fields = header.split(separator: ",").compactMap { Int($0) }
        guard fields.count == 3, fields[0] > 0, fields[1] > 0 else { return nil }
        return CGImage(width: fields[0], height: fields[1], token: fields[2], payloadBytes: data.count)
    }
}
struct NativeFileContentVersion {
    let fileIdentifier = 0, byteCount = 0, modificationSeconds = 0
    let modificationNanoseconds = 0, creationSeconds = 0, creationNanoseconds = 0
    static func read(_ url: URL) -> Self? { nil }
}
actor ThumbnailBlockingReader<Value: Sendable> {
    func read(_ operation: @Sendable () -> Value?) async -> Value? { operation() }
}
final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
actor EncodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    let entered = DispatchSemaphore(value: 0)
    func wait() async {
        entered.signal()
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
