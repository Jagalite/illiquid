#!/usr/bin/env python3
"""Test and measure exact SourceTabs production excerpts in separate Swift modules."""
from __future__ import annotations

import argparse
import datetime
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
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
APP = "Sources/IlliquidApp/App/AppModel.swift"
CORE = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
TEST = "Tests/IlliquidAppTests/SourceTabMembershipTests.swift"
START = "struct SourceTabItem:"
END = "\nprivate struct PlaybackLifecycleObservation:"
PRELUDE = "import Foundation\nimport IlliquidCore\n\n"
SEED = 1729

PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceTabMembershipQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SourceTabMembershipProbe", targets: ["SourceTabMembershipProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "SourceTabMembershipProbe", dependencies: ["IlliquidApp", "IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),
    ]
)
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def extract(data: bytes) -> bytes:
    text = data.decode("utf-8")
    if text.count(START) != 1 or text.count(END) != 1:
        raise RuntimeError("AppModel extraction boundaries changed; review the harness")
    start, end = text.index(START), text.index(END)
    if start >= end:
        raise RuntimeError("AppModel extraction boundaries are out of order")
    excerpt = text[start:end]
    for declaration in (START, "struct SourceTab:", "enum SourceTabs {"):
        if excerpt.count(declaration) != 1:
            raise RuntimeError(f"Expected one production declaration: {declaration}")
    return (PRELUDE + excerpt).encode()


def baseline_sources() -> tuple[dict, dict[str, bytes]]:
    manifest = json.loads((HERE / "baseline/manifest.json").read_text())
    if manifest["revision"] != BASELINE or manifest["extraction"]["path"] != APP:
        raise RuntimeError("Unexpected frozen baseline revision or production path")
    for key, value in {"start": START, "end_exclusive": END, "prelude": PRELUDE}.items():
        if manifest["extraction"][key] != value:
            raise RuntimeError(f"Frozen extraction contract changed: {key}")
    files = {name: (HERE / "baseline" / name).read_bytes()
             for name in ("SourceTabs.swift", "NormalizedFileURL.swift")}
    for name, data in files.items():
        if sha(data) != manifest["files"][name]["sha256"]:
            raise RuntimeError(f"Frozen source hash mismatch: {name}")
    if not files["SourceTabs.swift"].startswith(PRELUDE.encode()):
        raise RuntimeError("Frozen source prelude changed")
    if sha(files["SourceTabs.swift"][len(PRELUDE.encode()):]) != manifest["extraction"]["excerpt_sha256"]:
        raise RuntimeError("Frozen production excerpt hash mismatch")
    return manifest, files


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.env = os.environ.copy()
        self.env.update(
            SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
            CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
        )
        self.sequence = 0
        (output / "logs").mkdir()

    def run(self, args: list[str | Path], label: str, timeout: int = 600) -> str:
        self.sequence += 1
        arguments = [str(value) for value in args]
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        result = subprocess.run(arguments, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        log.write_text(result.stdout + result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(arguments=arguments, returncode=result.returncode,
                                         seconds=time.monotonic() - started,
                                         log=str(log.relative_to(self.output))), sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({label}); see {log}\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}")
        return result.stdout


def measurement(runner: Runner, binary: Path, case: str, iterations: int, label: str) -> dict:
    row = json.loads(runner.run([binary, "measure", str(SEED), case, str(iterations)], label))
    if (row["workload"] != case or row["seed"] != SEED or row["iterations"] != iterations
            or row["queries_per_iteration"] != 16 or row["wall_ns"] <= 0 or row["cpu_ns"] <= 0
            or len(row["booleans"]) != 16):
        raise RuntimeError(f"Invalid measurement: {label}")
    expected_checksum = sum(index + 1 for index, value in enumerate(row["booleans"]) if value) * iterations
    if row["checksum"] != expected_checksum:
        raise RuntimeError(f"Observable output checksum mismatch: {label}")
    lookups = iterations * row["queries_per_iteration"]
    row.update(lookups=lookups, wall_ns_per_lookup=row["wall_ns"] / lookups,
               cpu_ns_per_lookup=row["cpu_ns"] / lookups)
    return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=60)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer of at least 2 for balanced AB/BA sampling")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    swift = shutil.which(os.environ.get("SWIFT", "swift"))
    if swift is None:
        parser.error("Swift is unavailable; set SWIFT or add its toolchain to PATH")
    frozen_manifest, baseline = baseline_sources()
    app_bytes, core_bytes = (ROOT / APP).read_bytes(), (ROOT / CORE).read_bytes()
    if core_bytes != baseline["NormalizedFileURL.swift"]:
        raise RuntimeError("NormalizedFileURL differs from baseline; requalify the experiment")
    candidate = {"SourceTabs.swift": extract(app_bytes), "NormalizedFileURL.swift": core_bytes}
    driver_bytes, test_bytes = (HERE / "Driver.swift").read_bytes(), (ROOT / TEST).read_bytes()
    runner = Runner(output)
    packages, binaries, tests, source_receipts = {}, {}, {}, {}
    manifest = {
        "schema_version": 1, "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "baseline": frozen_manifest,
        "candidate_revision": runner.run(["git", "rev-parse", "HEAD"], "git-head").strip(),
        "candidate_relevant_status": runner.run(["git", "status", "--short", "--", APP, CORE, TEST,
                                                   str(HERE.relative_to(ROOT))], "git-status").strip(),
        "environment": {"platform": platform.platform(), "machine": platform.machine(),
                        "cpu_count": os.cpu_count(), "python": platform.python_version(),
                        "swift": runner.run([swift, "--version"], "swift-version").strip(),
                        "swift_command": swift,
                        "variables": {key: runner.env.get(key) for key in
                                      ("LANG", "LC_ALL", "LC_COLLATE", "DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING")}},
        "inputs": {APP: sha(app_bytes), CORE: sha(core_bytes), TEST: sha(test_bytes),
                   "Driver.swift": sha(driver_bytes), "run.py": sha(Path(__file__).read_bytes()),
                   "Package.swift": sha(PACKAGE.encode())},
        "method": {
            "unit": "one SourceTabs.contains(candidate, in: tab) lookup",
            "scope": "in-memory source-tab membership; no filesystem scan, UI, decode, playback, or energy measurement",
            "modules": "unaltered production excerpt plus imports, separate IlliquidCore and IlliquidApp modules; no cross-module optimization",
            "configuration": "SwiftPM release, Swift 6 mode; IlliquidApp -enable-testing for internal benchmark access",
            "sampling": "fresh processes, rotated workload order, balanced baseline/candidate then candidate/baseline pairs",
            "timers": "DispatchTime monotonic wall time and CLOCK_PROCESS_CPUTIME_ID around repeated 16-query batches; includes loop, Boolean stores, checksum updates and timer overhead; no empty-loop subtraction",
            "exclusions": "all tab/query construction, Codable decoding, oracle, warmup, final checks, and JSON encoding are untimed",
            "observability": "preallocated exact boolean outputs plus weighted checksum from every timed batch",
            "calibration": "each variant independently targets requested duration; normalized per lookup; minimum one batch",
            "pairs": args.pairs, "target_ms": args.target_ms, "seed": SEED,
        },
    }
    save(output / "manifest.json", manifest)
    for variant, sources in (("baseline", baseline), ("candidate", candidate)):
        package = output / "packages" / variant
        paths = {
            "Sources/IlliquidCore/NormalizedFileURL.swift": sources["NormalizedFileURL.swift"],
            "Sources/IlliquidApp/SourceTabs.swift": sources["SourceTabs.swift"],
            "Sources/SourceTabMembershipProbe/Driver.swift": driver_bytes,
            "Tests/IlliquidAppTests/SourceTabMembershipTests.swift": test_bytes,
            "Package.swift": PACKAGE.encode(),
        }
        for name, data in paths.items():
            path = package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        source_receipts[variant] = {name: sha(data) for name, data in paths.items()}
        packages[variant] = package
    save(output / "source-receipts.json", source_receipts)

    for variant, package in packages.items():
        options = ["--package-path", package, "--cache-path", output / "package-cache",
                   "--config-path", output / "package-config", "--security-path", output / "package-security"]
        tests[variant] = {}
        for configuration in ("debug", "release"):
            print(f"Testing {variant} in {configuration}", flush=True)
            text = runner.run([swift, "test", *options, "--configuration", configuration,
                               "--jobs", "2", "--no-parallel"], f"{variant}-tests-{configuration}")
            counts = re.findall(r"Test run with (\d+) tests? .*passed", text)
            if not counts or int(counts[-1]) == 0:
                raise RuntimeError(f"No positive Swift Testing completion receipt: {variant}/{configuration}")
            tests[variant][configuration] = {"passed": True, "tests": int(counts[-1])}
            save(output / "tests.json", tests)
        runner.run([swift, "build", *options, "--configuration", "release", "--jobs", "2",
                    "--product", "SourceTabMembershipProbe"], f"{variant}-build-probe")
        bin_directory = runner.run([swift, "build", *options, "--configuration", "release", "--show-bin-path"],
                                   f"{variant}-bin-path").strip()
        binary = Path(bin_directory) / "SourceTabMembershipProbe"
        if not binary.is_file():
            raise RuntimeError(f"SwiftPM did not produce the benchmark: {binary}")
        binaries[variant] = binary
    save(output / "build-receipts.json", {
        variant: {"binary_sha256": sha(binary.read_bytes()), "binary": str(binary.relative_to(output)),
                  "package_sha256": sha((packages[variant] / "Package.swift").read_bytes())}
        for variant, binary in binaries.items()
    })
    cases = json.loads(runner.run([binaries["baseline"], "list", str(SEED)], "list-workloads"))
    if len(cases) != 22 or len(set(cases)) != len(cases):
        raise RuntimeError("Expected exactly 22 distinct workloads")
    verification = {variant: json.loads(runner.run([binary, "verify", str(SEED)], f"{variant}-verify"))
                    for variant, binary in binaries.items()}
    if verification["baseline"] != verification["candidate"]:
        save(output / "verification-mismatch.json", verification)
        raise RuntimeError("Exact baseline/candidate input and boolean receipts differ")
    if [record["workload"] for record in verification["candidate"]] != cases:
        raise RuntimeError("Verification omitted or reordered a workload")
    save(output / "verification.json", verification)
    expected_outputs = {record["workload"]: record["booleans"] for record in verification["candidate"]}
    print(f"Verified exact inputs and membership booleans for {len(cases)} workloads", flush=True)
    if args.tests_only:
        save(output / "summary.json", {"tests": tests, "verified_workloads": cases, "measurements": False})
        return

    iterations, calibration = {}, {}
    target_ns = args.target_ms * 1_000_000
    for case in cases:
        iterations[case], calibration[case] = {}, {}
        for variant, binary in binaries.items():
            first = measurement(runner, binary, case, 1, f"calibrate-{case}-{variant}-1")
            pilot_iterations = min(2_000_000, max(1, math.ceil(target_ns / 8 / first["wall_ns"])))
            pilot = (first if pilot_iterations == 1 else
                     measurement(runner, binary, case, pilot_iterations, f"calibrate-{case}-{variant}-2"))
            iterations[case][variant] = min(2_000_000, max(1, math.ceil(
                target_ns * pilot_iterations / pilot["wall_ns"])))
            calibration[case][variant] = {"first": first, "pilot": pilot,
                                           "iterations": iterations[case][variant]}
    save(output / "calibration.json", calibration)
    rows = []
    for pair in range(args.pairs):
        variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        ordered_cases = cases[pair % len(cases):] + cases[:pair % len(cases)]
        for case in ordered_cases:
            for position, variant in enumerate(variants):
                row = measurement(runner, binaries[variant], case, iterations[case][variant],
                                  f"pair-{pair + 1}-{case}-{variant}")
                if row["booleans"] != expected_outputs[case]:
                    raise RuntimeError(f"Timed output differs from verified receipt: {case}/{variant}")
                row.update(pair=pair, variant=variant, position=position)
                rows.append(row)
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Completed balanced pair {pair + 1}/{args.pairs}", flush=True)

    summaries = []
    for case in cases:
        subset = [row for row in rows if row["workload"] == case]
        summary = {"workload": case, "pairs": args.pairs, "iterations": iterations[case],
                   "item_count": subset[0]["item_count"]}
        for clock in ("wall", "cpu"):
            before = [next(row[f"{clock}_ns_per_lookup"] for row in subset
                           if row["pair"] == pair and row["variant"] == "baseline") for pair in range(args.pairs)]
            after = [next(row[f"{clock}_ns_per_lookup"] for row in subset
                          if row["pair"] == pair and row["variant"] == "candidate") for pair in range(args.pairs)]
            summary[clock] = {
                "baseline_median_ns_per_lookup": statistics.median(before),
                "candidate_median_ns_per_lookup": statistics.median(after),
                "paired_median_reduction_percent": statistics.median(100 * (1 - b / a) for a, b in zip(before, after)),
                "candidate_faster_pairs": sum(b < a for a, b in zip(before, after)),
                "baseline_ns_per_lookup": before, "candidate_ns_per_lookup": after,
            }
        summaries.append(summary)
    report = {"tests": tests, "verified_workloads": cases, "pairs": args.pairs,
              "measurements": len(rows), "results": summaries}
    save(output / "summary.json", report)
    print("workload | baseline us/lookup | candidate us/lookup | paired wall reduction | paired CPU reduction")
    for row in summaries:
        print(f"{row['workload']} | {row['wall']['baseline_median_ns_per_lookup']/1000:.3f} | "
              f"{row['wall']['candidate_median_ns_per_lookup']/1000:.3f} | "
              f"{row['wall']['paired_median_reduction_percent']:.1f}% | "
              f"{row['cpu']['paired_median_reduction_percent']:.1f}%")


if __name__ == "__main__":
    main()
