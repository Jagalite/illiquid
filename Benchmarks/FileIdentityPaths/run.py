#!/usr/bin/env python3
"""Measure file identity paths using exact, separately compiled Swift sources."""
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
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASE_BLOB = "d90e4fc199eabfa4e554c3c8d01a1ed48277ae20"
SOURCE_PATHS = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
]
TEST_NAMES = [
    "NormalizedFileURLPersistenceKeyTests",
    "LocalMediaSourceValidationTests",
    "PlaylistIdentityLookupTests",
    "PlaylistMutationTests",
    "PlaylistOrderRestorationTests",
    "FolderPlaylistTests",
]
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6"]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def positive(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    parser.add_argument("--pairs", type=positive, default=10)
    parser.add_argument("--target-ms", type=positive, default=80)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pairs < 4 or args.pairs % 2:
        parser.error("--pairs must be even and at least four")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be empty or new")
    logs = output / "logs"
    logs.mkdir()
    state = {"status": "running", "tests": [], "summaries": []}

    def save(name: str, value: object) -> None:
        (output / name).write_text(json.dumps(value, indent=2) + "\n")

    def append(name: str, value: dict) -> None:
        with (output / name).open("a") as handle:
            handle.write(json.dumps(value, separators=(",", ":")) + "\n")

    def run(command: list[str], label: str) -> str:
        log = logs / f"{label}.log"
        print("RUN " + label, flush=True)
        with log.open("w") as handle:
            process = subprocess.run(command, cwd=ROOT, text=True, stdout=handle,
                                     stderr=subprocess.STDOUT, check=False)
        append("commands.jsonl", {"label": label, "command": command,
                                 "exit_code": process.returncode})
        result = log.read_text()
        if process.returncode:
            print(result[-20000:], flush=True)
            raise RuntimeError(f"{label}: exit {process.returncode}; see {log}")
        return result

    def record(row: dict) -> None:
        append("observations.jsonl", row)
        print("FILE_IDENTITY_OBSERVATION " + json.dumps(row, separators=(",", ":")), flush=True)

    save("summary.json", state)
    try:
        baseline = HERE / "baseline/NormalizedFileURL.swift"
        data = baseline.read_bytes()
        git_blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if git_blob != BASE_BLOB:
            raise RuntimeError("frozen baseline does not match the recorded Git blob")
        sources: dict[str, list[Path]] = {}
        receipts: dict[str, dict] = {}
        for variant in VARIANTS:
            folder = output / "sources" / variant
            folder.mkdir(parents=True)
            sources[variant] = []
            for index, relative in enumerate(SOURCE_PATHS):
                source = baseline if variant == "baseline" and index == 0 else ROOT / relative
                copied = folder / source.name
                shutil.copyfile(source, copied)
                sources[variant].append(copied)
                receipts[f"{variant}/{source.name}"] = {
                    "repository_path": relative, "sha256": sha256(copied)}
        support = output / "sources/qualification"
        support.mkdir()
        qualification_files = [
            HERE / "Driver.swift", HERE / "run.py",
            ROOT / "Sources/IlliquidCore/Player/MediaSource.swift",
            *(ROOT / "Tests/IlliquidCoreTests" / f"{name}.swift" for name in TEST_NAMES),
        ]
        for source in qualification_files:
            copied = support / source.name
            shutil.copyfile(source, copied)
            receipts[f"qualification/{source.name}"] = {"sha256": sha256(copied)}
        manifest = {
            "baseline_commit": BASE_COMMIT, "baseline_identity_blob": BASE_BLOB,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "commit").strip(),
            "candidate_status": run(["git", "status", "--short"], "status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift-version").strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "compiler_flags": FLAGS, "source_sha256": receipts,
            "production_linkage": "separate dynamic library; no cross-module optimization",
            "pairs": args.pairs, "target_ms": args.target_ms,
            "sampling": "Fresh process per observation; AB/BA order alternates by pair.",
            "scope": "Warm component wall time, including result consumption; setup, sorting and byte checks excluded.",
        }
        if sys.platform == "darwin":
            manifest["macos"] = run(["sw_vers"], "macos").strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode").strip()
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        save("manifest.json", manifest)

        if args.mode in ("all", "tests"):
            for variant in VARIANTS:
                for configuration in ("debug", "release"):
                    work = output / "build" / f"tests-{variant}-{configuration}"
                    src = work / "Sources/IlliquidCore"
                    tests = work / "Tests/IlliquidCoreTests"
                    src.mkdir(parents=True)
                    tests.mkdir(parents=True)
                    for source in sources[variant]:
                        shutil.copyfile(source, src / source.name)
                    shutil.copyfile(support / "MediaSource.swift", src / "MediaSource.swift")
                    for name in TEST_NAMES:
                        shutil.copyfile(support / f"{name}.swift", tests / f"{name}.swift")
                    (work / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "FileIdentityQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
""")
                    label = f"tests-{variant}-{configuration}"
                    result = run(["swift", "test", "--package-path", str(work), "--no-parallel",
                                  "--jobs", "2", "-c", configuration,
                                  "-Xswiftc", "-warnings-as-errors"], label)
                    state["tests"].append({"variant": variant, "configuration": configuration,
                                           "passed": True, "log": f"logs/{label}.log"})
                    print("\n".join(result.splitlines()[-8:]), flush=True)
                    save("summary.json", state)

        if args.mode in ("all", "benchmark"):
            executables = {}
            for variant in VARIANTS:
                work = output / "build" / variant
                work.mkdir(parents=True)
                extension = "dylib" if sys.platform == "darwin" else "so"
                library = work / f"libIlliquidCore.{extension}"
                run(["swiftc", *FLAGS, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
                     *(str(source) for source in sources[variant]), "-o", str(library)],
                    f"compile-{variant}-library")
                executable = work / "file-identity-benchmark"
                run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                     str(support / "Driver.swift"), "-o", str(executable)], f"compile-{variant}-driver")
                executables[variant] = executable
                manifest.setdefault("binary_sha256", {})[variant] = {
                    "library": sha256(library), "driver": sha256(executable)}
            save("manifest.json", manifest)
            workloads = json.loads(run([str(executables["baseline"]), "--list"], "baseline-workloads"))
            if workloads != json.loads(run([str(executables["candidate"]), "--list"], "candidate-workloads")):
                raise RuntimeError("workload manifests differ")
            save("workloads.json", workloads)
            for workload in workloads:
                identifier = workload["id"]
                iterations = 1
                # Calibrate both variants, retaining every trial. Shared iterations
                # must give even the faster variant a meaningful timed interval.
                for trial in range(8):
                    calibration = []
                    for variant in VARIANTS:
                        row = json.loads(run([str(executables[variant]), identifier, str(iterations)],
                                             f"calibrate-{identifier}-{trial}-{variant}"))
                        row.update({"phase": "calibration", "variant": variant, "trial": trial})
                        record(row)
                        calibration.append(row["elapsedMilliseconds"])
                    fastest = min(calibration)
                    if fastest >= args.target_ms:
                        break
                    iterations = min(10_000_000, max(iterations + 1,
                        math.ceil(iterations * args.target_ms * 1.1 / max(fastest, 0.000001))))
                else:
                    raise RuntimeError(f"calibration did not converge: {identifier}")

                samples = {variant: [] for variant in VARIANTS}
                ratios = []
                wins = 0
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    paired = {}
                    for position, variant in enumerate(order):
                        row = json.loads(run([str(executables[variant]), identifier, str(iterations)],
                                             f"measure-{identifier}-{pair}-{variant}"))
                        if row["workload"] != workload or row["iterations"] != iterations:
                            raise RuntimeError("measurement receipt does not match request")
                        row.update({"phase": "measurement", "variant": variant,
                                    "pair": pair, "position_in_pair": position})
                        record(row)
                        paired[variant] = row
                        samples[variant].append(row["nanosecondsPerCall"])
                    before, after = paired["baseline"], paired["candidate"]
                    if (before["checksum"], before["calls"]) != (after["checksum"], after["calls"]):
                        raise RuntimeError(f"result receipt mismatch: {identifier}, pair {pair}")
                    ratios.append(after["nanosecondsPerCall"] / before["nanosecondsPerCall"])
                    wins += after["nanosecondsPerCall"] < before["nanosecondsPerCall"]
                before = statistics.median(samples["baseline"])
                after = statistics.median(samples["candidate"])
                summary = {
                    "workload": workload, "iterations": iterations, "pairs": args.pairs,
                    "baseline_median_ns": before, "candidate_median_ns": after,
                    "reduction_percent": 100 * (1 - after / before),
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                    "candidate_faster_pairs": wins,
                    "baseline_range_ns": [min(samples["baseline"]), max(samples["baseline"])],
                    "candidate_range_ns": [min(samples["candidate"]), max(samples["candidate"])],
                    "shorter_median_process_ms": min(before, after) * paired["baseline"]["calls"] / 1_000_000,
                }
                state["summaries"].append(summary)
                print("FILE_IDENTITY_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)
                save("summary.json", state)
        state["status"] = "passed"
        save("summary.json", state)
        print("FILE_IDENTITY_MANIFEST " + json.dumps(manifest, separators=(",", ":")), flush=True)
        print("FILE_IDENTITY_COMPLETE " + json.dumps({
            "status": state["status"], "tests": state["tests"],
            "workloads": len(state["summaries"])}), flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        save("summary.json", state)
        raise


if __name__ == "__main__":
    main()
