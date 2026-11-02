#!/usr/bin/env python3
"""Qualify exact baseline/candidate thumbnail sample planning in separate Swift modules."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE_REVISION = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "cf3b96706f34ba5c43041d650f4c9f6217e340cc"
SOURCE = "Sources/IlliquidCore/Player/ThumbnailPolicy.swift"
HELPERS = [
    "Sources/IlliquidCore/Player/ThumbnailPassCursor.swift",
    "Sources/IlliquidCore/Player/ThumbnailVisibilityPolicy.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/ThumbnailPolicyTests.swift",
    "Tests/IlliquidCoreTests/ThumbnailSchedulingPolicyRegressionTests.swift",
    "Tests/IlliquidCoreTests/ThumbnailSamplePrefixTests.swift",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailSamplePrefixQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ThumbnailSampleProbe", targets: ["ThumbnailSampleProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "ThumbnailSampleProbe", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
"""
MASK = (1 << 64) - 1


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.env = os.environ.copy()
        self.env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
        self.sequence = 0
        (output / "logs").mkdir()

    def run(self, command: list[str | Path], label: str, timeout: int = 600) -> str:
        self.sequence += 1
        args = [str(value) for value in command]
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        completed = subprocess.run(
            args, cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=timeout
        )
        log.write_text(completed.stdout + completed.stderr)
        self.last_log = log
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({
                "args": args, "exit_code": completed.returncode,
                "seconds": time.monotonic() - started,
                "log": str(log.relative_to(self.output)),
            }, sort_keys=True) + "\n")
        if completed.returncode:
            raise RuntimeError(f"{label} failed:\n{completed.stdout[-5000:]}\n{completed.stderr[-5000:]}")
        return completed.stdout


def measurement(runner: Runner, binary: Path, name: str, iterations: int, label: str) -> dict:
    result = json.loads(runner.run([binary, "measure", name, iterations], label))
    if (result["workload"] != name or result["iterations"] != iterations
            or result["wall_ns"] <= 0 or result["cpu_ns"] <= 0):
        raise RuntimeError(f"Invalid timing receipt: {label}")
    bits = result["output_bits"]
    if result["output_count"] != len(bits) or result["output_capacity"] < len(bits):
        raise RuntimeError(f"Invalid output receipt: {label}")
    unit = len(bits) + (int(bits[0], 16) + int(bits[-1], 16) if bits else 0)
    if int(result["checksum"]) != (unit * iterations & MASK):
        raise RuntimeError(f"Output checksum mismatch: {label}")
    if int(result["warmup_checksum"]) != 64 * len(bits):
        raise RuntimeError(f"Warmup checksum mismatch: {label}")
    result["wall_ns_per_call"] = result["wall_ns"] / iterations
    result["cpu_ns_per_call"] = result["cpu_ns"] / iterations
    return result


def interval(ratios: list[float]) -> list[float]:
    rng = random.Random(20261028)
    medians = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
    return [medians[249], medians[9749]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--kyoto-worker", action="store_true",
                        help="Only use when this entire command was submitted through Kyoto.")
    args = parser.parse_args()
    if args.pairs < 4 or args.pairs % 2:
        parser.error("--pairs must be even and at least four")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
    if kyoto.exists() and not args.kyoto_worker:
        parser.error("Kyoto is available. Submit this command through the shared queue with --kyoto-worker.")
    coordination = "Submitted through Kyoto" if args.kyoto_worker else (
        "Kyoto is unavailable on this host; compiling the isolated packages directly and serially."
    )
    print(coordination, flush=True)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    swift = shutil.which(os.environ.get("SWIFT", "swift"))
    if not swift:
        parser.error("Swift was not found")
    frozen = (HERE / "baseline/ThumbnailPolicy.swift").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(frozen)).encode() + b"\0" + frozen).hexdigest()
    if blob != BASELINE_BLOB:
        raise RuntimeError("Frozen baseline does not match its recorded Git blob")
    candidate = (ROOT / SOURCE).read_bytes()
    runner = Runner(output)
    manifest = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "baseline_revision": BASELINE_REVISION, "baseline_blob": BASELINE_BLOB,
        "candidate_revision": runner.run(["git", "rev-parse", "HEAD"], "revision").strip(),
        "relevant_git_status": runner.run(
            ["git", "status", "--short", "--", SOURCE, *HELPERS, *TESTS, str(HERE.relative_to(ROOT))],
            "status",
        ).strip(),
        "baseline_sha256": digest(frozen), "candidate_sha256": digest(candidate),
        "inputs": {path: digest((ROOT / path).read_bytes()) for path in HELPERS + TESTS},
        "harness": {name: digest((HERE / name).read_bytes()) for name in ["run.py", "Driver.swift"]},
        "package_sha256": digest(PACKAGE.encode()),
        "binaries": {},
        "environment": {
            "platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
            "python": platform.python_version(),
            "swift": runner.run([swift, "--version"], "swift-version").strip(),
            "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR"),
        },
        "build_coordination": coordination,
        "method": {
            "scope": "CPU and wall service time of sample planning; no decoding, UI, I/O, or energy claim",
            "compilation": "Complete unmodified baseline/candidate source in separate SwiftPM modules; release, no cross-module optimization",
            "sampling": "fresh processes; same iteration count in paired AB/BA order; rotate workload order",
            "timed_region": "production call, output count/first/last consumption and array lifetime",
            "excluded": "builds, fixture setup, warmup, JSON and full-output bit-pattern validation",
            "pairs": args.pairs, "target_ms": args.target_ms,
            "interval": "95% percentile bootstrap of paired median speedups; 10000 resamples; seed 20261028",
        },
    }
    save(output / "manifest.json", manifest)
    binaries: dict[str, Path] = {}
    differential = {}
    tests = {}
    for variant, source in [("baseline", frozen), ("candidate", candidate)]:
        package = output / "build" / variant
        library = package / "Sources/IlliquidCore"
        probe = package / "Sources/ThumbnailSampleProbe"
        testdir = package / "Tests/IlliquidCoreTests"
        for directory in [library, probe, testdir]:
            directory.mkdir(parents=True)
        (package / "Package.swift").write_text(PACKAGE)
        (library / "ThumbnailPolicy.swift").write_bytes(source)
        for path in HELPERS:
            shutil.copyfile(ROOT / path, library / Path(path).name)
        shutil.copyfile(HERE / "Driver.swift", probe / "main.swift")
        for path in TESTS:
            shutil.copyfile(ROOT / path, testdir / Path(path).name)
        tests[variant] = {}
        differential[variant] = {}
        for config in ["debug", "release"]:
            print(f"Testing {variant} {config}", flush=True)
            log = runner.run(
                [swift, "test", "--package-path", package, "--configuration", config,
                 "--no-parallel", "--jobs", "2"],
                f"{variant}-{config}-tests",
            )
            log = runner.last_log.read_text()
            count = re.search(r"Test run with (\d+) tests?.*passed", log)
            if count is None or int(count.group(1)) < 20:
                raise RuntimeError(f"Expected all thumbnail policy tests: {variant}/{config}")
            tests[variant][config] = {"passed": True, "tests": int(count.group(1)), "log_tail": log[-2000:]}
            runner.run(
                [swift, "build", "--package-path", package, "--configuration", config,
                 "--product", "ThumbnailSampleProbe", "--jobs", "2"],
                f"{variant}-{config}-probe-build",
            )
            bindir = Path(runner.run(
                [swift, "build", "--package-path", package, "--configuration", config, "--show-bin-path"],
                f"{variant}-{config}-binpath",
            ).strip())
            binary = bindir / "ThumbnailSampleProbe"
            manifest["binaries"][f"{variant}-{config}"] = digest(binary.read_bytes())
            save(output / "manifest.json", manifest)
            payload = runner.run([binary, "differential"], f"{variant}-{config}-differential")
            rows = json.loads(payload)
            if variant == "baseline" and config == "debug":
                reference = rows
            if rows != reference:
                mismatches = [i for i, (a, b) in enumerate(zip(reference, rows)) if a != b]
                raise RuntimeError(f"Exact output differential failed: {variant}/{config}: {mismatches[:8]}")
            differential[variant][config] = {
                "cases": len(rows), "passed": True, "output_sha256": digest(payload.encode())
            }
            if config == "release":
                binaries[variant] = binary
    save(output / "tests.json", tests)
    save(output / "differential.json", differential)
    cases = json.loads(runner.run([binaries["baseline"], "list"], "cases"))
    save(output / "cases.json", cases)
    calibrations = []
    iterations_by_case = {}
    for case in cases:
        name = case["name"]
        iterations = 1000
        for attempt in range(5):
            rows = {variant: measurement(runner, binary, name, iterations,
                                        f"calibrate-{name}-{attempt}-{variant}")
                    for variant, binary in binaries.items()}
            if rows["baseline"]["output_bits"] != rows["candidate"]["output_bits"]:
                raise RuntimeError(f"Calibration output mismatch: {name}")
            calibrations.append({"workload": name, "attempt": attempt, "measurements": rows})
            faster = min(row["wall_ns"] for row in rows.values())
            target = args.target_ms * 1_000_000
            if faster >= target * 0.75:
                break
            iterations = min(20_000_000, max(iterations + 1, math.ceil(iterations * target / faster)))
        iterations_by_case[name] = iterations
    save(output / "calibration.json", calibrations)
    observations = []
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        rotated = cases[pair % len(cases):] + cases[:pair % len(cases)]
        print(f"Measuring pair {pair + 1}/{args.pairs} ({'/'.join(order)})", flush=True)
        for case in rotated:
            name = case["name"]
            pair_rows = {}
            for variant in order:
                row = measurement(runner, binaries[variant], name, iterations_by_case[name],
                                  f"pair-{pair:02d}-{name}-{variant}")
                row.update(variant=variant, pair=pair, order=order)
                observations.append(row)
                pair_rows[variant] = row
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if (pair_rows["baseline"]["output_bits"] != pair_rows["candidate"]["output_bits"]
                    or pair_rows["baseline"]["checksum"] != pair_rows["candidate"]["checksum"]):
                raise RuntimeError(f"Timed output mismatch: {name}/{pair}")
    summaries = []
    for case in cases:
        name = case["name"]
        selected = [row for row in observations if row["workload"] == name]
        item = {"workload": name, "pairs": args.pairs, "iterations": iterations_by_case[name]}
        for clock in ["wall", "cpu"]:
            metric = f"{clock}_ns_per_call"
            before = [row[metric] for row in selected if row["variant"] == "baseline"]
            after = [row[metric] for row in selected if row["variant"] == "candidate"]
            ratios = [a / b for a, b in zip(before, after)]
            speedup = statistics.median(ratios)
            item[clock] = {
                "baseline_median_ns": statistics.median(before),
                "candidate_median_ns": statistics.median(after),
                "paired_median_speedup": speedup, "paired_speedups": ratios,
                "speedup_95pct_bootstrap_interval": interval(ratios),
                "service_time_reduction_percent": (1 - 1 / speedup) * 100,
            }
        for variant in ["baseline", "candidate"]:
            row = next(row for row in selected if row["variant"] == variant)
            item[variant + "_output"] = {
                "count": row["output_count"], "capacity": row["output_capacity"],
                "bits": row["output_bits"],
            }
        summaries.append(item)
    summary = {
        "schema_version": 1, "candidate_revision": manifest["candidate_revision"],
        "baseline_revision": BASELINE_REVISION,
        "all_differential_cases_match": True,
        "cases_per_configuration": len(reference),
        "measurements": summaries,
    }
    save(output / "summary.json", summary)
    save(output / "completion.json", {"tests": "passed", "differential": "passed", "timing": "completed"})
    print("THUMBNAIL_SAMPLE_SUMMARY_JSON " + json.dumps(summary, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
