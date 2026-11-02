#!/usr/bin/env python3
"""Regress the reviewed current NFO parser against a frozen oracle, without timing.

Requires Swift 6.1+ and Python 3.10+. Uses a temporary Swift package for the
regressions; does not resolve the native app's dependencies. Explicit
historical-timing mode reproduces the pinned protocol-3 source cohort.
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
HISTORICAL_CANDIDATE = "91dab495865210bbaced94ef39a2eb613209c3c7"
PARSER = "MediaLibrary/NFOMetadataHints.swift"
PARSER_BLOBS = {
    "baseline": "55e84590829c678f6ac5cb1328e64dead63651b6",
    "candidate": "051c475fd33bcd16ec33f6b4b93ee98fffdb21d3",
}
# Separate reviewed comparison for current-source regressions. Never extend the
# historical pair to accept newer parsers or infer approval from working-tree bytes.
CURRENT_PARSER_BLOBS = {
    "baseline": PARSER_BLOBS["baseline"],
    "candidate": "1dbcc6eb188c95f428e2600d3f585c6e30981676",
}
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
CURRENT_TESTS = [*TESTS, "NFODeclarationPreflightTests.swift"]
CASE_ITERATIONS = {
    "movie-small": 100_000,
    "episode-small": 50_000,
    "unicode-small": 50_000,
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


def git_bytes(root: Path, revision: str, path: Path) -> bytes:
    return subprocess.check_output(
        ["git", "-C", str(root), "show", f"{revision}:{path.as_posix()}"]
    )


def stage_sources(root: Path, work: Path, historical: bool) -> dict[str, Path]:
    roots = {variant: work / f"{variant}-root" for variant in PARSER_BLOBS}

    def write(variant: str, path: Path, data: bytes) -> None:
        destination = roots[variant] / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)

    for relative in SOURCES:
        path = Path("Sources/IlliquidCore") / relative
        candidate = (git_bytes(root, HISTORICAL_CANDIDATE, path) if historical
                     else (root / path).read_bytes())
        baseline = (git_bytes(root, BASELINE, path) if historical or relative == PARSER
                    else candidate)
        write("candidate", path, candidate)
        write("baseline", path, baseline)
    # Snapshot the shared tests and driver once, so both builds use the recorded bytes.
    tests = TESTS if historical else CURRENT_TESTS
    for path in [*(Path("Tests/IlliquidCoreTests") / name for name in tests),
                 Path("Benchmarks/NFOTextLimits/Driver.swift")]:
        data = (git_bytes(root, HISTORICAL_CANDIDATE, path) if historical
                else (root / path).read_bytes())
        write("candidate", path, data)
    return roots


def verify_isolation(roots: dict[str, Path], *, historical: bool = False) -> dict:
    source_bytes = {
        variant: {relative: (source_root / "Sources/IlliquidCore" / relative).read_bytes()
                  for relative in SOURCES}
        for variant, source_root in roots.items()
    }
    changed = [relative for relative in SOURCES
               if source_bytes["baseline"][relative] != source_bytes["candidate"][relative]]
    if changed != [PARSER]:
        raise RuntimeError(f"Source isolation failed: expected only {PARSER}, got {changed}")
    expected_blobs = PARSER_BLOBS if historical else CURRENT_PARSER_BLOBS
    for variant, expected in expected_blobs.items():
        actual = blob(source_bytes[variant][PARSER])
        if actual != expected:
            raise RuntimeError(f"Unexpected {variant} parser blob: {actual}; expected {expected}")
    return {
        "expected_parser_blobs": expected_blobs.copy(),
        "changed_sources": changed,
        "source_blobs": {
            variant: {relative: blob(data) for relative, data in sources.items()}
            for variant, sources in source_bytes.items()
        },
        "source_sha256": {
            variant: {relative: hashlib.sha256(data).hexdigest()
                      for relative, data in sources.items()}
            for variant, sources in source_bytes.items()
        },
    }


def compare_differentials(differentials: dict, output: Path) -> dict:
    metadata_fields = {"content", "title", "year", "season", "episode", "lastEpisode",
                       "episodeTitle", "catalogIDs", "sources"}
    for variant, report in differentials.items():
        if (set(report) != {"schemaVersion", "mode", "caseCount", "cases"}
                or report["schemaVersion"] != 1 or report["mode"] != "differential"
                or report["caseCount"] != 136 or len(report["cases"]) != 136):
            raise RuntimeError(f"Expected all 136 differential outputs: {variant}")
        names = set()
        for case in report["cases"]:
            if (set(case) != {"case", "inputBytes", "result"}
                    or case["case"] in names
                    or (case["result"] is not None and set(case["result"]) != metadata_fields)):
                raise RuntimeError(f"Incomplete or duplicate differential receipt: {variant}")
            names.add(case["case"])
    if differentials["baseline"] != differentials["candidate"]:
        (output / "differential-mismatch.json").write_text(
            json.dumps(differentials, indent=2, ensure_ascii=False) + "\n")
        raise RuntimeError("Baseline/candidate output mismatch in differential corpus")
    return differentials["candidate"]


def swift_tests(root: Path, sources: Path, output: Path, work: Path, variant: str, jobs: int,
                *, historical: bool = False) -> dict:
    package = work / f"tests-{variant}"
    source_dir = package / "Sources/IlliquidCore"
    test_dir = package / "Tests/IlliquidCoreTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    for relative in SOURCES:
        shutil.copy2(sources / "Sources/IlliquidCore" / relative, source_dir)
    # Both implementations receive the same snapshotted regression tests.
    for relative in TESTS if historical else CURRENT_TESTS:
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
                   "--configuration", configuration, "--no-parallel", "--jobs", str(jobs)]
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
    parser.add_argument("--mode", choices=("qualify", "historical-timing"), default="qualify")
    parser.add_argument("--rounds", type=int, help="Historical timing only (default: 12)")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--jobs", type=int, choices=(1, 2), default=2)
    args = parser.parse_args()
    historical = args.mode == "historical-timing"
    if not historical and (args.skip_tests or args.rounds is not None):
        parser.error("Qualification requires all tests and does not accept timing options")
    if historical and args.rounds is None:
        args.rounds = 12
    if historical and (args.rounds < 2 or args.rounds % 2):
        parser.error("--rounds must be a positive even number >= 2 for balanced AB/BA order")
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be a fresh or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "mode": args.mode,
        "completed": False,
        "baseline_commit": BASELINE if historical else None,
        "baseline_parser_commit": BASELINE,
        "baseline_kind": "historical-tree" if historical else "pinned-parser-with-current-shared-dependencies",
        "candidate_commit": (HISTORICAL_CANDIDATE if historical else
                             run(["git", "-C", str(root), "rev-parse", "HEAD"]).strip()),
        "candidate_status": ("pinned Git objects" if historical else
                             run(["git", "-C", str(root), "status", "--porcelain"]).strip()),
        "shared_inputs": (f"Git objects from {HISTORICAL_CANDIDATE}" if historical else
                          "Current working-tree bytes, snapshotted once for both variants; see hashes"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor_count": os.cpu_count(),
        "swift": run(["swiftc", "--version"]).strip(),
        "compile_flags": ["-swift-version", "6", "-O", "-parse-as-library", "-j", str(args.jobs)],
        "runner_blob": blob(Path(__file__).read_bytes()),
        "rounds": args.rounds,
        "protocol_revision": "3-longer-ordinary-controls" if historical else "current-regression-2-declaration-preflight",
        "protocol_change": (
            "After protocol 2 showed a 12.12% small-movie median regression in short "
            "batches, retain the same production source and fix movie/episode/Unicode "
            "ordinary controls at 100000/50000/50000 parses per observation. Keep "
            "protocol 2's other counts, including fallback 64 and ignored plot 1000. "
            "This investigates the ordinary control without pooling earlier cohorts."
        ) if historical else (
            "Current shared dependencies and six test suites; exact reviewed declaration-preflight "
            "candidate against the independent pre-text-limit parser oracle. No timing."
        ),
        "iterations": CASE_ITERATIONS if historical else {},
        "skipped_tests": args.skip_tests,
        "method": (
            "Real unmodified production sources compiled in separate executables with -O; "
            "same pinned historical tests for both versions, in debug and release unless skipped. Three "
            "untimed warmups per fresh process plus one excluded "
            "warm-up pair per case, then fresh processes in balanced alternating AB/BA "
            "order; XML Data fixture creation and full receipt serialization are untimed. "
            "The driver consumes each result during the timer. All samples retained."
        ) if historical else (
            "Both pinned parser versions with identical current shared dependencies and tests; "
            "debug/release tests and exact comparison of all 136 complete release differential outputs. "
            "No benchmark invocation or timing observations."
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
        } if historical else {
            "correctness": "All current debug/release regressions and all 136 exact differential outputs must pass.",
            "isolation": "Only the pinned NFO parser change; all shared dependencies must be byte-identical.",
            "timing": "None. Historical timings do not qualify the current integrated pipeline.",
        },
        "source_blobs": {},
        "tests": {},
    }
    rows = []
    receipts = {}
    with tempfile.TemporaryDirectory(prefix="nfo-work-", dir=output) as temporary:
        work = Path(temporary)
        roots = stage_sources(root, work, historical)
        manifest.update(verify_isolation(roots, historical=historical))  # Fail closed before any compilation.
        inputs = roots["candidate"]
        driver = inputs / "Benchmarks/NFOTextLimits/Driver.swift"
        manifest["driver_blob"] = blob(driver.read_bytes())
        manifest["test_blobs"] = {
            relative: blob((inputs / "Tests/IlliquidCoreTests" / relative).read_bytes())
            for relative in (TESTS if historical else CURRENT_TESTS)
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        probes = {}
        for variant, source_root in roots.items():
            sources = [source_root / "Sources/IlliquidCore" / relative for relative in SOURCES]
            if not args.skip_tests:
                manifest["tests"][variant] = swift_tests(
                    inputs, source_root, output, work, variant, args.jobs, historical=historical)
                (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            probe = work / variant
            command = ["swiftc", *manifest["compile_flags"], *map(str, sources),
                       str(driver), "-o", str(probe)]
            run(command, output / f"{variant}-compile.txt")
            probes[variant] = probe
        if not args.skip_tests:
            counts = {result["test_count"] for variant in manifest["tests"].values()
                      for result in variant.values()}
            if len(counts) != 1:
                raise RuntimeError(f"Debug/release test counts differ between builds: {counts}")
        differentials = {}
        for variant, probe in probes.items():
            differentials[variant] = json.loads(run([str(probe), "differential"]))
        shared_output = compare_differentials(differentials, output)
        (output / "differential.json").write_text(
            json.dumps(shared_output, indent=2, ensure_ascii=False) + "\n")
        manifest["differential_sha256"] = digest(shared_output)
        manifest["differential_case_count"] = shared_output["caseCount"]
        manifest["all_differential_outputs_equal"] = True
        print("Differential corpus: all 136 complete outputs exactly equal", flush=True)
        if not historical:
            manifest["completed"] = True
            (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print("Current-source parser regressions passed (no timing). Evidence:", output, flush=True)
            return
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
        manifest["completed"] = True
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Evidence:", output, flush=True)


if __name__ == "__main__":
    main()
