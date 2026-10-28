#!/usr/bin/env python3
"""Native, paired measurements of complete PlaybackCheckpoint.record() calls."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CHECKPOINT = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE = [
    "Persistence/LegacyPreferencesMigration.swift",
    "Persistence/PlaybackSessionStore.swift",
    "Player/MediaSource.swift",
    "Playlist/FolderPlaylist.swift",
    "Playlist/PlaylistMutation.swift",
    "Utilities/LifecyclePerformance.swift",
    "Utilities/NaturalFilenameOrdering.swift",
    "Utilities/NormalizedFileURL.swift",
]
CORE_TESTS = [
    "PlaylistMutationTests.swift",
    "PlaylistDeduplicationTests.swift",
    "PlaylistSessionRecordTests.swift",
    "PlaybackSessionStoreTests.swift",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "CheckpointConstruction",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "CheckpointBenchmark", targets: ["CheckpointBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .executableTarget(name: "CheckpointBenchmark", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
        .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
"""


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=40)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--pairs must be positive and even (at least 2); --target-ms must be finite and positive")
    if sys.platform != "darwin":
        parser.error("Use native macOS: the exact sources include os.signpost")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty; existing evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"
    logs.mkdir()
    commands = []
    observations = []

    def command(argv, label, cwd=ROOT):
        argv = [str(arg) for arg in argv]
        log = logs / f"{len(commands):04d}-{label}.log"
        started = time.time()
        completed = subprocess.run(
            argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=600, check=False
        )
        log.write_text(completed.stdout)
        commands.append({
            "argv": argv, "cwd": str(cwd), "log": str(log.relative_to(output)),
            "exitCode": completed.returncode, "elapsedSeconds": time.time() - started
        })
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if completed.returncode:
            print(completed.stdout[-16000:], flush=True)
            raise RuntimeError(f"{label} failed ({completed.returncode}); see {log}")
        return completed.stdout.strip()

    revision = command(["git", "rev-parse", "HEAD"], "revision")
    baseline = command(["git", "show", f"{BASE}:{CHECKPOINT}"], "baseline") + "\n"
    # Copy exact common supporting sources into both packages. Only the
    # checkpoint implementation differs; no imports or source bodies are edited.
    manifest = {
        "baselineCheckpointRevision": BASE,
        "candidateRevision": revision,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "swift": command(["swift", "--version"], "swift-version"),
        "xcode": command(["xcodebuild", "-version"], "xcode-version"),
        "macOS": command(["sw_vers"], "macos-version"),
        "cpu": command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu"),
        "pairs": args.pairs,
        "targetMilliseconds": args.target_ms,
        "sourceSHA256": {},
        "binarySHA256": {},
        "method": "Complete record construction, warm fixtures, alternating fresh-process pairs; no timing exclusions.",
    }
    shutil.copy2(__file__, output / "run.py")
    shutil.copy2(ROOT / "Benchmarks/CheckpointConstruction/Benchmark.swift", output / "Benchmark.swift")
    packages = {}
    for variant in ("baseline", "candidate"):
        package = output / "packages" / variant
        packages[variant] = package
        for directory in ("Sources/IlliquidCore", "Sources/IlliquidPlayer",
                          "Sources/CheckpointBenchmark", "Tests/IlliquidPlayerTests",
                          "Tests/IlliquidCoreTests"):
            (package / directory).mkdir(parents=True, exist_ok=True)
        (package / "Package.swift").write_text(PACKAGE)
        for relative in CORE:
            shutil.copy2(ROOT / "Sources/IlliquidCore" / relative,
                         package / "Sources/IlliquidCore" / Path(relative).name)
        checkpoint = package / "Sources/IlliquidPlayer/PlaybackCheckpointWriter.swift"
        if variant == "baseline":
            checkpoint.write_text(baseline)
        else:
            shutil.copy2(ROOT / CHECKPOINT, checkpoint)
        shutil.copy2(ROOT / "Benchmarks/CheckpointConstruction/Benchmark.swift",
                     package / "Sources/CheckpointBenchmark/Benchmark.swift")
        shutil.copy2(ROOT / "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift",
                     package / "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift")
        for name in CORE_TESTS:
            shutil.copy2(ROOT / "Tests/IlliquidCoreTests" / name,
                         package / "Tests/IlliquidCoreTests" / name)
        for source in sorted(package.rglob("*.swift")):
            manifest["sourceSHA256"][str(source.relative_to(output))] = sha256(source)

    # On shared development machines, submit this entire runner through Kyoto
    # as documented in AGENTS.md. Hosted CI has no shared queue, and this runner
    # serializes all builds in two separate package directories.
    if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
        print("Kyoto is unavailable; building serially in isolated packages.", flush=True)
    for variant, package in packages.items():
        for configuration in ("debug", "release"):
            result = command([
                "swift", "test", "--package-path", package,
                "--configuration", configuration, "--no-parallel",
                "-Xswiftc", "-enable-testing"
            ], f"{variant}-{configuration}-tests")
            print(f"CHECKPOINT_TESTS {variant} {configuration}\n{result[-8000:]}", flush=True)

    binaries = {}
    if not args.tests_only:
        for variant, package in packages.items():
            command([
                "swift", "build", "--package-path", package, "--configuration", "release",
                "--product", "CheckpointBenchmark", "-Xswiftc", "-enable-testing"
            ], f"{variant}-release-build")
            binary_directory = command([
                "swift", "build", "--package-path", package, "--configuration", "release",
                "--show-bin-path"
            ], f"{variant}-bin-path").splitlines()[-1]
            binary = Path(binary_directory) / "CheckpointBenchmark"
            binaries[variant] = binary
            manifest["binarySHA256"][variant] = sha256(binary)

    manifest["sourceSHA256"]["run.py"] = sha256(output / "run.py")
    manifest["sourceSHA256"]["Benchmark.swift"] = sha256(output / "Benchmark.swift")
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("CHECKPOINT_MANIFEST " + json.dumps(manifest, sort_keys=True), flush=True)
    if args.tests_only:
        return

    names = json.loads(command([binaries["baseline"], "--list"], "list-baseline"))
    candidate_names = json.loads(command([binaries["candidate"], "--list"], "list-candidate"))
    if names != candidate_names:
        raise RuntimeError("Baseline and candidate workloads differ")
    canonical = {}

    def observe(variant, name, iterations, phase, pair=None, order=None):
        record = json.loads(command(
            [binaries[variant], name, iterations],
            f"{phase}-{variant}-{name}"
        ))
        if record["workload"] != name or record["iterations"] != iterations or record["elapsedNanoseconds"] <= 0:
            raise RuntimeError("Malformed benchmark observation")
        identity = (record["resultSHA256"], record["inputCount"], record["outputCount"],
                    record["hasCollectionFolder"])
        if name in canonical and canonical[name] != identity:
            raise RuntimeError(f"Record contents changed for {name}: {variant}")
        canonical[name] = identity
        record.update(variant=variant, phase=phase, pair=pair, order=order)
        observations.append(record)
        with (output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        print("CHECKPOINT_OBSERVATION " + json.dumps(record, sort_keys=True), flush=True)
        return record

    rows = []
    for name in names:
        iterations = 1
        for _ in range(6):
            calibration = observe("baseline", name, iterations, "calibration")
            elapsed = calibration["elapsedNanoseconds"] / 1_000_000
            if elapsed >= args.target_ms / 2 or iterations >= 500000:
                break
            iterations = min(500000, max(iterations + 1, math.ceil(iterations * args.target_ms / elapsed)))
        retained = {"baseline": [], "candidate": []}
        reductions = []
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            pair_records = {}
            for position, variant in enumerate(order):
                result = observe(variant, name, iterations, "measurement", pair, position)
                pair_records[variant] = result
                retained[variant].append(result["elapsedNanoseconds"] / iterations)
            before, after = pair_records["baseline"], pair_records["candidate"]
            if before["checksum"] != after["checksum"]:
                raise RuntimeError(f"Timed checksums differ for {name}")
            reductions.append(100 * (1 - after["elapsedNanoseconds"] / before["elapsedNanoseconds"]))
        before = statistics.median(retained["baseline"])
        after = statistics.median(retained["candidate"])
        row = {
            "workload": name, "iterations": iterations, "pairs": args.pairs,
            "baselineMedianNanoseconds": before, "candidateMedianNanoseconds": after,
            "baselineRangeNanoseconds": [min(retained["baseline"]), max(retained["baseline"])],
            "candidateRangeNanoseconds": [min(retained["candidate"]), max(retained["candidate"])],
            "medianReductionPercent": 100 * (1 - after / before),
            "medianPairedReductionPercent": statistics.median(reductions),
            "fasterPairs": sum(value > 0 for value in reductions),
        }
        rows.append(row)
        (output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
        print("CHECKPOINT_RESULT " + json.dumps(row, sort_keys=True), flush=True)
    print("CHECKPOINT_COMPLETE " + json.dumps({
        "workloads": len(names), "measurements": sum(item["phase"] == "measurement" for item in observations),
        "calibrations": sum(item["phase"] == "calibration" for item in observations),
        "candidateRevision": revision,
    }, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
