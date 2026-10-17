#!/usr/bin/env python3
"""Test and benchmark the exact media-name recognizer against a pinned baseline.

Requires Swift 6.1+ (including Swift Testing) and Python 3.10+. No dependencies,
file discovery, metadata I/O, UI, or decoding are included in the timed region.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = Path("Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift")
TESTS = ["MediaNameRecognitionTests.swift", "MediaNameRecognitionPerformanceTests.swift"]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args: list[str | Path], output: Path, label: str, timeout: int = 300) -> bytes:
    argv = [str(arg) for arg in args]
    started = time.time()
    process = subprocess.run(argv, capture_output=True, timeout=timeout)
    (output / f"{label}.stdout").write_bytes(process.stdout)
    (output / f"{label}.stderr").write_bytes(process.stderr)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": argv, "label": label, "returncode": process.returncode,
                                 "started_unix_seconds": started,
                                 "elapsed_seconds": time.time() - started,
                                 "stdout_sha256": sha256(process.stdout),
                                 "stderr_sha256": sha256(process.stderr)}) + "\n")
    if process.returncode:
        raise RuntimeError(f"{label} failed ({process.returncode})\n{process.stderr.decode(errors='replace')}"
                           f"\n{process.stdout.decode(errors='replace')}")
    return process.stdout


def prepare(output: Path, configuration: dict[str, object]) -> dict[str, Path]:
    baseline = (HERE / "baseline/MediaNameRecognition.swift").read_bytes()
    pin = json.loads((HERE / "baseline/manifest.json").read_text())
    if sha256(baseline) != pin["sha256"]:
        raise RuntimeError("Frozen baseline differs from its pinned source digest")
    inputs = output / "inputs"
    inputs.mkdir()
    sources = {"baseline": baseline, "candidate": (ROOT / SOURCE).read_bytes()}
    paths = {}
    for variant, data in sources.items():
        path = inputs / variant / "MediaNameRecognition.swift"
        path.parent.mkdir()
        path.write_bytes(data)
        paths[variant] = path
    for name in ["Driver.swift", "Corpus.swift", "run.py"]:
        shutil.copyfile(HERE / name, inputs / name)
    for name in TESTS:
        shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name, inputs / name)
    manifest = {
        "baseline": pin,
        "source_sha256": {variant: sha256(data) for variant, data in sources.items()},
        "input_sha256": {str(path.relative_to(inputs)): sha256(path.read_bytes())
                         for path in sorted(inputs.rglob("*")) if path.is_file()},
        "git_head": command(["git", "-C", ROOT, "rev-parse", "HEAD"], output, "git-head").decode().strip(),
        "git_status": command(["git", "-C", ROOT, "status", "--porcelain"], output, "git-status").decode(),
        "system": platform.platform(), "architecture": platform.machine(),
        "python": platform.python_version(),
        "swift": command(["swiftc", "--version"], output, "swift-version").decode().strip(),
        "compile_flags": ["-swift-version", "6", "-O"],
        "configuration": configuration,
        "method": "Identical driver and corpus; two untimed warmup traversals per fresh process; "
                  "balanced AB/BA pairs; baseline-calibrated equal traversal counts; complete recognizer "
                  "plus lightweight result consumption and per-traversal macOS autoreleasepool. "
                  "Synthetic warm component workloads, not filesystem/UI/playback measurements.",
    }
    if platform.system() == "Darwin":
        manifest["host"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], output, "cpu").decode().strip()
        manifest["os"] = command(["sw_vers"], output, "os").decode().strip()
    else:
        manifest["host"] = platform.processor()
    write_json(output / "manifest.json", manifest)
    return paths


def test_sources(output: Path, sources: dict[str, Path]) -> None:
    for variant, source in sources.items():
        package = output / "build" / f"tests-{variant}"
        module = package / "Sources/IlliquidCore"
        tests = package / "Tests/IlliquidCoreTests"
        module.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(source, module / source.name)
        for name in TESTS:
            shutil.copyfile(output / "inputs" / name, tests / name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RecognitionTests", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
        for configuration in ["debug", "release"]:
            command(["swift", "test", "--package-path", package, "--configuration", configuration,
                     "--no-parallel"], output, f"tests-{variant}-{configuration}", timeout=600)
            print(f"Passed {variant} {configuration} recognition tests", flush=True)


def benchmark(output: Path, sources: dict[str, Path], pairs: int, target_ms: int) -> None:
    executables = {}
    build = output / "build"
    build.mkdir(exist_ok=True)
    for variant, source in sources.items():
        executable = build / variant
        command(["swiftc", "-swift-version", "6", "-O", source,
                 output / "inputs/Corpus.swift", output / "inputs/Driver.swift", "-o", executable],
                output, f"compile-{variant}")
        executables[variant] = executable
    manifest = json.loads((output / "manifest.json").read_text())
    manifest["executable_sha256"] = {variant: sha256(path.read_bytes())
                                     for variant, path in executables.items()}
    write_json(output / "manifest.json", manifest)
    receipts = {}
    for variant, executable in executables.items():
        receipts[variant] = command([executable, "dump"], output, f"receipts-{variant}")
    if receipts["baseline"] != receipts["candidate"]:
        a, b = json.loads(receipts["baseline"]), json.loads(receipts["candidate"])
        mismatches = [{"index": i, "baseline": x, "candidate": y}
                      for i, (x, y) in enumerate(zip(a, b)) if x != y]
        write_json(output / "parity-failure.json", {"baseline_count": len(a), "candidate_count": len(b),
                                                    "mismatches": mismatches[:20]})
        raise RuntimeError("Exact UTF-8 result parity failed; see parity-failure.json")
    write_json(output / "parity.json", {"equal": True, "paths": len(json.loads(receipts["baseline"])),
                                       "receipt_sha256": sha256(receipts["baseline"]),
                                       "scope": "All stored fields and seriesTitle/displayName/section, exact UTF-8"})

    # The same Swift corpus provides the workload names to prevent a stale Python list.
    cases = json.loads(command([executables["baseline"], "cases"], output, "cases"))
    rows = []
    summaries = {}
    for case in cases:
        calibration = json.loads(command([executables["baseline"], "measure", case, "1"],
                                         output, f"calibration-{case}"))
        elapsed = calibration["elapsed_nanoseconds"]
        passes = max(1, min(100_000, math.ceil(target_ms * 1_000_000 / max(elapsed, 1))))
        checksums = {}
        times = {"baseline": [], "candidate": []}
        for pair in range(pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for position, variant in enumerate(order):
                label = f"measure-{case}-{pair}-{variant}"
                row = json.loads(command([executables[variant], "measure", case, str(passes)], output, label))
                if row["workload"] != case or row["passes"] != passes or row["recognitions"] != row["paths"] * passes:
                    raise RuntimeError(f"Invalid measurement metadata: {label}")
                if row["elapsed_nanoseconds"] <= 0 or row["paths"] <= 0:
                    raise RuntimeError(f"Invalid timing/count: {label}")
                receipt = (row["checksum"], row["warmup_checksum"], row["recognitions"])
                if checksums and receipt != next(iter(checksums.values())):
                    raise RuntimeError(f"Benchmark checksum mismatch: {label}")
                checksums[variant] = receipt
                row.update(variant=variant, pair=pair, position=position)
                rows.append(row)
                times[variant].append(row["elapsed_nanoseconds"] / row["recognitions"])
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
        medians = {variant: statistics.median(values) for variant, values in times.items()}
        reductions = [(1 - candidate / baseline) * 100
                      for baseline, candidate in zip(times["baseline"], times["candidate"])]
        summary = {
            "paths_per_traversal": calibration["paths"], "passes": passes, "pairs": pairs,
            "median_ns_per_recognition": medians,
            "reduction_percent": (1 - medians["candidate"] / medians["baseline"]) * 100,
            "pair_reduction_percent": reductions,
            "range_ns_per_recognition": {variant: [min(values), max(values)] for variant, values in times.items()},
        }
        summaries[case] = summary
        write_json(output / "summary.json", summaries)
        print(f"{case}: {medians['baseline'] / 1000:.2f} -> {medians['candidate'] / 1000:.2f} us/name; "
              f"{summary['reduction_percent']:.1f}% reduction", flush=True)
    write_json(output / "measurement-checks.json", {"records": len(rows), "matching_pair_checksums": True,
                                                   "pairs": pairs, "target_ms": target_ms})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New, nonexisting evidence directory")
    parser.add_argument("--mode", choices=["all", "test", "benchmark"], default="all")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=int, default=200)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be a positive even number of at least 2")
    if args.target_ms <= 0:
        parser.error("--target-ms must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    try:
        sources = prepare(output, {"mode": args.mode, "pairs": args.pairs, "target_ms": args.target_ms})
        if args.mode in ["all", "test"]:
            test_sources(output, sources)
        if args.mode in ["all", "benchmark"]:
            benchmark(output, sources, args.pairs, args.target_ms)
        write_json(output / "result.json", {"success": True, "mode": args.mode})
    except Exception as error:
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
