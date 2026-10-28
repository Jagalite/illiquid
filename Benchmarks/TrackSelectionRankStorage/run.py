#!/usr/bin/env python3
"""Measure selection rank storage against the current, already optimized baseline.

Reuse the existing track-selection workload generator and compiler helpers. Only
the measurement boundary is adapted; the full 55,296 selected-ID receipt and
all workload inputs remain the existing harness's unmodified code.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SHARED = ROOT / "Benchmarks/TrackSelectionRanking"
HEAP = ROOT / "Benchmarks/StandardCompletionContract/CCompletionHeap"
VARIANTS = ("baseline", "candidate")
NATIVE = sys.platform == "darwin"
TESTS = ("TrackSelectionRankingTests.swift",)
MINIMUM_TIMING_INTERVAL_NS = 60_000_000

spec = importlib.util.spec_from_file_location("track_ranking_helpers", SHARED / "run.py")
assert spec is not None and spec.loader is not None
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
digest, file_digest, write_json = shared.digest, shared.file_digest, shared.write_json


def command(args: list[str], log: Path, out: Path, *, preload: Path | None = None) -> str:
    environment = dict(os.environ)
    for key, directory in {
        "CLANG_MODULE_CACHE_PATH": out / "cache/clang",
        "SWIFTPM_MODULECACHE_OVERRIDE": out / "cache/swift",
        "XDG_CACHE_HOME": out / "cache/xdg",
        "TMPDIR": out / "cache/tmp",
    }.items():
        directory.mkdir(parents=True, exist_ok=True)
        environment[key] = str(directory)
    if preload is not None:
        environment["LD_PRELOAD"] = str(preload) + (
            ":" + environment["LD_PRELOAD"] if environment.get("LD_PRELOAD") else "")
    log.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(args, text=True, capture_output=True, env=environment)
    log.write_text(json.dumps(args) + "\n\n" + result.stdout + result.stderr)
    with (out / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"arguments": args, "returncode": result.returncode,
            "log": str(log.relative_to(out)), "log_sha256": digest(log.read_bytes()),
            "allocation_preload": str(preload) if preload else None}) + "\n")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{result.stderr[-6000:]}")
    return result.stdout


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError("The shared harness measurement boundary changed; review the adapter")
    return text.replace(old, new)


def snapshot(out: Path) -> dict:
    pinned_bytes = (HERE / "baseline/manifest.json").read_bytes()
    pinned = json.loads(pinned_bytes)
    baseline = (HERE / "baseline/TrackSelectionPreferences.swift").read_bytes()
    media = (ROOT / pinned["media_track"]["path"]).read_bytes()
    for label, data in (("selection", baseline), ("media_track", media)):
        blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if digest(data) != pinned[label]["sha256"] or blob != pinned[label]["git_blob"]:
            raise RuntimeError(f"Pinned {label} source changed; requalify the baseline manifest")
    original = (SHARED / "Harness.swift").read_text()
    harness = replace_once(original,
        "        let start = DispatchTime.now().uptimeNanoseconds\n"
        "        let result = batch(values, iterations)\n"
        "        let elapsed = DispatchTime.now().uptimeNanoseconds - start\n",
        "        let start = TrackRankMeasurement.start()\n"
        "        let result = batch(values, iterations)\n"
        "        let measurement = TrackRankMeasurement.finish(start)\n")
    harness = replace_once(harness, '"elapsed_ns": elapsed, "checksum": String(result.checksum),',
        '"elapsed_ns": measurement.elapsedNanoseconds, "cpu_ns": measurement.cpuNanoseconds,\n'
        '              "allocations_instrumented": TrackRankMeasurement.instrumentsAllocations,\n'
        '              "allocation_requests": measurement.allocationRequests,\n'
        '              "requested_bytes": measurement.requestedBytes, "checksum": String(result.checksum),')
    # Append private helpers in the same file, preserving private harness access.
    harness += "\n" + (HERE / "Measurement.swift").read_text()
    inputs = {
        "baseline/TrackSelectionPreferences.swift": baseline,
        "candidate/TrackSelectionPreferences.swift": (ROOT / pinned["selection"]["path"]).read_bytes(),
        "MediaTrack.swift": media,
        "Harness.swift": harness.encode(),
        "shared/Harness.swift": original.encode(),
        "shared/run.py": (SHARED / "run.py").read_bytes(),
        "Measurement.swift": (HERE / "Measurement.swift").read_bytes(),
        "run.py": Path(__file__).read_bytes(),
        "baseline-manifest.json": pinned_bytes,
        "meter/heap.c": (HEAP / "heap.c").read_bytes(),
        "meter/include/CCompletionHeap.h": (HEAP / "include/CCompletionHeap.h").read_bytes(),
    }
    for name in TESTS:
        inputs["tests/" + name] = (ROOT / "Tests/IlliquidCoreTests" / name).read_bytes()
    hashes = {}
    for name, data in inputs.items():
        destination = out / "inputs" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        hashes[name] = digest(data)
    return {"baseline_commit": pinned["commit"], "input_sha256": hashes,
            "harness_adapter": "Only the batch clock boundary and measurement receipt fields change; "
                "workloads, warmup, full differential verifier and selected-ID consumption are unchanged."}


def flags(out: Path, compiler: dict) -> list[str]:
    result = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
              "-module-cache-path", str(out / "cache/modules")]
    if NATIVE:
        result += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", compiler["macos_sdk_path"]]
    return result


def build_meter(out: Path, args: argparse.Namespace) -> Path:
    if platform.system() != "Linux" or platform.libc_ver()[0] != "glibc":
        raise RuntimeError("Successful allocation request instrumentation requires Linux/glibc")
    cc = shared.executable(args.cc or os.environ.get("CC"), "cc")
    folder = out / "meter"
    folder.mkdir()
    shutil.copyfile(out / "inputs/meter/include/CCompletionHeap.h", folder / "CCompletionHeap.h")
    (folder / "module.modulemap").write_text(
        'module CCompletionHeap { header "CCompletionHeap.h" export * }\n')
    library = folder / "libTrackRankMeter.so"
    arguments = [cc, "-O2", "-std=c11", "-fPIC", "-shared", "-I", str(folder),
                 str(out / "inputs/meter/heap.c"), "-o", str(library)]
    command(arguments, folder / "build.log", out)
    write_json(folder / "manifest.json", {"command": arguments,
        "compiler_version": command([cc, "--version"], folder / "compiler.log", out).strip(),
        "source_sha256": digest((out / "inputs/meter/heap.c").read_bytes()),
        "header_sha256": digest((folder / "CCompletionHeap.h").read_bytes()),
        "modulemap_sha256": digest((folder / "module.modulemap").read_bytes()),
        "library_sha256": file_digest(library),
        "metric": "Successful intercepted malloc/calloc/realloc requests and requested bytes; not live heap or RSS."})
    return library


def build(variant: str, out: Path, compiler: dict, meter: Path | None) -> Path:
    folder = out / "build" / variant
    folder.mkdir(parents=True)
    sources = [out / "inputs/MediaTrack.swift", out / "inputs" / variant / "TrackSelectionPreferences.swift"]
    harness = out / "inputs/Harness.swift"
    library = folder / ("libIlliquidCore.dylib" if NATIVE else "libIlliquidCore.so")
    module_args = [compiler["swiftc"], *flags(out, compiler), "-emit-library", "-emit-module",
        "-module-name", "IlliquidCore", "-emit-module-path", str(folder / "IlliquidCore.swiftmodule"),
        "-o", str(library), *map(str, sources)]
    command(module_args, folder / "build-module.log", out)
    binary = folder / "track-selection-rank-storage"
    driver_args = [compiler["swiftc"], *flags(out, compiler), "-parse-as-library", "-I", str(folder),
        "-L", str(folder), "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(folder)]
    if meter is not None:
        driver_args += ["-D", "TRACK_RANK_ALLOCATIONS", "-I", str(meter.parent), "-L", str(meter.parent),
            "-lTrackRankMeter", "-Xlinker", "-rpath", "-Xlinker", str(meter.parent)]
    driver_args += [str(harness), "-o", str(binary)]
    command(driver_args, folder / "build-harness.log", out)
    write_json(folder / "manifest.json", {"variant": variant,
        "sources_sha256": {str(path.relative_to(out)): digest(path.read_bytes()) for path in [*sources, harness]},
        "module_command": module_args, "driver_command": driver_args,
        "library_sha256": file_digest(library), "executable_sha256": file_digest(binary),
        "swiftmodule_sha256": file_digest(folder / "IlliquidCore.swiftmodule"),
        "allocations_instrumented": meter is not None})
    return binary


def test(variant: str, configuration: str, out: Path, compiler: dict) -> None:
    folder = out / f"{variant}-{configuration}"
    sources, tests = folder / "Sources/IlliquidCore", folder / "Tests/IlliquidCoreTests"
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    shutil.copyfile(out / "inputs/MediaTrack.swift", sources / "MediaTrack.swift")
    shutil.copyfile(out / "inputs" / variant / "TrackSelectionPreferences.swift", sources / "TrackSelectionPreferences.swift")
    for name in TESTS:
        shutil.copyfile(out / "inputs/tests" / name, tests / name)
    (folder / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "TrackSelectionRankStorageQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
    arguments = [compiler["swift"], "test", "--package-path", str(folder), "--configuration", configuration,
        "--scratch-path", str(folder / "build"), "--no-parallel", "--jobs", "2",
        "--cache-path", str(out / "cache/packages"), "--config-path", str(out / "cache/config"),
        "--security-path", str(out / "cache/security"), "-Xswiftc", "-warnings-as-errors",
        "-Xswiftc", "-module-cache-path", "-Xswiftc", str(out / "cache/modules")]
    if not NATIVE:
        arguments.append("--use-integrated-swift-driver")
    command(arguments, folder / "tests.log", out)
    write_json(folder / "manifest.json", {"variant": variant, "configuration": configuration,
        "command": arguments, "sources_sha256": {str(path.relative_to(folder)): digest(path.read_bytes())
            for path in [*sources.glob("*.swift"), *tests.glob("*.swift"), folder / "Package.swift"]},
        "test_log_sha256": digest((folder / "tests.log").read_bytes())})
    print(f"PASS {variant} {configuration}: {folder / 'tests.log'}", flush=True)


def summarize(rows: list[dict]) -> dict:
    instrumented = {row["allocations_instrumented"] for row in rows}
    if len(instrumented) != 1:
        raise RuntimeError("Do not combine instrumented allocation and uninstrumented timing observations")
    allocations = instrumented.pop()
    metrics = ("allocation_requests", "requested_bytes") if allocations else ("elapsed_ns", "cpu_ns")
    summaries = []
    for workload in dict.fromkeys(row["workload"] for row in rows):
        selected = [row for row in rows if row["workload"] == workload]
        result = {"workload": workload, "iterations": selected[0]["iterations"], "metrics": {}}
        for metric in metrics:
            reductions = []
            favorable = 0
            for round_index in sorted({row["round"] for row in selected}):
                pair = [row for row in selected if row["round"] == round_index]
                shared.compare_pair(pair)
                matched = {row["variant"]: row for row in pair}
                baseline, candidate = (matched[v][metric] for v in VARIANTS)
                reductions.append((baseline - candidate) / baseline * 100 if baseline else None)
                favorable += candidate < baseline
            metric_result = {}
            for variant in VARIANTS:
                samples = [row[metric] / row["operations"] for row in selected if row["variant"] == variant]
                metric_result[variant] = {"median_per_selection": statistics.median(samples),
                    "minimum_per_selection": min(samples), "maximum_per_selection": max(samples), "samples": len(samples)}
            nonzero = [value for value in reductions if value is not None]
            metric_result.update({"paired_reductions_percent": reductions,
                "median_paired_reduction_percent": statistics.median(nonzero) if nonzero else None,
                "candidate_lower_pairs": favorable, "pairs": len(reductions)})
            result["metrics"][metric] = metric_result
        summaries.append(result)
    result = {"mode": "allocations" if allocations else "timing", "workloads": summaries}
    if not allocations:
        short = [
            {key: row[key] for key in ("workload", "variant", "round", "iterations", "operations", "elapsed_ns", "cpu_ns")}
            for row in rows
            if min(row["elapsed_ns"], row["cpu_ns"]) < MINIMUM_TIMING_INTERVAL_NS
        ]
        result["timing_qualification"] = {
            "qualified": not short,
            "minimum_wall_and_cpu_interval_ns": MINIMUM_TIMING_INTERVAL_NS,
            "observations": len(rows),
            "short_observation_count": len(short),
            "short_observations": short,
            "rule": "Every final wall and process CPU interval must reach the minimum; "
                "all short observations remain in the raw data and summaries.",
        }
    return result


def benchmark(out: Path, args: argparse.Namespace, compiler: dict) -> None:
    meter = build_meter(out, args) if args.allocations else None
    binaries = {variant: build(variant, out, compiler, meter) for variant in VARIANTS}
    receipts, lists = {}, {}
    for variant, binary in binaries.items():
        receipts[variant] = json.loads(command([str(binary), "verify"], out / f"verify-{variant}.log", out, preload=meter))
        lists[variant] = json.loads(command([str(binary), "list"], out / f"list-{variant}.log", out, preload=meter))["workloads"]
    if receipts["baseline"] != receipts["candidate"] or receipts["candidate"]["comparisons"] != 55_296:
        raise RuntimeError("Full 55,296-selection differential failed; inspect verification logs")
    if lists["baseline"] != lists["candidate"]:
        raise RuntimeError("Variant workloads differ")
    write_json(out / "verification.json", receipts["candidate"])
    print("PASS full differential: 55,296 selections", flush=True)
    workloads = args.workload or lists["candidate"]
    if len(set(workloads)) != len(workloads) or set(workloads) - set(lists["candidate"]):
        raise RuntimeError("Choose unique workload names from the shared harness")

    def measure(variant: str, workload: str, iterations: int, label: str) -> dict:
        log = out / "processes" / f"{label}-{workload}-{variant}.log"
        row = json.loads(command([str(binaries[variant]), "benchmark", workload, str(iterations)], log, out, preload=meter))
        if (row["workload"] != workload or row["iterations"] != iterations or row["operations"] <= 0
                or row["elapsed_ns"] <= 0 or row["cpu_ns"] <= 0
                or row["allocations_instrumented"] != args.allocations):
            raise RuntimeError(f"Invalid measurement receipt: {row}")
        row.update({"variant": variant, "process_log_sha256": digest(log.read_bytes())})
        return row

    counts = {}
    with (out / "calibration.jsonl").open("w") as stream:
        for index, workload in enumerate(workloads):
            count = args.iterations or 1_000
            if args.iterations is None and not args.allocations:
                for attempt in range(8):
                    order = VARIANTS if (index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
                    pair = [measure(variant, workload, count, f"calibration-{attempt:02d}") for variant in order]
                    shared.compare_pair(pair)
                    for row in pair:
                        row.update({"attempt": attempt, "order": list(order)})
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    fastest = min(min(row["elapsed_ns"], row["cpu_ns"]) for row in pair)
                    if fastest >= args.target_ms * 1_000_000:
                        break
                    count = max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / fastest * 1.1))
                else:
                    raise RuntimeError(f"Unable to calibrate {workload}; specify --iterations")
            counts[workload] = count
    write_json(out / "iteration-counts.json", counts)
    rows = []
    with (out / "measurements.jsonl").open("w") as stream:
        for round_index in range(args.rounds):
            for index, workload in enumerate(workloads):
                order = VARIANTS if (round_index + index) % 2 == 0 else tuple(reversed(VARIANTS))
                pair = []
                for variant in order:
                    row = measure(variant, workload, counts[workload], f"round-{round_index:02d}")
                    row.update({"round": round_index, "order": list(order)})
                    if not args.allocations:
                        row["duration_qualified"] = min(row["elapsed_ns"], row["cpu_ns"]) >= MINIMUM_TIMING_INTERVAL_NS
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    rows.append(row)
                    pair.append(row)
                shared.compare_pair(pair)
            print(f"Completed paired round {round_index + 1}/{args.rounds}", flush=True)
    summary = summarize(rows)
    write_json(out / "summary.json", summary)
    if not args.allocations:
        qualification = summary["timing_qualification"]
        write_json(out / "qualification.json", qualification)
        if not qualification["qualified"]:
            print(f"TIMING UNQUALIFIED: {qualification['short_observation_count']} final observations "
                  "had wall or CPU intervals below 60 ms; all observations were retained.", flush=True)
    for item in summary["workloads"]:
        metric = "requested_bytes" if args.allocations else "elapsed_ns"
        values = item["metrics"][metric]
        print(f"{item['workload']}: {values['baseline']['median_per_selection']:.2f} -> "
              f"{values['candidate']['median_per_selection']:.2f} {metric}/selection; "
              f"paired reduction {values['median_paired_reduction_percent']}%", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("test", "benchmark", "summarize"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--variant", choices=(*VARIANTS, "both"), default="both")
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--target-ms", type=float, default=100.0)
    parser.add_argument("--workload", action="append", help="Select an exact workload; repeat for multiple workloads")
    parser.add_argument("--allocations", action="store_true", help="Linux/glibc counters; separate from timing evidence")
    parser.add_argument("--cpu", type=int, help="Pin this runner and child processes to an allowed Linux CPU")
    parser.add_argument("--swiftc")
    parser.add_argument("--swift")
    parser.add_argument("--cc")
    args = parser.parse_args()
    if args.mode == "benchmark":
        inherited = [name for name in ("LD_PRELOAD", "DYLD_INSERT_LIBRARIES") if os.environ.get(name)]
        if inherited:
            parser.error("Measurement requires no inherited allocator/library interposition; unset "
                         + ", ".join(inherited) + ". The allocation cohort loads only its recorded meter.")
    if (args.rounds < 2 or args.rounds % 2 or (args.iterations is not None and args.iterations <= 0)
            or not math.isfinite(args.target_ms) or args.target_ms <= 0):
        parser.error("Use even --rounds >= 2, positive --iterations, and a finite positive --target-ms")
    if args.allocations and args.mode != "benchmark":
        parser.error("--allocations is only valid with benchmark")
    if args.cpu is not None:
        if not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0):
            parser.error("--cpu must name an allowed Linux CPU")
        os.sched_setaffinity(0, {args.cpu})
    out = args.output.resolve()
    if args.mode != "summarize" and out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("Use a fresh --output directory to preserve previous evidence")
    out.mkdir(parents=True, exist_ok=True)
    if args.mode == "summarize":
        write_json(out / "summary.json", summarize([
            json.loads(line) for line in (out / "measurements.jsonl").read_text().splitlines()]))
        return
    receipt = snapshot(out)
    compiler = shared.toolchain(args, out)
    receipt.update({"recorded_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
        "machine": platform.machine(), "cpu_count": os.cpu_count(), "python": sys.version,
        "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "compiler": compiler, "macos_target": "26.0" if NATIVE else None,
        "git_head": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "measurement": "successful allocation requests/bytes" if args.allocations else "uninstrumented wall/process CPU time",
        "inherited_measurement_interposition_absent": True if args.mode == "benchmark" else None,
        "minimum_timing_interval_ns": MINIMUM_TIMING_INTERVAL_NS})
    write_json(out / "manifest.json", receipt)
    try:
        if args.mode == "test":
            for variant in VARIANTS if args.variant == "both" else (args.variant,):
                test(variant, args.configuration, out, compiler)
        else:
            benchmark(out, args, compiler)
    except Exception as error:
        write_json(out / "completion.json", {"completed": False, "error": str(error)})
        raise
    completion = {"completed": True, "mode": args.mode,
        "allocations_instrumented": args.allocations, "recorded_utc": datetime.now(timezone.utc).isoformat()}
    if args.mode == "benchmark" and not args.allocations:
        completion["timing_qualified"] = json.loads((out / "qualification.json").read_text())["qualified"]
    write_json(out / "completion.json", completion)


if __name__ == "__main__":
    main()
