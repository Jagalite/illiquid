#!/usr/bin/env python3
"""Compare exact file-identity implementations in isolated Swift modules/processes."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TARGET = "Utilities/NormalizedFileURL.swift"
COMMON = [
    "Playlist/FolderPlaylist.swift", "Playlist/PlaylistMutation.swift",
    "Utilities/NaturalFilenameOrdering.swift", "Utilities/MediaFileSupport.swift",
    "Player/MediaSource.swift",
]
TESTS = [
    "LocalMediaSourceValidationTests", "UtilitiesTests", "FolderPlaylistTests",
    "FolderPlaylistLookupTests", "PlaylistMutationTests", "PlaylistOrderRestorationTests",
    "PlaylistIdentityLookupTests", "PlaylistDeduplicationTests", "NaturalFilenameOrderingTests",
]
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6"]


def hashes(data: bytes) -> dict:
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "git_blob_sha1": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=75)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    parser.add_argument("--case", action="append", dest="cases")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be empty")
    logs = output / "logs"
    logs.mkdir()
    state = {"status": "running", "tests": [], "cases": []}
    observations = []
    commands = []
    manifest = {}

    def write(name, value):
        (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def append(name, value):
        with (output / name).open("a") as handle:
            handle.write(json.dumps(value, sort_keys=True) + "\n")

    def run(command, label):
        started = time.monotonic()
        receipt = {"label": label, "command": list(map(str, command)), "cwd": str(ROOT)}
        append("commands.jsonl", {"event": "start", **receipt})
        log = logs / (label + ".log")
        print("COMMAND " + label, flush=True)
        with log.open("w") as handle:
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=handle,
                                    stderr=subprocess.STDOUT, check=False)
        receipt.update(exit_code=result.returncode, elapsed_seconds=time.monotonic() - started,
                       log_sha256=hashes(log.read_bytes())["sha256"])
        commands.append(receipt)
        append("commands.jsonl", {"event": "finish", **receipt})
        content = log.read_text()
        if result.returncode:
            print(content[-30000:], flush=True)
            raise RuntimeError(f"{label} failed ({result.returncode})")
        return content.strip()

    try:
        frozen = (HERE / "baseline/NormalizedFileURL.swift").read_bytes()
        baseline = json.loads((HERE / "baseline/manifest.json").read_text())
        if hashes(frozen)["git_blob_sha1"] != baseline["git_blob_sha1"]:
            raise RuntimeError("frozen baseline blob mismatch")
        source_dir = output / "sources"
        sources = {}
        identities = {}
        for variant in VARIANTS:
            folder = source_dir / variant
            folder.mkdir(parents=True)
            sources[variant] = []
            for relative in [TARGET, *COMMON]:
                data = frozen if variant == "baseline" and relative == TARGET else (ROOT / "Sources/IlliquidCore" / relative).read_bytes()
                path = folder / Path(relative).name
                path.write_bytes(data)
                sources[variant].append(path)
                identities[f"{variant}/{relative}"] = hashes(data)
        support = source_dir / "support"
        support.mkdir()
        for source in [HERE / "Harness.swift", HERE / "run.py", HERE / "baseline/manifest.json",
                       *(ROOT / "Tests/IlliquidCoreTests" / (test + ".swift") for test in TESTS)]:
            shutil.copyfile(source, support / source.name)
            identities[f"support/{source.name}"] = hashes(source.read_bytes())
        manifest = {
            "schema_version": 1, "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "baseline": baseline, "head": run(["git", "rev-parse", "HEAD"], "head"),
            "git_status": run(["git", "status", "--short"], "status"),
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(), "swift": run(["swiftc", "--version"], "swift"),
            "compiler_flags": FLAGS, "source_hashes": identities,
            "pairs": args.pairs, "target_ms": args.target_ms,
            "method": "Separate optimized production module; fresh process per case/variant/pair; balanced AB/BA order; shared calibrated iterations.",
            "scope": "In-memory key lookup and playlist component wall/CPU time; no disk, UI, decode or whole-player claims.",
            "environment": {key: os.environ.get(key) for key in ("LANG", "LC_ALL", "DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING")},
        }
        if sys.platform == "darwin":
            manifest["macos"] = run(["sw_vers"], "macos")
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode")
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu")
        write("manifest.json", manifest)

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
                    for test in TESTS:
                        shutil.copyfile(support / (test + ".swift"), tests / (test + ".swift"))
                    (work / "Package.swift").write_text(
                        '// swift-tools-version: 6.1\nimport PackageDescription\n'
                        'let package = Package(name: "FileIdentityQualification", targets: [\n'
                        '    .target(name: "IlliquidCore"),\n'
                        '    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),\n'
                        '])\n'
                    )
                    label = f"tests-{variant}-{configuration}"
                    content = run(["swift", "test", "--package-path", str(work), "--no-parallel",
                                   "--jobs", "2", "-c", configuration], label)
                    counts = re.findall(r"Test run with (\d+) tests.*?passed", content)
                    if not counts or int(counts[-1]) == 0:
                        raise RuntimeError(f"{label} did not execute Swift Testing tests")
                    result = {"variant": variant, "configuration": configuration, "count": int(counts[-1]),
                              "passed": True, "log": f"logs/{label}.log", "log_sha256": commands[-1]["log_sha256"]}
                    state["tests"].append(result)
                    print("FILE_IDENTITY_TEST " + json.dumps(result, sort_keys=True), flush=True)
                    write("summary.json", state)

        if args.mode in ("all", "benchmark"):
            executables = {}
            for variant in VARIANTS:
                work = output / "build" / variant
                work.mkdir(parents=True)
                extension = "dylib" if sys.platform == "darwin" else "so"
                library = work / f"libIlliquidCore.{extension}"
                run(["swiftc", *FLAGS, "-parse-as-library", "-emit-library", "-emit-module",
                     "-module-name", "IlliquidCore", "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
                     *map(str, sources[variant]), "-o", str(library)], f"compile-{variant}-module")
                executable = work / "file-identity"
                run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                     str(support / "Harness.swift"), "-o", str(executable)], f"compile-{variant}-driver")
                executables[variant] = executable
                manifest.setdefault("binary_hashes", {})[variant] = {
                    "library": hashes(library.read_bytes()), "driver": hashes(executable.read_bytes()),
                }
            available = {v: json.loads(run([str(executables[v]), "--list"], f"cases-{v}")) for v in VARIANTS}
            if available["baseline"] != available["candidate"]:
                raise RuntimeError("case lists differ")
            cases = args.cases or available["baseline"]
            if len(set(cases)) != len(cases) or any(case not in available["baseline"] for case in cases):
                raise RuntimeError("duplicate or unknown case")
            manifest["cases"] = cases
            write("manifest.json", manifest)

            def measure(variant, case, iterations, label):
                row = json.loads(run([str(executables[variant]), case, str(iterations)], label))
                if (row["case"] != case or row["iterations"] != iterations or row["wall_ns"] <= 0
                        or row["cpu_ns"] < 0 or row["operations_per_iteration"] <= 0):
                    raise RuntimeError(f"invalid sample: {label}")
                return {"variant": variant, **row, "command_label": label}

            for case in cases:
                iterations = 1
                for attempt in range(12):
                    pair = []
                    for variant in VARIANTS:
                        row = measure(variant, case, iterations, f"calibrate-{case}-{attempt}-{variant}")
                        append("calibration.jsonl", row)
                        pair.append(row)
                    if pair[0]["receipt"] != pair[1]["receipt"] or pair[0]["sink"] != pair[1]["sink"]:
                        raise RuntimeError(f"calibration parity failure: {case}")
                    fastest = min(row["wall_ns"] for row in pair)
                    if fastest >= args.target_ms * 1_000_000:
                        break
                    iterations = max(iterations + 1, math.ceil(iterations * args.target_ms * 1_000_000 / fastest * 1.15))
                else:
                    raise RuntimeError(f"failed to calibrate {case}")
                rows = []
                for sample in range(args.pairs):
                    order = VARIANTS if sample % 2 == 0 else tuple(reversed(VARIANTS))
                    pair = []
                    for variant in order:
                        row = measure(variant, case, iterations, f"sample-{case}-{sample}-{variant}")
                        row["pair"] = sample
                        row["order"] = list(order)
                        rows.append(row)
                        observations.append(row)
                        append("observations.jsonl", row)
                        print("FILE_IDENTITY_OBSERVATION " + json.dumps(row, sort_keys=True), flush=True)
                        pair.append(row)
                    if (pair[0]["receipt"] != pair[1]["receipt"] or pair[0]["sink"] != pair[1]["sink"]
                            or pair[0]["operations_per_iteration"] != pair[1]["operations_per_iteration"]):
                        raise RuntimeError(f"timed parity failure: {case}/{sample}")
                if len({row["receipt"] for row in rows}) != 1:
                    raise RuntimeError(f"unstable receipt: {case}")
                values = {}
                for variant in VARIANTS:
                    values[variant] = {}
                    for metric in ("wall_ns", "cpu_ns"):
                        samples = [row[metric] / (row["iterations"] * row["operations_per_iteration"])
                                   for row in rows if row["variant"] == variant]
                        values[variant][metric + "_per_operation"] = {
                            "median": statistics.median(samples), "min": min(samples), "max": max(samples),
                        }
                reductions = []
                for sample in range(args.pairs):
                    pair = {row["variant"]: row for row in rows if row["pair"] == sample}
                    reductions.append(100 * (1 - pair["candidate"]["wall_ns"] / pair["baseline"]["wall_ns"]))
                summary = {"case": case, "iterations": iterations, "pairs": args.pairs, **values,
                           "paired_wall_reduction_percent": {"median": statistics.median(reductions),
                                                              "min": min(reductions), "max": max(reductions)},
                           "candidate_faster_pairs": sum(value > 0 for value in reductions)}
                state["cases"].append(summary)
                write("summary.json", state)
                print("FILE_IDENTITY_CASE " + json.dumps(summary, sort_keys=True), flush=True)
            persisted = [json.loads(line) for line in (output / "observations.jsonl").read_text().splitlines()]
            if persisted != observations or len(observations) != len(cases) * args.pairs * 2:
                raise RuntimeError("persisted observation set is incomplete")
        state["status"] = "passed"
        state["observation_count"] = len(observations)
        write("summary.json", state)
        write("manifest.json", manifest)
        print("FILE_IDENTITY_MANIFEST " + json.dumps(manifest, sort_keys=True), flush=True)
        print("FILE_IDENTITY_SUMMARY " + json.dumps(state, sort_keys=True), flush=True)
    except Exception as error:
        state.update(status="failed", error=str(error))
        write("summary.json", state)
        print("FILE_IDENTITY_FAILURE " + json.dumps(state, sort_keys=True), flush=True)
        raise


if __name__ == "__main__":
    main()
