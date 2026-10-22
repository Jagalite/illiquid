#!/usr/bin/env python3
"""Compare session encoding and actual atomic saves using production Swift sources."""
from __future__ import annotations

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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
STORE = "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift"
SHARED = [
    "Sources/IlliquidCore/Persistence/LegacyPreferencesMigration.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
]
CASES = [(0, "plain"), (1, "plain"), (24, "plain"), (1000, "plain"),
         (10000, "plain"), (24, "rich"), (1000, "rich"), (10000, "rich")]
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=int, default=80)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 1:
        parser.error("--pairs must be positive and even (at least 2); --target-ms must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be empty or new")
    (output / "logs").mkdir()
    flags = FLAGS + (["-target", f"{platform.machine()}-apple-macosx26.0"]
                     if sys.platform == "darwin" else [])

    def write(name: str, value) -> None:
        (output / name).write_text(json.dumps(value, indent=2) + "\n")

    def run(command: list[str], label: str) -> str:
        result = subprocess.run(command, cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / "logs" / f"{label}.log").write_text(result.stdout)
        with (output / "commands.jsonl").open("a") as handle:
            handle.write(json.dumps({"label": label, "command": command,
                                     "exit_code": result.returncode}) + "\n")
        if result.returncode:
            print(result.stdout[-15000:], flush=True)
            raise RuntimeError(f"{label} failed ({result.returncode})")
        return result.stdout

    baseline = (HERE / "baseline/PlaybackSessionStore.swift").read_bytes()
    original = subprocess.check_output(["git", "show", f"{BASE}:{STORE}"], cwd=ROOT)
    if baseline != original:
        raise RuntimeError("frozen baseline differs from the cited production commit")
    subprocess.run(["git", "merge-base", "--is-ancestor", BASE, "HEAD"], cwd=ROOT, check=True)
    metadata = {
        "baseline_commit": BASE,
        "candidate_commit": run(["git", "rev-parse", "HEAD"], "head").strip(),
        "worktree_status": run(["git", "status", "--short"], "status").strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift": run(["swiftc", "--version"], "swift-version").strip(),
        "flags": flags, "pairs": args.pairs, "target_ms": args.target_ms,
        "shared_sources": {p: digest((ROOT / p).read_bytes()) for p in SHARED},
        "baseline_store_sha256": digest(baseline),
        "candidate_store_sha256": digest((ROOT / STORE).read_bytes()),
        "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "test_sha256": digest((ROOT / "Tests/IlliquidCoreTests/PlaybackSessionStoreTests.swift").read_bytes()),
        "scope": "Steady overwrite with actual save() including lock, directory call, encoding, atomic write; encode-only is a separate attribution kernel. No fsync, crash-durability, total-player, or energy measurement.",
        "sampling": "Fresh process per variant and pair; alternating pair order; three untimed warmups; shared iteration count calibrated on baseline; complete final payloads compared.",
        "linux_adapter": None if sys.platform == "darwin" else "Only LifecyclePerformance.isEnabled is stubbed false; explicit disposable file paths are used. Store and all data-model sources are unmodified.",
    }
    if sys.platform == "darwin":
        metadata["macos"] = run(["sw_vers"], "macos").strip()
        metadata["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        metadata["xcode"] = run(["xcodebuild", "-version"], "xcode").strip()
    write("manifest.json", metadata)
    executables = {}
    test_receipts = []
    for variant in VARIANTS:
        work = output / "build" / variant
        source = work / "Sources/IlliquidCore"
        source.mkdir(parents=True)
        for path in SHARED:
            shutil.copyfile(ROOT / path, source / Path(path).name)
        (source / "PlaybackSessionStore.swift").write_bytes(
            baseline if variant == "baseline" else (ROOT / STORE).read_bytes())
        if sys.platform == "darwin":
            shutil.copyfile(ROOT / "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
                            source / "LifecyclePerformance.swift")
        else:
            (source / "LifecyclePerformance.swift").write_text(
                "// Linux-only inactive signpost adapter; explicit file URLs bypass this flag.\n"
                "public enum LifecyclePerformance { public static let isEnabled = false }\n")
        if args.mode != "benchmark":
            tests = work / "Tests/IlliquidCoreTests"
            tests.mkdir(parents=True)
            shutil.copyfile(ROOT / "Tests/IlliquidCoreTests/PlaybackSessionStoreTests.swift",
                            tests / "PlaybackSessionStoreTests.swift")
            (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SessionCheckpointTests", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
''')
            for configuration in ("debug", "release"):
                label = f"tests-{variant}-{configuration}"
                result = run(["swift", "test", "--package-path", str(work),
                              "--cache-path", str(output / "cache"),
                              "--config-path", str(output / "config"),
                              "--security-path", str(output / "security"), "--jobs", "2",
                              "-c", configuration, "-Xswiftc", "-warnings-as-errors"], label)
                print("\n".join(result.splitlines()[-4:]), flush=True)
                test_receipts.append({"variant": variant, "configuration": configuration, "passed": True})
            write("tests.json", test_receipts)
        if args.mode == "tests":
            continue
        library = work / ("libIlliquidCore.dylib" if sys.platform == "darwin" else "libIlliquidCore.so")
        run(["swiftc", *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
             "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
             *map(str, sorted(source.glob("*.swift"))), "-o", str(library)], f"build-{variant}")
        executable = work / "session-benchmark"
        run(["swiftc", *flags, "-parse-as-library", "-I", str(work), "-L", str(work),
             "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
             str(HERE / "Harness.swift"), "-o", str(executable)], f"driver-{variant}")
        executables[variant] = executable

    if args.mode == "tests":
        return
    observations = []
    summaries = []

    def measure(variant: str, mode: str, count: int, kind: str, iterations: int, label: str):
        folder = output / "samples" / label
        text = run([str(executables[variant]), mode, str(count), kind, str(iterations), variant,
                    str(folder)], label)
        row = json.loads(text.strip().splitlines()[-1])
        row["sample"] = label
        payload_file = folder / "payload.json"
        payload_bytes = payload_file.read_bytes()
        row["payload_sha256"] = digest(payload_bytes)
        # Preserve representative raw payloads; all comparisons and hashes remain.
        if "-pair0-" not in label:
            payload_file.unlink()
        with (output / "observations.jsonl").open("a") as handle:
            handle.write(json.dumps(row) + "\n")
        return row, json.loads(payload_bytes)

    for mode in ("encode", "save"):
        for count, kind in CASES:
            case = f"{mode}-{count}-{kind}"
            calibration, _ = measure("baseline", mode, count, kind, 3, f"{case}-calibration")
            iterations = max(1, min(10000, math.ceil(args.target_ms * 1_000_000 /
                                                   calibration["wall_ns_per_save"])))
            paired_rows = []
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                rows = {}
                payloads = {}
                for variant in order:
                    label = f"{case}-pair{pair}-{variant}"
                    rows[variant], payloads[variant] = measure(
                        variant, mode, count, kind, iterations, label)
                    observations.append(rows[variant])
                if payloads["baseline"] != payloads["candidate"]:
                    raise RuntimeError(f"complete JSON value mismatch: {case} pair {pair}")
                if rows["baseline"]["payload_bytes"] != rows["candidate"]["payload_bytes"]:
                    raise RuntimeError(f"payload length changed: {case} pair {pair}")
                paired_rows.append(rows)
            summary = {"mode": mode, "count": count, "kind": kind, "iterations": iterations,
                       "pairs": args.pairs, "json_parity_passed": True,
                       "payload_bytes": paired_rows[-1]["baseline"]["payload_bytes"]}
            for metric in ("wall_ns_per_save", "cpu_ns_per_save"):
                b = [p["baseline"][metric] for p in paired_rows]
                c = [p["candidate"][metric] for p in paired_rows]
                summary[metric] = {
                    "baseline_median": statistics.median(b), "candidate_median": statistics.median(c),
                    "baseline_range": [min(b), max(b)], "candidate_range": [min(c), max(c)],
                    "median_reduction_percent": 100 * (1 - statistics.median(c) / statistics.median(b)),
                    "paired_reduction_percent": [100 * (1 - y / x) for x, y in zip(b, c)],
                }
            summaries.append(summary)
            write("summary.json", summaries)
            print("RESULT " + json.dumps(summary), flush=True)
    print(f"PASS: {len(observations)} timing observations and {len(observations) // 2} complete JSON comparisons", flush=True)


if __name__ == "__main__":
    main()
