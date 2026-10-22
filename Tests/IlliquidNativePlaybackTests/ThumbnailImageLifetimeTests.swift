import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IlliquidNativePlayback

@MainActor
final class ThumbnailImageLifetimeTests: XCTestCase {
    private func fixture() throws -> (URL, NativeThumbnailCache.Key, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = NativeThumbnailCache.Key(path: "/synthetic/video.mkv", version: "1",
            halfSecond: 0, width: 320, height: 180)
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180,
            bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Texture exercises ImageIO's deferred JPEG backing; a tiny solid-color
        // JPEG may be entirely cached and conceal the pathname dependency.
        for y in 0..<180 { for x in 0..<320 {
            context.setFillColor(red: CGFloat((x * 17 + y * 3) % 256) / 255,
                green: CGFloat((x * 3 + y * 11) % 256) / 255,
                blue: CGFloat((x * 7 + y * 19) % 256) / 255, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, key, data as Data)
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    func testEncodedSizeLimitAcceptsBoundaryAndRejectsOversizedJPEG() throws {
        let (root, key, data) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bounded.jpg")
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Valid JPEG with trailing padding: dimensions alone cannot bound its
        // encoded size. Truncate creates the padding without a large test buffer.
        try handle.truncate(atOffset: UInt64(NativeThumbnailDiskCache.maximumEncodedImageBytes))
        XCTAssertNotNil(NativeThumbnailDiskCache.readImage(at: url, key: key))
        try handle.truncate(atOffset: UInt64(NativeThumbnailDiskCache.maximumEncodedImageBytes + 1))
        XCTAssertNil(NativeThumbnailDiskCache.readImage(at: url, key: key))
    }

    func testOversizedForegroundAliasFallsBackToValidBackgroundJPEG() async throws {
        let (root, key, data) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreground = root.appendingPathComponent("f-\(key.digest).jpg")
        try data.write(to: foreground)
        let handle = try FileHandle(forWritingTo: foreground)
        try handle.truncate(atOffset: UInt64(NativeThumbnailDiskCache.maximumEncodedImageBytes + 1))
        try handle.close()
        try data.write(to: root.appendingPathComponent("b-\(key.digest).jpg"))
        let cache = NativeThumbnailDiskCache(directory: root)
        let result = await cache.image(for: key, background: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(try Data(contentsOf: foreground), data)
        let bytes = await cache.bytes()
        XCTAssertEqual(bytes, data.count)
    }

    func testDecodedImageSurvivesSourceRenameAndRemoval() throws {
        let (root, key, data) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("b-\(key.digest).jpg")
        let promotedURL = root.appendingPathComponent("f-\(key.digest).jpg")
        try data.write(to: sourceURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let reference = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let expected = try pixels(reference)
        let image = try autoreleasepool {
            try XCTUnwrap(NativeThumbnailDiskCache.readImage(at: sourceURL, key: key))
        }
        try FileManager.default.moveItem(at: sourceURL, to: promotedURL)
        XCTAssertEqual(try pixels(image), expected)
        try FileManager.default.removeItem(at: promotedURL)
        XCTAssertNotNil(image.dataProvider?.data)
        XCTAssertEqual(try pixels(image), expected)
    }

    func testForegroundPromotionReturnsRenderablePixels() async throws {
        let (root, key, data) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try data.write(to: root.appendingPathComponent("b-\(key.digest).jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let reference = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let expected = try pixels(reference)
        let cache = NativeThumbnailDiskCache(directory: root)
        let result = await cache.image(for: key, background: false)
        let image = try XCTUnwrap(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b-\(key.digest).jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("f-\(key.digest).jpg").path))
        XCTAssertEqual(try pixels(image), expected)
    }
}
