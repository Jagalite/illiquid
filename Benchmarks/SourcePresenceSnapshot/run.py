#!/usr/bin/env python3
"""Compare per-job source-presence snapshots using pinned production sources.

Swift 6.1+ / Python 3.10+, on macOS or Linux with glibc 2.33+. This measures
component allocator residency and snapshot construction, not player RSS or I/O.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCANNER = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
CASES = [
    "empty", "small-32-8", "repair-1000-100", "repair-10000-100",
    "repair-100000-100", "repair-100000-10000", "mixed-100000-100",
    "whole-tree-100000", "filesystem-root-10000",
]
CORE = ["MediaFileSupport.swift", "NormalizedFileURL.swift", "SourcePreparationExecutor.swift"]
APP = ["UI/SourceMediaPresenceRecomputation.swift", "App/SourceRootPruning.swift"]
TESTS = ["SourceMediaPresenceReuseTests.swift", "SourceMediaPresenceRecomputationTests.swift"]
METRICS = [
    "snapshotEntries", "snapshotCapacity", "snapshotCreationDeltaBytes",
    "liveSnapshotAndPublicationDeltaBytes", "snapshotReleaseDeltaBytes",
    "remainingPublicationDeltaBytes", "wallNanosecondsPerSnapshot", "cpuNanosecondsPerSnapshot",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def declaration(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"Declaration marker is no longer unique: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise RuntimeError(f"Unclosed declaration: {marker}")


def scanner_shell(source: str, variant: str) -> str:
    start = "                let reusableResults = "
    end = "                let cursor = SourceMediaPresenceCursor("
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError("Production snapshot extraction boundaries changed")
    fragment = source[source.index(start):source.index(end)]
    expected = "self.results.filter" if variant == "baseline" else "SourceMediaPresenceCursor.reusableResults"
    if expected not in fragment:
        raise RuntimeError(f"Unexpected {variant} snapshot implementation")
    fields = [
        "private(set) var results: [String: Bool] = [:]",
        "@ObservationIgnored private var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]",
    ]
    if any(source.count(field) != 1 for field in fields):
        raise RuntimeError("Production snapshot storage declarations changed")
    return ("import Foundation\nimport Observation\n\n"
            "@MainActor @Observable\nfinal class PresenceSnapshotBenchmarkScanner {\n"
            + "\n".join("    " + field for field in fields) + "\n"
            + f"    static let isScoped = {'true' if variant == 'candidate' else 'false'}\n"
            + """
    init(results: [String: Bool], summaries: [String: SourceMediaPresenceCursor.Summary]) {
        self.results = results
        self.summaries = summaries
    }

    @inline(never)
    func snapshot(in path: String) -> [String: Bool] {
""" + fragment + """
        return reusableResults
    }

    @inline(never)
    func publish(_ path: String, value: Bool) {
        results[path] = value
    }
}
""")


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output
        self.build = self.output / "build"
        self.env = os.environ.copy()
        self.env.update(
            CLANG_MODULE_CACHE_PATH=str(self.build / "module-cache"),
            SWIFT_MODULECACHE_PATH=str(self.build / "module-cache"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.build / "module-cache"),
            SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb", NO_COLOR="1",
        )

    def run(self, argv: list, name: str | None = None, timeout: int = 600) -> str:
        arguments = [str(value) for value in argv]
        started = time.time()
        result = subprocess.run(arguments, env=self.env, capture_output=True, text=True, timeout=timeout)
        append(self.output / "commands.jsonl", {
            "argv": arguments, "returncode": result.returncode,
            "elapsedSeconds": time.time() - started,
            "stdoutSHA256": digest(result.stdout.encode()), "stderr": result.stderr,
        })
        if name:
            (self.output / name).write_text(result.stdout + result.stderr)
        if result.returncode:
            (self.output / "failure.log").write_text(result.stdout + result.stderr)
            raise RuntimeError(f"Command failed: {arguments}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def stage(self, variant: str) -> dict:
        package = self.build / variant
        receipts = {}

        def put(relative: str, data: bytes, origin: str, transformation: str = "none") -> None:
            path = package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            receipts[relative] = {"origin": origin, "sha256": digest(data),
                                  "transformation": transformation}

        scanner_path = HERE / "baseline/SourceMediaPresenceScanner.swift" if variant == "baseline" else ROOT / SCANNER
        scanner = scanner_path.read_bytes()
        put("Sources/IlliquidApp/SourceMediaPresenceScanner.swift", scanner, str(scanner_path.relative_to(ROOT)))
        for name in CORE:
            path = ROOT / "Sources/IlliquidCore/Utilities" / name
            put("Sources/IlliquidCore/" + name, path.read_bytes(), str(path.relative_to(ROOT)))
        for name in APP:
            path = ROOT / "Sources/IlliquidApp" / name
            put("Sources/IlliquidApp/" + Path(name).name, path.read_bytes(), str(path.relative_to(ROOT)))
        identity_source = (ROOT / "Sources/IlliquidApp/UI/SourcesSidebar.swift").read_text()
        identity = "import Foundation\nimport IlliquidCore\n\n" + declaration(identity_source, "enum SourceTreeIdentity {") + "\n"
        put("Sources/IlliquidApp/SourceTreeIdentity.swift", identity.encode(),
            "Sources/IlliquidApp/UI/SourcesSidebar.swift", "exact SourceTreeIdentity declaration; imports added")
        shell = scanner_shell(scanner.decode(), variant)
        put("Sources/IlliquidApp/BenchmarkScanner.swift", shell.encode(), SCANNER,
            "exact snapshot statement and storage declarations in an observed MainActor shell; setup/publication adapters added")
        put("Sources/PresenceSnapshotBenchmark/Harness.swift", (HERE / "Harness.swift").read_bytes(),
            "Benchmarks/SourcePresenceSnapshot/Harness.swift")
        for relative in ["heap.c", "include/CPresenceHeap.h"]:
            put("Sources/CPresenceHeap/" + relative, (HERE / "CHeap" / relative).read_bytes(),
                "Benchmarks/SourcePresenceSnapshot/CHeap/" + relative)
        if variant == "candidate":
            for name in TESTS:
                path = ROOT / "Tests/IlliquidAppTests" / name
                put("Tests/IlliquidAppTests/" + name, path.read_bytes(), str(path.relative_to(ROOT)))
        targets = [
            '.target(name: "IlliquidCore")',
            '.target(name: "IlliquidApp", dependencies: ["IlliquidCore"])',
            '.target(name: "CPresenceHeap", publicHeadersPath: "include")',
            '.executableTarget(name: "PresenceSnapshotBenchmark", dependencies: ["IlliquidApp", "CPresenceHeap"])',
        ]
        if variant == "candidate":
            targets.append('.testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])')
        manifest = ('// swift-tools-version: 6.1\nimport PackageDescription\n'
                    'let package = Package(name: "SourcePresenceSnapshot", platforms: [.macOS("26.0")],\n'
                    'products: [.executable(name: "PresenceSnapshotBenchmark", targets: ["PresenceSnapshotBenchmark"])],\n'
                    'targets: [\n' + ',\n'.join(targets) + '\n], swiftLanguageModes: [.v6])\n')
        put("Package.swift", manifest.encode(), "generated isolated component package")
        return receipts

    def swift(self, variant: str, operation: str, configuration: str) -> list:
        command = [self.args.swift, operation, "--package-path", self.build / variant,
                   "-c", configuration, "--jobs", "2",
                   "--cache-path", self.build / "cache", "--config-path", self.build / "config",
                   "--security-path", self.build / "security", "-Xswiftc", "-warnings-as-errors",
                   "-Xswiftc", "-enable-testing"]
        if operation == "test":
            command.append("--no-parallel")
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def measure(self, executable: Path, case: str, iterations: int, seed: int) -> dict:
        row = json.loads(self.run([executable, case, iterations, seed], timeout=180))
        if (row["workload"], row["iterations"], row["seed"]) != (case, iterations, seed):
            raise RuntimeError("Measurement does not match requested fixture")
        if row["wallNanoseconds"] <= 0 or row["cpuNanoseconds"] <= 0:
            raise RuntimeError("Invalid timing sample")
        row["wallNanosecondsPerSnapshot"] = row["wallNanoseconds"] / iterations
        row["cpuNanosecondsPerSnapshot"] = row["cpuNanoseconds"] / iterations
        return row


def summarize(records: list[dict]) -> dict:
    result = {}
    for case in dict.fromkeys(row["workload"] for row in records):
        rows = [row for row in records if row["workload"] == case]
        summary = {}
        for variant in ["baseline", "candidate"]:
            values = [row for row in rows if row["variant"] == variant]
            summary[variant] = {metric: {
                "min": min(row[metric] for row in values),
                "median": statistics.median(row[metric] for row in values),
                "max": max(row[metric] for row in values),
            } for metric in METRICS}
        paired = {}
        for metric in ["liveSnapshotAndPublicationDeltaBytes", "wallNanosecondsPerSnapshot", "cpuNanosecondsPerSnapshot"]:
            reductions = []
            for pair in sorted({row["pair"] for row in rows}):
                samples = {row["variant"]: row for row in rows if row["pair"] == pair}
                for key in ["workload", "seed", "iterations", "reachableLookupReceipt"]:
                    if samples["baseline"][key] != samples["candidate"][key]:
                        raise RuntimeError(f"Pair parity failure: {case} / {pair} / {key}")
                before = samples["baseline"][metric]
                if before > 0:
                    reductions.append(100 * (1 - samples["candidate"][metric] / before))
            paired[metric] = ({"medianReductionPercent": statistics.median(reductions),
                               "minReductionPercent": min(reductions),
                               "maxReductionPercent": max(reductions),
                               "improvedPairs": sum(value > 0 for value in reductions),
                               "pairs": len(reductions)} if reductions else None)
        summary["paired"] = paired
        result[case] = summary
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=50)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; not final qualification")
    args = parser.parse_args()
    cases = args.cases.split(",")
    if (args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0
            or any(case not in CASES for case in cases) or len(cases) != len(set(cases))):
        parser.error("Use an even pair count >= 2, positive duration, and unique supported cases")
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use an empty output directory; preserve previous attempts")
    args.output.mkdir(parents=True, exist_ok=True)
    runner = Runner(args)
    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    if digest((HERE / "baseline/SourceMediaPresenceScanner.swift").read_bytes()) != baseline["sha256"]:
        raise RuntimeError("Pinned baseline hash mismatch")
    manifest = {
        "collectedAtUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": runner.run([args.swift, "--version"]).strip(),
        "gitHead": runner.run(["git", "-C", ROOT, "rev-parse", "HEAD"]).strip(),
        "gitStatus": runner.run(["git", "-C", ROOT, "status", "--porcelain"]).strip(),
        "baseline": baseline, "arguments": {**vars(args), "output": str(args.output)},
        "sourceReceipts": {},
        "harnessSHA256": {str(path.relative_to(HERE)): digest(path.read_bytes())
                          for path in [Path(__file__), HERE / "Harness.swift", HERE / "CHeap/heap.c",
                                       HERE / "CHeap/include/CPresenceHeap.h"]},
        "method": "Optimized observed MainActor snapshot expressions, exact cursor helper, separate module; balanced fresh-process AB/BA pairs; deterministic hashing with per-pair fixture seeds.",
        "memoryScope": "Allocator-accounted incremental bytes before snapshot, after snapshot, after one source publication, and after snapshot release. Not RSS, physical footprint, or whole-player memory.",
        "timingScope": "Snapshot construction and destruction only; excludes fixture setup, source publication, allocator sampling, lookup verification, traversal, and UI rendering.",
    }
    if platform.system() == "Darwin":
        manifest["hardware"] = runner.run(["sysctl", "hw.model", "machdep.cpu.brand_string"]).strip()
    for variant in ["baseline", "candidate"]:
        manifest["sourceReceipts"][variant] = runner.stage(variant)
    save(args.output / "manifest.json", manifest)
    if not args.skip_tests:
        for configuration in ["debug", "release"]:
            runner.run(runner.swift("candidate", "test", configuration),
                       name=f"candidate-{configuration}-tests.log")
            print(f"Candidate {configuration} regression tests passed", flush=True)
        save(args.output / "tests.json", {"candidateDebug": "passed", "candidateRelease": "passed"})
    if args.tests_only:
        return
    executables = {}
    for variant in ["baseline", "candidate"]:
        runner.run(runner.swift(variant, "build", "release") + ["--product", "PresenceSnapshotBenchmark"],
                   name=f"{variant}-build.log")
        binary_dir = runner.run(runner.swift(variant, "build", "release") + ["--show-bin-path"]).strip()
        executables[variant] = Path(binary_dir) / "PresenceSnapshotBenchmark"
    manifest["binarySHA256"] = {variant: digest(path.read_bytes()) for variant, path in executables.items()}
    save(args.output / "manifest.json", manifest)
    records = []
    for case in cases:
        calibration = {variant: runner.measure(executable, case, 3, 1000)
                       for variant, executable in executables.items()}
        iterations = max(1, min(100_000, math.ceil(args.target_ms * 1_000_000 /
                         min(row["wallNanosecondsPerSnapshot"] for row in calibration.values()))))
        append(args.output / "calibration.jsonl", {"case": case, "iterations": iterations,
                                                  "samples": calibration})
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            paired = {}
            for variant in order:
                row = runner.measure(executables[variant], case, iterations, 73 + pair * 101)
                row.update(variant=variant, pair=pair)
                records.append(row)
                append(args.output / "measurements.jsonl", row)
                paired[variant] = row
            if paired["baseline"]["reachableLookupReceipt"] != paired["candidate"]["reachableLookupReceipt"]:
                raise RuntimeError(f"Reachable lookup mismatch: {case}, pair {pair}")
        save(args.output / "summary.json", summarize(records))
        summary = summarize(records)[case]
        print(f'{case}: live snapshot + publication bytes '
              f'{summary["baseline"]["liveSnapshotAndPublicationDeltaBytes"]["median"]} -> '
              f'{summary["candidate"]["liveSnapshotAndPublicationDeltaBytes"]["median"]}', flush=True)
    save(args.output / "completion.json", {"status": "passed", "cases": len(cases),
         "pairs": args.pairs * len(cases), "samples": len(records),
         "reachableLookupParity": "passed", "testsSkipped": args.skip_tests})


if __name__ == "__main__":
    main()
