#!/usr/bin/env python3
"""Test exact source-browser sorting code and measure paired complete sorts.

The isolated Swift package uses the real entry/metadata types and sorter. Only
unrelated SwiftUI declarations are omitted; no sorting implementation or model
is substituted. This runner does not fetch dependencies or edit app sources.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SIDEBAR = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
METADATA = "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
TEST = "Tests/IlliquidAppTests/SourceTreeSortingTests.swift"
WORKLOADS = [
    "name-random", "name-sorted", "name-reverse", "name-duplicates",
    "mixed-name", "date-unique", "date-unique-descending", "date-ties", "date-only", "type-only",
    "off", "metadata-name",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SourceTreeSortingQualification", targets: [
    .target(name: "IlliquidCore"),
    .executableTarget(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"]),
])
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def between(source: str, first: str, after: str) -> str:
    if source.count(first) != 1 or source.count(after) != 1:
        raise ValueError("Source declaration boundaries changed; review extraction")
    start, end = source.index(first), source.index(after)
    if end <= start:
        raise ValueError("Invalid declaration order")
    return source[start:end]


def selected_source(source: bytes) -> bytes:
    text = source.decode()
    entry = between(text, "struct SourceTreeEntry: ", "struct SourceVisibilityRegexMatch: ")
    sorting = between(text, "enum SourceTreeSortCriterion: ", "struct SourceDirectoryListing: ")
    return ("import Foundation\nimport IlliquidCore\n\n" + entry + sorting).encode()


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("--output must be new or empty; existing evidence is never overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env.update(
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
            CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
        )
        self.receipt: dict = {"baseline_revision": BASELINE, "variants": {}}
        self.commands: list[dict] = []

    def command(self, argv: list[str | Path], log: Path | None = None) -> str:
        argv = [str(part) for part in argv]
        started = time.monotonic()
        completed = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                   text=True, timeout=1200)
        self.commands.append({"argv": argv, "returncode": completed.returncode,
                              "elapsed_seconds": time.monotonic() - started})
        write_json(self.output / "commands.json", self.commands)
        if log:
            log.write_text(completed.stdout + completed.stderr)
        if completed.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n"
                               f"{completed.stdout[-5000:]}\n{completed.stderr[-7000:]}")
        return completed.stdout

    def swift(self, action: str, variant: str, configuration: str) -> list[str | Path]:
        return [self.args.swift, action,
                "--package-path", self.output / variant,
                "--scratch-path", self.output / "build" / variant,
                "--cache-path", self.output / "swiftpm-cache",
                "--config-path", self.output / "swiftpm-config",
                "--security-path", self.output / "swiftpm-security",
                "--configuration", configuration, "--jobs", "2"]

    def prepare(self) -> None:
        environment = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "architecture": platform.machine(),
            "logical_cpus": os.cpu_count(), "python": sys.version,
            "swift": self.command([self.args.swift, "--version"]).strip(),
            "head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "status": self.command(["git", "status", "--short"]),
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
        }
        write_json(self.output / "environment.json", environment)
        harness = (HERE / "Harness.swift").read_bytes()
        tests = (ROOT / TEST).read_bytes()
        (self.output / "runner.snapshot.py").write_bytes(Path(__file__).read_bytes())
        for variant in ("baseline", "candidate"):
            sidebar = ((ROOT / SIDEBAR).read_bytes() if variant == "candidate" else
                       self.command(["git", "show", f"{BASELINE}:{SIDEBAR}"]).encode())
            metadata = ((ROOT / METADATA).read_bytes() if variant == "candidate" else
                        self.command(["git", "show", f"{BASELINE}:{METADATA}"]).encode())
            sources = {
                "Package.swift": PACKAGE.encode(),
                "Sources/IlliquidApp/SidebarSorting.swift": selected_source(sidebar),
                "Sources/IlliquidApp/Harness.swift": harness,
                "Sources/IlliquidCore/MediaNameRecognition.swift": metadata,
                "Tests/IlliquidAppTests/SourceTreeSortingTests.swift": tests,
            }
            manifest = {"repository_sources": {SIDEBAR: digest(sidebar), METADATA: digest(metadata)},
                        "staged_sources": {name: digest(data) for name, data in sources.items()}}
            for name, data in sources.items():
                path = self.output / variant / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            self.receipt["variants"][variant] = manifest
        write_json(self.output / "source-receipt.json", self.receipt)

    def build_and_verify(self) -> dict[str, Path]:
        binaries: dict[str, Path] = {}
        verification: dict = {}
        for configuration in ("debug", "release"):
            traces = {}
            for variant in ("baseline", "candidate"):
                print(f"Testing {variant} ({configuration})", flush=True)
                self.command(self.swift("test", variant, configuration),
                             self.output / f"tests-{variant}-{configuration}.log")
                bin_path = Path(self.command(self.swift("build", variant, configuration)
                                             + ["--show-bin-path"]).strip())
                binary = bin_path / "IlliquidApp"
                trace = self.command([binary, "verify"])
                (self.output / f"parity-{variant}-{configuration}.json").write_text(trace)
                traces[variant] = json.loads(trace)
                if configuration == "release":
                    binaries[variant] = binary
            if traces["baseline"] != traces["candidate"]:
                raise AssertionError(f"Exact row-order/metadata parity failed in {configuration}")
            verification[configuration] = {"exact_parity": True, "result": traces["candidate"]}
        write_json(self.output / "verification.json", verification)
        return binaries

    def measure(self, binaries: dict[str, Path]) -> None:
        summaries = []
        observations = []
        for size in self.args.sizes:
            for workload in self.args.workloads:
                complete_outputs = {}
                for variant in ("baseline", "candidate"):
                    complete_outputs[variant] = self.command(
                        [binaries[variant], "verify-fixture", str(size), workload])
                if json.loads(complete_outputs["baseline"]) != json.loads(complete_outputs["candidate"]):
                    raise AssertionError(f"Complete benchmark fixture parity failed: {workload}/{size}")
                fixtures = self.output / "verified-fixtures"
                fixtures.mkdir(exist_ok=True)
                # Both exact ordinal sequences are equal; retain one copy.
                (fixtures / f"{workload}-{size}.json").write_text(complete_outputs["candidate"])
                warm = {}
                for variant in ("baseline", "candidate"):
                    warm[variant] = json.loads(self.command([binaries[variant], "bench", str(size), workload, "1"]))
                iterations = max(1, min(2000, math.ceil(self.args.target_ms * 1_000_000 /
                                                      max(1, warm["baseline"]["elapsed_ns"]))))
                timings = {"baseline": [], "candidate": []}
                paired_changes = []
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    results = {}
                    for variant in order:
                        result = json.loads(self.command([binaries[variant], "bench", str(size), workload,
                                                          str(iterations)]))
                        results[variant] = result
                        elapsed = result["elapsed_ns"] / iterations
                        timings[variant].append(elapsed)
                        observations.append({"size": size, "workload": workload, "pair": pair,
                                             "order": order, "variant": variant,
                                             "nanoseconds_per_sort": elapsed, **result})
                    if results["baseline"]["checksum"] != results["candidate"]["checksum"]:
                        raise AssertionError(f"Benchmark output parity failed: {workload}/{size}")
                    paired_changes.append(100 * (results["candidate"]["elapsed_ns"] /
                                                  max(1, results["baseline"]["elapsed_ns"]) - 1))
                baseline, candidate = (statistics.median(timings[v]) for v in ("baseline", "candidate"))
                summaries.append({"size": size, "workload": workload, "iterations": iterations,
                                  "pairs": self.args.pairs,
                                  "complete_fixture_parity": True,
                                  "baseline_median_ns": baseline, "candidate_median_ns": candidate,
                                  "change_percent": 100 * (candidate / baseline - 1),
                                  "paired_change_median_percent": statistics.median(paired_changes),
                                  "baseline_range_ns": [min(timings["baseline"]), max(timings["baseline"])],
                                  "candidate_range_ns": [min(timings["candidate"]), max(timings["candidate"])]})
                write_json(self.output / "observations.json", observations)
                write_json(self.output / "summary.json", summaries)
                print(f"{workload:17} n={size:5} {baseline / 1e6:9.3f} -> {candidate / 1e6:9.3f} ms "
                      f"({100 * (candidate / baseline - 1):+.1f}%)", flush=True)

    def verify_sources(self) -> None:
        for variant, receipt in self.receipt["variants"].items():
            for name, expected in receipt["staged_sources"].items():
                if digest((self.output / variant / name).read_bytes()) != expected:
                    raise AssertionError(f"Staged source changed during qualification: {variant}/{name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=60)
    parser.add_argument("--sizes", type=int, nargs="+", default=[10, 100, 1000, 10000])
    parser.add_argument("--workloads", nargs="+", choices=WORKLOADS, default=WORKLOADS)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be an even integer in 2...20 for balanced ordering")
    if not math.isfinite(args.target_ms) or not 1 <= args.target_ms <= 1000:
        parser.error("--target-ms must be finite and in 1...1000")
    if any(size < 0 or size > 100000 for size in args.sizes):
        parser.error("--sizes must be in 0...100000")
    runner = Runner(args)
    runner.prepare()
    binaries = runner.build_and_verify()
    if not args.tests_only:
        runner.measure(binaries)
    runner.verify_sources()
    print(f"Qualification complete: {runner.output}", flush=True)


if __name__ == "__main__":
    main()
