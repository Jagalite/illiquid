#!/usr/bin/env python3
"""Measure native thumbnail inventory ownership using unchanged production sources."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CHANGED = "Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift"
CORE = ["Sources/IlliquidCore/" + path for path in (
    "Player/ThumbnailPolicy.swift", "Utilities/NonDecodePerformance.swift",
    "Persistence/MediaContentVersion.swift", "Persistence/MediaPlaybackSettings.swift",
    "Player/MediaTrack.swift",
)]
NATIVE = ["Sources/IlliquidNativePlayback/Media/" + name + ".swift" for name in (
    "NativeThumbnailCache", "NativeThumbnailDiskCache", "ThumbnailPromotionMailbox",
    "ThumbnailBlockingReader", "NativeFileContentVersion", "ThumbnailDiskEvictionHeap",
)]
TESTS = ["Tests/IlliquidNativePlaybackTests/" + name + ".swift" for name in (
    "ThumbnailDiskEvictionTests", "ThumbnailInventoryRegressionTests",
    "ThumbnailPhysicalEntryTests", "ThumbnailPromotionMailboxTests",
    "QueuedThumbnailPromotionTests", "ThumbnailImageLifetimeTests",
    "ThumbnailDiskPathTests",
)]
COUNTS = [0, 128, 2048, 8191]
METRIC_FILES = ["Benchmarks/ThumbnailReadAllocation/CThumbnailReadMetrics/" + name
                for name in ("Metrics.c", "Metrics.h", "module.modulemap")]


# Reviewed main integration drift; any other supporting-source change still fails.
CURRENT_SUPPORT = {
    "Sources/IlliquidCore/Player/ThumbnailPolicy.swift",
    "Sources/IlliquidCore/Persistence/MediaPlaybackSettings.swift",
    "Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift",
}


def reference_source(path, historical, current, regression):
    if path != CHANGED and historical != current:
        if not regression or path not in CURRENT_SUPPORT:
            raise RuntimeError(f"Review supporting-source drift before measuring: {path}")
        return current
    return historical


def whitespace_boundary(regression, requested):
    if regression:
        if not requested or not re.fullmatch(r"[0-9a-fA-F]{40}", requested) or set(requested) == {"0"}:
            raise ValueError("Regression mode requires --whitespace-base with a full nonzero commit SHA.")
        return requested
    if requested is not None:
        raise ValueError("--whitespace-base is only valid with --current-source-regression.")
    return BASELINE


def executed_test_summaries(log):
    expected = {Path(path).stem for path in TESTS}
    suites = set(re.findall(r"Test Suite '([^']+)' passed", log))
    if not expected <= suites or not re.search(r"Executed 44 tests?, with 0 failures", log):
        raise RuntimeError("Expected all seven suites and 44 executed XCTest tests with zero failures.")
    return [line.strip() for line in log.splitlines()
            if "Executed " in line and "0 failures" in line]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--current-source-regression", action="store_true",
                        help="Use reviewed current support for parity only; no performance claim.")
    parser.add_argument("--whitespace-base",
                        help="Regression-only explicit commit defining the introduced whitespace delta.")
    args = parser.parse_args()
    try:
        requested_whitespace_base = whitespace_boundary(args.current_source_regression, args.whitespace_base)
    except ValueError as error:
        parser.error(str(error))
    if platform.system() != "Darwin":
        parser.error("Requires macOS: this experiment uses real Foundation, ImageIO, and CoreGraphics.")
    if not 2 <= args.pairs <= 12 or args.pairs % 2:
        parser.error("--pairs must be an even number from 2 to 12.")
    queue = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
    if queue.is_file() and os.environ.get("ILLIQUID_THUMBNAIL_INVENTORY_QUEUED") != "1":
        parser.error("Submit this command through Kyoto with ILLIQUID_THUMBNAIL_INVENTORY_QUEUED=1.")
    if not queue.is_file():
        print("Kyoto is unavailable on this isolated host; compiling serially in private build directories.",
              flush=True)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty.")
    for name in ("logs", "sources", "build", "fixtures", "test-packages", "driver"):
        (output / name).mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    environment.pop("ILLIQUID_ENABLE_BENCHMARK_OVERRIDES", None)
    environment.pop("ILLIQUID_BENCHMARK_NONDECODE", None)
    commands = []

    def run(argv: list[object], label: str, timeout: int = 600) -> str:
        command = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=environment, text=True,
                                capture_output=True, timeout=timeout)
        stem = f"{len(commands):03d}-{label}"
        (output / "logs" / (stem + ".stdout.log")).write_text(result.stdout)
        (output / "logs" / (stem + ".stderr.log")).write_text(result.stderr)
        record = dict(index=len(commands), argv=command, label=label, exit=result.returncode,
                      elapsed_seconds=time.monotonic() - started,
                      stdout=f"logs/{stem}.stdout.log", stderr=f"logs/{stem}.stderr.log")
        commands.append(record)
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed:\n{result.stdout[-6000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    whitespace_base = run(["git", "rev-parse", "--verify", requested_whitespace_base + "^{commit}"],
                          "whitespace-base").strip()
    whitespace_head = run(["git", "rev-parse", "--verify", "HEAD^{commit}"], "whitespace-head").strip()
    whitespace = {
        "mode": "introduced-delta" if args.current_source_regression else "historical-baseline",
        "requested_base": requested_whitespace_base,
        "resolved_base": whitespace_base, "resolved_head": whitespace_head,
        "github_event": os.environ.get("GITHUB_EVENT_NAME"),
        "github_sha": os.environ.get("GITHUB_SHA"),
        "passed": False,
    }
    write_json(output / "whitespace.json", whitespace)
    run(["git", "diff", "--check", whitespace_base, whitespace_head], "diff-check")
    whitespace["passed"] = True
    write_json(output / "whitespace.json", whitespace)
    sources = {}
    adaptations = {}
    paths = {variant: {} for variant in ("baseline", "candidate")}
    for path in CORE + NATIVE:
        baseline = run(["git", "show", f"{BASELINE}:{path}"], "source-" + Path(path).stem).encode()
        candidate = (ROOT / path).read_bytes()
        historical = baseline
        baseline = reference_source(path, historical, candidate, args.current_source_regression)
        if baseline != historical:
            original = output / "sources" / "historical" / path
            original.parent.mkdir(parents=True, exist_ok=True)
            original.write_bytes(historical)
            sources[f"historical/{path}"] = digest(historical)
            adaptations[path] = {"historical_sha256": digest(historical),
                                 "current_sha256": digest(baseline)}
        for variant, content in (("baseline", baseline), ("candidate", candidate)):
            destination = output / "sources" / variant / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            paths[variant][path] = destination
            sources[f"{variant}/{path}"] = digest(content)
    if paths["baseline"][CHANGED].read_bytes() == paths["candidate"][CHANGED].read_bytes():
        raise RuntimeError("Candidate source has no change.")
    for path in METRIC_FILES:
        target = output / "driver" / "metrics" / Path(path).name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / path).read_bytes())
        sources[path] = digest(target.read_bytes())
    for name in ("Harness.swift", "run.py"):
        target = output / "driver" / name
        target.write_bytes((HERE / name).read_bytes())
        sources["driver/" + name] = digest(target.read_bytes())
    frozen_tests = {}
    for path in TESTS:
        target = output / "sources" / "tests" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / path).read_bytes())
        frozen_tests[path] = target
        sources["tests/" + path] = digest(target.read_bytes())
    write_json(output / "sources.json", sources)
    mode = "current-source-regression" if args.current_source_regression else "historical-measurement"
    write_json(output / "source-policy.json", {
        "mode": mode, "pinned_disk_baseline": BASELINE,
        "adapted_support": adaptations,
        "performance_qualified": False,
        "scope": "Parity with reviewed current support; not historical performance evidence."
                 if args.current_source_regression else "Strict historical support equality.",
    })

    swiftc = run(["xcrun", "--find", "swiftc"], "find-swiftc").strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").strip()
    host = {
        "baseline": BASELINE,
        "candidate_commit": run(["git", "rev-parse", "HEAD"], "head").strip(),
        "working_tree": run(["git", "status", "--porcelain"], "status"),
        "compiler": run([swiftc, "--version"], "compiler"),
        "xcode": run(["xcodebuild", "-version"], "xcode"),
        "os": run(["sw_vers"], "os"),
        "hardware": run(["sysctl", "hw.model", "hw.ncpu", "hw.memsize"], "hardware"),
        "machine": platform.machine(), "sdk": sdk, "pairs": args.pairs,
        "swift_deterministic_hashing": "1",
        "heap_metric": "malloc_zone_statistics(NULL).size_in_use",
        "resident_metric": "task_info(MACH_TASK_BASIC_INFO).resident_size",
    }
    write_json(output / "environment.json", host)
    common = ["-swift-version", "6", "-parse-as-library", "-sdk", sdk,
              "-target", f"{platform.machine()}-apple-macos26.0",
              "-module-cache-path", output / "build" / "module-cache"]
    optimized = ["-O", "-whole-module-optimization", *common]
    core_dir = output / "build" / "core"
    core_dir.mkdir()
    run([swiftc, *optimized, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
         "-emit-module-path", core_dir / "IlliquidCore.swiftmodule",
         *[paths["baseline"][path] for path in CORE],
         "-o", core_dir / "libIlliquidCore.dylib"], "build-core")
    metrics = output / "driver" / "metrics"
    metric_object = output / "build" / "Metrics.o"
    run(["xcrun", "clang", "-O2", "-c", metrics / "Metrics.c", "-o", metric_object], "build-metrics")
    binaries = {}
    for variant in ("baseline", "candidate"):
        binary = output / "build" / variant
        run([swiftc, *optimized, "-I", core_dir, "-L", core_dir, "-lIlliquidCore",
             "-Xlinker", "-rpath", "-Xlinker", core_dir, "-I", metrics,
             *[paths[variant][path] for path in NATIVE],
             output / "driver" / "Harness.swift", metric_object, "-o", binary],
            "build-" + variant)
        binaries[variant] = binary
    write_json(output / "binaries.json", {
        **{name: digest(path.read_bytes()) for name, path in binaries.items()},
        "core": digest((core_dir / "libIlliquidCore.dylib").read_bytes()),
        "metrics": digest(metric_object.read_bytes()),
    })

    # Both variants run the same independent filesystem, alias, ImageIO lifetime,
    # eviction, and promotion tests. No production-source rewriting or stubs.
    test_receipts = []
    manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ThumbnailInventoryQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"]),
        .testTarget(name: "ThumbnailTests", dependencies: ["IlliquidCore", "IlliquidNativePlayback"])
    ])
"""
    for variant in ("baseline", "candidate"):
        package = output / "test-packages" / variant
        package.mkdir()
        (package / "Package.swift").write_text(manifest)
        for module, source_paths in (("IlliquidCore", CORE), ("IlliquidNativePlayback", NATIVE)):
            destination = package / "Sources" / module
            destination.mkdir(parents=True)
            for path in source_paths:
                shutil.copyfile(paths[variant][path], destination / Path(path).name)
        destination = package / "Tests" / "ThumbnailTests"
        destination.mkdir(parents=True)
        for path in TESTS:
            shutil.copyfile(frozen_tests[path], destination / Path(path).name)
        for configuration in ("debug", "release"):
            log = run(["swift", "test", "--package-path", package, "--configuration", configuration,
                       "--jobs", "2", "--no-parallel"], f"tests-{variant}-{configuration}", timeout=900)
            receipt = dict(variant=variant, configuration=configuration, passed=True,
                           suites=7, tests=44, summaries=executed_test_summaries(log))
            test_receipts.append(receipt)
            print("THUMBNAIL_INVENTORY_TEST " + json.dumps(receipt, sort_keys=True), flush=True)
    write_json(output / "tests.json", test_receipts)

    fixture_receipts = []
    for count in COUNTS:
        directory = output / "fixtures" / f"inventory-{count}"
        receipt = json.loads(run([binaries["baseline"], "seed", directory, count], f"seed-{count}"))
        fixture_receipts.append({"count": count, "receipt": receipt})
    write_json(output / "fixtures.json", fixture_receipts)

    observations = []
    for pair in range(args.pairs):
        order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        for count in COUNTS:
            directory = output / "fixtures" / f"inventory-{count}"
            pair_rows = {}
            for position, variant in enumerate(order):
                row = json.loads(run([binaries[variant], "measure", directory, count],
                                     f"measure-{pair}-{count}-{variant}"))
                assert row["count"] == count
                assert row["inventory_bytes"] == count * 4096
                assert row["read_iterations"] == 512
                assert isinstance(row["read_checksum"], int) and row["read_checksum"] > 0
                assert len(row["pixel_sha256"]) == (0 if count == 0 else 3)
                row.update(pair=pair, order=position, variant=variant)
                observations.append(row)
                pair_rows[variant] = row
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            for key in ("inventory_bytes", "read_iterations", "read_checksum", "pixel_sha256"):
                assert pair_rows["baseline"].get(key) == pair_rows["candidate"].get(key), (count, pair, key)
            print(f"Measured pair {pair + 1}/{args.pairs}, inventory {count}", flush=True)

    # These exact frozen inputs were used throughout both builds and all executions.
    for name, expected_hash in sources.items():
        if name.startswith("driver/"):
            staged = output / name
        elif name in METRIC_FILES:
            staged = output / "driver" / "metrics" / Path(name).name
        else:
            staged = output / "sources" / name
        if digest(staged.read_bytes()) != expected_hash:
            raise RuntimeError(f"Staged source changed during qualification: {name}")
    if args.current_source_regression:
        qualification = {"mode": mode, "tests_passed": len(test_receipts),
                         "suites_per_execution": 7, "tests_per_execution": 44,
                         "measurement_processes": len(observations),
                         "balanced_ab_ba_pairs": args.pairs, "counts": COUNTS,
                         "inventory_and_read_parity": True, "sources_frozen_and_hashed": True,
                         "pinned_disk_baseline": BASELINE, "adapted_support": adaptations,
                         "performance_qualified": False}
        write_json(output / "qualification.json", qualification)
        print("THUMBNAIL_INVENTORY_REGRESSION " + json.dumps(qualification, sort_keys=True), flush=True)
        return

    summary = {"baseline": BASELINE, "candidate_commit": host["candidate_commit"],
               "pairs": args.pairs, "processes": len(observations), "scenarios": []}
    for count in COUNTS:
        rows = [row for row in observations if row["count"] == count]
        result = {"count": count, "metrics": {}}
        getters = {
            "heap_delta_bytes": lambda row: row["heap_delta_bytes"],
            "resident_delta_bytes": lambda row: row["resident_delta_bytes"],
            "inventory_wall_ns": lambda row: row["inventory_wall_ns"],
            "inventory_cpu_ns": lambda row: row["inventory_cpu_ns"],
            "read_wall_ns_per_op": lambda row: row["read_wall_ns"] / row["read_iterations"],
            "read_cpu_ns_per_op": lambda row: row["read_cpu_ns"] / row["read_iterations"],
        }
        for name, getter in getters.items():
            pairs = {pair: {row["variant"]: getter(row) for row in rows if row["pair"] == pair}
                     for pair in range(args.pairs)}
            baseline = [pairs[pair]["baseline"] for pair in pairs]
            candidate = [pairs[pair]["candidate"] for pair in pairs]
            differences = [b - a for a, b in zip(baseline, candidate)]
            result["metrics"][name] = {
                "baseline_median": statistics.median(baseline),
                "candidate_median": statistics.median(candidate),
                "paired_candidate_minus_baseline": differences,
                "median_paired_difference": statistics.median(differences),
                "median_paired_change_percent": statistics.median(
                    [100 * (b - a) / a for a, b in zip(baseline, candidate) if a > 0]
                ) if any(a > 0 for a in baseline) else None,
            }
        summary["scenarios"].append(result)
    write_json(output / "summary.json", summary)
    qualification = {"tests_passed": len(test_receipts), "measurement_processes": len(observations),
                     "balanced_ab_ba_pairs": args.pairs,
                     "inventory_and_read_parity": True, "sources_frozen_and_hashed": True}
    write_json(output / "qualification.json", qualification)
    print("THUMBNAIL_INVENTORY_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    print("THUMBNAIL_INVENTORY_QUALIFICATION " + json.dumps(qualification, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
