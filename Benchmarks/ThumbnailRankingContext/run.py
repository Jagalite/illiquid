#!/usr/bin/env python3
"""Measure the production thumbnail ranking policy with identical bounded workloads."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
VARIANTS = ("baseline", "candidate")
SCENARIOS = ("no-folder-32", "no-folder-128", "no-folder-2048",
             "with-folder-32", "with-folder-128", "with-folder-2048")


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def run(args: list, output: Path, log: str | None = None, timeout: int = 900) -> str:
    args = [str(x) for x in args]
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               TERM="dumb", NO_COLOR="1")
    start = time.time()
    result = subprocess.run(args, capture_output=True, env=env, timeout=timeout)
    stdout = result.stdout.decode()
    stderr = result.stderr.decode()
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": args, "returncode": result.returncode,
                                 "started_unix": start, "seconds": time.time() - start,
                                 "stdout": stdout, "stderr": stderr}) + "\n")
    if log:
        (output / log).write_text(stdout + stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{stdout}\n{stderr}")
    return stdout


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / variant
    source_hashes = {}

    def copy(path: str, destination: str | None = None, current: bool = False) -> None:
        data = ((ROOT / path).read_bytes() if current or variant == "candidate"
                else git("show", f"{baseline}:{path}"))
        target = package / (destination or path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        source_hashes[path] = {"sha256": digest(data),
                              "destination": str(target.relative_to(package)),
                              "transformation": "none"}

    for name in ("ThumbnailPolicy.swift", "ThumbnailPassCursor.swift", "ThumbnailVisibilityPolicy.swift"):
        copy("Sources/IlliquidCore/Player/" + name)
    for name in ("ThumbnailPolicyTests.swift", "ThumbnailSchedulingPolicyRegressionTests.swift",
                 "ThumbnailRankingContextTests.swift"):
        copy("Tests/IlliquidCoreTests/" + name, current=True)
    copy("Benchmarks/ThumbnailRankingContext/Harness.swift",
         "Sources/ThumbnailRankingBenchmark/Harness.swift", current=True)
    manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailRankingContext",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ThumbnailRankingBenchmark", targets: ["ThumbnailRankingBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "ThumbnailRankingBenchmark", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ],
    swiftLanguageModes: [.v6]
)
"""
    (package / "Package.swift").write_text(manifest)
    source_hashes["generated-Package.swift"] = {"sha256": digest(manifest.encode())}
    return source_hashes


def swift_command(args: argparse.Namespace, variant: str, operation: str,
                  configuration: str = "release") -> list:
    command = [args.swift, operation, "--package-path", args.output / variant,
               "--configuration", configuration, "--jobs", "2",
               "--cache-path", args.output / "cache",
               "--config-path", args.output / "config",
               "--security-path", args.output / "security",
               "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        command += ["--no-parallel"]
    return command


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even number of at least 2")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    print("Build variants serially in isolated package directories.", flush=True)
    baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
    manifest = {
        "baseline_commit": baseline,
        "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "worktree_status": git("status", "--porcelain").decode(),
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": run([args.swift, "--version"], args.output).strip(),
        "method": "exact production sources; release builds; balanced AB/BA; fresh processes",
        "scope": "thumbnail candidate ranking only; no decoding, UI latency, RSS, or energy claim",
        "pairs": args.pairs,
        "tests_only": args.tests_only, "source_hashes": {},
        "harness_hashes": {p.name: digest(p.read_bytes()) for p in (HERE / "Harness.swift", HERE / "run.py")},
    }
    if platform.system() == "Darwin":
        manifest["macos_version"] = run(["sw_vers"], args.output).strip()
        manifest["cpu_brand"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], args.output).strip()
        manifest["cpu_count"] = os.cpu_count()
    binaries = {}
    for variant in VARIANTS:
        print(f"Stage and compile {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
        save(args.output / "manifest.json", manifest)
        run([*swift_command(args, variant, "build"), "--product", "ThumbnailRankingBenchmark"],
            args.output, f"{variant}-build.log")
        bin_path = run([*swift_command(args, variant, "build"), "--show-bin-path"], args.output).strip()
        binaries[variant] = Path(bin_path) / "ThumbnailRankingBenchmark"

    source_changes = [path for path, receipt in manifest["source_hashes"]["baseline"].items()
                      if receipt != manifest["source_hashes"]["candidate"].get(path)]
    expected = ["Sources/IlliquidCore/Player/ThumbnailPolicy.swift"]
    if source_changes != expected:
        raise ValueError(f"Unexpected before/after source differences: {source_changes}")
    manifest["changed_sources"] = source_changes
    manifest["binary_hashes"] = {variant: digest(binary.read_bytes())
                                 for variant, binary in binaries.items()}
    save(args.output / "manifest.json", manifest)

    tests = []
    for variant, configuration in (("baseline", "release"), ("candidate", "debug"),
                                    ("candidate", "release")):
        print(f"Test {variant} {configuration}", flush=True)
        log = f"{variant}-{configuration}-tests.log"
        run(swift_command(args, variant, "test", configuration), args.output, log)
        tests.append({"variant": variant, "configuration": configuration,
                      "result": "passed", "log": log,
                      "sha256": digest((args.output / log).read_bytes())})
        save(args.output / "tests.json", tests)

    verifications = {}
    for variant in VARIANTS:
        print(f"Verify ranking context matrix: {variant}", flush=True)
        text = run([binaries[variant], "--verify"], args.output, f"{variant}-verification.log")
        verifications[variant] = json.loads(text)
        save(args.output / f"{variant}-verification.json", verifications[variant])
    if verifications["baseline"] != verifications["candidate"]:
        raise ValueError("Semantic verification differs between baseline and candidate")
    verification = {"result": "identical", "details": verifications["candidate"]}
    save(args.output / "verification.json", verification)
    print("All verification outputs match.", flush=True)
    if args.tests_only:
        return

    rows = []
    calibrations = {}
    for scenario in SCENARIOS:
        probe = json.loads(run([binaries["baseline"], "--scenario", scenario, "--iterations", "1"],
                               args.output))
        # Keep each measured workload above timer noise, with identical work in each variant.
        iterations = max(1, min(100_000, math.ceil(300_000_000 / max(1, probe["wall_nanoseconds"]))))
        calibrations[scenario] = {"iterations": iterations, "probe": probe}
        save(args.output / "calibration.json", calibrations)
        print(f"Measure {scenario}: {iterations} iterations, {args.pairs} AB/BA pairs", flush=True)
        for pair in range(args.pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            paired = {}
            for variant in order:
                row = json.loads(run([binaries[variant], "--scenario", scenario,
                                      "--iterations", str(iterations)], args.output))
                row.update(variant=variant, pair=pair, order=list(order))
                rows.append(row)
                paired[variant] = row
                save(args.output / "measurements.json", rows)
            if paired["baseline"]["checks"] != paired["candidate"]["checks"]:
                raise ValueError(f"Timed workload outputs differ: {scenario}, pair {pair}")

    summary = []
    for scenario in SCENARIOS:
        selected = [row for row in rows if row["scenario"] == scenario]
        by_variant = {variant: [r["wall_nanoseconds"] / r["iterations"] for r in selected
                                if r["variant"] == variant] for variant in VARIANTS}
        base = statistics.median(by_variant["baseline"])
        candidate = statistics.median(by_variant["candidate"])
        paired_reductions = [100 * (1 - next(r["wall_nanoseconds"] for r in selected
                                            if r["pair"] == pair and r["variant"] == "candidate")
                                   / next(r["wall_nanoseconds"] for r in selected
                                          if r["pair"] == pair and r["variant"] == "baseline"))
                             for pair in range(args.pairs)]
        summary.append({
            "scenario": scenario, "pairs": args.pairs,
            "iterations_per_process": calibrations[scenario]["iterations"],
            "baseline_median_ms": base / 1_000_000,
            "candidate_median_ms": candidate / 1_000_000,
            "median_time_reduction_percent": 100 * (1 - candidate / base),
            "speedup": base / candidate,
            "paired_time_reduction_percent": paired_reductions,
            "checks": selected[0]["checks"],
        })
    save(args.output / "summary.json", summary)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
