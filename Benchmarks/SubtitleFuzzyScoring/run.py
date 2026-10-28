#!/usr/bin/env python3
"""Compare complete production subtitle association with and without fuzzy-prefix copies."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
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
    "Tests/IlliquidCoreTests/ExternalSubtitleCandidateTraversalTests.swift",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleFuzzyScoringQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .executableTarget(name: "SubtitleFuzzyScoring", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sha(path):
    return digest(Path(path).read_bytes())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def describe(values):
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", default=6, type=int)
    parser.add_argument("--target-ms", default=250, type=int)
    parser.add_argument("--cases", help="Comma-separated subset for exploratory timing; verification still covers every case")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--reuse-builds-from", type=Path,
                        help="Reuse source- and binary-hash-verified builds; requires --skip-tests")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("pairs must be even and >= 2; target-ms must be positive")
    if not args.swift:
        parser.error("Swift 6.1 or newer is required; supply --swift or put it on PATH")
    if args.skip_tests and args.tests_only:
        parser.error("--skip-tests and --tests-only conflict")
    if args.reuse_builds_from and not args.skip_tests:
        parser.error("--reuse-builds-from requires --skip-tests")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    commands = []

    def command(argv, log=None, binary=False, timeout=600):
        argv = [str(value) for value in argv]
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                                text=not binary, timeout=timeout)
        commands.append({"argv": argv, "returncode": result.returncode})
        write_json(output / "commands.json", commands)
        stdout = result.stdout.decode(errors="replace") if binary else result.stdout
        stderr = result.stderr.decode(errors="replace") if binary else result.stderr
        if log:
            (output / log).write_text(stdout + stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{stdout[-3000:]}\n{stderr[-9000:]}")
        return result.stdout

    baseline = command(["git", "rev-parse", "--verify", args.baseline + "^{commit}"]).strip()
    manifest = {
        "startedUTC": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "compiler": command([args.swift, "--version"]).strip(),
        "baselineCommit": baseline,
        "candidateCommit": command(["git", "rev-parse", "HEAD"]).strip(),
        "worktreeStatus": command(["git", "status", "--porcelain=v1"]),
        "runnerSHA256": sha(__file__),
        "driverSHA256": sha(HERE / "Driver.swift"),
        "pairs": args.pairs,
        "targetCPUms": args.target_ms,
        "minimumIterations": 5,
        "hashing": "SWIFT_DETERMINISTIC_HASHING=1",
        "protocol": "fresh processes; balanced AB/BA; complete association and count consumption; fixtures and oracle outside timing",
        "sources": {}, "packageHashes": {}, "binaries": {}, "tests": {},
    }
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    shutil.copyfile(HERE / "Driver.swift", output / "driver.snapshot.swift")
    reused = args.reuse_builds_from.resolve() if args.reuse_builds_from else None
    prior = json.loads((reused / "manifest.json").read_text()) if reused else None
    if reused:
        if prior["compiler"] != manifest["compiler"]:
            raise ValueError("Compiler differs from reused build")
        manifest["reusedBuildsFrom"] = str(reused)
    binaries = {}
    for variant in ("baseline", "candidate"):
        package = output / variant
        for directory in ("Sources/IlliquidCore", "Sources/SubtitleFuzzyScoring", "Tests/IlliquidCoreTests"):
            (package / directory).mkdir(parents=True, exist_ok=True)
        for path in SOURCES:
            data = (command(["git", "show", baseline + ":" + path], binary=True)
                    if variant == "baseline" else (ROOT / path).read_bytes())
            destination = package / "Sources/IlliquidCore" / Path(path).name
            destination.write_bytes(data)
            manifest["sources"][variant + ":" + path] = {
                "sha256": digest(data),
                "gitBlob": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
            }
        for path in TESTS:
            shutil.copyfile(ROOT / path, package / "Tests/IlliquidCoreTests" / Path(path).name)
        shutil.copyfile(HERE / "Driver.swift", package / "Sources/SubtitleFuzzyScoring/Driver.swift")
        (package / "Package.swift").write_text(PACKAGE)
        hashes = {str(path.relative_to(package)): sha(path)
                  for path in sorted(package.rglob("*")) if path.is_file()}
        manifest["packageHashes"][variant] = hashes
        write_json(output / "manifest.json", manifest)
        flags = ["--package-path", package, "--jobs", "2", "-Xswiftc", "-warnings-as-errors",
                 "--cache-path", output / "cache", "--config-path", output / "config",
                 "--security-path", output / "security"]
        if not args.skip_tests:
            for configuration in ("debug", "release"):
                label = variant + "-" + configuration
                print("Testing " + label, flush=True)
                log = label + "-tests.log"
                command([args.swift, "test", *flags, "-c", configuration], log=log)
                summaries = re.findall(r"Test run with \d+ tests?.*", (output / log).read_text())
                manifest["tests"][label] = {"status": "passed", "log": log, "summaries": summaries}
                print(label + ": " + (" | ".join(summaries) or "swift test exited successfully"), flush=True)
                write_json(output / "manifest.json", manifest)
        else:
            manifest["tests"][variant] = {"status": "skipped"}
        if args.tests_only:
            continue
        if reused:
            if prior["packageHashes"][variant] != hashes:
                raise ValueError("Reused package sources differ: " + variant)
            binary = Path(prior["binaries"][variant]["path"])
            if sha(binary) != prior["binaries"][variant]["sha256"]:
                raise ValueError("Reused binary hash differs: " + variant)
            print("Reusing verified " + variant + " binary", flush=True)
        else:
            command([args.swift, "build", *flags, "-c", "release", "--product", "SubtitleFuzzyScoring"],
                    log=variant + "-build.log")
            binpath = Path(command([args.swift, "build", "--package-path", package,
                                   "-c", "release", "--show-bin-path"]).strip())
            binary = binpath / "SubtitleFuzzyScoring"
        binaries[variant] = binary
        manifest["binaries"][variant] = {"path": str(binary), "sha256": sha(binary)}
        write_json(output / "manifest.json", manifest)
    if args.tests_only:
        print("All baseline/candidate debug/release test commands passed.", flush=True)
        return

    verification = {}
    for variant, binary in binaries.items():
        verification[variant] = json.loads(command([binary, "--verify"], log=variant + "-verification.json"))
    if verification["baseline"] != verification["candidate"]:
        raise ValueError("Complete baseline/candidate output mappings differ")
    canonical = json.dumps(verification["baseline"], sort_keys=True, separators=(",", ":")).encode()
    parity = {"status": "passed", "fixtureCount": len(verification["baseline"]),
              "completeMappingsSHA256": digest(canonical)}
    write_json(output / "parity.json", parity)
    print("Full-output parity: " + json.dumps(parity, sort_keys=True), flush=True)
    available = json.loads(command([binaries["baseline"], "--list-cases"]))
    if json.loads(command([binaries["candidate"], "--list-cases"])) != available:
        raise ValueError("Benchmark cases differ")
    selected = args.cases.split(",") if args.cases else available
    if len(set(selected)) != len(selected) or any(case not in available for case in selected):
        parser.error("--cases contains an unknown or repeated case")
    manifest["measuredCases"] = selected
    write_json(output / "manifest.json", manifest)
    rows = []
    calibrations = {}

    def timed(variant, case, iterations):
        row = json.loads(command([binaries[variant], "--case", case,
                                  "--iterations", iterations, "--warmup", "4"], timeout=180))
        if row["checksum"] != row["expectedChecksum"]:
            raise ValueError("Timed checksum mismatch")
        if row["caseName"] != case or row["iterations"] != iterations:
            raise ValueError("Timed invocation metadata differs")
        return row

    for case in selected:
        pilots = {variant: timed(variant, case, 1) for variant in binaries}
        fastest = min(row["cpuNsPerAssociation"] for row in pilots.values())
        if fastest <= 0:
            raise ValueError("Calibration returned a nonpositive duration")
        iterations = max(5, min(100000, math.ceil(args.target_ms * 1e6 / fastest)))
        calibrations[case] = {"pilots": pilots, "iterations": iterations}
        write_json(output / "calibrations.json", calibrations)
        print(f"Measuring {case}: {iterations} associations/sample, {args.pairs} paired processes", flush=True)
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            paired = {}
            for position, variant in enumerate(order):
                row = timed(variant, case, iterations)
                row.update(variant=variant, pair=pair, orderIndex=position)
                rows.append(row)
                paired[variant] = row
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            for key in ("checksum", "expectedChecksum", "mediaCount", "subtitleCount", "localeIdentifier"):
                if paired["baseline"][key] != paired["candidate"][key]:
                    raise ValueError(f"Measured-pair metadata/output differs: {case}/{key}")

    # Verify the retained artifact before using it as the source of summaries.
    persisted = [json.loads(line) for line in (output / "observations.jsonl").read_text().splitlines()]
    expected_count = len(selected) * args.pairs * 2
    expected_grid = {(case, variant, pair) for case in selected
                     for variant in ("baseline", "candidate") for pair in range(args.pairs)}
    observed_grid = [(row["caseName"], row["variant"], row["pair"]) for row in persisted]
    if (persisted != rows or len(persisted) != expected_count
            or len(set(observed_grid)) != expected_count or set(observed_grid) != expected_grid):
        raise ValueError("Persisted observations are incomplete, duplicated, or differ from measured rows")
    rows = persisted
    integrity = {"status": "passed", "rowCount": len(rows), "expectedRowCount": expected_count,
                 "completeUniqueGrid": True, "sha256": sha(output / "observations.jsonl")}
    write_json(output / "observation-integrity.json", integrity)
    print("Retained observation integrity: " + json.dumps(integrity, sort_keys=True), flush=True)
    summary = {"pairs": args.pairs, "parity": parity, "observationIntegrity": integrity, "cases": []}
    for case in selected:
        entry = {"caseName": case}
        groups = {variant: [row for row in rows if row["caseName"] == case and row["variant"] == variant]
                  for variant in binaries}
        for metric in ("wallNsPerAssociation", "cpuNsPerAssociation"):
            baseline_rows = groups["baseline"]
            candidate_rows = groups["candidate"]
            changes = [100 * (candidate_rows[index][metric] / baseline_rows[index][metric] - 1)
                       for index in range(args.pairs)]
            entry[metric] = {
                "baseline": describe([row[metric] for row in baseline_rows]),
                "candidate": describe([row[metric] for row in candidate_rows]),
                "pairedChangePercent": describe(changes),
                "candidateFasterPairs": sum(change < 0 for change in changes),
            }
        summary["cases"].append(entry)
    write_json(output / "summary.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
    print("Evidence written to " + str(output), flush=True)


if __name__ == "__main__":
    main()
