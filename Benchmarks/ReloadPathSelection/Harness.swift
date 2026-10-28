import Foundation
@testable import IlliquidApp
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Calls the complete production consumer, compiled in a separate module.
/// Fixture creation, the pinned oracle, and full equality checks are untimed.
@main @MainActor
struct ReloadBenchmark {
    struct Workload {
        let plan: SourceFilesystemInvalidationPlan
        let roots: [URL]
        let expanded: Set<String>
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    static func workload(_ name: String) -> Workload {
        if name == "empty-plan" {
            return Workload(plan: .init(), roots: [url("/library/root-0")], expanded: [])
        }
        if name == "no-active-roots" {
            return Workload(plan: .init(directoriesToReload: ["/library/expanded"]),
                            roots: [], expanded: ["/library/expanded"])
        }
        if name == "root-rescan-1" || name == "root-rescan-32" {
            let count = name == "root-rescan-1" ? 1 : 32
            let paths = (0..<count).map { "/library/root-\($0)" }
            return Workload(plan: .init(rootsToRescan: Set(paths)),
                            roots: paths.map(url), expanded: [])
        }
        let parameters: (Int, Int, String) = switch name {
        case "expanded-1x1": (1, 1, "expanded")
        case "expanded-1x32": (1, 32, "expanded")
        case "expanded-1x256": (1, 256, "expanded")
        case "mixed-8x256": (8, 256, "mixed")
        case "mixed-32x1024": (32, 1024, "mixed")
        case "collapsed-32x1024": (32, 1024, "collapsed")
        case "outside-8x256": (8, 256, "outside")
        case "filesystem-root-256": (1, 256, "filesystem-root")
        case "overlapping-8x256": (8, 256, "overlapping")
        default: fatalError("Unknown workload: \(name)")
        }
        let (rootCount, count, kind) = parameters
        let roots: [URL]
        if kind == "filesystem-root" {
            roots = [url("/")]
        } else if kind == "overlapping" {
            roots = (0..<rootCount).map {
                url("/library" + String(repeating: "/nested", count: $0))
            }
        } else {
            roots = (0..<rootCount).map { url("/library/root-\($0)") }
        }
        var paths: Set<String> = []
        var expanded: Set<String> = []
        for index in 0..<count {
            let path: String
            if kind == "outside" || (kind == "mixed" && index % 4 == 0) {
                // A lexical sibling, not a descendant of root-0.
                path = "/library/root-0-sibling/folder-\(index)"
            } else if kind == "filesystem-root" {
                path = "/library/folder-\(index)"
            } else if kind == "overlapping" {
                path = "/library" + String(repeating: "/nested", count: index % rootCount)
                    + "/folder-\(index)"
            } else {
                path = "/library/root-\(index % rootCount)/folder-\(index)"
            }
            paths.insert(path)
            if kind != "collapsed" && (kind != "mixed" || index % 3 != 0) {
                expanded.insert(path)
            }
        }
        return Workload(plan: .init(directoriesToReload: paths), roots: roots, expanded: expanded)
    }

    static let names = [
        "empty-plan", "no-active-roots", "root-rescan-1", "root-rescan-32",
        "expanded-1x1", "expanded-1x32", "expanded-1x256", "mixed-8x256",
        "mixed-32x1024", "collapsed-32x1024", "outside-8x256",
        "filesystem-root-256", "overlapping-8x256",
    ]

    static func candidate(_ input: Workload) -> Set<String> {
        SourceTreeDirectoryState.reloadPaths(for: input.plan, activeRoots: input.roots,
                                             expandedFolderIDs: input.expanded)
    }

    static func reference(_ input: Workload) -> Set<String> {
        BaselineSourceTreeDirectoryState.reloadPaths(for: input.plan, activeRoots: input.roots,
                                                     expandedFolderIDs: input.expanded)
    }

    static func fingerprint(_ paths: Set<String>) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for path in paths.sorted() {
            for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            hash = (hash ^ 0xff) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func cpuNanoseconds() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func verify() throws {
        let relative = URL(fileURLWithPath: "../Movies", isDirectory: true,
                           relativeTo: url("/Volumes/Reference/Child"))
        let rootSets: [[URL]] = [
            [], [url("/")], [url("/Movies")], [url("/Movies"), url("/Movies/Season")],
            [url("/Movies"), url("/Movies/./"), url("/Movies/Other/../")],
            [url("/Movies"), url("/Movies2")], [url("/Café"), url("/Cafe\u{301}")],
            [relative], [URL(string: "https://example.invalid/Movies/../Archive")!],
            [URL(string: "file://localhost/Movies/")!, url("/日本語/映画")],
        ]
        let paths = [
            "", "/", "/Movies", "/Movies/", "/Movies/Season", "/Movies/Season/Episode",
            "/Movies/Collapsed", "/Movies2", "/Movies2/Season", "/Movies-old",
            "/Movie", "/Other/Expanded", "/Café", "/Cafe\u{301}/Season", "/Café2/Season",
            "/日本語/映画", "/日本語/映画/Season", "/Volumes/Reference/Movies",
            "/Volumes/Reference/Movies/Season", "/Archive", "/Archive/Season",
            "/Movies/./Season", "Movies/Season", "/Movies/%20", "/Movies/Space Folder",
        ]
        var state: UInt64 = 0x5245_4c4f_4144
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 32
        }
        var count = 0
        var receipts: [String] = []
        for roots in rootSets {
            for _ in 0..<128 {
                var plan = SourceFilesystemInvalidationPlan()
                var expanded: Set<String> = []
                for path in paths {
                    let bits = next()
                    if bits & 1 != 0 { plan.directoriesToReload.insert(path) }
                    if bits & 2 != 0 { plan.rootsToRescan.insert(path) }
                    if bits & 4 != 0 { plan.treesToInvalidate.insert(path) }
                    if bits & 8 != 0 { expanded.insert(path) }
                }
                let input = Workload(plan: plan, roots: roots, expanded: expanded)
                let actual = candidate(input), expected = reference(input)
                precondition(actual == expected, "Reload selection differs in case \(count)")
                receipts.append(fingerprint(actual))
                count += 1
            }
        }
        for name in names {
            let input = workload(name)
            let actual = candidate(input)
            precondition(actual == reference(input), "Workload differs: \(name)")
            receipts.append(fingerprint(actual))
            count += 1
        }
        try emit(["verified_cases": count, "receipts": receipts])
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "verify" { try verify(); return }
        precondition(args.count == 4 && args[1] == "bench",
                     "usage: ReloadBenchmark verify | bench CASE ITERATIONS")
        let input = workload(args[2])
        let iterations = Int(args[3])!
        precondition(iterations > 0)
        let expected = reference(input)
        for _ in 0..<5 { precondition(candidate(input) == expected) }
        var checksum: UInt64 = 0
        var last: Set<String> = []
        let cpuStart = cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            last = candidate(input)
            checksum &+= UInt64(last.count)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpu = cpuNanoseconds() - cpuStart
        precondition(last == expected, "Full reload set differs")
        try emit([
            "case": args[2], "iterations": iterations, "elapsed_ns": elapsed, "cpu_ns": cpu,
            "checksum": checksum, "input_paths": input.plan.directoriesToReload.union(input.plan.rootsToRescan).count,
            "active_roots": input.roots.count, "expanded_paths": input.expanded.count,
            "output_paths": last.count, "fingerprint": fingerprint(last), "oracle_equal": true,
        ])
    }
}
