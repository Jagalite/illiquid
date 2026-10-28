#!/usr/bin/env python3
"""Measure thumbnail refinement scheduling using complete production Swift sources.

Requires macOS, Swift 6.1+ and Python 3.10+. Builds and tests pinned baseline
and checkout sources in isolated packages, then runs balanced native pairs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = ["Player/ThumbnailPolicy.swift", "Player/ThumbnailPassCursor.swift",
           "Player/ThumbnailVisibilityPolicy.swift"]
TESTS = ["ThumbnailPolicyTests.swift", "ThumbnailSchedulingPolicyRegressionTests.swift",
         "ThumbnailRefinementOrderTests.swift"]
SOURCE_DIRECTORIES: dict[str, Path] = {}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def run(command: list[str], output: Path, *, timeout: int = 300) -> str:
    started = time.time()
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    append_json(output / "commands.jsonl", {
        "command": command, "returncode": result.returncode,
        "elapsed_seconds": time.time() - started,
    })
    if result.returncode:
        (output / "failure.txt").write_text(result.stdout)
        raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n{result.stdout}")
    return result.stdout


def source_path(variant: str, relative: str) -> Path:
    return SOURCE_DIRECTORIES[variant] / relative


def prepare_sources(variant: str, destination: Path) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    paths = []
    for relative in SOURCES:
        path = destination / Path(relative).name
        shutil.copyfile(source_path(variant, relative), path)
        paths.append(path)
    return paths


def build(variant: str, work: Path, output: Path) -> Path:
    destination = work / variant
    destination.mkdir(parents=True)
    library = destination / ("libIlliquidCore.dylib" if sys.platform == "darwin"
                             else "libIlliquidCore.so")
    paths = [str(path) for path in prepare_sources(variant, destination / "sources")]
    run(["swiftc", "-swift-version", "6", "-O", "-whole-module-optimization", "-enable-testing",
         "-warnings-as-errors", "-emit-library", "-emit-module",
         "-module-name", "IlliquidCore", "-emit-module-path",
         str(destination / "IlliquidCore.swiftmodule"), *paths, "-o", str(library)], output)
    executable = destination / "benchmark"
    run(["swiftc", "-swift-version", "6", "-O", "-warnings-as-errors", "-parse-as-library", "-I",
         str(destination), "-L", str(destination), "-lIlliquidCore", "-Xlinker", "-rpath",
         "-Xlinker", str(destination), str(HERE / "Driver.swift"), "-o", str(executable)], output)
    return executable


def test_variant(variant: str, work: Path, output: Path) -> None:
    package = work / f"tests-{variant}"
    source_dir = package / "Sources/IlliquidCore"
    test_dir = package / "Tests/IlliquidCoreTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    prepare_sources(variant, source_dir)
    for relative in TESTS:
        shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / relative,
                        test_dir / Path(relative).name)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailRefinementRegressionTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
''')
    for configuration in ("debug", "release"):
        log = run(["swift", "test", "--package-path", str(package), "--jobs", "2",
                   "--no-parallel", "-c", configuration, "-Xswiftc", "-warnings-as-errors"],
                  output, timeout=600)
        (output / f"{variant}-{configuration}-tests.txt").write_text(log)
        print(f"{variant} {configuration} regressions passed", flush=True)


def measure(executable: Path, case: str, iterations: int, seed: int,
            output: Path) -> dict:
    record = json.loads(run([str(executable), case, str(iterations), str(seed)],
                            output, timeout=120))
    if record["iterations"] != iterations or record["case"] != case or record["seed"] != seed:
        raise RuntimeError("Driver receipt does not match its command")
    if record["elapsed_ns"] <= 0:
        raise RuntimeError("Driver reported a nonpositive timing")
    receipt = record.pop("receipt")
    record["receipt_sha256"] = digest(json.dumps(receipt, sort_keys=True,
                                               separators=(",", ":")).encode())
    if record["operations_per_iteration"] < 1:
        raise RuntimeError("Driver reported no schedule constructions")
    record["ns_per_iteration"] = record["elapsed_ns"] / iterations
    record["ns_per_operation"] = record["elapsed_ns"] / (iterations * record["operations_per_iteration"])
    # Save one complete receipt per variant/case/seed. The driver checks complete
    # expected output itself before and after timing, not just this digest.
    receipt_dir = output / "receipts"
    receipt_dir.mkdir(exist_ok=True)
    receipt_path = receipt_dir / f"{executable.parent.name}-{case}-{seed}.json"
    write_json(receipt_path, receipt)
    return record


def summarize(records: list[dict]) -> dict:
    summaries = {}
    for case in dict.fromkeys(row["case"] for row in records):
        rows = [row for row in records if row["case"] == case]
        summary = {}
        for variant in ("baseline", "candidate"):
            values = [row["ns_per_operation"] for row in rows if row["variant"] == variant]
            summary[variant] = {"median_ns": statistics.median(values),
                                "min_ns": min(values), "max_ns": max(values)}
        reductions = []
        for pair in sorted({row["pair"] for row in rows}):
            paired = {row["variant"]: row for row in rows if row["pair"] == pair}
            for field in ("receipt_sha256", "checksum", "warmup_checksum", "iterations", "seed", "operations_per_iteration"):
                if paired["baseline"][field] != paired["candidate"][field]:
                    raise RuntimeError(f"Pair mismatch: {case}/{pair}/{field}")
            reductions.append(100 * (1 - paired["candidate"]["ns_per_operation"] /
                                      paired["baseline"]["ns_per_operation"]))
        summary["paired_reduction_percent"] = {
            "median": statistics.median(reductions), "min": min(reductions),
            "max": max(reductions), "candidate_faster_pairs": sum(x > 0 for x in reductions),
            "pairs": len(reductions),
        }
        summary["median_reduction_percent"] = 100 * (1 - summary["candidate"]["median_ns"] /
                                                        summary["baseline"]["median_ns"])
        summaries[case] = summary
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--max-sample-ms", type=float, default=1500)
    parser.add_argument("--cases", help="Comma-separated subset; defaults to all driver cases")
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This qualification requires the native macOS Swift toolchain")
    if (args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or
            args.max_sample_ms < args.target_ms):
        parser.error("Use an even positive pair count and positive timing bounds")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output directory must be empty; preserve earlier attempts separately")
    output.mkdir(parents=True, exist_ok=True)
    work = output / "build"
    work.mkdir()
    try:
        baseline = run(["git", "-C", str(ROOT), "rev-parse", "--verify",
                        args.baseline + "^{commit}"], output).strip()
        if baseline != args.baseline:
            raise RuntimeError("Use a complete baseline commit SHA")
        for variant in ("baseline", "candidate"):
            directory = output / "sources" / variant
            SOURCE_DIRECTORIES[variant] = directory
            for relative in SOURCES:
                path = directory / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                repository_path = "Sources/IlliquidCore/" + relative
                if variant == "baseline":
                    path.write_text(run(["git", "-C", str(ROOT), "show",
                                         baseline + ":" + repository_path], output))
                else:
                    shutil.copyfile(ROOT / repository_path, path)
        inputs = output / "inputs"
        inputs.mkdir()
        for path in [HERE / "Driver.swift", Path(__file__),
                     *(ROOT / "Tests/IlliquidCoreTests" / name for name in TESTS)]:
            shutil.copyfile(path, inputs / path.name)
        manifest = {
            "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], output).strip(),
            "hardware": run(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip(),
            "git_head": run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], output).strip(),
            "git_status": run(["git", "-C", str(ROOT), "status", "--porcelain"], output).strip(),
            "baseline_commit": baseline,
            "arguments": {**vars(args), "output": str(output)},
            "source_sha256": {variant: {path: digest(source_path(variant, path).read_bytes())
                                       for path in SOURCES} for variant in ("baseline", "candidate")},
            "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "test_sha256": {path: digest((ROOT / "Tests/IlliquidCoreTests" / path).read_bytes())
                            for path in TESTS},
            "method": "Whole production sources, separate optimized module, no behavior stubs; "
                      "same-iteration fresh-process pairs with alternating AB/BA order; "
                      "16 prebuilt inputs per case; warm in-memory work; full bit-pattern "
                      "oracle checks outside timing; result allocation/destruction inside timing; "
                      "no discarded samples, control subtraction or timing-based CI threshold.",
            "unit": "nanoseconds per complete refinement schedule construction",
        }
        write_json(output / "manifest.json", manifest)

        # Callers follow repository AGENTS.md for Kyoto coordination. The hosted
        # workflow verifies that no shared queue is available before invoking us.
        print("Compiling isolated regression packages serially.", flush=True)
        for variant in ("baseline", "candidate"):
            test_variant(variant, work, output)
        write_json(output / "tests.json", {
            "baseline_debug": "passed", "baseline_release": "passed",
            "candidate_debug": "passed", "candidate_release": "passed",
            "files": TESTS,
        })
        if args.tests_only:
            return

        executables = {variant: build(variant, work, output) for variant in ("baseline", "candidate")}
        manifest["binary_sha256"] = {
            variant: {path.name: digest(path.read_bytes()) for path in executable.parent.iterdir()
                      if path.is_file() and (path.name == "benchmark" or path.suffix == ".dylib")}
            for variant, executable in executables.items()
        }
        write_json(output / "manifest.json", manifest)
        supported = {variant: json.loads(run([str(binary), "cases"], output))
                     for variant, binary in executables.items()}
        if supported["baseline"] != supported["candidate"]:
            raise RuntimeError("Baseline and candidate driver cases differ")
        cases = args.cases.split(",") if args.cases else supported["candidate"]
        if not cases or len(set(cases)) != len(cases) or any(case not in supported["candidate"] for case in cases):
            raise RuntimeError("Use a nonempty, unique subset of driver cases")
        write_json(output / "cases.json", cases)

        parity = {}
        for variant, executable in executables.items():
            receipt = run([str(executable), "verify", "1028"], output)
            (output / (variant + "-full-parity.json")).write_text(receipt)
            parity[variant] = json.loads(receipt)
        if parity["baseline"] != parity["candidate"]:
            raise RuntimeError("Full baseline/candidate schedule parity mismatch")
        parity_schedules = sum(len(schedules) for schedules in parity["candidate"].values())
        write_json(output / "parity.json", {
            "equal": True, "seed": 1028, "complete_schedules": parity_schedules,
            "cases": len(parity["candidate"]),
            "sha256": digest(json.dumps(parity["candidate"], sort_keys=True,
                                        separators=(",", ":")).encode()),
        })
        records = []
        for case in cases:
            calibration = {}
            for variant, executable in executables.items():
                first = measure(executable, case, 128, 1000, output)
                probe_iterations = max(128, min(100000000, math.ceil(30_000_000 / first["ns_per_iteration"])))
                calibrated = measure(executable, case, probe_iterations, 1000, output)
                calibration[variant] = calibrated["ns_per_iteration"]
                append_json(output / "calibration.jsonl", {"variant": variant, "stage": "pilot", **first})
                append_json(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **calibrated})
            # Equal work in each pair, calibrated against the faster variant.
            # The slower sample is bounded; actual durations remain in evidence.
            iterations = max(1, min(math.ceil(args.target_ms * 1e6 / min(calibration.values())),
                                    math.floor(args.max_sample_ms * 1e6 / max(calibration.values()))))
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    record = measure(executables[variant], case, iterations, 2000 + pair, output)
                    record.update(variant=variant, pair=pair, position=position)
                    records.append(record)
                    append_json(output / "measurements.jsonl", record)
                summarize(records[-2:])
            summary = summarize(records)
            write_json(output / "summary.json", summary)
            print(case, json.dumps(summary[case], sort_keys=True), flush=True)
        write_json(output / "verification.json", {
            "all_pairs_equal": True, "records": len(records), "cases": len(cases),
            "pairs_per_case": args.pairs, "full_parity_schedules": parity_schedules,
        })
    except Exception as error:
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
