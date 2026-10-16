import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import IlliquidCore
@testable import IlliquidNativePlayback

/// Real macOS framework counterparts to the portable actor/codec-adapter tests.
/// These are not exercised by the Linux runner; run with the native SwiftPM graph.
final class QueuedThumbnailPromotionTests: XCTestCase {
    func testReservationReturnsWhileDiskActorIsBlocked() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = NativeThumbnailDiskCache(directory: directory)
        let image = try image()
        await disk.insert(image, for: key(1), background: true, epoch: 0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await disk.holdForPromotionTest(entered, release) }
        await wait(entered)
        // No await: this must complete before the test allows any actor progress.
        XCTAssertTrue(disk.enqueuePromotion(key(1), epoch: 0))
        release.signal()
        await blocker.value
        await disk.flushPromotions()
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("f-\(key(1).digest).jpg").path))
        let loaded = await disk.image(for: key(1), background: false)
        XCTAssertEqual(loaded?.width, image.width)
        XCTAssertEqual(loaded?.height, image.height)
    }

    func testDequeuedPromotionRemainsLatchedWhileEncoding() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = PromotionJPEGGate()
        let disk = NativeThumbnailDiskCache(directory: directory, encode: { image in
            await gate.wait()
            return Self.jpeg(image)
        })
        let value = try image(), key = key(1)
        let insertion = Task { await disk.insert(value, for: key, background: true, epoch: 0) }
        await wait(gate.entered)
        XCTAssertTrue(disk.enqueuePromotion(key, epoch: 0))
        await disk.flushPromotions()
        await gate.open()
        await insertion.value
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("f-\(key.digest).jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("b-\(key.digest).jpg").path))
    }

    func testClearInvalidatesOldPromotionEpoch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = NativeThumbnailDiskCache(directory: directory)
        await disk.insert(try image(), for: key(1), background: true, epoch: 0)
        XCTAssertTrue(disk.enqueuePromotion(key(1), epoch: 0))
        let cleared = await disk.clear(epoch: 1)
        XCTAssertTrue(cleared)
        await disk.flushPromotions()
        XCTAssertFalse(disk.enqueuePromotion(key(1), epoch: 0))
        XCTAssertTrue(disk.enqueuePromotion(key(2), epoch: 1))
        await disk.flushPromotions()
        let bytes = await disk.bytes()
        XCTAssertEqual(bytes, 0)
    }

    func testReservationOverflowKeepsEarlierClaims() async {
        let disk = NativeThumbnailDiskCache(directory: nil)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await disk.holdForPromotionTest(entered, release) }
        await wait(entered)
        for index in 0..<128 { XCTAssertTrue(disk.enqueuePromotion(key(index), epoch: 0)) }
        XCTAssertFalse(disk.enqueuePromotion(key(128), epoch: 0))
        XCTAssertTrue(disk.enqueuePromotion(key(0), epoch: 0))
        release.signal()
        await blocker.value
        await disk.flushPromotions()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("IlliquidPromotionTests-" + UUID().uuidString)
    }
    private func key(_ position: Int) -> NativeThumbnailCache.Key {
        .init(path: "/synthetic/promotion-test.mkv", version: "1", halfSecond: position, width: 16, height: 16)
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return try XCTUnwrap(context.makeImage())
    }
    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    private func wait(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                precondition(semaphore.wait(timeout: .now() + 10) == .success)
                continuation.resume()
            }
        }
    }
}

private actor PromotionJPEGGate {
    nonisolated let entered = DispatchSemaphore(value: 0)
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            entered.signal()
        }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private extension NativeThumbnailDiskCache {
    func holdForPromotionTest(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
        entered.signal()
        precondition(release.wait(timeout: .now() + 10) == .success)
    }
}
