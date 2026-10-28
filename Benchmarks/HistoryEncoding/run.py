#!/usr/bin/env python3
"""Compare complete production history writes against the pinned pre-change source.

Measures changed mutation + synchronous writer flush + UserDefaults.set, not
isolated encoder CPU time, disk fsync, player RSS, or playback frame rate.
"""
import argparse
import gzip
import hashlib
import json
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
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
STORE = "Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift"
SOURCES = [
    STORE,
    "Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift",
    "Sources/IlliquidCore/Persistence/PlaybackPreferences.swift",
    "Sources/IlliquidCore/Persistence/PlaybackRestoreTarget.swift",
    "Sources/IlliquidCore/Persistence/MediaPlaybackSettings.swift",
    "Sources/IlliquidCore/Persistence/MediaContentVersion.swift",
    "Sources/IlliquidCore/Player/MediaTrack.swift",
    "Sources/IlliquidCore/Player/TrackSelectionPreferences.swift",
    "Sources/IlliquidCore/Player/SubtitleFallbackEncoding.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NonDecodePerformance.swift",
]
# Exact complete declarations, extracted from their current production owners.
# Their unrelated neighbors need the UI/geometry graph; these enums do not.
ENUMS = {
    "Sources/IlliquidCore/Player/PlaybackModels.swift": "HardwareDecodingPolicy",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift": "PlaybackRepeatMode",
}
EXISTING_TESTS = [
    "PlaybackPersistenceStoreTests.swift", "HistoryPolicyTests.swift",
    "DeferredPersistenceTests.swift", "IdempotentPersistenceTests.swift",
    "PersistenceWriterTests.swift", "PersistenceWriterLifetimeTests.swift",
    "PlaybackHistoryScalingTests.swift",
]
NEW_TESTS = ["HistoryEncodingTests.swift"]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Run:
    def __init__(self, output):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.sequence = 0

    def command(self, args, *, cwd=ROOT, env=None, label="command", timeout=600):
        self.sequence += 1
        args = [str(value) for value in args]
        log = self.logs / f"{self.sequence:04d}-{label}.log"
        before = time.monotonic()
        try:
            result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            log.write_bytes((error.stdout or b"") + (error.stderr or b""))
            with (self.output / "commands.jsonl").open("a") as stream:
                stream.write(json.dumps(dict(args=args, cwd=str(cwd),
                    elapsed_seconds=time.monotonic() - before, returncode=None,
                    timed_out=True, log=str(log.relative_to(self.output)))) + "\n")
            raise RuntimeError(f"Command timed out after {timeout}s; see {log}") from error
        log.write_bytes(result.stdout + result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(args=args, cwd=str(cwd),
                elapsed_seconds=time.monotonic() - before, returncode=result.returncode,
                log=str(log.relative_to(self.output)))) + "\n")
        if result.returncode:
            print(log.read_text(errors="replace"), file=sys.stderr, flush=True)
            raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
        return result.stdout.decode().strip()


def snapshot_sources(run, manifest):
    result = {}
    for variant in ["baseline", "candidate"]:
        directory = run.output / "sources" / variant
        directory.mkdir(parents=True)
        result[variant] = []
        hashes = manifest[variant + "_sources"] = {}
        enums = []
        for path in [*SOURCES, *ENUMS]:
            raw = (subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                   if variant == "baseline" else (ROOT / path).read_bytes())
            compiled = raw
            if path in ENUMS:
                name = ENUMS[path]
                matches = re.findall(rf"(?ms)^public enum {name}: [^\n]+\n.*?^}}", raw.decode())
                if len(matches) != 1:
                    raise RuntimeError(f"Expected one complete {name} declaration in {path}")
                compiled = (matches[0] + "\n").encode()
                enums.append(compiled)
                (directory / (Path(path).stem + ".full-source.txt")).write_bytes(raw)
            else:
                target = directory / Path(path).name
                target.write_bytes(compiled)
                result[variant].append(target)
            hashes[path] = dict(full_sha256=sha256(raw), compiled_sha256=sha256(compiled))
        enum_file = directory / "PersistenceEnums.swift"
        enum_file.write_bytes(b"// Unchanged enums extracted from the hashed production files.\n" + b"\n".join(enums))
        result[variant].append(enum_file)
    for path in [*SOURCES, *ENUMS]:
        if path != STORE and manifest["baseline_sources"][path] != manifest["candidate_sources"][path]:
            raise RuntimeError(f"Unrelated production dependency changed: {path}")
    for filename in ["Harness.swift", "run.py"]:
        raw = (HERE / filename).read_bytes()
        (run.output / "sources" / filename).write_bytes(raw)
        manifest[filename + "_sha256"] = sha256(raw)
    diff = subprocess.run(["git", "diff", BASELINE, "--", STORE], cwd=ROOT,
                          capture_output=True, check=True).stdout
    (run.output / "production-change.patch").write_bytes(diff)
    manifest["production_change_sha256"] = sha256(diff)
    return result


def build_benchmarks(run, sources, swiftc, manifest):
    binaries = {}
    target_flags = []
    if sys.platform == "darwin":
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], label="macos-sdk")
        target_flags = ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    for variant, files in sources.items():
        directory = run.output / "build" / variant
        directory.mkdir(parents=True)
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
                 "-module-cache-path", directory / "module-cache", *target_flags]
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        library = directory / ("libIlliquidCore" + suffix)
        run.command([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", directory / "IlliquidCore.swiftmodule", *files,
                     "-o", library], label=f"build-{variant}-library")
        binary = directory / "history-encoding"
        run.command([swiftc, *flags, "-parse-as-library", "-I", directory, "-L", directory,
                     "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory,
                     run.output / "sources" / "Harness.swift", "-o", binary],
                    label=f"build-{variant}-harness")
        binaries[variant] = binary
        manifest[variant + "_library_sha256"] = sha256(library.read_bytes())
        manifest[variant + "_binary_sha256"] = sha256(binary.read_bytes())
    return binaries


def run_tests(run, sources, swift, manifest, summary):
    for variant, files in sources.items():
        package = run.output / "build" / (variant + "-tests")
        source_directory = package / "Sources" / "IlliquidCore"
        test_directory = package / "Tests" / "IlliquidCoreTests"
        source_directory.mkdir(parents=True)
        test_directory.mkdir(parents=True)
        for source in files:
            shutil.copy2(source, source_directory)
        tests = EXISTING_TESTS + (NEW_TESTS if variant == "candidate" else [])
        hashes = manifest[variant + "_test_sha256"] = {}
        for name in tests:
            source = ROOT / "Tests" / "IlliquidCoreTests" / name
            shutil.copy2(source, test_directory)
            hashes[name] = sha256(source.read_bytes())
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "HistoryEncodingQualification",
    platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
              .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
''')
        env = os.environ.copy()
        env["CLANG_MODULE_CACHE_PATH"] = str(package / "module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(package / "module-cache")
        for configuration in ["debug", "release"]:
            run.command([swift, "test", "--package-path", package,
                         "--scratch-path", package / "build", "--cache-path", package / "cache",
                         "--config-path", package / "config", "--security-path", package / "security",
                         "-c", configuration, "--no-parallel", "--jobs", "2",
                         "-Xswiftc", "-warnings-as-errors"], env=env,
                        label=f"tests-{variant}-{configuration}", timeout=1200)
            summary["tests"].append(dict(variant=variant, configuration=configuration,
                                         files=tests, passed=True))
            save(run.output / "summary.json", summary)
            print(f"Passed {variant} {configuration} persistence suites", flush=True)


def workloads(quick):
    counts = [1, 1000] if quick else [1, 1000, 10000]
    profiles = ["normal", "deep", "escaped"] if quick else ["short", "normal", "deep", "escaped"]
    return [dict(count=0, profile="normal", id="empty-0")] + [
        dict(count=count, profile=profile, id=f"{profile}-{count}")
        for count in counts for profile in profiles]


def semantic_value(raw):
    result = json.loads(raw)
    # This is the sole unordered array in StoredState. Never sort replacement
    # histories, track language preferences, or arbitrary future arrays.
    result["completedFiles"] = sorted(result["completedFiles"])
    return result


def count_slashes(value):
    if isinstance(value, str):
        return value.count("/")
    if isinstance(value, dict):
        return sum(key.count("/") + count_slashes(item) for key, item in value.items())
    if isinstance(value, list):
        return sum(count_slashes(item) for item in value)
    return 0


def verify_shape(value, count):
    if len(value["playbackDurations"]) != count:
        raise RuntimeError("Duration inventory differs from the constructed fixture")
    completed = count // 7
    expected = {
        "playbackPositions": count - completed,
        "completedFiles": completed,
        "mediaSettings": (count + 15) // 16,
        "mediaVersions": (count + 15) // 16,
        "replacedHistory": (count + 31) // 32,
    }
    for key, expected_count in expected.items():
        if len(value[key]) != expected_count:
            raise RuntimeError(f"Unexpected {key} inventory: {len(value[key])} != {expected_count}")


def benchmark(run, binaries, args, summary):
    payload_directory = run.output / "payloads"
    payload_directory.mkdir()
    temporary_payload = run.output / "build" / "last-payload.json"
    for workload in workloads(args.quick):
        rows = {"baseline": [], "candidate": []}
        reference = None
        reference_canonical = None
        slash_count = None
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for variant in order:
                raw_receipt = run.command([binaries[variant], workload["count"], workload["profile"],
                    args.iterations, temporary_payload], label=f"{workload['id']}-{pair}-{variant}")
                row = json.loads(raw_receipt)
                for key in ["count", "profile"]:
                    if row[key] != workload[key]:
                        raise RuntimeError(f"Mismatched workload {key}")
                if row["iterations"] != args.iterations or row["writes"] != args.iterations:
                    raise RuntimeError("Wrong write/iteration count")
                raw = temporary_payload.read_bytes()
                value = semantic_value(raw)
                canonical = json.dumps(value, sort_keys=True, ensure_ascii=False,
                                       separators=(",", ":")).encode()
                verify_shape(value, workload["count"])
                if reference is None:
                    reference = value
                    reference_canonical = canonical
                    slash_count = count_slashes(value)
                elif value != reference or canonical != reference_canonical:
                    raise RuntimeError(f"Complete decoded history differs for {workload['id']} {variant}")
                if row["final_payload_bytes"] != len(raw):
                    raise RuntimeError("Receipt does not describe the exported payload")
                if not rows[variant]:
                    # Retain one complete output per variant; later samples are
                    # fully compared in memory and retain their raw hashes.
                    artifact = payload_directory / f"{workload['id']}-{variant}.json.gz"
                    artifact.write_bytes(gzip.compress(raw, mtime=0))
                row.update(variant=variant, pair=pair, workload=workload["id"],
                           payload_sha256=sha256(raw), semantic_sha256=sha256(canonical),
                           complete_semantic_comparison_passed=True, decoded_slashes=slash_count)
                rows[variant].append(row)
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                print(f"{workload['id']} pair {pair + 1}/{args.pairs}: {variant}", flush=True)
            baseline_row = rows["baseline"][-1]
            candidate_row = rows["candidate"][-1]
            if baseline_row["final_payload_bytes"] - candidate_row["final_payload_bytes"] != slash_count:
                raise RuntimeError("Payload reduction is not exactly one byte per decoded slash")
        entry = dict(workload, pairs=args.pairs, iterations=args.iterations,
                     bytes_saved=slash_count, complete_semantic_comparison_passed=True)
        for variant, samples in rows.items():
            medians = [statistics.median(row["mutation_flush_ns"]) for row in samples]
            means = [statistics.mean(row["mutation_flush_ns"]) for row in samples]
            entry[variant] = dict(payload_bytes=samples[0]["final_payload_bytes"],
                median_mutation_flush_ns=statistics.median(medians),
                min_process_median_ns=min(medians), max_process_median_ns=max(medians),
                median_process_mean_ns=statistics.median(means),
                process_medians_ns=medians, process_means_ns=means)
        entry["payload_reduction_percent"] = 100 * slash_count / entry["baseline"]["payload_bytes"]
        ratios = [statistics.median(candidate["mutation_flush_ns"]) /
                  statistics.median(baseline["mutation_flush_ns"])
                  for baseline, candidate in zip(rows["baseline"], rows["candidate"])]
        entry["paired_time_ratios"] = ratios
        entry["median_paired_time_change_percent"] = 100 * (statistics.median(ratios) - 1)
        summary["workloads"].append(entry)
        save(run.output / "summary.json", summary)
        print(json.dumps(entry, sort_keys=True), flush=True)
    temporary_payload.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "benchmark", "tests"], default="all")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--iterations", type=int, default=11)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--queued", action="store_true", help="The entire runner was submitted through Kyoto")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not 1 <= args.iterations <= 100:
        parser.error("Use an even number of at least two pairs and 1...100 iterations")
    if KYOTO.exists() and not args.queued:
        parser.error(f"Submit this runner via {KYOTO} submit -- python3 ... --queued")
    if not KYOTO.exists():
        print("Kyoto is unavailable here; compiling the isolated portable qualification directly.", flush=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be new or empty; existing evidence is never overwritten")
    run = Run(output)
    summary = dict(status="running", baseline=BASELINE, mode=args.mode, tests=[], workloads=[],
        measurement_scope="changed mutation + production writer flush + real UserDefaults.set; not fsync",
        unqualified=["isolated encoder CPU", "disk durability", "whole-player RSS", "playback frame rate"])
    manifest = dict(baseline=BASELINE, platform=platform.platform(), machine=platform.machine(),
        python_version=platform.python_version(), cpu_count=os.cpu_count(),
        timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        arguments={**vars(args), "output": str(output)}, kyoto_available=KYOTO.exists())
    try:
        swift = shutil.which("swift")
        swiftc = shutil.which("swiftc")
        if not swift or not swiftc:
            raise RuntimeError("swift and swiftc must be on PATH")
        manifest["swift_version"] = run.command([swift, "--version"], label="swift-version")
        manifest["head"] = run.command(["git", "rev-parse", "HEAD"], label="head")
        manifest["worktree_status"] = run.command(["git", "status", "--short"], label="status")
        sources = snapshot_sources(run, manifest)
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)
        if args.mode in ["all", "tests"]:
            run_tests(run, sources, swift, manifest, summary)
            save(output / "manifest.json", manifest)
        if args.mode in ["all", "benchmark"]:
            binaries = build_benchmarks(run, sources, swiftc, manifest)
            save(output / "manifest.json", manifest)
            benchmark(run, binaries, args, summary)
        summary["status"] = "complete"
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
