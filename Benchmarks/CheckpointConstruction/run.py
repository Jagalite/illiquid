#!/usr/bin/env python3
"""Compare complete production checkpoint construction on macOS."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CORE = [
    "Playlist/FolderPlaylist.swift",
    "Playlist/PlaylistMutation.swift",
    "Utilities/NaturalFilenameOrdering.swift",
    "Utilities/NormalizedFileURL.swift",
    "Utilities/MediaFileSupport.swift",
    "Player/MediaSource.swift",
    "Persistence/PlaybackSessionStore.swift",
    "Persistence/LegacyPreferencesMigration.swift",
    "Utilities/LifecyclePerformance.swift",
]
CHECKPOINT = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE_TESTS = [
    "PlaybackSessionStoreTests.swift", "PlaylistMutationTests.swift",
    "FolderPlaylistTests.swift", "UtilitiesTests.swift",
]
PLAYER_TEST = "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift"
PATTERNS = [
    "first", "middle", "last", "no-folder", "nil-index", "stale-index",
    "stale-first", "out-of-range-index", "missing", "remote",
]
CASES = [(n, pattern) for n in [16, 256, 1024] for pattern in PATTERNS]
CASES += [(1, "first"), (1, "missing"), (0, "empty")]

PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "CheckpointConstructionQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .executableTarget(name: "CheckpointDriver", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    ]
)
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


class Run:
    def __init__(self, output):
        self.output = output
        (output / "logs").mkdir()
        self.sequence = 0
        self.env = os.environ.copy()
        self.env["SWIFT_DETERMINISTIC_HASHING"] = "1"
        self.env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
        self.env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")

    def command(self, args, label, timeout=600):
        self.sequence += 1
        args = [str(value) for value in args]
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=self.env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
        log.write_bytes(result.stdout)
        row = dict(sequence=self.sequence, args=args, cwd=str(ROOT), returncode=result.returncode,
                   seconds=time.monotonic() - started, log=str(log.relative_to(self.output)))
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"command failed; {log}: {result.stdout.decode(errors='replace')[-6000:]}")
        return result.stdout


def stage(run, manifest):
    """Copy complete files; never rewrite or extract production declarations."""
    originals = {}
    for path in [*["Sources/IlliquidCore/" + name for name in CORE], CHECKPOINT]:
        originals[path] = run.command(["git", "show", f"{BASELINE}:{path}"], "baseline-source")
        if path != CHECKPOINT and originals[path] != (ROOT / path).read_bytes():
            raise RuntimeError("Shared production dependency changed; requalify the baseline: " + path)
    sources = manifest["sources"] = {}
    for variant in ["baseline", "candidate"]:
        package = run.output / "packages" / variant
        for name in ["Sources/IlliquidCore", "Sources/IlliquidPlayer", "Sources/CheckpointDriver",
                     "Tests/IlliquidCoreTests", "Tests/IlliquidPlayerTests"]:
            (package / name).mkdir(parents=True)
        (package / "Package.swift").write_text(PACKAGE)
        for path, original in originals.items():
            raw = original if variant == "baseline" else (ROOT / path).read_bytes()
            module = "IlliquidPlayer" if path == CHECKPOINT else "IlliquidCore"
            (package / "Sources" / module / Path(path).name).write_bytes(raw)
            sources[variant + ":" + path] = digest(raw)
        for name in CORE_TESTS:
            source = ROOT / "Tests/IlliquidCoreTests" / name
            shutil.copyfile(source, package / "Tests/IlliquidCoreTests" / name)
            sources[str(source.relative_to(ROOT))] = digest(source.read_bytes())
        shutil.copyfile(ROOT / PLAYER_TEST, package / "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift")
        shutil.copyfile(HERE / "Driver.swift", package / "Sources/CheckpointDriver/Driver.swift")
    sources[PLAYER_TEST] = digest((ROOT / PLAYER_TEST).read_bytes())
    sources["Benchmarks/CheckpointConstruction/Driver.swift"] = digest((HERE / "Driver.swift").read_bytes())
    sources["Benchmarks/CheckpointConstruction/run.py"] = digest(Path(__file__).read_bytes())
    manifest["package_sha256"] = digest(PACKAGE.encode())
    shutil.copyfile(__file__, run.output / "runner.snapshot.py")


def build_and_verify(run, swift, manifest, summary):
    binaries = {}
    verification = {}
    for variant in ["baseline", "candidate"]:
        package = run.output / "packages" / variant
        common = [
            "--package-path", package, "--scratch-path", package / "build", "--jobs", "2",
            "--cache-path", run.output / "cache", "--config-path", run.output / "config",
            "--security-path", run.output / "security", "-Xswiftc", "-warnings-as-errors",
            "-Xswiftc", "-enable-testing",
        ]
        for configuration in ["debug", "release"]:
            print(f"Testing {variant} {configuration}", flush=True)
            result = run.command([swift, "test", *common, "-c", configuration, "--no-parallel"],
                                 f"tests-{variant}-{configuration}")
            summary["tests"].append(dict(variant=variant, configuration=configuration, passed=True))
            print("\n".join(result.decode(errors="replace").splitlines()[-4:]), flush=True)
        run.command([swift, "build", *common, "-c", "release", "--product", "CheckpointDriver"],
                    f"build-{variant}-driver")
        binary_dir = run.command([swift, "build", *common, "-c", "release", "--show-bin-path"],
                                 f"path-{variant}").decode().strip().splitlines()[-1]
        binary = Path(binary_dir) / "CheckpointDriver"
        binaries[variant] = binary
        manifest[variant + "_binary_sha256"] = digest(binary.read_bytes())
        raw = run.command([binary, "--verify"], f"verify-{variant}")
        verification[variant] = json.loads(raw)
        manifest[variant + "_verification_sha256"] = digest(raw)
        if verification[variant].get("passed") is not True:
            raise RuntimeError("Differential corpus did not pass")
    # Every full normalized JSON record is compared, not only a checksum/hash.
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Complete baseline and candidate verification records differ")
    summary["verification"] = dict(cases=verification["baseline"]["cases"],
                                   complete_records_equal=True)
    print("VERIFICATION " + json.dumps(summary["verification"], sort_keys=True), flush=True)
    return binaries


def observe(run, binary, count, pattern, iterations, label):
    row = json.loads(run.command([binary, count, pattern, iterations], label))
    if (row["count"], row["pattern"], row["iterations"]) != (count, pattern, iterations):
        raise RuntimeError("Workload identity mismatch")
    if row["cpu_ns"] <= 0 or row["wall_ns"] <= 0:
        raise RuntimeError("Invalid timer observation")
    return row


def measure(run, args, binaries, summary):
    calibration = []
    iterations_by_case = {}
    for count, pattern in CASES:
        iterations = 1
        for _ in range(4):
            row = observe(run, binaries["baseline"], count, pattern, iterations, "calibration")
            calibration.append(row)
            if row["cpu_ns"] >= args.target_ms * 800_000 or iterations >= 1_000_000:
                break
            iterations = min(1_000_000, max(iterations + 1, math.ceil(
                iterations * args.target_ms * 1_000_000 / row["cpu_ns"])))
        iterations_by_case[(count, pattern)] = iterations
    save(run.output / "calibration.json", calibration)
    rows = {case: {"baseline": [], "candidate": []} for case in CASES}
    for pair in range(args.pairs):
        # Rotate the workload order while balancing AB/BA for each workload.
        cases = CASES[pair:] + CASES[:pair]
        for count, pattern in cases:
            iterations = iterations_by_case[(count, pattern)]
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            paired = []
            for position, variant in enumerate(order):
                row = observe(run, binaries[variant], count, pattern, iterations,
                              f"pair-{pair}-{count}-{pattern}-{variant}")
                row.update(variant=variant, pair=pair, process_order=position)
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                rows[(count, pattern)][variant].append(row)
                paired.append(row)
            for key in ["fingerprint", "checksum", "output_count", "has_collection_folder"]:
                if paired[0][key] != paired[1][key]:
                    raise RuntimeError("Paired output differs: " + key)
        print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)

    for count, pattern in CASES:
        records = rows[(count, pattern)]
        iterations = iterations_by_case[(count, pattern)]
        result = dict(count=count, pattern=pattern, iterations=iterations)
        for metric in ["cpu_ns", "wall_ns"]:
            baseline = [row[metric] / iterations for row in records["baseline"]]
            candidate = [row[metric] / iterations for row in records["candidate"]]
            ratios = [c / b for b, c in zip(baseline, candidate)]
            result[metric] = {
                "baseline_median": statistics.median(baseline),
                "candidate_median": statistics.median(candidate),
                "baseline_range": [min(baseline), max(baseline)],
                "candidate_range": [min(candidate), max(candidate)],
                "paired_candidate_over_baseline_median": statistics.median(ratios),
                "paired_change_percent": 100 * (statistics.median(ratios) - 1),
                "paired_change_range_percent": [100 * (min(ratios) - 1), 100 * (max(ratios) - 1)],
                "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
            }
        summary["workloads"].append(result)
        print("WORKLOAD " + json.dumps(result, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("macOS is required: complete production sources import os.signpost")
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("pairs must be even and >= 2; target-ms must be finite and positive")
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift 6.1 or newer is required")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    run = Run(args.output)
    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": BASELINE, "platform": platform.platform(), "machine": platform.machine(),
        "pairs": args.pairs, "target_cpu_ms": args.target_ms,
        "warmup_iterations_per_process": 4, "hashing": "SWIFT_DETERMINISTIC_HASHING=1",
        "protocol": "complete production record; fresh process; balanced AB/BA; rotated workload order",
    }
    summary = dict(status="running", tests=[], workloads=[])
    try:
        manifest["candidate_commit"] = run.command(["git", "rev-parse", "HEAD"], "revision").decode().strip()
        manifest["worktree_status"] = run.command(["git", "status", "--porcelain=v1"], "status").decode()
        manifest["compiler"] = run.command([swift, "--version"], "swift-version").decode().strip()
        manifest["xcode"] = run.command(["xcodebuild", "-version"], "xcode-version").decode().strip()
        manifest["cpu"] = run.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").decode().strip()
        manifest["memory_bytes"] = run.command(["sysctl", "-n", "hw.memsize"], "memory").decode().strip()
        stage(run, manifest)
        save(args.output / "manifest.json", manifest)
        binaries = build_and_verify(run, swift, manifest, summary)
        if not args.tests_only:
            measure(run, args, binaries, summary)
        summary["status"] = "passed"
    except BaseException as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        raise
    finally:
        manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
        save(args.output / "manifest.json", manifest)
        save(args.output / "summary.json", summary)
        print("CHECKPOINT_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
        print("CHECKPOINT_MANIFEST " + json.dumps(manifest, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
