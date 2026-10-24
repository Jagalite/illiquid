#!/usr/bin/env python3
"""Qualify actual playlist/session code against a pinned pre-change revision."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCES = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
]
TESTS = [
    "PlaylistDeduplicationTests.swift", "PlaylistSessionRecordTests.swift",
    "PlaylistMutationTests.swift", "PlaylistOrderRestorationTests.swift",
    "FolderPlaylistTests.swift", "NaturalFilenameOrderingTests.swift",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def cases(quick):
    sizes = [0, 1, 32, 1000] if quick else [0, 1, 32, 1000, 10000, 50000]
    duplicates = [1000] if quick else [1000, 10000]
    result = []
    for scope in ["deduplicate", "session"]:
        for size, pattern in [(n, "unique") for n in sizes] + [(n, "sparse") for n in [0, 1, 32, 1000]] + [
            (n, p) for n in duplicates for p in ["early", "late", "fourfold", "all"]
        ]:
            result.append(dict(id=f"{scope}/{pattern}/{size}", scope=scope,
                               pattern=pattern, count=size))
    return result


class Run:
    def __init__(self, output):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.number = 0

    def command(self, args, *, cwd=ROOT, env=None, label="command"):
        self.number += 1
        log = self.logs / f"{self.number:04d}-{label}.log"
        start = time.monotonic()
        completed = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_bytes(completed.stdout)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(args=[str(a) for a in args], cwd=str(cwd),
                log=str(log.relative_to(self.output)), returncode=completed.returncode,
                elapsed_seconds=time.monotonic() - start)) + "\n")
        if completed.returncode:
            raise RuntimeError(f"Command failed ({completed.returncode}); see {log}")
        return completed.stdout.decode().strip()


def snapshots(run, manifest):
    outputs = {}
    for variant in ["baseline", "candidate"]:
        directory = run.output / "sources" / variant
        directory.mkdir(parents=True)
        exported = []
        manifest[variant + "_sources"] = {}
        for path in SOURCES:
            raw = (subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                   if variant == "baseline" else (ROOT / path).read_bytes())
            data = raw
            # Compile the complete production record type verbatim. The rest of
            # this file is disk I/O and macOS signposting, outside this study.
            if path.endswith("PlaybackSessionStore.swift"):
                marker = b"\npublic protocol PlaybackSessionStoring: Sendable {"
                if raw.count(marker) != 1:
                    raise RuntimeError("PlaybackSessionRecord extraction boundary changed")
                data = raw.split(marker)[0] + b"\n"
            destination = directory / Path(path).name
            destination.write_bytes(data)
            exported.append(destination)
            manifest[variant + "_sources"][path] = dict(
                full_sha256=digest(raw), compiled_sha256=digest(data))
        outputs[variant] = exported
    for path in SOURCES:
        if path.endswith("PlaylistMutation.swift"):
            continue
        if manifest["baseline_sources"][path] != manifest["candidate_sources"][path]:
            raise RuntimeError(f"Unrelated benchmark dependency changed: {path}")
    for name in ["Driver.swift", "MemoryProbe.c", "run.py"]:
        data = (HERE / name).read_bytes()
        (run.output / "sources" / name).write_bytes(data)
        manifest[name + "_sha256"] = digest(data)
    return outputs


def tests(run, sources, swift, summary, manifest):
    summary["tests"] = []
    manifest["test_sha256"] = {}
    for variant, files in sources.items():
        package = run.output / "build" / (variant + "-tests")
        source_dir = package / "Sources" / "IlliquidCore"
        test_dir = package / "Tests" / "IlliquidCoreTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        for source in files:
            shutil.copy2(source, source_dir)
        for name in TESTS:
            source = ROOT / "Tests" / "IlliquidCoreTests" / name
            shutil.copy2(source, test_dir)
            manifest["test_sha256"][name] = digest(source.read_bytes())
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlaylistDeduplicationQualification",
    platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
''')
        env = os.environ.copy()
        env["CLANG_MODULE_CACHE_PATH"] = str(package / "module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(package / "module-cache")
        for configuration in ["debug", "release"]:
            run.command([swift, "test", "--package-path", package, "--scratch-path", package / "build",
                         "--cache-path", package / "cache", "--config-path", package / "config",
                         "--security-path", package / "security", "-c", configuration,
                         "--no-parallel"], env=env, label=f"tests-{variant}-{configuration}")
            summary["tests"].append(dict(variant=variant, configuration=configuration, passed=True))
            save(run.output / "summary.json", summary)


def build(run, sources, swiftc, cc, manifest):
    binaries = {}
    target = (["-target", f"{platform.machine()}-apple-macosx26.0"]
              if sys.platform == "darwin" else [])
    swift_sdk = []
    c_sdk = []
    if sys.platform == "darwin":
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], label="macos-sdk")
        swift_sdk = ["-sdk", sdk]
        c_sdk = ["-isysroot", sdk]
    for variant, files in sources.items():
        directory = run.output / "build" / variant
        directory.mkdir(parents=True)
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        library = directory / ("libIlliquidCore" + suffix)
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6",
                 "-module-cache-path", directory / "module-cache", *target, *swift_sdk]
        run.command([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", directory / "IlliquidCore.swiftmodule",
                     *files, "-o", library], label=f"build-{variant}-library")
        probe = directory / "MemoryProbe.o"
        run.command([cc, "-O2", *c_sdk, "-c", run.output / "sources" / "MemoryProbe.c", "-o", probe],
                    label=f"build-{variant}-probe")
        binary = directory / "driver"
        run.command([swiftc, *flags, "-parse-as-library", "-I", directory, "-L", directory,
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory,
                     run.output / "sources" / "Driver.swift", probe, "-o", binary],
                    label=f"build-{variant}-driver")
        binaries[variant] = binary
        manifest[variant + "_binary_sha256"] = digest(binary.read_bytes())
        manifest[variant + "_library_sha256"] = digest(library.read_bytes())
    return binaries


def measure(run, binaries, args, summary):
    workloads = cases(args.quick)
    save(run.output / "workloads.json", workloads)
    observations = []
    calibration = []
    summary["workloads"] = []

    def sample(variant, case, iterations, label):
        result = json.loads(run.command([binaries[variant], case["scope"], case["pattern"],
                            str(case["count"]), str(iterations)], label=label))
        for key in ["scope", "pattern", "count"]:
            assert result[key] == case[key], (case, result)
        assert result["iterations"] == iterations
        result.update(variant=variant, workload=case["id"])
        if variant == "candidate" and case["pattern"] == "unique" and case["count"]:
            assert result["shares_input_storage"] is True, "Unique result lost storage sharing"
            assert result["additional_element_capacity_bytes"] == 0
        if variant == "candidate" and case["pattern"] == "sparse":
            assert result["output_capacity"] <= max(64, 2 * case["count"]), "Sparse result pins oversized storage"
            if case["count"]:
                assert result["shares_input_storage"] is False
        if case["count"] == 0:
            assert result["output_capacity"] == 0
        return result

    for case in workloads:
        iterations = 1
        for _ in range(3):
            result = sample("baseline", case, iterations, "calibration")
            calibration.append(result)
            save(run.output / "calibration.json", calibration)
            if result["elapsed_ns"] >= args.target_ms * 500_000 or iterations >= 100_000:
                break
            iterations = min(100_000, max(iterations + 1,
                math.ceil(iterations * args.target_ms * 1_000_000 / max(1, result["elapsed_ns"]))))
        current = {"baseline": [], "candidate": []}
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            paired = []
            for variant in order:
                observation = sample(variant, case, iterations, f"pair-{pair}-{variant}")
                observation["pair"] = pair
                paired.append(observation)
                current[variant].append(observation)
                observations.append(observation)
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(observation, sort_keys=True) + "\n")
            for key in ["output_count", "output_fingerprint", "checksum"]:
                assert paired[0][key] == paired[1][key], (key, paired)
        row = dict(case, iterations=iterations, pairs=args.pairs)
        for variant, entries in current.items():
            times = [entry["elapsed_ns"] / iterations for entry in entries]
            row[variant] = dict(
                median_ns=statistics.median(times), min_ns=min(times), max_ns=max(times),
                median_loop_ns=statistics.median(entry["elapsed_ns"] for entry in entries),
                additional_element_capacity_bytes=sorted(set(
                    entry["additional_element_capacity_bytes"] for entry in entries)),
                live_allocator_delta_bytes=[entry["allocated_after_bytes"] - entry["allocated_before_bytes"]
                                             for entry in entries],
                shared_results=sum(entry["shares_input_storage"] for entry in entries),
                input_capacity=entries[0]["input_capacity"],
                output_capacities=sorted(set(entry["output_capacity"] for entry in entries)),
                output_count=entries[0]["output_count"], element_stride=entries[0]["element_stride"])
        row["median_time_change_percent"] = 100 * (row["candidate"]["median_ns"] /
                                                   row["baseline"]["median_ns"] - 1)
        summary["workloads"].append(row)
        save(run.output / "summary.json", summary)
        print(json.dumps(row, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "tests", "benchmark"], default="all")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=40)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target duration")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be new or empty; existing evidence is never overwritten")
    run = Run(output)
    summary = dict(status="running", baseline=BASELINE, mode=args.mode)
    manifest = dict(baseline=BASELINE, platform=platform.platform(), machine=platform.machine(),
        python_version=platform.python_version(), cpu_count=os.cpu_count(),
        allocator_probe=("default malloc zone size_in_use" if sys.platform == "darwin"
                         else "glibc mallinfo2 uordblks + hblkhd (includes allocator caches)"),
        timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        arguments=vars(args) | {"output": str(output)})
    try:
        swift = shutil.which("swift")
        swiftc = shutil.which("swiftc")
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not swift or not swiftc or not cc:
            raise RuntimeError("swift, swiftc, and a C compiler must be on PATH")
        manifest["swift_version"] = run.command([swift, "--version"], label="swift-version")
        manifest["cc_version"] = run.command([cc, "--version"], label="cc-version")
        manifest["head"] = run.command(["git", "rev-parse", "HEAD"], label="head")
        manifest["worktree_status"] = run.command(["git", "status", "--short"], label="status")
        sources = snapshots(run, manifest)
        save(output / "manifest.json", manifest)
        if args.mode in ["all", "tests"]:
            tests(run, sources, swift, summary, manifest)
        if args.mode in ["all", "benchmark"]:
            binaries = build(run, sources, swiftc, cc, manifest)
            save(output / "manifest.json", manifest)
            measure(run, binaries, args, summary)
        summary["status"] = "passed"
        print("QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
