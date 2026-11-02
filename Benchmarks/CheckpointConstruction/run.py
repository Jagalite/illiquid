#!/usr/bin/env python3
"""Qualify checkpoint regressions or measure construction against a fixed revision."""
import argparse
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
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
]
PLAYER = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
TESTS = [
    "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift",
    "Tests/IlliquidPlayerTests/PlaybackCheckpointIndexHintTests.swift",
    "Tests/IlliquidCoreTests/PlaylistSessionRecordTests.swift",
    "Tests/IlliquidCoreTests/PlaylistDeduplicationTests.swift",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def workloads(quick):
    sizes = [0, 1, 32, 1000] if quick else [0, 1, 32, 1000, 10000]
    cases = [(s, n) for n in sizes for s in ("no-folder-last", "folder-last")]
    for count in ([32] if quick else [32, 1000, 10000]):
        cases += [(s, count) for s in ("no-folder-first", "folder-first", "folder-missing")]
    cases += [(s, 1000) for s in (
        "no-folder-missing", "folder-middle", "folder-unicode", "no-folder-unicode",
        "folder-unsupported-source", "folder-remote", "folder-invalid-items",
        "folder-mixed-items", "folder-duplicates",
    )]
    return [dict(scenario=s, count=n, id=f"{s}/{n}") for s, n in cases]


class Run:
    def __init__(self, output):
        self.output = output
        (output / "logs").mkdir()
        self.sequence = 0

    def command(self, argv, label, cwd=ROOT, raw=False):
        self.sequence += 1
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        start = time.monotonic()
        env = os.environ.copy()
        env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "build" / "module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = env["CLANG_MODULE_CACHE_PATH"]
        result = subprocess.run([str(a) for a in argv], cwd=cwd, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_bytes(result.stdout)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(argv=[str(a) for a in argv], cwd=str(cwd),
                exit_code=result.returncode, elapsed_seconds=time.monotonic() - start,
                log=str(log.relative_to(self.output)), log_sha256=digest(result.stdout))) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}): {log}\n"
                               + result.stdout.decode(errors="replace")[-5000:])
        return result.stdout if raw else result.stdout.decode().strip()


def compiled_source(path, raw):
    if path.endswith("PlaybackSessionStore.swift"):
        marker = b"\n/// A versioned, atomic Application Support document"
        if raw.count(marker) != 1:
            raise RuntimeError("Session record/protocol extraction boundary changed")
        return raw.split(marker)[0] + b"\n"
    return raw


def stage(run, manifest, regression_only=False):
    # Capture live inputs once. Both variants and every configuration consume
    # these snapshots even if the checkout changes after staging.
    current = {path: (ROOT / path).read_bytes() for path in CORE + [PLAYER]}
    harness_paths = [HERE / "Driver.swift", Path(__file__).resolve()] + [ROOT / p for p in TESTS]
    harness = {str(path.relative_to(ROOT)): path.read_bytes() for path in harness_paths}
    historical = {path: run.command(["git", "show", f"{BASELINE}:{path}"],
        f"baseline-{Path(path).stem}", raw=True) for path in CORE + [PLAYER]}
    manifest["historical_sources"] = {}
    for path, raw in historical.items():
        # Preserve the actual historical support even when it is not compiled.
        data = compiled_source(path, raw)
        snapshot = run.output / "sources" / "historical" / path
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(raw)
        manifest["historical_sources"][path] = dict(
            source_revision=BASELINE, full_sha256=digest(raw), compiled_sha256=digest(data),
            full_snapshot=str(snapshot.relative_to(run.output)))

    variants = {}
    manifest["sources"] = {}
    for variant in ("baseline", "candidate"):
        directory = run.output / "sources" / variant
        directory.mkdir(parents=True)
        files = {"IlliquidCore": [], "IlliquidPlayer": []}
        manifest["sources"][variant] = {}
        for path in CORE + [PLAYER]:
            use_current = variant == "candidate" or (regression_only and path in CORE)
            raw = current[path] if use_current else historical[path]
            data = compiled_source(path, raw)
            destination = directory / Path(path).name
            destination.write_bytes(data)
            full_destination = directory / "full" / Path(path).name
            full_destination.parent.mkdir(exist_ok=True)
            full_destination.write_bytes(raw)
            module = "IlliquidPlayer" if path == PLAYER else "IlliquidCore"
            files[module].append(destination)
            manifest["sources"][variant][path] = dict(
                origin="current-worktree" if use_current else "pinned-baseline",
                source_revision=manifest["head"] if use_current else BASELINE,
                full_sha256=digest(raw), compiled_sha256=digest(data),
                full_snapshot=str(full_destination.relative_to(run.output)),
                compiled_snapshot=str(destination.relative_to(run.output)),
                transformation="prefix before atomic disk store marker plus newline"
                    if path.endswith("PlaybackSessionStore.swift") else "none",
                differs_from_historical=raw != historical[path])
        variants[variant] = files
    for path in CORE:
        if any(manifest["sources"]["baseline"][path][key] !=
               manifest["sources"]["candidate"][path][key]
               for key in ("full_sha256", "compiled_sha256")):
            raise RuntimeError(f"Unrelated benchmark dependency changed: {path}")
    manifest["harness_sha256"] = {}
    for path, data in harness.items():
        destination = run.output / "sources" / Path(path).name
        destination.write_bytes(data)
        manifest["harness_sha256"][path] = digest(data)
    return variants


def test(run, variants, summary):
    package_text = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "CheckpointQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidPlayer", "IlliquidCore"])
])
'''
    summary["tests"] = []
    for variant, modules in variants.items():
        package = run.output / "build" / f"{variant}-tests"
        for module, files in modules.items():
            directory = package / "Sources" / module
            directory.mkdir(parents=True)
            for path in files:
                shutil.copy2(path, directory)
        for path in TESTS:
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(run.output / "sources" / Path(path).name, destination)
        (package / "Package.swift").write_text(package_text)
        for configuration in ("debug", "release"):
            argv = ["swift", "test", "--package-path", package, "--scratch-path", package / "build",
                    "--cache-path", package / "cache", "--config-path", package / "config",
                    "--security-path", package / "security", "--jobs", "2", "--no-parallel",
                    "-c", configuration, "-Xswiftc", "-warnings-as-errors"]
            if sys.platform == "linux":
                argv += ["--use-integrated-swift-driver"]
            log = run.command(argv, f"tests-{variant}-{configuration}")
            counts = re.findall(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log)
            if not counts or int(counts[-1]) == 0:
                raise RuntimeError("No successful Swift Testing count found")
            xctest = re.search(
                r"Test Suite 'PlaybackCheckpointIndexHintTests' passed[^\n]*\n"
                r"\s*Executed (\d+) tests?, with 0 failures", log)
            if not xctest or int(xctest[1]) < 6:
                raise RuntimeError("Checkpoint index-hint XCTest suite did not execute completely")
            summary["tests"].append(dict(variant=variant, configuration=configuration,
                                         passed=int(counts[-1]), xctest_passed=int(xctest[1])))
            save(run.output / "summary.json", summary)


def build(run, variants, manifest):
    native_flags = []
    if sys.platform == "darwin":
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")
        native_flags = ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    binaries = {}
    manifest["binaries"] = {}
    for variant, modules in variants.items():
        directory = run.output / "build" / variant
        directory.mkdir(parents=True)
        flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
                 "-module-cache-path", directory / "module-cache", *native_flags]
        libraries = []
        for module, files in modules.items():
            library = directory / (f"lib{module}" + (".dylib" if sys.platform == "darwin" else ".so"))
            links = [] if module == "IlliquidCore" else ["-I", directory, "-L", directory,
                "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory]
            run.command(["swiftc", *flags, "-enable-testing", "-emit-library", "-emit-module",
                "-module-name", module, "-emit-module-path", directory / f"{module}.swiftmodule",
                *links, *files, "-o", library], f"build-{variant}-{module}")
            libraries.append(library)
        binary = directory / "checkpoint-benchmark"
        run.command(["swiftc", *flags, "-parse-as-library", "-I", directory, "-L", directory,
            "-lIlliquidPlayer", "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory,
            run.output / "sources" / "Driver.swift", "-o", binary], f"build-{variant}-driver")
        binaries[variant] = binary
        for path in libraries + [binary]:
            manifest["binaries"][str(path.relative_to(run.output))] = digest(path.read_bytes())
    return binaries


def measure(run, binaries, args, summary):
    if args.regression_only:
        raise RuntimeError("Regression-only snapshots cannot qualify historical performance")
    cases = workloads(args.quick)
    save(run.output / "workloads.json", cases)
    summary["workloads"] = []
    calibration = []

    def sample(variant, case, iterations, label):
        result = json.loads(run.command([binaries[variant], case["scenario"], case["count"], iterations], label))
        for key in ("scenario", "count"):
            if result[key] != case[key]:
                raise RuntimeError(f"Wrong workload: {case}, {result}")
        if result["iterations"] != iterations or result["elapsed_ns"] <= 0 or result["cpu_ns"] <= 0:
            raise RuntimeError(f"Invalid observation: {result}")
        return dict(result, variant=variant, workload=case["id"])

    for case in cases:
        iterations = 1
        # Calibrate both variants to keep even fast candidate observations long
        # enough to measure. Every pair uses the same final iteration count.
        for _ in range(3):
            pilots = [sample(v, case, iterations, f"pilot-{v}") for v in binaries]
            calibration.extend(pilots)
            save(run.output / "calibration.json", calibration)
            fastest = min(min(p["elapsed_ns"], p["cpu_ns"]) for p in pilots)
            if fastest >= args.target_ms * 800_000 or iterations >= 2_000_000:
                break
            iterations = min(2_000_000, max(iterations + 1,
                math.ceil(iterations * args.target_ms * 1_000_000 / fastest)))
        observations = {v: [] for v in binaries}
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            paired = []
            for variant in order:
                observation = dict(sample(variant, case, iterations, f"pair-{pair}-{variant}"), pair=pair)
                observations[variant].append(observation)
                paired.append(observation)
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(observation, sort_keys=True) + "\n")
            for key in ("output_fingerprint", "output_count", "checksum"):
                if paired[0][key] != paired[1][key]:
                    raise RuntimeError(f"Paired output mismatch ({key}): {paired}")
        row = dict(case, iterations=iterations, pairs=args.pairs)
        for variant, values in observations.items():
            row[variant] = {}
            for metric in ("elapsed_ns", "cpu_ns"):
                samples = [v[metric] / iterations for v in values]
                row[variant][metric] = dict(median=statistics.median(samples), min=min(samples), max=max(samples))
            row[variant]["minimum_loop_ns"] = min(v["elapsed_ns"] for v in values)
            row[variant]["minimum_cpu_loop_ns"] = min(v["cpu_ns"] for v in values)
            row[variant]["duration_qualified"] = all(
                min(v["elapsed_ns"], v["cpu_ns"]) >= args.target_ms * 250_000 for v in values)
        for metric in ("elapsed_ns", "cpu_ns"):
            paired_ratios = [c[metric] / b[metric] for b, c in zip(
                observations["baseline"], observations["candidate"])]
            row[metric + "_paired_change_percent"] = 100 * (statistics.median(paired_ratios) - 1)
        summary["workloads"].append(row)
        save(run.output / "summary.json", summary)
        print(json.dumps(row, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    parser.add_argument("--regression-only", action="store_true",
        help="Run both writers' debug/release tests with identical current CORE support; no timing")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    if args.regression_only:
        if args.mode == "benchmark":
            parser.error("--regression-only cannot measure a historical performance comparison")
        args.mode = "tests"
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >=2 and a positive finite target duration")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output directory must be empty or nonexistent")
    run = Run(output)
    qualification = "current-support-regression" if args.regression_only else "historical"
    summary = dict(status="running", baseline=BASELINE, mode=args.mode,
                   qualification=qualification, performance_measured=False)
    manifest = dict(baseline=BASELINE, platform=platform.platform(), machine=platform.machine(),
        python=platform.python_version(), timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        arguments=vars(args) | {"output": str(output)}, qualification=qualification,
        performance_measured=False,
        source_policy="Pinned PlaybackCheckpointWriter; identical current CORE support in both variants"
            if args.regression_only else "Pinned baseline; reject CORE supporting-source drift",
        minimum_sample_ms=args.target_ms / 4,
        maximum_iterations=2_000_000,
        scope="complete PlaybackCheckpoint.record construction and release; no encoding or disk I/O")
    try:
        if not shutil.which("swift") or not shutil.which("swiftc"):
            raise RuntimeError("Swift 6.1+ must be on PATH")
        manifest["swift"] = run.command(["swift", "--version"], "swift-version")
        manifest["head"] = run.command(["git", "rev-parse", "HEAD"], "head")
        manifest["worktree_status"] = run.command(["git", "status", "--short"], "status")
        if sys.platform == "darwin":
            manifest["cpu"] = run.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu")
        else:
            manifest["cpu"] = next((line for line in Path("/proc/cpuinfo").read_text().splitlines()
                                    if line.startswith("model name")), "unknown")
        variants = stage(run, manifest, args.regression_only)
        save(output / "manifest.json", manifest)
        if args.mode in ("all", "tests"):
            test(run, variants, summary)
        if args.mode in ("all", "benchmark"):
            binaries = build(run, variants, manifest)
            save(output / "manifest.json", manifest)
            measure(run, binaries, args, summary)
            summary["performance_measured"] = manifest["performance_measured"] = True
        summary["status"] = "passed"
        print("REGRESSION_PASS" if args.regression_only else "QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
