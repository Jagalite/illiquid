#!/usr/bin/env python3
"""Compare complete production identity sources with exact results and paired timings."""
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

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = [
    "Utilities/NormalizedFileURL.swift",
    "Utilities/NaturalFilenameOrdering.swift",
    "Playlist/FolderPlaylist.swift",
]
FLAGS = ["-swift-version", "6", "-O"]
MODULE_FLAGS = [*FLAGS, "-whole-module-optimization", "-parse-as-library"]


def command(args: list[str], **kwargs) -> str:
    return subprocess.check_output(args, text=True, **kwargs).strip()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compile_probe(swiftc: str, sources: dict[str, bytes], work: Path, driver: Path) -> dict:
    work.mkdir()
    source_hashes = {}
    paths = []
    for relative, data in sources.items():
        path = work / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        paths.append(str(path))
        source_hashes[relative] = sha256(data)
    object_file = work / "IlliquidCore.o"
    subprocess.run([
        swiftc, *MODULE_FLAGS, "-emit-module", "-emit-object", "-module-name", "IlliquidCore",
        "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
        *paths, "-o", str(object_file),
    ], check=True)
    subprocess.run([
        swiftc, *FLAGS, "-I", str(work), str(driver), str(object_file), "-o", str(work / "probe"),
    ], check=True)
    return source_hashes


def probe(path: Path, case: str, iterations: int) -> dict:
    result = json.loads(command([str(path), case, str(iterations)], timeout=120))
    if (result["iterations"] != iterations or result["elapsedNanoseconds"] <= 0
            or result["cpuElapsedTicks"] < 0 or result["clockTicksPerSecond"] <= 0
            or result["operationsPerIteration"] <= 0):
        raise RuntimeError(f"Invalid measurement for {path.parent.name}/{case}")
    return result


def summary(values: dict[str, list[float]], pairs: list[float]) -> dict:
    result = {
        variant: {"median_ns": statistics.median(samples), "min_ns": min(samples), "max_ns": max(samples)}
        for variant, samples in values.items()
    }
    baseline = result["baseline"]["median_ns"]
    candidate = result["candidate"]["median_ns"]
    result.update({
        "speedup": baseline / candidate,
        "candidate_delta_percent": (candidate / baseline - 1) * 100,
        "saved_ns_per_operation": baseline - candidate,
        "median_paired_speedup": statistics.median(pairs),
        "candidate_faster_pairs": sum(ratio > 1 for ratio in pairs),
        "pair_count": len(pairs),
    })
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-revision", default=BASELINE)
    parser.add_argument("--candidate-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=50)
    parser.add_argument("--case", action="append", dest="cases")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be even and at least 2 for balanced AB/BA pairs")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be positive and finite")
    swiftc = shutil.which(args.swiftc)
    if not swiftc:
        parser.error(f"Swift compiler not found: {args.swiftc}")
    root = args.candidate_root.resolve()
    revision = command(["git", "-C", str(root), "rev-parse", args.baseline_revision + "^{commit}"])
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    driver = Path(__file__).resolve().with_name("main.swift")
    production_paths = ["Sources/IlliquidCore/" + source for source in SOURCES]
    sources = {
        "baseline": {source: subprocess.check_output(["git", "-C", str(root), "show", revision + ":Sources/IlliquidCore/" + source]) for source in SOURCES},
        "candidate": {source: (root / "Sources/IlliquidCore" / source).read_bytes() for source in SOURCES},
    }
    cpu = command(["sysctl", "-n", "machdep.cpu.brand_string"]) if platform.system() == "Darwin" else platform.processor()
    if not cpu and Path("/proc/cpuinfo").exists():
        cpu = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown")
    report = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {
            "platform": platform.platform(), "machine": platform.machine(), "cpu": cpu,
            "logical_cpu_count": os.cpu_count(), "python": platform.python_version(),
            "swiftc": swiftc, "swift": command([swiftc, "--version"]),
            "variables": {name: os.environ.get(name) for name in ["LANG", "LC_ALL", "SWIFT_DETERMINISTIC_HASHING"]},
        },
        "provenance": {
            "baseline_revision": revision,
            "candidate_head": command(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "candidate_status": command(["git", "-C", str(root), "status", "--short", "--", *production_paths]),
        },
        "method": {
            "flags": FLAGS, "production_flags": MODULE_FLAGS,
            "module_boundary": "Complete production sources compiled to a separate optimized IlliquidCore module/object; no source rewrites.",
            "unit": "One persistenceKey call, or one complete FolderPlaylist.index(of:) call for playlist cases.",
            "sampling": "Fresh processes, one untimed warmup, balanced alternating AB/BA pairs; same iterations for both variants.",
            "timer": "Sum of DispatchTime intervals around batches of 64 keys or four playlist lookups; result arrays are collected inside the timer, exact byte checks outside.",
            "cpu_timer": "Sum of POSIX clock() deltas immediately outside each wall interval; includes timer overhead and all process threads.",
            "scope": "In-memory identity operations only. URL/playlist construction, sorting, oracle, validation and JSON encoding are outside timed intervals. No filesystem or application-latency claim.",
            "rounds": args.rounds, "target_ms": args.target_ms, "max_iterations": 10000,
        },
        "driver_sha256": sha256(driver.read_bytes()), "runner_sha256": sha256(Path(__file__).read_bytes()),
        "source_sha256": {}, "calibration": {}, "rows": [], "summaries": {}, "cpu_summaries": {},
    }
    receipts = {}

    def verify(case: str, value: dict) -> str:
        receipt = {name: value[name] for name in ["locale", "itemCount", "operationsPerIteration", "output"]}
        if case in receipts and receipt != receipts[case]:
            raise RuntimeError(f"Exact output/fixture receipt changed for {case}")
        receipts[case] = receipt
        return sha256(json.dumps(receipt, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())

    kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
    if kyoto.exists():
        print("Kyoto is available; invoke this entire runner through its shared queue as required by AGENTS.md.", flush=True)
    else:
        print("Kyoto is unavailable on this host; compiling isolated benchmark modules directly and serially.", flush=True)
    with tempfile.TemporaryDirectory(prefix=".persistence-key-benchmark-", dir=root) as temporary:
        work = Path(temporary)
        copied_driver = work / "main.swift"
        copied_driver.write_bytes(driver.read_bytes())
        probes = {}
        for variant in ["baseline", "candidate"]:
            report["source_sha256"][variant] = compile_probe(swiftc, sources[variant], work / variant, copied_driver)
            probes[variant] = work / variant / "probe"
        available = json.loads(command([str(probes["baseline"]), "--list"]))
        if json.loads(command([str(probes["candidate"]), "--list"])) != available:
            raise RuntimeError("Probe case manifests differ")
        cases = args.cases or available
        if len(cases) != len(set(cases)) or any(case not in available for case in cases):
            parser.error("--case must name distinct cases from: " + ", ".join(available))
        report["method"]["case_order"] = cases
        for case in cases:
            pilots = [probe(probes["baseline"], case, 1) for _ in range(3)]
            for pilot in pilots:
                verify(case, pilot)
            baseline_ns = statistics.median(pilot["elapsedNanoseconds"] for pilot in pilots)
            iterations = max(1, min(10000, math.ceil(args.target_ms * 1_000_000 / baseline_ns)))
            operations = pilots[0]["operationsPerIteration"]
            report["calibration"][case] = {
                "baseline_pilot_ns": [pilot["elapsedNanoseconds"] for pilot in pilots],
                "baseline_median_ns": baseline_ns, "iterations": iterations,
                "operations_per_iteration": operations, "included_in_summary": False,
            }
            wall = {"baseline": [], "candidate": []}
            cpu_values = {"baseline": [], "candidate": []}
            wall_pairs, cpu_pairs = [], []
            for round_number in range(args.rounds):
                order = ["baseline", "candidate"] if round_number % 2 == 0 else ["candidate", "baseline"]
                pair, cpu_pair = {}, {}
                for position, variant in enumerate(order):
                    result = probe(probes[variant], case, iterations)
                    digest = verify(case, result)
                    if result["cpuElapsedTicks"] == 0:
                        raise RuntimeError(f"CPU clock resolution insufficient for {case}; increase --target-ms")
                    denominator = iterations * operations
                    wall_ns = result["elapsedNanoseconds"] / denominator
                    cpu_ns = result["cpuElapsedTicks"] * 1_000_000_000 / result["clockTicksPerSecond"] / denominator
                    wall[variant].append(wall_ns)
                    cpu_values[variant].append(cpu_ns)
                    pair[variant], cpu_pair[variant] = wall_ns, cpu_ns
                    report["rows"].append({
                        "case": case, "round": round_number, "position": position, "variant": variant,
                        "iterations": iterations, "operations_per_iteration": operations,
                        "elapsed_nanoseconds": result["elapsedNanoseconds"], "nanoseconds_per_operation": wall_ns,
                        "cpu_elapsed_ticks": result["cpuElapsedTicks"], "clock_ticks_per_second": result["clockTicksPerSecond"],
                        "cpu_nanoseconds_per_operation": cpu_ns, "receipt_sha256": digest,
                    })
                wall_pairs.append(pair["baseline"] / pair["candidate"])
                cpu_pairs.append(cpu_pair["baseline"] / cpu_pair["candidate"])
            report["summaries"][case] = summary(wall, wall_pairs)
            report["cpu_summaries"][case] = summary(cpu_values, cpu_pairs)
            print(case, json.dumps({"wall": report["summaries"][case], "cpu": report["cpu_summaries"][case]}), flush=True)
    report["all_receipts_equal"] = True
    receipt_path = output.with_suffix(".receipts.json.gz")
    data = json.dumps(receipts, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
    receipt_path.write_bytes(gzip.compress(data, mtime=0))
    report["receipts_file"] = receipt_path.name
    report["receipts_uncompressed_sha256"] = sha256(data)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"All exact receipts matched. Saved {output} and {receipt_path}", flush=True)


if __name__ == "__main__":
    main()
