#!/usr/bin/env python3
"""Qualify complete native video-color sampling sources on macOS.

Run this entire command through Kyoto when that shared build queue is available.
Otherwise explain its absence before compiling, as the hosted workflow does.
All builds here are sequential and use an isolated output directory.
"""
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
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CORE = "Sources/IlliquidCore/Player/VideoColorSample.swift"
MAPPING = "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift"
SAMPLER = "Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift"
TESTS = (
    "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerTests.swift",
    "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerLayoutTests.swift",
)
# Keep the benchmark call boundary opaque even with Swift\'s default CMO.
FLAGS = ["-swift-version", "6", "-O", "-whole-module-optimization",
         "-disable-cmo", "-warnings-as-errors", "-parse-as-library"]


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be empty; retain previous attempts separately")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        (self.output / "receipts").mkdir()
        self.commands: list[dict] = []
        self.manifest: dict = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
            "pairs": args.pairs,
            "target_ms": args.target_ms,
            "flags": FLAGS,
            "method": "Complete production files; separately optimized dynamic modules; "
                      "fresh processes; equal iterations per pair; alternating AB/BA order; "
                      "calibration retained and excluded from timed pairs; no discarded samples "
                      "or control subtraction.",
            "scope": "Warm CPU component timings using real CoreVideo buffers. "
                     "No decoder, GPU playback, whole-player CPU, FPS, or energy claim.",
            "files": {
                str(path.relative_to(ROOT)): digest(path.read_bytes())
                for path in [Path(__file__).resolve(), HERE / "Harness.swift",
                             *(ROOT / relative for relative in TESTS)]
            },
        }

    def command(self, argv: list[str], *, timeout: int = 600) -> subprocess.CompletedProcess:
        index = len(self.commands) + 1
        log = self.output / "logs" / f"{index:03d}-{Path(argv[0]).name}.log"
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout)
        log.write_text(result.stdout + result.stderr)
        record = {
            "argv": argv, "cwd": str(ROOT), "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started,
            "log": str(log.relative_to(self.output)),
        }
        self.commands.append(record)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv!r}\n"
                               + (result.stdout + result.stderr)[-10000:])
        return result

    def prepare(self) -> None:
        self.manifest.update({
            "swift": self.command(["swift", "--version"]).stdout.strip(),
            "swiftc": self.command(["swiftc", "--version"]).stdout.strip(),
            "git_head": self.command(["git", "rev-parse", "HEAD"]).stdout.strip(),
            "git_status": self.command(["git", "status", "--porcelain"]).stdout.strip(),
            "hardware": self.command(["sysctl", "hw.model", "machdep.cpu.brand_string"]).stdout.strip(),
            "macos": self.command(["sw_vers"]).stdout.strip(),
            "sdk": self.command(["xcrun", "--show-sdk-version"]).stdout.strip(),
            "sources": {},
        })
        baseline = {}
        for relative in (CORE, MAPPING, SAMPLER):
            baseline[relative] = self.command(
                ["git", "show", f"{BASELINE}:{relative}"]).stdout.encode()
        for relative in (CORE, MAPPING):
            if (ROOT / relative).read_bytes() != baseline[relative]:
                raise RuntimeError(f"Shared source changed since baseline; review comparison: {relative}")
        for variant in ("baseline", "candidate"):
            source_dir = self.output / "sources" / variant
            source_dir.mkdir(parents=True)
            hashes = {}
            for relative in (CORE, MAPPING, SAMPLER):
                data = (baseline[relative] if variant == "baseline"
                        else (ROOT / relative).read_bytes())
                (source_dir / Path(relative).name).write_bytes(data)
                hashes[relative] = digest(data)
            self.manifest["sources"][variant] = hashes
        support = self.output / "sources" / "harness-and-tests"
        support.mkdir()
        for source in [HERE / "Harness.swift", *(ROOT / relative for relative in TESTS)]:
            shutil.copyfile(source, support / source.name)
        write_json(self.output / "manifest.json", self.manifest)

    def test(self, variant: str) -> list[dict]:
        package = self.output / "build" / f"tests-{variant}"
        core = package / "Sources" / "IlliquidCore"
        native = package / "Sources" / "IlliquidNativePlayback"
        tests = package / "Tests" / "IlliquidNativePlaybackTests"
        for directory in (core, native, tests):
            directory.mkdir(parents=True)
        source = self.output / "sources" / variant
        shutil.copyfile(source / Path(CORE).name, core / Path(CORE).name)
        for relative in (MAPPING, SAMPLER):
            shutil.copyfile(source / Path(relative).name, native / Path(relative).name)
        for relative in TESTS:
            shutil.copyfile(ROOT / relative, tests / Path(relative).name)
        (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "VideoColorSamplingQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidCore", "IlliquidNativePlayback"]),
    ]
)
""")
        results = []
        for configuration in ("debug", "release"):
            result = self.command([
                "swift", "test", "--package-path", str(package),
                "--scratch-path", str(package / ".build"), "--jobs", "2", "--no-parallel",
                "--configuration", configuration, "-Xswiftc", "-warnings-as-errors",
            ], timeout=900)
            counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*passed",
                                result.stdout + result.stderr)
            if not counts or int(counts[-1]) < 8:
                raise RuntimeError("Expected existing and layout Swift Testing suites to execute")
            record = {"variant": variant, "configuration": configuration,
                      "tests_passed": int(counts[-1]), "status": "passed"}
            results.append(record)
            print("VIDEO_COLOR_TEST " + json.dumps(record, sort_keys=True), flush=True)
        return results

    def build(self, variant: str) -> Path:
        directory = self.output / "build" / f"benchmark-{variant}"
        directory.mkdir(parents=True)
        source = self.output / "sources" / variant
        core_library = directory / "libIlliquidCore.dylib"
        native_library = directory / "libIlliquidNativePlayback.dylib"
        common = ["swiftc", *FLAGS, "-enable-testing", "-emit-module", "-emit-library"]
        self.command([
            *common, "-module-name", "IlliquidCore", "-emit-module-path",
            str(directory / "IlliquidCore.swiftmodule"),
            str(source / Path(CORE).name), "-o", str(core_library),
        ])
        link = ["-I", str(directory), "-L", str(directory), "-lIlliquidCore",
                "-Xlinker", "-rpath", "-Xlinker", str(directory)]
        self.command([
            *common, "-module-name", "IlliquidNativePlayback", "-emit-module-path",
            str(directory / "IlliquidNativePlayback.swiftmodule"), *link,
            str(source / Path(MAPPING).name), str(source / Path(SAMPLER).name),
            "-o", str(native_library),
        ])
        executable = directory / "sampler-benchmark"
        self.command([
            "swiftc", *FLAGS, *link, "-lIlliquidNativePlayback",
            str(HERE / "Harness.swift"), "-o", str(executable),
        ])
        self.manifest.setdefault("binaries", {})[variant] = {
            path.name: digest(path.read_bytes())
            for path in (core_library, native_library, executable)
        }
        return executable

    def measure(self, executable: Path, case: str, iterations: int) -> dict:
        record = json.loads(self.command(
            [str(executable), "measure", case, str(iterations)], timeout=180).stdout)
        if (record["case"] != case or record["iterations"] != iterations
                or record["elapsed_ns"] <= 0 or record["operations"] <= 0
                or "checksum" not in record):
            raise RuntimeError("Measurement receipt does not match its invocation")
        record["ns_per_operation"] = record["elapsed_ns"] / record["operations"]
        return record

    def benchmarks(self, executables: dict[str, Path]) -> None:
        receipts = {}
        for variant, executable in executables.items():
            receipt = json.loads(self.command([str(executable), "verify"]).stdout)
            receipts[variant] = receipt
            write_json(self.output / "receipts" / f"{variant}-verification.json", receipt)
        if receipts["baseline"] != receipts["candidate"]:
            raise RuntimeError("Complete baseline/candidate verification receipts differ")
        cases = receipts["candidate"]["cases"]
        if not cases or len(set(cases)) != len(cases):
            raise RuntimeError("Harness returned an empty or duplicate case list")
        verification = {
            "full_receipts_equal": True,
            "fixture_count": len(receipts["candidate"]["fixtures"]),
            "cases": cases,
            "receipt_sha256": {
                variant: digest(json.dumps(receipt, sort_keys=True, separators=(",", ":"),
                                           allow_nan=False).encode())
                for variant, receipt in receipts.items()
            },
        }
        write_json(self.output / "verification.json", verification)
        print("VIDEO_COLOR_VERIFICATION " + json.dumps(verification, sort_keys=True), flush=True)
        records = []
        calibration = []
        for case in cases:
            initial = {variant: self.measure(binary, case, 1000)
                       for variant, binary in executables.items()}
            for variant, row in initial.items():
                calibration.append({"variant": variant, "stage": "initial", **row})
            fastest = min(row["elapsed_ns"] / 1000 for row in initial.values())
            pilot_iterations = max(1000, math.ceil(20_000_000 / fastest))
            pilots = {variant: self.measure(binary, case, pilot_iterations)
                      for variant, binary in executables.items()}
            for variant, row in pilots.items():
                calibration.append({"variant": variant, "stage": "pilot", **row})
            write_json(self.output / "calibration.json", calibration)
            fastest = min(row["elapsed_ns"] / pilot_iterations for row in pilots.values())
            iterations = max(1, math.ceil(self.args.target_ms * 1_000_000 / fastest))
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                paired = {}
                for position, variant in enumerate(order):
                    row = self.measure(executables[variant], case, iterations)
                    row.update(variant=variant, pair=pair, position=position)
                    paired[variant] = row
                    records.append(row)
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
                    print("VIDEO_COLOR_MEASUREMENT " + json.dumps(row, sort_keys=True), flush=True)
                for field in ("checksum", "operations", "iterations", "published_samples"):
                    if paired["baseline"][field] != paired["candidate"][field]:
                        raise RuntimeError(f"Paired {field} differs for {case}, pair {pair}")
            selected = [row for row in records if row["case"] == case]
            summary = {}
            for variant in ("baseline", "candidate"):
                values = [row["ns_per_operation"] for row in selected if row["variant"] == variant]
                summary[variant] = {"median_ns": statistics.median(values),
                                    "min_ns": min(values), "max_ns": max(values)}
            reductions = []
            for pair in range(self.args.pairs):
                values = {row["variant"]: row["ns_per_operation"]
                          for row in selected if row["pair"] == pair}
                reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
            summary["paired_reduction_percent"] = {
                "median": statistics.median(reductions), "min": min(reductions),
                "max": max(reductions), "values": reductions,
                "candidate_faster_pairs": sum(value > 0 for value in reductions),
                "pairs": len(reductions),
            }
            summary["minimum_sample_ms"] = min(row["elapsed_ns"] for row in selected) / 1_000_000
            self.manifest.setdefault("summary", {})[case] = summary
            write_json(self.output / "summary.json", self.manifest["summary"])
            print("VIDEO_COLOR_SUMMARY " + json.dumps({case: summary}, sort_keys=True), flush=True)

    def run(self) -> None:
        try:
            self.prepare()
            tests = []
            for variant in ("baseline", "candidate"):
                tests.extend(self.test(variant))
                write_json(self.output / "tests.json", tests)
            if not self.args.tests_only:
                executables = {variant: self.build(variant)
                               for variant in ("baseline", "candidate")}
                self.benchmarks(executables)
            self.manifest["status"] = "passed"
        except Exception as error:
            self.manifest["status"] = "failed"
            write_json(self.output / "failure.json", {
                "type": type(error).__name__, "message": str(error),
            })
            raise
        finally:
            self.manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
            self.manifest["commands"] = self.commands
            write_json(self.output / "manifest.json", self.manifest)
            # Summary and exact commands have their own readable log records.
            compact = {key: value for key, value in self.manifest.items()
                       if key not in ("commands", "summary")}
            print("VIDEO_COLOR_MANIFEST " + json.dumps(compact, sort_keys=True), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This qualification uses real CoreVideo buffers and requires macOS")
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms < 50:
        parser.error("Use an even pair count of at least two and a target of at least 50 ms")
    Runner(args).run()


if __name__ == "__main__":
    main()
