#!/usr/bin/env python3
"""Build actual Swift sources and measure balanced fresh-process comparisons."""

import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift"
BASELINE = HERE / "baseline/SubtitleMemoryBudget.swift"
BASE_REVISION = "8c3cc3d4008d5d1b8d436bcf2d51d891382b6548"
BASE_BLOB = "7694b209c13e86406fc2eac6bef2c7ed09974569"
VARIANTS = ("baseline", "same-size-only", "candidate")
MODES = ("resize-same", "resize-change", "acquire-release", "preflight", "snapshot")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def run(command, **kwargs):
    return subprocess.run(command, text=True, check=True, capture_output=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=6,
                        help="multiple of six balances every ordering of three variants")
    parser.add_argument("--iterations", type=int, default=500_000)
    parser.add_argument("--counts", type=int, nargs="+", default=[1, 4, 32, 128])
    parser.add_argument("--modes", nargs="+", choices=MODES, default=MODES)
    parser.add_argument("--candidate-source", type=Path, default=SOURCE,
                        help="defaults to production; may select a preserved experimental source")
    parser.add_argument("--swift-language-version", choices=["5", "6"], default="6")
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    if args.rounds < 6 or args.rounds % 6 or args.iterations < 2 or args.iterations % 2:
        parser.error("rounds must be a positive multiple of six; iterations must be positive and even")
    if any(count < 1 or count > 128 for count in args.counts):
        parser.error("qualified live lease counts are 1 through 128")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = output / "build"
    build.mkdir()
    swiftc = shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("swiftc must be on PATH (Swift 6.1 or newer)")

    baseline = BASELINE.read_bytes()
    if git_blob(baseline) != BASE_BLOB:
        raise SystemExit("pinned baseline Git blob mismatch")
    anchor = "            guard let existing = state.reservations[id] else { return false }\n"
    text = baseline.decode()
    if text.count(anchor) != 1:
        raise SystemExit("same-size ablation anchor is not unique")
    ablation = text.replace(anchor, anchor + "            guard requested != existing.bytes else { return true }\n")

    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "base_revision": BASE_REVISION,
        "baseline_git_blob": BASE_BLOB,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "swift_version": run([swiftc, "--version"]).stdout.strip(),
        "harness_sha256": sha256(HERE / "Harness.swift"),
        "runner_sha256": sha256(Path(__file__)),
        "rounds": args.rounds,
        "iterations": args.iterations,
        "counts": args.counts,
        "modes": args.modes,
        "candidate_source": str(args.candidate_source.resolve()),
        "swift_language_version": args.swift_language_version,
        "variants": {},
        "scope": "Linux/macOS Swift reservation bookkeeping only; no native playback or pixel memory",
    }
    if platform.system() == "Linux":
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.exists():
            manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in cpuinfo.read_text().splitlines() if line.startswith("model name")), None)
        quota = Path("/sys/fs/cgroup/cpu.max")
        if quota.exists():
            manifest["cgroup_cpu_max"] = quota.read_text().strip()
    for variant in VARIANTS:
        destination = build / variant
        destination.mkdir()
        source = destination / "SubtitleMemoryBudget.swift"
        source.write_bytes(baseline if variant == "baseline" else
                           ablation.encode() if variant == "same-size-only" else args.candidate_source.read_bytes())
        harness = destination / "Harness.swift"
        shutil.copy2(HERE / "Harness.swift", harness)
        binary = destination / "budget-benchmark"
        command = [swiftc, "-swift-version", args.swift_language_version,
                   "-O", "-whole-module-optimization", "-warnings-as-errors",
                   str(source), str(harness), "-o", str(binary)]
        if platform.system() == "Darwin":
            command[1:1] = ["-target", f"{platform.machine()}-apple-macosx26.0"]
        try:
            result = run(command)
        except subprocess.CalledProcessError as error:
            print(error.stdout + error.stderr, file=sys.stderr)
            raise
        (destination / "build.log").write_text(result.stdout + result.stderr)
        manifest["variants"][variant] = {
            "command": command,
            "source_sha256": sha256(source),
            "source_git_blob": git_blob(source.read_bytes()),
            "binary_sha256": sha256(binary),
        }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.build_only:
        print(f"Built all three variants in {output}")
        return

    # Every case sees all six permutations. Both predecessor and time-order
    # effects are balanced; each observation is a fresh subprocess.
    orders = list(itertools.permutations(VARIANTS))
    cases = list(itertools.product(args.modes, args.counts))
    rows = []
    with (output / "measurements.jsonl").open("w") as stream:
        for round_index in range(args.rounds):
            round_cases = cases if round_index % 2 == 0 else list(reversed(cases))
            for case_index, (mode, count) in enumerate(round_cases):
                order = orders[round_index % len(orders)]
                receipts = []
                for position, variant in enumerate(order):
                    binary = build / variant / "budget-benchmark"
                    row = json.loads(run([str(binary), mode, str(count), str(args.iterations)]).stdout)
                    row.update(variant=variant, round=round_index, position=position,
                               case_position=case_index, order=list(order))
                    rows.append(row)
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    receipts.append({key: row[key] for key in (
                        "receipt", "warmup_receipt", "reserved_bytes", "owner_count", "rejections")})
                if receipts[1:] != receipts[:-1]:
                    raise SystemExit(f"receipt mismatch for {mode}, {count}, round {round_index}")
            print(f"Completed round {round_index + 1}/{args.rounds}", flush=True)

    summary = []
    for mode, count in cases:
        values = {variant: [row["ns_per_operation"] for row in rows
                           if row["mode"] == mode and row["live_leases"] == count
                           and row["variant"] == variant] for variant in VARIANTS}
        medians = {variant: statistics.median(samples) for variant, samples in values.items()}
        summary.append({
            "mode": mode, "live_leases": count,
            "median_ns": medians,
            "range_ns": {variant: [min(samples), max(samples)] for variant, samples in values.items()},
            "candidate_reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
            "candidate_speedup": medians["baseline"] / medians["candidate"],
        })
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
