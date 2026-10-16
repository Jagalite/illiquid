// Compare effective history and preferences after deterministic mixed operations.
// Real store/JSON/UserDefaults; batch receipts are semantic, not dictionary ordering.
import Foundation

struct Generator {
    var state: UInt64 = 0xF017_AC31_0C15
    mutating func next(_ limit: Int) -> Int {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Int(state % UInt64(limit))
    }
}
@main struct Main {
    static func main() throws {
        let suite = "com.example.IlliquidDifferential." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = PlaybackPersistenceStore(userDefaults: defaults)
        let urls = (0..<32).map { URL(fileURLWithPath: "/synthetic/mixed/episode-\($0).mkv") }
        let folder = URL(fileURLWithPath: "/synthetic/mixed", isDirectory: true)
        var random = Generator()
        for batch in 0..<200 {
            for _ in 0..<50 {
                let url = urls[random.next(urls.count)]
                let position = Double(random.next(151)), operation = random.next(18)
                switch operation {
                case 0: store.setPlaybackProgress(position: position, duration: 100, for: url)
                case 1: store.setPlaybackPosition(position, for: url)
                case 2: store.markPlaybackCompleted(for: url)
                case 3: store.removePlaybackPosition(for: url)
                case 4: store.setLastOpenedMedia(.file(url))
                case 5: store.setLastOpenedMedia(.folder(folder))
                case 6: store.setLastWatchedFile(url, for: folder)
                case 7: store.setLastWatchedFile(nil, for: folder)
                case 8: store.setMediaSettings(.init(areSubtitlesVisible: random.next(2) == 0,
                    subtitleDelay: position / 10 - 5), for: url)
                case 9: store.setMediaSettings(nil, for: url)
                case 10, 11:
                    let version = MediaContentVersion(fileIdentifier: UInt64(random.next(4)), byteCount: 200,
                        modificationSeconds: 10, modificationNanoseconds: 1, creationSeconds: 5, creationNanoseconds: 2)
                    store.acceptMediaVersion(version, for: url)
                case 12:
                    if let version = store.mediaVersion(for: url) {
                        store.copyHistoryForLocatedMedia(from: url, to: urls[random.next(urls.count)], version: version)
                    }
                case 13: store.clearPlaybackProgress()
                case 14: store.clearRememberedMediaSettings()
                case 15: store.clearPlaybackHistory()
                case 16:
                    var preferences = store.loadPreferences()
                    preferences.remembersPlaybackHistory = random.next(2) == 0
                    store.savePreferences(preferences)
                default: store.setMuted(random.next(2) == 0)
                }
            }
            store.flushSynchronously()
            store = PlaybackPersistenceStore(userDefaults: defaults)
            var object: [String: Any] = [:]
            if let data = defaults.data(forKey: "Illiquid.playback-state.v1") {
                object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            // This duplicate field may be captured later by design. The separate
            // preference key has precedence on reload in both implementations.
            object["preferences"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.loadPreferences()))
            if let completed = object["completedFiles"] as? [String] { object["completedFiles"] = completed.sorted() }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print("\(batch) " + String(decoding: data, as: UTF8.self))
        }
    }
}
