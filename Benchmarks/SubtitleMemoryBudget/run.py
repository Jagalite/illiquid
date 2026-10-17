#!/usr/bin/env python3
"""Fresh-process, order-balanced benchmarks of the actual Swift budget sources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PRODUCTION = ROOT / "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift"
BASELINE = HERE / "baseline/SubtitleMemoryBudget.swift"
BASELINE_BLOB = "7694b209c13e86406fc2eac6bef2c7ed09974569"
SCENARIOS = [
    "resize-unchanged", "resize-changing", "resize-rejected", "acquire-release",
    "preflight", "snapshot", "held-snapshot-resize",
]
RECEIPT_KEYS = [
    "scenario", "live_leases", "iterations", "checksum", "reserved_bytes", "by_owner", "rejections",
]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new output directory")
    parser.add_argument("--rounds", type=int, default=6, help="even count for balanced AB/BA pairs")
    parser.add_argument("--iterations", type=int, default=100_000)
    parser.add_argument("--counts", type=int, nargs="+", default=[1, 2, 5, 9, 32, 128])
    parser.add_argument("--scenarios", choices=SCENARIOS, nargs="+", default=SCENARIOS)
    parser.add_argument("--candidate-source", type=Path, default=PRODUCTION)
    parser.add_argument("--include-noop-control", action="store_true")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2 or args.iterations < 1 or any(n < 1 for n in args.counts):
        parser.error("use a positive iteration/count and an even number of rounds >= 2")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = output / "build"
    build.mkdir()
    baseline_bytes = BASELINE.read_bytes()
    baseline_blob = hashlib.sha1(b"blob " + str(len(baseline_bytes)).encode() + b"\0" + baseline_bytes).hexdigest()
    if baseline_blob != BASELINE_BLOB:
        raise RuntimeError("baseline is not the pinned unmodified production blob")
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise RuntimeError("swiftc must be on PATH (Swift 6.1 or newer)")
    sources = {"baseline": BASELINE, "candidate": args.candidate_source.resolve()}
    if args.include_noop_control:
        marker = "guard let existing = state.reservations[id] else { return false }"
        text = baseline_bytes.decode()
        if text.count(marker) != 1:
            raise RuntimeError("unexpected baseline resize body")
        control = build / "UnchangedOnly.swift"
        control.write_text(text.replace(marker, marker + "\n            if requested == existing.bytes { return true }"))
        sources["unchanged-only"] = control
    binaries = {}
    compile_commands = []
    for variant, source in sources.items():
        binary = build / variant
        command = [swiftc, "-O", "-whole-module-optimization", "-parse-as-library", "-module-name", "SubtitleBudgetBenchmark", "-module-cache-path", str(build / "module-cache"), str(source), str(HERE / "BudgetBenchmark.swift"), "-o", str(binary)]
        subprocess.run(command, check=True)
        binaries[variant] = binary
        compile_commands.append(command)
    manifest = {
        "baseline_commit": "8c3cc3d4008d5d1b8d436bcf2d51d891382b6548",
        "baseline_git_blob": baseline_blob,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "swift": subprocess.check_output([swiftc, "--version"], text=True).strip(),
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "cpu_count": os.cpu_count(),
        "compile_commands": compile_commands,
        "source_sha256": {key: sha256(value) for key, value in sources.items()},
        "harness_sha256": sha256(HERE / "BudgetBenchmark.swift"),
        "runner_sha256": sha256(Path(__file__)),
        "binary_sha256": {key: sha256(value) for key, value in binaries.items()},
        "rounds": args.rounds, "iterations": args.iterations,
        "counts": args.counts, "scenarios": args.scenarios,
        "swift_deterministic_hashing": True,
        "timing_scope": "single-thread budget API only; no decoder, native renderer, or pixel storage",
    }
    write_json(output / "manifest.json", manifest)
    rows = []
    rng = random.Random(0xB0D6E7)
    variants = list(sources)
    process_env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1")
    cells = [(scenario, count) for scenario in args.scenarios for count in args.counts]
    # For two variants, each scenario gets AB/BA exactly. With three, alternate
    # permutations and reversals, rotating the leader every pair of rounds.
    for round_index in range(args.rounds):
        rng.shuffle(cells)
        for scenario, count in cells:
            rotation = (round_index // 2) % len(variants) if len(variants) > 2 else 0
            order = variants[rotation:] + variants[:rotation]
            if round_index % 2:
                order = order[::-1]
            reference = None
            for order_index, variant in enumerate(order):
                command = [str(binaries[variant]), scenario, str(count), str(args.iterations)]
                row = json.loads(subprocess.check_output(command, text=True, env=process_env))
                receipt = {key: row[key] for key in RECEIPT_KEYS}
                if reference is not None and receipt != reference:
                    raise RuntimeError(f"behavior mismatch for {scenario}/{count}: {receipt} != {reference}")
                reference = receipt
                row.update(variant=variant, round=round_index, order_index=order_index, command=command)
                rows.append(row)
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"round {round_index + 1}/{args.rounds}: {len(rows)} verified process observations", flush=True)
    summaries = []
    for scenario in args.scenarios:
        for count in args.counts:
            entry = {"scenario": scenario, "live_leases": count, "variants": {}}
            for variant in variants:
                samples = [row["ns_per_operation"] for row in rows if row["scenario"] == scenario and row["live_leases"] == count and row["variant"] == variant]
                entry["variants"][variant] = {"median_ns": statistics.median(samples), "min_ns": min(samples), "max_ns": max(samples), "samples": len(samples)}
            baseline = entry["variants"]["baseline"]["median_ns"]
            for variant in variants[1:]:
                candidate = entry["variants"][variant]["median_ns"]
                entry["variants"][variant]["change_percent"] = (candidate / baseline - 1) * 100
                paired_changes = []
                for round_index in range(args.rounds):
                    pair = {row["variant"]: row["ns_per_operation"] for row in rows
                            if row["scenario"] == scenario and row["live_leases"] == count
                            and row["round"] == round_index}
                    paired_changes.append((pair[variant] / pair["baseline"] - 1) * 100)
                entry["variants"][variant]["median_paired_change_percent"] = statistics.median(paired_changes)
                entry["variants"][variant]["paired_change_percent"] = paired_changes
            summaries.append(entry)
    write_json(output / "summary.json", summaries)
    print(f"saved {len(rows)} timing observations; every paired behavior receipt matched")


if __name__ == "__main__":
    main()
