import CoreGraphics
import CryptoKit
import Foundation
import IlliquidCore

/// App-wide small-image storage. Native decoder/frame ownership never enters this cache.
actor NativeThumbnailCache {
    struct Key: Hashable, Encodable, Sendable {
        let path: String
        let version: String
        let halfSecond: Int
        let width: Int
        let height: Int
        // Bump if default-stream selection, color conversion or image semantics change.
        let renderer = "default-video-bgra-v1"
        var digest: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = (try? encoder.encode(self)) ?? Data()
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    private struct Resident {
        let image: CGImage
        let bytes: Int
        var used: UInt64
        var background: Bool
        var diskTouch: Date
    }
    private let maximumResidentImages = 96
    private var preferences = ThumbnailPreferences()
    private var images: [Key: Resident] = [:]
    private var storyboardKeys = Set<Key>()
    private var storyboardSource: String?
    private var serial: UInt64 = 0
    private var memoryBytes = 0
    private let identityReader = ThumbnailBlockingReader<Key>()
    private let disk: NativeThumbnailDiskCache
    private let hasDisk: Bool
    private var epoch: UInt64 = 0
    private var memoryRevision: UInt64 = 0
    private struct Write: Sendable {
        let image: CGImage
        let key: Key
        let background: Bool
        let epoch: UInt64
    }
    private var pending: Write?
    private var writer: Task<Void, Never>?

    init(directory: URL? = nil, encode: (@Sendable (CGImage) async -> Data?)? = nil) {
        disk = NativeThumbnailDiskCache(directory: directory, encode: encode)
        hasDisk = directory != nil
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Illiquid/Thumbnails-v1", isDirectory: true)
    }

    func configure(_ value: ThumbnailPreferences) async {
        preferences = value.bounded
        trimMemory(incoming: 0, background: false)
        await disk.configure(preferences)
    }

    static func key(url: URL, time: Double, size: CGSize) -> Key? {
        guard url.isFileURL, time.isFinite, time >= 0,
              let bucket = Int(exactly: (time * 2).rounded()),
              let width = Int(exactly: size.width.rounded()),
              let height = Int(exactly: size.height.rounded()),
              (1...2048).contains(width), (1...2048).contains(height),
              let version = NativeFileContentVersion.read(url) else { return nil }
        return Key(path: url.standardizedFileURL.path,
                   version: "\(version.fileIdentifier):\(version.byteCount):\(version.modificationSeconds).\(version.modificationNanoseconds):\(version.creationSeconds).\(version.creationNanoseconds)",
                   halfSecond: bucket, width: width, height: height)
    }

    func makeKey(url: URL, time: Double, size: CGSize) async -> Key? {
        await identityReader.read { Self.key(url: url, time: time, size: size) }
    }

    func nearest(to key: Key, maximumDistance: Double, fallbackTimes: [Double] = []) async -> (CGImage, Double)? {
        guard maximumDistance.isFinite, maximumDistance >= 0 else { return nil }
        var candidates = Set(images.keys.filter {
            $0.path == key.path && $0.version == key.version && $0.width == key.width && $0.height == key.height
                && abs(Double($0.halfSecond) - Double(key.halfSecond)) / 2 <= maximumDistance
        })
        // The deterministic storyboard also gives us disk keys after a restart,
        // without a filesystem walk or decoding merely to find an approximation.
        for time in fallbackTimes {
            guard time.isFinite, let bucket = Int(exactly: (time * 2).rounded()),
                  abs(Double(bucket) - Double(key.halfSecond)) / 2 <= maximumDistance else { continue }
            candidates.insert(Key(path: key.path, version: key.version, halfSecond: bucket,
                                  width: key.width, height: key.height))
        }
        for match in candidates.sorted(by: {
            let a = abs(Double($0.halfSecond) - Double(key.halfSecond))
            let b = abs(Double($1.halfSecond) - Double(key.halfSecond))
            return a == b ? $0.halfSecond < $1.halfSecond : a < b
        }) {
            guard !Task.isCancelled else { return nil }
            if let image = await image(for: match, background: false) {
                return (image, Double(match.halfSecond) / 2)
            }
        }
        return nil
    }

    func admitsBackground(size: CGSize) -> Bool {
        let estimate = (Int(size.width) * 4 + 64) * Int(size.height)
        let victims = images.filter { $0.value.background && !storyboardKeys.contains($0.key) }
        let reclaimable = victims.reduce(0) { $0 + $1.value.bytes }
        // Do not decode speculative images that cannot become resident. Disk
        // persistence is a secondary benefit, not a reason to keep decoding.
        return memoryBytes - reclaimable + estimate <= preferences.memoryMiB * 1024 * 1024
            && (images.count < maximumResidentImages || !victims.isEmpty)
    }

    func selectStoryboardSource(_ key: Key) {
        let identity = key.path + "\n" + key.version
        if storyboardSource != identity {
            storyboardKeys.removeAll()
            storyboardSource = identity
        }
    }

    func protectStoryboard(_ key: Key) {
        selectStoryboardSource(key)
        if images[key] != nil { storyboardKeys.insert(key) }
    }

    func image(for key: Key, background: Bool) async -> CGImage? {
        if var resident = images[key] {
            if !background {
                let now = Date()
                let shouldTouchDisk = resident.background || now.timeIntervalSince(resident.diskTouch) >= 60
                serial &+= 1
                resident.used = serial
                resident.background = false
                if shouldTouchDisk { resident.diskTouch = now }
                images[key] = resident
                if shouldTouchDisk, hasDisk, preferences.diskMiB > 0 {
                    let revision = epoch
                    await disk.promote(key, epoch: revision)
                    guard epoch == revision, !Task.isCancelled else { return nil }
                    enqueueWrite(resident.image, key: key, background: false)
                }
            }
            return resident.image
        }
        let revision = epoch
        let residentRevision = memoryRevision
        guard hasDisk, preferences.diskMiB > 0,
              let image = await disk.image(for: key, background: background),
              epoch == revision, memoryRevision == residentRevision, !Task.isCancelled else { return nil }
        rememberMemory(image, key: key, background: background)
        return image
    }

    func insert(_ image: CGImage, for key: Key, background: Bool, storyboard: Bool = false) async {
        if storyboard { selectStoryboardSource(key) }
        let promotesResident = !background && images[key]?.background == true
        rememberMemory(image, key: key, background: background)
        if promotesResident, hasDisk, preferences.diskMiB > 0 {
            let revision = epoch
            await disk.promote(key, epoch: revision)
            guard epoch == revision, !Task.isCancelled else { return }
        }
        if storyboard, images[key] != nil { storyboardKeys.insert(key) }
        enqueueWrite(image, key: key, background: background)
    }

    private func enqueueWrite(_ image: CGImage, key: Key, background: Bool) {
        guard hasDisk, preferences.diskMiB > 0 else { return }
        // One physical writer plus one replaceable pending image. Foreground
        // writes/promotions take precedence over speculative persistence.
        if background, pending?.background == false { return }
        pending = Write(image: image, key: key, background: background, epoch: epoch)
        guard writer == nil else { return }
        writer = Task(priority: .utility) { [weak self] in await self?.drainWrites() }
    }

    private func drainWrites() async {
        while let next = pending {
            pending = nil
            if next.epoch == epoch, !Task.isCancelled {
                await disk.insert(next.image, for: next.key, background: next.background, epoch: next.epoch)
            }
        }
        writer = nil
    }

    func flushPendingWrites() async {
        while let active = writer { await active.value }
    }

    private func rememberMemory(_ image: CGImage, key: Key, background: Bool) {
        if var resident = images[key] {
            // A foreground decode/disk read can finish after a background
            // request has inserted the same key during an actor suspension.
            if !background {
                serial &+= 1
                resident.used = serial
                resident.background = false
                images[key] = resident
            }
            return
        }
        let bytes = image.bytesPerRow * image.height
        trimMemory(incoming: bytes, background: background)
        guard memoryBytes + bytes <= preferences.memoryMiB * 1024 * 1024,
              images.count < maximumResidentImages else { return }
        serial &+= 1
        images[key] = Resident(image: image, bytes: bytes, used: serial, background: background, diskTouch: Date())
        memoryBytes += bytes
    }

    private func trimMemory(incoming: Int, background: Bool) {
        let limit = preferences.memoryMiB * 1024 * 1024
        guard memoryBytes + incoming > limit || (incoming > 0 && images.count >= maximumResidentImages) else { return }
        let victims = images.filter { (!background || $0.value.background) && (!background || !storyboardKeys.contains($0.key)) }.sorted {
            if storyboardKeys.contains($0.key) != storyboardKeys.contains($1.key) { return !storyboardKeys.contains($0.key) }
            if $0.value.background != $1.value.background { return $0.value.background }
            return $0.value.used < $1.value.used
        }
        for victim in victims {
            guard memoryBytes + incoming > limit || (incoming > 0 && images.count >= maximumResidentImages) else { break }
            memoryBytes -= victim.value.bytes
            images.removeValue(forKey: victim.key)
            storyboardKeys.remove(victim.key)
        }
    }

    @discardableResult
    func clear() async -> Bool {
        epoch &+= 1
        pending = nil
        images.removeAll()
        storyboardKeys.removeAll()
        memoryBytes = 0
        return await disk.clear(epoch: epoch)
    }

    func usage() async -> (memoryBytes: Int, diskBytes: Int, images: Int) {
        (memoryBytes, await disk.bytes(), images.count)
    }

    /// Preserve disk entries and user limits. Reclaim speculative images first;
    /// critical pressure discards all resident images, including dictionary capacity.
    func trimForMemoryPressure(critical: Bool) {
        memoryRevision &+= 1
        pending = nil
        let target = critical ? 0 : memoryBytes / 2
        let victims = images.sorted {
            if $0.value.background != $1.value.background { return $0.value.background }
            return $0.value.used < $1.value.used
        }
        for victim in victims where memoryBytes > target {
            memoryBytes -= victim.value.bytes
            images.removeValue(forKey: victim.key)
            storyboardKeys.remove(victim.key)
        }
        if images.isEmpty { images = [:] }
    }
}
