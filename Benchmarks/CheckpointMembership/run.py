#!/usr/bin/env python3
"""Test exact checkpoint production sources and measure paired record construction.

This is a macOS component experiment. It does not build or run the media player.
Submit the entire command through Kyoto when the shared queue is available (see
AGENTS.md); compilation within this runner is strictly sequential.
"""
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

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CHECKPOINT = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE_SOURCES = [
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
    "Sources/IlliquidCore/Persistence/LegacyPreferencesMigration.swift",
]
CORE_TESTS = [
    "PlaylistDeduplicationTests.swift",
    "PlaylistSessionRecordTests.swift",
    "PlaybackSessionStoreTests.swift",
]
PLAYER_TEST = "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift"
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CheckpointMembershipQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "CheckpointProbe", targets: ["CheckpointProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .executableTarget(
            name: "CheckpointProbe", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(
            name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    ]
)
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def workloads():
    result = []
    groups = [
        ("no-folder-last", [0, 1, 32, 1000, 10000]),
        ("folder-last", [0, 1, 32, 1000, 10000]),
        ("no-folder-miss", [32, 10000]),
        ("folder-miss", [32, 10000]),
        ("folder-first", [1, 10000]),
        ("remote-source", [1, 10000]),
        ("unsupported-source", [1, 10000]),
        ("no-folder-first", [1, 10000]),
        ("all-invalid-items", [1, 10000]),
    ]
    for scenario, sizes in groups:
        for count in sizes:
            result.append(dict(id=f"{scenario}/{count}", scenario=scenario, count=count))
    return result


class Run:
    def __init__(self, output):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.number = 0

    def command(self, args, *, cwd=ROOT, env=None, label="command", show_tail=False):
        self.number += 1
        args = [str(argument) for argument in args]
        log = self.logs / f"{self.number:04d}-{label}.log"
        start = time.monotonic()
        completed = subprocess.run(args, cwd=cwd, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_bytes(completed.stdout)
        elapsed = time.monotonic() - start
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(
                args=args, cwd=str(cwd), log=str(log.relative_to(self.output)),
                returncode=completed.returncode, elapsed_seconds=elapsed)) + "\n")
        output = completed.stdout.decode("utf-8", errors="replace").strip()
        if completed.returncode or show_tail:
            print(f"COMMAND_LOG {label} {log.relative_to(self.output)}", flush=True)
            print("\n".join(output.splitlines()[-80 if completed.returncode else -16:]),
                  flush=True)
        if completed.returncode:
            raise RuntimeError(f"{label} failed ({completed.returncode}); see {log}")
        return output


def snapshots(run, manifest):
    sources = {}
    for variant in ("baseline", "candidate"):
        directory = run.output / "sources" / variant
        directory.mkdir(parents=True)
        sources[variant] = {}
        manifest[variant + "_sources"] = {}
        for path in CORE_SOURCES + [CHECKPOINT]:
            raw = (subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                   if variant == "baseline" else (ROOT / path).read_bytes())
            destination = directory / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
            sources[variant][path] = destination
            manifest[variant + "_sources"][path] = dict(sha256=digest(raw), bytes=len(raw))
    for path in CORE_SOURCES:
        if manifest["baseline_sources"][path] != manifest["candidate_sources"][path]:
            raise RuntimeError(f"Unrelated benchmark dependency changed: {path}")

    shared = run.output / "sources" / "shared"
    shared.mkdir()
    shared_files = [
        "Benchmarks/CheckpointMembership/Driver.swift",
        "Benchmarks/CheckpointMembership/run.py",
        ".github/workflows/checkpoint-membership-performance.yml",
        PLAYER_TEST,
    ] + [f"Tests/IlliquidCoreTests/{name}" for name in CORE_TESTS]
    manifest["shared_sources"] = {}
    for path in shared_files:
        raw = (ROOT / path).read_bytes()
        destination = shared / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        manifest["shared_sources"][path] = dict(sha256=digest(raw), bytes=len(raw))
    (shared / "Package.swift").write_text(PACKAGE)
    manifest["isolated_package_sha256"] = digest(PACKAGE.encode())
    return sources, shared


def stage(run, sources, shared):
    packages = {}
    for variant, files in sources.items():
        package = run.output / "build" / variant
        package.mkdir(parents=True)
        (package / "Package.swift").write_text(PACKAGE)
        for path, snapshot in files.items():
            module = "IlliquidPlayer" if path == CHECKPOINT else "IlliquidCore"
            destination = package / "Sources" / module / Path(path).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(snapshot, destination)
        driver = package / "Sources" / "CheckpointProbe" / "Driver.swift"
        driver.parent.mkdir(parents=True)
        shutil.copy2(shared / "Benchmarks/CheckpointMembership/Driver.swift", driver)
        for path in [PLAYER_TEST] + [f"Tests/IlliquidCoreTests/{name}" for name in CORE_TESTS]:
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(shared / path, destination)
        packages[variant] = package
    return packages


def swift_command(swift, package, verb, configuration):
    # Testable visibility is needed only for the internal checkpoint helper in
    # this isolated executable. Both variants use the identical compiler flags.
    return [
        swift, verb, "--package-path", package, "--scratch-path", package / ".build",
        "--cache-path", package / ".cache", "--config-path", package / ".config",
        "--security-path", package / ".security", "-c", configuration,
        "-Xswiftc", "-enable-testing",
    ]


def build_and_test(run, packages, swift, summary, manifest):
    binaries = {}
    for variant, package in packages.items():
        env = os.environ.copy()
        env["CLANG_MODULE_CACHE_PATH"] = str(package / "module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(package / "module-cache")
        for configuration in ("debug", "release"):
            label = f"tests-{variant}-{configuration}"
            output = run.command(
                swift_command(swift, package, "test", configuration) + ["--no-parallel"],
                env=env, label=label, show_tail=True)
            receipt = dict(variant=variant, configuration=configuration, passed=True)
            # Swift Testing prints its aggregate test count in this line. Retain
            # the whole receipt instead of guessing parameterized test counts.
            receipt["result_lines"] = [
                line for line in output.splitlines() if "Test run with" in line and "passed" in line
            ]
            if not receipt["result_lines"]:
                raise RuntimeError(f"Swift Testing execution receipt missing: {label}")
            summary["tests"].append(receipt)
            save(run.output / "summary.json", summary)
            print("CHECKPOINT_TEST " + json.dumps(receipt, sort_keys=True), flush=True)
        run.command(
            swift_command(swift, package, "build", "release") + ["--product", "CheckpointProbe"],
            env=env, label=f"build-{variant}", show_tail=True)
        binary_directory = run.command(
            swift_command(swift, package, "build", "release") + ["--show-bin-path"],
            env=env, label=f"bin-path-{variant}").splitlines()[-1]
        binary = Path(binary_directory) / "CheckpointProbe"
        if not binary.is_file():
            raise RuntimeError(f"Compiled benchmark is missing: {binary}")
        binaries[variant] = binary
        manifest[variant + "_binary_sha256"] = digest(binary.read_bytes())
    return binaries


def measure(run, binaries, args, summary):
    cases = workloads()
    save(run.output / "workloads.json", cases)
    calibration = []

    def sample(variant, case, iterations, label):
        result = json.loads(run.command(
            [binaries[variant], case["scenario"], case["count"], iterations], label=label))
        for key in ("scenario", "count"):
            if result[key] != case[key]:
                raise RuntimeError(f"Workload mismatch for {key}: {case} vs {result}")
        if result["iterations"] != iterations:
            raise RuntimeError(f"Iteration mismatch: {result}")
        if not isinstance(result["elapsed_ns"], (int, float)) or not (
                math.isfinite(result["elapsed_ns"]) and result["elapsed_ns"] > 0):
            raise RuntimeError(f"Invalid elapsed time: {result}")
        for key in ("checksum", "fingerprint"):
            if key not in result:
                raise RuntimeError(f"Driver omitted parity field {key}")
        return dict(result, variant=variant, workload=case["id"])

    for case in cases:
        iterations = 1
        for attempt in range(4):
            result = sample("baseline", case, iterations, "calibration")
            calibration.append(result)
            save(run.output / "calibration.json", calibration)
            if result["elapsed_ns"] >= args.target_ms * 750_000 or iterations >= 100_000:
                break
            if attempt != 3:
                iterations = min(100_000, max(iterations + 1, math.ceil(
                    iterations * args.target_ms * 1_000_000 / result["elapsed_ns"])))

        samples = {"baseline": [], "candidate": []}
        ratios = []
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            paired = {}
            for variant in order:
                result = sample(variant, case, iterations, f"pair-{pair}-{variant}")
                result["pair"] = pair
                samples[variant].append(result)
                paired[variant] = result
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(result, sort_keys=True) + "\n")
            for key in ("checksum", "fingerprint"):
                if paired["baseline"][key] != paired["candidate"][key]:
                    raise RuntimeError(f"Checkpoint result mismatch ({key}): {paired}")
            ratios.append(paired["candidate"]["elapsed_ns"] / paired["baseline"]["elapsed_ns"])

        row = dict(case, iterations=iterations, pairs=args.pairs,
                   paired_candidate_over_baseline=ratios,
                   median_paired_time_change_percent=100 * (statistics.median(ratios) - 1),
                   faster_pairs=sum(ratio < 1 for ratio in ratios),
                   fingerprint=samples["candidate"][0]["fingerprint"])
        for variant, entries in samples.items():
            times = [entry["elapsed_ns"] / iterations for entry in entries]
            row[variant] = dict(median_ns=statistics.median(times),
                                min_ns=min(times), max_ns=max(times))
        summary["workloads"].append(row)
        save(run.output / "summary.json", summary)
        print("CHECKPOINT_RESULT " + json.dumps(row, sort_keys=True), flush=True)


def write_step_summary(summary):
    destination = os.environ.get("GITHUB_STEP_SUMMARY")
    if not destination:
        return
    with Path(destination).open("a") as stream:
        stream.write("## Checkpoint membership component qualification\n\n")
        stream.write(f"Status: **{summary['status']}**. Baseline: \x60{BASELINE}\x60.\n\n")
        stream.write("The same checkpoint and playlist/session tests run on baseline and "
                     "candidate, in debug and release. Exact production files are compiled "
                     "in isolated modules; this is not a full-player or UI qualification.\n\n")
        stream.write("| Scenario | Items | Baseline μs/record | Candidate μs/record | "
                     "Median paired time change | Faster pairs |\n")
        stream.write("|---|---:|---:|---:|---:|---:|\n")
        for row in summary["workloads"]:
            stream.write(
                f"| {row['scenario']} | {row['count']} | "
                f"{row['baseline']['median_ns'] / 1000:.3f} | "
                f"{row['candidate']['median_ns'] / 1000:.3f} | "
                f"{row['median_paired_time_change_percent']:+.2f}% | "
                f"{row['faster_pairs']}/{row['pairs']} |\n")
        stream.write("\nNegative time change means faster. Timings include complete record "
                     "construction and its existing playlist deduplication, but exclude "
                     "encoding, disk I/O, decoding and presentation. This experiment does "
                     "not measure allocation counts, peak memory, retained memory or energy.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=50)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least 2")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be positive and finite")
    if sys.platform != "darwin":
        parser.error("macOS is required by the exact production os.signpost source")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be new or empty; evidence is never overwritten")
    run = Run(output)
    summary = dict(status="running", baseline=BASELINE, tests=[], workloads=[])
    manifest = dict(
        baseline=BASELINE, platform=platform.platform(), machine=platform.machine(),
        python_version=platform.python_version(), cpu_count=os.cpu_count(),
        timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        arguments=dict(pairs=args.pairs, target_ms=args.target_ms, output=str(output)),
        scope="Exact complete production checkpoint/core files in isolated Swift modules",
        compiler_note="Debug/release tests; release timing; -enable-testing on both variants",
        excluded="Full player, JSON encoding, disk I/O, allocation counts, memory and energy",
    )
    try:
        swift = shutil.which("swift")
        if not swift:
            raise RuntimeError("swift must be on PATH")
        manifest["swift_version"] = run.command([swift, "--version"], label="swift-version")
        manifest["head"] = run.command(["git", "rev-parse", "HEAD"], label="head")
        manifest["worktree_status"] = run.command(["git", "status", "--short"], label="status")
        sources, shared = snapshots(run, manifest)
        save(output / "manifest.json", manifest)
        packages = stage(run, sources, shared)
        binaries = build_and_test(run, packages, swift, summary, manifest)
        save(output / "manifest.json", manifest)
        measure(run, binaries, args, summary)
        summary["status"] = "passed"
        print("CHECKPOINT_QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)
        print("CHECKPOINT_MANIFEST " + json.dumps(manifest, sort_keys=True), flush=True)
        write_step_summary(summary)


if __name__ == "__main__":
    main()
