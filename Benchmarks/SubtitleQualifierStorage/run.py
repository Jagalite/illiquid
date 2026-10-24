#!/usr/bin/env python3
"""Qualify token-buffer ownership using complete production subtitle matchers."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCES = [
    "Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/ExternalSubtitleMatcherTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleMatcherEmptyTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleTokenizationTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleQualifierStorageTests.swift",
]
MEMORY_CASES = ["release16", "release256", "release4096", "release32768",
                "plain4096", "mixed4096", "unicode4096", "empty4096"]
TIMING_CASES = ["ascii_16", "ascii_256", "ascii_4096", "unicode_256", "mixed_256",
                "plain_4096", "mixed_qualifiers_4096"]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def check_sampling_phase(source):
    """Fail closed if the callback no longer samples the completed media index."""
    markers = ["public static func associate(", "        let index = TokenIndex()",
               "        for subtitleURL in subtitleURLs {"]
    if any(source.count(marker) != 1 for marker in markers):
        raise ValueError("Association sampling markers changed")
    begin, index, subtitle = [source.index(marker) for marker in markers]
    initial = source[begin:index]
    indexing = source[index:subtitle]
    guard = "guard !isCancelled() else { return [:] }"
    if (initial.count("isCancelled()") != 3 or initial.count(guard) != 2
            or "for mediaURL in mediaURLs {\n            " + guard not in initial
            or "return isCancelled() ? [:] : result" not in initial):
        raise ValueError("Initial/output-map cancellation cadence changed")
    if (indexing.count("isCancelled()") != 1 or indexing.count(guard) != 1
            or "for url in result.keys where MediaFileSupport.isSupportedMediaFile(url) {" not in indexing):
        raise ValueError("Media-index cancellation cadence changed")
    if not source[subtitle:].startswith(markers[2] + "\n            " + guard):
        raise ValueError("First-subtitle sample is no longer before processing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=int, default=250)
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--reuse-builds-from", type=Path,
                        help="Reuse hash-verified identical staged packages; requires --skip-tests")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("pairs must be even and >= 2; target-ms must be positive")
    if args.skip_tests and args.tests_only:
        parser.error("Conflicting test options")
    if args.reuse_builds_from and not args.skip_tests:
        parser.error("--reuse-builds-from requires --skip-tests")
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift 6.1 or newer is required on PATH")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    for path in SOURCES:
        entry = baseline["sources"][path]
        data = (HERE / "baseline" / entry["file"]).read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if blob != entry["git_blob"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Frozen baseline mismatch: " + path)
    env = os.environ.copy()
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    commands = []

    def command(argv, log=None, timeout=600):
        argv = [str(value) for value in argv]
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=timeout)
        commands.append({"argv": argv, "returncode": result.returncode})
        write_json(output / "commands.json", commands)
        if log:
            (output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-3000:]}\n{result.stderr[-9000:]}")
        return result.stdout

    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": command([swift, "--version"]).strip(),
        "candidate_commit": command(["git", "rev-parse", "HEAD"]).strip(),
        "worktree_status": command(["git", "status", "--porcelain=v1"]),
        "baseline": baseline, "sources": {}, "pairs": args.pairs,
        "target_cpu_ms": args.target_ms, "minimum_timing_iterations": 5,
        "runner_sha256": sha(__file__), "hashing": "SWIFT_DETERMINISTIC_HASHING=1",
        "protocol": "fresh process per sample; balanced AB/BA; first-subtitle poll samples the complete index; ordinary full-association CPU timed separately",
    }
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    reused = args.reuse_builds_from.resolve() if args.reuse_builds_from else None
    prior_manifest = json.loads((reused / "manifest.json").read_text()) if reused else None
    if reused:
        if prior_manifest["compiler"] != manifest["compiler"]:
            raise ValueError("Reused binaries have a different compiler")
        manifest["reused_builds_from"] = str(reused)
    binaries = {}
    for variant in ("baseline", "candidate"):
        package = output / variant
        for sub in ("Sources/IlliquidCore", "Sources/CMemoryProbe/include",
                    "Sources/MemoryDriver", "Sources/AssociationDriver", "Tests/IlliquidCoreTests"):
            (package / sub).mkdir(parents=True, exist_ok=True)
        for path in SOURCES:
            source = HERE / "baseline" / Path(path).name if variant == "baseline" else ROOT / path
            if path.endswith("ExternalSubtitleMatcher.swift"):
                check_sampling_phase(source.read_text())
            shutil.copyfile(source, package / "Sources/IlliquidCore" / source.name)
            manifest["sources"][variant + ":" + path] = sha(source)
        for path in TESTS:
            shutil.copyfile(ROOT / path, package / "Tests/IlliquidCoreTests" / Path(path).name)
            manifest["sources"][path] = sha(ROOT / path)
        for source, destination in [
            (HERE / "MemoryDriver.swift", "Sources/MemoryDriver/MemoryDriver.swift"),
            (HERE / "MemoryProbe.c", "Sources/CMemoryProbe/MemoryProbe.c"),
            (HERE / "MemoryProbe.h", "Sources/CMemoryProbe/include/MemoryProbe.h"),
            (HERE / "AssociationDriver.swift", "Sources/AssociationDriver/Driver.swift"),
        ]:
            shutil.copyfile(source, package / destination)
            manifest["sources"][str(source.relative_to(ROOT))] = sha(source)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleQualifierStorageQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "CMemoryProbe", publicHeadersPath: "include"),
    .executableTarget(name: "MemoryDriver", dependencies: ["IlliquidCore", "CMemoryProbe"]),
    .executableTarget(name: "AssociationDriver", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
        write_json(output / "manifest.json", manifest)
        flags = ["--package-path", package, "--jobs", "2", "-Xswiftc", "-warnings-as-errors",
                 "--cache-path", output / "cache", "--config-path", output / "config",
                 "--security-path", output / "security"]
        if not args.skip_tests:
            for configuration in ("debug", "release"):
                print(f"Testing {variant} {configuration}", flush=True)
                command([swift, "test", *flags, "-c", configuration],
                        log=f"{variant}-{configuration}-tests.log")
        if args.tests_only:
            continue
        if reused:
            for key, digest in manifest["sources"].items():
                if prior_manifest["sources"].get(key) != digest:
                    raise ValueError("Reused historical source receipt differs: " + key)
            files = [package / "Package.swift"]
            files += sorted(p for directory in ("Sources", "Tests")
                            for p in (package / directory).rglob("*") if p.is_file())
            previous_package = reused / variant
            previous_files = [previous_package / "Package.swift"]
            previous_files += sorted(p for directory in ("Sources", "Tests")
                                     for p in (previous_package / directory).rglob("*") if p.is_file())
            if ({p.relative_to(package) for p in files}
                    != {p.relative_to(previous_package) for p in previous_files}):
                raise ValueError("Reused package file set differs: " + variant)
            for path in files:
                previous = reused / variant / path.relative_to(package)
                if not previous.is_file() or sha(previous) != sha(path):
                    raise ValueError("Reused package differs: " + str(path))
            binpath = reused / variant / ".build/release"
            for name in ("MemoryDriver", "AssociationDriver"):
                if sha(binpath / name) != prior_manifest["binaries"][variant][name]:
                    raise ValueError("Reused binary hash differs: " + name)
            print(f"Reusing verified {variant} release binaries", flush=True)
        else:
            print(f"Building {variant} release measurements", flush=True)
            command([swift, "build", *flags, "-c", "release"], log=f"{variant}-build.log")
            binpath = Path(command([swift, "build", "--package-path", package,
                                   "-c", "release", "--show-bin-path"]).strip())
        binaries[variant] = {name: binpath / name for name in ("MemoryDriver", "AssociationDriver")}
        manifest.setdefault("binaries", {})[variant] = {k: sha(v) for k, v in binaries[variant].items()}
        write_json(output / "manifest.json", manifest)
    if args.tests_only:
        return

    verification = {}
    for variant in binaries:
        verification[variant] = json.loads(command([binaries[variant]["AssociationDriver"], "--verify"],
                                                   log=f"{variant}-associations.json"))
    if verification["baseline"] != verification["candidate"]:
        raise ValueError("Complete association outputs differ")
    write_json(output / "parity.json", {"status": "passed", "record_count": verification["baseline"]["recordCount"]})

    memory = []
    timing = []
    for case in MEMORY_CASES:
        print("Memory " + case, flush=True)
        for pair in range(args.pairs):
            rows = {}
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for position, variant in enumerate(order):
                row = json.loads(command([binaries[variant]["MemoryDriver"], case], timeout=180))
                row.update(variant=variant, pair=pair, order_index=position)
                memory.append(row)
                rows[variant] = row
                with (output / "memory.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            for field in ("all_output_checksum", "media_count", "subtitle_count", "sampled_poll"):
                if rows["baseline"][field] != rows["candidate"][field]:
                    raise ValueError(f"Memory cohort output differs: {case}/{field}")

    for case in TIMING_CASES:
        def timed(variant, iterations):
            row = json.loads(command([binaries[variant]["AssociationDriver"], "--case", case,
                                      "--iterations", iterations, "--warmup", "4"], timeout=180))
            if row["checksum"] != row["expectedChecksum"]:
                raise ValueError("Timing output mismatch")
            return row
        pilot = timed("baseline", 1)
        # A slow one-shot pilot must not reduce a sample to one association.
        iterations = max(5, min(100000, math.ceil(args.target_ms * 1e6 / pilot["cpuNsPerLookup"])))
        print(f"Timing {case}: {iterations} associations per sample", flush=True)
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for position, variant in enumerate(order):
                row = timed(variant, iterations)
                row.update(variant=variant, case=case, pair=pair, order_index=position)
                timing.append(row)
                with (output / "timing.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")

    summary = {"memory": [], "timing": [], "pairs": args.pairs}
    for kind, rows, cases in (("memory", memory, MEMORY_CASES), ("timing", timing, TIMING_CASES)):
        for case in cases:
            entry = {"case": case}
            for variant in ("baseline", "candidate"):
                selected = [r for r in rows if r["case"] == case and r["variant"] == variant]
                keys = [k for k, v in selected[0].items() if isinstance(v, (int, float))
                        and k not in {"pair", "order_index"}]
                values = {key: {"min": min(r[key] for r in selected),
                                "median": statistics.median(r[key] for r in selected),
                                "max": max(r[key] for r in selected)} for key in keys}
                if kind == "memory" and all(r["heap_index"] is not None for r in selected):
                    deltas = [r["heap_index"] - r["heap_before"] for r in selected]
                    values["index_heap_delta"] = {"min": min(deltas), "median": statistics.median(deltas), "max": max(deltas)}
                if kind == "memory":
                    deltas = [r["heap_after"] - r["heap_before"] for r in selected]
                    values["return_heap_delta"] = {"min": min(deltas), "median": statistics.median(deltas), "max": max(deltas)}
                entry[variant] = values
            summary[kind].append(entry)
    write_json(output / "summary.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
