#!/usr/bin/env python3
"""Qualify and measure actual MediaSidecarReader sources against a fixed baseline."""
from __future__ import annotations

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
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
READER = "MediaSidecarReader.swift"
SOURCES = ["MediaNameRecognition.swift", "MediaMetadataHints.swift",
           "NFOMetadataHints.swift", "PlexMatchHints.swift", READER]
TESTS = ["MediaSidecarTests.swift", "MediaSidecarPathPlanTests.swift",
         "NFOMetadataFieldSelectionTests.swift", "NFOEpisodeScopeRegressionTests.swift",
         "PlexMatchHintsRegressionTests.swift", "PlexMatchReaderRegressionTests.swift"]
MANIFEST = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SidecarPathPlanQualification", platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
              .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


class Runner:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Output must be new or empty; do not overwrite previous evidence")
        self.evidence = self.out / "evidence"
        self.evidence.mkdir(parents=True)
        self.build = self.out / "build"
        self.build.mkdir()
        self.env = dict(os.environ)
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.build / "module-cache")
        self.env["SWIFT_MODULECACHE_PATH"] = str(self.build / "module-cache")
        self.env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(self.build / "module-cache")
        self.binaries = {}
        self.expected = {}

    def command(self, argv, log=None, timeout=600):
        argv = [str(x) for x in argv]
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        combined = result.stdout + result.stderr
        if log:
            (self.evidence / log).write_text(combined)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"command": argv, "returncode": result.returncode,
                                     "stdout_sha256": sha(result.stdout.encode()),
                                     "stderr_sha256": sha(result.stderr.encode()), "log": log}) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n{combined}")
        return result.stdout

    def stage(self):
        # Snapshot shared dependencies, tests, and driver once. The reader is
        # the only production file allowed to differ between variants.
        current = {name: (ROOT / "Sources/IlliquidCore/MediaLibrary" / name).read_bytes()
                   for name in SOURCES}
        old_reader = subprocess.check_output(["git", "show",
            f"{self.args.baseline}:Sources/IlliquidCore/MediaLibrary/{READER}"], cwd=ROOT)
        if old_reader == current[READER]:
            raise RuntimeError("Baseline and candidate reader are identical")
        tests = {name: (ROOT / "Tests/IlliquidCoreTests" / name).read_bytes() for name in TESTS}
        harness = (HERE / "Harness.swift").read_bytes()
        receipts = {}
        for variant in ("baseline", "candidate"):
            package = self.build / variant
            production = package / "Sources/IlliquidCore"
            test_dir = package / "Tests/IlliquidCoreTests"
            production.mkdir(parents=True)
            test_dir.mkdir(parents=True)
            (package / "Package.swift").write_text(MANIFEST)
            receipt = {"production": {}, "tests": {}, "harness_sha256": sha(harness),
                       "manifest_sha256": sha(MANIFEST.encode())}
            for name, shared in current.items():
                original = old_reader if name == READER and variant == "baseline" else shared
                compiled = original
                adaptation = None
                if platform.system() == "Linux":
                    if name == READER:
                        if original.count(b"import Darwin\n") != 1:
                            raise RuntimeError("Unexpected POSIX import; review Linux adaptation")
                        compiled = original.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        adaptation = "Darwin import -> Glibc"
                    elif name == "NFOMetadataHints.swift":
                        compiled = original.replace(b"import Foundation\n",
                                                    b"import Foundation\nimport FoundationXML\n", 1)
                        adaptation = "add FoundationXML import"
                (production / name).write_bytes(compiled)
                receipt["production"][name] = {"original_sha256": sha(original),
                                               "compiled_sha256": sha(compiled), "adaptation": adaptation}
            for name, data in tests.items():
                # All test bytes are identical on both platforms. macOS-only
                # suites retain their platform guards and are reported as such.
                (test_dir / name).write_bytes(data)
                receipt["tests"][name] = sha(data)
            driver = package / "Harness.swift"
            driver.write_bytes(harness)
            receipts[variant] = receipt
            (self.evidence / f"{variant}-sources.json").write_text(json.dumps(receipt, indent=2) + "\n")
            flags = ["-swift-version", "6", "-warnings-as-errors", "-O", "-whole-module-optimization"]
            if platform.system() == "Darwin":
                flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
            binary = package / "sidecar-harness"
            self.command([self.args.swiftc, *flags, *[production / name for name in SOURCES],
                          driver, "-o", binary], f"{variant}-compile.log")
            self.binaries[variant] = binary
            print("Built", variant, flush=True)
        changed = [name for name in SOURCES if receipts["baseline"]["production"][name]
                   != receipts["candidate"]["production"][name]]
        if changed != [READER]:
            raise RuntimeError(f"Source isolation failed: {changed}")
        (self.evidence / "binaries.json").write_text(json.dumps(
            {variant: sha(path.read_bytes()) for variant, path in self.binaries.items()}, indent=2) + "\n")

    def tests(self):
        results = {}
        for variant in self.binaries:
            for configuration in ("debug", "release"):
                log = f"{variant}-{configuration}-tests.log"
                self.command([self.args.swift, "test", "--package-path", self.build / variant,
                              "--configuration", configuration, "--jobs", self.args.jobs,
                              "--no-parallel"], log)
                text = (self.evidence / log).read_text()
                count = re.findall(r"Test run with ([1-9][0-9]*) tests? .* passed", text)
                if not count:
                    raise RuntimeError(f"Missing nonempty successful Swift Testing summary in {log}")
                results[f"{variant}-{configuration}"] = int(count[-1])
                print(variant, configuration, count[-1], "tests passed", flush=True)
        (self.evidence / "tests.json").write_text(json.dumps(results, indent=2) + "\n")

    def verify(self):
        self.fixtures = self.build / "fixtures"
        self.command([self.binaries["baseline"], "prepare", self.fixtures], "fixture-setup.log")
        catalogs = []
        reports = []
        for variant, binary in self.binaries.items():
            catalogs.append(json.loads(self.command([binary, "list"])))
            report = json.loads(self.command([binary, "verify", self.fixtures]))
            (self.evidence / f"{variant}-outputs.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            reports.append(report)
        if catalogs[0] != catalogs[1] or reports[0] != reports[1]:
            raise RuntimeError("Complete baseline/candidate output or filesRead mismatch")
        self.cases = catalogs[0]
        self.expected = {row["scenario"]["name"]: row for row in reports[0]}
        receipt = {"scenarios": len(reports[0]),
                   "outputs": sum(len(row["outputs"]) for row in reports[0]),
                   "complete_outputs_sha256": sha(canonical(reports[0])),
                   "cases": self.cases}
        (self.evidence / "verification.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("Complete output and filesRead parity:", receipt["outputs"], "files", flush=True)

    def sample(self, variant, case, iterations):
        row = json.loads(self.command([self.binaries[variant], "bench", self.fixtures, case, iterations]))
        expected = self.expected[case]
        if (row["final"] != expected["outputs"] or row["filesReadPerScan"] != expected["filesRead"]
                or row["iterations"] != iterations or row["scenario"] != case):
            raise RuntimeError(f"Timed output mismatch: {variant} {case}")
        row["output_sha256"] = sha(canonical(row.pop("final")))
        return row

    def measure(self):
        all_rows, summaries, calibration = [], [], []
        for case in self.cases:
            if not case["measure"]:
                continue
            name = case["name"]
            # Calibrate both variants once; choose a shared iteration count
            # targeting >= target-ms for the faster variant. Retain pilots.
            pilots = []
            for variant in self.binaries:
                pilot = self.sample(variant, name, 1)
                pilot["variant"] = variant
                calibration.append(pilot)
                pilots.append(pilot["elapsedNS"])
            iterations = min(100_000, max(1, math.ceil(self.args.target_ms * 1_000_000 / min(pilots))))
            rows = []
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for position, variant in enumerate(order):
                    row = self.sample(variant, name, iterations)
                    row.update(variant=variant, pair=pair, process_order=position)
                    rows.append(row)
                    all_rows.append(row)
                    with (self.evidence / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            stats = {variant: {metric: statistics.median(
                row[field] / row["iterations"] for row in rows if row["variant"] == variant)
                for metric, field in (("wall_ns_per_scan", "elapsedNS"), ("cpu_ns_per_scan", "cpuNS"))}
                for variant in self.binaries}
            paired = {}
            for metric, field in (("wall", "elapsedNS"), ("cpu", "cpuNS")):
                changes = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[field] for row in rows if row["pair"] == pair}
                    changes.append((values["candidate"] / values["baseline"] - 1) * 100)
                paired[metric] = {"median_change_percent": statistics.median(changes),
                                  "changes_percent": changes, "faster_pairs": sum(x < 0 for x in changes)}
            summary = {"scenario": name, "files_per_scan": case["count"], "iterations": iterations,
                       "pairs": self.args.pairs, "medians": stats, "paired": paired,
                       "minimum_sample_ms": min(row["elapsedNS"] for row in rows) / 1_000_000}
            summaries.append(summary)
            print(name, "wall", f"{paired['wall']['median_change_percent']:+.1f}%",
                  "CPU", f"{paired['cpu']['median_change_percent']:+.1f}%", flush=True)
        expected_rows = sum(case["measure"] for case in self.cases) * self.args.pairs * 2
        if len(all_rows) != expected_rows:
            raise RuntimeError("Incomplete measurement campaign")
        (self.evidence / "calibration.json").write_text(json.dumps(calibration, indent=2) + "\n")
        (self.evidence / "summary.json").write_text(json.dumps(
            {"observations": len(all_rows), "scenarios": summaries}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or args.jobs <= 0:
        parser.error("Use an even number of pairs >= 2, positive target-ms and jobs")
    runner = Runner(args)
    environment = {"platform": platform.platform(), "architecture": platform.machine(),
                   "swift": runner.command([args.swift, "--version"]).strip(),
                   "swiftc": runner.command([args.swiftc, "--version"]).strip(),
                   "baseline": args.baseline, "head": runner.command(["git", "rev-parse", "HEAD"]).strip(),
                   "git_status": runner.command(["git", "status", "--short"]),
                   "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "runner_sha256": sha(Path(__file__).read_bytes()),
                   "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()}}
    (runner.evidence / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    runner.stage()
    runner.tests()
    runner.verify()
    if not args.tests_only:
        runner.measure()
    (runner.evidence / "completion.json").write_text(json.dumps({"complete": True,
        "timing": not args.tests_only, "finished_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}) + "\n")


if __name__ == "__main__":
    main()
