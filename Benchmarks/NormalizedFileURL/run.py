#!/usr/bin/env python3
"""Compare native file-key implementations without the app's FFmpeg dependencies."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6"]
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
TESTS = (
    "LocalMediaSourceValidationTests", "UtilitiesTests",
    "FolderPlaylistLookupTests", "NormalizedFileURLPersistenceKeyTests",
)
CORPUS = ROOT / "Tests/IlliquidCoreTests/TestSupport/NormalizedFileURLCorpus.swift"
SHARED = (
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_blob(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("tests", "benchmark", "all"), default="all")
    parser.add_argument("--pairs", type=positive_int, default=8)
    parser.add_argument("--target-ms", type=positive_int, default=80)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--under-kyoto", action="store_true",
                        help="Only set when this whole command was submitted through Kyoto.")
    args = parser.parse_args()
    if args.pairs < 4 or args.pairs % 2:
        parser.error("--pairs must be even and at least four")
    if sys.platform != "darwin":
        parser.error("This experiment qualifies Darwin Foundation; run on macOS.")
    if KYOTO.is_file() and not args.under_kyoto:
        parser.error("Kyoto is available: submit this complete command through "
                     f"python3 {KYOTO} submit -- and add --under-kyoto. "
                     "Inspect show/logs/wait for that job before reporting results.")
    if not KYOTO.is_file():
        print(f"Kyoto unavailable at {KYOTO}; using serialized isolated direct builds.", flush=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be an empty or new directory")
    logs = output / "logs"
    logs.mkdir()
    raw = output / "observations.jsonl"
    command_log = output / "commands.jsonl"
    state = {"status": "running", "mode": args.mode, "pairs": args.pairs,
             "target_ms": args.target_ms, "tests": [], "verification": None, "summaries": []}

    def save_state() -> None:
        (output / "summary.json").write_text(json.dumps(state, indent=2) + "\n")

    def append(path: Path, value: dict) -> None:
        with path.open("a") as handle:
            handle.write(json.dumps(value, separators=(",", ":")) + "\n")

    def run(command: list[str], name: str) -> str:
        started = time.time()
        append(command_log, {"event": "start", "name": name, "command": command,
                             "cwd": str(ROOT), "started_unix": started})
        print("COMMAND " + shlex.join(command), flush=True)
        log = logs / (name + ".log")
        with log.open("w") as handle:
            process = subprocess.run(command, cwd=ROOT, text=True, stdout=handle,
                                     stderr=subprocess.STDOUT, check=False)
        append(command_log, {"event": "finish", "name": name,
                             "exit_code": process.returncode,
                             "wall_seconds": time.time() - started})
        result = log.read_text()
        if process.returncode:
            print(result[-20000:], flush=True)
            raise RuntimeError(f"{name} exited {process.returncode}; see {log}")
        return result

    def observation(executable: Path, workload: dict, iterations: int,
                    phase: str, variant: str, index: int, position: int) -> dict:
        label = f"{phase}-{workload['id']}-{index}-{variant}"
        row = json.loads(run([str(executable), workload["id"], str(iterations)], label))
        if (row["workload"] != workload or row["iterations"] != iterations
                or row["checksum"] != row["expectedChecksum"]
                or not math.isfinite(row["nanosecondsPerCall"])
                or row["nanosecondsPerCall"] <= 0):
            raise RuntimeError(f"Invalid observation: {label}")
        row.update({"phase": phase, "variant": variant, "pair": index,
                    "position_in_pair": position})
        append(raw, row)
        # Native receipts are also available in logs when artifact download is unavailable.
        print("OBSERVATION " + json.dumps(row, separators=(",", ":")), flush=True)
        return row

    save_state()
    try:
        manifest = json.loads((HERE / "baseline/manifest.json").read_text())
        if manifest["baseline_commit"] != BASELINE_COMMIT:
            raise RuntimeError("Unexpected baseline commit")
        entry = manifest["file"]
        baseline = HERE / "baseline/NormalizedFileURL.swift"
        if git_blob(baseline) != entry["git_blob_sha"]:
            raise RuntimeError("Frozen baseline Git blob mismatch")
        snapshots = output / "sources"
        sources: dict[str, list[Path]] = {variant: [] for variant in VARIANTS}
        source_receipts = {}
        for variant in VARIANTS:
            folder = snapshots / variant
            folder.mkdir(parents=True)
            primary = baseline if variant == "baseline" else ROOT / entry["path"]
            for source in (primary, *(ROOT / path for path in SHARED)):
                copied = folder / source.name
                shutil.copyfile(source, copied)
                sources[variant].append(copied)
                source_receipts[f"{variant}/{source.name}"] = {
                    "sha256": digest(source), "git_blob_sha": git_blob(source),
                    "repository_path": str(source.relative_to(ROOT)),
                }
        support = snapshots / "qualification"
        support.mkdir()
        for source in (HERE / "Harness.swift", HERE / "run.py",
                       HERE / "baseline/manifest.json", CORPUS,
                       *(ROOT / "Tests/IlliquidCoreTests" / (name + ".swift") for name in TESTS)):
            shutil.copyfile(source, support / source.name)
            source_receipts[f"qualification/{source.name}"] = {"sha256": digest(source)}
        metadata = {
            "schema_version": 1, "baseline": manifest,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "candidate-commit").strip(),
            "candidate_status": run(["git", "status", "--short"], "candidate-status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift-version").strip(),
            "macos": run(["sw_vers"], "macos-version").strip(),
            "xcode": run(["xcodebuild", "-version"], "xcode-version").strip(),
            "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip(),
            "compiler_flags": FLAGS, "cross_module_optimization": False,
            "linkage": "Separate optimized dynamic modules and separately compiled identical driver",
            "source_sha256": source_receipts, "pairs": args.pairs, "target_ms": args.target_ms,
            "calibration": "Both variants calibrated; common count targets the faster variant. All rows retained.",
            "sampling": "Fresh processes; alternating AB/BA pairs; no outlier removal.",
            "scope": "Component wall time; URL preparation, playlist sorting, oracles and warmup excluded.",
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "kyoto_available": KYOTO.is_file(), "under_kyoto": args.under_kyoto,
        }

        def save_metadata() -> None:
            (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")

        save_metadata()
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
                    for name in (*TESTS, "NormalizedFileURLCorpus"):
                        shutil.copyfile(support / (name + ".swift"), tests / (name + ".swift"))
                    (work / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "NormalizedFileURLQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
""")
                    label = f"tests-{variant}-{configuration}"
                    result = run(["swift", "test", "--package-path", str(work),
                                  "--no-parallel", "-c", configuration], label)
                    counts = re.findall(r"Test run with (\d+) tests? in \d+ suites? passed", result)
                    receipt = {"variant": variant, "configuration": configuration, "passed": True,
                               "test_count": int(counts[-1]) if counts else None,
                               "log": f"logs/{label}.log"}
                    state["tests"].append(receipt)
                    print("TEST_PASS " + json.dumps(receipt, separators=(",", ":")), flush=True)
                    print("\n".join(result.splitlines()[-8:]), flush=True)
                    save_state()

        if args.mode in ("benchmark", "all"):
            executables = {}
            for variant in VARIANTS:
                work = output / "build" / variant
                work.mkdir(parents=True)
                library = work / "libIlliquidCore.dylib"
                run(["swiftc", *FLAGS, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
                     *(str(source) for source in sources[variant]), "-o", str(library)],
                    f"compile-{variant}-module")
                executable = work / "file-key-benchmark"
                run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                     str(support / "NormalizedFileURLCorpus.swift"),
                     str(support / "Harness.swift"), "-o", str(executable)],
                    f"compile-{variant}-driver")
                executables[variant] = executable
                metadata.setdefault("binary_sha256", {})[variant] = {
                    "library": digest(library), "driver": digest(executable),
                }
                save_metadata()

            verified = {}
            verification_dir = output / "verification"
            verification_dir.mkdir()
            for variant in VARIANTS:
                verified[variant] = json.loads(run([str(executables[variant]), "--verify"],
                                                   f"verify-{variant}"))
                (verification_dir / f"{variant}.json").write_text(
                    json.dumps(verified[variant], ensure_ascii=True, separators=(",", ":")) + "\n")
            if verified["baseline"] != verified["candidate"]:
                raise RuntimeError("Full baseline/candidate verification receipts differ")
            verification = verified["baseline"]
            if not 1000 <= len(verification["receipts"]) <= 10000:
                raise RuntimeError("Unexpected corpus size")
            state["verification"] = {
                "passed": True, "url_cases": len(verification["receipts"]),
                "constructor_failures": sum(row["constructorFailed"] for row in verification["receipts"]),
                "folder_workloads": len(verification["folderReceipts"]),
                "comparison": "Complete JSON receipts, including optional UTF-8 byte arrays",
                "baseline_sha256": digest(verification_dir / "baseline.json"),
                "candidate_sha256": digest(verification_dir / "candidate.json"),
            }
            print("VERIFICATION_PASS " + json.dumps(state["verification"], separators=(",", ":")), flush=True)
            save_state()
            del verified, verification
            workloads = json.loads(run([str(executables["baseline"]), "--list"], "list-baseline"))
            if workloads != json.loads(run([str(executables["candidate"]), "--list"], "list-candidate")):
                raise RuntimeError("Workload manifests differ")
            (output / "workloads.json").write_text(json.dumps(workloads, indent=2) + "\n")
            for workload in workloads:
                iterations = 1
                calibrated = False
                for trial in range(8):
                    order = VARIANTS if trial % 2 == 0 else tuple(reversed(VARIANTS))
                    rows = [observation(executables[v], workload, iterations, "calibration", v, trial, p)
                            for p, v in enumerate(order)]
                    fastest = min(row["elapsedMilliseconds"] for row in rows)
                    if fastest >= args.target_ms * 0.8:
                        calibrated = True
                        break
                    iterations = min(10_000_000, max(iterations + 1,
                        math.ceil(iterations * args.target_ms / max(fastest, 0.000001))))
                if not calibrated:
                    raise RuntimeError(f"Could not calibrate {workload['id']} to target interval")
                samples = {variant: [] for variant in VARIANTS}
                ratios = []
                faster = 0
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    paired = {}
                    receipts = {}
                    for position, variant in enumerate(order):
                        row = observation(executables[variant], workload, iterations,
                                          "measurement", variant, pair, position)
                        value = row["nanosecondsPerCall"]
                        samples[variant].append(value)
                        paired[variant] = value
                        receipts[variant] = (row["iterations"], row["checksum"], row["expectedChecksum"])
                    if receipts["baseline"] != receipts["candidate"]:
                        raise RuntimeError(f"Paired checksum mismatch: {workload['id']}")
                    ratios.append(paired["candidate"] / paired["baseline"])
                    faster += paired["candidate"] < paired["baseline"]
                before = statistics.median(samples["baseline"])
                after = statistics.median(samples["candidate"])
                summary = {
                    "workload": workload, "iterations": iterations, "pairs": args.pairs,
                    "baseline_median_ns": before, "candidate_median_ns": after,
                    "reduction_percent": 100 * (1 - after / before),
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                    "candidate_faster_pairs": faster,
                    "baseline_median_process_ms": before * iterations / 1_000_000,
                    "candidate_median_process_ms": after * iterations / 1_000_000,
                    "baseline_min_ns": min(samples["baseline"]),
                    "baseline_max_ns": max(samples["baseline"]),
                    "candidate_min_ns": min(samples["candidate"]),
                    "candidate_max_ns": max(samples["candidate"]),
                }
                state["summaries"].append(summary)
                print("BENCHMARK_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)
                save_state()
        state["status"] = "passed"
        save_state()
        print("QUALIFICATION_MANIFEST " + json.dumps(metadata, separators=(",", ":")), flush=True)
        print("QUALIFICATION_PASS " + json.dumps(state, separators=(",", ":")), flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        save_state()
        raise


if __name__ == "__main__":
    main()
