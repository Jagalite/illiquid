import Foundation

struct Generator {
    var state: UInt64 = 0x1f2e3d4c5b6a7988
    mutating func next(_ count: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 16) % UInt64(count))
    }
}

func fixtures(count: Int, exclusions: Int) -> ([ThumbnailPolicy.Candidate], ThumbnailPreferences) {
    var preferences = ThumbnailPreferences()
    preferences.excludedFolderPaths = (0..<exclusions).map { "/not-this-library/excluded-\($0)/../excluded-\($0)" }
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let candidates = (0..<count).map { i in
        ThumbnailPolicy.Candidate(url: URL(fileURLWithPath: "/media/series-\(i % 16)/episode-\(i).mkv"),
            lastUsed: now.addingTimeInterval(-Double(i % 9) * 86400),
            isVisible: i < 32, neighborDistance: i < 9 ? i : nil)
    }
    return (candidates, preferences)
}

#if DIFFERENTIAL
func equivalent(_ candidates: [ThumbnailPolicy.Candidate], _ settings: ThumbnailPreferences,
                current: URL?, folder: URL?, now: Date, maximum: Int?) -> Bool {
    var old = LegacyThumbnailPreferences()
    old.excludedFolderPaths = settings.excludedFolderPaths
    old.priority = LegacyThumbnailPreferences.Priority(rawValue: settings.priority.rawValue)!
    old.recencyDays = settings.recencyDays
    old.videosPerPass = settings.videosPerPass
    let legacy = candidates.map { LegacyThumbnailPolicy.Candidate(url: $0.url,
        lastUsed: $0.lastUsed, isVisible: $0.isVisible, neighborDistance: $0.neighborDistance) }
    let a = LegacyThumbnailPolicy.ranked(legacy, current: current, folder: folder, now: now,
        preferences: old, maximumCount: maximum)
    let b = ThumbnailPolicy.ranked(candidates, current: current, folder: folder, now: now,
        preferences: settings, maximumCount: maximum)
    return a == b
}
#endif

@main struct Main {
    static func main() {
        #if DIFFERENTIAL
        var random = Generator()
        let paths = ["/media/one.mkv", "/media2/two.mkv", "/media/sub/../three.mkv",
            "/media/\u{65}\u{301}/four.mkv", "/media/é/four.mkv", "/media/a b/1.mkv",
            "/else/one.mkv", "/one.mkv", "/media/%25/a.mkv", "/media/字幕/5.mkv",
            "/media/movie.mkv/", "/media//x.mkv"]
        let excluded = ["/media", "/media2", "/media/../else", "/media/字幕", "relative", "/", "/missing", "/media/"]
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let limits: [Int?] = [nil, -1, 0, 1, 8, 64, Int.max]
        var checks = 0
        for iteration in 0..<600 {
            var preferences = ThumbnailPreferences()
            preferences.priority = ThumbnailPreferences.Priority.allCases[random.next(3)]
            preferences.recencyDays = [-5,1,7,30,90][random.next(5)]
            preferences.videosPerPass = [-1,1,8,64,100][random.next(5)]
            preferences.excludedFolderPaths = (0..<random.next(8)).map { _ in excluded[random.next(excluded.count)] }
            var candidates: [ThumbnailPolicy.Candidate] = []
            for _ in 0..<random.next(64) {
                let url = random.next(12) == 0 ? URL(string: "https://example.invalid/a.mkv")!
                    : URL(fileURLWithPath: paths[random.next(paths.count)])
                candidates.append(.init(url: url,
                    lastUsed: random.next(4) == 0 ? nil : now.addingTimeInterval(Double(random.next(45)-5) * -86400),
                    isVisible: random.next(4) == 0, neighborDistance: random.next(3) == 0 ? random.next(10)-2 : nil))
            }
            let current = random.next(3) == 0 ? nil : candidates.first?.url
            let folder = random.next(3) == 0 ? nil : URL(fileURLWithPath: "/media")
            for maximum in limits {
                precondition(equivalent(candidates, preferences, current: current, folder: folder, now: now, maximum: maximum),
                    "Differential mismatch case \(iteration) limit \(String(describing: maximum))")
                checks += 1
            }
        }
        // Full bounded pool and all exclusions, without /'s early exit.
        for count in [32,256,2048] {
            for exclusions in [0,16,128] {
                let (candidates, preferences) = fixtures(count: count, exclusions: exclusions)
                for maximum in [8,count] {
                    precondition(equivalent(candidates, preferences, current: candidates.first?.url,
                        folder: URL(fileURLWithPath: "/media/series-0"), now: now, maximum: maximum))
                    checks += 1
                }
            }
        }
        print("{\"test\":\"ranking_differential\",\"checks\":\(checks),\"passed\":true}")
        #else
        let args = CommandLine.arguments
        let count = Int(args[1])!, exclusions = Int(args[2])!, iterations = Int(args[3])!
        let (candidates, preferences) = fixtures(count: count, exclusions: exclusions)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let folder = URL(fileURLWithPath: "/media/series-0")
        var checksum = 0
        for _ in 0..<2 {
            checksum += ThumbnailPolicy.ranked(candidates, current: candidates.first?.url,
                folder: folder, now: now, preferences: preferences, maximumCount: count).count
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let output = ThumbnailPolicy.ranked(candidates, current: candidates.first?.url,
                folder: folder, now: now, preferences: preferences, maximumCount: count)
            checksum += output.count + (output.first?.path.utf8.count ?? 0)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("{\"count\":\(count),\"exclusions\":\(exclusions),\"iterations\":\(iterations),\"ms_per_call\":\(elapsed/Double(iterations)),\"checksum\":\(checksum)}")
        #endif
    }
}
