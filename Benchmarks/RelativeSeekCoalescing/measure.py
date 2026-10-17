#!/usr/bin/env python3
"""Run paired fresh-process driver measurements and verify their receipts.

Build the two executables with run.py first. All measurements run sequentially;
every workload uses equal AB and BA pairs. Raw results are saved before summary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

DRIVER = "Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift"
VARIANTS = ["baseline", "candidate"]
METRICS = [
    "burst_elapsed_ns", "burst_cpu_ns", "absolute_settlement_elapsed_ns",
    "clock_event_mean_ns", "clock_event_mean_cpu_ns",
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_build(path: Path) -> tuple[dict, Path]:
    manifest = json.loads((path / "manifest.json").read_text())
    if manifest.get("status") != "passed" or manifest.get("configuration") != "release":
        raise ValueError(f"Expected a successful release build: {path}")
    executable = Path(manifest["executable"]["path"])
    if digest(executable) != manifest["executable"]["sha256"]:
        raise ValueError(f"Executable changed after build: {executable}")
    return manifest, executable


def check_builds(builds: dict[str, dict]) -> None:
    a, b = builds["baseline"], builds["candidate"]
    for key in ["compiler", "platform", "configuration"]:
        if a[key] != b[key]:
            raise ValueError(f"Builds disagree on {key}")
    if set(a["sources"]) != set(b["sources"]):
        raise ValueError("Builds use different source sets")
    changes = {
        path for path in a["sources"]
        if a["sources"][path]["sha256"] != b["sources"][path]["sha256"]
    }
    if changes != {DRIVER}:
        raise ValueError(f"Expected only the production driver to differ, got {sorted(changes)}")
    for build in builds.values():
        for path, source in build["sources"].items():
            if source["role"] == "production" and source["transformation"] != "none":
                raise ValueError(f"Production source was transformed: {path}")


def check_result(result: dict, variant: str, burst: int, ticks: int) -> None:
    configuration = result["configuration"]
    if not result["valid_semantics"] or result["invariant_violations_during_burst"]:
        raise ValueError("Harness reported invalid semantics or an invariant violation")
    if configuration["verification_enabled"]:
        raise ValueError("Verification tracing must be separate from headline timings")
    if configuration["relative_seek_commands"] != burst or configuration["clock_events"] != ticks:
        raise ValueError("Harness executed different counts from requested workload")
    after = result["after_clock_events"]
    abandoned = result["abandoned_never_dispatched_seek_effects"]
    expected = abandoned if variant == "baseline" else 0
    if after["pending_effects"] != expected or after["outstanding_effects"] != expected:
        raise ValueError(f"Unexpected retained effect count for {variant}")
    if variant == "baseline" and not result["outstanding_ids_match_abandoned_ids"]:
        raise ValueError("Baseline retained effects do not exactly match undispatched seeks")
    if burst >= 32 and abandoned == 0:
        raise ValueError("The burst did not exercise deferred-seek supersession")


def validate_rows(rows: list[dict], bursts: list[int], repeats: int, ticks: int) -> dict:
    expected_count = len(bursts) * repeats * 2
    if len(rows) != expected_count:
        raise ValueError(f"Expected {expected_count} observations, got {len(rows)}")
    offset = 0
    for repeat in range(repeats):
        rotation = repeat % len(bursts)
        for burst in bursts[rotation:] + bursts[:rotation]:
            pair = rows[offset:offset + 2]
            order = VARIANTS if repeat % 2 == 0 else VARIANTS[::-1]
            for index, (row, variant) in enumerate(zip(pair, order)):
                if (row["repeat"], row["burst"], row["variant"], row["process_order"]) != (
                    repeat, burst, variant, index
                ):
                    raise ValueError(f"Unexpected process order at observation {offset + index}")
                check_result(row["result"], variant, burst, ticks)
            for key in ["configuration", "settled_snapshot", "final_snapshot",
                        "settled_snapshot_checksum", "final_snapshot_checksum"]:
                if pair[0]["result"][key] != pair[1]["result"][key]:
                    raise ValueError(f"Pair differs on {key}: repeat {repeat}, burst {burst}")
            offset += 2
    return {"passed": True, "observations": len(rows), "pairs": len(rows) // 2,
            "ab_pairs_per_workload": repeats // 2, "ba_pairs_per_workload": repeats // 2}


def summaries(rows: list[dict], bursts: list[int]) -> list[dict]:
    summary = []
    for burst in bursts:
        entry = {"relative_seek_commands": burst, "variants": {}, "median_change_percent": {}}
        for variant in VARIANTS:
            selected = [row["result"] for row in rows if row["burst"] == burst and row["variant"] == variant]
            values = {key: [row[key] for row in selected] for key in METRICS}
            values["abandoned_effects"] = [row["abandoned_never_dispatched_seek_effects"] for row in selected]
            values["retained_pending_outstanding_slot_bytes"] = [
                row["after_clock_events"]["pending_outstanding_value_slot_bytes"] for row in selected
            ]
            values["retained_completed_id_slot_bytes"] = [
                row["after_clock_events"]["completed_id_value_slot_bytes"] for row in selected
            ]
            values["native_seek_dispatches"] = [row["native_seek_dispatches"] for row in selected]
            entry["variants"][variant] = {
                key: {"median": statistics.median(value), "min": min(value), "max": max(value)}
                for key, value in values.items()
            }
        for key in METRICS:
            old = entry["variants"]["baseline"][key]["median"]
            new = entry["variants"]["candidate"][key]["median"]
            entry["median_change_percent"][key] = (new / old - 1) * 100 if old else None
        summary.append(entry)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-build", required=True, type=Path)
    parser.add_argument("--candidate-build", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--bursts", default="0,32,256,2048,8192")
    parser.add_argument("--repeats", type=int, default=6)
    parser.add_argument("--ticks", type=int, default=4096)
    args = parser.parse_args()
    bursts = [int(value) for value in args.bursts.split(",")]
    if not bursts or len(bursts) != len(set(bursts)) or any(value < 0 for value in bursts):
        parser.error("--bursts requires unique nonnegative counts")
    if args.repeats < 2 or args.repeats % 2 or args.ticks < 1:
        parser.error("--repeats must be positive and even; --ticks must be positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty; evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    builds, executables = {}, {}
    for variant, directory in [("baseline", args.baseline_build), ("candidate", args.candidate_build)]:
        builds[variant], executables[variant] = load_build(directory.resolve())
        save(output / f"{variant}-build.json", builds[variant])
    check_builds(builds)
    environment = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "python": sys.version,
        "compiler": builds["baseline"]["compiler"],
        "repeats": args.repeats, "bursts": bursts, "ticks": args.ticks,
        "runner_sha256": digest(Path(__file__)),
        "policy": "sequential fresh processes; rotating workload order; equal AB and BA pairs",
    }
    save(output / "environment.json", environment)
    rows = []
    with (output / "measurements.jsonl").open("w") as stream:
        for repeat in range(args.repeats):
            rotation = repeat % len(bursts)
            for burst in bursts[rotation:] + bursts[:rotation]:
                order = VARIANTS if repeat % 2 == 0 else VARIANTS[::-1]
                for index, variant in enumerate(order):
                    command = [str(executables[variant]), "--burst", str(burst), "--ticks", str(args.ticks)]
                    started = datetime.now(timezone.utc).isoformat()
                    begin = time.monotonic()
                    try:
                        process = subprocess.run(command, capture_output=True, text=True, timeout=180)
                    except subprocess.TimeoutExpired as error:
                        row = {"repeat": repeat, "burst": burst, "variant": variant,
                               "process_order": index, "started_utc": started, "command": command,
                               "timeout_seconds": 180, "process_wall_seconds": time.monotonic() - begin,
                               "stdout": str(error.stdout or ""), "stderr": str(error.stderr or "")}
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                        stream.flush()
                        raise
                    row = {"repeat": repeat, "burst": burst, "variant": variant,
                           "process_order": index, "started_utc": started, "command": command,
                           "process_wall_seconds": time.monotonic() - begin,
                           "returncode": process.returncode, "stderr": process.stderr}
                    try:
                        row["result"] = json.loads(process.stdout)
                    except json.JSONDecodeError:
                        row["stdout"] = process.stdout
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    if process.returncode or "result" not in row:
                        raise RuntimeError(f"Benchmark failed; see {output / 'measurements.jsonl'}")
                    check_result(row["result"], variant, burst, args.ticks)
                    rows.append(row)
                    print(f"round {repeat + 1}/{args.repeats}: {variant}, {burst} seeks, "
                          f"{row['result']['clock_event_mean_ns']:.1f} ns/clock event", flush=True)
    validation = validate_rows(rows, bursts, args.repeats, args.ticks)
    for variant in VARIANTS:
        if digest(executables[variant]) != builds[variant]["executable"]["sha256"]:
            raise ValueError("Executable changed during measurements")
    save(output / "validation.json", validation)
    save(output / "summary.json", summaries(rows, bursts))
    print(json.dumps(validation), flush=True)


if __name__ == "__main__":
    main()
