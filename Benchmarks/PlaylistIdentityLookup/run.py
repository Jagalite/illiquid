#!/usr/bin/env python3
"""Qualify exact baseline/candidate Swift sources in isolated native processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shlex
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TESTS = ("PlaylistIdentityLookupTests", "PlaylistMutationTests",
         "PlaylistOrderRestorationTests", "FolderPlaylistTests")
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6"]
BASELINE_COMMIT = "68274d1b09dcc866296321a5a8858efc297c4f19"
MUTATION_SMALL_INPUT_MIN_ITERATIONS = 500_000


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("tests", "benchmark", "all"), default="all")
    parser.add_argument("--pairs", type=positive_int, default=8)
    parser.add_argument("--target-ms", type=positive_int, default=40)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pairs % 2:
        parser.error("--pairs must be even to balance variant execution order")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Refuse reuse so earlier evidence cannot be silently overwritten or mixed.
    if any(output.iterdir()):
        parser.error("--output must be an empty or new directory")
    logs = output / "logs"
    logs.mkdir()
    command_log = output / "commands.jsonl"
    raw = output / "observations.jsonl"
    state = {"status": "running", "mode": args.mode, "pairs": args.pairs,
             "target_ms": args.target_ms, "tests": [], "summaries": []}

    def save_state() -> None:
        (output / "summary.json").write_text(json.dumps(state, indent=2) + "\n")

    def append(path: Path, value: dict) -> None:
        with path.open("a") as handle:
            handle.write(json.dumps(value, separators=(",", ":")) + "\n")

    def run(command: list[str], name: str) -> str:
        started = time.time()
        append(command_log, {"event": "start", "name": name, "command": command,
                             "cwd": str(ROOT), "started_unix": started})
        log = logs / (name + ".log")
        print("COMMAND " + shlex.join(command), flush=True)
        with log.open("w") as handle:
            process = subprocess.run(command, cwd=ROOT, text=True, stdout=handle,
                                     stderr=subprocess.STDOUT, check=False)
        append(command_log, {"event": "finish", "name": name,
                             "exit_code": process.returncode,
                             "wall_seconds": time.time() - started})
        text = log.read_text()
        if process.returncode:
            print(text[-20000:], flush=True)
            raise RuntimeError(f"{name} failed with exit {process.returncode}; see {log}")
        return text

    save_state()
    try:
        manifest = json.loads((HERE / "baseline/manifest.json").read_text())
        if manifest["baseline_commit"] != BASELINE_COMMIT:
            raise RuntimeError("unexpected frozen baseline commit")
        sources: dict[str, list[Path]] = {variant: [] for variant in VARIANTS}
        receipts: dict[str, dict] = {}
        snapshots = output / "sources"
        for variant in VARIANTS:
            folder = snapshots / variant
            folder.mkdir(parents=True)
            for filename, entry in manifest["files"].items():
                source = HERE / "baseline" / filename if variant == "baseline" else ROOT / entry["path"]
                value = digest(source)
                if variant == "baseline" and value != entry["sha256"]:
                    raise RuntimeError(f"frozen baseline hash mismatch: {filename}")
                copied = folder / filename
                shutil.copyfile(source, copied)
                sources[variant].append(copied)
                receipts[f"{variant}/{filename}"] = {"sha256": value, "repository_path": entry["path"]}
        support = snapshots / "qualification"
        support.mkdir()
        for source in (HERE / "Harness.swift", HERE / "run.py", HERE / "baseline/manifest.json",
                       *(ROOT / "Tests/IlliquidCoreTests" / (name + ".swift") for name in TESTS)):
            shutil.copyfile(source, support / source.name)
            receipts[f"qualification/{source.name}"] = {"sha256": digest(source)}
        metadata = {
            "schema_version": 1, "baseline": manifest,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "candidate-commit").strip(),
            "candidate_status": run(["git", "status", "--short"], "candidate-status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift-version").strip(),
            "compiler_flags": FLAGS, "cross_module_optimization": False,
            "production_module_linkage": "dynamic, separately compiled from driver",
            "source_sha256": receipts, "pairs": args.pairs, "target_ms": args.target_ms,
            "calibration": "All baseline calibration trials retained; one shared iteration count per workload.",
            "initial_calibration_iterations": {
                "default": 1,
                "mutation_count_at_most_one": MUTATION_SMALL_INPUT_MIN_ITERATIONS,
            },
            "sampling": "Fresh process per variant/pair; baseline-first and candidate-first pairs alternate.",
            "scope": "Function-level lookup elapsed wall time; fixture construction and sorting excluded.",
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
        }
        if sys.platform == "darwin":
            metadata["macos"] = run(["sw_vers"], "macos-version").strip()
            metadata["xcode"] = run(["xcodebuild", "-version"], "xcode-version").strip()
            metadata["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")

        if args.mode in ("tests", "all"):
            for variant in VARIANTS:
                for configuration in ("debug", "release"):
                    work = output / "build" / f"tests-{variant}-{configuration}"
                    src = work / "Sources/IlliquidCore"
                    tests = work / "Tests/IlliquidCoreTests"
                    src.mkdir(parents=True)
                    tests.mkdir(parents=True)
                    for source in sources[variant]:
                        shutil.copyfile(source, src / source.name)
                    for name in TESTS:
                        shutil.copyfile(support / (name + ".swift"), tests / (name + ".swift"))
                    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlaylistIdentityQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
''')
                    label = f"tests-{variant}-{configuration}"
                    result = run(["swift", "test", "--package-path", str(work),
                                  "--no-parallel", "-c", configuration], label)
                    state["tests"].append({"variant": variant, "configuration": configuration,
                                           "passed": True, "log": f"logs/{label}.log"})
                    print("TEST_PASS " + variant + " " + configuration, flush=True)
                    print("\n".join(result.splitlines()[-8:]), flush=True)
                    save_state()

        if args.mode in ("benchmark", "all"):
            executables = {}
            for variant in VARIANTS:
                work = output / "build" / variant
                work.mkdir(parents=True)
                extension = "dylib" if sys.platform == "darwin" else "so"
                run(["swiftc", *FLAGS, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
                     *(str(source) for source in sources[variant]),
                     "-o", str(work / f"libIlliquidCore.{extension}")], f"compile-{variant}-module")
                executable = work / "lookup-benchmark"
                run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                     str(support / "Harness.swift"), "-o", str(executable)], f"compile-{variant}-driver")
                executables[variant] = executable
                metadata.setdefault("binary_sha256", {})[variant] = {
                    "library": digest(work / f"libIlliquidCore.{extension}"),
                    "driver": digest(executable),
                }
                (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
            workloads = json.loads(run([str(executables["baseline"]), "--list"], "list-workloads"))
            candidate_workloads = json.loads(run([str(executables["candidate"]), "--list"], "list-candidate-workloads"))
            if workloads != candidate_workloads:
                raise RuntimeError("baseline and candidate workload manifests differ")
            (output / "workloads.json").write_text(json.dumps(workloads, indent=2) + "\n")
            for workload in workloads:
                identifier = workload["id"]
                # Predefined for the final study: singleton mutation now has a
                # constant result, so its candidate loop needs more repetitions.
                iterations = (MUTATION_SMALL_INPUT_MIN_ITERATIONS
                              if workload["api"] == "mutation" and workload["count"] <= 1 else 1)
                for trial in range(8):
                    label = f"calibrate-{identifier}-{trial}"
                    row = json.loads(run([str(executables["baseline"]), identifier, str(iterations)], label))
                    row.update({"phase": "calibration", "variant": "baseline", "trial": trial})
                    append(raw, row)
                    elapsed = row["elapsedMilliseconds"]
                    if elapsed >= args.target_ms / 2 or iterations >= 10_000_000 or trial == 7:
                        break
                    iterations = min(10_000_000, max(iterations + 1,
                        math.ceil(iterations * args.target_ms / max(elapsed, 0.000001))))
                samples = {variant: [] for variant in VARIANTS}
                pair_ratios = []
                candidate_faster_pairs = 0
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    paired = {}
                    paired_receipts = {}
                    for position, variant in enumerate(order):
                        label = f"measure-{identifier}-{pair}-{variant}"
                        row = json.loads(run([str(executables[variant]), identifier, str(iterations)], label))
                        row.update({"phase": "measurement", "variant": variant,
                                    "pair": pair, "position_in_pair": position})
                        append(raw, row)
                        value = row["nanosecondsPerCall"]
                        samples[variant].append(value)
                        paired[variant] = value
                        paired_receipts[variant] = (row.get("expectedIndex"), row["checksum"], row["iterations"])
                        if row["iterations"] != iterations or row["workload"] != workload:
                            raise RuntimeError(f"observation receipt mismatch: {identifier} {variant}")
                    if paired_receipts["baseline"] != paired_receipts["candidate"]:
                        raise RuntimeError(f"baseline/candidate result receipt mismatch: {identifier} pair {pair}")
                    pair_ratios.append(paired["candidate"] / paired["baseline"])
                    candidate_faster_pairs += paired["candidate"] < paired["baseline"]
                before = statistics.median(samples["baseline"])
                after = statistics.median(samples["candidate"])
                summary = {"workload": workload, "iterations": iterations, "pairs": args.pairs,
                           "baseline_median_ns": before, "candidate_median_ns": after,
                           "reduction_percent": 100 * (1 - after / before),
                           "median_paired_reduction_percent": 100 * (1 - statistics.median(pair_ratios)),
                           "candidate_faster_pairs": candidate_faster_pairs,
                           "baseline_median_process_ms": before * iterations / 1_000_000,
                           "candidate_median_process_ms": after * iterations / 1_000_000,
                           "baseline_min_ns": min(samples["baseline"]),
                           "baseline_max_ns": max(samples["baseline"]),
                           "candidate_min_ns": min(samples["candidate"]),
                           "candidate_max_ns": max(samples["candidate"])}
                state["summaries"].append(summary)
                print("BENCHMARK_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)
                save_state()
        state["status"] = "passed"
        save_state()
        print("QUALIFICATION_PASS " + json.dumps({"tests": len(state["tests"]),
              "workloads": len(state["summaries"]), "pairs": args.pairs}), flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        save_state()
        raise


if __name__ == "__main__":
    main()
