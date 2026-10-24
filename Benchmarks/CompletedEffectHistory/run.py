#!/usr/bin/env python3
"""Compare exact production playback-core sources in balanced fresh processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
# This is the playback core's only dependency on the product-level module.
# Copy the actual file; no platform shims, model stubs or dependencies are used.
CORE_FILES = ["Player/MediaTrack.swift"]
METRICS = ["retained_allocator_delta_bytes", "released_allocator_delta_bytes",
           "loop_wall_nanoseconds", "loop_cpu_nanoseconds"]


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def command(arguments: list, output: Path, *, name: str | None = None,
            timeout: int = 600) -> str:
    arguments = [str(value) for value in arguments]
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               TERM="dumb", NO_COLOR="1")
    started = time.time()
    result = subprocess.run(arguments, capture_output=True, env=env, timeout=timeout)
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": arguments, "returncode": result.returncode,
                                 "started_unix": started, "seconds": time.time() - started,
                                 "stdout": stdout, "stderr": stderr}) + "\n")
    if name:
        (output / name).write_text(stdout + stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments}\n{stdout}\n{stderr}")
    return stdout


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / variant
    revision = baseline if variant == "baseline" else None
    receipts = {}

    def copy(relative: str, destination: Path | None = None, *, current: bool = False) -> None:
        data = (git("show", f"{revision}:{relative}") if revision and not current
                else (ROOT / relative).read_bytes())
        target = destination or package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[relative] = {"sha256": sha256(data), "destination": str(target.relative_to(package)),
                              "transformation": "none"}

    for relative in CORE_FILES:
        copy("Sources/IlliquidCore/" + relative)
    for folder in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace",
                   "Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]:
        paths = (git("ls-tree", "-r", "--name-only", revision, "--", folder).decode().splitlines()
                 if revision else [str(p.relative_to(ROOT)) for p in sorted((ROOT / folder).rglob("*.swift"))])
        for relative in paths:
            if relative.endswith(".swift"):
                copy(relative)
    copy("Benchmarks/CompletedEffectHistory/Harness.swift",
         package / "Sources/EffectHistoryBenchmark/Harness.swift", current=True)
    for relative in ["heap.c", "include/CEffectHistoryHeap.h"]:
        copy("Benchmarks/CompletedEffectHistory/CEffectHistoryHeap/" + relative,
             package / "Sources/CEffectHistoryHeap" / relative, current=True)

    targets = [
        '.target(name: "IlliquidCore")',
        '.target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"])',
        '.target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"])',
        '.target(name: "CEffectHistoryHeap", publicHeadersPath: "include")',
        '.executableTarget(name: "EffectHistoryBenchmark", dependencies: ["IlliquidCore", "IlliquidPlaybackCore", "CEffectHistoryHeap"])',
        '.testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"])',
        '.testTarget(name: "IlliquidPlaybackStateSpaceTests", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"])',
    ]
    manifest = ('// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "CompletedEffectHistory", platforms: [.macOS("26.0")],\n'
                'products: [.executable(name: "EffectHistoryBenchmark", targets: ["EffectHistoryBenchmark"])],\n'
                'targets: [\n' + ',\n'.join(targets) + '\n], swiftLanguageModes: [.v6])\n')
    (package / "Package.swift").write_text(manifest)
    return receipts


def swift_command(args: argparse.Namespace, variant: str, operation: str, configuration: str) -> list:
    result = [args.swift, operation, "--package-path", args.output / variant,
              "--configuration", configuration, "--jobs", "2",
              "--cache-path", args.output / "cache", "--config-path", args.output / "config",
              "--security-path", args.output / "security", "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        result += ["--scratch-path", args.output / variant / ".build/tests", "--no-parallel"]
    if platform.system() == "Linux":
        result.append("--use-integrated-swift-driver")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--cycles", default="32,4096,32768")
    parser.add_argument("--scenarios", default="transport,replacement,checkpointBurst,unclosedGap")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; final evidence must run tests")
    parser.add_argument("--tests-only", action="store_true", help="Run correctness gates without repeating measurements")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    if args.pairs < 1:
        raise ValueError("pairs must be positive")
    cycles = [int(value) for value in args.cycles.split(",")]
    if any(value < 1 for value in cycles):
        raise ValueError("cycles must be positive")
    scenarios = args.scenarios.split(",")
    baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
    manifest = {
        "baseline_commit": baseline, "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "candidate_sources": "current worktree", "compiler": command([args.swift, "--version"], args.output).strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "method": "exact production sources; balanced AB/BA; fresh processes; optimized Swift 6",
        "scope": "playback state-machine allocator residency and component CPU/wall time; not player RSS or decoding",
        "tests_skipped": args.skip_tests, "tests_only": args.tests_only,
        "pairs": args.pairs, "cycles": cycles, "scenarios": scenarios,
        "source_hashes": {}, "harness_hashes": {str(p.relative_to(HERE)): sha256(p.read_bytes())
            for p in sorted(HERE.rglob("*")) if p.is_file() and p.suffix in {".swift", ".py", ".c", ".h"}},
    }
    binaries = {}
    for variant in ["baseline", "candidate"]:
        print(f"Stage and build {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
        save(args.output / "manifest.json", manifest)
        command([*swift_command(args, variant, "build", "release"), "--product", "EffectHistoryBenchmark"],
                args.output, name=f"{variant}-build.log")
        bin_path = command([*swift_command(args, variant, "build", "release"), "--show-bin-path"], args.output).strip()
        binaries[variant] = Path(bin_path) / "EffectHistoryBenchmark"
    manifest["binary_hashes"] = {name: sha256(path.read_bytes()) for name, path in binaries.items()}
    save(args.output / "manifest.json", manifest)
    if not args.skip_tests:
        for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
            print(f"Test {variant} {configuration}", flush=True)
            command(swift_command(args, variant, "test", configuration), args.output,
                    name=f"{variant}-{configuration}-tests.log")

    verification = {}
    for variant, binary in binaries.items():
        verification[variant] = json.loads(command([binary, "--mode", "verify"], args.output))
    save(args.output / "verification.json", verification)
    if verification["baseline"] != verification["candidate"]:
        raise ValueError("Baseline/candidate semantic verification differs")
    print("Semantic output parity passed", flush=True)
    if args.tests_only:
        return

    rows = []
    for scenario in scenarios:
        for count in cycles:
            print(f"Measure {scenario}: {count} cycles, {args.pairs} pairs", flush=True)
            for pair in range(args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                paired = {}
                for variant in order:
                    observed = json.loads(command([binaries[variant], "--scenario", scenario,
                                                   "--cycles", str(count)], args.output))
                    observed.update(variant=variant, pair=pair, scenario=scenario, cycles=count)
                    rows.append(observed)
                    paired[variant] = observed
                    save(args.output / "observations.json", rows)
                if paired["baseline"]["checks"] != paired["candidate"]["checks"]:
                    raise ValueError(f"Workload outputs differ: {scenario}, {count}, {pair}")
    summary = []
    for scenario in scenarios:
        for count in cycles:
            metrics = {}
            for metric in METRICS:
                data = {variant: [row[metric] for row in rows if row["variant"] == variant
                                  and row["scenario"] == scenario and row["cycles"] == count]
                        for variant in ["baseline", "candidate"]}
                baseline_median = statistics.median(data["baseline"])
                candidate_median = statistics.median(data["candidate"])
                metrics[metric] = {"baseline_median": baseline_median, "candidate_median": candidate_median,
                                   "change_percent": 100 * (candidate_median / baseline_median - 1)
                                   if baseline_median else None,
                                   "baseline_range": [min(data["baseline"]), max(data["baseline"])],
                                   "candidate_range": [min(data["candidate"]), max(data["candidate"])]}
            summary.append({"scenario": scenario, "cycles": count, "pairs": args.pairs, "metrics": metrics})
    save(args.output / "summary.json", summary)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
