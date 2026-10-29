#!/usr/bin/env python3
"""Measure the production bounded queue with frozen-baseline/source parity."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import time

BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_QUEUE_BLOB = "ed52718d3bd42d1ebbd157343334be2bc6b6cc91"
RING_BLOB = "f381657f22d07f49941b05afbd0c2549a2d98b1e"
VARIANTS = ("baseline", "candidate")


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def optional_command(command, cwd=None):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def cases():
    result = []

    def add(mode, method, costs, capacity, depth):
        result.append({
            "id": f"{mode}/{method}/{costs}/capacity-{capacity}/depth-{depth}",
            "mode": mode, "method": method, "costs": costs,
            "capacity": capacity, "depth": depth,
        })

    for costs in ("zero", "packet"):
        for method in ("push", "try-push", "prepend"):
            add("buffered", method, costs, 96, 1)
        for capacity, depth in ((48, 4), (64, 16), (96, 48), (192, 48)):
            for method in ("push", "try-push"):
                add("buffered", method, costs, capacity, depth)
        add("buffered", "prepend", costs, 64, 16)
        for capacity in (1, 48, 96):
            add("threaded", "push", costs, capacity, 1)
    return result


def command_for(binary, case, iterations):
    return [
        str(binary), case["mode"], case["method"], case["costs"],
        str(case["capacity"]), str(case["depth"]), str(iterations),
    ]


def validate(observation, case, iterations):
    for key in ("mode", "method", "costs", "capacity", "depth"):
        if observation[key] != case[key]:
            raise RuntimeError(f"case mismatch: {case['id']} {key}")
    transfers = iterations * case["depth"]
    if observation["iterations"] != iterations or observation["transfers"] != transfers:
        raise RuntimeError(f"operation-count mismatch: {case['id']}")
    if observation["queueOperations"] != transfers * 2:
        raise RuntimeError(f"queue-operation mismatch: {case['id']}")
    if case["mode"] == "buffered":
        expected = iterations * case["depth"] * (case["depth"] + 1) // 2
        if observation["producerWaits"] != 0:
            raise RuntimeError(f"uncontended fixture unexpectedly waited: {case['id']}")
    else:
        cycles, remainder = divmod(iterations, 4096)
        expected = cycles * 4096 * 4097 // 2 + remainder * (remainder + 1) // 2
    if int(observation["checksum"], 16) != expected:
        raise RuntimeError(f"payload receipt mismatch: {case['id']}")
    if observation["elapsedNanoseconds"] <= 0 or observation["processCPUSeconds"] < 0:
        raise RuntimeError(f"invalid timing observation: {case['id']}")


def run_observation(binary, case, iterations, output):
    command = command_for(binary, case, iterations)
    started = time.monotonic()
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(
                f"driver exited {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        observation = json.loads(result.stdout)
        validate(observation, case, iterations)
    except Exception as error:
        write_json(output / "failure.json", {
            "time": timestamp(), "command": command, "case": case,
            "error": str(error),
        })
        raise
    observation["command"] = command
    observation["processWallSeconds"] = time.monotonic() - started
    return observation


def receipt(observation):
    # Scheduling changes may legitimately change waits. Those are retained in
    # the raw evidence, but they are not semantic-equivalence requirements.
    keys = (
        "mode", "method", "costs", "capacity", "depth", "iterations",
        "warmupTransfers", "transfers", "queueOperations", "checksum",
    )
    return {key: observation[key] for key in keys}


def describe(values):
    return {
        "median": statistics.median(values),
        "minimum": min(values),
        "maximum": max(values),
        "samples": len(values),
    }


def summarize(rows, case_list, rounds):
    summaries = []
    for case in case_list:
        selected = [row for row in rows if row["case_id"] == case["id"]]
        variants = {}
        for variant in VARIANTS:
            samples = [row for row in selected if row["variant"] == variant]
            if len(samples) != rounds:
                raise RuntimeError(f"incomplete measurements: {case['id']} {variant}")
            variants[variant] = {
                "wall_ns_per_transfer": describe([
                    row["elapsedNanoseconds"] / row["transfers"] for row in samples
                ]),
                "process_cpu_ns_per_transfer": describe([
                    row["processCPUSeconds"] * 1e9 / row["transfers"] for row in samples
                ]),
                "producer_waits": describe([row["producerWaits"] for row in samples]),
                "producer_wait_seconds": describe([row["producerWaitSeconds"] for row in samples]),
            }
        paired_ratios = []
        for round_number in range(rounds):
            pair = {row["variant"]: row for row in selected if row["round"] == round_number}
            if receipt(pair["baseline"]) != receipt(pair["candidate"]):
                raise RuntimeError(f"variant receipt mismatch: {case['id']} round {round_number}")
            paired_ratios.append(
                pair["baseline"]["elapsedNanoseconds"] / pair["candidate"]["elapsedNanoseconds"]
            )
        before = variants["baseline"]["wall_ns_per_transfer"]["median"]
        after = variants["candidate"]["wall_ns_per_transfer"]["median"]
        summaries.append({
            "case": case,
            "iterations": selected[0]["iterations"],
            "transfers_per_process": selected[0]["transfers"],
            "variants": variants,
            "baseline_over_candidate_paired_ratio": describe(paired_ratios),
            "median_wall_time_reduction_percent": (1 - after / before) * 100,
            "median_wall_ns_saved_per_transfer": before - after,
        })
    return {
        "scope": (
            "Synthetic component measurements of complete production queue methods. "
            "One transfer is one enqueue and one pop. Payload/queue/thread creation "
            "and warmup are excluded; threaded capacity and consumer waits are included. "
            "These are not full playback, decoding, rendering, or energy measurements."
        ),
        "rounds": rounds,
        "receipt_parity": "passed",
        "observation_count": len(rows),
        "cases": summaries,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100.0)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be a positive even number of at least 2")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    if not args.swiftc:
        parser.error("Swift 6.1 or newer is required on PATH (or pass --swiftc)")

    benchmark = Path(__file__).resolve().parent
    root = benchmark.parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source_paths = {
        "baseline_queue": benchmark / "baseline" / "PacketQueue.swift",
        "candidate_queue": root / "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
        "ring": root / "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
        "driver": benchmark / "Driver.swift",
        "runner": Path(__file__).resolve(),
    }
    sources = {name: path.read_bytes() for name, path in source_paths.items()}
    if git_blob(sources["baseline_queue"]) != BASELINE_QUEUE_BLOB:
        raise RuntimeError("Frozen baseline PacketQueue.swift does not match the pinned Git blob")
    if git_blob(sources["ring"]) != RING_BLOB:
        raise RuntimeError("FixedRingBuffer.swift changed; re-evaluate this controlled comparison")
    manifest = {
        "started_utc": timestamp(),
        "baseline_commit": BASELINE_COMMIT,
        "baseline_queue_blob": BASELINE_QUEUE_BLOB,
        "rounds": args.rounds,
        "target_baseline_ms": args.target_ms,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "cpu_count": os.cpu_count(),
            "macos_cpu": optional_command(["sysctl", "-n", "machdep.cpu.brand_string"])
                if platform.system() == "Darwin" else None,
        },
        "compiler": optional_command([args.swiftc, "--version"]),
        "git_revision": optional_command(["git", "rev-parse", "HEAD"], cwd=root),
        "git_status": optional_command(["git", "status", "--porcelain"], cwd=root),
        "sources": {
            name: {
                "path": str(path.relative_to(root)),
                "sha256": sha256(sources[name]),
                "git_blob": git_blob(sources[name]),
            }
            for name, path in source_paths.items()
        },
        "build_commands": [],
        "binaries": {},
        "ordering": "Seeded case order; AB on even rounds, BA on odd rounds; fresh process per observation.",
    }
    write_json(output / "manifest.json", manifest)
    binaries = {}
    for variant in VARIANTS:
        build = output / "build" / variant
        build.mkdir(parents=True)
        (build / "PacketQueue.swift").write_bytes(sources[f"{variant}_queue"])
        (build / "FixedRingBuffer.swift").write_bytes(sources["ring"])
        (build / "Driver.swift").write_bytes(sources["driver"])
        binary = build / "driver"
        command = [
            args.swiftc, "-swift-version", "6", "-O", "-whole-module-optimization",
            "-parse-as-library", "-warnings-as-errors", "-module-name", "QueueNotificationsBenchmark",
            str(build / "PacketQueue.swift"), str(build / "FixedRingBuffer.swift"),
            str(build / "Driver.swift"), "-o", str(binary),
        ]
        manifest["build_commands"].append(command)
        write_json(output / "manifest.json", manifest)
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        (output / f"build-{variant}.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"{variant} build failed; see build-{variant}.log")
        binaries[variant] = binary
        manifest["binaries"][variant] = {"path": str(binary), "sha256": sha256(binary.read_bytes())}
        write_json(output / "manifest.json", manifest)

    case_list = cases()
    write_json(output / "cases.json", case_list)
    calibration = {}
    for case in case_list:
        if case["mode"] == "threaded":
            iterations = 20_000 if case["capacity"] == 1 else 100_000
            calibration[case["id"]] = {
                "iterations": iterations,
                "reason": "Fixed transfer count; includes synchronized producer/consumer waits.",
            }
        else:
            initial = max(256, 20_000 // case["depth"])
            observation = run_observation(binaries["baseline"], case, initial, output)
            estimate = math.ceil(initial * args.target_ms * 1e6 / observation["elapsedNanoseconds"])
            iterations = max(256, min(4_000_000 // case["depth"], estimate))
            calibration[case["id"]] = {
                "iterations": iterations,
                "initial_observation": observation,
            }
        write_json(output / "calibration.json", calibration)

    rows = []
    sequence = 0
    with (output / "observations.jsonl").open("w") as raw:
        for round_number in range(args.rounds):
            ordered = list(case_list)
            random.Random(0x111C01D + round_number).shuffle(ordered)
            order = VARIANTS if round_number % 2 == 0 else tuple(reversed(VARIANTS))
            for case in ordered:
                pair = {}
                for variant in order:
                    observation = run_observation(
                        binaries[variant], case, calibration[case["id"]]["iterations"], output
                    )
                    row = {
                        "round": round_number, "sequence": sequence,
                        "variant": variant, "case_id": case["id"], **observation,
                    }
                    raw.write(json.dumps(row, sort_keys=True) + "\n")
                    raw.flush()
                    rows.append(row)
                    pair[variant] = row
                    sequence += 1
                if receipt(pair["baseline"]) != receipt(pair["candidate"]):
                    raise RuntimeError(f"variant receipt mismatch: {case['id']} round {round_number}")
            print(f"Completed round {round_number + 1}/{args.rounds}", flush=True)

    for name, path in source_paths.items():
        if path.read_bytes() != sources[name]:
            raise RuntimeError(f"source changed during measurement: {path}")
    summary = summarize(rows, case_list, args.rounds)
    write_json(output / "summary.json", summary)
    manifest["finished_utc"] = timestamp()
    manifest["verified_observations"] = len(rows)
    write_json(output / "manifest.json", manifest)
    write_json(output / "completion.json", {
        "passed": True, "receipt_parity": True, "sources_unchanged": True,
        "observations": len(rows), "cases": len(case_list), "rounds": args.rounds,
    })
    print("Case | baseline ns/transfer | candidate ns/transfer | reduction %")
    for row in summary["cases"]:
        before = row["variants"]["baseline"]["wall_ns_per_transfer"]["median"]
        after = row["variants"]["candidate"]["wall_ns_per_transfer"]["median"]
        print(f"{row['case']['id']} | {before:.2f} | {after:.2f} | "
              f"{row['median_wall_time_reduction_percent']:.2f}")
    print(f"Receipts matched for all {len(rows)} observations. Evidence: {output}")


if __name__ == "__main__":
    main()
