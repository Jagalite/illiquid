#!/usr/bin/env python3
"""Qualify the actual Foundation read-ahead gate without the player SDK.

Wake counts use a benchmark-only wrapper around NSCondition. CPU/context-switch runs
compile the production source unchanged with Foundation's real NSCondition.
Neither is a measurement of whole-player CPU or energy.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = "Sources/IlliquidNativePlayback/Media/MediaReadAheadGate.swift"
TEST = "Tests/IlliquidNativePlaybackTests/MediaReadAheadGateTests.swift"
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ORIGINAL_EXPERIMENT_COMMIT = "2bea445f23e65f238ca46539fa2b63169f1ffebb"
BASELINE_HASH = "0eb12da34194e55f47502f2bbb55649718c552d5128021228d9b81728c5973ee"
VARIANTS = ("baseline", "candidate")
SCENARIOS = ("eof", "future", "active", "idle", "multi-eof")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6",
         "-warnings-as-errors", "-parse-as-library"]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.commands: list[dict] = []
        self.test_results: list[dict] = []
        self.env = os.environ.copy()
        self.env["SWIFT_MODULECACHE_PATH"] = str(self.output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.swift = shutil.which("swift")
        self.swiftc = shutil.which("swiftc")
        if not self.swift or not self.swiftc:
            raise RuntimeError("Swift 6.1+ and swiftc must be on PATH")
        baseline = HERE / "baseline/MediaReadAheadGate.swift"
        if digest(baseline) != BASELINE_HASH:
            raise RuntimeError("Pinned baseline changed; review before measuring")
        self.sources = {"baseline": baseline, "candidate": ROOT / SOURCE}
        if digest(self.sources["candidate"]) == BASELINE_HASH:
            raise RuntimeError("Candidate equals baseline; no performance change to qualify")
        self.manifest = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_commit": BASELINE_COMMIT,
            "original_experiment_commit": ORIGINAL_EXPERIMENT_COMMIT,
            "checkout_commit": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree": self.command(["git", "status", "--short"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": self.command([self.swiftc, "--version"]).strip(),
            "flags": FLAGS, "pairs": args.pairs,
            "updates": args.updates, "interval_us": args.interval_us,
            "scenarios": args.scenarios,
            "source_sha256": {key: digest(path) for key, path in self.sources.items()},
            "driver_sha256": digest(HERE / "Driver.swift"),
            "counter_sha256": digest(HERE / "CountingCondition.swift"),
            "test_sha256": digest(ROOT / TEST),
            "runner_sha256": digest(Path(__file__)),
            "scope": "Gate only; paced synthetic observations, no player, decoding, rendering, or energy measurement.",
        }
        if platform.system() == "Darwin":
            self.manifest["host"] = self.command(["sw_vers"])
            self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()

    def command(self, argv: list[str], log: Path | None = None, timeout: int = 300) -> str:
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - start})
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Failed: {argv!r}\n{result.stdout[-2000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def test(self, variant: str) -> None:
        package = self.output / variant / "tests"
        source = package / "Sources/IlliquidNativePlayback"
        tests = package / "Tests/IlliquidNativePlaybackTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copy2(self.sources[variant], source / "MediaReadAheadGate.swift")
        shutil.copy2(ROOT / TEST, tests / "MediaReadAheadGateTests.swift")
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ReadAheadGateQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
        for configuration in ("debug", "release"):
            args = [self.swift, "test", "--package-path", str(package),
                    "--scratch-path", str(package / "build"),
                    "--cache-path", str(package / "cache"),
                    "--config-path", str(package / "config"),
                    "--security-path", str(package / "security"),
                    "--disable-sandbox", "--no-parallel", "--jobs", "2",
                    "--configuration", configuration, "-Xswiftc", "-warnings-as-errors"]
            if platform.system() == "Linux":
                args.append("--use-integrated-swift-driver")
            log_path = self.output / f"{variant}-{configuration}-tests.log"
            self.command(args, log_path)
            log = log_path.read_text()
            completions = re.findall(r"Test run with (\d+) tests? passed", log)
            expected_count = len(re.findall(r"@Test\b", (ROOT / TEST).read_text()))
            if len(completions) != 1 or int(completions[0]) != expected_count or expected_count == 0:
                raise RuntimeError(f"Missing complete regression receipt: {variant}/{configuration}")
            self.test_results.append({"variant": variant, "configuration": configuration,
                                      "passed": True, "tests": expected_count})
            write_json(self.output / "tests.json", self.test_results)
            print(f"{variant} {configuration}: {expected_count} tests passed", flush=True)

    def build(self, variant: str, instrumented: bool) -> Path:
        directory = self.output / variant
        directory.mkdir(exist_ok=True)
        mode = "counts" if instrumented else "native"
        binary = directory / f"gate-{mode}"
        args = [self.swiftc, *FLAGS, "-module-cache-path", str(self.output / "module-cache")]
        if platform.system() == "Darwin":
            args.extend(["-target", f"{platform.machine()}-apple-macosx26.0"])
        args.extend([str(self.sources[variant]), str(HERE / "Driver.swift")])
        if instrumented:
            args.extend(["-D", "GATE_WAKE_COUNTS", str(HERE / "CountingCondition.swift")])
        args.extend(["-o", str(binary)])
        self.command(args, self.output / f"{variant}-{mode}-build.log")
        self.manifest.setdefault("binary_sha256", {})[f"{variant}-{mode}"] = digest(binary)
        return binary

    def measure(self, binaries: dict[tuple[str, bool], Path]) -> None:
        rows: list[dict] = []
        with (self.output / "measurements.jsonl").open("w") as output:
            # Counter runs establish event counts, never timing claims. Run both
            # orders across pairs for the actual uninstrumented measurements.
            for instrumented, rounds in ((True, 1), (False, self.args.pairs)):
                for pair in range(rounds):
                    scenarios = self.args.scenarios if pair % 2 == 0 else list(reversed(self.args.scenarios))
                    if not instrumented:
                        scenarios = [scenario for scenario in scenarios if scenario != "multi-eof"]
                    for scenario in scenarios:
                        order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                        receipts = []
                        for order_index, variant in enumerate(order):
                            updates = min(24, self.args.updates) if scenario == "multi-eof" else self.args.updates
                            argv = [str(binaries[variant, instrumented]), "--scenario", scenario,
                                    "--updates", str(updates), "--interval-us", str(self.args.interval_us)]
                            row = json.loads(self.command(argv, timeout=60))
                            row.update(variant=variant, pair=pair, order=order_index)
                            if row["instrumented"] != instrumented:
                                raise RuntimeError("Instrumentation mode receipt is wrong")
                            if instrumented and scenario in ("eof", "future", "idle", "multi-eof"):
                                broadcasts = row["counts"]["broadcasts"]
                                if variant == "candidate" and broadcasts != 0:
                                    raise RuntimeError(f"Candidate generated unnecessary broadcasts: {scenario}")
                                if variant == "baseline" and broadcasts < updates:
                                    raise RuntimeError(f"Baseline update broadcasts were not observed: {scenario}")
                            receipts.append(row["receipt"])
                            rows.append(row)
                            output.write(json.dumps(row, sort_keys=True) + "\n")
                            output.flush()
                        if receipts[0] != receipts[1]:
                            raise RuntimeError(f"Behavioral receipt differs for {scenario}: {receipts}")
                    print(f"{'counts' if instrumented else 'native'} round {pair + 1}/{rounds} passed", flush=True)
        summary = []
        for scenario in self.args.scenarios:
            item: dict = {"scenario": scenario}
            if scenario == "multi-eof":
                item["scope"] = "Instrumented adversarial multiple-reader control; no CPU timing claim"
                for variant in VARIANTS:
                    counted = next(r for r in rows if r["scenario"] == scenario and r["variant"] == variant and r["instrumented"])
                    item[variant] = {"counts": counted["counts"]}
                summary.append(item)
                continue
            for variant in VARIANTS:
                cohort = [r for r in rows if r["scenario"] == scenario and r["variant"] == variant and not r["instrumented"]]
                item[variant] = {metric: statistics.median(r[metric] for r in cohort)
                                 for metric in ("cpu_ns", "elapsed_ns", "voluntary_context_switches", "involuntary_context_switches")}
                counted = next(r for r in rows if r["scenario"] == scenario and r["variant"] == variant and r["instrumented"])
                item[variant]["counts"] = counted["counts"]
                item[variant]["cpu_range_ns"] = [min(r["cpu_ns"] for r in cohort), max(r["cpu_ns"] for r in cohort)]
            base, cand = item["baseline"]["cpu_ns"], item["candidate"]["cpu_ns"]
            item["cpu_median_reduction_percent"] = 100 * (1 - cand / base) if base else None
            item["paired_cpu_reduction_percent"] = []
            for pair in range(self.args.pairs):
                by_variant = {r["variant"]: r["cpu_ns"] for r in rows
                              if r["scenario"] == scenario and r["pair"] == pair and not r["instrumented"]}
                item["paired_cpu_reduction_percent"].append(
                    100 * (1 - by_variant["candidate"] / by_variant["baseline"])
                    if by_variant["baseline"] else None)
            summary.append(item)
        write_json(self.output / "summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)

    def run(self) -> None:
        try:
            if self.args.mode in ("test", "all"):
                for variant in VARIANTS:
                    self.test(variant)
            if self.args.mode in ("benchmark", "all"):
                binaries = {(variant, counted): self.build(variant, counted)
                            for variant in VARIANTS for counted in (False, True)}
                checks = {}
                for variant in VARIANTS:
                    checks[variant] = json.loads(self.command(
                        [str(binaries[variant, True]), "--check"], timeout=60))
                    if checks[variant].get("passed") is not True:
                        raise RuntimeError(f"Instrumented qualification failed: {variant}")
                if checks["baseline"]["receipt"] != checks["candidate"]["receipt"]:
                    raise RuntimeError("Instrumented qualification receipts differ")
                if any(item["counts"]["broadcasts"] != 0
                       for item in checks["candidate"]["observations"]):
                    raise RuntimeError("Candidate readers generated their own wakeups")
                write_json(self.output / "qualification.json", checks)
                self.measure(binaries)
            write_json(self.output / "completion.json", {"passed": True, "mode": self.args.mode})
        finally:
            self.manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
            write_json(self.output / "manifest.json", self.manifest)
            write_json(self.output / "commands.json", self.commands)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("all", "test", "benchmark"), nargs="?", default="all")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--updates", type=int, default=240)
    parser.add_argument("--interval-us", type=int, default=8333)
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    args = parser.parse_args()
    if (args.pairs < 2 or args.pairs % 2 or args.updates < 1
            or not 1 <= args.interval_us <= 100_000
            or len(set(args.scenarios)) != len(args.scenarios)):
        parser.error("even pairs >= 2, positive updates, interval-us in 1...100000, and unique scenarios required")
    Runner(args).run()


if __name__ == "__main__":
    main()
