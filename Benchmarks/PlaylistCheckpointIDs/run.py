#!/usr/bin/env python3
"""Qualify shuffled checkpoint IDs against a frozen production baseline."""
from __future__ import annotations

import argparse
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
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PATHS = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
TESTS = [
    "PlaylistMutationTests", "PlaylistOrderRestorationTests",
    "NaturalFilenameOrderingTests", "FolderPlaylistTests",
]
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors"]
BASELINE_SHIM = r"""
extension PlaylistMutation {
    public static func restoringIDs(
        _ items: [FolderPlaylistItem], ids: [FolderPlaylistItem.ID]
    ) -> [FolderPlaylistItem.ID] {
        restoringOrder(items, ids: ids).map(\.id)
    }
}
"""


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--memory-pairs", type=int, default=4)
    parser.add_argument("--target-ms", type=int, default=100)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    args = parser.parse_args()
    if any(n < 2 or n % 2 for n in [args.pairs, args.memory_pairs]):
        parser.error("Pair counts must be even and at least two")
    if args.target_ms < 1:
        parser.error("--target-ms must be positive")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("--output must be empty or new")
    (out / "logs").mkdir()
    state = {"status": "running", "tests": [], "timing": [], "memory": []}
    manifest = {}

    def write(name, value):
        (out / name).write_text(json.dumps(value, indent=2) + "\n")

    def append(name, value):
        with (out / name).open("a") as handle:
            handle.write(json.dumps(value, separators=(",", ":")) + "\n")

    def run(command, label):
        command = [str(value) for value in command]
        started = time.time()
        append("commands.jsonl", {
            "event": "start", "label": label, "command": command,
            "cwd": str(ROOT), "started_unix": started,
        })
        process = subprocess.run(
            command, cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        (out / "logs" / f"{label}.stdout").write_text(process.stdout)
        (out / "logs" / f"{label}.stderr").write_text(process.stderr)
        append("commands.jsonl", {
            "event": "finish", "label": label, "exit_code": process.returncode,
            "wall_seconds": time.time() - started,
        })
        if process.returncode:
            raise RuntimeError(
                f"{label}: exit {process.returncode}\n"
                + process.stdout[-6000:] + process.stderr[-12000:]
            )
        return process.stdout

    def declaration(text, name):
        match = re.search(
            r"    (?:public static|private) func " + name
            + r"\([\s\S]*?\n    }\n", text
        )
        if not match:
            raise RuntimeError(f"Cannot locate {name} declaration")
        return match.group(0)

    write("summary.json", state)
    try:
        manifest.update({
            "baseline_commit": BASE,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "head").strip(),
            "candidate_status": run(["git", "status", "--short"], "status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift").strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "arguments": vars(args) | {"output": str(out)},
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "flags": FLAGS, "cross_module_optimization": False,
            "sampling": "Fresh process per variant/pair, alternating AB/BA",
            "scope": "Production identity projection, excluding fixture setup and validation",
            "autorelease_policy": "Each timed projection constructs and disposes inside one pool",
            "memory_scope": "Separate cold process, one projection, sampled live allocator peak",
            "sources": {},
        })
        native_flags = []
        sdk = None
        if sys.platform == "darwin":
            manifest["macos"] = run(["sw_vers"], "macos").strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode").strip()
            sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").strip()
            native_flags = ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
        manifest["native_flags"] = native_flags

        snapshots = {}
        for variant in VARIANTS:
            directory = out / "sources" / variant
            directory.mkdir(parents=True)
            snapshots[variant] = []
            for path in PATHS:
                destination = directory / Path(path).name
                if variant == "baseline":
                    destination.write_text(run(
                        ["git", "show", f"{BASE}:{path}"], f"freeze-{Path(path).stem}"
                    ))
                else:
                    shutil.copyfile(ROOT / path, destination)
                snapshots[variant].append(destination)
                manifest["sources"][f"{variant}/{destination.name}"] = {
                    "repository_path": path, "sha256": digest(destination),
                }
        old = out / "sources/baseline/PlaylistMutation.swift"
        new = out / "sources/candidate/PlaylistMutation.swift"
        if declaration(old.read_text(), "restoringOrder") != declaration(new.read_text(), "restoringOrder"):
            raise RuntimeError("Reference restoringOrder changed")
        for path in PATHS:
            name = Path(path).name
            if name != "PlaylistMutation.swift" and digest(out / "sources/baseline" / name) != digest(
                out / "sources/candidate" / name
            ):
                raise RuntimeError(f"Shared support source changed: {name}")

        # Tie the experiment to the actual main-actor caller, not an unused API.
        controller_path = "Sources/IlliquidPlayer/Player/PlaybackController.swift"
        old_controller = run(["git", "show", f"{BASE}:{controller_path}"], "freeze-controller")
        old_call = declaration(old_controller, "checkpointSession")
        new_call = declaration((ROOT / controller_path).read_text(), "checkpointSession")
        old_expression = (
            "PlaylistMutation.restoringOrder(\n"
            "                state.playlist, ids: unshuffledPlaylistIDs ?? []\n"
            "            ).map(\\.id)"
        )
        new_expression = (
            "PlaylistMutation.restoringIDs(\n"
            "                state.playlist, ids: unshuffledPlaylistIDs ?? []\n"
            "            )"
        )
        if old_call.count(old_expression) != 1 or new_call != old_call.replace(old_expression, new_expression):
            raise RuntimeError("Checkpoint caller differs beyond the qualified projection replacement")
        manifest["controller_sha256"] = digest(ROOT / controller_path)

        support = out / "sources/qualification"
        support.mkdir()
        for name in ["Harness.swift", "MemoryProbe.c", "MemoryProbe.h", "run.py"]:
            shutil.copyfile(HERE / name, support / name)
            manifest["sources"][f"qualification/{name}"] = {"sha256": digest(support / name)}
        for name in TESTS:
            source = ROOT / "Tests/IlliquidCoreTests" / f"{name}.swift"
            shutil.copyfile(source, support / source.name)
            manifest["sources"][f"qualification/{source.name}"] = {"sha256": digest(source)}
        write("manifest.json", manifest)

        if args.mode in ("all", "tests"):
            for variant in VARIANTS:
                package = out / "build" / f"tests-{variant}"
                sources = package / "Sources/IlliquidCore"
                tests = package / "Tests/IlliquidCoreTests"
                sources.mkdir(parents=True)
                tests.mkdir(parents=True)
                for source in snapshots[variant]:
                    shutil.copyfile(source, sources / source.name)
                if variant == "baseline":
                    # Tests only: expose the old caller expression under the new API.
                    # This shim is NOT included in the benchmark module.
                    (sources / "BaselineProjection.swift").write_text(BASELINE_SHIM)
                for name in TESTS:
                    shutil.copyfile(support / f"{name}.swift", tests / f"{name}.swift")
                (package / "Package.swift").write_text(
                    '// swift-tools-version: 6.1\nimport PackageDescription\n'
                    'let package = Package(name: "CheckpointIDQualification", targets: [\n'
                    '    .target(name: "IlliquidCore"),\n'
                    '    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),\n'
                    '])\n'
                )
                for configuration in ("debug", "release"):
                    label = f"tests-{variant}-{configuration}"
                    run(["swift", "test", "--package-path", package, "--no-parallel",
                         "-c", configuration], label)
                    logs = "".join((out / "logs" / f"{label}.{stream}").read_text()
                                   for stream in ("stdout", "stderr"))
                    matches = re.findall(r"Test run with (\d+) tests(?: in (\d+) suites)? passed", logs)
                    if not matches or int(matches[-1][0]) == 0:
                        raise RuntimeError(f"No successful nonempty test receipt: {label}")
                    receipt = dict(variant=variant, configuration=configuration,
                                   count=int(matches[-1][0]), exit_code=0)
                    state["tests"].append(receipt)
                    write("summary.json", state)
                    print("TEST_RESULT " + json.dumps(receipt), flush=True)

        if args.mode == "tests":
            state["status"] = "passed"
            return

        executables = {}
        for variant in VARIANTS:
            build = out / "build" / variant
            build.mkdir(parents=True)
            flags = FLAGS + native_flags + ["-module-cache-path", str(build / "module-cache")]
            extension = "dylib" if sys.platform == "darwin" else "so"
            library = build / f"libIlliquidCore.{extension}"
            run([
                "swiftc", *flags, "-emit-library", "-emit-module",
                "-module-name", "IlliquidCore",
                "-emit-module-path", build / "IlliquidCore.swiftmodule",
                *snapshots[variant], "-o", library,
            ], f"build-{variant}-module")
            probe_flags = []
            if sdk:
                probe = build / "MemoryProbe.o"
                run(["clang", "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror",
                     "-isysroot", sdk, "-mmacosx-version-min=26.0",
                     "-c", support / "MemoryProbe.c", "-o", probe],
                    f"build-{variant}-probe")
                probe_flags = ["-import-objc-header", str(support / "MemoryProbe.h"), str(probe)]
            executable = build / "checkpoint-ids"
            defines = ["-D", "CANDIDATE"] if variant == "candidate" else []
            run([
                "swiftc", *flags, *defines, "-parse-as-library",
                "-I", build, "-L", build, "-lIlliquidCore",
                "-Xlinker", "-rpath", "-Xlinker", build,
                *probe_flags, support / "Harness.swift", "-o", executable,
            ], f"build-{variant}-driver")
            executables[variant] = executable
            manifest.setdefault("binaries", {})[variant] = {
                "library_sha256": digest(library), "driver_sha256": digest(executable),
            }
        write("manifest.json", manifest)
        workloads = json.loads(run([executables["baseline"], "--list"], "workloads-baseline"))
        if workloads != json.loads(run([executables["candidate"], "--list"], "workloads-candidate")):
            raise RuntimeError("Workload manifests differ")
        write("workloads.json", workloads)

        def observation(variant, workload, iterations, mode, label, phase, **metadata):
            row = json.loads(run([executables[variant], mode, workload, iterations], label))
            if row["workload"] != workload or row["mode"] != mode:
                raise RuntimeError("Observation identity mismatch")
            if not row["receipt"]["complete_array_equality"] or not row["receipt"]["utf8_equality"]:
                raise RuntimeError("Incomplete identity verification")
            row.update(variant=variant, phase=phase, **metadata)
            append("observations.jsonl", row)
            return row

        for workload in workloads:
            identifier = f'{workload["count"]}-{workload["scenario"]}'
            receipts = {}
            for variant in VARIANTS:
                row = observation(variant, identifier, 1, "verify",
                                  f"verify-{identifier}-{variant}", "verification")
                receipts[variant] = row["receipt"]
            if receipts["baseline"] != receipts["candidate"]:
                raise RuntimeError(f"Cross-variant output mismatch: {identifier}")

            # Calibrate both implementations, and use the same count in every pair.
            iterations = 10_000 if workload["count"] <= 1 else 1
            for trial in range(4):
                pilots = [
                    observation(v, identifier, iterations, "timing",
                                f"calibrate-{identifier}-{trial}-{v}", "calibration", trial=trial)
                    for v in VARIANTS
                ]
                fastest = min(min(row["wall_nanoseconds"], row["cpu_nanoseconds"]) for row in pilots)
                if fastest >= args.target_ms * 800_000 or iterations >= 2_000_000:
                    break
                iterations = min(2_000_000, max(
                    iterations + 1, math.ceil(iterations * args.target_ms * 1_000_000 / max(fastest, 1))
                ))
            samples = {v: [] for v in VARIANTS}
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                for position, variant in enumerate(order):
                    row = observation(
                        variant, identifier, iterations, "timing",
                        f"timing-{identifier}-{pair}-{variant}", "measurement",
                        pair=pair, position_in_pair=position,
                    )
                    if row["iterations"] != iterations or row["receipt"] != receipts[variant]:
                        raise RuntimeError("Measured result differs from verification")
                    samples[variant].append(row)
                if samples["baseline"][-1]["checksum"] != samples["candidate"][-1]["checksum"]:
                    raise RuntimeError("Paired checksum differs")
            summary = dict(workload=identifier, iterations=iterations, pairs=args.pairs)
            for metric in ("wall", "cpu"):
                key = f"{metric}_nanoseconds"
                values = {v: [r[key] / iterations for r in samples[v]] for v in VARIANTS}
                ratios = [c[key] / b[key] for b, c in zip(samples["baseline"], samples["candidate"])]
                summary[metric] = {
                    "baseline_median_ns": statistics.median(values["baseline"]),
                    "candidate_median_ns": statistics.median(values["candidate"]),
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                    "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
                    "baseline_samples_ns": values["baseline"],
                    "candidate_samples_ns": values["candidate"],
                    "duration_qualified": all(r[key] >= args.target_ms * 250_000
                                              for v in VARIANTS for r in samples[v]),
                }
            state["timing"].append(summary)
            write("summary.json", state)
            print("TIMING_RESULT " + json.dumps(summary), flush=True)

            # Predeclared memory cohort plus an empty-call observer floor.
            memory_case = (
                identifier == "0-empty" or
                workload["count"] >= 1_000 and workload["scenario"] in ("empty", "unchanged", "duplicates")
            )
            if sys.platform == "darwin" and memory_case:
                memory = {v: [] for v in VARIANTS}
                for pair in range(args.memory_pairs):
                    order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                    for position, variant in enumerate(order):
                        row = observation(
                            variant, identifier, 1, "memory",
                            f"memory-{identifier}-{pair}-{variant}", "memory",
                            pair=pair, position_in_pair=position,
                        )
                        if row["receipt"] != receipts[variant] or row["memory"]["sample_count"] < 2:
                            raise RuntimeError("Invalid memory receipt")
                        memory[variant].append(row["memory"])
                memory_summary = dict(workload=identifier, pairs=args.memory_pairs)
                for variant in VARIANTS:
                    memory_summary[variant] = {
                        "sampled_peak_extra_median_bytes": statistics.median(
                            r["sampled_peak_extra_bytes"] for r in memory[variant]),
                        "sampled_peak_extra_samples_bytes": [
                            r["sampled_peak_extra_bytes"] for r in memory[variant]],
                        "minimum_sample_count": min(r["sample_count"] for r in memory[variant]),
                        "maximum_sample_gap_ns": max(r["maximum_sample_gap_ns"] for r in memory[variant]),
                    }
                memory_summary["median_paired_extra_bytes_reduction"] = statistics.median(
                    b["sampled_peak_extra_bytes"] - c["sampled_peak_extra_bytes"]
                    for b, c in zip(memory["baseline"], memory["candidate"])
                )
                state["memory"].append(memory_summary)
                write("summary.json", state)
                print("MEMORY_RESULT " + json.dumps(memory_summary), flush=True)
        state["status"] = "passed"
        print("QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        state.update(status="failed", error=f"{type(error).__name__}: {error}")
        raise
    finally:
        write("manifest.json", manifest)
        write("summary.json", state)


if __name__ == "__main__":
    main()
