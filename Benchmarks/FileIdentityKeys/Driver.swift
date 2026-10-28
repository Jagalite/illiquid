import Foundation
import IlliquidCore

enum DriverError: Error {
    case usage
}

@main
enum FileIdentityBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["verify"] {
            try verify()
            return
        }
        guard arguments.count == 3, arguments[0] == "measure",
              let iterations = Int(arguments[2]), iterations > 0 else {
            throw DriverError.usage
        }
        let name = arguments[1]
        let operation = try operation(for: name)
        // Setup and warmup are outside the measured interval.
        var warmupChecksum = 0
        for index in 0..<32 { warmupChecksum &+= operation(index) }
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations { checksum &+= operation(index) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try emit([
            "workload": name,
            "iterations": iterations,
            "elapsed_ns": elapsed,
            "checksum": checksum,
            "warmup_checksum": warmupChecksum,
        ])
    }

    private static func encoded(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return Data(value.utf8).base64EncodedString()
    }

    private static func verify() throws {
        var rows: [[String: Any]] = []
        var constructed = 0
        var oracleMismatches = 0
        for entry in FileIdentityKeyCorpus.make() {
            guard let url = entry.url else {
                rows.append(["label": entry.label, "constructed": false])
                continue
            }
            constructed += 1
            let key = NormalizedFileURL.persistenceKey(for: url)
            let normalized = NormalizedFileURL.normalize(url)
            let oracle = normalized?.path
            if key.map({ Array($0.utf8) }) != oracle.map({ Array($0.utf8) }) {
                oracleMismatches += 1
            }
            rows.append([
                "label": entry.label,
                "constructed": true,
                "absolute_url": url.absoluteString,
                "key_utf8_base64": encoded(key),
                "normalized_key_utf8_base64": encoded(oracle),
                "normalized_url": encoded(normalized?.absoluteString),
            ])
        }
        guard constructed > 1_000 else { throw DriverError.usage }
        let folder = URL(fileURLWithPath: "/Volumes/Media/", isDirectory: true)
        let playlist = makePlaylist(count: 32)
        let queries = [
            playlist.items[0].url, playlist.items[16].url, playlist.items[31].url,
            folder.appendingPathComponent("missing.mkv"),
            URL(string: "file://media-server.invalid/Volumes/Media/Episode%2000000.mkv")!,
        ]
        let lookup = queries.map { playlist.index(of: $0) }
        try emit([
            "cases": rows.count,
            "constructed": constructed,
            "constructor_rejections": rows.count - constructed,
            "oracle_mismatches": oracleMismatches,
            "rows": rows,
            "playlist_ids": playlist.items.map(\.id),
            "playlist_lookup": lookup.map { value -> Any in
                if let value { return value }
                return NSNull()
            },
        ])
    }

    private static func operation(for name: String) throws -> (Int) -> Int {
        let prepared = (0..<128).map {
            URL(fileURLWithPath: "/Volumes/Media/Series \($0 % 7)/Episode \($0).mkv",
                isDirectory: false)
        }
        switch name {
        case "key-prepared":
            return { NormalizedFileURL.persistenceKey(for: prepared[$0 % prepared.count])?.utf8.count ?? -1 }
        case "key-unicode":
            let urls = (0..<128).map {
                URL(fileURLWithPath: "/Volumes/Media/Cafe\u{0301}/\u{1100}\u{1161}/世界 🎬 \($0).mkv",
                    isDirectory: false)
            }
            return { NormalizedFileURL.persistenceKey(for: urls[$0 % urls.count])?.utf8.count ?? -1 }
        case "key-lexical":
            let urls = (0..<128).map {
                URL(string: "file://LOCALHOST/Volumes/Media/Season%20\($0)/../Episode%20\($0)%252F%23.mkv?copy=1#chapter")!
            }
            return { NormalizedFileURL.persistenceKey(for: urls[$0 % urls.count])?.utf8.count ?? -1 }
        case "key-rejected-control":
            let urls = [
                "https://example.invalid/Media/Feature.mkv",
                "file://media-server.invalid/Media/Feature.mkv",
                "file://localhost:1234/Media/Feature.mkv",
                "file://user:password@localhost/Media/Feature.mkv",
                "file:relative.mkv",
            ].map { URL(string: $0)! }
            return { NormalizedFileURL.persistenceKey(for: urls[$0 % urls.count])?.utf8.count ?? -1 }
        case "normalize-control":
            return { NormalizedFileURL.normalize(prepared[$0 % prepared.count])?.path.utf8.count ?? -1 }
        case "same-file":
            let aliases = (0..<128).map {
                URL(string: "file://localhost/Volumes/Media/Series%20\($0 % 7)/Temp/../Episode%20\($0).mkv")!
            }
            return { index in
                let offset = index % prepared.count
                let other = index % 2 == 0 ? offset : (offset + 1) % prepared.count
                return NormalizedFileURL.representsSameFile(prepared[offset], aliases[other]) ? 1 : 0
            }
        case "playlist-32", "playlist-1000", "playlist-10000":
            guard let count = Int(name.dropFirst("playlist-".count)) else { throw DriverError.usage }
            let playlist = makePlaylist(count: count)
            let queries = [
                playlist.items[0].url,
                playlist.items[count / 2].url,
                playlist.items[count - 1].url,
                URL(fileURLWithPath: "/Volumes/Media/Missing.mkv", isDirectory: false),
            ]
            return { playlist.index(of: queries[$0 % queries.count]) ?? -1 }
        default:
            throw DriverError.usage
        }
    }

    private static func makePlaylist(count: Int) -> FolderPlaylist {
        let folder = URL(fileURLWithPath: "/Volumes/Media/", isDirectory: true)
        let items = (0..<count).map { index in
            let name = String(format: "Episode %05d.mkv", index)
            return FolderPlaylistItem(url: folder.appendingPathComponent(name))
        }
        return FolderPlaylist(folderURL: folder, items: items)
    }

    private static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
