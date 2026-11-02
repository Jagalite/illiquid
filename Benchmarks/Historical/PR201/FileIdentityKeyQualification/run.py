#!/usr/bin/env python3
"""Compare frozen and current file identity keys using actual production sources."""
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
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "d90e4fc199eabfa4e554c3c8d01a1ed48277ae20"
SOURCE_PATHS = (
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
)
TEST_NAMES = (
    "LocalMediaSourceValidationTests.swift",
    "NormalizedFileURLPersistenceKeyTests.swift",
    "FolderPlaylistTests.swift",
    "FolderPlaylistLookupTests.swift",
)
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
         "-Xfrontend", "-disable-cmo"]
MAX_ITERATIONS = 100_000_000


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=positive_int, default=10)
    parser.add_argument("--target-ms", type=positive_int, default=100)
    parser.add_argument("--mode", choices=("tests", "benchmark", "all"), default="all")
    args = parser.parse_args()
    if args.pairs % 2:
        parser.error("--pairs must be even to balance execution order")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be new or empty")
    logs = output / "logs"
    logs.mkdir()
    state = {"status": "running", "tests": [], "summaries": []}

    def save(name: str, value) -> None:
        (output / name).write_text(json.dumps(value, indent=2) + "\n")

    def append(name: str, value) -> None:
        with (output / name).open("a") as handle:
            handle.write(json.dumps(value, separators=(",", ":")) + "\n")

    def run(command: list[str], name: str) -> str:
        started = time.time()
        append("commands.jsonl", {"name": name, "command": command, "started_unix": started})
        with (logs / (name + ".log")).open("w") as handle:
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=handle,
                                    stderr=subprocess.STDOUT, check=False)
        append("commands.jsonl", {"name": name, "exit_code": result.returncode,
                                  "wall_seconds": time.time() - started})
        text = (logs / (name + ".log")).read_text()
        if result.returncode:
            print(text[-20000:], flush=True)
            raise RuntimeError(f"{name} failed with exit {result.returncode}")
        return text

    def observe(variant: str, workload: dict, iterations: int, phase: str,
                number: int, position: int = 0) -> dict:
        name = f"{phase}-{workload['id']}-{number}-{variant}"
        row = json.loads(run([str(executables[variant]), workload["id"], str(iterations)], name))
        if (row["id"] != workload["id"] or row["iterations"] != iterations
                or row["operationsPerIteration"] != workload["operationsPerIteration"]
                or row["elapsedNS"] <= 0):
            raise RuntimeError(f"invalid measurement receipt: {name}")
        row.update(variant=variant, phase=phase, number=number, position=position)
        append("measurements.jsonl", row)
        print("OBSERVATION " + json.dumps(row, separators=(",", ":")), flush=True)
        return row

    save("summary.json", state)
    try:
        frozen = HERE / "baseline/NormalizedFileURL.swift"
        contents = frozen.read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(contents)).encode() + b"\0" + contents).hexdigest()
        if blob != BASELINE_BLOB:
            raise RuntimeError("frozen baseline does not match the recorded Git blob")
        sources = {}
        receipts = {}
        for variant in VARIANTS:
            folder = output / "sources" / variant
            folder.mkdir(parents=True)
            sources[variant] = []
            for path in SOURCE_PATHS:
                source = frozen if variant == "baseline" and path == SOURCE_PATHS[0] else ROOT / path
                copied = folder / source.name
                shutil.copyfile(source, copied)
                sources[variant].append(copied)
                receipts[f"{variant}/{source.name}"] = {
                    "repository_path": path, "sha256": sha256(copied)
                }
        support = output / "sources" / "qualification"
        support.mkdir()
        for source in (HERE / "Driver.swift", HERE / "run.py",
                       *(ROOT / "Tests/IlliquidCoreTests" / name for name in TEST_NAMES)):
            shutil.copyfile(source, support / source.name)
            receipts[f"qualification/{source.name}"] = {"sha256": sha256(source)}

        manifest = {
            "baseline_commit": BASELINE_COMMIT, "baseline_blob": BASELINE_BLOB,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "commit").strip(),
            "candidate_status": run(["git", "status", "--short"], "status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift-version").strip(),
            "compiler_flags": FLAGS, "source_sha256": receipts,
            "module_boundary": "Production module and driver compiled separately with -Xfrontend -disable-cmo",
            "sampling": "Fresh process per variant per pair; AB/BA order alternates; all samples retained",
            "calibration": "One shared iteration count per workload, chosen using both variants",
            "scope": "Steady-state component calls; fixture creation, sorting and warmup excluded",
            "pairs": args.pairs, "target_ms": args.target_ms,
            "logical_cpu_count": os.cpu_count(),
            "mode": args.mode, "developer_dir": os.environ.get("DEVELOPER_DIR"),
        }
        if sys.platform == "darwin":
            manifest["macos"] = run(["sw_vers"], "macos-version").strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode-version").strip()
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        if sys.platform.startswith("linux") and Path("/proc/cpuinfo").is_file():
            manifest["cpu"] = next((line.split(":", 1)[1].strip()
                for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), "unknown")
        save("manifest.json", manifest)
        print("MANIFEST " + json.dumps(manifest, separators=(",", ":")), flush=True)

        if args.mode in ("tests", "all"):
            for variant in VARIANTS:
                work = output / "build" / ("tests-" + variant)
                src = work / "Sources/IlliquidCore"
                tests = work / "Tests/IlliquidCoreTests"
                src.mkdir(parents=True)
                tests.mkdir(parents=True)
                for source in sources[variant]:
                    shutil.copyfile(source, src / source.name)
                for name in TEST_NAMES:
                    shutil.copyfile(support / name, tests / name)
                (work / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "FileIdentityKeyQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
""")
                for configuration in ("debug", "release"):
                    label = f"tests-{variant}-{configuration}"
                    result = run(["swift", "test", "--package-path", str(work),
                                  "--no-parallel", "--jobs", "2", "-c", configuration,
                                  "-Xswiftc", "-warnings-as-errors"], label)
                    receipt = {"variant": variant, "configuration": configuration, "passed": True,
                               "log": "logs/" + label + ".log",
                               "result": "\n".join(result.splitlines()[-8:])}
                    state["tests"].append(receipt)
                    print("TEST_PASS " + json.dumps(receipt, separators=(",", ":")), flush=True)
                    save("summary.json", state)

        executables = {}
        if args.mode in ("benchmark", "all"):
            for variant in VARIANTS:
                work = output / "build" / variant
                work.mkdir(parents=True)
                extension = "dylib" if sys.platform == "darwin" else "so"
                library = work / f"libIlliquidCore.{extension}"
                run(["swiftc", *FLAGS, "-emit-library", "-emit-module",
                     "-module-name", "IlliquidCore", "-emit-module-path",
                     str(work / "IlliquidCore.swiftmodule"),
                     *(str(source) for source in sources[variant]), "-o", str(library)],
                    "compile-" + variant + "-module")
                executable = work / "file-identity-benchmark"
                run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                     str(support / "Driver.swift"), "-o", str(executable)],
                    "compile-" + variant + "-driver")
                executables[variant] = executable
                manifest.setdefault("binary_sha256", {})[variant] = {
                    "module": sha256(library), "driver": sha256(executable)}
            save("manifest.json", manifest)
            print("BUILD_RECEIPT " + json.dumps(manifest["binary_sha256"], separators=(",", ":")), flush=True)
            workloads = json.loads(run([str(executables["baseline"]), "--list"], "list-baseline"))
            if workloads != json.loads(run([str(executables["candidate"]), "--list"], "list-candidate")):
                raise RuntimeError("workload lists differ")
            save("workloads.json", workloads)

            for workload in workloads:
                required = []
                signatures = set()
                for variant in VARIANTS:
                    iterations = 1
                    for trial in range(8):
                        row = observe(variant, workload, iterations, "calibration", trial)
                        signatures.add(row["signature"])
                        if (row["elapsedNS"] >= args.target_ms * 500_000
                                or iterations == MAX_ITERATIONS or trial == 7):
                            break
                        iterations = min(MAX_ITERATIONS, max(iterations + 1, math.ceil(
                            iterations * args.target_ms * 1_000_000 / row["elapsedNS"])))
                    required.append(min(MAX_ITERATIONS, max(1, math.ceil(
                        iterations * args.target_ms * 1_000_000 / row["elapsedNS"]))))
                if len(signatures) != 1:
                    raise RuntimeError("calibration result bytes differ: " + workload["id"])
                iterations = max(required)
                samples = {variant: [] for variant in VARIANTS}
                ratios = []
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                    paired = {}
                    result_receipts = []
                    for position, variant in enumerate(order):
                        row = observe(variant, workload, iterations, "measurement", pair, position)
                        value = row["elapsedNS"] / (iterations * workload["operationsPerIteration"])
                        samples[variant].append(value)
                        paired[variant] = value
                        result_receipts.append((row["signature"], row["checksum"]))
                    if result_receipts[0] != result_receipts[1] or result_receipts[0][0] not in signatures:
                        raise RuntimeError("measured result bytes/checksums differ: " + workload["id"])
                    ratios.append(paired["candidate"] / paired["baseline"])
                before = statistics.median(samples["baseline"])
                after = statistics.median(samples["candidate"])
                summary = {
                    **workload, "iterations": iterations, "pairs": args.pairs,
                    "baseline_median_ns": before, "candidate_median_ns": after,
                    "delta_ns": after - before, "reduction_percent": 100 * (1 - after / before),
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                    "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
                    "baseline_range_ns": [min(samples["baseline"]), max(samples["baseline"])],
                    "candidate_range_ns": [min(samples["candidate"]), max(samples["candidate"])],
                }
                state["summaries"].append(summary)
                print("BENCHMARK_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)
                save("summary.json", state)
        state["status"] = "passed"
        save("summary.json", state)
        print("QUALIFICATION_PASS " + json.dumps({"tests": len(state["tests"]),
              "workloads": len(state["summaries"]), "pairs": args.pairs}), flush=True)
    except BaseException as error:
        state.update(status="failed", error=f"{type(error).__name__}: {error}")
        save("summary.json", state)
        raise


if __name__ == "__main__":
    main()
