#!/usr/bin/env python3
"""Compare actual Swift filename sorting and in-memory folder playlist construction.

Every subprocess warms its operation before timing. This is warm, reused-input
function work, with no directory enumeration, cold-open, UI, or memory claim.
Complete outputs are compared outside the timer; retained receipts contain SHA256
digests instead of thousands of repeated URLs. Measurements are never filtered.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
NATURAL = "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift"
SOURCES = (
    NATURAL,
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylistDiscovery.swift",
)
FLAGS = ("-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors")


def even_pairs(value: str) -> int:
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an even integer of at least 2") from error
    if number < 2 or number % 2:
        raise argparse.ArgumentTypeError("must be an even integer of at least 2")
    return number


def target_ms(value: str) -> float:
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a finite number between 30 and 1000") from error
    if not math.isfinite(number) or not 30 <= number <= 1000:
        raise argparse.ArgumentTypeError("must be a finite number between 30 and 1000")
    return number


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a", encoding="utf-8") as stream:
        stream.write(canonical(value).decode("utf-8") + "\n")
        stream.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc", help="compiler executable or absolute path")
    parser.add_argument("--output", type=Path, required=True, help="new or empty evidence directory")
    parser.add_argument("--pairs", type=even_pairs, default=10, help="even measured pairs per case (default: 10)")
    parser.add_argument("--target-ms", type=target_ms, default=50.0, help="calibration batch target, 30–1000 ms")
    parser.add_argument("--case", action="append", dest="case_ids", help="exact case identifier; repeat to select several")
    parser.add_argument("--list-cases", action="store_true", help="compile, print case manifest, then exit without timing")
    args = parser.parse_args()
    if args.case_ids and len(set(args.case_ids)) != len(args.case_ids):
        parser.error("--case identifiers must be unique")
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("--output must be a new or empty directory; evidence is never overwritten")
    swiftc = shutil.which(args.swiftc)
    if swiftc is None:
        parser.error(f"compiler not found: {args.swiftc}")
    output.mkdir(parents=True, exist_ok=True)
    command_log = output / "commands.jsonl"
    measurements_path = output / "measurements.jsonl"

    def command(argv: list[str], timeout: int = 300) -> str:
        start = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        except Exception as error:
            append_json(command_log, {"command": argv, "elapsed_seconds": time.monotonic() - start, "error": repr(error)})
            raise
        append_json(command_log, {"command": argv, "elapsed_seconds": time.monotonic() - start,
                    "returncode": result.returncode, "stdout_bytes": len(result.stdout.encode("utf-8")),
                    "stderr": result.stderr})
        if result.returncode:
            raise RuntimeError(f"command failed ({result.returncode}): {argv!r}\n{result.stderr}")
        return result.stdout

    def run_json(argv: list[str]) -> object:
        return json.loads(command(argv))

    environment: dict[str, object] = {
        "schema": 1,
        "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": sys.version,
        "logical_cpu_count": os.cpu_count(),
        "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "compiler_path": str(Path(swiftc).resolve()),
        "compiler_flags": list(FLAGS),
        "pairs": args.pairs,
        "target_ms": args.target_ms,
        "requested_cases": args.case_ids,
        "measurement_scope": "warm in-memory operations on reused inputs; fresh process per variant and pair",
        "timed_includes": "sort/makePlaylist call, result consumption, loop bookkeeping and intermediate result lifetime management",
        "timed_excludes": "fixture construction, one local warmup call, complete output receipt creation, serialization and equality checking",
        "baseline_source": "Benchmarks/NaturalFilenameOrdering/baseline/NaturalFilenameOrdering.swift",
        "status": "running",
    }
    write_json(output / "environment.json", environment)
    try:
        environment["compiler_version"] = command([swiftc, "--version"]).strip()
        environment["git_commit"] = command(["git", "rev-parse", "HEAD"]).strip()
        driver_bytes = (HERE / "Driver.swift").read_bytes()
        environment["driver_sha256"] = digest_bytes(driver_bytes)
        environment["runner_sha256"] = digest_bytes(Path(__file__).read_bytes())
        source_bytes = {name: (ROOT / name).read_bytes() for name in SOURCES}
        baseline_bytes = (HERE / "baseline" / "NaturalFilenameOrdering.swift").read_bytes()
        source_hashes = {
            "baseline": {name: digest_bytes(baseline_bytes if name == NATURAL else data) for name, data in source_bytes.items()},
            "candidate": {name: digest_bytes(data) for name, data in source_bytes.items()},
        }
        write_json(output / "source-hashes.json", source_hashes)
        write_json(output / "environment.json", environment)
        with tempfile.TemporaryDirectory(prefix="build-", dir=output) as build_directory:
            build = Path(build_directory)
            binaries: dict[str, Path] = {}
            for variant in ("baseline", "candidate"):
                directory = build / variant
                directory.mkdir()
                paths = []
                for name, data in source_bytes.items():
                    path = directory / Path(name).name
                    path.write_bytes(baseline_bytes if variant == "baseline" and name == NATURAL else data)
                    paths.append(str(path))
                driver = directory / "Driver.swift"
                driver.write_bytes(driver_bytes)
                executable = directory / "natural-filename-ordering"
                command([swiftc, *FLAGS, *paths, str(driver), "-o", str(executable)])
                binaries[variant] = executable
                write_json(output / f"{variant}-build.json", {
                    "source_sha256": source_hashes[variant],
                    "driver_sha256": digest_bytes(driver.read_bytes()),
                    "binary_sha256": digest_bytes(executable.read_bytes()),
                    "compiler_flags": list(FLAGS),
                })
            manifest = run_json([str(binaries["baseline"]), "list"])
            if not isinstance(manifest, list) or manifest != run_json([str(binaries["candidate"]), "list"]):
                raise RuntimeError("baseline and candidate case manifests differ")
            known = {spec["id"] for spec in manifest}
            if args.case_ids and set(args.case_ids) - known:
                raise ValueError(f"unknown case identifiers: {sorted(set(args.case_ids) - known)}")
            selected = [spec for spec in manifest if not args.case_ids or spec["id"] in args.case_ids]
            write_json(output / "cases.json", selected)
            if args.list_cases:
                print(json.dumps(manifest, indent=2), flush=True)
                environment["status"] = "listed"
                write_json(output / "environment.json", environment)
                return

            # Keep complete baselines in memory, not in retained evidence. Python
            # equality checks every URL representation, item, date and subtitle.
            references: dict[str, dict[str, object]] = {}
            verification: list[dict[str, object]] = []
            for spec in selected:
                outputs = {}
                for variant in ("baseline", "candidate"):
                    record = run_json([str(binaries[variant]), "verify", spec["id"]])
                    if not isinstance(record, dict) or record["spec"] != spec or record["mode"] != "verify":
                        raise RuntimeError("invalid verification record")
                    outputs[variant] = record
                before, after = outputs["baseline"], outputs["candidate"]
                if before["locale"] != after["locale"] or before["receipt"] != after["receipt"]:
                    raise RuntimeError(f"complete baseline/candidate output mismatch for {spec['id']}")
                if before["checksumPerIteration"] != after["checksumPerIteration"]:
                    raise RuntimeError(f"output consumer mismatch for {spec['id']}")
                receipt_hash = digest_bytes(canonical(before["receipt"]))
                references[spec["id"]] = {"receipt": before["receipt"], "checksum": before["checksumPerIteration"],
                    "sha256": receipt_hash, "locale": before["locale"]}
                verification.append({"case": spec["id"], "complete_outputs_equal": True,
                    "receipt_sha256": receipt_hash, "receipt_bytes": len(canonical(before["receipt"])),
                    "checksum_per_iteration": before["checksumPerIteration"], "locale": before["locale"]})
                write_json(output / "verification.json", verification)

            def checked_record(variant: str, spec: dict[str, object], mode: str, parameter: object) -> dict[str, object]:
                record = run_json([str(binaries[variant]), mode, str(spec["id"]), str(parameter)])
                if not isinstance(record, dict) or record["spec"] != spec or record["mode"] != mode:
                    raise RuntimeError("invalid measurement record")
                reference = references[str(spec["id"])]
                receipt = record.pop("receipt")
                if record["locale"] != reference["locale"] or receipt != reference["receipt"]:
                    raise RuntimeError(f"complete measured output mismatch: {variant}/{spec['id']}")
                iterations = record["iterations"]
                elapsed = record["elapsedNanoseconds"]
                if not isinstance(iterations, int) or iterations <= 0 or not isinstance(elapsed, int) or elapsed <= 0:
                    raise RuntimeError("invalid iteration count or duration")
                if mode == "measure" and iterations != parameter:
                    raise RuntimeError("driver ignored the requested iteration count")
                if record["checksumPerIteration"] != reference["checksum"] or record["checksum"] != (int(reference["checksum"]) * iterations) % (1 << 64):
                    raise RuntimeError("timed checksum mismatch")
                if not math.isclose(record["nanosecondsPerOperation"], elapsed / iterations, rel_tol=1e-12):
                    raise RuntimeError("driver reported an inconsistent per-operation duration")
                record.update({"variant": variant, "receipt_sha256": digest_bytes(canonical(receipt)), "complete_output_equal": True})
                return record

            summaries: list[dict[str, object]] = []
            for case_index, spec in enumerate(selected):
                calibration_iterations = []
                # Exactly one excluded warmup/calibration process per variant.
                warmup_order = ("baseline", "candidate") if case_index % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(warmup_order):
                    record = checked_record(variant, spec, "calibrate", args.target_ms)
                    record.update({"phase": "warmup", "pair": -1, "position": position})
                    calibration_iterations.append(record["iterations"])
                    append_json(measurements_path, record)
                iterations = max(calibration_iterations)
                rows: dict[str, list[float]] = {"baseline": [], "candidate": []}
                pair_reductions = []
                for pair in range(args.pairs):
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    pair_values = {}
                    for position, variant in enumerate(order):
                        record = checked_record(variant, spec, "measure", iterations)
                        record.update({"phase": "measured", "pair": pair, "position": position})
                        append_json(measurements_path, record)
                        value = record["nanosecondsPerOperation"]
                        rows[variant].append(value)
                        pair_values[variant] = value
                    pair_reductions.append(100 * (1 - pair_values["candidate"] / pair_values["baseline"]))
                before, after = (statistics.median(rows[variant]) for variant in ("baseline", "candidate"))
                summary = {"case": spec["id"], "spec": spec, "pairs": args.pairs, "iterations_per_process": iterations,
                    "baseline_median_ms": before / 1_000_000, "candidate_median_ms": after / 1_000_000,
                    "reduction_percent": 100 * (1 - after / before),
                    "baseline_range_ms": [min(rows["baseline"]) / 1_000_000, max(rows["baseline"]) / 1_000_000],
                    "candidate_range_ms": [min(rows["candidate"]) / 1_000_000, max(rows["candidate"]) / 1_000_000],
                    "paired_reduction_percent_median": statistics.median(pair_reductions),
                    "paired_reduction_percent_range": [min(pair_reductions), max(pair_reductions)],
                    "candidate_faster_pairs": sum(value > 0 for value in pair_reductions),
                    "receipt_sha256": references[spec["id"]]["sha256"]}
                summaries.append(summary)
                write_json(output / "summary.json", summaries)
                print(json.dumps(summary, sort_keys=True), flush=True)
        environment["status"] = "completed"
        environment["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        environment["measured_process_count"] = len(selected) * args.pairs * 2
        environment["excluded_calibration_process_count"] = len(selected) * 2
        write_json(output / "environment.json", environment)
    except Exception as error:
        environment["status"] = "failed"
        write_json(output / "environment.json", environment)
        write_json(output / "failure.json", {"error": repr(error), "utc": dt.datetime.now(dt.timezone.utc).isoformat()})
        raise


if __name__ == "__main__":
    main()
