#!/usr/bin/env python3
"""Compare the actual file-key helper and its folder-playlist caller."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
KEY_SOURCE = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
SOURCES = [
    KEY_SOURCE,
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/UtilitiesTests.swift",
    "Tests/IlliquidCoreTests/LocalMediaSourceValidationTests.swift",
    "Tests/IlliquidCoreTests/FolderPlaylistLookupTests.swift",
    "Tests/IlliquidCoreTests/FolderPlaylistTests.swift",
    "Tests/IlliquidCoreTests/FileIdentityKeyTests.swift",
    "Tests/IlliquidCoreTests/TestSupport/FileIdentityKeyCorpus.swift",
]
WORKLOADS = [
    "key-prepared", "key-unicode", "key-lexical", "key-rejected-control",
    "normalize-control", "same-file", "playlist-32", "playlist-1000", "playlist-10000",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "FileIdentityKeyRegressions",
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
"""


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Research:
    def __init__(self, output):
        self.output = output
        self.commands = []
        self.environment = os.environ.copy()
        cache = output / "module-cache"
        cache.mkdir()
        for key in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.environment[key] = str(cache)
        self.environment.update({"TERM": "dumb", "NO_COLOR": "1"})
        self.swiftc = shutil.which("swiftc")
        self.swift = shutil.which("swift")
        if not self.swiftc or not self.swift:
            raise RuntimeError("A Swift 6.1 or newer toolchain is required")
        frozen = HERE / "baseline/NormalizedFileURL.swift"
        baseline = json.loads((HERE / "baseline/manifest.json").read_text())
        content = frozen.read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        if blob != baseline["git_blob"]:
            raise RuntimeError("Frozen baseline no longer matches its recorded Git blob")
        self.manifest = {
            "baseline": baseline,
            "git_head": self.run(["git", "rev-parse", "HEAD"], "git-head.log").strip(),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": sys.version,
            "compiler": self.run([self.swiftc, "--version"], "compiler.log").strip(),
            "swiftc": self.swiftc,
            "flags": ["-swift-version", "6", "-O", "-whole-module-optimization"],
            "source_files": {},
            "harness_files": {
                str(path.relative_to(ROOT)): sha256(path)
                for path in [Path(__file__), HERE / "Driver.swift"] + [ROOT / name for name in TESTS]
            },
            "qualification": "macOS Foundation component timing; no live playback or UI claim",
        }
        write_json(output / "manifest.json", self.manifest)

    def run(self, arguments, log):
        started = time.monotonic()
        result = subprocess.run(
            [str(value) for value in arguments], cwd=ROOT, env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        destination = self.output / log
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(result.stdout)
        self.commands.append({
            "argv": [str(value) for value in arguments],
            "returncode": result.returncode,
            "log": log,
            "wall_seconds": time.monotonic() - started,
        })
        write_json(self.output / "commands.json", self.commands)
        if result.returncode:
            print(result.stdout[-12000:], flush=True)
            raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
        return result.stdout

    def stage(self, variant, parent):
        target = parent / "Sources/IlliquidCore"
        target.mkdir(parents=True)
        records = {}
        for relative in SOURCES:
            source = HERE / "baseline/NormalizedFileURL.swift" if (
                variant == "baseline" and relative == KEY_SOURCE
            ) else ROOT / relative
            shutil.copyfile(source, target / Path(relative).name)
            records[relative] = sha256(source)
        self.manifest["source_files"][variant] = records
        write_json(self.output / "manifest.json", self.manifest)
        return sorted(target.glob("*.swift"))

    def build_driver(self, variant):
        build = self.output / "build" / variant
        sources = self.stage(variant, build)
        extension = "dylib" if sys.platform == "darwin" else "so"
        library = build / f"libIlliquidCore.{extension}"
        common = [self.swiftc, "-swift-version", "6", "-O", "-whole-module-optimization",
                  "-warnings-as-errors"]
        self.run(common + [
            "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
            "-emit-module-path", build / "IlliquidCore.swiftmodule",
            *sources, "-o", library,
        ], f"{variant}-library-build.log")
        driver = build / "driver"
        self.run(common + [
            "-parse-as-library", "-I", build, "-L", build, "-lIlliquidCore",
            "-Xlinker", "-rpath", "-Xlinker", build,
            ROOT / "Tests/IlliquidCoreTests/TestSupport/FileIdentityKeyCorpus.swift",
            HERE / "Driver.swift", "-o", driver,
        ], f"{variant}-driver-build.log")
        self.manifest.setdefault("binaries", {})[variant] = {
            "driver": sha256(driver), "library": sha256(library),
        }
        write_json(self.output / "manifest.json", self.manifest)
        return driver

    def tests(self):
        receipts = []
        for variant in ("baseline", "candidate"):
            package = self.output / "build" / variant
            self.stage(variant, package)
            test_directory = package / "Tests/IlliquidCoreTests"
            test_directory.mkdir(parents=True)
            for relative in TESTS:
                shutil.copyfile(ROOT / relative, test_directory / Path(relative).name)
            (package / "Package.swift").write_text(PACKAGE)
            for configuration in ("debug", "release"):
                command = [
                    self.swift, "test", "--package-path", package,
                    "--configuration", configuration, "--jobs", "2", "--no-parallel",
                    "--cache-path", self.output / "cache",
                    "--config-path", self.output / "config",
                    "--security-path", self.output / "security",
                    "--scratch-path", package / ".build",
                    "-Xswiftc", "-warnings-as-errors",
                ]
                if sys.platform == "linux":
                    command.append("--use-integrated-swift-driver")
                log = f"{variant}-{configuration}-tests.log"
                self.run(command, log)
                receipts.append({"variant": variant, "configuration": configuration, "passed": True,
                                 "log": log, "log_sha256": sha256(self.output / log)})
                write_json(self.output / "tests.json", {"runs": receipts})
        print("FILE_IDENTITY_TESTS " + json.dumps({"runs": receipts}, sort_keys=True), flush=True)

    def timings(self, pair_count, target_ms):
        drivers = {variant: self.build_driver(variant) for variant in ("baseline", "candidate")}
        verification = {}
        for variant, driver in drivers.items():
            verification[variant] = json.loads(self.run([driver, "verify"], f"{variant}-verify.json"))
        baseline, candidate = verification["baseline"], verification["candidate"]
        mismatches = []
        if baseline != candidate:
            if len(baseline["rows"]) != len(candidate["rows"]):
                raise RuntimeError("Differential corpus sizes differ")
            for index, (before, after) in enumerate(zip(baseline["rows"], candidate["rows"])):
                if before != after:
                    mismatches.append({"index": index, "baseline": before, "candidate": after})
        passed = baseline == candidate and candidate["oracle_mismatches"] == 0
        receipt = {
            "passed": passed, "cases": baseline["cases"], "constructed": baseline["constructed"],
            "constructor_rejections": baseline["constructor_rejections"],
            "candidate_oracle_mismatches": candidate["oracle_mismatches"],
            "baseline_receipt_sha256": sha256(self.output / "baseline-verify.json"),
            "candidate_receipt_sha256": sha256(self.output / "candidate-verify.json"),
            "mismatch_count": len(mismatches), "first_mismatches": mismatches[:20],
        }
        write_json(self.output / "verification.json", receipt)
        print("FILE_IDENTITY_VERIFICATION " + json.dumps(receipt, sort_keys=True), flush=True)
        if not passed:
            raise RuntimeError("File-key compatibility failed; no performance result is accepted")

        calibration = []
        observations = []
        summaries = []
        sequence = 0

        def sample(variant, workload, iterations, phase, pair=None):
            nonlocal sequence
            sequence += 1
            log = f"measurements/{sequence:04d}-{phase}-{workload}-{variant}.json"
            data = json.loads(self.run([drivers[variant], "measure", workload, iterations], log))
            if data["iterations"] != iterations or data["workload"] != workload:
                raise RuntimeError("Driver returned inconsistent workload metadata")
            data.update({"variant": variant, "phase": phase, "pair": pair, "log": log})
            return data

        def same_outputs(before, after):
            for field in ("iterations", "checksum", "warmup_checksum", "workload"):
                if before[field] != after[field]:
                    raise RuntimeError(f"Timing output mismatch: {field}")

        for workload in WORKLOADS:
            iterations = 4
            for attempt in range(8):
                before = sample("baseline", workload, iterations, "calibration")
                after = sample("candidate", workload, iterations, "calibration")
                same_outputs(before, after)
                calibration.extend([before, after])
                write_json(self.output / "calibration.json", calibration)
                fastest = min(before["elapsed_ns"], after["elapsed_ns"])
                if fastest >= target_ms * 1_000_000:
                    break
                iterations = max(iterations + 4, math.ceil(
                    iterations * target_ms * 1_000_000 / max(1, fastest) / 4
                ) * 4)
                if iterations > 10_000_000:
                    raise RuntimeError("Calibration exceeded its iteration bound")
            else:
                raise RuntimeError("Calibration did not reach its target duration")

            pairs = []
            for pair in range(pair_count):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                measured = {}
                for variant in order:
                    value = sample(variant, workload, iterations, "timing", pair)
                    observations.append(value)
                    measured[variant] = value
                    write_json(self.output / "observations.json", observations)
                same_outputs(measured["baseline"], measured["candidate"])
                pairs.append({
                    "pair": pair, "order": list(order),
                    "baseline_ns_per_operation": measured["baseline"]["elapsed_ns"] / iterations,
                    "candidate_ns_per_operation": measured["candidate"]["elapsed_ns"] / iterations,
                    "candidate_over_baseline": measured["candidate"]["elapsed_ns"]
                        / measured["baseline"]["elapsed_ns"],
                })
            ratios = [value["candidate_over_baseline"] for value in pairs]
            summary = {
                "workload": workload, "iterations": iterations, "pair_count": pair_count,
                "baseline_median_ns": statistics.median(
                    value["baseline_ns_per_operation"] for value in pairs),
                "candidate_median_ns": statistics.median(
                    value["candidate_ns_per_operation"] for value in pairs),
                "median_paired_ratio": statistics.median(ratios),
                "paired_ratio_min": min(ratios), "paired_ratio_max": max(ratios),
                "median_paired_reduction_percent": (1 - statistics.median(ratios)) * 100,
                "pairs": pairs,
            }
            summaries.append(summary)
            write_json(self.output / "summary.json", {
                "method": "fresh processes; identical operation counts; alternating AB/BA pairs",
                "target_ms": target_ms, "workloads": summaries,
            })
            print("FILE_IDENTITY_RESULT " + json.dumps(summary, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    arguments = parser.parse_args()
    if arguments.pairs < 4 or arguments.pairs % 2:
        parser.error("--pairs must be even and at least four")
    if arguments.target_ms <= 0:
        parser.error("--target-ms must be positive")
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    try:
        if Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists():
            print("Kyoto is available; launch this harness through its shared queue.", flush=True)
        else:
            print("Kyoto is unavailable; compiling serially in an isolated component build.", flush=True)
        research = Research(output)
        if arguments.test:
            research.tests()
        else:
            research.timings(arguments.pairs, arguments.target_ms)
    except Exception as error:
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
