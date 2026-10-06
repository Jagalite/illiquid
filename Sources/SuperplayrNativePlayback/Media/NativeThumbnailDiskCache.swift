import CoreGraphics
import Foundation
import ImageIO
import SuperplayrCore
import UniformTypeIdentifiers

/// Disk work is isolated from RAM hits and runs through a bounded utility writer.
actor NativeThumbnailDiskCache {
    typealias Key = NativeThumbnailCache.Key
    private struct DiskEntry {
        var url: URL
        let bytes: Int
        var used: Date
        var background: Bool
    }
    private let directory: URL?
    private var preferences = ThumbnailPreferences()
    private var files: [String: DiskEntry] = [:]
    private var loadedDisk = false
    private var diskBytes = 0
    private var generation: UInt64 = 0
    private let encode: @Sendable (CGImage) async -> Data?
    private var encoding: (digest: String, epoch: UInt64, promoted: Bool)?
    init(directory: URL?, encode: (@Sendable (CGImage) async -> Data?)? = nil) {
        self.directory = directory
        self.encode = encode ?? { image in
            await Task.detached(priority: .utility) { Self.encode(image) }.value
        }
    }

    func configure(_ value: ThumbnailPreferences) {
        preferences = value.bounded
        if preferences.diskMiB == 0 { loadDisk() }
        if loadedDisk { trimDisk(incoming: 0, background: false) }
    }

    func image(for key: Key, background: Bool) -> CGImage? {
        guard preferences.diskMiB > 0 else { return nil }
        loadDisk()
        // An empty cache cannot hit. Avoid lazy hashing/framework initialization
        // on the first foreground preview; persistence can do it at utility priority.
        guard !files.isEmpty else { return nil }
        let digest = key.digest
        guard let entry = files[digest] else { return nil }
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width <= key.width, height <= key.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { removeDisk(digest); return nil }
        if !background { promoteDisk(digest) }
        return image
    }

    func insert(_ image: CGImage, for key: Key, background: Bool, epoch: UInt64) async {
        guard epoch == generation, !Task.isCancelled else { return }
        guard preferences.diskMiB > 0, let directory else { return }
        loadDisk()
        let digest = key.digest
        guard files[digest] == nil else { if !background { promoteDisk(digest) }; return }
        // Encoding must not occupy this actor: foreground disk lookups can
        // proceed while the single utility writer compresses its current image.
        encoding = (digest, epoch, false)
        defer { encoding = nil }
        guard let data = await encode(image), epoch == generation,
              !Task.isCancelled, preferences.diskMiB > 0 else { return }
        let background = background && encoding?.promoted != true
        trimDisk(incoming: data.count, background: background)
        guard diskBytes + data.count <= preferences.diskMiB * 1024 * 1024,
              files.count < 8192 else { return }
        let url = directory.appendingPathComponent("\(background ? "b" : "f")-\(digest).jpg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            files[digest] = DiskEntry(url: url, bytes: data.count, used: Date(), background: background)
            diskBytes += data.count
        } catch { /* A cache write failure must not fail a preview. */ }
    }

    /// Foreground protection is metadata, not a replaceable image write. This
    /// also promotes an in-flight encode before it commits its disk entry.
    func promote(_ key: Key, epoch: UInt64) {
        guard epoch == generation, preferences.diskMiB > 0 else { return }
        loadDisk()
        let digest = key.digest
        if encoding?.digest == digest, encoding?.epoch == epoch { encoding?.promoted = true }
        promoteDisk(digest)
    }

    private nonisolated static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func promoteDisk(_ digest: String) {
        guard var entry = files[digest] else { return }
        let promoted = entry.url.deletingLastPathComponent().appendingPathComponent("f-\(digest).jpg")
        if entry.background, (try? FileManager.default.moveItem(at: entry.url, to: promoted)) != nil {
            entry.url = promoted
            entry.background = false
        }
        // Avoid filesystem writes on every hover of an already promoted image.
        if entry.background || Date().timeIntervalSince(entry.used) > 60 {
            entry.used = Date()
            try? FileManager.default.setAttributes([.modificationDate: entry.used], ofItemAtPath: entry.url.path)
        }
        files[digest] = entry
    }

    private func loadDisk() {
        guard !loadedDisk else { return }
        loadedDisk = true
        guard let directory, let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        for url in urls where url.pathExtension == "jpg" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.count == 66, name.hasPrefix("b-") || name.hasPrefix("f-"),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let bytes = values.fileSize else { continue }
            let digest = String(name.dropFirst(2))
            guard digest.allSatisfy({ $0.isHexDigit }) else { continue }
            files[digest] = DiskEntry(url: url, bytes: bytes, used: values.contentModificationDate ?? .distantPast,
                                      background: name.hasPrefix("b-"))
        }
        diskBytes = files.values.reduce(0) { $0 + $1.bytes }
        trimDisk(incoming: 0, background: false)
    }

    private func trimDisk(incoming: Int, background: Bool) {
        let limit = preferences.diskMiB * 1024 * 1024
        guard diskBytes + incoming > limit || files.count >= 8192 else { return }
        let victims = files.filter { !background || $0.value.background }.sorted {
            if $0.value.background != $1.value.background { return $0.value.background }
            return $0.value.used < $1.value.used
        }
        for victim in victims {
            guard diskBytes + incoming > limit || files.count >= 8192 else { break }
            guard removeDisk(victim.key) else { break }
        }
    }

    @discardableResult
    private func removeDisk(_ digest: String) -> Bool {
        guard let entry = files[digest] else { return true }
        do { try FileManager.default.removeItem(at: entry.url) }
        catch {
            guard (error as NSError).code == NSFileNoSuchFileError else { return false }
        }
        files.removeValue(forKey: digest)
        diskBytes -= entry.bytes
        return true
    }

    func clear(epoch: UInt64) -> Bool {
        generation = epoch
        loadDisk()
        for key in Array(files.keys) { removeDisk(key) }
        return files.isEmpty
    }
    func bytes() -> Int { diskBytes }
}
