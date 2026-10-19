#!/usr/bin/env python3
"""Benchmark unmodified FolderPlaylist.index(of:) sources across a separate module boundary."""
from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import tempfile
from pathlib import Path

BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCES = [
    "Playlist/FolderPlaylist.swift",
    "Utilities/NaturalFilenameOrdering.swift",
    "Utilities/NormalizedFileURL.swift",
]
FLAGS = ["-swift-version", "6", "-O"]
MODULE_FLAGS = [*FLAGS, "-whole-module-optimization", "-parse-as-library"]


def command(arguments: list[str], **kwargs) -> str:
    return subprocess.check_output(arguments, text=True, **kwargs).strip()


def hashes(data: bytes) -> dict[str, str]:
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "git_blob_sha1": hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest(),
    }


def git_metadata(root: Path) -> dict:
    return {
        "root": str(root),
        "head": command(["git", "-C", str(root), "rev-parse", "HEAD"]),
        "relevant_status": command([
            "git", "-C", str(root), "status", "--short", "--",
            *["Sources/IlliquidCore/" + source for source in SOURCES],
        ]),
    }


def compile_probe(swiftc: str, root: Path, output: Path, driver: Path) -> dict:
    paths = []
    source_hashes = {}
    for source in SOURCES:
        data = (root / "Sources/IlliquidCore" / source).read_bytes()
        path = output.with_name(output.name + "-sources") / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        paths.append(path)
        source_hashes[source] = hashes(data)
    module = output.with_name(output.name + "-module")
    module.mkdir()
    object_file = module / "IlliquidCore.o"
    subprocess.run([
        swiftc, *MODULE_FLAGS, "-emit-module", "-emit-object", "-module-name", "IlliquidCore",
        "-emit-module-path", str(module / "IlliquidCore.swiftmodule"),
        *map(str, paths), "-o", str(object_file),
    ], check=True)
    subprocess.run([
        swiftc, *FLAGS, "-I", str(module), str(driver), str(object_file), "-o", str(output),
    ], check=True)
    return source_hashes


def cpu_description() -> str:
    if platform.system() == "Darwin":
        return command(["sysctl", "-n", "machdep.cpu.brand_string"])
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def run_probe(probe: Path, case: str, iterations: int) -> dict:
    result = json.loads(command([str(probe), case, str(iterations)], timeout=120))
    if (result["iterations"] != iterations or result["elapsedNanoseconds"] <= 0
            or result["cpuElapsedTicks"] < 0 or result["clockTicksPerSecond"] <= 0
            or result["operationsPerIteration"] <= 0):
        raise RuntimeError(f"Invalid measurement from {probe.name}/{case}")
    return result


def summarize(timing: dict[str, list[float]], paired_speedups: list[float], iterations: int, operations: int) -> dict:
    summary = {
        variant: {
            "median_ms": statistics.median(values) / 1_000_000,
            "min_ms": min(values) / 1_000_000,
            "max_ms": max(values) / 1_000_000,
        }
        for variant, values in timing.items()
    }
    ratio = summary["baseline"]["median_ms"] / summary["candidate"]["median_ms"]
    summary.update({
        "speedup": ratio,
        "candidate_delta_percent": (1 / ratio - 1) * 100,
        "median_paired_speedup": statistics.median(paired_speedups),
        "candidate_faster_pairs": sum(value > 1 for value in paired_speedups),
        "pair_count": len(paired_speedups),
        "iterations_per_process": iterations,
        "operations_per_iteration": operations,
        "lookups_per_process": iterations * operations,
    })
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    baseline = parser.add_mutually_exclusive_group()
    baseline.add_argument("--baseline-revision", default=BASELINE)
    baseline.add_argument("--baseline-root", type=Path)
    parser.add_argument("--candidate-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--case", action="append", dest="cases", help="Select a case; repeat to select several")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be a positive even number of at least 2 (balanced AB/BA)")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    candidate_root = args.candidate_root.resolve()
    driver = Path(__file__).resolve().with_name("main.swift")
    driver_bytes = driver.read_bytes()
    swiftc = shutil.which(args.swiftc)
    if swiftc is None:
        parser.error(f"Swift compiler not found: {args.swiftc}")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "schema_version": 2,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu": cpu_description(),
            "logical_cpu_count": os.cpu_count(),
            "python": platform.python_version(),
            "swiftc": swiftc,
            "swift": command([swiftc, "--version"]),
            "variables": {key: os.environ.get(key) for key in [
                "LANG", "LC_ALL", "LC_COLLATE", "SWIFT_DETERMINISTIC_HASHING",
            ]},
        },
        "method": {
            "compiler_flags": FLAGS,
            "production_compiler_flags": MODULE_FLAGS,
            "module_boundary": "Production sources form a separate optimized IlliquidCore module/object; driver imports and statically links it.",
            "operation_unit": "One FolderPlaylist.index(of:) lookup; each timed invocation batches 32 lookups.",
            "rounds": args.rounds,
            "target_milliseconds_per_process": args.target_ms,
            "max_iterations_per_process": 10_000,
            "sampling": "Fresh processes in balanced AB/BA pairs; one untimed warmup in each process.",
            "timer": "Sum of DispatchTime intervals around 32-lookup batches; report values divided by iterations and operations_per_iteration. Construction, original-predicate oracle, and result validation outside timer.",
            "cpu_timer": "Sum of process clock() deltas immediately outside each wall interval, divided by CLOCKS_PER_SEC.",
            "cpu_limitations": "Includes wall-clock reads, CPU clock sampling overhead, and CPU use by all process threads. Tick granularity especially affects tiny inputs. CPU time excludes descheduled waiting, but still reflects processor frequency and cache effects.",
            "primary_comparison": "cpu_summaries median_paired_speedup; summaries retains separate wall-time statistics.",
            "cpu_clock_reference": "https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/clock.3.html",
            "scope": "In-memory index lookup; fixture decoding, construction, and sorting untimed. No filesystem scan or application latency measurement.",
            "receipt_check": "Every batch agrees with the independent original firstIndex predicate; exact decoded cross-process index/query/item receipts match; hashes are supplementary.",
        },
        "driver_hashes": hashes(driver_bytes),
        "runner_hashes": hashes(Path(__file__).read_bytes()),
        "provenance": {"candidate": git_metadata(candidate_root)},
        "source_hashes": {},
        "calibration": {},
        "rows": [],
        "summaries": {},
        "cpu_summaries": {},
    }
    receipts: dict[str, dict] = {}

    def verify_receipt(case: str, variant: str, result: dict) -> str:
        ticks_per_second = result["clockTicksPerSecond"]
        if report["environment"].setdefault("clock_ticks_per_second", ticks_per_second) != ticks_per_second:
            raise RuntimeError(f"CPU clock scale differs for {case}/{variant}")
        receipt = {key: result[key] for key in ["locale", "itemCount", "operationsPerIteration", "output"]}
        if case in receipts and receipt != receipts[case]:
            raise RuntimeError(f"Exact output mismatch for {case}/{variant}")
        receipts[case] = receipt
        canonical = json.dumps(receipt, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        return hashlib.sha256(canonical).hexdigest()

    # Keep temporary files under the explicitly selected checkout. The original
    # sources are copied byte-for-byte, never rewritten or extracted as snippets.
    with tempfile.TemporaryDirectory(prefix=".folder-playlist-lookup-benchmark-", dir=candidate_root) as temporary:
        work = Path(temporary)
        driver = work / "main.swift"
        driver.write_bytes(driver_bytes)
        if args.baseline_root:
            baseline_root = args.baseline_root.resolve()
            report["provenance"]["baseline"] = git_metadata(baseline_root)
        else:
            revision = command(["git", "-C", str(candidate_root), "rev-parse", args.baseline_revision + "^{commit}"])
            baseline_root = work / "baseline-sources"
            for source in SOURCES:
                relative = "Sources/IlliquidCore/" + source
                data = subprocess.check_output(["git", "-C", str(candidate_root), "show", revision + ":" + relative])
                path = baseline_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            report["provenance"]["baseline"] = {"revision": revision, "source": "git show from candidate checkout"}
        probes = {}
        for variant, root in [("baseline", baseline_root), ("candidate", candidate_root)]:
            probe = work / (variant + "-probe")
            report["source_hashes"][variant] = compile_probe(swiftc, root, probe, driver)
            probes[variant] = probe
        available = json.loads(command([str(probes["baseline"]), "--list"]))
        if json.loads(command([str(probes["candidate"]), "--list"])) != available:
            raise RuntimeError("Probe case manifests differ")
        cases = args.cases or available
        if len(set(cases)) != len(cases) or any(case not in available for case in cases):
            parser.error("--case must name distinct cases from: " + ", ".join(available))
        report["method"]["case_order"] = cases
        for case in cases:
            calibration = run_probe(probes["baseline"], case, 1)
            verify_receipt(case, "baseline calibration", calibration)
            operations = calibration["operationsPerIteration"]
            iterations = max(1, min(10_000, math.ceil(args.target_ms * 1_000_000 / calibration["elapsedNanoseconds"])))
            report["calibration"][case] = {
                "baseline_nanoseconds": calibration["elapsedNanoseconds"],
                "baseline_cpu_ticks": calibration["cpuElapsedTicks"],
                "clock_ticks_per_second": calibration["clockTicksPerSecond"],
                "selected_iterations": iterations,
                "operations_per_iteration": operations,
                "included_in_summary": False,
            }
            timing = {"baseline": [], "candidate": []}
            cpu_timing = {"baseline": [], "candidate": []}
            paired_speedups = []
            cpu_paired_speedups = []
            for round_number in range(args.rounds):
                order = ["baseline", "candidate"] if round_number % 2 == 0 else ["candidate", "baseline"]
                pair = {}
                cpu_pair = {}
                for position, variant in enumerate(order):
                    result = run_probe(probes[variant], case, iterations)
                    digest = verify_receipt(case, variant, result)
                    ns_per_operation = result["elapsedNanoseconds"] / iterations / operations
                    if result["cpuElapsedTicks"] == 0:
                        raise RuntimeError(f"CPU measurement below clock resolution for {case}/{variant}; increase --target-ms")
                    cpu_ns_per_operation = result["cpuElapsedTicks"] * 1_000_000_000 / result["clockTicksPerSecond"] / iterations / operations
                    pair[variant] = ns_per_operation
                    cpu_pair[variant] = cpu_ns_per_operation
                    timing[variant].append(ns_per_operation)
                    cpu_timing[variant].append(cpu_ns_per_operation)
                    report["rows"].append({
                        "case": case, "round": round_number, "position": position, "variant": variant,
                        "iterations": iterations, "operations_per_iteration": operations,
                        "total_lookups": iterations * operations, "elapsed_nanoseconds": result["elapsedNanoseconds"],
                        "nanoseconds_per_operation": ns_per_operation,
                        "cpu_elapsed_ticks": result["cpuElapsedTicks"],
                        "clock_ticks_per_second": result["clockTicksPerSecond"],
                        "cpu_nanoseconds_per_operation": cpu_ns_per_operation, "receipt_sha256": digest,
                    })
                paired_speedups.append(pair["baseline"] / pair["candidate"])
                cpu_paired_speedups.append(cpu_pair["baseline"] / cpu_pair["candidate"])
            summary = summarize(timing, paired_speedups, iterations, operations)
            cpu_summary = summarize(cpu_timing, cpu_paired_speedups, iterations, operations)
            report["summaries"][case] = summary
            report["cpu_summaries"][case] = cpu_summary
            print(case, json.dumps({"cpu": cpu_summary, "wall": summary}), flush=True)
    report["all_receipts_equal"] = True
    receipt_path = output.with_suffix(".receipts.json.gz")
    receipt_data = json.dumps(receipts, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
    receipt_path.write_bytes(gzip.compress(receipt_data, mtime=0))
    report["receipts_file"] = receipt_path.name
    report["receipts_uncompressed_sha256"] = hashlib.sha256(receipt_data).hexdigest()
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"All exact receipts matched. Saved {output} and {receipt_path}", flush=True)


if __name__ == "__main__":
    main()
