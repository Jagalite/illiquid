#!/usr/bin/env python3
"""Qualify exact subtitle/playlist sources and compare complete model operations."""
from __future__ import annotations

import argparse
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
ROOT = HERE.parents[1]
PIN = "68274d1b09dcc866296321a5a8858efc297c4f19"
VARIANTS = ("baseline", "candidate")
CALIBRATION_MIN_NS = 5_000_000
TEST_FILES = (
    "ExternalSubtitleMatcherTests.swift", "FolderPlaylistDiscoveryTests.swift",
    "FolderDiscoveryFilesystemRegressionTests.swift", "TestSupport/TemporaryDirectory.swift",
)
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "EmptySubtitleAssociationQualification",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fingerprint(data: bytes) -> dict:
    return {"sha256": digest(data),
            "git_blob": hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest(),
            "bytes": len(data)}


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False).encode() + b"\n"
    with temporary.open("wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    if path.read_bytes() != data or json.loads(path.read_bytes()) != value:
        raise RuntimeError(f"JSON readback failed: {path}")


def append_json(path: Path, value: object) -> None:
    with path.open("ab") as stream:
        stream.write(canonical(value) + b"\n")
        stream.flush()
        os.fsync(stream.fileno())


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.env = os.environ.copy()
        cache = output / "module-cache"
        cache.mkdir()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
        self.sequence = 0

    def execute(self, command: list, label: str, *, timeout: int = 900, compact_result: bool = False) -> bytes:
        command = [str(item) for item in command]
        prefix = f"{self.sequence:04d}-{label}"
        self.sequence += 1
        logs = self.output / "logs"
        logs.mkdir(exist_ok=True)
        stdout_path, stderr_path = logs / (prefix + ".stdout.log"), logs / (prefix + ".stderr.log")
        started = time.monotonic()
        try:
            result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, timeout=timeout)
            stdout, stderr, code = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr, code = error.stdout or b"", error.stderr or b"", "timeout"
        # The caller compares the complete decoded result in memory before a
        # sample is accepted. Keep one complete canonical receipt per workload,
        # while repeated subprocess logs retain every scalar and a result hash.
        logged_stdout = stdout
        if compact_result and code == 0:
            logged = json.loads(stdout)
            logged["result_sha256"] = digest(canonical(logged.pop("result")))
            logged_stdout = canonical(logged) + b"\n"
        stdout_path.write_bytes(logged_stdout)
        stderr_path.write_bytes(stderr)
        append_json(self.output / "commands.jsonl", {
            "sequence": self.sequence - 1, "label": label, "command": command,
            "returncode": code, "elapsed_seconds": time.monotonic() - started,
            "stdout_path": str(stdout_path.relative_to(self.output)), "stdout_sha256": digest(logged_stdout),
            "original_stdout_sha256": digest(stdout), "full_result_replaced_with_hash": compact_result and code == 0,
            "stderr_path": str(stderr_path.relative_to(self.output)), "stderr_sha256": digest(stderr),
        })
        if code != 0:
            raise RuntimeError(f"{label} failed ({code}); see {stdout_path} and {stderr_path}\n"
                               + stderr.decode(errors="replace")[-4000:])
        return stdout


def checked_baseline() -> dict:
    manifest = json.loads((HERE / "baseline/manifest.json").read_bytes())
    if manifest["revision"] != PIN or len(manifest["files"]) != 7:
        raise RuntimeError("Unexpected baseline source manifest")
    for name, expected in manifest["files"].items():
        actual = fingerprint((HERE / "baseline" / name).read_bytes())
        if any(actual[key] != expected[key] for key in ("sha256", "git_blob")):
            raise RuntimeError(f"Frozen baseline source changed: {name}")
    return manifest


def stage_sources(output: Path, variant: str, baseline: dict, *, tests: bool) -> tuple[Path, dict]:
    directory = output / "packages" / variant
    manifest = {"variant": variant, "baseline_revision": PIN, "files": {},
                "shared_source_policy": "Current six helpers are identical across both variants; baseline matcher is frozen"}
    for name, entry in baseline["files"].items():
        origin = (HERE / "baseline" / name if variant == "baseline" and name == "ExternalSubtitleMatcher.swift"
                  else ROOT / entry["repository_path"])
        data = origin.read_bytes()
        relative = Path("Sources/IlliquidCore") / name
        destination = directory / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        manifest["files"][str(relative)] = {"origin": str(origin.relative_to(ROOT)), **fingerprint(data),
                                            "matches_frozen_baseline": digest(data) == entry["sha256"]}
    if tests:
        for name in TEST_FILES:
            origin = ROOT / "Tests/IlliquidCoreTests" / name
            data = origin.read_bytes()
            relative = Path("Tests/IlliquidCoreTests") / name
            destination = directory / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            manifest["files"][str(relative)] = {"origin": str(origin.relative_to(ROOT)), **fingerprint(data)}
        (directory / "Package.swift").write_text(PACKAGE)
        manifest["files"]["Package.swift"] = fingerprint(PACKAGE.encode())
    else:
        data = (HERE / "Harness.swift").read_bytes()
        (directory / "Harness.swift").write_bytes(data)
        manifest["files"]["Harness.swift"] = {"origin": str((HERE / "Harness.swift").relative_to(ROOT)), **fingerprint(data)}
    write_json(output / f"{variant}-sources.json", manifest)
    return directory, manifest


def check_staged(directory: Path, manifest: dict) -> None:
    for relative, expected in manifest["files"].items():
        if digest((directory / relative).read_bytes()) != expected["sha256"]:
            raise RuntimeError(f"Staged bytes changed during execution: {directory / relative}")


def check_shared_sources(manifests: dict, baseline: dict) -> None:
    for name in baseline["files"]:
        if name == "ExternalSubtitleMatcher.swift":
            continue
        relative = f"Sources/IlliquidCore/{name}"
        if manifests["baseline"]["files"][relative]["sha256"] != manifests["candidate"]["files"][relative]["sha256"]:
            raise RuntimeError(f"Shared source bytes differ across variants: {name}")
    for manifest in manifests.values():
        manifest["shared_source_equality_verified"] = True


def environment(runner: Runner, args: argparse.Namespace) -> tuple[dict, list[str], list[str]]:
    swiftc = [args.swiftc] if args.swiftc else (["xcrun", "--sdk", "macosx", "swiftc"] if sys.platform == "darwin" else ["swiftc"])
    common_flags = ["-swift-version", "6", "-warnings-as-errors", "-module-cache-path", str(runner.output / "module-cache")]
    value = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "architecture": platform.machine(), "python": sys.version,
        "logical_cpus": os.cpu_count(), "baseline_revision": PIN,
        "head": runner.execute(["git", "rev-parse", "HEAD"], "git-head").decode().strip(),
        "working_tree_status": runner.execute(["git", "status", "--short"], "git-status").decode(),
        "swiftc": runner.execute(swiftc + ["--version"], "swiftc-version").decode().strip(),
        "swift": runner.execute([args.swift, "--version"], "swift-version").decode().strip(),
        "drivers": {name: fingerprint((HERE / name).read_bytes()) for name in ("run.py", "Harness.swift")},
        "github_actions": {key: os.environ.get(key) for key in
                           ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "RUNNER_OS", "RUNNER_ARCH")},
        "method": "Separate optimized full-source module and identical separately compiled driver; no application, disk enumeration or metadata I/O in model timings.",
        "timer": "CLOCK_MONOTONIC wall time and CLOCK_PROCESS_CPUTIME_ID CPU time",
        "locale_environment": {key: os.environ.get(key) for key in ("LANG", "LC_ALL", "LC_CTYPE")},
        "arguments": {key: str(item) if isinstance(item, Path) else item for key, item in vars(args).items()},
    }
    if sys.platform == "darwin":
        for key, command in (
            ("sw_vers", ["sw_vers"]), ("xcode", ["xcodebuild", "-version"]),
            ("sdk_path", ["xcrun", "--sdk", "macosx", "--show-sdk-path"]),
            ("sdk_version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
            ("cpu", ["sysctl", "-n", "machdep.cpu.brand_string"]),
        ):
            value[key] = runner.execute(command, key).decode().strip()
        common_flags += ["-sdk", value["sdk_path"]]
        runner.env["SDKROOT"] = value["sdk_path"]
    elif Path("/proc/cpuinfo").exists():
        value["cpu"] = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                             if line.startswith("model name")), "unknown")
    value["compiler_command"] = swiftc
    value["common_compiler_flags"] = common_flags
    write_json(runner.output / "environment.json", value)
    return value, swiftc, common_flags


def run_tests(runner: Runner, args: argparse.Namespace, baseline: dict) -> None:
    sources = {}
    for variant in VARIANTS:
        directory, manifest = stage_sources(runner.output, variant, baseline, tests=True)
        command = [args.swift, "test", "--package-path", directory,
                   "--scratch-path", runner.output / "build" / variant,
                   "--cache-path", runner.output / "swiftpm-cache",
                   "--config-path", runner.output / "swiftpm-config",
                   "--security-path", runner.output / "swiftpm-security",
                   "--configuration", args.configuration, "--jobs", str(args.jobs),
                   "--no-parallel", "-Xswiftc", "-warnings-as-errors"]
        print(f"Testing {variant} ({args.configuration})", flush=True)
        runner.execute(command, f"test-{variant}-{args.configuration}", timeout=1200)
        check_staged(directory, manifest)
        sources[variant] = manifest
    if any(sources["baseline"]["files"][f"Tests/IlliquidCoreTests/{name}"]["sha256"] !=
           sources["candidate"]["files"][f"Tests/IlliquidCoreTests/{name}"]["sha256"] for name in TEST_FILES):
        raise RuntimeError("Baseline and candidate test bytes differ")
    check_shared_sources(sources, baseline)
    for variant, manifest in sources.items():
        write_json(runner.output / f"{variant}-sources.json", manifest)
    write_json(runner.output / "tests.json", {
        "passed": True, "configuration": args.configuration, "variants": list(VARIANTS),
        "tests": list(TEST_FILES), "source_readback_passed": True, "shared_source_equality_verified": True,
        "scope": "Selected actual core sources and unmodified repository tests; no full app/native playback build",
    })


def build(runner: Runner, baseline: dict, swiftc: list[str], common_flags: list[str]) -> tuple[dict, dict]:
    binaries, staged = {}, {}
    for variant in VARIANTS:
        directory, manifest = stage_sources(runner.output, variant, baseline, tests=False)
        destination = runner.output / "build" / variant
        destination.mkdir(parents=True)
        library = destination / "libIlliquidCore.a"
        flags = common_flags + ["-O", "-whole-module-optimization", "-parse-as-library"]
        core_sources = sorted((directory / "Sources/IlliquidCore").glob("*.swift"))
        runner.execute(swiftc + flags + ["-module-name", "IlliquidCore", "-emit-library", "-static",
                       "-emit-module", "-emit-module-path", destination / "IlliquidCore.swiftmodule",
                       "-o", library, *core_sources], f"build-core-{variant}")
        binary = destination / "empty-subtitle-benchmark"
        runner.execute(swiftc + flags + ["-I", destination, directory / "Harness.swift", library,
                                        "-o", binary], f"build-driver-{variant}")
        check_staged(directory, manifest)
        manifest["library"] = fingerprint(library.read_bytes())
        manifest["binary"] = fingerprint(binary.read_bytes())
        manifest["separate_compilation"] = True
        write_json(runner.output / f"{variant}-sources.json", manifest)
        binaries[variant], staged[variant] = binary, (directory, manifest)
    manifests = {variant: manifest for variant, (_, manifest) in staged.items()}
    check_shared_sources(manifests, baseline)
    if manifests["baseline"]["files"]["Harness.swift"]["sha256"] != manifests["candidate"]["files"]["Harness.swift"]["sha256"]:
        raise RuntimeError("Driver bytes differ across variants")
    for variant, manifest in manifests.items():
        write_json(runner.output / f"{variant}-sources.json", manifest)
    return binaries, staged


def workloads() -> list[dict]:
    values = []
    for operation in ("associate", "makePlaylist"):
        for style, sizes in (("ascii", (0, 1, 8, 1000, 10000)), ("unicode", (8, 1000, 10000))):
            values.extend({"operation": operation, "style": style, "mode": "empty", "media_count": size} for size in sizes)
        values.extend({"operation": operation, "style": "ascii", "mode": mode, "media_count": 128}
                      for mode in ("matched", "unsupported"))
    return values


def workload_id(work: dict) -> str:
    return "-".join(str(work[key]) for key in ("operation", "style", "mode", "media_count"))


def measurement(runner: Runner, binary: Path, work: dict, iterations: int, label: str,
                *, allow_zero_duration: bool = False) -> tuple[dict, dict]:
    raw = runner.execute([binary, "measure", work["operation"], work["style"], work["mode"],
                          str(work["media_count"]), str(iterations)], label, compact_result=True)
    value = json.loads(raw)
    if any(value.get(key) != expected for key, expected in work.items()) or value.get("iterations") != iterations:
        raise RuntimeError("Driver returned the wrong workload or iteration count")
    for key in ("elapsed_ns", "cpu_ns", "checksum", "warmup_iterations", "subtitle_count"):
        if type(value.get(key)) is not int or value[key] < 0:
            raise RuntimeError(f"Invalid measurement field {key}")
    if not allow_zero_duration and (value["elapsed_ns"] == 0 or value["cpu_ns"] == 0):
        raise RuntimeError("Measured wall and CPU durations must be positive")
    if value["warmup_iterations"] != min(3, iterations):
        raise RuntimeError("Invalid warmup count")
    expected_subtitles = 0 if work["mode"] == "empty" else work["media_count"]
    if value["subtitle_count"] != expected_subtitles or value["checksum"] != work["media_count"] * (iterations + min(3, iterations)):
        raise RuntimeError("Invalid subtitle count or consumed-result checksum")
    result = value.pop("result")
    return value, result


def calibrate(runner: Runner, binary: Path, work: dict, variant: str, max_iterations: int,
              expected: dict | None) -> tuple[dict, dict]:
    identity = workload_id(work)
    iterations, attempt = 1, 0
    while True:
        row, result = measurement(runner, binary, work, iterations,
                                  f"calibration-{identity}-{variant}-attempt-{attempt}", allow_zero_duration=True)
        positive = row["elapsed_ns"] > 0 and row["cpu_ns"] > 0
        at_cap = iterations == max_iterations
        ready = positive and (row["elapsed_ns"] >= CALIBRATION_MIN_NS or at_cap)
        row.update(variant=variant, phase="calibration", workload=identity, calibration_attempt=attempt,
                   calibration_target_ns=CALIBRATION_MIN_NS, at_iteration_cap=at_cap,
                   selected_for_loop_count=ready, result_sha256=digest(canonical(result)))
        # Persist even zero-duration and terminal unsuccessful attempts. They
        # are calibration evidence, never accepted paired timing measurements.
        append_json(runner.output / "calibration.jsonl", row)
        if expected is not None and result != expected:
            raise RuntimeError(f"Calibration output mismatch: {identity}/{variant}/attempt {attempt}")
        expected = result
        if ready:
            return row, expected
        if at_cap:
            raise RuntimeError(f"Calibration could not obtain positive wall and CPU durations at "
                               f"the {max_iterations}-iteration cap: {identity}/{variant}")
        iterations = min(max_iterations, iterations * 4)
        attempt += 1


def measured_iterations(calibration: list[dict], target_ms: float, max_iterations: int) -> int:
    # Adaptive calibration may finish with different loop counts for the two
    # variants. Compare their per-call costs, never their aggregate durations.
    slowest_per_call = max(row["elapsed_ns"] / row["iterations"] for row in calibration)
    if slowest_per_call <= 0:
        raise RuntimeError("Calibration did not establish a positive per-call duration")
    return max(1, min(max_iterations, math.ceil(target_ms * 1_000_000 / slowest_per_call)))


def check_logs(output: Path) -> None:
    for row in (json.loads(line) for line in (output / "commands.jsonl").read_bytes().splitlines()):
        for stream in ("stdout", "stderr"):
            if digest((output / row[f"{stream}_path"]).read_bytes()) != row[f"{stream}_sha256"]:
                raise RuntimeError("Subprocess log readback failed")


def run_benchmark(runner: Runner, args: argparse.Namespace, baseline: dict, swiftc: list[str], flags: list[str]) -> None:
    binaries, staged = build(runner, baseline, swiftc, flags)
    differential = {}
    for variant in VARIANTS:
        differential[variant] = json.loads(runner.execute([binaries[variant], "differential"], f"differential-{variant}"))
    if differential["baseline"] != differential["candidate"] or len(differential["baseline"]) != 72:
        raise RuntimeError("Complete differential output mismatch or missing fixtures")
    write_json(runner.output / "differential.json", {
        "passed": True, "comparisons": len(differential["baseline"]),
        "independent_empty_map_and_known_match_oracles": True,
        "results": differential["baseline"],
    })
    cells = workloads()
    write_json(runner.output / "workloads.json", cells)
    rows, summaries = [], []
    for work in cells:
        identity = workload_id(work)
        expected = None
        calibration = []
        # Grow each variant's calibration above timer resolution before choosing
        # one shared loop count for every paired process in this cell.
        for variant in VARIANTS:
            row, expected = calibrate(runner, binaries[variant], work, variant, args.max_iterations, expected)
            calibration.append(row)
        iterations = measured_iterations(calibration, args.target_ms, args.max_iterations)
        receipt = runner.output / "receipts" / (identity + ".json")
        write_json(receipt, expected)
        result_digest = digest(canonical(expected))
        for pair in range(args.pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            for process_order, variant in enumerate(order):
                row, result = measurement(runner, binaries[variant], work, iterations,
                                          f"pair-{pair}-{process_order}-{identity}-{variant}")
                if result != expected:
                    raise RuntimeError(f"Complete output mismatch: {identity}/{pair}/{variant}")
                row.update(variant=variant, phase="measurement", pair=pair, process_order=process_order,
                           workload=identity, result_sha256=result_digest,
                           receipt_path=str(receipt.relative_to(runner.output)))
                rows.append(row)
                append_json(runner.output / "measurements.jsonl", row)
        cell = [row for row in rows if row["workload"] == identity]
        summary = {**work, "workload": identity, "iterations": iterations, "pairs": args.pairs}
        for variant in VARIANTS:
            members = [row for row in cell if row["variant"] == variant]
            wall = [row["elapsed_ns"] / row["iterations"] / 1_000_000 for row in members]
            cpu = [row["cpu_ns"] / row["iterations"] / 1_000_000 for row in members]
            summary[variant] = {"median_ms": statistics.median(wall), "min_ms": min(wall), "max_ms": max(wall),
                                "cpu_median_ms": statistics.median(cpu)}
        summary["candidate_change_percent"] = 100 * (summary["candidate"]["median_ms"] / summary["baseline"]["median_ms"] - 1)
        summary["within_pair"] = {}
        for field, label in (("elapsed_ns", "wall"), ("cpu_ns", "cpu")):
            reductions = []
            for pair in range(args.pairs):
                before = next(row for row in cell if row["pair"] == pair and row["variant"] == "baseline")[field]
                after = next(row for row in cell if row["pair"] == pair and row["variant"] == "candidate")[field]
                if before <= 0:
                    raise RuntimeError("Within-pair reduction needs a positive baseline duration")
                reductions.append(100 * (1 - after / before))
            summary["within_pair"][label] = {"median_reduction_percent": statistics.median(reductions),
                                               "improved_pair_count": sum(value > 0 for value in reductions),
                                               "pair_reductions_percent": reductions}
        summaries.append(summary)
        write_json(runner.output / "summary.json", {"complete": False, "cells": summaries})
        print(json.dumps(summary, sort_keys=True), flush=True)
    # Independently replay actual recorded identities/order, not a description of
    # the intended schedule. Reject missing, duplicate or reordered observations.
    readback = [json.loads(line) for line in (runner.output / "measurements.jsonl").read_bytes().splitlines()]
    expected_order = [(workload_id(work), pair, position, variant)
                      for work in cells for pair in range(args.pairs)
                      for position, variant in enumerate(VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS)))]
    actual_order = [(row["workload"], row["pair"], row["process_order"], row["variant"]) for row in readback]
    if readback != rows or actual_order != expected_order or len(set(actual_order)) != len(actual_order):
        raise RuntimeError("Measurement readback/order validation failed")
    for row in readback:
        if digest(canonical(json.loads((runner.output / row["receipt_path"]).read_bytes()))) != row["result_sha256"]:
            raise RuntimeError("Complete-result receipt changed")
    for directory, manifest in staged.values():
        check_staged(directory, manifest)
    check_logs(runner.output)
    write_json(runner.output / "validation.json", {
        "passed": True, "observations": len(rows), "cells": len(cells), "pairs": args.pairs,
        "alternating_order_verified_from_recorded_rows": True,
        "complete_output_equality": True, "source_and_log_readback": True,
        "shared_source_equality_verified": True,
        "no_completed_observations_removed": True,
    })
    write_json(runner.output / "summary.json", {"complete": True, "cells": summaries})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    for action in ("test", "benchmark"):
        command = commands.add_parser(action)
        command.add_argument("--output", type=Path, required=True, help="new or empty evidence directory")
        command.add_argument("--swift", default="swift")
        command.add_argument("--swiftc", default=None)
        if action == "test":
            command.add_argument("--configuration", choices=("debug", "release"), required=True)
            command.add_argument("--jobs", type=int, default=2)
        else:
            command.add_argument("--pairs", type=int, default=6)
            command.add_argument("--target-ms", type=float, default=60)
            command.add_argument("--max-iterations", type=int, default=100000)
    args = parser.parse_args()
    if args.action == "test" and args.jobs < 1:
        parser.error("jobs must be positive")
    if args.action == "benchmark" and (not 2 <= args.pairs <= 20 or args.pairs % 2 or
                                     not math.isfinite(args.target_ms) or args.target_ms <= 0 or args.max_iterations < 1):
        parser.error("pairs must be even and in 2...20; target-ms and max-iterations must be positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output must be new or empty; previous evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    runner = Runner(output)
    try:
        baseline = checked_baseline()
        _, swiftc, flags = environment(runner, args)
        if args.action == "test":
            run_tests(runner, args, baseline)
            check_logs(output)
        else:
            run_benchmark(runner, args, baseline, swiftc, flags)
    except BaseException as error:
        write_json(output / "failure.json", {"error": str(error), "type": type(error).__name__})
        raise


if __name__ == "__main__":
    main()
