#!/usr/bin/env python3
"""Qualify and measure exact production ring/queue sources in fresh processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE_FILES = [
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
]
TEST_FILES = [
    "Tests/IlliquidNativePlaybackTests/FixedRingBufferTests.swift",
    "Tests/IlliquidNativePlaybackTests/PacketQueueWakeupTests.swift",
]
CASES = [
    "ring-fifo", "ring-prepend", "queue-fifo", "queue-prepend",
    "ring-reference-fifo", "queue-reference-fifo",
]
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library"]
MAX_ITERATIONS = 100_000_000


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def environment(output: Path) -> dict[str, str]:
    env = os.environ.copy()
    cache = str(output / "module-cache")
    env.update(CLANG_MODULE_CACHE_PATH=cache, SWIFT_MODULECACHE_PATH=cache,
               SWIFTPM_MODULECACHE_OVERRIDE=cache, TERM="dumb", NO_COLOR="1")
    return env


def command(arguments: list, output: Path, name: str, *, timeout: int = 600) -> str:
    arguments = list(map(str, arguments))
    started = time.time()
    result = subprocess.run(arguments, cwd=ROOT, env=environment(output),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log = output / "logs" / (name + ".log")
    log.write_text(result.stdout)
    append(output / "commands.jsonl", {
        "name": name, "argv": arguments, "cwd": str(ROOT),
        "started_unix": started, "elapsed_seconds": time.time() - started,
        "returncode": result.returncode, "log": str(log.relative_to(output)),
    })
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}):\n{result.stdout[-12000:]}")
    return result.stdout


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / "build" / variant
    receipts = {}
    for relative in SOURCE_FILES:
        data = (git("show", f"{baseline}:{relative}") if variant == "baseline"
                else (ROOT / relative).read_bytes())
        target = package / "Sources/IlliquidNativePlayback" / Path(relative).name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[relative] = {"sha256": digest(data), "bytes": len(data),
                              "transformation": "none"}
    for relative in TEST_FILES:
        data = (ROOT / relative).read_bytes()
        target = package / "Tests/IlliquidNativePlaybackTests" / Path(relative).name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (package / "Driver.swift").write_bytes((HERE / "Driver.swift").read_bytes())
    (package / "Package.swift").write_text(
        '// swift-tools-version: 6.1\n'
        'import PackageDescription\n'
        'let package = Package(name: "FixedRingBufferQualification",\n'
        '    platforms: [.macOS("26.0")],\n'
        '    targets: [\n'
        '        .target(name: "IlliquidNativePlayback"),\n'
        '        .testTarget(name: "IlliquidNativePlaybackTests",\n'
        '                    dependencies: ["IlliquidNativePlayback"]),\n'
        '    ], swiftLanguageModes: [.v6])\n'
    )
    return receipts


def probe(binary: Path, case: str, capacity: int, iterations: int, output: Path) -> dict:
    argv = [str(binary), case, str(capacity), str(iterations)]
    result = subprocess.run(argv, cwd=ROOT, env=environment(output),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=60)
    if result.returncode:
        append(output / "probe-failures.jsonl", {
            "argv": argv, "returncode": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr,
        })
        raise RuntimeError(f"Probe failed ({result.returncode}): {argv}\n{result.stderr}")
    try:
        row = json.loads(result.stdout)
    except ValueError as error:
        raise RuntimeError(f"Probe emitted invalid JSON: {argv}\n{result.stdout}") from error
    if (row.get("case") != case or row.get("capacity") != capacity
            or row.get("iterations") != iterations
            or row.get("operations") != iterations * 2
            or type(row.get("elapsed_ns")) is not int or row["elapsed_ns"] <= 0
            or type(row.get("checksum")) is not int
            or type(row.get("warmup_checksum")) is not int):
        raise RuntimeError(f"Invalid probe receipt: {argv}\n{row}")
    def expected(count: int) -> int:
        triangular = lambda n: n * (n - 1) // 2
        if "reference" in case:
            return (count // capacity) * triangular(capacity) + triangular(count % capacity)
        if case.endswith("prepend"):
            return triangular(count)
        retained = capacity - 1
        return triangular(min(count, retained)) + triangular(max(0, count - retained))
    if (row["checksum"] != expected(iterations)
            or row["warmup_checksum"] != expected(min(iterations, 20_000))):
        raise RuntimeError(f"Probe does not match the independent checksum oracle: {argv}\n{row}")
    return row


def summarize(rows: list[dict], workloads: list[tuple[str, int]], pairs: int) -> list[dict]:
    summaries = []
    for case, capacity in workloads:
        matching = [row for row in rows if row["case"] == case and row["capacity"] == capacity]
        by_variant = {
            variant: [row["elapsed_ns"] / row["iterations"] for row in matching
                      if row["variant"] == variant]
            for variant in ("baseline", "candidate")
        }
        if any(len(values) != pairs for values in by_variant.values()):
            raise RuntimeError(f"Missing observations for {case}/{capacity}")
        paired_ratios = []
        for pair in range(pairs):
            observations = {row["variant"]: row for row in matching if row["pair"] == pair}
            if len(observations) != 2:
                raise RuntimeError(f"Invalid pair {case}/{capacity}/{pair}")
            baseline, candidate = observations["baseline"], observations["candidate"]
            if (baseline["iterations"], baseline["checksum"], baseline["operations"]) != (
                    candidate["iterations"], candidate["checksum"], candidate["operations"]):
                raise RuntimeError(f"Pair receipts differ for {case}/{capacity}/{pair}")
            paired_ratios.append(candidate["elapsed_ns"] / baseline["elapsed_ns"])
        stats = {
            variant: {"median": statistics.median(values), "min": min(values), "max": max(values)}
            for variant, values in by_variant.items()
        }
        median_ratio = statistics.median(paired_ratios)
        summaries.append({
            "case": case, "capacity": capacity, "pairs": pairs,
            "iterations_per_process": matching[0]["iterations"],
            "nanoseconds_per_cycle": stats,
            "candidate_over_baseline_median_ratio": stats["candidate"]["median"] / stats["baseline"]["median"],
            "median_paired_candidate_over_baseline_ratio": median_ratio,
            "median_paired_reduction_percent": 100 * (1 - median_ratio),
            "paired_ratio_range": [min(paired_ratios), max(paired_ratios)],
            "candidate_faster_pairs": sum(ratio < 1 for ratio in paired_ratios),
        })
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--capacities", default="3,12,48,64,96,192")
    parser.add_argument("--case", action="append", dest="cases", choices=CASES)
    parser.add_argument("--seed", type=int, default=20261028)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    capacities = [int(value) for value in args.capacities.split(",")]
    cases = args.cases or CASES
    if (args.pairs < 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0
            or not capacities or any(value <= 0 for value in capacities)
            or len(capacities) != len(set(capacities)) or len(cases) != len(set(cases))):
        parser.error("Use at least two pairs, a positive finite duration and distinct positive capacities/cases")
    swift = shutil.which(args.swift)
    swiftc = shutil.which(args.swiftc)
    if not swift or not swiftc:
        parser.error("Both swift and swiftc must be available")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Use a new or empty output directory; existing evidence is never overwritten")
    (output / "logs").mkdir()
    try:
        baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
        manifest = {
            "schema_version": 1,
            "baseline_commit": baseline,
            "candidate_commit": git("rev-parse", "HEAD").decode().strip(),
            "candidate_status": git("status", "--porcelain", "--untracked-files=no").decode(),
            "candidate_source": "working tree, copied byte-for-byte",
            "platform": platform.platform(), "machine": platform.machine(),
            "processor": platform.processor(), "python": platform.python_version(),
            "logical_cpu_count": os.cpu_count(),
            "environment": {key: os.environ.get(key)
                            for key in ("LANG", "LC_ALL", "SWIFT_DETERMINISTIC_HASHING")},
            "compiler": command([swiftc, "--version"], output, "swiftc-version").strip(),
            "swift": command([swift, "--version"], output, "swift-version").strip(),
            "compiler_flags": FLAGS,
            "test_sources": {relative: digest((ROOT / relative).read_bytes()) for relative in TEST_FILES},
            "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "source_hashes": {},
            "pairs": args.pairs, "capacities": capacities, "cases": cases,
            "target_ms": args.target_ms, "seed": args.seed, "tests_only": args.tests_only,
            "method": {
                "unit": "nanoseconds per enqueue/dequeue cycle (two operations)",
                "compilation": "Exact production sources and shared driver compiled together with whole-module optimization",
                "sampling": "Fresh process per observation, reproducibly shuffled case/capacity order within each pair",
                "variant_order": "AB for even pair indices, BA for odd pair indices",
                "baseline_first_pairs": (args.pairs + 1) // 2,
                "candidate_first_pairs": args.pairs // 2,
                "warmup": "Driver warms each process outside its timer; runner additionally validates 1024-cycle probes",
                "calibration": "Baseline-only doubling/proportional calibration to target duration; one fixed iteration count per workload",
                "checks": "Both source variants pass identical debug/release tests; deterministic checksums match",
                "probe_command": ["<binary_paths[variant]>", "<case>", "<capacity>", "<iterations>"],
                "probe_receipts": "calibration.jsonl, verification.json and observations.jsonl retain every successful invocation's inputs and output",
                "timing_gate": False,
                "scope": "Uncontended ring and synchronized queue component costs; no decoder, producer contention, UI, energy or playback-throughput measurement",
            },
        }
        if platform.system() == "Darwin":
            manifest["os_version"] = command(["sw_vers"], output, "os-version").strip()
            manifest["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], output, "cpu").strip()
        for variant in ("baseline", "candidate"):
            manifest["source_hashes"][variant] = stage(output, variant, baseline)
        if manifest["source_hashes"]["baseline"][SOURCE_FILES[1]] != manifest["source_hashes"]["candidate"][SOURCE_FILES[1]]:
            raise RuntimeError("PacketQueue.swift must remain byte-identical across this experiment")
        save(output / "manifest.json", manifest)

        tests = []
        for variant in ("baseline", "candidate"):
            package = output / "build" / variant
            for configuration in ("debug", "release"):
                label = f"tests-{variant}-{configuration}"
                print(label, flush=True)
                log = command([
                    swift, "test", "--package-path", package,
                    "--scratch-path", package / ".build",
                    "--configuration", configuration, "--jobs", "2", "--no-parallel",
                    "--cache-path", output / "cache",
                    "--config-path", output / "config",
                    "--security-path", output / "security",
                    "-Xswiftc", "-warnings-as-errors",
                ], output, label)
                matches = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", log)
                if not matches or int(matches[-1]) < 8:
                    raise RuntimeError(f"{label} did not discover and pass the expected ring/queue tests")
                tests.append({"variant": variant, "configuration": configuration,
                              "passed": True, "test_count": int(matches[-1])})
                save(output / "verification.json", {"tests": tests})
        if len({test["test_count"] for test in tests}) != 1:
            raise RuntimeError("Source variants/configurations discovered different test counts")
        if args.tests_only:
            save(output / "summary.json", {"status": "tests_passed", "tests": tests, "timing_run": False})
            return

        binaries = {}
        for variant in ("baseline", "candidate"):
            package = output / "build" / variant
            binary = package / "ring-probe"
            command([
                swiftc, *FLAGS,
                *[package / "Sources/IlliquidNativePlayback" / Path(relative).name
                  for relative in SOURCE_FILES],
                package / "Driver.swift", "-o", binary,
            ], output, f"compile-{variant}")
            binaries[variant] = binary
        manifest["binary_paths"] = {variant: str(binary) for variant, binary in binaries.items()}
        manifest["binary_hashes"] = {variant: digest(binary.read_bytes()) for variant, binary in binaries.items()}
        save(output / "manifest.json", manifest)

        workloads = [(case, capacity) for case in cases for capacity in capacities]
        iterations_for = {}
        receipts = {}

        def verify(row: dict) -> None:
            key = (row["case"], row["capacity"], row["iterations"])
            receipt = (row["checksum"], row["operations"])
            if key in receipts and receipts[key] != receipt:
                raise RuntimeError(f"Non-deterministic or mismatched checksum for {key}")
            receipts[key] = receipt

        warmups = []
        for case, capacity in workloads:
            for variant, binary in binaries.items():
                row = probe(binary, case, capacity, 1024, output)
                verify(row)
                warmups.append({"variant": variant, **row})
            iterations = 1024
            for attempt in range(16):
                row = probe(binaries["baseline"], case, capacity, iterations, output)
                verify(row)
                append(output / "calibration.jsonl", {"attempt": attempt, "variant": "baseline", **row})
                if row["elapsed_ns"] >= args.target_ms * 1_000_000:
                    break
                if iterations >= MAX_ITERATIONS:
                    raise RuntimeError(f"Cannot reach target duration for {case}/{capacity}")
                iterations = min(MAX_ITERATIONS, max(
                    iterations * 2,
                    math.ceil(iterations * args.target_ms * 1_000_000 / row["elapsed_ns"] * 1.1),
                ))
            else:
                raise RuntimeError(f"Calibration did not converge for {case}/{capacity}")
            iterations_for[(case, capacity)] = iterations
        save(output / "verification.json", {
            "tests": tests, "warmup_receipts": warmups, "warmup_checksums_match": True,
        })

        rows = []
        for pair in range(args.pairs):
            ordering = list(workloads)
            random.Random(args.seed + pair).shuffle(ordering)
            variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            print(f"Measuring pair {pair + 1}/{args.pairs}: {'/'.join(variants)}", flush=True)
            for workload_order, (case, capacity) in enumerate(ordering):
                for position, variant in enumerate(variants):
                    row = probe(binaries[variant], case, capacity, iterations_for[(case, capacity)], output)
                    verify(row)
                    row = {**row, "variant": variant, "pair": pair,
                           "workload_order": workload_order, "position": position,
                           "sequence": len(rows)}
                    rows.append(row)
                    append(output / "observations.jsonl", row)
        summary = {
            "status": "passed",
            "tests": tests,
            "measurements": len(rows),
            "all_checksums_match": True,
            "timing_gate": False,
            "unit": "nanoseconds per complete enqueue/dequeue cycle",
            "scope": manifest["method"]["scope"],
            "workloads": summarize(rows, workloads, args.pairs),
        }
        save(output / "summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)
    except Exception as error:
        save(output / "failure.json", {
            "type": type(error).__name__, "message": str(error),
            "status": "failed", "evidence_retained": True,
        })
        raise


if __name__ == "__main__":
    main()
