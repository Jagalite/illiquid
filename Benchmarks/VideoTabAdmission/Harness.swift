import Dispatch
import Foundation
import IlliquidCore

/// Executes the production types directly. The generated package keeps this
/// executable in IlliquidApp so the real internal OpenVideoTabStore is visible.
@main
@MainActor
struct VideoTabAdmissionBenchmark {
    private enum InvocationError: Error {
        case usage
    }
    private struct Inputs {
        let sources: [MediaSource]
        let playlist: [FolderPlaylistItem]
        let folder = URL(fileURLWithPath: "/Volumes/Media/Season 01 日本語", isDirectory: true)

        init(size: Int) {
            sources = (0..<size).map {
                .localFile(URL(fileURLWithPath: "/Volumes/Media/Season 01 日本語/Episode-\($0).mkv"))
            }
            playlist = sources.map { FolderPlaylistItem(url: $0.url) }
        }
    }

    /// A process-independent digest omits generated UUID values but includes
    /// ordered sources, titles, resume state, playlist contents, and selection.
    private struct Digest {
        private(set) var value: UInt64 = 14_695_981_039_346_656_037

        mutating func add(_ value: UInt64) {
            var bytes = value.littleEndian
            withUnsafeBytes(of: &bytes) { bytes in
                for byte in bytes { self.value = (self.value ^ UInt64(byte)) &* 1_099_511_628_211 }
            }
        }

        mutating func add(_ text: String) {
            add(UInt64(text.utf8.count))
            for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        }

        mutating func add(_ tab: OpenVideoTab, selected: Bool) {
            add(tab.source.isRemote ? 1 : 0)
            add(tab.source.url.absoluteURL.absoluteString)
            add(tab.title)
            add(tab.position.bitPattern)
            add(tab.wasPaused ? 1 : 0)
            add(tab.folder?.absoluteString ?? "")
            add(UInt64(tab.playlist.count))
            for item in tab.playlist { add(item.url.absoluteURL.absoluteString) }
            add(selected ? 1 : 0)
        }
    }

    private static func checksum(_ tabs: OpenVideoTabs) -> String {
        var digest = Digest()
        digest.add(UInt64(tabs.items.count))
        for tab in tabs.items { digest.add(tab, selected: tab.id == tabs.selectedID) }
        return String(digest.value, radix: 16)
    }

    private static func checksum(_ store: OpenVideoTabStore) -> String {
        var digest = Digest()
        digest.add(UInt64(store.items.count))
        for item in store.items {
            guard let tab = store.tab(id: item.id) else { preconditionFailure("Missing backing tab") }
            precondition(item.source == tab.source && item.title == tab.title)
            digest.add(tab, selected: item.id == store.selectedID)
        }
        return String(digest.value, radix: 16)
    }

    private static func elapsed(_ body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return DispatchTime.now().uptimeNanoseconds - start
    }

    private static func emit(scope: String, operation: String, size: Int,
                             iterations: Int, nanoseconds: UInt64, checksum: String) throws {
        let object: [String: Any] = [
            "scope": scope, "operation": operation, "size": size,
            "iterations": iterations, "elapsed_ns": nanoseconds,
            "checksum": checksum,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func runCore(_ inputs: Inputs, size: Int, cold: Int, warm: Int) throws {
        var tabs = OpenVideoTabs()
        let unique = elapsed {
            for _ in 0..<cold {
                tabs = OpenVideoTabs()
                for source in inputs.sources { tabs.add(source) }
            }
        }
        precondition(tabs.items.map(\.source) == inputs.sources && tabs.selectedID == nil)
        try emit(scope: "core", operation: "unique_add", size: size, iterations: cold,
                 nanoseconds: unique, checksum: checksum(tabs))

        let last = inputs.sources[size - 1]
        var lastID = tabs.items[size - 1].id
        var observedID = lastID
        let duplicate = elapsed {
            for _ in 0..<warm { observedID = tabs.add(last) }
        }
        precondition(observedID == lastID && tabs.items.count == size)
        try emit(scope: "core", operation: "duplicate_last", size: size, iterations: warm,
                 nanoseconds: duplicate, checksum: checksum(tabs))

        let record = elapsed {
            for tick in 0..<warm {
                tabs.record(source: last, position: Double(tick), wasPaused: tick.isMultiple(of: 2),
                            playlist: inputs.playlist, folder: inputs.folder)
            }
        }
        precondition(tabs.items[size - 1].position == Double(warm - 1))
        precondition(tabs.items[size - 1].playlist == inputs.playlist && tabs.items.count == size)
        try emit(scope: "core", operation: "record_last", size: size, iterations: warm,
                 nanoseconds: record, checksum: checksum(tabs))

        if size <= 10 {
            tabs.select(lastID)
            let close = elapsed {
                for _ in 0..<warm {
                    tabs.close(lastID)
                    lastID = tabs.add(last)
                    tabs.select(lastID)
                }
            }
            precondition(tabs.items.map(\.source) == inputs.sources && tabs.selectedID == lastID)
            precondition(tabs.items[size - 1].position == 0)
            try emit(scope: "core", operation: "close_reopen_last", size: size, iterations: warm,
                     nanoseconds: close, checksum: checksum(tabs))
        }
    }

    private static func runStore(_ inputs: Inputs, size: Int, cold: Int, warm: Int) throws {
        var store = OpenVideoTabStore()
        let unique = elapsed {
            for _ in 0..<cold {
                store = OpenVideoTabStore()
                for source in inputs.sources { store.add(source) }
            }
        }
        precondition(store.items.map(\.source) == inputs.sources && store.selectedID == nil)
        try emit(scope: "store", operation: "unique_add", size: size, iterations: cold,
                 nanoseconds: unique, checksum: checksum(store))

        let last = inputs.sources[size - 1]
        var lastID = store.items[size - 1].id
        var observedID = lastID
        let duplicate = elapsed {
            for _ in 0..<warm { observedID = store.add(last) }
        }
        precondition(observedID == lastID && store.items.count == size)
        try emit(scope: "store", operation: "duplicate_last", size: size, iterations: warm,
                 nanoseconds: duplicate, checksum: checksum(store))

        let record = elapsed {
            for tick in 0..<warm {
                store.record(source: last, position: Double(tick), wasPaused: tick.isMultiple(of: 2),
                             playlist: inputs.playlist, folder: inputs.folder)
            }
        }
        precondition(store.tab(id: lastID)?.position == Double(warm - 1))
        precondition(store.tab(id: lastID)?.playlist == inputs.playlist && store.items.count == size)
        try emit(scope: "store", operation: "record_last", size: size, iterations: warm,
                 nanoseconds: record, checksum: checksum(store))

        if size <= 10 {
            store.select(lastID)
            let close = elapsed {
                for _ in 0..<warm {
                    store.close(lastID)
                    lastID = store.add(last)
                    store.select(lastID)
                }
            }
            precondition(store.items.map(\.source) == inputs.sources && store.selectedID == lastID)
            precondition(store.tab(id: lastID)?.position == 0)
            try emit(scope: "store", operation: "close_reopen_last", size: size, iterations: warm,
                     nanoseconds: close, checksum: checksum(store))
        }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, ["core", "store"].contains(arguments[1]),
              let size = Int(arguments[2]), size > 0,
              let cold = Int(arguments[3]), cold > 0,
              let warm = Int(arguments[4]), warm > 0
        else {
            FileHandle.standardError.write(Data(
                "Usage: TabAdmissionBenchmark core|store SIZE COLD_ITERATIONS WARM_ITERATIONS\n".utf8))
            throw InvocationError.usage
        }
        let inputs = Inputs(size: size)
        if arguments[1] == "core" { try runCore(inputs, size: size, cold: cold, warm: warm) }
        else { try runStore(inputs, size: size, cold: cold, warm: warm) }
    }
}
