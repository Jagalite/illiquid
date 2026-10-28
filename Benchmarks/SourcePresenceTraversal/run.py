#!/usr/bin/env python3
"""Qualify exact source-presence traversal implementations with paired filesystem scans.

The baseline is pinned to the main revision before this experiment. Both variants
compile complete production scanner sources in isolated Swift packages, run the
same debug/release tests, and scan the same generated filesystem fixtures. These
are warm local-filesystem component measurements, not player/UI/energy timings.
"""
from __future__ import annotations

import argparse
import datetime
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
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCANNER = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
IDENTITY = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
CORE = [
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/SourcePreparationExecutor.swift",
]
APP = [
    SCANNER,
    "Sources/IlliquidApp/UI/SourceMediaPresenceRecomputation.swift",
    "Sources/IlliquidApp/App/SourceRootPruning.swift",
]
TESTS = [
    "SourceMediaPresenceReuseTests.swift",
    "SourceMediaPresenceRecomputationTests.swift",
    "SourcePresenceTraversalRegressionTests.swift",
]
CASES = [
    "flat_media_4096", "flat_nonmedia_4096", "nested_mixed_4096",
    "directory_only_512", "cached_repair", "small_32",
]
PRIMARY = CASES[:3]
CONTROLS = CASES[3:]
PRODUCT = "SourcePresenceTraversalBenchmark"
MAX_ITERATIONS = 1_000_000
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourcePresenceTraversalQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SourcePresenceTraversalBenchmark",
                           targets: ["SourcePresenceTraversalBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "SourcePresenceTraversalBenchmark",
                           dependencies: ["IlliquidApp", "IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"]),
    ],
    swiftLanguageModes: [.v6]
)
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def identity_excerpt(data: bytes) -> bytes:
    """Copy the complete declaration; no scanner or identity behavior is rewritten."""
    start = b"enum SourceTreeIdentity {"
    end = b"\nstruct SourcesSidebarExpansionSnapshot:"
    if data.count(start) != 1 or data.count(end) != 1:
        raise RuntimeError("SourceTreeIdentity extraction boundaries changed")
    first, last = data.index(start), data.index(end)
    if first >= last:
        raise RuntimeError("SourceTreeIdentity extraction boundaries are reversed")
    return b"import Foundation\nimport IlliquidCore\n\n" + data[first:last]


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output
        self.env = os.environ.copy()
        self.env.update(
            CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
            SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb", NO_COLOR="1",
        )
        self.sequence = 0
        (self.output / "logs").mkdir()

    def run(self, arguments: list, label: str, timeout: int = 600, *, combined: bool = False) -> str:
        argv = [str(value) for value in arguments]
        self.sequence += 1
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                    text=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or b""
            stderr = error.stderr or b""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            log.write_text(stdout + stderr)
            append(self.output / "commands.jsonl", {
                "argv": argv, "label": label, "timedOut": True,
                "elapsedSeconds": time.monotonic() - started,
                "log": str(log.relative_to(self.output)),
            })
            raise RuntimeError(f"Command timed out: {label}; see {log}") from error
        log.write_text(result.stdout + result.stderr)
        append(self.output / "commands.jsonl", {
            "argv": argv, "label": label, "returncode": result.returncode,
            "elapsedSeconds": time.monotonic() - started,
            "stdoutSHA256": digest(result.stdout.encode()),
            "stderrSHA256": digest(result.stderr.encode()),
            "log": str(log.relative_to(self.output)),
        })
        if result.returncode:
            raise RuntimeError(f"Command failed ({label}); see {log}\n"
                               + result.stdout[-4000:] + result.stderr[-4000:])
        return result.stdout + result.stderr if combined else result.stdout

    def baseline(self, relative: str) -> bytes:
        data = self.run(["git", "show", f"{BASELINE}:{relative}"],
                        "baseline-" + Path(relative).name).encode()
        # subprocess text decoding must not change even the source line endings.
        # Compare with Git's blob identity before calling these exact sources.
        expected = self.run(["git", "rev-parse", f"{BASELINE}:{relative}"],
                            "baseline-blob-" + Path(relative).name).strip()
        actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Baseline source bytes do not match the pinned Git blob: {relative}")
        return data

    def swift(self, variant: str, operation: str, configuration: str) -> list:
        arguments = [self.args.swift, operation, "--package-path", self.output / "packages" / variant,
                     "-c", configuration, "--jobs", "2",
                     "--cache-path", self.output / "package-cache",
                     "--config-path", self.output / "package-config",
                     "--security-path", self.output / "package-security",
                     "-Xswiftc", "-warnings-as-errors"]
        if operation == "test":
            arguments.append("--no-parallel")
        if platform.system() == "Linux":
            arguments.append("--use-integrated-swift-driver")
        return arguments

    def measure(self, binary: Path, case: str, iterations: int, label: str) -> dict:
        row = json.loads(self.run([binary, "measure", self.output / "fixtures", case, iterations],
                                  label, timeout=180))
        if (row.get("workload"), row.get("iterations")) != (case, iterations):
            raise RuntimeError(f"Mismatched workload receipt: {label}")
        for key in ("elapsedNanoseconds", "cpuNanoseconds", "visitedEntries"):
            value = row.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise RuntimeError(f"Invalid {key}: {label}")
        if isinstance(row.get("checksum"), bool) or not isinstance(row.get("checksum"), int):
            raise RuntimeError(f"Missing integer observable checksum: {label}")
        row["wallNanosecondsPerScan"] = row["elapsedNanoseconds"] / iterations
        row["cpuNanosecondsPerScan"] = row["cpuNanoseconds"] / iterations
        return row


def paired_parity(samples: dict, label: str) -> None:
    for key in ("workload", "iterations", "checksum", "visitedEntries"):
        if samples["baseline"][key] != samples["candidate"][key]:
            raise RuntimeError(f"Paired {key} mismatch: {label}")


def stage(runner: Runner) -> dict:
    before = {relative: runner.baseline(relative) for relative in CORE + APP + [IDENTITY]}
    after = {relative: (ROOT / relative).read_bytes() for relative in CORE + APP + [IDENTITY]}
    for relative in CORE + APP:
        if relative != SCANNER and before[relative] != after[relative]:
            raise RuntimeError(f"Non-scanner dependency differs from pinned baseline: {relative}")
    if identity_excerpt(before[IDENTITY]) != identity_excerpt(after[IDENTITY]):
        raise RuntimeError("SourceTreeIdentity differs from pinned baseline")
    records = {}
    for variant, inputs in (("baseline", before), ("candidate", after)):
        files = {f"Sources/IlliquidCore/{Path(relative).name}": inputs[relative] for relative in CORE}
        files.update({f"Sources/IlliquidApp/{Path(relative).name}": inputs[relative] for relative in APP})
        files["Sources/IlliquidApp/SourceTreeIdentity.swift"] = identity_excerpt(inputs[IDENTITY])
        files[f"Sources/{PRODUCT}/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
        files["Package.swift"] = PACKAGE.encode()
        for name in TESTS:
            files["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
        package = runner.output / "packages" / variant
        for relative, data in files.items():
            path = package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        records[variant] = {
            "productionFiles": {relative: digest(data) for relative, data in inputs.items()},
            "stagedFiles": {relative: digest(data) for relative, data in files.items()},
            "transformations": {
                "Sources/IlliquidApp/SourceTreeIdentity.swift":
                    "Complete SourceTreeIdentity declaration extracted unchanged; Foundation and IlliquidCore imports added.",
                "Package.swift": "Isolated package with separate production and benchmark modules; Swift 6 mode.",
                "otherProductionSources": "None: complete original files compiled without changes.",
            },
        }
    save(runner.output / "sources.json", records)
    return records


def summarize(records: list[dict], cases: list[str], pairs: int) -> dict:
    results = []
    for case in cases:
        rows = [row for row in records if row["workload"] == case]
        entry = {"workload": case, "role": "primary" if case in PRIMARY else "control"}
        for metric, field in (("wall", "wallNanosecondsPerScan"), ("cpu", "cpuNanosecondsPerScan")):
            variants = {variant: [row[field] for row in rows if row["variant"] == variant]
                        for variant in ("baseline", "candidate")}
            reductions = []
            for pair in range(pairs):
                samples = {row["variant"]: row for row in rows if row["pair"] == pair}
                if set(samples) != {"baseline", "candidate"}:
                    raise RuntimeError(f"Missing paired measurements: {case}/{pair}")
                paired_parity(samples, f"{case}/{pair}")
                reductions.append(100 * (1 - samples["candidate"][field] / samples["baseline"][field]))
            entry[metric] = {
                "baselineMedianNanosecondsPerScan": statistics.median(variants["baseline"]),
                "candidateMedianNanosecondsPerScan": statistics.median(variants["candidate"]),
                "baselineRangeNanosecondsPerScan": [min(variants["baseline"]), max(variants["baseline"])],
                "candidateRangeNanosecondsPerScan": [min(variants["candidate"]), max(variants["candidate"])],
                "pairedMedianReductionPercent": statistics.median(reductions),
                "pairedReductionsPercent": reductions,
                "improvedPairs": sum(value > 0 for value in reductions),
                "pairs": pairs,
            }
        results.append(entry)
    primary_met = all(
        row[metric]["pairedMedianReductionPercent"] >= 15
        and row[metric]["improvedPairs"] >= math.ceil(pairs * 7 / 8)
        for row in results if row["role"] == "primary" for metric in ("wall", "cpu")
    )
    controls_met = all(row[metric]["pairedMedianReductionPercent"] >= -5
                       for row in results if row["role"] == "control" for metric in ("wall", "cpu"))
    return {"results": results, "predeclaredThresholds": {
        "primaryMedianReductionPercent": 15, "primaryFavorablePairFraction": 7 / 8,
        "maximumControlMedianRegressionPercent": 5,
        "primaryCases": PRIMARY, "controlCases": CONTROLS,
        "primaryThresholdMet": primary_met, "controlThresholdMet": controls_met,
        "allCasesIncluded": cases == CASES,
        "nativePlatform": platform.system() == "Darwin",
        "successCriteriaMet": cases == CASES and pairs >= 8 and primary_met and controls_met,
    }}


def experiment(args: argparse.Namespace, runner: Runner) -> None:
    baseline = runner.run(["git", "rev-parse", f"{BASELINE}^{{commit}}"], "baseline-revision").strip()
    if baseline != BASELINE:
        raise RuntimeError("Unexpected baseline commit")
    relevant_paths = CORE + APP + [IDENTITY, str(HERE.relative_to(ROOT)),
                                  ".github/workflows/source-presence-traversal.yml"]
    relevant_paths += ["Tests/IlliquidAppTests/" + name for name in TESTS]
    manifest = {
        "schemaVersion": 1,
        "collectedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "baselineCommit": BASELINE,
        "candidateCommit": runner.run(["git", "rev-parse", "HEAD"], "candidate-revision").strip(),
        "relevantGitStatus": runner.run(["git", "status", "--short", "--", *relevant_paths],
                                         "git-status").strip(),
        "platform": platform.platform(), "machine": platform.machine(), "cpuCount": os.cpu_count(),
        "python": platform.python_version(),
        "swift": runner.run([args.swift, "--version"], "swift-version").strip(),
        "environment": {name: runner.env.get(name) for name in
                        ("DEVELOPER_DIR", "LANG", "LC_ALL", "LC_COLLATE", "SWIFT_DETERMINISTIC_HASHING")},
        "github": {name: os.environ.get(name) for name in
                   ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_EVENT_NAME")},
        "arguments": {**vars(args), "output": str(args.output)},
        "runnerSHA256": digest(Path(__file__).read_bytes()),
        "method": {
            "scope": "Complete SourceMediaPresenceCursor traversal of warm generated local filesystems; no file-content decoding, scanner pacing sleeps, UI rendering, or energy measurement.",
            "sources": "Complete production scanner plus unchanged dependencies; real Foundation/Observation, separate Swift modules, no cross-module optimization.",
            "tests": "Same complete reuse, recomputation, and traversal regression suites in baseline/candidate, debug/release; complete filesystem oracle receipts compared across all four executables.",
            "sampling": "Fresh processes, same iteration count for both variants, balanced AB/BA pairs, rotating workload order; every sample retained.",
            "timing": "Harness monotonic wall and process CPU clocks; fixture creation and receipt verification outside timing; no empty-loop subtraction.",
            "calibration": "Both variants warm up, then matched pilots select one count with a 1.5x duration margin targeting at least target-ms in the faster variant; verification pilots retained. Observed samples below target are retained, never retried or discarded.",
            "acceptance": "Each of three primary cases: >=15% paired median wall and CPU reduction and >=7/8 favorable pairs; each of three controls: <=5% paired median regression. Final native claim requires all six cases, >=8 pairs, and every observed sample >=250ms.",
        },
    }
    if platform.system() == "Darwin":
        manifest["host"] = runner.run(["sw_vers"], "macos-version").strip()
        manifest["hardware"] = runner.run(["sysctl", "hw.model", "machdep.cpu.brand_string"], "hardware").strip()
    sources = stage(runner)
    save(args.output / "manifest.json", manifest)
    tests = {}
    binaries = {}
    verification_binaries = {}
    for variant in ("baseline", "candidate"):
        tests[variant] = {}
        if not args.skip_tests:
            for configuration in ("debug", "release"):
                print(f"Testing {variant}/{configuration}", flush=True)
                output = runner.run(runner.swift(variant, "test", configuration),
                                    f"{variant}-{configuration}-tests", combined=True)
                counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", output)
                if not counts or int(counts[-1]) <= 0:
                    raise RuntimeError(f"No positive test completion receipt: {variant}/{configuration}")
                tests[variant][configuration] = {"passed": True, "testCount": int(counts[-1])}
                save(args.output / "tests.json", tests)
        for configuration in ("debug", "release"):
            runner.run(runner.swift(variant, "build", configuration) + ["--product", PRODUCT],
                       f"{variant}-{configuration}-build")
            directory = runner.run(runner.swift(variant, "build", configuration) + ["--show-bin-path"],
                                   f"{variant}-{configuration}-binary-directory").strip()
            binary = Path(directory) / PRODUCT
            if not binary.is_file():
                raise RuntimeError(f"Missing {variant}/{configuration} executable")
            verification_binaries[f"{variant}-{configuration}"] = binary
            if configuration == "release":
                binaries[variant] = binary
    if not args.skip_tests and (tests["baseline"] != tests["candidate"]
                               or tests["baseline"]["debug"] != tests["baseline"]["release"]):
        raise RuntimeError("Baseline/candidate or debug/release test completion counts differ")
    binary_hashes = {label: digest(path.read_bytes()) for label, path in verification_binaries.items()}
    save(args.output / "builds.json", {label: {
        "binary": str(path.relative_to(args.output)), "sha256": binary_hashes[label],
    } for label, path in verification_binaries.items()})
    runner.run([binaries["candidate"], "prepare", args.output / "fixtures"], "prepare-fixtures")
    verification = {label: json.loads(runner.run([binary, "verify", args.output / "fixtures"],
                                                f"{label}-verify-before"))
                    for label, binary in verification_binaries.items()}
    save(args.output / "verification.json", verification)
    if any(value != verification["baseline-release"] for value in verification.values()):
        raise RuntimeError("Exact baseline/candidate or debug/release traversal receipts differ")
    if args.tests_only:
        save(args.output / "completion.json", {"status": "tests-and-parity-passed", "measurements": False,
                                               "verifiedExecutables": list(verification_binaries),
                                               "testsSkipped": False})
        return
    counts = {}
    for case in args.cases:
        warmup = {variant: runner.measure(binary, case, 1, f"warmup-{case}-{variant}")
                  for variant, binary in binaries.items()}
        paired_parity(warmup, f"warmup-{case}")
        append(args.output / "warmup.jsonl", {"workload": case, "samples": warmup})
        fastest = min(row["wallNanosecondsPerScan"] for row in warmup.values())
        count = max(1, min(MAX_ITERATIONS, math.ceil(args.target_ms * 1_000_000 * 1.5 / fastest)))
        for attempt in range(4):
            pilots = {variant: runner.measure(binary, case, count,
                                              f"calibrate-{case}-{attempt}-{variant}")
                      for variant, binary in binaries.items()}
            paired_parity(pilots, f"calibration-{case}-{attempt}")
            append(args.output / "calibration.jsonl", {
                "workload": case, "attempt": attempt, "iterations": count, "samples": pilots,
            })
            duration = min(row["elapsedNanoseconds"] for row in pilots.values())
            if duration >= args.target_ms * 1_000_000:
                break
            count = min(MAX_ITERATIONS, max(count + 1,
                        math.ceil(count * args.target_ms * 1_000_000 * 1.5 / duration)))
        else:
            raise RuntimeError(f"Could not calibrate {case} to the requested duration")
        counts[case] = count
    save(args.output / "iteration-counts.json", counts)
    records = []
    for pair in range(args.pairs):
        offset = pair % len(args.cases)
        order = args.cases[offset:] + args.cases[:offset]
        for position, case in enumerate(order):
            variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            samples = {}
            for variant in variants:
                row = runner.measure(binaries[variant], case, counts[case], f"pair-{pair}-{case}-{variant}")
                row.update(pair=pair, position=position, variant=variant, order=list(variants))
                samples[variant] = row
                records.append(row)
                append(args.output / "measurements.jsonl", row)
            paired_parity(samples, f"{case}/{pair}")
        print(f"Completed paired block {pair + 1}/{args.pairs}", flush=True)
    for label, binary in verification_binaries.items():
        after = json.loads(runner.run([binary, "verify", args.output / "fixtures"],
                                      f"{label}-verify-after"))
        save(args.output / f"verification-after-{label}.json", after)
        if after != verification[label] or digest(binary.read_bytes()) != binary_hashes[label]:
            raise RuntimeError(f"{label} executable or fixture/output receipts changed during measurement")
    for variant in ("baseline", "candidate"):
        for relative, expected in sources[variant]["stagedFiles"].items():
            if digest((args.output / "packages" / variant / relative).read_bytes()) != expected:
                raise RuntimeError(f"Staged source changed during measurement: {variant}/{relative}")
    summary = summarize(records, args.cases, args.pairs)
    def short_samples(threshold: float) -> list[dict]:
        return [{key: row[key] for key in ("workload", "pair", "variant", "elapsedNanoseconds", "iterations")}
                for row in records if row["elapsedNanoseconds"] < threshold]

    durations = {
        "requestedTargetNanoseconds": args.target_ms * 1_000_000,
        "nativeMinimumNanoseconds": 250_000_000,
        "minimumObservedNanoseconds": min(row["elapsedNanoseconds"] for row in records),
        "samplesUnderRequestedTarget": short_samples(args.target_ms * 1_000_000),
        "samplesUnderNativeMinimum": short_samples(250_000_000),
        "allSamplesRetained": True,
    }
    summary["sampleDurations"] = durations
    summary["predeclaredThresholds"]["testsSkipped"] = args.skip_tests
    summary["predeclaredThresholds"]["nativeQualificationSuccess"] = (
        platform.system() == "Darwin" and not args.skip_tests
        and summary["predeclaredThresholds"]["successCriteriaMet"] and args.target_ms >= 250
        and not durations["samplesUnderNativeMinimum"]
    )
    save(args.output / "summary.json", summary)
    save(args.output / "completion.json", {
        "status": "completed", "pairs": args.pairs, "samples": len(records),
        "cases": args.cases, "exactReceiptParity": True, "sourceAndBinaryIntegrity": True,
        "verifiedExecutables": list(verification_binaries), "sampleDurations": durations,
        "testsSkipped": args.skip_tests,
        "nativeQualificationSuccess": summary["predeclaredThresholds"]["nativeQualificationSuccess"],
    })
    print(json.dumps(summary, sort_keys=True), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=os.environ.get("SWIFT", "swift"))
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; cannot qualify a final candidate")
    args = parser.parse_args()
    args.cases = args.cases.split(",")
    if (args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0
            or not args.cases or len(args.cases) != len(set(args.cases))
            or any(case not in CASES for case in args.cases)):
        parser.error("Use an even pair count >=2, a finite positive duration, and unique supported cases")
    if args.tests_only and args.skip_tests:
        parser.error("--tests-only and --skip-tests are incompatible")
    swift = shutil.which(args.swift)
    if not swift:
        parser.error("Swift is unavailable; set --swift, SWIFT, or PATH")
    args.swift = swift
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use a new or empty --output directory; previous attempts must be preserved")
    args.output.mkdir(parents=True, exist_ok=True)
    runner = Runner(args)
    try:
        experiment(args, runner)
    except Exception as error:
        save(args.output / "completion.json", {"status": "failed", "error": str(error)})
        raise


if __name__ == "__main__":
    main()
