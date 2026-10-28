import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import IlliquidCore
@testable import IlliquidNativePlayback

final class ThumbnailDiskPathTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "illiquid-disk-path-tests-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func key() -> NativeThumbnailCache.Key {
        .init(path: "/test/path.mkv", version: "v1", halfSecond: 1, width: 64, height: 64)
    }

    private func path(
        _ directory: URL,
        _ key: NativeThumbnailCache.Key,
        background: Bool
    ) -> URL {
        directory.appendingPathComponent(
            "\(background ? "b" : "f")-\(key.digest).jpg",
            isDirectory: false
        )
    }

    private func image(width: Int = 12) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: 12,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 12))
        return try XCTUnwrap(context.makeImage())
    }

    @discardableResult
    private func writeJPEG(
        _ directory: URL,
        _ key: NativeThumbnailCache.Key,
        background: Bool = true,
        width: Int = 12
    ) throws -> Int {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try image(width: width), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: path(directory, key, background: background))
        return data.length
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    func testInventoryPromotionAndClearPreserveLiteralDirectoryCharacters() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("caché 雪 %25 #", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let selected = key()
        let expectedBytes = try writeJPEG(directory, selected)
        let backgroundURL = path(directory, selected, background: true)
        let foregroundURL = path(directory, selected, background: false)
        let oldDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: backgroundURL.path
        )

        let cache = NativeThumbnailDiskCache(directory: directory)
        let inventoriedBytes = await cache.bytes()
        XCTAssertEqual(inventoriedBytes, expectedBytes)
        let result = await cache.image(for: selected, background: false)
        XCTAssertEqual(result?.width, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foregroundURL.path))
        XCTAssertGreaterThan(try modificationDate(foregroundURL), oldDate)
        let promotedBytes = await cache.bytes()
        XCTAssertEqual(promotedBytes, expectedBytes)

        let cleared = await cache.clear(epoch: 1)
        XCTAssertTrue(cleared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testRelativeDirectoryUsesItsBaseForInsertInventoryAndClear() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = "relative cache % # 雪"
        let directory = URL(fileURLWithPath: leaf, isDirectory: true, relativeTo: root)
        let absoluteDirectory = root.appendingPathComponent(leaf, isDirectory: true)
        let selected = key()
        let cache = NativeThumbnailDiskCache(directory: directory)

        await cache.insert(try image(), for: selected, background: true, epoch: 0)
        let backgroundURL = path(absoluteDirectory, selected, background: true)
        let foregroundURL = path(absoluteDirectory, selected, background: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backgroundURL.path))

        // A fresh instance exercises URL reconstruction from inventoried names.
        let reopened = NativeThumbnailDiskCache(directory: directory)
        let bytes = await reopened.bytes()
        XCTAssertGreaterThan(bytes, 0)
        let result = await reopened.image(for: selected, background: false)
        XCTAssertEqual(result?.width, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foregroundURL.path))

        let cleared = await reopened.clear(epoch: 1)
        XCTAssertTrue(cleared)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: absoluteDirectory.path), []
        )
    }

    func testSymlinkedCacheDirectoryInventoriesPromotesAndClearsTargetFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real cache", isDirectory: true)
        let alias = root.appendingPathComponent("cache link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let selected = key()
        let expectedBytes = try writeJPEG(target, selected)
        let sentinel = target.appendingPathComponent("keep.txt")
        try Data([1]).write(to: sentinel)

        let cache = NativeThumbnailDiskCache(directory: alias)
        let bytes = await cache.bytes()
        XCTAssertEqual(bytes, expectedBytes)
        let result = await cache.image(for: selected, background: false)
        XCTAssertEqual(result?.width, 12)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: path(target, selected, background: true).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: path(target, selected, background: false).path
        ))

        let cleared = await cache.clear(epoch: 1)
        XCTAssertTrue(cleared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["keep.txt"])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path))
    }

    func testFailedPromotionTouchesAndClearsTheOriginalPhysicalFilename() async throws {
        for inventoryFirst in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let selected = key()
            let expectedBytes = try writeJPEG(root, selected)
            let backgroundURL = path(root, selected, background: true)
            let blockedForegroundURL = path(root, selected, background: false)
            try FileManager.default.createDirectory(
                at: blockedForegroundURL, withIntermediateDirectories: true
            )
            let sentinel = blockedForegroundURL.appendingPathComponent("keep.txt")
            try Data([1]).write(to: sentinel)
            let oldDate = Date(timeIntervalSince1970: 1)
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate], ofItemAtPath: backgroundURL.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate], ofItemAtPath: blockedForegroundURL.path
            )

            let cache = NativeThumbnailDiskCache(directory: root)
            if inventoryFirst { _ = await cache.bytes() }
            let result = await cache.image(for: selected, background: false)
            XCTAssertEqual(result?.width, 12)
            // The entry is foreground-used, but a failed rename leaves its
            // physical filename in the b- tier. Both touch and unlink must use it.
            XCTAssertGreaterThan(try modificationDate(backgroundURL), oldDate)
            XCTAssertEqual(try modificationDate(blockedForegroundURL), oldDate)
            let bytes = await cache.bytes()
            XCTAssertEqual(bytes, expectedBytes)

            let cleared = await cache.clear(epoch: 1)
            XCTAssertTrue(cleared)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            let remainingBytes = await cache.bytes()
            XCTAssertEqual(remainingBytes, 0)
        }
    }

    func testRetargetedDirectorySymlinkPreservesInventoriedURLSemantics() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        let alias = root.appendingPathComponent("cache link", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let selected = key()
        let expectedBytes = try writeJPEG(first, selected, width: 12)
        try writeJPEG(second, selected, width: 24)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)

        // Use the URL Foundation actually enumerates as the original behavior's
        // oracle; do not assume that enumeration resolves or preserves the link.
        let inventoriedURL: URL = try {
            let entries = FileManager.default.enumerator(
                at: alias, includingPropertiesForKeys: [],
                options: [.skipsSubdirectoryDescendants]
            )
            return try XCTUnwrap(entries?.nextObject() as? URL)
        }()
        let cache = NativeThumbnailDiskCache(directory: alias)
        let bytes = await cache.bytes()
        XCTAssertEqual(bytes, expectedBytes)

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        let expectedImage = try XCTUnwrap(
            NativeThumbnailDiskCache.readImage(at: inventoriedURL, key: selected)
        )
        let result = await cache.image(for: selected, background: true)
        XCTAssertEqual(result?.width, expectedImage.width)

        let expectedRemoval = inventoriedURL.resolvingSymlinksInPath().path
        let firstPath = path(first, selected, background: true).resolvingSymlinksInPath().path
        let secondPath = path(second, selected, background: true).resolvingSymlinksInPath().path
        XCTAssertTrue([firstPath, secondPath].contains(expectedRemoval))
        let untouched = expectedRemoval == firstPath ? secondPath : firstPath
        let cleared = await cache.clear(epoch: 1)
        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedRemoval))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path))
    }
}
