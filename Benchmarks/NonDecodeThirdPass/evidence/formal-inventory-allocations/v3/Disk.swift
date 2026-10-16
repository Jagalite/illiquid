import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    private nonisolated let promotions = ThumbnailPromotionMailbox()
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

    // ADAPTER: not called by inventory timing or inventory tests.
    func image(for key: Key, background: Bool) -> CGImage? {
        guard preferences.diskMiB > 0 else { return nil }
        loadDisk()
        guard let entry = files[key.digest], let data = try? Data(contentsOf: entry.url),
              let image = CGImage.decode(data), image.width <= key.width, image.height <= key.height else { return nil }
        if !background { promoteDisk(key.digest) }
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
            && !promotions.protects(digest, epoch: epoch)
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

    /// Synchronously reserve protection, but never wait for this actor's disk I/O.
    /// Saturation/epoch mismatch/in-progress eviction uses the old awaited path.
    nonisolated func enqueuePromotion(_ key: Key, epoch: UInt64) -> Bool {
        let interval = NonDecodePerformance.begin("ThumbnailPromotionReserve")
        defer { NonDecodePerformance.end(interval) }
        switch promotions.reserve(key.digest, epoch: epoch) {
        case .unavailable: return false
        case .accepted(let startDrain):
            if startDrain {
                Task(priority: .utility) { await self.drainPromotions() }
            }
            return true
        }
    }

    private func drainPromotions() async {
        var processed = 0
        while let request = promotions.next() {
            // There is no await between dequeue, promotion, and acknowledgement.
            // Clear/configure may interleave only at the explicit fairness yield.
            if request.epoch == generation, preferences.diskMiB > 0 {
                NonDecodePerformance.measure("ThumbnailDiskPromotion") {
                    loadDisk()
                    if encoding?.digest == request.digest, encoding?.epoch == request.epoch {
                        encoding?.promoted = true
                    }
                    promoteDisk(request.digest)
                }
            }
            promotions.complete(request)
            processed += 1
            if processed.isMultiple(of: 8) { await Task.yield() }
        }
    }

    func flushPromotions() async { await promotions.waitUntilEmpty() }

    private nonisolated static func encode(_ image: CGImage) -> Data? { image.encoded() }
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
        let interval = NonDecodePerformance.begin("ThumbnailDiskInventory")
        defer { NonDecodePerformance.end(interval) }
        loadedDisk = true
        // Stream names rather than retaining a URL/resource cache for every
        // directory entry. Our explicit resource-value lookup runs only for a
        // valid cache filename; FileManager may still do internal metadata I/O.
        // This remains a complete, shallow inventory before budget enforcement.
        guard let directory, let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]) else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey,
                                        .isRegularFileKey, .isSymbolicLinkKey]
        for case let url as URL in entries {
            guard let parsed = Self.parseFilename(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes >= 0 else { continue }
            files[parsed.digest] = DiskEntry(url: url, bytes: bytes,
                used: values.contentModificationDate ?? .distantPast,
                background: parsed.background)
        }
        diskBytes = files.values.reduce(0) { $0 + $1.bytes }
        trimDisk(incoming: 0, background: false)
    }

    /// The on-disk format is b-/f- followed by 64 ASCII hex bytes and .jpg.
    /// Checking UTF-8 rejects malformed/Unicode lookalikes before filesystem work.
    private static func parseFilename(_ name: String) -> (digest: String, background: Bool)? {
        let bytes = name.utf8
        guard bytes.count == 70 else { return nil }
        var iterator = bytes.makeIterator()
        guard let tier = iterator.next(), tier == 98 || tier == 102,
              iterator.next() == 45 else { return nil }
        for _ in 0..<64 {
            guard let byte = iterator.next(), (48...57).contains(byte)
                || (65...70).contains(byte) || (97...102).contains(byte) else { return nil }
        }
        guard iterator.next() == 46, iterator.next() == 106,
              iterator.next() == 112, iterator.next() == 103 else { return nil }
        return (String(decoding: bytes.dropFirst(2).prefix(64), as: UTF8.self), tier == 98)
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
            if background {
                guard promotions.beginEviction(victim.key, epoch: generation) else { continue }
                let removed = removeDisk(victim.key)
                promotions.endEviction(victim.key)
                guard removed else { break }
            } else {
                guard removeDisk(victim.key) else { break }
            }
        }
    }

    @discardableResult
    private func removeDisk(_ digest: String) -> Bool {
        guard let entry = files[digest] else { return true }
        // Never use recursive deletion for a cache image. A path may have
        // become a directory since inventory; unlink refuses directories and
        // removes only the link itself if a symlink was substituted meanwhile.
        let removed = entry.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return unlink(path) == 0 || errno == ENOENT
        }
        guard removed else { return false }
        files.removeValue(forKey: digest)
        diskBytes -= entry.bytes
        return true
    }

    func clear(epoch: UInt64) -> Bool {
        generation = epoch
        promotions.reset(epoch: epoch)
        loadDisk()
        for key in Array(files.keys) { removeDisk(key) }
        return files.isEmpty
    }
    func bytes() -> Int { loadDisk(); return diskBytes }
}

extension NativeThumbnailDiskCache {
    func testEntryCount() -> Int { files.count }
    #if CANDIDATE
    func testParseFilename(_ name: String) -> String? { Self.parseFilename(name)?.digest }
    #endif
}
