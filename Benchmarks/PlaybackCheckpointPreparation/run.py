#!/usr/bin/env python3
"""Compare the actual checkpoint writer with a pinned baseline in fresh processes.

Only PlaybackCheckpointWriter.swift differs between production arms. The exact
complete PlaybackSessionRecord and PlaybackSessionStoring declarations are staged
from their source file; the unused macOS disk-store implementation is excluded.
No production declarations are replaced by stand-ins.
"""

import argparse
import datetime
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PLAYER_SOURCE = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
SESSION_SOURCE = "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift"
CORE_SOURCES = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    SESSION_SOURCE,
]
BASELINE_SHA256 = {
    CORE_SOURCES[0]: "8a3c017132f0e79cb8280551ff686066b9a3005c49bd7833efc54bb11dfe75fe",
    CORE_SOURCES[1]: "b38441770551ab48f9c5db544479156656494588296c1777ac81caa768796ec8",
    CORE_SOURCES[2]: "d167212f90dd5cd6d8e0e73c208d8e9b4648cc7f4dd21212d51c85a693a263e7",
    CORE_SOURCES[3]: "3b65c98b88722ca4d51c315a7fd5e2fde0e40c846071b6b1e34cd1f1eddb3fd2",
    CORE_SOURCES[4]: "d3e776abaa9bdae73a6a656114eee1bc761ddbea78017a6b710ed22895f6d254",
    SESSION_SOURCE: "4318a57a49833f22c3b1181c53694fc31e3a74535ee1644d82bce3134c54228f",
    PLAYER_SOURCE: "72e1b32e382d18736c54ae2222b91c7093bb0c9577c8197c630e74fd8405d591",
}
SESSION_BOUNDARY = (
    b"\n/// A versioned, atomic Application Support document for crash-safe playback"
)
SESSION_PREFIX_SHA256 = "1c78a07bea0f3118b410a4940be69ebd7554dbdb2335a3a792bccc3ab307f7f4"
CORE_TESTS = [
    "PlaylistSessionRecordTests.swift",
    "PlaylistMutationTests.swift",
    "PlaylistOrderRestorationTests.swift",
    "FolderPlaylistTests.swift",
]
PLAYER_TESTS = ["PlaybackCheckpointTests.swift"]
VARIANTS = ("baseline", "candidate")
MAX_ITERATIONS = 1_000_000
SEMANTIC_FIELDS = (
    "pattern", "count", "iterations", "checksum", "semantic_checksum",
    "expected_count", "has_folder",
)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def loader_environment(binary):
    # Prefer this arm's actual libraries over any inherited research paths.
    # Keep the remainder for toolchain runtime dependencies such as ncurses.
    key = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    inherited = os.environ.get(key, "")
    return {key: str(binary.parent) + (os.pathsep + inherited if inherited else "")}


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def session_prefix(raw):
    """Retain the production record AND protocol; reject a changed boundary."""
    if raw.count(SESSION_BOUNDARY) != 1:
        raise RuntimeError("PlaybackSessionStore extraction boundary changed")
    prefix, remainder = raw.split(SESSION_BOUNDARY)
    if not prefix.endswith(
        b"public protocol PlaybackSessionStoring: Sendable {\n"
        b"    func load() throws -> PlaybackSessionRecord?\n"
        b"    func save(_ session: PlaybackSessionRecord) throws\n"
        b"    func clear() throws\n"
        b"}\n"
    ) or not remainder.startswith(
        b"\n/// restoration. Preferences intentionally live in a separate store.\n"
        b"public final class AtomicPlaybackSessionStore: PlaybackSessionStoring, @unchecked Sendable {"
    ):
        raise RuntimeError("PlaybackSessionStore extraction declarations changed")
    compiled = prefix + b"\n"
    if digest(compiled) != SESSION_PREFIX_SHA256:
        raise RuntimeError("PlaybackSessionRecord/protocol bytes differ from the pinned dependency")
    return compiled


class Run:
    def __init__(self, output):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.number = 0
        self.receipts = {}
        self.worktree_receipts = {}

    def retain(self, relative, raw):
        destination = self.output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        self.receipts[str(relative)] = digest(raw)
        return destination

    def command(self, args, *, cwd=ROOT, env_overrides=None, label="command", compress=False, combined=False):
        self.number += 1
        label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label)
        stem = f"{self.number:04d}-{label}"
        stdout_file = self.logs / (stem + (".stdout.gz" if compress else ".stdout"))
        stderr_file = self.logs / (stem + ".stderr")
        env = os.environ.copy()
        env.update(env_overrides or {})
        started_utc = utc_now()
        start = time.monotonic()
        completed = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elapsed = time.monotonic() - start
        stdout_file.write_bytes(gzip.compress(completed.stdout, mtime=0)
                                if compress else completed.stdout)
        stderr_file.write_bytes(completed.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(
                args=[str(a) for a in args], cwd=str(cwd),
                env_overrides=env_overrides or {}, started_utc=started_utc,
                elapsed_seconds=elapsed, returncode=completed.returncode,
                stdout=str(stdout_file.relative_to(self.output)),
                stderr=str(stderr_file.relative_to(self.output)),
                stdout_raw_sha256=digest(completed.stdout),
                stdout_file_sha256=digest(stdout_file.read_bytes()),
                stderr_sha256=digest(completed.stderr),
            ), sort_keys=True) + "\n")
        if completed.returncode:
            raise RuntimeError(
                f"Command failed ({completed.returncode}); inspect {stdout_file} and {stderr_file}"
            )
        return completed.stdout + completed.stderr if combined else completed.stdout

    def guard_inputs(self):
        for relative, expected in self.receipts.items():
            if digest((self.output / relative).read_bytes()) != expected:
                raise RuntimeError(f"Staged source or executable changed during qualification: {relative}")
        for relative, expected in self.worktree_receipts.items():
            if digest((ROOT / relative).read_bytes()) != expected:
                raise RuntimeError(f"Qualification input changed during the run: {relative}")


def snapshots(run, manifest):
    sources = {}
    manifest["production_sources"] = {}
    for variant in VARIANTS:
        sources[variant] = {"core": [], "player": []}
        manifest["production_sources"][variant] = {}
        for relative in [*CORE_SOURCES, PLAYER_SOURCE]:
            if variant == "baseline":
                raw = run.command(["git", "show", f"{BASELINE}:{relative}"],
                                  label=f"baseline-{Path(relative).stem}")
                if digest(raw) != BASELINE_SHA256[relative]:
                    raise RuntimeError(f"Pinned baseline source hash changed: {relative}")
            else:
                raw = (ROOT / relative).read_bytes()
                run.worktree_receipts[relative] = digest(raw)
                if relative != PLAYER_SOURCE and digest(raw) != BASELINE_SHA256[relative]:
                    raise RuntimeError(f"Unrelated production dependency changed: {relative}")
            compiled = session_prefix(raw) if relative == SESSION_SOURCE else raw
            full = run.retain(Path("production-sources") / variant / relative, raw)
            module = "IlliquidPlayer" if relative == PLAYER_SOURCE else "IlliquidCore"
            staged = run.retain(Path("sources") / variant / module / Path(relative).name, compiled)
            sources[variant]["player" if relative == PLAYER_SOURCE else "core"].append(staged)
            manifest["production_sources"][variant][relative] = dict(
                full_sha256=digest(raw), compiled_sha256=digest(compiled),
                full_path=str(full.relative_to(run.output)),
                compiled_path=str(staged.relative_to(run.output)),
                extracted=relative == SESSION_SOURCE,
            )
    manifest["shared_inputs"] = {}
    for name in ["Bridge.swift", "Driver.swift", "run.py"]:
        source = HERE / name
        raw = source.read_bytes()
        relative = str(source.relative_to(ROOT))
        run.worktree_receipts[relative] = digest(raw)
        staged = run.retain(Path("sources") / name, raw)
        manifest["shared_inputs"][relative] = dict(sha256=digest(raw),
                                                  path=str(staged.relative_to(run.output)))
    for module, names in [("IlliquidCoreTests", CORE_TESTS), ("IlliquidPlayerTests", PLAYER_TESTS)]:
        for name in names:
            relative = str(Path("Tests") / module / name)
            raw = (ROOT / relative).read_bytes()
            run.worktree_receipts[relative] = digest(raw)
            staged = run.retain(Path("sources") / "tests" / module / name, raw)
            manifest["shared_inputs"][relative] = dict(sha256=digest(raw),
                                                      path=str(staged.relative_to(run.output)))
    return sources


def test(run, sources, swift, summary):
    for variant in VARIANTS:
        package = run.output / "build" / (variant + "-tests")
        for kind, module in [("core", "IlliquidCore"), ("player", "IlliquidPlayer")]:
            destination = package / "Sources" / module
            destination.mkdir(parents=True)
            for source in sources[variant][kind]:
                run.retain(destination.relative_to(run.output) / source.name, source.read_bytes())
        for module in ["IlliquidCoreTests", "IlliquidPlayerTests"]:
            for source in (run.output / "sources" / "tests" / module).glob("*.swift"):
                run.retain(package.relative_to(run.output) / "Tests" / module / source.name,
                           source.read_bytes())
        package_manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlaybackCheckpointPreparationQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    ])
'''
        run.retain(package.relative_to(run.output) / "Package.swift", package_manifest.encode())
        env_overrides = {
            "CLANG_MODULE_CACHE_PATH": str(package / "module-cache"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(package / "module-cache"),
        }
        for configuration in ["debug", "release"]:
            print(f"Testing {variant} ({configuration})", flush=True)
            stdout = run.command([
                swift, "test", "--package-path", package, "--scratch-path", package / "build",
                "--cache-path", package / "cache", "--config-path", package / "config",
                "--security-path", package / "security", "-c", configuration,
                "--jobs", "2", "--no-parallel",
            ], env_overrides=env_overrides, label=f"tests-{variant}-{configuration}", combined=True)
            passed = re.search(rb"Test run with (\d+) tests?(?: in \d+ suites?)? passed", stdout)
            if not passed or int(passed.group(1)) <= 0:
                raise RuntimeError(f"No successful nonempty Swift Testing summary for {variant}/{configuration}")
            if b"Playback checkpoint preparation" not in stdout:
                raise RuntimeError(f"The checkpoint regression suite did not execute for {variant}/{configuration}")
            summary["tests"].append(dict(variant=variant, configuration=configuration,
                                         passed=True, tests_reported=int(passed.group(1)),
                                         combined_output_sha256=digest(stdout)))
            save(run.output / "summary.json", summary)
            run.guard_inputs()


def build(run, sources, swiftc, manifest):
    binaries = {}
    target = ["-target", f"{platform.machine()}-apple-macosx26.0"] if sys.platform == "darwin" else []
    sdk_flags = []
    if sys.platform == "darwin":
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], label="macos-sdk").decode().strip()
        sdk_flags = ["-sdk", sdk]
        manifest["macos_sdk"] = sdk
    manifest["binaries"] = {}
    for variant in VARIANTS:
        print(f"Building separate production modules for {variant}", flush=True)
        directory = run.output / "build" / variant
        directory.mkdir(parents=True)
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6",
                 "-module-cache-path", directory / "module-cache", *target, *sdk_flags]
        core = directory / ("libIlliquidCore" + suffix)
        player = directory / ("libIlliquidPlayer" + suffix)
        run.command([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", directory / "IlliquidCore.swiftmodule",
                     *sources[variant]["core"], "-o", core], label=f"build-{variant}-core")
        link_flags = ["-I", directory, "-L", directory,
                      "-Xlinker", "-rpath", "-Xlinker", directory]
        run.command([swiftc, *flags, *link_flags, "-lIlliquidCore",
                     "-emit-library", "-emit-module", "-module-name", "IlliquidPlayer",
                     "-emit-module-path", directory / "IlliquidPlayer.swiftmodule",
                     *sources[variant]["player"], run.output / "sources" / "Bridge.swift",
                     "-o", player], label=f"build-{variant}-player")
        binary = directory / "driver"
        run.command([swiftc, *flags, *link_flags, "-parse-as-library",
                     "-lIlliquidCore", "-lIlliquidPlayer",
                     run.output / "sources" / "Driver.swift", "-o", binary],
                    label=f"build-{variant}-driver")
        binaries[variant] = binary
        run.command(["otool", "-L", binary] if sys.platform == "darwin" else ["ldd", binary],
                    env_overrides=loader_environment(binary), label=f"dependencies-{variant}")
        manifest["binaries"][variant] = {}
        for path in [core, player, binary, directory / "IlliquidCore.swiftmodule",
                     directory / "IlliquidPlayer.swiftmodule"]:
            relative = str(path.relative_to(run.output))
            receipt = digest(path.read_bytes())
            run.receipts[relative] = receipt
            manifest["binaries"][variant][path.name] = dict(path=relative, sha256=receipt)
        run.guard_inputs()
    return binaries


def verify(run, binaries, summary):
    outputs = {}
    for variant in VARIANTS:
        raw = run.command([binaries[variant], "verify"], label=f"verify-{variant}", compress=True,
                          env_overrides=loader_environment(binaries[variant]))
        lines = raw.splitlines()
        if not lines:
            raise RuntimeError(f"No complete output comparisons for {variant}")
        for line in lines:
            json.loads(line)
        stored = run.retain(Path("verification") / f"{variant}.jsonl.gz", gzip.compress(raw, mtime=0))
        outputs[variant] = raw
        summary["verification"][variant] = dict(
            cases=len(lines), raw_sha256=digest(raw), gzip_sha256=digest(stored.read_bytes()),
            path=str(stored.relative_to(run.output)),
        )
    if outputs["baseline"] != outputs["candidate"]:
        raise RuntimeError("Baseline and candidate complete checkpoint outputs differ")
    summary["verification"]["byte_identical"] = True
    save(run.output / "summary.json", summary)
    run.guard_inputs()


def check_sample(value, case, iterations):
    if not isinstance(value, dict) or any(key not in value for key in (*SEMANTIC_FIELDS, "cpu_ns", "wall_ns")):
        raise RuntimeError(f"Missing benchmark result fields: {value!r}")
    for key, expected in [("pattern", case["pattern"]), ("count", case["count"]), ("iterations", iterations)]:
        if value[key] != expected:
            raise RuntimeError(f"Unexpected {key} in benchmark result: {value!r}")
    for key in ["cpu_ns", "wall_ns"]:
        if isinstance(value[key], bool) or not isinstance(value[key], (float, int)) or not math.isfinite(value[key]) or value[key] < 0:
            raise RuntimeError(f"Invalid clock measurement: {value!r}")
    if not isinstance(value["has_folder"], bool) or not isinstance(value["expected_count"], int) or value["expected_count"] < 0:
        raise RuntimeError(f"Invalid semantic result fields: {value!r}")


def check_pair(left, right):
    for key in SEMANTIC_FIELDS:
        if left[key] != right[key]:
            raise RuntimeError(f"Baseline/candidate result mismatch for {key}: {left!r} / {right!r}")


def summarize(case, observations, iterations, pairs):
    row = dict(case, iterations=iterations, pairs=pairs)
    for variant in VARIANTS:
        selected = [entry for entry in observations if entry["variant"] == variant]
        row[variant] = {}
        for metric in ["wall", "cpu"]:
            durations = [entry[f"{metric}_ns"] / iterations for entry in selected]
            row[variant][metric] = dict(
                median_ns=statistics.median(durations), min_ns=min(durations), max_ns=max(durations),
                median_loop_ns=statistics.median(entry[f"{metric}_ns"] for entry in selected),
            )
    for metric in ["wall", "cpu"]:
        reductions = []
        for pair in range(pairs):
            values = {entry["variant"]: entry[f"{metric}_ns"] for entry in observations if entry["pair"] == pair}
            if values["baseline"] <= 0 or values["candidate"] <= 0:
                raise RuntimeError("A retained timed loop did not advance both clocks")
            reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
        row[metric + "_reduction"] = dict(
            median_ratio_reduction_percent=100 * (
                1 - row["candidate"][metric]["median_ns"] / row["baseline"][metric]["median_ns"]),
            median_paired_percent=statistics.median(reductions),
            min_paired_percent=min(reductions), max_paired_percent=max(reductions),
            paired_percent=reductions, pairs_faster=sum(value > 0 for value in reductions),
        )
    return row


def measure(run, binaries, args, summary):
    lists = {variant: json.loads(run.command([binaries[variant], "list"], label=f"list-{variant}",
                                           env_overrides=loader_environment(binaries[variant])))
             for variant in VARIANTS}
    if lists["baseline"] != lists["candidate"]:
        raise RuntimeError("Baseline and candidate workload lists differ")
    workloads = lists["baseline"]
    if not isinstance(workloads, list) or not workloads:
        raise RuntimeError("No benchmark workloads")
    seen = set()
    for case in workloads:
        if (not isinstance(case, dict) or not isinstance(case.get("id"), str)
                or not case["id"] or case["id"] in seen
                or not isinstance(case.get("pattern"), str) or not case["pattern"]
                or not isinstance(case.get("count"), int) or isinstance(case["count"], bool)
                or case["count"] < 0):
            raise RuntimeError(f"Invalid or duplicate workload: {case!r}")
        seen.add(case["id"])
    save(run.output / "all-workloads.json", workloads)
    if args.quick:
        workloads = [case for case in workloads if case["count"] <= 1000]
    if not workloads:
        raise RuntimeError("The requested workload filter selected no cases")
    save(run.output / "workloads.json", workloads)

    def sample(variant, case, iterations, phase, **metadata):
        value = json.loads(run.command(
            [binaries[variant], "measure", case["pattern"], case["count"], iterations],
            label=f"{phase}-{case['id']}-{variant}",
            env_overrides=loader_environment(binaries[variant]),
        ))
        check_sample(value, case, iterations)
        value.update(variant=variant, workload=case["id"], phase=phase, **metadata)
        with (run.output / ("calibration.jsonl" if phase == "calibration" else "observations.jsonl")).open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")
        return value

    for case in workloads:
        print(f"Measuring {case['id']}", flush=True)
        iterations = 1
        # Every calibration observation is retained separately. Choose a common
        # count from the faster arm's CPU duration, then allow at most two
        # refinements to reach the target without an unbounded calibration loop.
        for attempt in range(3):
            calibrated = [sample(variant, case, iterations, "calibration", attempt=attempt)
                          for variant in VARIANTS]
            check_pair(*calibrated)
            fastest_cpu = min(value["cpu_ns"] for value in calibrated)
            if fastest_cpu >= args.target_ms * 1_000_000 or iterations >= MAX_ITERATIONS:
                break
            next_count = (MAX_ITERATIONS if fastest_cpu <= 0 else min(MAX_ITERATIONS,
                max(iterations + 1, math.ceil(iterations * args.target_ms * 1_000_000 / fastest_cpu))))
            iterations = next_count
        summary.setdefault("calibration", []).append(dict(
            workload=case["id"], iterations=iterations, target_cpu_ns=args.target_ms * 1_000_000,
            maximum_iterations=MAX_ITERATIONS, last_trial_iterations=calibrated[0]["iterations"],
            last_trial_fastest_cpu_ns=fastest_cpu,
        ))
        current = []
        for pair in range(args.pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            paired = [sample(variant, case, iterations, "measurement", pair=pair, order=position)
                      for position, variant in enumerate(order)]
            check_pair(*paired)
            current.extend(paired)
            run.guard_inputs()
        row = summarize(case, current, iterations, args.pairs)
        summary["workloads"].append(row)
        save(run.output / "summary.json", summary)
        print("BENCHMARK_SUMMARY " + json.dumps(row, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--quick", action="store_true", help="Measure only workloads with at most 1,000 items")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--tests-only", action="store_true")
    modes.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target duration")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be new or empty; existing evidence is never overwritten")
    run = Run(output)
    manifest = dict(
        baseline=BASELINE, platform=platform.platform(), machine=platform.machine(),
        python_version=platform.python_version(), cpu_count=os.cpu_count(), started_utc=utc_now(),
        arguments=vars(args) | {"output": str(output)},
        source_policy="Only PlaybackCheckpointWriter.swift differs; exact complete record/protocol prefix; no stubs",
        compilation="Separate optimized IlliquidCore, IlliquidPlayer+Bridge, and driver; no cross-module optimization",
        calibration_policy="Both arms at one iteration, then common count targeting faster-arm CPU; at most three trials",
        measured_order="Alternating baseline/candidate and candidate/baseline fresh-process pairs per workload",
        exclusions="Calibration excluded from measured summaries; no measured observations excluded",
        environment={key: os.environ[key] for key in ["LANG", "LC_ALL", "SWIFT_DETERMINISTIC_HASHING"] if key in os.environ},
    )
    summary = dict(status="running", baseline=BASELINE, tests=[], verification={}, workloads=[])
    try:
        swift = shutil.which("swift")
        swiftc = shutil.which("swiftc")
        if not swift or not swiftc:
            raise RuntimeError("swift and swiftc must be on PATH")
        manifest["swift_path"] = swift
        manifest["swiftc_path"] = swiftc
        manifest["swift_version"] = run.command([swift, "--version"], label="swift-version").decode().strip()
        manifest["head"] = run.command(["git", "rev-parse", "HEAD"], label="head").decode().strip()
        manifest["worktree_status"] = run.command(["git", "status", "--short"], label="status").decode().strip()
        sources = snapshots(run, manifest)
        save(output / "manifest.json", manifest)
        if not args.skip_tests:
            test(run, sources, swift, summary)
        if not args.tests_only:
            binaries = build(run, sources, swiftc, manifest)
            save(output / "manifest.json", manifest)
            verify(run, binaries, summary)
            measure(run, binaries, args, summary)
        run.guard_inputs()
        manifest["final_input_guards_passed"] = True
        summary["status"] = "passed"
        print("QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        manifest["finished_utc"] = utc_now()
        manifest["artifact_sha256"] = run.receipts
        manifest["worktree_input_sha256"] = run.worktree_receipts
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
