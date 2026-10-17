#!/usr/bin/env python3
"""Compare production bitmap-subtitle timeline insertion on macOS.

Requires Swift 6.1+ and Python 3.10+. Complete timeline and budget sources are
compiled with the exact ASSRenderedRegion declaration, without FFmpeg/libass.
Geometry and leases use their real native types. This is a component benchmark.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TIMELINE = "Subtitles/BitmapSubtitleTimeline.swift"
BUDGET = "Subtitles/SubtitleMemoryBudget.swift"
REGIONS = "Subtitles/LibassContext.swift"
SOURCES = [TIMELINE, BUDGET, REGIONS]
TESTS = ["BitmapSubtitleTimelineOrderingTests.swift", "SubtitleMemoryBudgetAccountingTests.swift"]
CASES = [
    "fill-ascending-1", "fill-ascending-8", "fill-ascending-32", "fill-ascending-128",
    "fill-descending-128", "fill-shuffled-128", "replace-32", "replace-128",
    "stream-8", "stream-32", "stream-128", "reject-full-128",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def run(command: list[str], output: Path, *, timeout: int = 300) -> str:
    started = time.time()
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    append_json(output / "commands.jsonl", {
        "command": command, "returncode": result.returncode,
        "elapsed_seconds": time.time() - started,
    })
    if result.returncode:
        (output / "failure.txt").write_text(result.stdout)
        raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n{result.stdout}")
    return result.stdout


def source_path(variant: str, relative: str) -> Path:
    if variant == "baseline" and relative == TIMELINE:
        return HERE / "baseline/BitmapSubtitleTimeline.swift"
    return ROOT / "Sources/IlliquidNativePlayback" / relative


def region_source() -> str:
    original = source_path("candidate", REGIONS).read_text()
    start = "struct ASSRenderedRegion: Sendable {"
    end = "struct ASSRenderResult: Sendable {"
    if original.count(start) != 1 or original.count(end) != 1:
        raise RuntimeError("ASSRenderedRegion extraction boundaries changed")
    return "import Foundation\nimport CoreGraphics\n\n" + original[
        original.index(start):original.index(end)]


def prepare_sources(variant: str, destination: Path) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    paths = []
    for relative in (TIMELINE, BUDGET):
        path = destination / Path(relative).name
        shutil.copyfile(source_path(variant, relative), path)
        paths.append(path)
    support = destination / "ASSRenderedRegion.swift"
    support.write_text(region_source())
    paths.append(support)
    return paths


def build(variant: str, work: Path, output: Path) -> Path:
    destination = work / variant
    destination.mkdir(parents=True)
    library = destination / ("libIlliquidNativePlayback.dylib" if sys.platform == "darwin"
                             else "libIlliquidNativePlayback.so")
    paths = [str(path) for path in prepare_sources(variant, destination / "sources")]
    run(["swiftc", "-swift-version", "6", "-O", "-whole-module-optimization", "-enable-testing",
         "-warnings-as-errors", "-emit-library", "-emit-module",
         "-module-name", "IlliquidNativePlayback", "-emit-module-path",
         str(destination / "IlliquidNativePlayback.swiftmodule"), *paths, "-o", str(library)], output)
    executable = destination / "benchmark"
    run(["swiftc", "-swift-version", "6", "-O", "-warnings-as-errors", "-parse-as-library", "-I",
         str(destination), "-L", str(destination), "-lIlliquidNativePlayback", "-Xlinker", "-rpath",
         "-Xlinker", str(destination), str(HERE / "Driver.swift"), "-o", str(executable)], output)
    return executable


def test_variant(variant: str, work: Path, output: Path) -> None:
    package = work / f"tests-{variant}"
    source_dir = package / "Sources/IlliquidNativePlayback"
    test_dir = package / "Tests/IlliquidNativePlaybackTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    prepare_sources(variant, source_dir)
    for relative in TESTS:
        shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / relative,
                        test_dir / Path(relative).name)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "BitmapSubtitleTimelineRegressionTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
''')
    for configuration in ("debug", "release"):
        log = run(["swift", "test", "--package-path", str(package), "--jobs", "2",
                   "--no-parallel", "-c", configuration, "-Xswiftc", "-warnings-as-errors"],
                  output, timeout=600)
        (output / f"{variant}-{configuration}-tests.txt").write_text(log)
        print(f"{variant} {configuration} regressions passed", flush=True)


def measure(executable: Path, case: str, iterations: int, seed: int,
            output: Path) -> dict:
    record = json.loads(run([str(executable), case, str(iterations), str(seed)],
                            output, timeout=120))
    if record["iterations"] != iterations or record["case"] != case or record["seed"] != seed:
        raise RuntimeError("Driver receipt does not match its command")
    if record["elapsed_ns"] <= 0:
        raise RuntimeError("Driver reported a nonpositive timing")
    receipt = record.pop("receipt")
    record["receipt_sha256"] = digest(json.dumps(receipt, sort_keys=True,
                                               separators=(",", ":")).encode())
    if record["operations_per_iteration"] < 1:
        raise RuntimeError("Driver reported no insertion operations")
    record["ns_per_iteration"] = record["elapsed_ns"] / iterations
    record["ns_per_operation"] = record["elapsed_ns"] / (iterations * record["operations_per_iteration"])
    # Save one complete receipt per variant/case/seed. The driver checks complete
    # expected output itself before and after timing, not just this digest.
    receipt_dir = output / "receipts"
    receipt_dir.mkdir(exist_ok=True)
    receipt_path = receipt_dir / f"{executable.parent.name}-{case}-{seed}.json"
    write_json(receipt_path, receipt)
    return record


def summarize(records: list[dict]) -> dict:
    summaries = {}
    for case in dict.fromkeys(row["case"] for row in records):
        rows = [row for row in records if row["case"] == case]
        summary = {}
        for variant in ("baseline", "candidate"):
            values = [row["ns_per_operation"] for row in rows if row["variant"] == variant]
            summary[variant] = {"median_ns": statistics.median(values),
                                "min_ns": min(values), "max_ns": max(values)}
        reductions = []
        for pair in sorted({row["pair"] for row in rows}):
            paired = {row["variant"]: row for row in rows if row["pair"] == pair}
            for field in ("receipt_sha256", "checksum", "iterations", "seed", "operations_per_iteration"):
                if paired["baseline"][field] != paired["candidate"][field]:
                    raise RuntimeError(f"Pair mismatch: {case}/{pair}/{field}")
            reductions.append(100 * (1 - paired["candidate"]["ns_per_operation"] /
                                      paired["baseline"]["ns_per_operation"]))
        summary["paired_reduction_percent"] = {
            "median": statistics.median(reductions), "min": min(reductions),
            "max": max(reductions), "candidate_faster_pairs": sum(x > 0 for x in reductions),
            "pairs": len(reductions),
        }
        summary["median_reduction_percent"] = 100 * (1 - summary["candidate"]["median_ns"] /
                                                        summary["baseline"]["median_ns"])
        summaries[case] = summary
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--max-sample-ms", type=float, default=1500)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    cases = args.cases.split(",")
    if sys.platform != "darwin":
        parser.error("This native component harness requires macOS CoreGraphics")
    if (args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or
            args.max_sample_ms < args.target_ms or len(set(cases)) != len(cases) or
            any(case not in CASES for case in cases)):
        parser.error("Use an even positive pair count, valid cases, and positive timing bounds")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output directory must be empty; preserve previous attempts separately")
    output.mkdir(parents=True, exist_ok=True)
    work = output / "build"
    work.mkdir()
    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    if digest((HERE / "baseline/BitmapSubtitleTimeline.swift").read_bytes()) != baseline["sha256"]:
        raise RuntimeError("Frozen baseline hash mismatch")
    manifest = {
        "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift": run(["swiftc", "--version"], output).strip(),
        "git_head": run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], output).strip(),
        "git_status": run(["git", "-C", str(ROOT), "status", "--porcelain"], output).strip(),
        "baseline": baseline, "arguments": {**vars(args), "output": str(output)},
        "source_sha256": {variant: {path: digest(source_path(variant, path).read_bytes())
                                    for path in SOURCES} for variant in ("baseline", "candidate")},
        "region_declaration_sha256": digest(region_source().encode()),
        "extraction": "Complete ASSRenderedRegion declaration from LibassContext.swift; "
                      "only Foundation/CoreGraphics imports added. Timeline and budget copied whole.",
        "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "test_sha256": {path: digest((ROOT / "Tests/IlliquidNativePlaybackTests" / path).read_bytes())
                        for path in TESTS},
        "method": "Separate optimized production module; same-iteration fresh-process pairs; "
                  "alternating AB/BA order; deterministic per-pair fixture shuffle; warm in-memory "
                  "work; calibration excluded; no discarded timing samples or control subtraction.",
    }
    if sys.platform == "darwin":
        manifest["hardware"] = run(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip()
    write_json(output / "manifest.json", manifest)
    try:
        if args.tests_only:
            for variant in ("baseline", "candidate"):
                test_variant(variant, work, output)
            write_json(output / "tests.json", {"baseline_debug": "passed", "baseline_release": "passed",
                                               "candidate_debug": "passed", "candidate_release": "passed"})
            return
        executables = {variant: build(variant, work, output) for variant in ("baseline", "candidate")}
        manifest["binary_sha256"] = {
            variant: {path.name: digest(path.read_bytes()) for path in executable.parent.iterdir()
                      if path.is_file() and (path.name == "benchmark" or path.suffix in (".so", ".dylib"))}
            for variant, executable in executables.items()
        }
        write_json(output / "manifest.json", manifest)
        records = []
        for case in cases:
            calibration = {}
            for variant, executable in executables.items():
                first = measure(executable, case, 1, 1000, output)
                probe_iterations = max(1, min(10000, math.ceil(20_000_000 / first["elapsed_ns"])))
                calibrated = measure(executable, case, probe_iterations, 1000, output)
                calibration[variant] = calibrated["ns_per_iteration"]
                append_json(output / "calibration.jsonl", {"variant": variant, "stage": "single", **first})
                append_json(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **calibrated})
            # Equal work in each pair; aim for target-ms on the faster variant,
            # while bounding the slower one. The actual duration is retained.
            iterations = max(1, min(math.ceil(args.target_ms * 1e6 / min(calibration.values())),
                                    math.floor(args.max_sample_ms * 1e6 / max(calibration.values()))))
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    record = measure(executables[variant], case, iterations, 2000 + pair, output)
                    record.update(variant=variant, pair=pair, position=position)
                    records.append(record)
                    append_json(output / "measurements.jsonl", record)
                summarize(records[-2:])  # fail immediately on a paired correctness mismatch
            summary = summarize(records)
            write_json(output / "summary.json", summary)
            print(case, json.dumps(summary[case], sort_keys=True), flush=True)
        write_json(output / "verification.json", {"all_pairs_equal": True, "records": len(records),
                                                  "cases": len(cases), "pairs_per_case": args.pairs})
    except Exception as error:
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
