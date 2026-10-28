#!/usr/bin/env python3
"""Qualify the exact production ring buffer on the explicitly selected platform.

macOS is the default. --platform linux provides a separate portability gate;
Linux results must not be reported as native macOS performance evidence.
No third-party Python or Swift package dependencies are required. Component
packages and all evidence are written to a fresh --output directory.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
RING = "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift"
QUEUE = "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift"
BASELINE_RING_BLOB = "f381657f22d07f49941b05afbd0c2549a2d98b1e"
COMMON_QUEUE_BLOB = "ed52718d3bd42d1ebbd157343334be2bc6b6cc91"
TESTS = [
    "Tests/IlliquidNativePlaybackTests/FixedRingBufferTests.swift",
    "Tests/IlliquidNativePlaybackTests/PacketQueueWakeupTests.swift",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "RingBufferWrapQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(
            name: "IlliquidNativePlaybackTests",
            dependencies: ["IlliquidNativePlayback"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
"""
RECEIPT_KEYS = (
    "schema", "workload", "iterations", "capacity", "initial_count",
    "logical_elements_per_iteration", "operations_per_iteration",
    "checksum", "expected_checksum", "final_count",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


class Runner:
    def __init__(self, output: Path, report: dict):
        self.output = output
        self.report = report

    def run(self, command, label: str, *, cwd: Path | None = None,
            allow_failure: bool = False, timeout: int = 300) -> str:
        args = [str(value) for value in command]
        workdir = ROOT if cwd is None else cwd
        index = len(self.report["commands"])
        safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label)
        log = self.output / "logs" / f"{index:04d}-{safe_label}.txt"
        log.parent.mkdir(parents=True, exist_ok=True)
        started = now()
        start = time.perf_counter_ns()
        try:
            process = subprocess.run(
                args, cwd=workdir, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, check=False, timeout=timeout,
            )
            content = process.stdout
            returncode = process.returncode
        except subprocess.TimeoutExpired as error:
            content = (error.stdout or b"") + b"\nRUNNER: command timed out\n"
            returncode = -1
        except OSError as error:
            content = (f"RUNNER: {error}\n").encode()
            returncode = -1
        elapsed = time.perf_counter_ns() - start
        log.write_bytes(content)
        receipt = {
            "index": index, "label": label, "command": args, "cwd": str(workdir),
            "started_utc": started, "elapsed_ns": elapsed, "returncode": returncode,
            "log": str(log.relative_to(self.output)), "log_sha256": digest(content),
            "log_bytes": len(content),
        }
        self.report["commands"].append(receipt)
        text = content.decode("utf-8", errors="replace")
        if returncode != 0 and not allow_failure:
            print(text[-16000:], file=sys.stderr)
            raise RuntimeError(f"{label} failed with status {returncode}; see {receipt['log']}")
        return text

    def json(self, command, label: str, *, timeout: int = 60):
        text = self.run(command, label, timeout=timeout)
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"{label} did not emit a single JSON value") from error


def source_record(data: bytes) -> dict:
    return {"sha256": digest(data), "git_blob_sha1": git_blob(data), "bytes": len(data)}


def stage(output: Path, report: dict):
    baseline_path = HERE / "baseline" / "FixedRingBuffer.swift"
    originals = {
        str(baseline_path.relative_to(ROOT)): baseline_path.read_bytes(),
        RING: (ROOT / RING).read_bytes(),
        QUEUE: (ROOT / QUEUE).read_bytes(),
        str((HERE / "Driver.swift").relative_to(ROOT)): (HERE / "Driver.swift").read_bytes(),
        str(Path(__file__).resolve().relative_to(ROOT)): Path(__file__).read_bytes(),
    }
    originals.update({path: (ROOT / path).read_bytes() for path in TESTS})
    baseline = originals[str(baseline_path.relative_to(ROOT))]
    if git_blob(baseline) != BASELINE_RING_BLOB:
        raise RuntimeError("Frozen FixedRingBuffer baseline does not match the pinned Git blob")
    report["shared_queue"] = {
        "path": QUEUE, "initial_git_blob_sha1": COMMON_QUEUE_BLOB,
        "current_git_blob_sha1": git_blob(originals[QUEUE]),
        "matches_initial_queue_blob": git_blob(originals[QUEUE]) == COMMON_QUEUE_BLOB,
        "contract": "Use the exact current PacketQueue.swift for both baseline and candidate; freeze only the ring-buffer baseline.",
    }
    report["sources"] = {path: source_record(data) for path, data in originals.items()}
    report["baseline"] = {
        "commit": BASELINE, "path": RING, "git_blob_sha1": BASELINE_RING_BLOB,
        "frozen_path": str(baseline_path.relative_to(ROOT)),
    }
    staged = {}
    packages = {}
    benchmarks = {}
    for variant in ("baseline", "candidate"):
        ring = baseline if variant == "baseline" else originals[RING]
        package = output / "packages" / variant
        paths = {
            package / "Package.swift": PACKAGE.encode(),
            package / "Sources" / "IlliquidNativePlayback" / "FixedRingBuffer.swift": ring,
            package / "Sources" / "IlliquidNativePlayback" / "PacketQueue.swift": originals[QUEUE],
        }
        for path in TESTS:
            paths[package / "Tests" / "IlliquidNativePlaybackTests" / Path(path).name] = originals[path]
        benchmark = output / "benchmark-sources" / variant
        paths.update({
            benchmark / "FixedRingBuffer.swift": ring,
            benchmark / "PacketQueue.swift": originals[QUEUE],
            benchmark / "Driver.swift": (HERE / "Driver.swift").read_bytes(),
        })
        for path, data in paths.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            staged[path] = digest(data)
        packages[variant] = package
        benchmarks[variant] = benchmark
    report["staged_sources"] = {
        str(path.relative_to(output)): {"sha256": sha, "bytes": path.stat().st_size}
        for path, sha in staged.items()
    }
    return originals, staged, packages, benchmarks


def positive_int(value, name: str) -> int:
    if type(value) is not int or value <= 0:
        raise RuntimeError(f"{name} must be a positive integer: {value!r}")
    return value


def measurement(runner: Runner, binary: Path, case: dict,
                iterations: int, label: str) -> dict:
    row = runner.json([binary, "measure", case["workload"], iterations], label)
    if not isinstance(row, dict):
        raise RuntimeError(f"{label}: measurement must be an object")
    if row.get("workload") != case["workload"] or row.get("iterations") != iterations:
        raise RuntimeError(f"{label}: measurement identity differs from the command")
    if set(row) != set(RECEIPT_KEYS) | {"wall_ns", "cpu_ns"}:
        raise RuntimeError(f"{label}: unexpected measurement fields")
    for field in (
        "schema", "capacity", "initial_count", "logical_elements_per_iteration",
        "operations_per_iteration", "final_count",
    ):
        if row.get(field) != case[field]:
            raise RuntimeError(f"{label}: inconsistent {field}")
    for field in ("wall_ns", "cpu_ns"):
        positive_int(row.get(field), f"{label}/{field}")
    if not isinstance(row["checksum"], str) or not isinstance(row["expected_checksum"], str):
        raise RuntimeError(f"{label}: checksums must be decimal strings")
    if int(row["checksum"]) != int(row["expected_checksum"]):
        raise RuntimeError(f"{label}: checksum differs from the independent expectation")
    row["command_index"] = len(runner.report["commands"]) - 1
    return row


def equal_receipts(first: dict, second: dict, label: str) -> None:
    if {key: first[key] for key in RECEIPT_KEYS} != {key: second[key] for key in RECEIPT_KEYS}:
        raise RuntimeError(f"{label}: baseline/candidate deterministic measurement receipts differ")


def calibrate(runner: Runner, binaries: dict, cases: list[dict],
              target_ns: int, maximum_ns: int) -> dict:
    counts = {}
    for case_index, case in enumerate(cases):
        name = case["workload"]
        iterations = 1
        records = []
        # Initial estimates are followed by two longer paired observations.
        # Every calibration is retained, including warmup-sized estimates.
        for attempt in range(3):
            order = ("baseline", "candidate") if (case_index + attempt) % 2 == 0 else ("candidate", "baseline")
            observed = {}
            for variant in order:
                row = measurement(
                    runner, binaries[variant], case, iterations,
                    f"calibrate-{case_index}-{attempt}-{variant}",
                )
                row.update({"variant": variant, "attempt": attempt, "order": list(order)})
                records.append(row)
                runner.report["calibration_observations"].append(row)
                observed[variant] = row
            equal_receipts(observed["baseline"], observed["candidate"], f"calibration/{name}/{attempt}")
            per_iteration = [
                observed[variant]["wall_ns"] / iterations for variant in ("baseline", "candidate")
            ]
            fast, slow = min(per_iteration), max(per_iteration)
            target_count = max(1, math.ceil(target_ns / fast))
            # Keep the slower side near or below the stated budget. This is a
            # calibration aim, not a reason to discard an observed slow sample.
            cap_count = max(1, math.floor(maximum_ns / slow))
            iteration_limit = min(
                1_000_000, 1_000_000_000 // case["logical_elements_per_iteration"]
            )
            iterations = min(target_count, cap_count, iteration_limit)
        counts[name] = {
            "iterations": iterations,
            "estimated_fast_ns": min(per_iteration) * iterations,
            "estimated_slow_ns": max(per_iteration) * iterations,
            "target_ns": target_ns,
            "maximum_target_ns": maximum_ns,
            "slower_budget_limited": cap_count < target_count,
            "driver_iteration_limit": iteration_limit,
            "work_budget_limited": iteration_limit < min(target_count, cap_count),
            "calibration_observations": len(records),
        }
        print(f"Calibrated {name}: {iterations} iterations per paired sample", flush=True)
    return counts


def summarize(rows: list[dict], cases: list[dict], pairs: int) -> list[dict]:
    summaries = []
    for case in cases:
        name = case["workload"]
        selected = [row for row in rows if row["workload"] == name]
        if len(selected) != 2 * pairs:
            raise RuntimeError(f"Missing observations for {name}")
        summary = {
            "workload": name, "pairs": pairs,
            "iterations_per_sample": selected[0]["iterations"],
            "logical_elements_per_iteration": case["logical_elements_per_iteration"],
            "operations_per_iteration": case["operations_per_iteration"],
        }
        for metric in ("wall", "cpu"):
            before, after, reductions, savings = [], [], [], []
            for pair in range(pairs):
                grouped = {
                    row["variant"]: row for row in selected if row["pair"] == pair
                }
                if set(grouped) != {"baseline", "candidate"}:
                    raise RuntimeError(f"Incomplete {name}/{pair} pair")
                baseline, candidate = grouped["baseline"], grouped["candidate"]
                if baseline["iterations"] != candidate["iterations"]:
                    raise RuntimeError("Unequal work in a paired comparison")
                equal_receipts(baseline, candidate, f"summary/{name}/{pair}")
                divisor = baseline["iterations"] * case["logical_elements_per_iteration"]
                first, second = baseline[f"{metric}_ns"] / divisor, candidate[f"{metric}_ns"] / divisor
                before.append(first)
                after.append(second)
                reductions.append(100.0 * (first - second) / first)
                savings.append(first - second)
            summary[metric] = {
                "baseline_median_ns_per_element": statistics.median(before),
                "candidate_median_ns_per_element": statistics.median(after),
                "paired_median_reduction_percent": statistics.median(reductions),
                "paired_median_saved_ns_per_element": statistics.median(savings),
                "candidate_wins": sum(right < left for left, right in zip(before, after)),
                "paired_reduction_percent": reductions,
                "baseline_ns_per_element": before,
                "candidate_ns_per_element": after,
                "baseline_median_ns_per_api_operation": statistics.median(before)
                    * case["logical_elements_per_iteration"] / case["operations_per_iteration"],
                "candidate_median_ns_per_api_operation": statistics.median(after)
                    * case["logical_elements_per_iteration"] / case["operations_per_iteration"],
            }
        summaries.append(summary)
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=("macos", "linux"), default="macos")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80.0)
    parser.add_argument("--max-sample-ms", type=float, default=1000.0)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer of at least two")
    if not (0 < args.target_ms <= args.max_sample_ms <= 5000):
        parser.error("require 0 < --target-ms <= --max-sample-ms <= 5000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be a fresh empty directory")
    output.mkdir(parents=True, exist_ok=True)
    report = {
        "schema": 1, "status": "running", "started_utc": now(),
        "arguments": {
            "pairs": args.pairs, "target_ms": args.target_ms,
            "max_sample_ms": args.max_sample_ms, "output": str(output),
            "platform": args.platform,
        },
        "qualification_platform": {
            "requested": args.platform,
            "actual_system": platform.system(),
            "native_macos": args.platform == "macos" and platform.system() == "Darwin",
        },
        "scope": {
            "platform": "Native macOS components." if args.platform == "macos"
                else "Linux component qualification and paired measurements; not native macOS qualification.",
            "production": "Exact FixedRingBuffer.swift and PacketQueue.swift, no source extraction or platform adapters.",
            "compilation": "Swift 6, -O -whole-module-optimization; benchmark and production files compiled together.",
            "measurements": "Warm synthetic component operations, fresh process for each observation.",
            "pairing": "Equal iteration counts; alternating AB/BA pairs; workload order rotated by pair index.",
            "calibration": "Faster variant targeted to requested duration with a slower-variant duration cap.",
            "slow_samples": "No observations discarded; samples exceeding the calibration budget are retained.",
            "limits": "No whole-player CPU, playback, frame-rate, energy, or UI performance claim.",
        },
        "commands": [], "tests": {}, "builds": {},
        "calibration_observations": [], "observations": [],
    }
    save(output / "results.json", report)
    runner = Runner(output, report)
    try:
        expected_system = {"macos": "Darwin", "linux": "Linux"}[args.platform]
        if platform.system() != expected_system:
            raise RuntimeError(
                f"--platform {args.platform} requires {expected_system}, observed {platform.system()}; "
                "results must retain their actual platform"
            )
        print(report["scope"]["platform"], flush=True)
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        report["build_coordination"] = {
            "kyoto_available": kyoto.is_file(),
            "compilation": "Serialized, isolated component packages.",
            "queue_submission": "Managed by the caller when Kyoto is available; not inferred by this runner.",
        }
        if not kyoto.is_file():
            print("Kyoto is unavailable on this hosted runner; compiling serially in isolated packages.", flush=True)
        swift = shutil.which("swift")
        swiftc = shutil.which("swiftc")
        if swift is None or swiftc is None:
            raise RuntimeError("Swift compiler and package manager are required")
        report["environment"] = {
            "platform": platform.platform(), "machine": platform.machine(),
            "python": sys.version,
            "variables": {
                name: os.environ[name] for name in (
                    "DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "TOOLCHAINS",
                    "SWIFT_EXEC", "ImageOS", "ImageVersion", "RUNNER_OS", "RUNNER_ARCH",
                    "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_EVENT_NAME",
                ) if name in os.environ
            },
            "swift": runner.run([swiftc, "--version"], "swift-version").strip(),
            "uname": runner.run(["uname", "-a"], "uname").strip(),
            "git_head": runner.run(["git", "rev-parse", "HEAD"], "git-head").strip(),
            "git_status": runner.run(["git", "status", "--porcelain"], "git-status").strip(),
        }
        if args.platform == "macos":
            report["environment"].update({
                "macos": runner.run(["sw_vers"], "macos-version").strip(),
                "hardware": runner.run(["sysctl", "hw.model", "machdep.cpu.brand_string"], "hardware").strip(),
                "xcode": runner.run(["xcodebuild", "-version"], "xcode-version").strip(),
            })
        else:
            os_release = Path("/etc/os-release")
            cpu_info = Path("/proc/cpuinfo")
            report["environment"].update({
                "linux_os_release": os_release.read_text() if os_release.is_file() else None,
                "cpu_models": sorted({
                    line.split(":", 1)[1].strip() for line in cpu_info.read_text().splitlines()
                    if line.startswith(("model name", "Hardware")) and ":" in line
                }) if cpu_info.is_file() else [],
                "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
            })
        originals, staged, packages, benchmark_sources = stage(output, report)
        save(output / "results.json", report)
        for variant in ("baseline", "candidate"):
            report["tests"][variant] = {}
            for configuration in ("debug", "release"):
                print(f"Testing {variant} / {configuration}", flush=True)
                log = runner.run([
                    swift, "test", "--package-path", packages[variant],
                    "--configuration", configuration, "--jobs", "2", "--no-parallel",
                ], f"test-{variant}-{configuration}", timeout=300)
                counts = re.findall(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log)
                if not counts or int(counts[-1]) <= 0:
                    raise RuntimeError(f"No positive Swift Testing completion receipt for {variant}/{configuration}")
                report["tests"][variant][configuration] = {
                    "passed": True, "tests": int(counts[-1]),
                    "command_index": len(report["commands"]) - 1,
                }
                save(output / "results.json", report)
        test_counts = {
            entry["tests"] for configurations in report["tests"].values()
            for entry in configurations.values()
        }
        if len(test_counts) != 1:
            raise RuntimeError("The four test configurations did not execute the same test count")
        binaries = {}
        for variant in ("baseline", "candidate"):
            source = benchmark_sources[variant]
            binary = output / "bin" / variant
            binary.parent.mkdir(parents=True, exist_ok=True)
            print(f"Building optimized {variant} benchmark", flush=True)
            runner.run([
                swiftc, "-swift-version", "6", "-O", "-whole-module-optimization",
                "-parse-as-library", "-module-cache-path", output / "module-cache",
                source / "FixedRingBuffer.swift", source / "PacketQueue.swift",
                source / "Driver.swift", "-o", binary,
            ], f"build-{variant}", timeout=300)
            binaries[variant] = binary
            report["builds"][variant] = {
                "path": str(binary.relative_to(output)), "sha256": digest(binary.read_bytes()),
                "bytes": binary.stat().st_size, "command_index": len(report["commands"]) - 1,
            }
        listings = {
            variant: runner.json([binary, "list"], f"list-{variant}")
            for variant, binary in binaries.items()
        }
        if listings["baseline"] != listings["candidate"]:
            raise RuntimeError("Baseline and candidate workload lists differ")
        names = listings["baseline"]
        if not isinstance(names, list) or not names or any(not isinstance(name, str) for name in names) or len(set(names)) != len(names):
            raise RuntimeError("Invalid workload list")
        verification = {
            variant: runner.json([binary, "verify"], f"verify-{variant}", timeout=120)
            for variant, binary in binaries.items()
        }
        report["verification"] = verification
        if verification["baseline"] != verification["candidate"]:
            raise RuntimeError("Exact differential verification receipts differ")
        cases = verification["baseline"]["cases"]
        if not isinstance(cases, list) or [case["workload"] for case in cases] != names:
            raise RuntimeError("Verification cases do not match the workload list")
        for case in cases:
            if set(case) != set(RECEIPT_KEYS) or case["schema"] != 1 or case["iterations"] != 3:
                raise RuntimeError("Unexpected verification case schema")
            positive_int(case["operations_per_iteration"], "operations_per_iteration")
            positive_int(case["logical_elements_per_iteration"], "logical_elements_per_iteration")
            if not isinstance(case["checksum"], str) or not isinstance(case["expected_checksum"], str):
                raise RuntimeError("Verification checksums must be decimal strings")
            if int(case["checksum"]) != int(case["expected_checksum"]):
                raise RuntimeError("Verification checksum differs from the independent expectation")
        report["differential_equal"] = True
        report["workloads"] = cases
        save(output / "results.json", report)
        calibration = calibrate(
            runner, binaries, cases, round(args.target_ms * 1_000_000),
            round(args.max_sample_ms * 1_000_000),
        )
        report["calibration"] = calibration
        save(output / "results.json", report)
        for pair in range(args.pairs):
            rotation = pair % len(cases)
            ordered = cases[rotation:] + cases[:rotation]
            variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for case_position, case in enumerate(ordered):
                iterations = calibration[case["workload"]]["iterations"]
                paired_rows = {}
                for variant_position, variant in enumerate(variants):
                    row = measurement(
                        runner, binaries[variant], case, iterations,
                        f"sample-{pair}-{case_position}-{variant}",
                    )
                    row.update({
                        "pair": pair, "variant": variant,
                        "case_position": case_position,
                        "variant_position": variant_position,
                        "variant_order": list(variants),
                        "above_calibration_budget": row["wall_ns"] > args.max_sample_ms * 1_000_000,
                    })
                    report["observations"].append(row)
                    paired_rows[variant] = row
                equal_receipts(
                    paired_rows["baseline"], paired_rows["candidate"],
                    f"sample/{case['workload']}/{pair}",
                )
            save(output / "results.json", report)
            print(f"Completed paired round {pair + 1}/{args.pairs}", flush=True)
        if len(report["observations"]) != len(cases) * args.pairs * 2:
            raise RuntimeError("Unexpected number of timing observations")
        report["summary"] = summarize(report["observations"], cases, args.pairs)
        changed_originals = [path for path, data in originals.items() if (ROOT / path).read_bytes() != data]
        changed_staged = [str(path.relative_to(output)) for path, sha in staged.items() if digest(path.read_bytes()) != sha]
        changed_binaries = [
            variant for variant, binary in binaries.items()
            if digest(binary.read_bytes()) != report["builds"][variant]["sha256"]
        ]
        if changed_originals or changed_staged or changed_binaries:
            raise RuntimeError(f"Inputs changed during qualification: {changed_originals}, {changed_staged}, {changed_binaries}")
        report["unchanged_inputs_and_binaries"] = True
        report["status"] = "completed"
        print("workload | baseline ns/element | candidate ns/element | paired wall reduction | paired CPU reduction")
        for row in report["summary"]:
            wall, cpu = row["wall"], row["cpu"]
            print(f"{row['workload']} | {wall['baseline_median_ns_per_element']:.3f} | "
                  f"{wall['candidate_median_ns_per_element']:.3f} | "
                  f"{wall['paired_median_reduction_percent']:.2f}% | "
                  f"{cpu['paired_median_reduction_percent']:.2f}%")
    except Exception as error:
        report["status"] = "failed"
        report["failure"] = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        report["finished_utc"] = now()
        save(output / "results.json", report)


if __name__ == "__main__":
    main()
