#!/usr/bin/env python3
"""Test and measure the actual observation ledger, including retained snapshots.

Uses the Python standard library and the installed Swift toolchain. It extracts
one contiguous production region; it never rewrites that region or substitutes
platform shims. macOS also runs the complete native target in the CI workflow.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCE = "Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift"
TEST = "Tests/IlliquidNativePlaybackTests/RuntimeObservationMetricsTests.swift"
COALESCER_TESTS = "Tests/IlliquidNativePlaybackTests/PresentationTimeObservationTests.swift"
SCENARIOS = ("steady-1", "steady-4", "steady-16", "batch-16", "retained-64", "snapshot-only", "control")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library"]


def digest(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def region(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("Source boundaries changed; review extraction before measuring")
    first, last = source.index(start), source.index(end)
    if first >= last:
        raise ValueError("Invalid source boundary order")
    return source[first:last]


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.commands: list[dict] = []
        self.env = os.environ.copy()
        self.env["SWIFT_MODULECACHE_PATH"] = str(self.output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.swift = shutil.which("swift")
        self.swiftc = shutil.which("swiftc")
        if not self.swift or not self.swiftc:
            raise ValueError("Swift and swiftc must be on PATH (Swift 6.1 or newer)")
        self.manifest = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
            "swift_version": self.command([self.swiftc, "--version"]).strip(),
            "flags": FLAGS,
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
            "test_sha256": digest((ROOT / TEST).read_bytes()),
            "pairs": args.pairs,
            "iterations": args.iterations,
            "scenarios": args.scenarios,
            "ledger_only_tests": args.ledger_only_tests,
            "sources": {},
            "scope": "Observation accounting component only; no playback, decoder, renderer, or UI CPU measurement",
        }
        if platform.system() == "Darwin":
            self.manifest["host"] = self.command(["sw_vers"])
            self.manifest["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        elif Path("/proc/cpuinfo").exists():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), None)
            if Path("/sys/fs/cgroup/cpu.max").exists():
                self.manifest["cgroup_cpu_max"] = Path("/sys/fs/cgroup/cpu.max").read_text().strip()

    def command(self, argv: list[str], log: Path | None = None) -> str:
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - started})
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n{result.stdout[-2000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def prepare(self, variant: str) -> Path:
        raw = ((ROOT / SOURCE).read_text() if variant == "candidate" else
               self.command(["git", "show", f"{BASELINE}:{SOURCE}"]))
        extracted = "import Foundation\n\n" + region(raw,
            "enum RuntimeObservationSource: String, CaseIterable, Sendable {",
            "/// Production adapter around the qualified native playback implementation.")
        destination = self.output / variant
        destination.mkdir()
        path = destination / "Observation.swift"
        path.write_text(extracted)
        self.manifest["sources"][variant] = {
            "path": SOURCE, "whole_file_sha256": digest(raw),
            "extracted_sha256": digest(extracted),
            "extracted_bytes": len(extracted.encode()),
        }
        return path

    def test(self, variant: str, source: Path) -> None:
        package = source.parent / "tests"
        production = package / "Sources/IlliquidNativePlayback"
        tests = package / "Tests/IlliquidNativePlaybackTests"
        production.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copy2(source, production / source.name)
        shutil.copy2(ROOT / TEST, tests / Path(TEST).name)
        # These existing production-coalescer tests need only Foundation.
        # Copy their bodies unchanged; native-only renderer tests remain in the
        # full app job, with no CoreMedia stand-ins in this component package.
        bodies = region((ROOT / COALESCER_TESTS).read_text(),
            "    @Test @MainActor func busyMainActorCoalescesClockCallbacks()",
            "    @Test func invalidFrameRatesStayBounded()")
        (tests / "ObservationCoalescerTests.swift").write_text(
            "import Foundation\nimport Testing\n@testable import IlliquidNativePlayback\n\n"
            '@Suite("Production observation coalescer", .serialized)\n'
            "struct ObservationCoalescerTests {\n" + bodies + "}\n")
        self.manifest["coalescer_test_bodies_sha256"] = digest(bodies)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ObservationMetricsQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
        for configuration in ("debug", "release"):
            command = [self.swift, "test", "--package-path", str(package),
                       "--scratch-path", str(package / "build"),
                       "--cache-path", str(package / "cache"),
                       "--config-path", str(package / "config"),
                       "--security-path", str(package / "security"),
                       "--jobs", "2", "--disable-sandbox", "--no-parallel",
                       "--configuration", configuration]
            if platform.system() == "Linux":
                command.append("--use-integrated-swift-driver")
            if self.args.ledger_only_tests:
                command.extend(["--filter", "RuntimeObservationMetricsTests"])
            result = self.command(command, self.output / f"{variant}-{configuration}-tests.log")
            print(f"{variant} {configuration}: " + "\n".join(result.splitlines()[-2:]), flush=True)

    def build(self, variant: str, source: Path) -> Path:
        binary = source.parent / "observation-benchmark"
        target = ["-target", f"{platform.machine()}-apple-macosx26.0"] if platform.system() == "Darwin" else []
        command = [self.swiftc, *FLAGS, *target, "-module-cache-path", str(self.output / "module-cache"),
                   str(source), str(HERE / "Harness.swift"), "-o", str(binary)]
        self.command(command, self.output / f"{variant}-build.log")
        self.manifest["sources"][variant]["binary_sha256"] = digest(binary.read_bytes())
        return binary

    def measure(self, binaries: dict[str, Path]) -> None:
        rows: list[dict] = []
        with (self.output / "measurements.jsonl").open("w") as output:
            for pair in range(self.args.pairs):
                scenarios = self.args.scenarios if pair % 2 == 0 else list(reversed(self.args.scenarios))
                for scenario in scenarios:
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    receipts = []
                    for position, variant in enumerate(order):
                        row = json.loads(self.command([str(binaries[variant]), "--scenario", scenario,
                                                       "--iterations", str(self.args.iterations)]))
                        row.update(variant=variant, pair=pair, position=position)
                        row["ns_per_operation"] = row["elapsed_ns"] / row["operations"]
                        receipts.append((row["checksum"], row["operations"]))
                        rows.append(row)
                        output.write(json.dumps(row, sort_keys=True) + "\n")
                        output.flush()
                    if receipts[0] != receipts[1]:
                        raise ValueError(f"Benchmark receipt differs: {scenario}, pair {pair}")
                print(f"Completed paired round {pair + 1}/{self.args.pairs}", flush=True)
        summary = []
        for scenario in self.args.scenarios:
            cohorts = {variant: [row["ns_per_operation"] for row in rows
                                 if row["scenario"] == scenario and row["variant"] == variant]
                       for variant in ("baseline", "candidate")}
            baseline, candidate = (statistics.median(cohorts[v]) for v in ("baseline", "candidate"))
            paired = []
            for pair in range(self.args.pairs):
                by_variant = {r["variant"]: r["ns_per_operation"] for r in rows
                              if r["scenario"] == scenario and r["pair"] == pair}
                paired.append(100 * (1 - by_variant["candidate"] / by_variant["baseline"]))
            result = {"scenario": scenario, "baseline_ns": baseline, "candidate_ns": candidate,
                      "median_reduction_percent": 100 * (1 - candidate / baseline),
                      "paired_reduction_percent": paired,
                      "baseline_range_ns": [min(cohorts["baseline"]), max(cohorts["baseline"])],
                      "candidate_range_ns": [min(cohorts["candidate"]), max(cohorts["candidate"])]}
            summary.append(result)
            print(f"{scenario}: {baseline:.1f} -> {candidate:.1f} ns/op "
                  f"({result['median_reduction_percent']:.1f}% reduction)", flush=True)
        write_json(self.output / "summary.json", summary)

    def run(self) -> None:
        try:
            sources = {v: self.prepare(v) for v in ("baseline", "candidate")}
            if self.args.mode in ("all", "test"):
                for variant, source in sources.items():
                    self.test(variant, source)
            if self.args.mode in ("all", "bench"):
                binaries = {v: self.build(v, s) for v, s in sources.items()}
                self.measure(binaries)
        finally:
            self.manifest["commands"] = self.commands
            self.manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
            write_json(self.output / "manifest.json", self.manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("all", "test", "bench"), default="all")
    parser.add_argument("--output", type=Path, required=True, help="new output directory")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=200_000)
    parser.add_argument("--ledger-only-tests", action="store_true",
                        help="exclude asynchronous coalescer tests on hosts unable to run libdispatch reliably")
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.iterations < 16:
        parser.error("pairs must be positive and even; iterations must be at least 16")
    Runner(args).run()


if __name__ == "__main__":
    main()
