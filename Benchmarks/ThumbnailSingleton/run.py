#!/usr/bin/env python3
"""Compare singleton preparation with the already-bounded neighborhood helper."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile

BASELINE = "8637a8d2c6a628699d5a552a55061b4e0bfc6f10"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
SUPPORT = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
]
FLAGS = ["-swift-version", "6", "-O"]
MODULE_FLAGS = [*FLAGS, "-whole-module-optimization", "-parse-as-library", "-enable-testing"]
POSITIONS = ["nil", "front", "middle", "last", "absent"]


def command(arguments: list[str], **kwargs) -> str:
    return subprocess.check_output(arguments, text=True, **kwargs).strip()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-revision", default=BASELINE)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=50)
    parser.add_argument("--counts", default="1,2,8,32,10000")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be even and at least two for balanced AB/BA pairs")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    try:
        counts = [int(value) for value in args.counts.split(",")]
        if not counts or min(counts) <= 0 or len(set(counts)) != len(counts):
            raise ValueError()
    except ValueError:
        parser.error("--counts must be distinct positive integers")
    root = Path(__file__).resolve().parents[2]
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise SystemExit("swiftc is unavailable")
    revision = command(["git", "-C", str(root), "rev-parse", args.baseline_revision + "^{commit}"])
    original = subprocess.check_output(["git", "-C", str(root), "show", revision + ":" + SCHEDULER])
    baseline = subprocess.check_output(["git", "-C", str(root), "show", revision + ":" + HELPER])
    candidate = (root / HELPER).read_bytes()
    driver = Path(__file__).with_name("main.swift")
    report = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu": command(["sysctl", "-n", "machdep.cpu.brand_string"]) if platform.system() == "Darwin" else platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "swift": command([swiftc, "--version"]),
            "python": platform.python_version(),
        },
        "provenance": {
            "baseline_revision": revision,
            "candidate_revision": command(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "relevant_status": command(["git", "-C", str(root), "status", "--short", "--", SCHEDULER, HELPER, *SUPPORT]),
            "baseline_scheduler_sha256": sha256(original),
            "baseline_helper_sha256": sha256(baseline),
            "candidate_helper_sha256": sha256(candidate),
            "candidate_scheduler_sha256": sha256((root / SCHEDULER).read_bytes()),
            "driver_sha256": sha256(driver.read_bytes()),
            "runner_sha256": sha256(Path(__file__).read_bytes()),
            "support_sha256": {path: sha256((root / path).read_bytes()) for path in SUPPORT},
        },
        "method": {
            "compiler_flags": FLAGS,
            "module_flags": MODULE_FLAGS,
            "baseline": "Complete, unmodified bounded ThumbnailPlaylistNeighborhood.swift from PR #132 at the pinned revision.",
            "candidate": "Unmodified production ThumbnailPlaylistNeighborhood.swift.",
            "boundary": "Both helpers compiled as a separate optimized IlliquidApp module; identical unmodified IlliquidCore support sources and benchmark driver.",
            "sampling": "Fresh processes in balanced AB/BA pairs. One untimed warmup per process. Independent calibration per variant, up to four retained trials targeting at least 80% of the requested interval, capped at 5000000 calls. Calibration is excluded from timed summaries.",
            "timer": "DispatchTime interval around repeated helper calls, output count consumption, and result destruction. Fixture creation, normalization, warmup, and exact output validation are outside the interval.",
            "scope": "Synchronous neighborhood preparation only; no actor scheduling, decoding, rendering, full-app latency, or energy measurement.",
            "memory_scope": "Both versions already retain at most nine URLs and nine distance entries. This experiment measures construction time, not allocation counts, peak RSS, or a new asymptotic memory reduction.",
            "rounds": args.rounds,
            "target_ms": args.target_ms,
            "counts": counts,
            "positions": POSITIONS,
        },
        "calibration": {},
        "receipts": {},
        "rows": [],
        "summaries": {},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".thumbnail-singleton-", dir=root) as temporary:
        work = Path(temporary)
        core = work / "core"
        core.mkdir()
        core_object = core / "IlliquidCore.o"
        subprocess.run([
            swiftc, *MODULE_FLAGS, "-emit-module", "-emit-object", "-module-name", "IlliquidCore",
            "-emit-module-path", str(core / "IlliquidCore.swiftmodule"),
            *[str(root / path) for path in SUPPORT], "-o", str(core_object),
        ], check=True)
        probes = {}
        for variant, source in [("baseline", baseline), ("candidate", candidate)]:
            directory = work / variant
            directory.mkdir()
            path = directory / "ThumbnailPlaylistNeighborhood.swift"
            path.write_bytes(source)
            object_file = directory / "IlliquidApp.o"
            subprocess.run([
                swiftc, *MODULE_FLAGS, "-I", str(core), "-emit-module", "-emit-object",
                "-module-name", "IlliquidApp", "-emit-module-path", str(directory / "IlliquidApp.swiftmodule"),
                str(path), "-o", str(object_file),
            ], check=True)
            probe = directory / "probe"
            subprocess.run([
                swiftc, *FLAGS, "-I", str(core), "-I", str(directory), str(driver),
                str(object_file), str(core_object), "-o", str(probe),
            ], check=True)
            probes[variant] = probe

        def run(variant: str, count: int, position: str, iterations: int) -> dict:
            result = json.loads(command([str(probes[variant]), str(count), position, str(iterations)], timeout=180))
            if (result["iterations"] != iterations or result["count"] != count
                    or result["position"] != position or result["elapsed_nanoseconds"] <= 0):
                raise RuntimeError("Invalid benchmark result")
            key = f"{count}/{position}"
            if key in report["receipts"] and report["receipts"][key] != result["receipt"]:
                raise RuntimeError("Exact output mismatch for " + key + "/" + variant)
            report["receipts"][key] = result["receipt"]
            stride = result["url_stride_bytes"]
            if report["environment"].setdefault("url_stride_bytes", stride) != stride:
                raise RuntimeError("URL layout differs between variants")
            return result

        for count in counts:
            positions = ["nil", "front", "absent"] if count == 1 else (["nil", "front", "last", "absent"] if count == 2 else POSITIONS)
            for position in positions:
                key = f"{count}/{position}"
                iterations = {}
                calibration = {}
                for variant in ["baseline", "candidate"]:
                    trials = []
                    trial_iterations = 1
                    for _ in range(4):
                        sample = run(variant, count, position, trial_iterations)
                        trials.append({
                            "iterations": trial_iterations,
                            "elapsed_nanoseconds": sample["elapsed_nanoseconds"],
                        })
                        if sample["elapsed_nanoseconds"] >= args.target_ms * 800_000 or trial_iterations == 5_000_000:
                            break
                        if len(trials) < 4:
                            trial_iterations = min(5_000_000, max(trial_iterations + 1, math.ceil(
                                trial_iterations * args.target_ms * 1_000_000 / sample["elapsed_nanoseconds"])))
                    iterations[variant] = trial_iterations
                    calibration[variant] = {"trials": trials, "iterations": trial_iterations}
                report["calibration"][key] = calibration
                timings = {"baseline": [], "candidate": []}
                ratios = []
                for round_number in range(args.rounds):
                    order = ["baseline", "candidate"] if round_number % 2 == 0 else ["candidate", "baseline"]
                    pair = {}
                    for order_index, variant in enumerate(order):
                        result = run(variant, count, position, iterations[variant])
                        ns = result["elapsed_nanoseconds"] / result["iterations"]
                        pair[variant] = ns
                        timings[variant].append(ns)
                        report["rows"].append({
                            "case": key, "round": round_number, "order": order_index, "variant": variant,
                            "iterations": result["iterations"], "elapsed_nanoseconds": result["elapsed_nanoseconds"],
                            "nanoseconds_per_call": ns, "checksum": result["checksum"],
                        })
                    ratios.append(pair["baseline"] / pair["candidate"])
                summary = {
                    variant: {
                        "median_ns": statistics.median(values), "min_ns": min(values), "max_ns": max(values),
                    } for variant, values in timings.items()
                }
                summary.update({
                    "median_paired_speedup": statistics.median(ratios),
                    "candidate_faster_pairs": sum(value > 1 for value in ratios),
                    "pairs": args.rounds,
                    "output_url_count": len(report["receipts"][key]["urls"]),
                })
                report["summaries"][key] = summary
                print(key, json.dumps(summary, sort_keys=True), flush=True)
    report["all_exact_receipts_equal"] = True
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    # Retain a readable receipt in job logs as well as the downloadable artifact.
    print("THUMBNAIL_SINGLETON_REPORT_BEGIN", flush=True)
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    print("THUMBNAIL_SINGLETON_REPORT_END", flush=True)


if __name__ == "__main__":
    main()
