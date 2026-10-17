#!/usr/bin/env python3
"""Compare exact media-name recognition sources with native Foundation."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
TESTS = ["MediaNameRecognitionTests.swift", "MediaNameRecognitionFastPathTests.swift"]
VARIANTS = ["baseline", "candidate"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "MediaNameRecognitionQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "RecognitionBenchmark", targets: ["RecognitionBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "RecognitionBenchmark", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def execute(command: list, output: Path, env: dict, log_name: str | None = None) -> str:
    command = [str(argument) for argument in command]
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=600)
    record = {
        "command": command, "returncode": result.returncode,
        "wall_seconds": time.monotonic() - started,
        "stdout_sha256": digest(result.stdout.encode()),
        "stderr": result.stderr, "log": log_name,
    }
    with (output / "commands.jsonl").open("a") as log:
        log.write(json.dumps(record, sort_keys=True) + "\n")
    if log_name:
        (output / log_name).write_text(result.stdout + "\nSTDERR\n" + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def prepare(output: Path, variant: str) -> tuple[Path, dict]:
    package = output / "packages" / variant
    mapping = {
        "Sources/IlliquidCore/MediaNameRecognition.swift": (
            HERE / "baseline/MediaNameRecognition.swift" if variant == "baseline" else ROOT / SOURCE
        ),
        **{f"Sources/RecognitionBenchmark/{name}": HERE / name for name in ["Driver.swift", "Corpus.swift"]},
        **{f"Tests/IlliquidCoreTests/{name}": ROOT / "Tests/IlliquidCoreTests" / name for name in TESTS},
    }
    hashes = {}
    for destination, source in mapping.items():
        path = package / destination
        path.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        path.write_bytes(data)
        hashes[destination] = {"source": str(source.relative_to(ROOT)), "sha256": digest(data)}
    (package / "Package.swift").write_text(PACKAGE)
    hashes["Package.swift"] = {"source": "generated", "sha256": digest(PACKAGE.encode())}
    write_json(output / f"{variant}-sources.json", hashes)
    return package, hashes


def verify(package: Path, hashes: dict) -> None:
    for name, expected in hashes.items():
        if digest((package / name).read_bytes()) != expected["sha256"]:
            raise RuntimeError(f"Staged source changed: {package / name}")


def metric_summary(selected: list[dict], field: str) -> dict:
    by_variant = {
        variant: [row[field] / row["operations"] for row in selected if row["variant"] == variant]
        for variant in VARIANTS
    }
    pairs = []
    for pair in sorted({row["pair"] for row in selected}):
        values = {row["variant"]: row[field] / row["operations"]
                  for row in selected if row["pair"] == pair}
        pairs.append(100 * (1 - values["candidate"] / values["baseline"]))
    medians = {variant: statistics.median(values) for variant, values in by_variant.items()}
    return {
        "ns_per_filename": {variant: {"median": medians[variant], "min": min(values), "max": max(values)}
                            for variant, values in by_variant.items()},
        "reduction_from_separate_medians_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
        "paired_reduction_percent": {"median": statistics.median(pairs), "min": min(pairs), "max": max(pairs)},
        "candidate_faster_pairs": sum(value > 0 for value in pairs),
    }


def summary(rows: list[dict], cases: list[dict]) -> dict:
    summaries = []
    for case in cases:
        selected = [row for row in rows if row["case"] == case["name"]]
        record = {
            "case": case["name"], "filenames_per_batch": case["count"],
            "iterations": selected[0]["iterations"], "pairs": len({row["pair"] for row in selected}),
            **metric_summary(selected, "elapsed_ns"),
        }
        if all("cpu_ns" in row for row in selected):
            record["process_cpu"] = metric_summary(selected, "cpu_ns")
        summaries.append(record)
    return {"measurements": len(rows), "cases": summaries}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new or empty output directory")
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=750)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs > 30 or args.pairs % 2:
        parser.error("pairs must be an even number from 2 to 30")
    if not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 2000:
        parser.error("target-ms must be from 10 to 2000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output must be new or empty; existing evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               CLANG_MODULE_CACHE_PATH=str(output / "module-cache"))
    retained = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline_data = (HERE / "baseline/MediaNameRecognition.swift").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(baseline_data)).encode() + b"\0" + baseline_data).hexdigest()
    if retained["revision"] != BASELINE or digest(baseline_data) != retained["sha256"] or blob != retained["git_blob"]:
        raise RuntimeError("Frozen baseline does not match its manifest")
    manifest = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(), "logical_cpus": os.cpu_count(),
        "python": sys.version, "swift": execute([args.swift, "--version"], output, env).strip(),
        "head": execute(["git", "rev-parse", "HEAD"], output, env).strip(),
        "working_tree_status": execute(["git", "status", "--short"], output, env),
        "locale": execute(["locale"], output, env).strip(),
        "baseline": retained, "pairs": args.pairs, "target_ms": args.target_ms,
        "timing": "DispatchTime.uptimeNanoseconds and CLOCK_PROCESS_CPUTIME_ID; warmed in-memory recognition and bounded batch result handling",
        "ordering": "Rotate case order per pair; alternate baseline/candidate process order per case and pair",
        "calibration": "One fresh process per variant/case at one batch; slower calibration selects equal iterations; excluded from summary",
        "driver_sources": {name: digest((HERE / name).read_bytes()) for name in ["run.py", "Driver.swift", "Corpus.swift"]},
    }
    if platform.system() == "Darwin":
        manifest["hardware"] = execute(["sysctl", "-n", "machdep.cpu.brand_string", "hw.model", "hw.memsize"], output, env).strip()
        manifest["xcode"] = execute(["xcodebuild", "-version"], output, env).strip()
    write_json(output / "manifest.json", manifest)
    packages, hashes, binaries = {}, {}, {}
    for variant in VARIANTS:
        packages[variant], hashes[variant] = prepare(output, variant)

    def swift_command(variant: str, action: str, configuration: str) -> list:
        return [args.swift, action, "--package-path", packages[variant],
                "--scratch-path", output / "build" / variant,
                "--cache-path", output / "swiftpm-cache", "--config-path", output / "swiftpm-config",
                "--security-path", output / "swiftpm-security", "--configuration", configuration,
                "--jobs", "1", "-Xswiftc", "-warnings-as-errors"]

    for variant in VARIANTS:
        for configuration in ["debug", "release"]:
            print(f"Testing {variant} in {configuration}", flush=True)
            execute(swift_command(variant, "test", configuration) + ["--no-parallel"], output, env,
                    f"tests-{variant}-{configuration}.txt")
            verify(packages[variant], hashes[variant])
    write_json(output / "tests.json", {"passed": True, "variants": VARIANTS,
                                      "configurations": ["debug", "release"], "files": TESTS})
    if args.tests_only:
        return
    for variant in VARIANTS:
        command = swift_command(variant, "build", "release")
        execute(command + ["--product", "RecognitionBenchmark"], output, env, f"build-{variant}.txt")
        directory = execute(command + ["--show-bin-path"], output, env).strip()
        binaries[variant] = Path(directory) / "RecognitionBenchmark"
    manifest["binary_sha256"] = {variant: digest(binary.read_bytes()) for variant, binary in binaries.items()}
    write_json(output / "manifest.json", manifest)
    cases = json.loads(execute([binaries["baseline"], "--list"], output, env))
    if cases != json.loads(execute([binaries["candidate"], "--list"], output, env)):
        raise RuntimeError("Workload definitions differ")
    write_json(output / "cases.json", cases)

    differential = {}
    for variant in VARIANTS:
        raw = execute([binaries[variant], "--differential"], output, env)
        (output / f"differential-{variant}.json.gz").write_bytes(gzip.compress(raw.encode(), mtime=0))
        differential[variant] = json.loads(raw)
    if differential["baseline"] != differential["candidate"]:
        differences = [{"baseline": before, "candidate": after}
                       for before, after in zip(differential["baseline"], differential["candidate"])
                       if before != after]
        write_json(output / "differences.json", {"baseline_count": len(differential["baseline"]),
                    "candidate_count": len(differential["candidate"]), "differences": differences})
        raise RuntimeError("Complete recognition outputs differ")
    write_json(output / "differential.json", {"passed": True, "cases": len(differential["baseline"]),
        "comparison": "Every input and complete stored/derived result field; explicit null optionals",
        "archives": {variant: digest((output / f"differential-{variant}.json.gz").read_bytes()) for variant in VARIANTS}})
    print(f"Exact output parity: {len(differential['baseline'])} paths", flush=True)

    rows, expected, iterations = [], {}, {}

    def measure(variant: str, case: dict, count: int) -> dict:
        row = json.loads(execute([binaries[variant], "--case", case["name"], "--iterations", count], output, env))
        if (row["case"] != case["name"] or row["iterations"] != count
                or row["operations"] != count * case["count"]
                or type(row["elapsed_ns"]) is not int or row["elapsed_ns"] <= 0
                or type(row["cpu_ns"]) is not int or row["cpu_ns"] <= 0):
            raise RuntimeError(f"Invalid benchmark record: {row}")
        key = (case["name"], count)
        checksums = (row["checksum"], row["semantic_checksum"])
        if key in expected and expected[key] != checksums:
            raise RuntimeError(f"Timed workload output differs: {case['name']}")
        expected[key] = checksums
        return row

    for case in cases:
        pilots = []
        for variant in VARIANTS:
            row = measure(variant, case, 1)
            row["variant"] = variant
            pilots.append(row)
            with (output / "calibration.jsonl").open("a") as log:
                log.write(json.dumps(row, sort_keys=True) + "\n")
        iterations[case["name"]] = max(1, min(2000, math.ceil(args.target_ms * 1e6 / max(row["elapsed_ns"] for row in pilots))))
    write_json(output / "iterations.json", iterations)
    for pair in range(args.pairs):
        offset = pair % len(cases)
        for case in cases[offset:] + cases[:offset]:
            index = cases.index(case)
            order = VARIANTS if (pair + index) % 2 == 0 else list(reversed(VARIANTS))
            for position, variant in enumerate(order):
                row = measure(variant, case, iterations[case["name"]])
                row.update(variant=variant, pair=pair, position=position)
                rows.append(row)
                with (output / "measurements.jsonl").open("a") as log:
                    log.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)
    for variant in VARIANTS:
        verify(packages[variant], hashes[variant])
        if digest(binaries[variant].read_bytes()) != manifest["binary_sha256"][variant]:
            raise RuntimeError(f"Binary changed: {variant}")
    results = summary(rows, cases)
    write_json(output / "summary.json", results)
    print(json.dumps(results, indent=2), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAILED: {error}", file=sys.stderr, flush=True)
        raise
