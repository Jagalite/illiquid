#!/usr/bin/env python3
"""Qualify the common timestamp fast path against an immutable production baseline.

All production sources are compiled whole. The four isolated test builds share
the candidate's golden tests. Debug and release differential runs compare full
UTF-8 output/errors; only release binaries are timed, in fresh AB/BA processes.
Run serially on an idle macOS host, through Kyoto when it is available.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE = "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
TESTS = ["ExternalTextSubtitleConverterTests.swift", "ExternalSubtitleEscapingTests.swift"]
CASES = [
    "srt-1-plain", "vtt-1-plain", "srt-100-plain", "vtt-100-plain",
    "srt-2000-plain", "vtt-2000-plain", "srt-10000-plain", "vtt-10000-plain",
    "srt-2000-multilingual", "vtt-2000-multilingual",
    "srt-2000-escaped", "vtt-2000-escaped",
    "srt-100-plain-crlf", "vtt-100-multilingual-crlf",
    "timestamp-control-srt-2000-wide-hours", "timestamp-control-vtt-2000-wide-hours",
    "timestamp-control-vtt-2000-unicode-settings",
    "timestamp-control-srt-2000-malformed", "timestamp-control-vtt-2000-malformed",
]


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=350)
    args = parser.parse_args()
    output = args.output.resolve()
    if platform.system() != "Darwin":
        parser.error("Native macOS Foundation is required for this qualification")
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    commands = []

    def run(command, log):
        argv = [str(item) for item in command]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=900)
        log.write_text(result.stdout + result.stderr)
        commands.append({"argv": argv, "returncode": result.returncode,
                         "seconds": time.monotonic() - started,
                         "log": str(log.relative_to(output)),
                         "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        write(output / "commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{(result.stdout + result.stderr)[-6000:]}")
        return result.stdout

    revision = run(["git", "rev-parse", "--verify", args.baseline_ref + "^{commit}"],
                   output / "baseline-ref.log").strip()
    baseline = subprocess.check_output(["git", "show", revision + ":" + SOURCE], cwd=ROOT)
    candidate = (ROOT / SOURCE).read_bytes()
    if baseline == candidate:
        raise RuntimeError("Baseline and candidate production sources are identical")
    environment = {
        "baseline_revision": revision,
        "candidate_revision": run(["git", "rev-parse", "HEAD"], output / "head.log").strip(),
        "working_tree_status": run(["git", "status", "--short"], output / "status.log"),
        "sw_vers": run(["sw_vers"], output / "sw-vers.log").strip(),
        "hardware": run(["sysctl", "-n", "machdep.cpu.brand_string"], output / "hardware.log").strip(),
        "swift": run(["swift", "--version"], output / "swift-version.log").strip(),
        "architecture": platform.machine(), "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "image_os": os.environ.get("ImageOS"), "image_version": os.environ.get("ImageVersion"),
        "workflow_run": os.environ.get("GITHUB_RUN_ID"), "runner_arch": os.environ.get("RUNNER_ARCH"),
        "production_sha256": {variant: hashlib.sha256(data).hexdigest()
                              for variant, data in [("baseline", baseline), ("candidate", candidate)]},
        "test_sha256": {name: hashlib.sha256(
            (ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes()).hexdigest() for name in TESTS},
    }
    write(output / "environment.json", environment)
    tested = []
    for configuration in ["debug", "release"]:
        for variant, source in [("baseline", baseline), ("candidate", candidate)]:
            package = output / "tests" / f"{variant}-{configuration}"
            sources = package / "Sources/IlliquidNativePlayback"
            tests = package / "Tests/IlliquidNativePlaybackTests"
            sources.mkdir(parents=True)
            tests.mkdir(parents=True)
            (sources / "ExternalTextSubtitleConverter.swift").write_bytes(source)
            for name in TESTS:
                shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / name, tests / name)
            (package / "Package.swift").write_text(
                '// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "SubtitleTimestampRegressions", targets: [\n'
                '    .target(name: "IlliquidNativePlayback"),\n'
                '    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])\n'
                '])\n')
            log = output / f"tests-{variant}-{configuration}.log"
            run(["swift", "test", "--package-path", package, "-c", configuration,
                 "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"], log)
            tested.append({"variant": variant, "configuration": configuration, "passed": True,
                           "log": log.name})
            write(output / "tests.json", tested)
            print(f"PASS golden regressions: {variant}/{configuration}", flush=True)

    benchmark = ROOT / "Benchmarks/ExternalSubtitleConversion/run.py"
    common = ["--baseline-ref", revision, "--swiftc", shutil.which("swiftc") or "swiftc"]
    run([sys.executable, benchmark, "verify", *common, "--configuration", "debug",
         "--output", output / "debug"], output / "differential-debug.log")
    print("PASS complete debug differential", flush=True)
    timing_command = [sys.executable, benchmark, "benchmark", *common, "--output", output / "release",
                      "--rounds", args.pairs, "--target-ms", args.target_ms]
    for case in CASES:
        timing_command += ["--case", case]
    run(timing_command, output / "benchmark-release.log")
    debug = json.loads((output / "debug/verification.json").read_text())
    release = json.loads((output / "release/verification.json").read_text())
    if debug != release:
        raise RuntimeError("Debug and release verification records differ")
    observations = [json.loads(row) for row in
                    (output / "release/measurements.jsonl").read_text().splitlines()]
    completion = {"complete": True, "golden_test_runs": len(tested),
                  "differential_cases_per_build": len(release),
                  "differential_builds": 4, "timed_cases": len(CASES), "pairs": args.pairs,
                  "observations": len(observations),
                  "minimum_sample_ms": min(row["elapsed_ns"] for row in observations) / 1_000_000}
    write(output / "completion.json", completion)
    print(json.dumps(completion, sort_keys=True), flush=True)
    print((output / "benchmark-release.log").read_text()[-6000:], flush=True)


if __name__ == "__main__":
    main()
