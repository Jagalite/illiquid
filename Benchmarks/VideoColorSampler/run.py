#!/usr/bin/env python3
"""Qualify and measure the actual VideoFrameColorSampler on native macOS."""
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
TARGET = "Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift"
SOURCES = [
    "Sources/IlliquidCore/Player/VideoColorSample.swift",
    "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift",
    TARGET,
]
TESTS = [
    "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerTests.swift",
    "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerLayoutTests.swift",
    "Tests/IlliquidNativePlaybackTests/PiPVideoMappingTests.swift",
]
CASES = [
    "bgra_tiny", "bgra_1080p", "nv12_video_1080p", "nv12_full_1080p",
    "p010_video_2160p", "p010_full_2160p", "mixed_padded",
    "cadence_60fps", "throttled",
]
VARIANTS = ["baseline", "candidate"]
MANIFEST = """// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "VideoColorSamplerResearch",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ColorSamplerBenchmark", targets: ["ColorSamplerBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "ColorSamplerBenchmark",
                          dependencies: ["IlliquidCore", "IlliquidNativePlayback"]),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidCore", "IlliquidNativePlayback"]),
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
        self.commands = []
        self.binaries = {}
        self.receipts = {}
        self.cases = {}
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
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "seconds": time.monotonic() - start,
                              "stdout_sha256": sha(result.stdout),
                              "stderr_sha256": sha(result.stderr), "log": log})
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-8000:]}\n{result.stderr[-16000:]}")
        return result.stdout + result.stderr if log else result.stdout

    def swift_command(self, variant, operation, configuration):
        command = [self.swift, operation, "--package-path", self.output / variant,
                   "--configuration", configuration, "--jobs", "2",
                   "--cache-path", self.output / "cache",
                   "--config-path", self.output / "config",
                   "--security-path", self.output / "security"]
        if operation == "test":
            command += ["--no-parallel"]
        return command

    def prepare(self):
        if platform.system() != "Darwin":
            raise RuntimeError("Native CoreVideo is required; no substitute implementation is measured")
        baseline = self.command(["git", "rev-parse", f"{self.args.baseline}^{{commit}}"]).strip()
        self.manifest = {
            "schema": 1, "baseline_commit": baseline,
            "candidate_commit": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_status": self.command(["git", "status", "--porcelain=v1"]).splitlines(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "architecture": platform.machine(),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "hardware_model": self.command(["sysctl", "-n", "hw.model"]).strip(),
            "logical_cpus": os.cpu_count(),
            "macos": self.command(["sw_vers"]).strip(),
            "swift": self.command([self.swift, "--version"]).strip(),
            "sdk": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "runner": {key: os.environ.get(key) for key in
                       ["GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "RUNNER_ARCH", "RUNNER_OS"]},
            "method": "exact full production sources; separate module; optimized release; fresh AB/BA processes",
            "pairs": self.args.pairs, "target_ms": self.args.target_ms, "cases": CASES,
            "scope": "CPU and wall time per sampler invocation including lock/unlock, output consumption and autoreleasepool",
            "limitations": [
                "Synthetic IOSurface-backed buffers are allocated and filled outside timing.",
                "Each process warms 1024 calls; these are warm component measurements.",
                "No live playback, FPS, power, memory-footprint or whole-player latency claim.",
                "The default accepted sampling cadence is at most 4 Hz.",
                "The isolated package uses toolchain Testing, not the full application dependency graph.",
                "Bootstrap intervals describe these paired process observations, not all devices.",
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

            for path in SOURCES:
                module = "IlliquidCore" if path.startswith("Sources/IlliquidCore/") else "IlliquidNativePlayback"
                stage(path, f"Sources/{module}/{Path(path).name}", production=True)
            for path in TESTS:
                stage(path, "Tests/IlliquidNativePlaybackTests/" + Path(path).name)
            stage("Benchmarks/VideoColorSampler/Harness.swift", "Sources/ColorSamplerBenchmark/Harness.swift")
            (package / "Package.swift").write_text(MANIFEST)
            self.manifest["sources"][variant] = receipts
            self.receipts[variant] = receipts

        before, after = (self.receipts[v] for v in VARIANTS)
        differences = [path for path in before if before[path]["sha256"] != after[path]["sha256"]]
        if differences != [TARGET]:
            raise ValueError(f"The only differing staged source must be {TARGET}: {differences}")
        self.save("manifest.json", self.manifest)
        self.verification = {"exact_bit_pattern_parity": True, "comparisons": [], "tests": []}
        for variant in VARIANTS:
            for configuration in ["debug", "release"]:
                print(f"Test {variant} {configuration}", flush=True)
                log = f"tests-{variant}-{configuration}.log"
                output = self.command(self.swift_command(variant, "test", configuration), log=log)
                counts = re.findall(r"Test run with (\d+) tests?.*passed", output)
                if not counts or int(counts[-1]) != 13:
                    raise ValueError(f"Expected 13 executed Swift Testing tests: {log}")
                self.verification["tests"].append({
                    "variant": variant, "configuration": configuration, "passed": True,
                    "tests": int(counts[-1]), "log": log, "sha256": sha((self.output / log).read_bytes()),
                })
                self.save("verification.json", self.verification)
                print(f"Build {variant} {configuration}", flush=True)
                self.command([*self.swift_command(variant, "build", configuration),
                              "--product", "ColorSamplerBenchmark"],
                             log=f"build-{variant}-{configuration}.log")
                folder = self.command([*self.swift_command(variant, "build", configuration),
                                       "--show-bin-path"]).strip()
                self.binaries[(variant, configuration)] = Path(folder) / "ColorSamplerBenchmark"
        self.manifest["binaries"] = {
            f"{variant}-{configuration}": {"sha256": sha(binary.read_bytes()),
                                           "bytes": binary.stat().st_size}
            for (variant, configuration), binary in self.binaries.items()
        }
        self.save("manifest.json", self.manifest)

    def verify(self):
        reference = None
        (self.output / "traces").mkdir()
        for variant in VARIANTS:
            for configuration in ["debug", "release"]:
                output = self.command([self.binaries[(variant, configuration)], "verify"])
                trace = json.loads(output)
                if len(trace["traces"]) != 184 or len(trace["layouts"]) != 45:
                    raise ValueError("Incomplete verification corpus")
                data = canonical(trace).encode()
                if reference is not None and data != reference:
                    raise ValueError(f"Exact complete output parity failed: {variant}/{configuration}")
                reference = data
                compressed = gzip.compress(data, compresslevel=9, mtime=0)
                name = f"traces/{variant}-{configuration}.json.gz"
                (self.output / name).write_bytes(compressed)
                self.verification["comparisons"].append({
                    "variant": variant, "configuration": configuration, "traces": len(trace["traces"]),
                    "layouts": len(trace["layouts"]), "sha256": sha(data),
                    "gzip_sha256": sha(compressed), "artifact": name,
                })
                print(f"Exact parity: {variant}/{configuration}, {len(trace['traces'])} traces", flush=True)
        self.save("verification.json", self.verification)

    def invoke(self, variant, workload, iterations):
        row = json.loads(self.command([self.binaries[(variant, "release")],
                                       "measure", workload, iterations]))
        if row["workload"] != workload or row["iterations"] != iterations:
            raise ValueError("Wrong workload or iteration count")
        layouts = row.pop("layouts")
        if workload in self.cases and self.cases[workload] != layouts:
            raise ValueError(f"Different fixture layouts: {workload}")
        self.cases[workload] = layouts
        row["layout_sha256"] = sha(canonical(layouts))
        return row

    @staticmethod
    def check_pair(samples):
        left, right = (samples[variant] for variant in VARIANTS)
        for name in ["workload", "iterations", "layout_sha256"]:
            if left[name] != right[name]:
                raise ValueError(f"Measured pair differs: {name}")
        for section in ["warmup", "measured"]:
            for name in ["checksum", "published"]:
                if left[section][name] != right[section][name]:
                    raise ValueError(f"Timed output differs: {section}/{name}")

    def measure(self):
        observations, calibrations, summaries = [], [], []
        for workload in CASES:
            print("Calibrate " + workload, flush=True)
            pilots = {variant: [self.invoke(variant, workload, 4096) for _ in range(2)]
                      for variant in VARIANTS}
            for index in range(2):
                self.check_pair({variant: pilots[variant][index] for variant in VARIANTS})
            fastest = min(row["measured"]["elapsedNanoseconds"] / row["iterations"]
                          for rows in pilots.values() for row in rows)
            requested = math.ceil(self.args.target_ms * 1_000_000 * 1.3 / fastest)
            iterations = max(4096, math.ceil(requested / 256) * 256)
            if iterations > 20_000_000:
                raise ValueError("Calibration exceeded the documented iteration bound")
            calibrations.append({"workload": workload, "pilots": pilots, "iterations": iterations,
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
                self.check_pair(samples)
            summary = {"workload": workload, "iterations": iterations, "pairs": self.args.pairs}
            for metric in ["elapsedNanoseconds", "cpuNanoseconds"]:
                values = {variant: [row["measured"][metric] / iterations for row in rows
                                    if row["variant"] == variant] for variant in VARIANTS}
                medians = {variant: statistics.median(value) for variant, value in values.items()}
                paired = [(values["candidate"][index] / values["baseline"][index] - 1) * 100
                          for index in range(self.args.pairs)]
                summary[metric] = {
                    "median_ns_per_call": medians,
                    "range_ns_per_call": {variant: [min(value), max(value)]
                                          for variant, value in values.items()},
                    "change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                    "saving_ns_per_call": medians["baseline"] - medians["candidate"],
                    "paired_change_percent": paired,
                    "median_paired_change_percent": statistics.median(paired),
                    "paired_median_bootstrap_95_percent_interval": bootstrap_interval(paired),
                }
            summary["observations_below_target"] = [
                {"variant": row["variant"], "pair": row["pair"],
                 "milliseconds": row["measured"]["elapsedNanoseconds"] / 1_000_000}
                for row in rows if row["measured"]["elapsedNanoseconds"] < self.args.target_ms * 1_000_000
            ]
            summaries.append(summary)
            wall = summary["elapsedNanoseconds"]
            print(f"{workload}: {wall['median_ns_per_call']['baseline']:.1f} -> "
                  f"{wall['median_ns_per_call']['candidate']:.1f} ns/call "
                  f"({wall['change_percent']:+.2f}%)", flush=True)
            self.save("summary.json", summaries)
            self.save("cases.json", self.cases)
        return {"observations": len(observations),
                "all_observations_met_target": all(not row["observations_below_target"] for row in summaries)}

    def finish(self, measurements):
        for variant in VARIANTS:
            for relative, receipt in self.receipts[variant].items():
                staged = self.output / variant / receipt["destination"]
                if sha(staged.read_bytes()) != receipt["sha256"]:
                    raise ValueError("Staged source changed during execution")
                if receipt["source"] == "current worktree" and sha((ROOT / relative).read_bytes()) != receipt["sha256"]:
                    raise ValueError("Worktree source changed during execution")
        for (variant, configuration), binary in self.binaries.items():
            if sha(binary.read_bytes()) != self.manifest["binaries"][f"{variant}-{configuration}"]["sha256"]:
                raise ValueError("Measured binary changed during execution")
        if sha(Path(__file__).read_bytes()) != self.manifest["runner_sha256"]:
            raise ValueError("Runner changed during execution")
        self.verification["sources_and_binaries_unchanged"] = True
        self.verification["complete"] = True
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
        parser.error("Use an even number of pairs >= 2 and a positive finite target-ms")
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
