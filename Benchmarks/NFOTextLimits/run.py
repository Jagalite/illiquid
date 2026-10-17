#!/usr/bin/env python3
"""Measure complete NFO metadata parsing against a pinned baseline.

Requires Swift 6.1+ and Python 3.10+. Uses a temporary Swift package for the
existing and new tests; does not resolve the native app's dependencies.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
from pathlib import Path

BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCES = [
    "MediaLibrary/MediaNameRecognition.swift",
    "MediaLibrary/MediaMetadataHints.swift",
    "MediaLibrary/NFOMetadataHints.swift",
    "MediaLibrary/PlexMatchHints.swift",
    "MediaLibrary/MediaSidecarReader.swift",
]
TESTS = [
    "MediaSidecarTests.swift",
    "NFOMetadataFieldSelectionTests.swift",
    "NFOEpisodeScopeRegressionTests.swift",
    "MediaNameRecognitionTests.swift",
    "NFOTextLimitPerformanceTests.swift",
]
CASE_ITERATIONS = {
    "movie-small": 5_000,
    "episode-small": 3_000,
    "unicode-small": 3_000,
    "ascii-boundary-4096": 400,
    "ascii-fragmented-4096": 20,
    "unicode-fragmented-4095-bytes": 8,
    "unicode-fallback-2500": 300,
    "unicode-fallback-fragmented": 64,
    "combining-cdata": 30,
    "ignored-long-plot": 1_000,
    "ascii-over-limit-4097": 400,
    "malformed-xml": 5_000,
    "doctype-rejected": 20_000,
}


def blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()


def run(command: list[str], log: Path | None = None) -> str:
    completed = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log is not None:
        log.write_text(completed.stdout)
    if completed.returncode:
        print(completed.stdout, flush=True)
        raise subprocess.CalledProcessError(completed.returncode, command, completed.stdout)
    return completed.stdout


def swift_tests(root: Path, sources: Path, output: Path, work: Path, variant: str) -> dict:
    package = work / f"tests-{variant}"
    source_dir = package / "Sources/IlliquidCore"
    test_dir = package / "Tests/IlliquidCoreTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    for relative in SOURCES:
        shutil.copy2(sources / "Sources/IlliquidCore" / relative, source_dir)
    # Both implementations receive the same current regression tests.
    for relative in TESTS:
        shutil.copy2(root / "Tests/IlliquidCoreTests" / relative, test_dir)
    (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "NFOTextLimitRegressions",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
""")
    result = {}
    for configuration in ("debug", "release"):
        command = ["swift", "test", "--package-path", str(package),
                   "--configuration", configuration, "--no-parallel"]
        log = output / f"{variant}-{configuration}-tests.txt"
        text = run(command, log)
        summaries = [line for line in text.splitlines() if "Test run with " in line]
        count = re.search(r"Test run with ([1-9][0-9]*) tests?", summaries[-1]) if summaries else None
        if count is None or "NFO text limit regressions" not in text:
            raise RuntimeError(f"Expected nonempty Swift Testing run and NFO text-limit suite in {log}")
        result[configuration] = {
            "command": command, "summary": summaries[-1], "test_count": int(count.group(1))
        }
        print(variant, configuration, summaries[-1], flush=True)
    return result


def summary(rows: list[dict], case: str) -> dict:
    measured = [row for row in rows if row["case"] == case and row["round"] >= 0]
    values = {
        variant: [row["nanoseconds_per_operation"] / 1_000_000
                  for row in measured if row["variant"] == variant]
        for variant in ("baseline", "candidate")
    }
    result = {}
    for variant, times in values.items():
        result[variant] = {
            "median_ms": statistics.median(times),
            "min_ms": min(times),
            "max_ms": max(times),
            "samples": len(times),
        }
    by_round = {}
    for row in measured:
        by_round.setdefault(row["round"], {})[row["variant"]] = row["nanoseconds_per_operation"]
    ratios = [pair["candidate"] / pair["baseline"] for pair in by_round.values()]
    result["median_paired_ratio"] = statistics.median(ratios)
    result["candidate_delta_percent"] = (
        result["candidate"]["median_ms"] / result["baseline"]["median_ms"] - 1
    ) * 100
    result["candidate_faster_pairs"] = sum(ratio < 1 for ratio in ratios)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be a positive even number >= 2 for balanced AB/BA order")
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    driver = Path(__file__).resolve().with_name("Driver.swift")
    manifest = {
        "baseline_commit": BASELINE,
        "candidate_commit": run(["git", "-C", str(root), "rev-parse", "HEAD"]).strip(),
        "candidate_status": run(["git", "-C", str(root), "status", "--porcelain"]).strip(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor_count": os.cpu_count(),
        "swift": run(["swiftc", "--version"]).strip(),
        "compile_flags": ["-swift-version", "6", "-O", "-parse-as-library"],
        "driver_blob": blob(driver.read_bytes()),
        "runner_blob": blob(Path(__file__).read_bytes()),
        "rounds": args.rounds,
        "protocol_revision": "2-longer-fallback-controls",
        "protocol_change": (
            "After the original byte-guard cohorts, fix repeated Unicode fallback at "
            "64 parses and ignored plot at 1000 parses per observation to investigate "
            "control variation with longer batches. Do not pool these samples with "
            "the earlier 8/100-parse protocol."
        ),
        "iterations": CASE_ITERATIONS,
        "skipped_tests": args.skip_tests,
        "method": (
            "Real unmodified production sources compiled in separate executables with -O; "
            "same current tests for both versions, in debug and release unless skipped. Three "
            "untimed warmups per fresh process plus one excluded "
            "warm-up pair per case, then fresh processes in balanced alternating AB/BA "
            "order; XML Data fixture creation and full receipt serialization are untimed. "
            "The driver consumes each result during the timer. All samples retained."
        ),
        "scope": (
            "Complete warmed in-memory NFO XML parsing, including input validation and output "
            "construction; excludes file I/O, whole app startup, playback, GPU, energy, and NAS latency."
        ),
        "research_acceptance": {
            "correctness": "All debug/release regressions and exact differential/receipt equality must pass.",
            "primary": "At least 25% lower median complete-parse time for fragmented fields within the UTF-8 bound.",
            "controls": "Investigate any consistent material (5% or greater) regression on ordinary and fallback controls.",
            "integration": "Run existing real sidecar reader regressions with both parser versions.",
        },
        "test_blobs": {
            relative: blob((root / "Tests/IlliquidCoreTests" / relative).read_bytes())
            for relative in TESTS
        },
        "source_blobs": {},
        "tests": {},
    }
    rows = []
    receipts = {}
    with tempfile.TemporaryDirectory(prefix="illiquid-nfo-text-limits-") as temporary:
        work = Path(temporary)
        baseline = work / "baseline-root"
        for relative in SOURCES:
            path = Path("Sources/IlliquidCore") / relative
            destination = baseline / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            # Use exact bytes from the pinned Git object; no source substitutions.
            destination.write_bytes(subprocess.check_output(
                ["git", "-C", str(root), "show", f"{BASELINE}:{path.as_posix()}"]
            ))
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        roots = {"baseline": baseline, "candidate": root}
        probes = {}
        for variant, source_root in roots.items():
            sources = [source_root / "Sources/IlliquidCore" / relative for relative in SOURCES]
            manifest["source_blobs"][variant] = {
                relative: blob(path.read_bytes()) for relative, path in zip(SOURCES, sources)
            }
            if not args.skip_tests:
                manifest["tests"][variant] = swift_tests(root, source_root, output, work, variant)
            probe = work / variant
            command = ["swiftc", "-swift-version", "6", "-O", "-parse-as-library", *map(str, sources),
                       str(driver), "-o", str(probe)]
            run(command, output / f"{variant}-compile.txt")
            probes[variant] = probe
        changed_sources = [relative for relative in SOURCES
                           if manifest["source_blobs"]["baseline"][relative]
                           != manifest["source_blobs"]["candidate"][relative]]
        manifest["changed_sources"] = changed_sources
        differentials = {}
        for variant, probe in probes.items():
            differentials[variant] = json.loads(run([str(probe), "differential"]))
        if differentials["baseline"] != differentials["candidate"]:
            (output / "differential-mismatch.json").write_text(
                json.dumps(differentials, indent=2, ensure_ascii=False) + "\n")
            raise RuntimeError("Baseline/candidate output mismatch in differential corpus")
        (output / "differential.json").write_text(
            json.dumps(differentials["candidate"], indent=2, ensure_ascii=False) + "\n")
        manifest["differential_sha256"] = digest(differentials["candidate"])
        print("Differential corpus: exact output equality", flush=True)
        with (output / "measurements.jsonl").open("w") as measurements:
            for case, iterations in CASE_ITERATIONS.items():
                for iteration in range(-1, args.rounds):
                    order = ("baseline", "candidate") if iteration % 2 == 0 else ("candidate", "baseline")
                    for position, variant in enumerate(order):
                        value = json.loads(run([str(probes[variant]), "benchmark", case, str(iterations)]))
                        elapsed = value.pop("elapsedNanoseconds")
                        if value["case"] != case or value["iterations"] != iterations:
                            raise RuntimeError(f"Unexpected benchmark identity: {case}/{variant}")
                        if case in receipts and value != receipts[case]:
                            raise RuntimeError(f"Output mismatch: {case}/{variant}/round {iteration}")
                        receipts[case] = value
                        row = {
                            "case": case, "round": iteration, "order": position,
                            "variant": variant, "iterations": iterations,
                            "elapsed_nanoseconds": elapsed,
                            "nanoseconds_per_operation": elapsed / iterations,
                            "receipt_sha256": digest(value),
                        }
                        rows.append(row)
                        measurements.write(json.dumps(row) + "\n")
                        measurements.flush()
                print(case, json.dumps(summary(rows, case)), flush=True)
        summaries = {case: summary(rows, case) for case in CASE_ITERATIONS}
        (output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
        (output / "receipts.json").write_text(json.dumps(receipts, indent=2, ensure_ascii=False) + "\n")
        manifest["all_receipts_equal"] = True
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Evidence:", output, flush=True)


if __name__ == "__main__":
    main()
