#!/usr/bin/env python3
"""Qualify complete effect retirement through the real playback reducer.

Both variants compile exact production Core and StateSpace sources with the
real MediaTrack dependency, and run the same debug/release regression suites.
Timing runs never preload the allocation probe. Separate Linux/glibc runs count
successful malloc/calloc/realloc requests during the synchronous reducer event.
Submit the entire command through Kyoto when available; builds are serialized.
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
CHANGED_SOURCE = "Sources/IlliquidPlaybackCore/PlaybackCore.swift"
MEDIA_TRACK = "Sources/IlliquidCore/Player/MediaTrack.swift"
SOURCE_DIRS = ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace"]
TEST_DIRS = ["Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]
BENCHMARK_DIR = "Benchmarks/EffectRetirementAllocation"
WORKFLOW = ".github/workflows/effect-retirement-allocation.yml"
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EffectRetirementQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "EffectRetirementProbe", targets: ["EffectRetirementProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
        .executableTarget(
            name: "EffectRetirementProbe", dependencies: ["IlliquidCore", "IlliquidPlaybackCore"]),
        .testTarget(
            name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidCore", "IlliquidPlaybackCore"]),
        .testTarget(
            name: "IlliquidPlaybackStateSpaceTests",
            dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
    ]
)
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def workloads():
    return [dict(id=f"{scenario}/{count}", scenario=scenario, count=count)
            for scenario in ("all", "mixed", "none", "sparse")
            for count in (0, 1, 8, 32, 512, 4096)]


class Run:
    def __init__(self, output):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.number = 0
        self.last_elapsed = 0.0

    def command(self, args, *, cwd=ROOT, env=None, label="command", show_tail=False):
        self.number += 1
        args = [str(argument) for argument in args]
        if args[0] == "git":
            # The hosted container may have a different uid from checkout.
            # Trust only this user-authorized checkout, never a wildcard.
            args[1:1] = ["-c", f"safe.directory={ROOT}"]
        log = self.logs / f"{self.number:04d}-{label}.log"
        start = time.monotonic()
        completed = subprocess.run(args, cwd=cwd, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.last_elapsed = time.monotonic() - start
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(
                args=args, cwd=str(cwd), log=str(log.relative_to(self.output)),
                returncode=completed.returncode, elapsed_seconds=self.last_elapsed,
                allocation_probe_preloaded=bool((env if env is not None else os.environ).get("LD_PRELOAD")))) + "\n")
        log.write_bytes(completed.stdout)
        output = completed.stdout.decode("utf-8", errors="replace").strip()
        if completed.returncode or show_tail:
            print(f"COMMAND_LOG {label} {log.relative_to(self.output)}", flush=True)
            print("\n".join(output.splitlines()[-100 if completed.returncode else -16:]),
                  flush=True)
        if completed.returncode:
            raise RuntimeError(f"{label} failed ({completed.returncode}); see {log}")
        return output


def snapshots(run, manifest):
    baseline_paths = set(run.command(
        ["git", "ls-tree", "-r", "--name-only", BASELINE, "--", *SOURCE_DIRS],
        label="baseline-source-list").splitlines())
    current_paths = set(run.command(
        ["git", "ls-files", "--", *SOURCE_DIRS], label="candidate-source-list").splitlines())
    baseline_paths = {path for path in baseline_paths if path.endswith(".swift")}
    current_paths = {path for path in current_paths if path.endswith(".swift")}
    if not baseline_paths or baseline_paths != current_paths:
        raise RuntimeError("The exact production source-file sets must match")
    paths = sorted(baseline_paths | {MEDIA_TRACK})
    tests = sorted(path for path in run.command(
        ["git", "ls-files", "--", *TEST_DIRS], label="test-source-list").splitlines()
        if path.endswith(".swift"))
    for directory in TEST_DIRS:
        if not any(path.startswith(directory + "/") for path in tests):
            raise RuntimeError(f"No regression tests found in {directory}")
    if "Tests/IlliquidPlaybackCoreTests/EffectRetirementTests.swift" not in tests:
        raise RuntimeError("Effect retirement regression suite is missing")

    sources = {}
    for variant in ("baseline", "candidate"):
        sources[variant] = {}
        manifest[variant + "_sources"] = {}
        for path in paths:
            raw = (subprocess.check_output(
                ["git", "-c", f"safe.directory={ROOT}", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                   if variant == "baseline" else (ROOT / path).read_bytes())
            destination = run.output / "sources" / variant / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
            sources[variant][path] = destination
            manifest[variant + "_sources"][path] = dict(sha256=digest(raw), bytes=len(raw))
    for path in paths:
        if path != CHANGED_SOURCE and (
                manifest["baseline_sources"][path] != manifest["candidate_sources"][path]):
            raise RuntimeError(f"Unrelated production dependency changed: {path}")

    shared = run.output / "sources" / "shared"
    shared.mkdir(parents=True)
    manifest["shared_sources"] = {}
    for path in tests + [f"{BENCHMARK_DIR}/{name}" for name in
                         ("Driver.swift", "AllocationProbe.c", "ProbeSelfTest.c", "run.py")] + [WORKFLOW]:
        raw = (ROOT / path).read_bytes()
        destination = shared / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        manifest["shared_sources"][path] = dict(sha256=digest(raw), bytes=len(raw))
    (shared / "Package.swift").write_text(PACKAGE)
    manifest["isolated_package_sha256"] = digest(PACKAGE.encode())
    manifest["test_files"] = tests
    return sources, shared, tests


def stage(run, sources, shared, tests):
    packages = {}
    for variant, files in sources.items():
        package = run.output / "build" / variant
        package.mkdir(parents=True)
        (package / "Package.swift").write_text(PACKAGE)
        for path, snapshot in files.items():
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(snapshot, destination)
        for path in tests:
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(shared / path, destination)
        driver = package / "Sources" / "EffectRetirementProbe" / "Driver.swift"
        driver.parent.mkdir(parents=True)
        shutil.copy2(shared / BENCHMARK_DIR / "Driver.swift", driver)
        packages[variant] = package
    return packages


def swift_command(swift, package, verb, configuration):
    return [
        swift, verb, "--package-path", package, "--scratch-path", package / ".build",
        "--cache-path", package / ".cache", "--config-path", package / ".config",
        "--security-path", package / ".security", "--jobs", "2", "-c", configuration,
        "-Xswiftc", "-enable-testing",
    ]


def build_and_test(run, packages, swift, summary, manifest):
    binaries = {}
    for variant, package in packages.items():
        env = os.environ.copy()
        env.pop("LD_PRELOAD", None)
        env["CLANG_MODULE_CACHE_PATH"] = str(package / "module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(package / "module-cache")
        for configuration in ("debug", "release"):
            label = f"tests-{variant}-{configuration}"
            output = run.command(
                swift_command(swift, package, "test", configuration) + ["--no-parallel"],
                env=env, label=label, show_tail=True)
            receipt = dict(variant=variant, configuration=configuration, passed=True,
                           result_lines=[line for line in output.splitlines()
                                         if "Test run with" in line and "passed" in line])
            if not receipt["result_lines"]:
                raise RuntimeError(f"Swift Testing execution receipt missing: {label}")
            summary["tests"].append(receipt)
            save(run.output / "summary.json", summary)
            print("EFFECT_TEST " + json.dumps(receipt, sort_keys=True), flush=True)
        run.command(
            swift_command(swift, package, "build", "release") +
            ["--product", "EffectRetirementProbe"],
            env=env, label=f"build-{variant}", show_tail=True)
        directory = run.command(
            swift_command(swift, package, "build", "release") + ["--show-bin-path"],
            env=env, label=f"bin-path-{variant}").splitlines()[-1]
        binary = Path(directory) / "EffectRetirementProbe"
        if not binary.is_file():
            raise RuntimeError(f"Compiled probe is missing: {binary}")
        binaries[variant] = binary
        manifest[variant + "_binary_sha256"] = digest(binary.read_bytes())
    return binaries


def build_allocation_probe(run, shared, manifest):
    if sys.platform != "linux":
        manifest["allocation_probe"] = dict(
            executed=False, reason="The malloc request probe is specific to Linux/glibc")
        return None
    selected_cc = os.environ.get("CC")
    cc = (shutil.which(selected_cc) if selected_cc else
          (shutil.which("cc") or shutil.which("clang")))
    if not cc:
        raise RuntimeError("A C compiler is required for the Linux allocation probe")
    directory = run.output / "build" / "allocation-probe"
    directory.mkdir(parents=True)
    library = directory / "libEffectAllocationProbe.so"
    check = directory / "probe-self-test"
    manifest["cc_version"] = run.command([cc, "--version"], label="cc-version")
    run.command(
        [cc, "-std=c11", "-O2", "-fno-builtin", "-fPIC", "-shared",
         shared / BENCHMARK_DIR / "AllocationProbe.c", "-o", library],
        label="build-allocation-probe", show_tail=True)
    run.command(
        [cc, "-std=c11", "-O2", "-fno-builtin",
         shared / BENCHMARK_DIR / "ProbeSelfTest.c", "-ldl", "-o", check],
        label="build-allocation-self-test", show_tail=True)
    env = os.environ.copy()
    env["LD_PRELOAD"] = str(library)
    receipt = run.command([check], env=env, label="allocation-probe-self-test", show_tail=True)
    if receipt != "ALLOCATION_PROBE_PASS calls=3 requested_bytes=225":
        raise RuntimeError(f"Unexpected allocation probe receipt: {receipt}")
    manifest["allocation_probe"] = dict(
        executed=True, self_test=receipt, library_sha256=digest(library.read_bytes()),
        scope="Successful malloc/calloc/realloc requests on the measured thread",
        excludes="Aligned allocators, free, live/peak/RSS memory, allocator usable sizes")
    return library


def measure(run, binaries, probe, args, summary):
    cases = workloads()
    save(run.output / "workloads.json", cases)
    semantics = run.output / "semantics"
    semantics.mkdir()
    calibration = []

    def sample(variant, case, iterations, mode, label):
        env = os.environ.copy()
        env.pop("LD_PRELOAD", None)
        if mode == "allocations":
            if probe is None:
                raise RuntimeError("Allocation mode requires the verified Linux probe")
            env["LD_PRELOAD"] = str(probe)
        value = json.loads(run.command(
            [binaries[variant], case["scenario"], case["count"], iterations, mode],
            env=env, label=label))
        for key in ("scenario", "count"):
            if value[key] != case[key]:
                raise RuntimeError(f"Driver workload mismatch: {case} vs {value}")
        if value["iterations"] != iterations:
            raise RuntimeError(f"Driver iteration mismatch: {value}")
        if mode == "timing" and not (
                isinstance(value["elapsed_ns"], (int, float)) and
                math.isfinite(value["elapsed_ns"]) and value["elapsed_ns"] > 0):
            raise RuntimeError(f"Invalid event time: {value}")
        if mode == "allocations":
            for key in ("alloc_calls", "requested_bytes"):
                if not isinstance(value[key], int) or value[key] < 0:
                    raise RuntimeError(f"Invalid allocation counter {key}: {value}")
        if "checksum" not in value or "semanticFingerprint" not in value:
            raise RuntimeError("Driver omitted semantic validation fields")
        canonical = json.dumps(value.pop("semanticFingerprint"),
                               sort_keys=True, separators=(",", ":")).encode()
        fingerprint = digest(canonical)
        destination = semantics / (fingerprint + ".json")
        if not destination.exists():
            destination.write_bytes(canonical + b"\n")
        value.update(variant=variant, mode=mode, workload=case["id"],
                     semantic_sha256=fingerprint, process_elapsed_seconds=run.last_elapsed)
        return value, canonical

    def paired_samples(case, iterations, mode):
        samples = {"baseline": [], "candidate": []}
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            paired = {}
            for variant in order:
                result, canonical = sample(
                    variant, case, iterations, mode, f"{mode}-{pair}-{variant}")
                result["pair"] = pair
                paired[variant] = (result, canonical)
                samples[variant].append(result)
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(result, sort_keys=True) + "\n")
                print("EFFECT_OBSERVATION " + json.dumps(result, sort_keys=True), flush=True)
            if paired["baseline"][1] != paired["candidate"][1]:
                raise RuntimeError(f"Semantic retirement mismatch: {case['id']}/{mode}")
            if paired["baseline"][0]["checksum"] != paired["candidate"][0]["checksum"]:
                raise RuntimeError(f"Consumed result mismatch: {case['id']}/{mode}")
        return samples

    for case in cases:
        iterations = 1
        for attempt in range(4):
            result, _ = sample("baseline", case, iterations, "timing", "calibration")
            calibration.append(result)
            save(run.output / "calibration.json", calibration)
            if (result["elapsed_ns"] >= args.target_ms * 750_000 or
                    iterations >= 20_000 or result["process_elapsed_seconds"] >= 2):
                break
            if attempt != 3:
                # Fixture construction is outside event timing. Also bound
                # process work so cheap controls do not cause excessive setup.
                by_event = math.ceil(iterations * args.target_ms * 1_000_000 /
                                     result["elapsed_ns"])
                by_process = math.ceil(iterations * 2 /
                                       max(0.001, result["process_elapsed_seconds"]))
                iterations = min(20_000, max(iterations + 1, min(by_event, by_process)))

        timed = paired_samples(case, iterations, "timing")
        ratios = [candidate["elapsed_ns"] / baseline["elapsed_ns"]
                  for baseline, candidate in zip(timed["baseline"], timed["candidate"])]
        row = dict(case, iterations=iterations, pairs=args.pairs,
                   semantic_sha256=timed["baseline"][0]["semantic_sha256"],
                   paired_candidate_over_baseline=ratios,
                   median_paired_time_change_percent=100 * (statistics.median(ratios) - 1),
                   faster_pairs=sum(ratio < 1 for ratio in ratios))
        for variant, entries in timed.items():
            values = [entry["elapsed_ns"] / iterations for entry in entries]
            row[variant] = dict(median_ns=statistics.median(values),
                                min_ns=min(values), max_ns=max(values))
        if probe is not None:
            allocated = paired_samples(case, 1, "allocations")
            for variant, entries in allocated.items():
                if any(entry["semantic_sha256"] != row["semantic_sha256"] for entry in entries):
                    raise RuntimeError(f"Allocation instrumentation changed semantics: {case['id']}")
                row[variant]["allocation_requests"] = [entry["alloc_calls"] for entry in entries]
                row[variant]["requested_bytes"] = [entry["requested_bytes"] for entry in entries]
                row[variant]["median_alloc_calls"] = statistics.median(
                    row[variant]["allocation_requests"])
                row[variant]["median_requested_bytes"] = statistics.median(
                    row[variant]["requested_bytes"])
            row["median_requested_byte_change"] = (
                row["candidate"]["median_requested_bytes"] - row["baseline"]["median_requested_bytes"])
            byte_ratios = [
                candidate["requested_bytes"] / baseline["requested_bytes"]
                for baseline, candidate in zip(allocated["baseline"], allocated["candidate"])
                if baseline["requested_bytes"] > 0]
            row["paired_requested_byte_ratios"] = byte_ratios
            row["median_paired_requested_byte_change_percent"] = (
                100 * (statistics.median(byte_ratios) - 1) if byte_ratios else None)
        summary["workloads"].append(row)
        save(run.output / "summary.json", summary)
        print("EFFECT_RESULT " + json.dumps(row, sort_keys=True), flush=True)


def step_summary(summary):
    destination = os.environ.get("GITHUB_STEP_SUMMARY")
    if not destination:
        return
    with Path(destination).open("a") as stream:
        stream.write("## Effect retirement component qualification\n\n")
        stream.write(f"Status: **{summary['status']}**. Platform: **{sys.platform}**. "
                     f"Baseline: \x60{BASELINE}\x60.\n\n")
        stream.write("Exact complete production reducer/Core/StateSpace sources are compiled; "
                     "fixtures exercise a real source-replacement commit. Fixture preparation, "
                     "consumption and semantic validation are outside each measured event. "
                     "This does not qualify live playback or UI performance.\n\n")
        stream.write("| Scenario | Effects | Baseline μs/event | Candidate μs/event | "
                     "Median paired time change | Baseline requested bytes | Candidate requested bytes |\n")
        stream.write("|---|---:|---:|---:|---:|---:|---:|\n")
        for row in summary["workloads"]:
            stream.write(
                f"| {row['scenario']} | {row['count']} | "
                f"{row['baseline']['median_ns'] / 1000:.3f} | "
                f"{row['candidate']['median_ns'] / 1000:.3f} | "
                f"{row['median_paired_time_change_percent']:+.2f}% | "
                f"{row['baseline'].get('median_requested_bytes', 'not measured')} | "
                f"{row['candidate'].get('median_requested_bytes', 'not measured')} |\n")
        stream.write("\nAllocation medians come from separate Linux/glibc processes with a "
                     "thread-local successful malloc/calloc/realloc request probe. Timing "
                     "processes never preload it. Requested bytes are allocation traffic, "
                     "not retained memory, peak memory, RSS or object counts. Aligned "
                     "allocators and free are excluded. Linux timings do not establish "
                     "native macOS Foundation or playback performance.\n")


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
    if sys.platform not in ("linux", "darwin"):
        parser.error("Qualification supports Linux and macOS")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be new or empty; evidence is never overwritten")
    run = Run(output)
    summary = dict(status="running", baseline=BASELINE, platform=sys.platform,
                   tests=[], workloads=[])
    manifest = dict(
        baseline=BASELINE, platform=platform.platform(), machine=platform.machine(),
        libc=platform.libc_ver(), python_version=platform.python_version(), cpu_count=os.cpu_count(),
        timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        arguments=dict(pairs=args.pairs, target_ms=args.target_ms, output=str(output)),
        scope="Actual reducer source-replacement event; synthetic outstanding-effect populations",
        source_policy="Complete production files; no extraction, stubs or benchmark-specific reducers",
        compiler_note="Debug/release tests; release timing; identical -enable-testing flags",
        timing_probe="No LD_PRELOAD; setup and validation outside each measured core.update",
        excluded="Live player/UI, peak/retained/RSS memory, energy",
    )
    try:
        swift = shutil.which("swift")
        if not swift:
            raise RuntimeError("swift must be on PATH")
        manifest["swift_version"] = run.command([swift, "--version"], label="swift-version")
        manifest["head"] = run.command(["git", "rev-parse", "HEAD"], label="head")
        manifest["worktree_status"] = run.command(["git", "status", "--short"], label="status")
        sources, shared, tests = snapshots(run, manifest)
        save(output / "manifest.json", manifest)
        packages = stage(run, sources, shared, tests)
        binaries = build_and_test(run, packages, swift, summary, manifest)
        probe = build_allocation_probe(run, shared, manifest)
        save(output / "manifest.json", manifest)
        measure(run, binaries, probe, args, summary)
        summary["status"] = "passed"
        print("EFFECT_QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)
        print("EFFECT_MANIFEST " + json.dumps(manifest, sort_keys=True), flush=True)
        step_summary(summary)


if __name__ == "__main__":
    main()
