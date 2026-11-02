import Foundation
import ReloadSelection
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Fixture {
    let name: String
    var directories: Set<String> = []
    var rescans: Set<String> = []
    var trees: Set<String> = []
    var roots: [URL] = []
    var expanded: Set<String> = []
}

private func directory(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
}

private func workload(
    _ name: String, roots: Int, paths: Int, expandedEvery: Int,
    outsideEvery: Int = 0, unicode: Bool = false, overlapping: Bool = false
) -> Fixture {
    let prefix = unicode ? "/Médiathèque/日本語/🎞️" : "/Media"
    let rootPaths = (0..<roots).map { index in
        overlapping ? prefix + String(repeating: "/Nested", count: index) : "\(prefix)/Root\(index)"
    }
    var input = Fixture(name: name, roots: rootPaths.map(directory))
    for index in 0..<paths {
        let root = rootPaths.isEmpty ? prefix : rootPaths[index % rootPaths.count]
        let outside = outsideEvery > 0 && index % outsideEvery == 0
        let path = "\(outside ? "/Inactive" : root)/Season\(index)/Folder"
        input.directories.insert(path)
        if expandedEvery > 0 && index % expandedEvery == 0 { input.expanded.insert(path) }
    }
    return input
}

private func workloads() -> [Fixture] {
    [
        Fixture(name: "single-root-event", directories: ["/Media/Movies"], roots: [directory("/Media/Movies")]),
        workload("single-expanded-folder", roots: 1, paths: 1, expandedEvery: 1),
        workload("single-collapsed-folder", roots: 1, paths: 1, expandedEvery: 0),
        workload("mixed-64-one-root", roots: 1, paths: 64, expandedEvery: 4, outsideEvery: 5),
        workload("mixed-512-eight-roots", roots: 8, paths: 512, expandedEvery: 4, outsideEvery: 5),
        workload("collapsed-4096-eight-roots", roots: 8, paths: 4096, expandedEvery: 0),
        workload("expanded-512-eight-roots", roots: 8, paths: 512, expandedEvery: 1),
        workload("expanded-512-32-roots", roots: 32, paths: 512, expandedEvery: 1),
        workload("inactive-512-eight-roots", roots: 8, paths: 512, expandedEvery: 1, outsideEvery: 1),
        workload("overlapping-512-eight-roots", roots: 8, paths: 512, expandedEvery: 1, overlapping: true),
        workload("unicode-512-eight-roots", roots: 8, paths: 512, expandedEvery: 4, outsideEvery: 5, unicode: true),
        Fixture(name: "root-rescan-eight-roots", rescans: Set((0..<8).map { "/Media/Root\($0)" }),
                roots: (0..<8).map { directory("/Media/Root\($0)") }),
        Fixture(name: "empty-plan-eight-roots", roots: (0..<8).map { directory("/Media/Root\($0)") }),
        workload("no-active-roots-512-paths", roots: 0, paths: 512, expandedEvery: 1),
    ]
}

@MainActor
private func select(_ fixture: Fixture) -> Set<String> {
    ReloadSelectionAPI.select(
        directoriesToReload: fixture.directories, rootsToRescan: fixture.rescans,
        activeRoots: fixture.roots, expandedFolderIDs: fixture.expanded,
        treesToInvalidate: fixture.trees
    )
}

private func exactPaths(_ paths: Set<String>) -> [[UInt8]] {
    paths.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

#if DIFFERENTIAL_VERIFY
@MainActor
private func verify() throws {
    var cases = 0
    var selectedPaths = 0
    var digest: UInt64 = 14_695_981_039_346_656_037
    func check(_ fixture: Fixture) {
        let actual = exactPaths(select(fixture))
        let expected = exactPaths(ReloadSelectionAPI.baselineSelect(
            directoriesToReload: fixture.directories, rootsToRescan: fixture.rescans,
            activeRoots: fixture.roots, expandedFolderIDs: fixture.expanded,
            treesToInvalidate: fixture.trees
        ))
        precondition(actual == expected, "Exact UTF-8 result mismatch: \(fixture.name)")
        cases += 1
        selectedPaths += actual.count
        for path in actual {
            for byte in path { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
            digest = (digest ^ 0xff) &* 1_099_511_628_211
        }
    }
    for input in workloads() { check(input) }

    let nfc = "/Café"
    let nfd = "/Cafe\u{301}"
    let roots: [[URL]] = [
        [], [directory("/")], [directory("/Movies")],
        [directory("/Movies"), directory("/Movies/Season")],
        [directory("/Movies/Season"), directory("/Movies")],
        [directory("/Movies"), directory("/Movies"), directory("/Movies2")],
        [directory("/Movies/../Movies/./")],
        [URL(string: "file://localhost/Movies/Season/../")!],
        [directory(nfc)], [directory(nfd)], [directory(nfc), directory(nfd)],
        [directory("/日本語/🎞️")],
        [URL(string: "https://example.invalid/Movies")!],
        [URL(string: "file://server.invalid/Movies")!],
        [URL(string: "https://example.invalid")!],
        [URL(string: "https://example.invalid")!, directory("/")],
        [URL(string: "https://example.invalid/Caf%C3%A9")!, URL(string: "https://example.invalid/Cafe%CC%81")!],
        [URL(string: "https://example.invalid/Cafe%CC%81")!, URL(string: "https://example.invalid/Caf%C3%A9")!],
    ]
    let paths = [
        "", "/", "Movies", "/Movies", "/Movies/", "/Movies/Season", "/Movies/Season/Episode",
        "/Movies2", "/Movies-old", "/Movie", "/Other/Expanded", "/Movies/../Other", "/Movies/./Season",
        "/Movies/Season/", nfc, nfd, nfc + "/Season", nfd + "/Season", nfc + "2/Season",
        nfd + "2/Season", "/日本語/🎞️", "/日本語/🎞️/Season", "/Movies/\u{301}/Episode",
        "/Movies/é", "/Movies/e\u{301}", "/Movies/\u{200d}/Episode", "/Movies//Season",
    ]
    let expansions: [Set<String>] = [[], Set(paths), Set(paths.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)),
                                   ["/Movies/Season", nfc + "/Season"], [nfd + "/Season", "/Other/Expanded"]]
    for (rootIndex, rootSet) in roots.enumerated() {
        for (expansionIndex, expansion) in expansions.enumerated() {
            for split in 0...paths.count {
                // Both union sides deliberately overlap; each side also has
                // canonically equal but byte-distinct spellings in some cases.
                check(Fixture(name: "matrix-\(rootIndex)-\(expansionIndex)-\(split)",
                    directories: Set(paths.prefix(split)), rescans: Set(paths.dropFirst(split / 2)),
                    trees: ["/Movies/TreeOnly", "/Inactive/TreeOnly"], roots: rootSet,
                    expanded: expansion.union(["/Movies/TreeOnly", "/Inactive/TreeOnly"])))
            }
            for path in paths {
                check(Fixture(name: "single-\(rootIndex)-\(expansionIndex)-\(path)", directories: [path],
                              roots: rootSet, expanded: expansion))
            }
            check(Fixture(name: "tree-only-\(rootIndex)-\(expansionIndex)", trees: Set(paths),
                          roots: rootSet, expanded: expansion))
        }
    }
    try emit(["cases": cases, "selected_paths": selectedPaths, "exact_utf8": true, "checksum": digest])
}
#endif

@main
private struct Main {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let fixtures = workloads()
        if arguments == ["--catalog"] {
            try emit(["workloads": fixtures.map { input in
                ["name": input.name, "paths": input.directories.union(input.rescans).count,
                 "roots": input.roots.count, "expanded": input.expanded.count] as [String: Any]
            }])
            return
        }
        if arguments == ["--verify"] {
            #if DIFFERENTIAL_VERIFY
            try verify()
            return
            #else
            preconditionFailure("Verification requires the differential binary")
            #endif
        }
        guard arguments.count == 4, arguments[0] == "--case", arguments[2] == "--iterations",
              let input = fixtures.first(where: { $0.name == arguments[1] }),
              let iterations = Int(arguments[3]), iterations > 0 else {
            fatalError("Usage: --catalog | --verify | --case NAME --iterations N")
        }
        var warmupChecksum = 0
        for _ in 0..<8 { warmupChecksum &+= select(input).count }
        var checksum = 0
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= select(input).count }
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        try emit(["workload": input.name, "iterations": iterations, "operations": iterations,
                  "paths_per_call": input.directories.union(input.rescans).count,
                  "elapsed_ns": wall, "cpu_ns": cpu, "checksum": checksum, "warmup_checksum": warmupChecksum])
    }
}
