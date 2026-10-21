#!/usr/bin/env python3
"""Compare the actual source-preparation executor with a pinned baseline.

Builds complete unmodified production files, runs the same contract tests on
both implementations, then measures separate optimized executables in balanced
AB/BA pairs. Requires Swift 6.1+ and Python 3. No external packages or media.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "a2de305c8dbcaa81aac1477df7c9a0017c14eae3"
SOURCE = "Sources/IlliquidCore/Utilities/SourcePreparationExecutor.swift"
TEST = "Tests/IlliquidCoreTests/SourcePreparationExecutorTests.swift"
SCENARIOS = [
    "interactive-single", "background-single",
    "burst-8-empty", "burst-32-empty", "burst-64-empty",
    "burst-8-100us", "burst-32-100us", "burst-64-100us",
    "burst-32-1ms", "burst-64-1ms",
    "burst-32-directory", "burst-64-directory",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def selected_tool(name: str) -> str | None:
    if configured := os.environ.get(name.upper()):
        return configured
    if sys.platform == "darwin":
        return subprocess.check_output(["xcrun", "--find", name], text=True).strip()
    return shutil.which(name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "test", "benchmark"], default="all")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--stress-repetitions", type=int, default=0,
                        help="Repeat the cancellation/handoff test in fresh processes per implementation and configuration")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=selected_tool("swift"))
    parser.add_argument("--swiftc", default=selected_tool("swiftc"))
    parser.add_argument("--scenario", choices=SCENARIOS, action="append")
    args = parser.parse_args()
    if not args.swiftc or (args.mode != "benchmark" and not args.swift):
        parser.error("Swift is required; set SWIFT/SWIFTC or select --swift/--swiftc")
    if not 2 <= args.pairs <= 30:
        parser.error("pairs must be 2...30")
    if not 0 <= args.stress_repetitions <= 1000:
        parser.error("stress-repetitions must be 0...1000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update(
        CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
        SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
        TERM="dumb", NO_COLOR="1",
    )

    def run(command: list[str | Path], log: Path | None = None, timeout: int = 300) -> str:
        argv = [str(value) for value in command]
        start = time.time()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=environment, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            if log:
                log.write_bytes((error.stdout or b"") + (error.stderr or b""))
            raise
        stdout = result.stdout.decode("utf-8", errors="strict")
        stderr = result.stderr.decode("utf-8", errors="replace")
        if log:
            log.write_text(stdout + stderr)
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "exit_code": result.returncode,
                                     "elapsed_seconds": time.time() - start,
                                     "log": str(log) if log else None}) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n{stdout[-5000:]}\n{stderr[-5000:]}")
        return stdout

    baseline = run(["git", "rev-parse", "--verify", args.baseline + "^{commit}"]).strip()
    receipt = {
        "baseline_commit": baseline,
        "candidate_head": run(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree": run(["git", "status", "--short"]),
        "platform": platform.platform(), "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "compiler": run([args.swiftc, "--version"]).strip(),
        "swiftc": args.swiftc, "swift": args.swift,
        "developer_dir": environment.get("DEVELOPER_DIR"),
        "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "tests_sha256": digest((ROOT / TEST).read_bytes()),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sources": {}, "pairs": args.pairs, "stress_repetitions": args.stress_repetitions,
        "scope": "Executor admission plus stated synthetic or warm directory work; not whole-player CPU or input latency",
    }
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-parse-as-library",
             "-warnings-as-errors", "-module-cache-path", str(output / "module-cache")]
    if sys.platform == "darwin":
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
        receipt["os_version"] = run(["sw_vers"]).strip()
        receipt["hardware"] = run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
    receipt["compiler_flags"] = flags
    binaries: dict[str, Path] = {}
    for variant in ["baseline", "candidate"]:
        folder = output / variant
        folder.mkdir()
        data = (run(["git", "show", f"{baseline}:{SOURCE}"]).encode("utf-8")
                if variant == "baseline" else (ROOT / SOURCE).read_bytes())
        source = folder / "SourcePreparationExecutor.swift"
        source.write_bytes(data)
        receipt["sources"][variant] = {"production_sha256": digest(data)}
        write_json(output / "receipt.json", receipt)
        if args.mode in {"all", "test"}:
            package = folder / "tests"
            target = package / "Sources/IlliquidCore"
            tests = package / "Tests/IlliquidCoreTests"
            target.mkdir(parents=True)
            tests.mkdir(parents=True)
            (target / source.name).write_bytes(data)
            shutil.copyfile(ROOT / TEST, tests / Path(TEST).name)
            (package / "Package.swift").write_text(
                '// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "SourcePreparationContract", platforms: [.macOS("26.0")], '
                'targets: [.target(name: "IlliquidCore"), '
                '.testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])], '
                'swiftLanguageModes: [.v6])\n'
            )
            for configuration in ["debug", "release"]:
                print(f"Testing {variant} ({configuration})", flush=True)
                command = [args.swift, "test", "--package-path", package, "--configuration", configuration,
                           "--jobs", "2", "--cache-path", output / "swiftpm-cache",
                           "--config-path", output / "swiftpm-config", "--security-path", output / "swiftpm-security",
                           "-Xswiftc", "-warnings-as-errors"]
                if sys.platform == "linux":
                    command += ["--use-integrated-swift-driver"]
                log = folder / f"tests-{configuration}.log"
                result = run(command, log)
                receipt["sources"][variant][f"tests_{configuration}_log_sha256"] = digest(log.read_bytes())
                # Keep the actual Swift Testing completion receipt in the summary.
                receipt["sources"][variant][f"tests_{configuration}"] = [
                    line for line in result.splitlines() if "tests passed" in line or "Test run with" in line
                ][-2:]
                if args.stress_repetitions:
                    bin_path = Path(run([args.swift, "build", "--package-path", package,
                                         "--configuration", configuration, "--show-bin-path"]).strip())
                    executable = bin_path / "SourcePreparationContractPackageTests.xctest"
                    if sys.platform == "darwin":
                        executable /= "Contents/MacOS/SourcePreparationContractPackageTests"
                    stress_log = folder / f"stress-{configuration}.log"
                    stress_rows = []
                    for repetition in range(args.stress_repetitions):
                        result = run([executable, "--testing-library", "swift-testing", "--filter",
                                      "cancellationRacingWithHandoffNeitherDuplicatesWorkNorLeaksCapacity"],
                                     stress_log, timeout=30)
                        if not re.search(r"Test run with 1 test(?: in 1 suite)? passed", stress_log.read_text()):
                            raise RuntimeError(f"Stress filter did not execute exactly one test: {stress_log}")
                        stress_rows.append({"process": repetition + 1, "handoffs": 32, "passed": True})
                    write_json(folder / f"stress-{configuration}.json", stress_rows)
                    receipt["sources"][variant][f"stress_{configuration}"] = {
                        "processes": args.stress_repetitions, "handoffs_per_process": 32,
                        "all_passed": True,
                    }
                    print(f"Passed {args.stress_repetitions} cancellation stress processes: "
                          f"{variant} ({configuration})", flush=True)
        if args.mode in {"all", "benchmark"}:
            binary = folder / "benchmark"
            run([args.swiftc, *flags, source, HERE / "Harness.swift", "-o", binary], folder / "build.log")
            binaries[variant] = binary
            receipt["sources"][variant]["binary_sha256"] = digest(binary.read_bytes())
        write_json(output / "receipt.json", receipt)
    # Source files can be edited during a local run. Refuse to publish timings
    # under receipts that no longer describe the compiled inputs.
    for path, key in [(HERE / "Harness.swift", "harness_sha256"),
                      (Path(__file__), "runner_sha256"), (ROOT / TEST, "tests_sha256")]:
        if digest(path.read_bytes()) != receipt[key]:
            raise RuntimeError(f"Input changed during preparation: {path}")
    if digest((ROOT / SOURCE).read_bytes()) != receipt["sources"]["candidate"]["production_sha256"]:
        raise RuntimeError("Candidate changed during preparation; rerun with a fresh output directory")
    if not binaries:
        return

    fixture = output / "fixture"
    for index in range(64):
        directory = fixture / f"directory-{index}"
        directory.mkdir(parents=True)
        for entry in range(16):
            (directory / f"Episode-{entry}.mkv").write_bytes(b"fixture\n")
    scenarios = args.scenario or SCENARIOS
    rows = []
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        # Reverse scenario order on alternate pairs to spread host drift.
        for scenario in scenarios if pair % 2 == 0 else list(reversed(scenarios)):
            pair_rows = []
            for variant in order:
                row = json.loads(run([binaries[variant], scenario, fixture], timeout=120))
                row.update(pair=pair, variant=variant)
                rows.append(row)
                pair_rows.append(row)
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            for key in ["scenario", "requestsPerBurst", "bursts", "completedRequests", "checksum"]:
                if pair_rows[0][key] != pair_rows[1][key]:
                    raise RuntimeError(f"Behavioral receipt mismatch for {scenario}: {key}")
        print(f"Completed timing pair {pair + 1}/{args.pairs}", flush=True)

    summary = {"pairs": args.pairs, "measurements": len(rows), "scenarios": {}}
    for scenario in scenarios:
        relevant = [row for row in rows if row["scenario"] == scenario]
        item: dict = {"requests_per_burst": relevant[0]["requestsPerBurst"]}
        for field, label in [("wallNanoseconds", "wall"), ("processCPUNanoseconds", "cpu")]:
            baseline_values = [row[field] / row["bursts"] / 1_000_000 for row in relevant if row["variant"] == "baseline"]
            candidate_values = [row[field] / row["bursts"] / 1_000_000 for row in relevant if row["variant"] == "candidate"]
            paired_changes = []
            for pair in range(args.pairs):
                pair_rows = {row["variant"]: row for row in relevant if row["pair"] == pair}
                paired_changes.append((1 - pair_rows["candidate"][field] / pair_rows["baseline"][field]) * 100)
            item[label] = {
                "baseline_median_ms_per_burst": statistics.median(baseline_values),
                "candidate_median_ms_per_burst": statistics.median(candidate_values),
                "paired_reduction_percent_median": statistics.median(paired_changes),
                "paired_reduction_percent_min": min(paired_changes),
                "paired_reduction_percent_max": max(paired_changes),
            }
        summary["scenarios"][scenario] = item
    write_json(output / "summary.json", summary)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
