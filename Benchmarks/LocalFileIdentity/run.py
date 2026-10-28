#!/usr/bin/env python3
"""Compare exact production file-identity sources in isolated native processes."""
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
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TARGET = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
SOURCES = [
    TARGET,
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
]
TESTS = [
    "NormalizedFileIdentityTests",
    "LocalMediaSourceValidationTests",
    "PlaylistIdentityLookupTests",
    "FolderPlaylistLookupTests",
    "PlaylistMutationTests",
    "PlaylistOrderRestorationTests",
    "FolderPlaylistTests",
]
VARIANTS = ("baseline", "candidate")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, separators=(",", ":")) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=int, default=60)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    args = parser.parse_args()
    if not 2 <= args.pairs <= 30 or args.pairs % 2 or not 10 <= args.target_ms <= 1000:
        parser.error("Use an even pair count in 2...30 and target-ms in 10...1000")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be new or empty")
    (output / "logs").mkdir()
    state = {"status": "running", "tests": [], "summaries": []}
    manifest = {
        "schema": 1, "baseline_commit": BASELINE, "target": TARGET,
        "platform": platform.platform(), "machine": platform.machine(),
        "pairs": args.pairs, "target_ms": args.target_ms,
        "sampling": "Fresh process per observation; balanced AB/BA; one shared iteration count per workload.",
        "calibration": "Both variants calibrated; use larger count; retain all trials; exclude trials from summary.",
        "scope": "Warm component wall time; preparation, byte checks and process startup excluded.",
        "source_hashes": {}, "binary_hashes": {},
    }
    environment = os.environ.copy()
    environment.update(
        CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
        SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
        SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
        TERM="dumb", NO_COLOR="1",
    )
    command_index = 0

    def run(command: list, label: str, timeout: int = 600) -> str:
        nonlocal command_index
        command = [str(arg) for arg in command]
        command_index += 1
        log = f"logs/{command_index:04d}-{label}.log"
        started = time.time()
        append(output / "commands.jsonl", {
            "event": "start", "label": label, "command": command,
            "log": log, "started_unix": started,
        })
        result = subprocess.run(command, cwd=ROOT, env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        text = result.stdout.decode()
        errors = result.stderr.decode()
        (output / log).write_text(text + errors)
        append(output / "commands.jsonl", {
            "event": "finish", "label": label, "returncode": result.returncode,
            "seconds": time.time() - started, "log": log,
        })
        if result.returncode:
            print((text + errors)[-20000:], flush=True)
            raise RuntimeError(f"{label} failed ({result.returncode}); see {log}")
        return text

    def record_state() -> None:
        save(output / "summary.json", state)

    record_state()
    try:
        manifest["candidate_commit"] = run(["git", "rev-parse", "HEAD"], "head").strip()
        manifest["candidate_status"] = run(["git", "status", "--porcelain=v1"], "status").splitlines()
        manifest["compiler"] = run([args.swiftc, "--version"], "compiler").strip()
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors"]
        if platform.system() == "Darwin":
            sdk = run(["xcrun", "--show-sdk-path"], "sdk").strip()
            flags += ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
            manifest["macos"] = run(["sw_vers"], "macos").strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode").strip()
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        manifest["compiler_flags"] = flags
        manifest["separate_dynamic_module_without_cross_module_optimization"] = True
        staged = {}
        for variant in VARIANTS:
            destination = output / "sources" / variant
            destination.mkdir(parents=True)
            staged[variant] = []
            manifest["source_hashes"][variant] = {}
            for source in SOURCES:
                data = (run(["git", "show", f"{BASELINE}:{source}"], f"baseline-{Path(source).stem}").encode()
                        if variant == "baseline" else (ROOT / source).read_bytes())
                copied = destination / Path(source).name
                copied.write_bytes(data)
                staged[variant].append(copied)
                manifest["source_hashes"][variant][source] = digest(data)
        differences = [source for source in SOURCES
                       if manifest["source_hashes"]["baseline"][source]
                       != manifest["source_hashes"]["candidate"][source]]
        if differences != [TARGET]:
            raise RuntimeError(f"Expected exactly one changed production source; got {differences}")
        support = output / "sources" / "qualification"
        support.mkdir()
        support_inputs = [HERE / "Harness.swift", HERE / "run.py",
                          *(ROOT / "Tests/IlliquidCoreTests" / f"{name}.swift" for name in TESTS)]
        manifest["qualification_hashes"] = {}
        for source in support_inputs:
            shutil.copyfile(source, support / source.name)
            manifest["qualification_hashes"][str(source.relative_to(ROOT))] = digest(source.read_bytes())
        save(output / "manifest.json", manifest)

        if args.mode in ("all", "tests"):
            for variant in VARIANTS:
                package = output / "build" / f"tests-{variant}"
                src, tests = package / "Sources/IlliquidCore", package / "Tests/IlliquidCoreTests"
                src.mkdir(parents=True)
                tests.mkdir(parents=True)
                for source in staged[variant]:
                    shutil.copyfile(source, src / source.name)
                for name in TESTS:
                    shutil.copyfile(support / f"{name}.swift", tests / f"{name}.swift")
                (package / "Package.swift").write_text(
                    '// swift-tools-version: 6.1\nimport PackageDescription\n'
                    'let package = Package(name: "FileIdentityQualification", platforms: [.macOS("26.0")], '
                    'targets: [.target(name: "IlliquidCore"), '
                    '.testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])], '
                    'swiftLanguageModes: [.v6])\n')
                for configuration in ("debug", "release"):
                    command = [args.swift, "test", "--package-path", package,
                               "--no-parallel", "--jobs", "2", "-c", configuration,
                               "-Xswiftc", "-warnings-as-errors"]
                    if platform.system() == "Linux":
                        command += ["--use-integrated-swift-driver"]
                    label = f"tests-{variant}-{configuration}"
                    logs = run(command, label)
                    state["tests"].append({"variant": variant, "configuration": configuration, "passed": True})
                    print("TEST_PASS " + variant + " " + configuration, flush=True)
                    print("\n".join(logs.splitlines()[-5:]), flush=True)
                    record_state()

        if args.mode in ("all", "benchmark"):
            executables = {}
            for variant in VARIANTS:
                build = output / "build" / variant
                build.mkdir(parents=True)
                extension = "dylib" if platform.system() == "Darwin" else "so"
                library = build / f"libIlliquidCore.{extension}"
                run([args.swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", build / "IlliquidCore.swiftmodule",
                     *staged[variant], "-o", library], f"compile-{variant}-module")
                executable = build / "identity-benchmark"
                run([args.swiftc, *flags, "-parse-as-library", "-I", build, "-L", build,
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", build,
                     support / "Harness.swift", "-o", executable], f"compile-{variant}-driver")
                executables[variant] = executable
                manifest["binary_hashes"][variant] = {
                    "library": digest(library.read_bytes()), "driver": digest(executable.read_bytes())}
            save(output / "manifest.json", manifest)
            workloads = json.loads(run([executables["baseline"], "--list"], "baseline-list"))
            if workloads != json.loads(run([executables["candidate"], "--list"], "candidate-list")):
                raise RuntimeError("Workload inventories differ")
            save(output / "workloads.json", workloads)
            semantic = run([executables["baseline"], "--verify"], "baseline-semantics")
            candidate_semantic = run([executables["candidate"], "--verify"], "candidate-semantics")
            if semantic != candidate_semantic:
                raise RuntimeError("Complete semantic receipts differ")
            (output / "semantics.json").write_text(semantic)
            state["semantic_bytes_equal"] = True
            state["semantic_sha256"] = digest(semantic.encode())
            record_state()

            def observe(variant: str, workload: dict, iterations: int, label: str) -> dict:
                row = json.loads(run([executables[variant], workload["id"], iterations], label))
                if row["workload"] != workload or row["iterations"] != iterations:
                    raise RuntimeError("Workload/iteration receipt mismatch")
                if row["checksum"] != row["expectedChecksum"] or row["elapsedNanoseconds"] <= 0:
                    raise RuntimeError("Incorrect checksum or invalid duration")
                row["variant"] = variant
                return row

            calibrated = {}
            for workload in workloads:
                counts = []
                for variant in VARIANTS:
                    iterations = 1
                    for trial in range(8):
                        row = observe(variant, workload, iterations, f"calibrate-{workload['id']}-{variant}-{trial}")
                        row.update(phase="calibration", trial=trial)
                        append(output / "observations.jsonl", row)
                        if row["elapsedNanoseconds"] >= args.target_ms * 1_000_000 or iterations >= 10_000_000:
                            break
                        iterations = min(10_000_000, max(iterations + 1, math.ceil(
                            iterations * args.target_ms * 1_000_000 / row["elapsedNanoseconds"])))
                    counts.append(row["iterations"])
                calibrated[workload["id"]] = max(counts)
            save(output / "calibration.json", calibrated)
            samples = []
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                scenarios = workloads if pair % 2 == 0 else list(reversed(workloads))
                for workload in scenarios:
                    receipts = []
                    for variant in order:
                        row = observe(variant, workload, calibrated[workload["id"]],
                                      f"measure-{pair}-{workload['id']}-{variant}")
                        row.update(phase="measurement", pair=pair, order=list(order))
                        append(output / "observations.jsonl", row)
                        samples.append(row)
                        receipts.append((row["checksum"], row["expectedChecksum"], row["iterations"]))
                        print("IDENTITY_OBSERVATION " + json.dumps(row, separators=(",", ":")), flush=True)
                    if receipts[0] != receipts[1]:
                        raise RuntimeError("Paired result receipts differ")
            for workload in workloads:
                rows = [r for r in samples if r["workload"] == workload]
                expected = {(v, p) for v in VARIANTS for p in range(args.pairs)}
                if len(rows) != len(expected) or {(r["variant"], r["pair"]) for r in rows} != expected:
                    raise RuntimeError("Incomplete or duplicated pairs")
                values = {v: [next(r["nanosecondsPerOperation"] for r in rows
                                   if r["variant"] == v and r["pair"] == p)
                              for p in range(args.pairs)] for v in VARIANTS}
                medians = {v: statistics.median(values[v]) for v in VARIANTS}
                reductions = [100 * (1 - b / a) for a, b in zip(values["baseline"], values["candidate"])]
                summary = {
                    "workload": workload, "pairs": args.pairs, "iterations": calibrated[workload["id"]],
                    "baseline_median_ns": medians["baseline"], "candidate_median_ns": medians["candidate"],
                    "reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                    "paired_reduction_median_percent": statistics.median(reductions),
                    "paired_reduction_range_percent": [min(reductions), max(reductions)],
                    "candidate_faster_pairs": sum(b < a for a, b in zip(values["baseline"], values["candidate"])),
                    "baseline_range_ns": [min(values["baseline"]), max(values["baseline"])],
                    "candidate_range_ns": [min(values["candidate"]), max(values["candidate"])],
                }
                state["summaries"].append(summary)
                print("IDENTITY_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)
                record_state()
        for variant in VARIANTS:
            for source, snapshot in zip(SOURCES, staged[variant]):
                if digest(snapshot.read_bytes()) != manifest["source_hashes"][variant][source]:
                    raise RuntimeError("A staged production source changed during the run")
                if variant == "candidate" and digest((ROOT / source).read_bytes()) != digest(snapshot.read_bytes()):
                    raise RuntimeError("A candidate production source changed during the run")
        for source in support_inputs:
            if digest(source.read_bytes()) != manifest["qualification_hashes"][str(source.relative_to(ROOT))]:
                raise RuntimeError("Qualification input changed during the run")
        state["status"] = "passed"
        record_state()
        print("IDENTITY_MANIFEST " + json.dumps(manifest, separators=(",", ":")), flush=True)
        print("QUALIFICATION_PASS " + json.dumps({
            "tests": state["tests"], "workloads": len(state["summaries"]),
            "semantic_sha256": state.get("semantic_sha256"),
        }, separators=(",", ":")), flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        record_state()
        raise


if __name__ == "__main__":
    main()
