import Foundation

public struct ThumbnailPreferences: Codable, Equatable, Sendable {
    public enum Priority: String, Codable, CaseIterable, Sendable {
        case balanced, nearby, recent
    }
    public var preparesCurrentVideo = true
    public var generatesInBackground = false
    public var generatesWithWindowClosed = false
    public var memoryMiB = 16
    public var diskMiB = 256
    public var videosPerPass = 8
    public var samplesPerVideo = 12
    public var idleSeconds = 3
    public var workSeconds = 15
    public var recencyDays = 7
    public var priority: Priority = .balanced
    public var excludedFolderPaths: [String] = []
    public init() {}

    public enum Preset: String, CaseIterable, Sendable {
        case economical, balanced, extensive
    }

    /// Presets change budgets, never opt the user into background work.
    public mutating func apply(_ preset: Preset) {
        switch preset {
        case .economical:
            memoryMiB = 8; diskMiB = 64; videosPerPass = 4; samplesPerVideo = 6
            idleSeconds = 5; workSeconds = 5
        case .balanced:
            memoryMiB = 16; diskMiB = 256; videosPerPass = 8; samplesPerVideo = 12
            idleSeconds = 3; workSeconds = 15
        case .extensive:
            memoryMiB = 64; diskMiB = 1024; videosPerPass = 16; samplesPerVideo = 24
            idleSeconds = 3; workSeconds = 30
        }
    }

    public func excludesBackgroundGeneration(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedFolderPaths.contains { folder in
            let root = URL(fileURLWithPath: folder).standardizedFileURL.path
            return root == "/" || path == root || path.hasPrefix(root + "/")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case preparesCurrentVideo, generatesInBackground, generatesWithWindowClosed, memoryMiB, diskMiB
        case videosPerPass, samplesPerVideo, idleSeconds, workSeconds, recencyDays, priority
        case excludedFolderPaths
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preparesCurrentVideo = try values.decodeIfPresent(Bool.self, forKey: .preparesCurrentVideo) ?? preparesCurrentVideo
        generatesInBackground = try values.decodeIfPresent(Bool.self, forKey: .generatesInBackground) ?? generatesInBackground
        generatesWithWindowClosed = try values.decodeIfPresent(Bool.self, forKey: .generatesWithWindowClosed) ?? generatesWithWindowClosed
        memoryMiB = try values.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? memoryMiB
        diskMiB = try values.decodeIfPresent(Int.self, forKey: .diskMiB) ?? diskMiB
        videosPerPass = try values.decodeIfPresent(Int.self, forKey: .videosPerPass) ?? videosPerPass
        samplesPerVideo = try values.decodeIfPresent(Int.self, forKey: .samplesPerVideo) ?? samplesPerVideo
        idleSeconds = try values.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? idleSeconds
        workSeconds = try values.decodeIfPresent(Int.self, forKey: .workSeconds) ?? workSeconds
        recencyDays = try values.decodeIfPresent(Int.self, forKey: .recencyDays) ?? recencyDays
        priority = try values.decodeIfPresent(Priority.self, forKey: .priority) ?? priority
        excludedFolderPaths = try values.decodeIfPresent([String].self, forKey: .excludedFolderPaths) ?? []
    }

    public var bounded: Self {
        var value = self
        value.memoryMiB = min(max(memoryMiB, 8), 128)
        value.diskMiB = min(max(diskMiB, 0), 2048)
        value.videosPerPass = min(max(videosPerPass, 1), 64)
        value.samplesPerVideo = min(max(samplesPerVideo, 1), 64)
        value.idleSeconds = min(max(idleSeconds, 1), 30)
        value.workSeconds = min(max(workSeconds, 1), 120)
        value.recencyDays = min(max(recencyDays, 1), 30)
        var seen = Set<String>()
        value.excludedFolderPaths = []
        for path in excludedFolderPaths where path.hasPrefix("/") {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(normalized).inserted { value.excludedFolderPaths.append(normalized) }
            if value.excludedFolderPaths.count == 128 { break }
        }
        return value
    }
}

/// Pure policy: no directory walks, decoding, or wall-clock reads.
public enum ThumbnailPolicy {
    public static func storyboard(duration: Double) -> [Double] {
        samples(duration: duration, focus: 0, count: 24)
    }

    public static func nearby(duration: Double, focus: Double) -> [Double] {
        guard duration.isFinite, duration > 0, focus.isFinite else { return [] }
        let interest = min(duration, max(0, focus))
        let center = floor(interest / 5) * 5
        return (0...12).compactMap { index in
            let offset = index == 0 ? 0 : ((index + 1) / 2) * (index % 2 == 1 ? 1 : -1)
            let time = center + Double(offset) * 5
            return time >= 0 && time < duration && abs(time - interest) <= 30 ? (time * 2).rounded() / 2 : nil
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let url: URL
        public let lastUsed: Date?
        public let isVisible: Bool
        public let neighborDistance: Int?
        public init(url: URL, lastUsed: Date? = nil, isVisible: Bool = false,
                    neighborDistance: Int? = nil) {
            self.url = url.standardizedFileURL
            self.lastUsed = lastUsed
            self.isVisible = isVisible
            self.neighborDistance = neighborDistance
        }
    }

    public static func ranked(_ candidates: [Candidate], current: URL?, folder: URL?,
                              now: Date, preferences: ThumbnailPreferences, maximumCount: Int? = nil) -> [URL] {
        let settings = preferences.bounded
        let current = current?.standardizedFileURL
        let folderPath = folder?.standardizedFileURL.path
        let horizon = Double(settings.recencyDays) * 86400
        var seen = Set<URL>()
        let eligible = candidates.filter { item in
            guard item.url.isFileURL, !settings.excludesBackgroundGeneration(for: item.url),
                  seen.insert(item.url).inserted else { return false }
            return item.url == current || item.isVisible || item.neighborDistance != nil
                || item.url.deletingLastPathComponent().path == folderPath
                || item.lastUsed.map { now.timeIntervalSince($0) <= horizon } == true
        }
        func score(_ item: Candidate) -> Double {
            // Hard foreground/current/viewport tiers cannot be overwhelmed by history.
            if item.url == current { return 10000 }
            let locationWeight: Double = settings.priority == .nearby ? 3 : 1
            let recencyWeight: Double = settings.priority == .recent ? 3 : 1
            let age = max(0, item.lastUsed.map { now.timeIntervalSince($0) } ?? horizon)
            let recency = max(0, 1 - age / horizon)
            let locality = item.url.deletingLastPathComponent().path == folderPath ? 1.0 : 0.0
            let neighbor = item.neighborDistance.map { 1 / (1 + Double(max(0, $0))) } ?? 0
            return (item.isVisible ? 1000 : 0) + 100 * (locationWeight * (locality + neighbor) + recencyWeight * recency)
        }
        let scored: [(offset: Int, url: URL, score: Double)] = eligible.enumerated().map {
            (offset: $0.offset, url: $0.element.url, score: score($0.element))
        }
        let ordered = scored.sorted { left, right in
            if left.score == right.score { return left.offset < right.offset }
            return left.score > right.score
        }
        // A scheduler may rank its entire bounded candidate pool before applying
        // a persistent pass cursor. Truncating first would starve everything below
        // the same high-priority prefix on every pass.
        return ordered.prefix(max(0, maximumCount ?? settings.videosPerPass)).map { $0.url }
    }

    /// After every video has its first image, keep a bounded visit on each file
    /// to reuse its decoder without letting one video consume the whole pass.
    public static func refinementOrder(_ plans: [[Double]], maximumPerVisit: Int = 4)
        -> [(video: Int, position: Double)] {
        let plans = plans.prefix(64).map { Array($0.prefix(64)) }
        let count = plans.map(\.count).max() ?? 0
        let visit = min(8, max(1, maximumPerVisit))
        var result: [(video: Int, position: Double)] = []
        for offset in stride(from: 0, to: count, by: visit) {
            for video in plans.indices {
                for position in plans[video].dropFirst(offset).prefix(visit) {
                    result.append((video, position))
                }
            }
        }
        return result
    }

    /// Resume/local interest first, then progressively fill the largest broad gaps.
    /// Half-second quantization matches foreground hover requests.
    public static func samples(duration: Double, focus: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let last = max(0, floor((duration - 0.5) * 2) / 2)
        var result: [Double] = []
        func add(_ value: Double) {
            let time = min(last, max(0, (value * 2).rounded() / 2))
            if !result.contains(time) { result.append(time) }
        }
        add(focus.isFinite ? focus : 0)
        add(0)
        var divisions = 2
        while result.count < min(max(count, 1), 64), divisions <= 128 {
            for numerator in stride(from: 1, to: divisions, by: 2) {
                add(duration * Double(numerator) / Double(divisions))
            }
            divisions *= 2
        }
        return Array(result.prefix(min(max(count, 1), 64)))
    }
}

public struct ThumbnailCacheUsage: Equatable, Sendable {
    public let memoryBytes: Int
    public let diskBytes: Int
    public let images: Int
    public init(memoryBytes: Int = 0, diskBytes: Int = 0, images: Int = 0) {
        self.memoryBytes = memoryBytes; self.diskBytes = diskBytes; self.images = images
    }
}
