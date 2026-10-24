import CoreGraphics
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ImageIO
import IlliquidCore
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
    // A full 2048x2048 BGRA thumbnail is 16 MiB before JPEG compression.
    // Bound encoded storage independently of the total disk-cache allowance.
    static let maximumEncodedImageBytes = 16 * 1024 * 1024
    private let directory: URL?
    private var preferences = ThumbnailPreferences()
    // Key by physical filename, not digest: b- and f- aliases can coexist.
    // Both consume disk space and must survive in accounting until unlinked.
    private var files: [String: DiskEntry] = [:]
    private var loadedDisk = false
    private var needsBudgetReconciliation = false
    private var diskBytes = 0
    private var trimDeferredByPromotions = false
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
        // The previous process may have used a larger limit, even when this
        // configured value equals our default. Reconcile after the first probe.
        needsBudgetReconciliation = !loadedDisk
        if preferences.diskMiB == 0 { loadDisk() }
        if loadedDisk { trimDisk(incoming: 0, background: false) }
    }

    func image(for key: Key, background: Bool) -> CGImage? {
        let interval = NonDecodePerformance.begin("ThumbnailDiskRead")
        defer { NonDecodePerformance.end(interval) }
        guard preferences.diskMiB > 0 else { return nil }
        if background { loadDisk() }
        let digest = key.digest
        prepareExactLookup(digest)
        defer { finishExactLookup() }
        // Deterministically prefer foreground. A corrupt foreground alias must
        // not hide a usable background copy, or remove its accounting.
        for name in Self.filenames(for: digest) {
            guard let entry = files[name] else { continue }
            guard let image = Self.readImage(at: entry.url, key: key) else {
                _ = removeDisk(name)
                continue
            }
            if !background { promoteDisk(digest, selectedName: name) }
            return image
        }
        return nil
    }

    nonisolated static func readImage(at url: URL, key: Key) -> CGImage? {
        // ImageIO can retain the URL for deferred JPEG reads even with immediate
        // caching requested. Promotion renames this file before the caller draws
        // the image; eviction may remove it later. Own the encoded bytes so the
        // returned CGImage never depends on that pathname remaining available.
        guard let data = readEncodedImage(at: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width <= key.width, height <= key.height else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private nonisolated static func readEncodedImage(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            // Reject existing oversized files before allocating their contents.
            let initialByteCount = try handle.seekToEnd()
            guard initialByteCount <= UInt64(maximumEncodedImageBytes) else { return nil }
            try handle.seek(toOffset: 0)
            // Reserve the validated size so multi-chunk reads do not repeatedly
            // grow and copy their backing storage. The read bound below still
            // applies if the file changes after this size probe.
            var data = Data(capacity: Int(initialByteCount))
            // Bound the read itself as well: the file may grow after the size
            // check. Small chunks avoid reserving 16 MiB for every tiny JPEG.
            while data.count <= maximumEncodedImageBytes {
                let count = min(64 * 1024, maximumEncodedImageBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
                data.append(chunk)
            }
            return nil
        } catch { return nil }
    }

    private static func filenames(for digest: String) -> [String] {
        ["f-\(digest).jpg", "b-\(digest).jpg"]
    }

    private func preferredFilename(for digest: String) -> String? {
        Self.filenames(for: digest).first { files[$0] != nil }
    }

    func insert(_ image: CGImage, for key: Key, background: Bool, epoch: UInt64) async {
        guard epoch == generation, !Task.isCancelled else { return }
        guard preferences.diskMiB > 0, let directory else { return }
        loadDisk()
        let digest = key.digest
        guard preferredFilename(for: digest) == nil else { if !background { promoteDisk(digest) }; return }
        // Encoding must not occupy this actor: foreground disk lookups can
        // proceed while the single utility writer compresses its current image.
        encoding = (digest, epoch, false)
        defer { encoding = nil }
        guard let data = await encode(image), data.count <= Self.maximumEncodedImageBytes, epoch == generation,
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
            files[url.lastPathComponent] = DiskEntry(url: url, bytes: data.count, used: Date(), background: background)
            diskBytes += data.count
        } catch { /* A cache write failure must not fail a preview. */ }
    }

    /// Foreground protection is metadata, not a replaceable image write. This
    /// also promotes an in-flight encode before it commits its disk entry.
    func promote(_ key: Key, epoch: UInt64) {
        guard epoch == generation, preferences.diskMiB > 0 else { return }
        let digest = key.digest
        prepareExactLookup(digest)
        defer { finishExactLookup() }
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
                    prepareExactLookup(request.digest)
                    defer { finishExactLookup() }
                    if encoding?.digest == request.digest, encoding?.epoch == request.epoch {
                        encoding?.promoted = true
                    }
                    promoteDisk(request.digest)
                }
            }
            promotions.complete(request)
            // Inventory may temporarily exceed its budget when every possible
            // victim has a pending foreground claim. Reconcile as claims finish,
            // before yielding or allowing a promotion flush to return.
            if trimDeferredByPromotions { trimDisk(incoming: 0, background: false) }
            processed += 1
            if processed.isMultiple(of: 8) { await Task.yield() }
        }
    }

    func flushPromotions() async {
        await promotions.waitUntilEmpty()
        // Re-enter this actor before returning to the caller. Mailbox completion
        // alone does not promise that the disk budget has been reconciled.
        if trimDeferredByPromotions { trimDisk(incoming: 0, background: false) }
    }

    private nonisolated static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func promoteDisk(_ digest: String, selectedName: String? = nil) {
        guard var name = selectedName ?? preferredFilename(for: digest),
              var entry = files[name] else { return }
        let wasBackground = entry.background
        let destinationName = "f-\(digest).jpg"
        let promoted = entry.url.deletingLastPathComponent().appendingPathComponent(destinationName)
        if name != destinationName {
            if (try? FileManager.default.moveItem(at: entry.url, to: promoted)) != nil {
                files.removeValue(forKey: name)
                // A previously indexed destination may have disappeared externally.
                // Never double-count it after successfully moving the source there.
                if let replaced = files.removeValue(forKey: destinationName) {
                    diskBytes -= replaced.bytes
                }
                name = destinationName
                entry.url = promoted
            } else if !loadedDisk {
                // A failed rename cannot persist the foreground filename. Fall
                // back to full accounting so the in-memory foreground tier is
                // retained, rather than discarded with a temporary exact lookup.
                loadDisk(protecting: name)
                guard let inventoried = files[name] else { return }
                entry = inventoried
            }
        }
        // A duplicate or failed rename is not permission for speculative
        // eviction of a foreground-used image within this process. Physical
        // aliases stay separately accounted; no valid backup is deleted here.
        entry.background = false
        if wasBackground || Date().timeIntervalSince(entry.used) > 60 {
            entry.used = Date()
            try? FileManager.default.setAttributes([.modificationDate: entry.used], ofItemAtPath: entry.url.path)
        }
        files[name] = entry
    }

    /// Before inventory, only two exact, validated names can answer a lookup.
    /// No directory traversal, persistent negative cache, or unbounded partial
    /// index is created. The actor does not suspend inside this temporary scope.
    /// Writes, explicit usage, reconfiguration and clear still require inventory.
    private func prepareExactLookup(_ digest: String) {
        guard !loadedDisk, let directory else { return }
        let interval = NonDecodePerformance.begin("ThumbnailExactDiskProbe")
        defer { NonDecodePerformance.end(interval) }
        for name in Self.filenames(for: digest) {
            let url = directory.appendingPathComponent(name)
            guard let entry = Self.inspectFile(url, background: name.hasPrefix("b-")) else { continue }
            files[name] = entry
            diskBytes += entry.bytes
        }
    }

    private func finishExactLookup() {
        // A changed limit must eventually be enforced even for foreground-only
        // traffic. Finish the exact hit/promotion first so inventory sees its tier.
        if needsBudgetReconciliation { loadDisk() }
        guard !loadedDisk else { return }
        // Never let many foreground-only requests accumulate a partial index.
        // These counters are private; bytes() always inventories before reporting.
        files.removeAll(keepingCapacity: false)
        diskBytes = 0
    }

    private nonisolated static func inspectFile(_ url: URL, background: Bool) -> DiskEntry? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey,
                                        .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes >= 0 else { return nil }
        return DiskEntry(url: url, bytes: bytes,
            used: values.contentModificationDate ?? .distantPast, background: background)
    }

    private func loadDisk(protecting protectedName: String? = nil) {
        guard !loadedDisk else { return }
        let interval = NonDecodePerformance.begin("ThumbnailDiskInventory")
        defer { NonDecodePerformance.end(interval) }
        loadedDisk = true
        needsBudgetReconciliation = false
        // Stream names rather than retaining a URL/resource cache for every
        // directory entry. Our explicit resource-value lookup runs only for a
        // valid cache filename; FileManager may still do internal metadata I/O.
        // This remains a complete, shallow inventory before budget enforcement.
        guard let directory, let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]) else { return }
        for case let url as URL in entries {
            guard let parsed = Self.parseFilename(url.lastPathComponent),
                  var entry = Self.inspectFile(url, background: parsed.background) else { continue }
            if url.lastPathComponent == protectedName {
                entry.background = false
                entry.used = Date()
            }
            files[url.lastPathComponent] = entry
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
        var skippedReservation = false
        defer {
            // Retry only an existing over-budget inventory, not an insertion
            // that was rejected or an ordinary promotion at the entry limit.
            trimDeferredByPromotions = skippedReservation
                && (diskBytes > limit || files.count >= 8192)
        }
        guard diskBytes + incoming > limit || files.count >= 8192 else { return }
        var victims = ThumbnailDiskEvictionHeap(files.compactMap { entry in
            guard !background || entry.value.background else { return nil }
            return .init(filename: entry.key, used: entry.value.used, background: entry.value.background)
        })
        while diskBytes + incoming > limit || files.count >= 8192 {
            guard let victim = victims.popFirst() else { break }
            // Initial inventory and reconfiguration also evict entries. Honor
            // queued foreground claims on those paths, not just insertions.
            // Explicitly disabling the disk cache must still remove everything.
            if preferences.diskMiB > 0 {
                let digest = String(decoding: victim.filename.utf8.dropFirst(2).prefix(64), as: UTF8.self)
                guard promotions.beginEviction(digest, epoch: generation) else {
                    skippedReservation = true
                    continue
                }
                let removed = removeDisk(victim.filename)
                promotions.endEviction(digest)
                guard removed else { break }
            } else {
                guard removeDisk(victim.filename) else { break }
            }
        }
    }

    @discardableResult
    private func removeDisk(_ filename: String) -> Bool {
        guard let entry = files[filename] else { return true }
        // Never use recursive deletion for a cache image. A path may have
        // become a directory since inventory; unlink refuses directories and
        // removes only the link itself if a symlink was substituted meanwhile.
        let removed = entry.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return unlink(path) == 0 || errno == ENOENT
        }
        guard removed else { return false }
        files.removeValue(forKey: filename)
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
