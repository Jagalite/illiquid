import Foundation

public struct ThumbnailPreferences: Codable, Equatable, Sendable {
    public enum Priority: String, Codable, CaseIterable, Sendable {
        case balanced, nearby, recent
    }
    public var generatesInBackground = false
    public var generatesWithWindowClosed = false
    public var memoryMiB = 32
    public var diskMiB = 256
    public var videosPerPass = 8
    public var samplesPerVideo = 12
    public var idleSeconds = 3
    public var workSeconds = 15
    public var recencyDays = 7
    public var priority: Priority = .balanced
    public init() {}

    public var bounded: Self {
        var value = self
        value.memoryMiB = min(max(memoryMiB, 8), 128)
        value.diskMiB = min(max(diskMiB, 0), 2048)
        value.videosPerPass = min(max(videosPerPass, 1), 64)
        value.samplesPerVideo = min(max(samplesPerVideo, 1), 64)
        value.idleSeconds = min(max(idleSeconds, 1), 30)
        value.workSeconds = min(max(workSeconds, 1), 120)
        value.recencyDays = min(max(recencyDays, 1), 30)
        return value
    }
}

/// Pure policy: no directory walks, decoding, or wall-clock reads.
public enum ThumbnailPolicy {
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
                              now: Date, preferences: ThumbnailPreferences) -> [URL] {
        let settings = preferences.bounded
        let current = current?.standardizedFileURL
        let folderPath = folder?.standardizedFileURL.path
        let horizon = Double(settings.recencyDays) * 86400
        var seen = Set<URL>()
        let eligible = candidates.filter { item in
            guard item.url.isFileURL, seen.insert(item.url).inserted else { return false }
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
        return ordered.prefix(settings.videosPerPass).map { $0.url }
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
