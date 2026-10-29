#!/usr/bin/env python3
"""Measure exact production partial-order validation on portable Swift."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TARGET = "Sources/IlliquidPlaybackStateSpace/PlaybackPartialOrderReducer.swift"
TESTS = [
    "Tests/IlliquidPlaybackStateSpaceTests/PlaybackStateSpaceTests.swift",
    "Tests/IlliquidPlaybackStateSpaceTests/PlaybackDiamondReuseTests.swift",
]
CASES = ["seek_8", "eof_7", "preroll_5", "two", "one", "zero",
         "validation_disabled", "search_seek_d3", "search_preroll_d3"]
VARIANTS = ["baseline", "candidate"]
MANIFEST = """// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PORDiamondReuseResearch",
    products: [.executable(name: "DiamondBenchmark", targets: ["DiamondBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "DiamondBenchmark",
                          dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
        .testTarget(name: "IlliquidPlaybackStateSpaceTests",
                    dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
    ],
    swiftLanguageModes: [.v6]
)
"""


def sha(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def bootstrap_interval(values):
    rng = random.Random(20261028)
    estimates = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10_000))
    return [estimates[249], estimates[9749]]


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("Use a new, empty output directory")
        self.commands, self.binaries, self.receipts = [], {}, {}
        self.swift = shutil.which("swift") or "swift"

    def save(self, name, value):
        (self.output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, argv, *, log=None, timeout=900):
        argv = [str(value) for value in argv]
        env = os.environ.copy()
        env.update(CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
                   SWIFT_MODULECACHE_PATH=str(self.output / "module-cache"),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                   TERM="dumb", NO_COLOR="1")
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "seconds": time.monotonic() - started,
                              "stdout_sha256": sha(result.stdout),
                              "stderr_sha256": sha(result.stderr), "log": log})
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-8000:]}\n{result.stderr[-16000:]}")
        return result.stdout + result.stderr if log else result.stdout

    def swift_command(self, variant, operation, configuration):
        argv = [self.swift, operation, "--package-path", self.output / variant,
                "--configuration", configuration, "--jobs", "2",
                "--cache-path", self.output / "cache",
                "--config-path", self.output / "config",
                "--security-path", self.output / "security"]
        if operation == "test":
            argv += ["--no-parallel"]
        return argv

    def prepare(self):
        baseline = self.command(["git", "rev-parse", f"{self.args.baseline}^{{commit}}"]).strip()
        production_paths = ["Sources/IlliquidCore/Player/MediaTrack.swift"]
        for folder in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace"]:
            previous = sorted(path for path in self.command(
                ["git", "ls-tree", "-r", "--name-only", baseline, "--", folder]
            ).splitlines() if path.endswith(".swift"))
            current = sorted(str(path.relative_to(ROOT)) for path in (ROOT / folder).rglob("*.swift"))
            if previous != current:
                raise ValueError("Production inventory changed: " + folder)
            production_paths += current
        cpu_file = Path("/proc/cpuinfo")
        self.manifest = {
            "schema": 1, "baseline_commit": baseline,
            "candidate_commit": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_status": self.command(["git", "status", "--porcelain=v1"]).splitlines(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "architecture": platform.machine(),
            "processor": platform.processor(), "logical_cpus": os.cpu_count(),
            "cpu_description": next((line.split(":", 1)[1].strip() for line in
                                     cpu_file.read_text().splitlines() if line.startswith("model name")), "")
                               if cpu_file.is_file() else platform.processor(),
            "swift": self.command([self.swift, "--version"]).strip(),
            "runner": {key: os.environ.get(key) for key in
                       ["GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "RUNNER_ARCH", "RUNNER_OS"]},
            "method": "full exact production modules; optimized release; fresh balanced AB/BA processes",
            "pairs": self.args.pairs, "target_ms": self.args.target_ms, "cases": CASES,
            "scope": "partial-order diamond validation and bounded state-space search",
            "limitations": [
                "Portable Swift measurements on one hosted machine, not macOS application qualification.",
                "No decoding, rendering, playback FPS, UI latency, energy or RSS claim.",
                "First-step reuse retains O(n) temporary successor states for n>2 candidates.",
                "Search workloads disable wall cutoffs and retain fixed depth/state/edge bounds.",
                "The isolated package uses toolchain Testing; application dependencies are not built.",
                "Bootstrap intervals describe these paired observations, not all devices.",
            ],
            "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "package_manifest_sha256": sha(MANIFEST),
            "sources": {},
        }
        for variant in VARIANTS:
            package = self.output / variant
            package.mkdir()
            receipts = {}

            def stage(relative, destination, production=False):
                data = (self.command(["git", "show", f"{baseline}:{relative}"]).encode()
                        if production and variant == "baseline" else (ROOT / relative).read_bytes())
                target = package / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                receipts[relative] = {
                    "sha256": sha(data), "destination": destination,
                    "source": baseline if production and variant == "baseline" else "current worktree",
                    "transformation": "none",
                }

            for path in production_paths:
                module = path.split("/")[1]
                stage(path, f"Sources/{module}/{Path(path).name}", production=True)
            for path in TESTS:
                stage(path, "Tests/IlliquidPlaybackStateSpaceTests/" + Path(path).name)
            stage("Benchmarks/PORDiamondReuse/Harness.swift", "Sources/DiamondBenchmark/Harness.swift")
            (package / "Package.swift").write_text(MANIFEST)
            self.manifest["sources"][variant] = receipts
            self.receipts[variant] = receipts

        before, after = (self.receipts[v] for v in VARIANTS)
        differences = [path for path in before if before[path]["sha256"] != after[path]["sha256"]]
        if differences != [TARGET]:
            raise ValueError(f"Only {TARGET} may differ between arms: {differences}")
        self.save("manifest.json", self.manifest)
        self.verification = {"complete_output_parity": True, "comparisons": [], "tests": []}
        for variant in VARIANTS:
            for configuration in ["debug", "release"]:
                print(f"Test {variant} {configuration}", flush=True)
                log = f"tests-{variant}-{configuration}.log"
                output = self.command(self.swift_command(variant, "test", configuration), log=log)
                counts = re.findall(r"Test run with (\d+) tests?.*passed", output)
                if not counts or int(counts[-1]) != 30:
                    raise ValueError(f"Expected 30 executed Swift Testing tests: {log}")
                self.verification["tests"].append({
                    "variant": variant, "configuration": configuration, "passed": True,
                    "tests": int(counts[-1]), "log": log, "sha256": sha((self.output / log).read_bytes()),
                })
                self.save("verification.json", self.verification)
                print(f"Build {variant} {configuration}", flush=True)
                self.command([*self.swift_command(variant, "build", configuration),
                              "--product", "DiamondBenchmark"], log=f"build-{variant}-{configuration}.log")
                folder = self.command([*self.swift_command(variant, "build", configuration),
                                       "--show-bin-path"]).strip()
                self.binaries[(variant, configuration)] = Path(folder) / "DiamondBenchmark"
        self.manifest["binaries"] = {
            f"{variant}-{configuration}": {"sha256": sha(binary.read_bytes()), "bytes": binary.stat().st_size}
            for (variant, configuration), binary in self.binaries.items()
        }
        self.save("manifest.json", self.manifest)

    def verify(self):
        reference = None
        (self.output / "traces").mkdir()
        for variant in VARIANTS:
            for configuration in ["debug", "release"]:
                trace = json.loads(self.command([self.binaries[(variant, configuration)], "verify"]))
                if trace.get("schema") != 1 or not trace.get("reductions") or not trace.get("searches"):
                    raise ValueError("Incomplete semantic corpus")
                data = canonical(trace).encode()
                if reference is not None and data != reference:
                    raise ValueError(f"Complete output parity failed: {variant}/{configuration}")
                reference = data
                compressed = gzip.compress(data, compresslevel=9, mtime=0)
                name = f"traces/{variant}-{configuration}.json.gz"
                (self.output / name).write_bytes(compressed)
                self.verification["comparisons"].append({
                    "variant": variant, "configuration": configuration,
                    "reductions": len(trace["reductions"]), "searches": len(trace["searches"]),
                    "sha256": sha(data), "gzip_sha256": sha(compressed), "artifact": name,
                })
                print(f"Exact parity: {variant}/{configuration}, "
                      f"{len(trace['reductions'])} reductions, {len(trace['searches'])} searches", flush=True)
        self.save("verification.json", self.verification)

    def invoke(self, variant, workload, iterations):
        row = json.loads(self.command([self.binaries[(variant, "release")],
                                       "measure", workload, iterations]))
        if row["workload"] != workload or row["iterations"] != iterations:
            raise ValueError("Wrong workload or iteration count")
        return row

    @staticmethod
    def semantic(row):
        return {key: value for key, value in row.items()
                if key not in {"elapsedNanoseconds", "cpuNanoseconds", "warmupElapsedNanoseconds", "warmupCPUNanoseconds",
                               "variant", "pair", "order", "process_order"}}

    def measure(self):
        observations, calibrations, summaries = [], [], []
        for workload in CASES:
            print("Calibrate " + workload, flush=True)
            pilot_history = []
            pilot_iterations = 1 if workload.startswith("search_") else 8
            while True:
                pilot = {variant: self.invoke(variant, workload, pilot_iterations) for variant in VARIANTS}
                if self.semantic(pilot["baseline"]) != self.semantic(pilot["candidate"]):
                    raise ValueError("Pilot output mismatch")
                pilot_history.append({"iterations": pilot_iterations, "rows": pilot})
                fastest_ns = min(row["elapsedNanoseconds"] for row in pilot.values())
                if fastest_ns >= 20_000_000:
                    break
                pilot_iterations *= max(2, min(16, math.ceil(20_000_000 / max(1, fastest_ns))))
                if pilot_iterations > 20_000_000:
                    raise ValueError("Pilot exceeded iteration bound")
            fastest = fastest_ns / pilot_iterations
            iterations = max(1, math.ceil(self.args.target_ms * 1_000_000 * 1.3 / fastest))
            if iterations > 20_000_000:
                raise ValueError("Calibration exceeded iteration bound")
            calibrations.append({"workload": workload, "pilots": pilot_history, "iterations": iterations,
                                 "target_ms": self.args.target_ms, "margin": 1.3})
            self.save("calibration.json", calibrations)
            rows = []
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else list(reversed(VARIANTS))
                samples = {}
                for position, variant in enumerate(order):
                    row = self.invoke(variant, workload, iterations)
                    row.update(variant=variant, pair=pair, order=order, process_order=position)
                    rows.append(row)
                    observations.append(row)
                    samples[variant] = row
                    self.save("observations.json", observations)
                if self.semantic(samples["baseline"]) != self.semantic(samples["candidate"]):
                    raise ValueError(f"Timed output mismatch: {workload}/{pair}")
            summary = {"workload": workload, "iterations": iterations, "pairs": self.args.pairs}
            for metric in ["elapsedNanoseconds", "cpuNanoseconds"]:
                values = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                          for variant in VARIANTS}
                medians = {variant: statistics.median(value) for variant, value in values.items()}
                paired = [(values["candidate"][index] / values["baseline"][index] - 1) * 100
                          for index in range(self.args.pairs)]
                summary[metric] = {
                    "median_ns_per_call": medians,
                    "range_ns_per_call": {variant: [min(value), max(value)] for variant, value in values.items()},
                    "change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                    "saving_ns_per_call": medians["baseline"] - medians["candidate"],
                    "paired_change_percent": paired, "median_paired_change_percent": statistics.median(paired),
                    "paired_median_bootstrap_95_percent_interval": bootstrap_interval(paired),
                }
            summary["observations_below_target"] = [
                {"variant": row["variant"], "pair": row["pair"],
                 "milliseconds": row["elapsedNanoseconds"] / 1_000_000}
                for row in rows if row["elapsedNanoseconds"] < self.args.target_ms * 1_000_000
            ]
            summaries.append(summary)
            wall = summary["elapsedNanoseconds"]
            print(f"{workload}: {wall['median_ns_per_call']['baseline']:.1f} -> "
                  f"{wall['median_ns_per_call']['candidate']:.1f} ns/call "
                  f"({wall['change_percent']:+.2f}%)", flush=True)
            self.save("summary.json", summaries)
        return {"observations": len(observations),
                "all_observations_met_target": all(not row["observations_below_target"] for row in summaries)}

    def finish(self, measurements):
        for variant in VARIANTS:
            for relative, receipt in self.receipts[variant].items():
                if sha((self.output / variant / receipt["destination"]).read_bytes()) != receipt["sha256"]:
                    raise ValueError("Staged source changed during execution")
                if receipt["source"] == "current worktree" and sha((ROOT / relative).read_bytes()) != receipt["sha256"]:
                    raise ValueError("Worktree source changed during execution")
        for (variant, configuration), binary in self.binaries.items():
            if sha(binary.read_bytes()) != self.manifest["binaries"][f"{variant}-{configuration}"]["sha256"]:
                raise ValueError("Measured binary changed during execution")
        if sha(Path(__file__).read_bytes()) != self.manifest["runner_sha256"]:
            raise ValueError("Runner changed during execution")
        self.verification.update(sources_and_binaries_unchanged=True, complete=True)
        self.save("verification.json", self.verification)
        self.save("completion.json", {"complete": True, "tests_only": self.args.tests_only, **measurements})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >=2 and a positive finite target-ms")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.verify()
        measurements = {} if args.tests_only else runner.measure()
        runner.finish(measurements)
    except Exception as error:
        runner.save("failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        runner.save("commands.json", runner.commands)


if __name__ == "__main__":
    main()
