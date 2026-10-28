#!/usr/bin/env python3
"""Native macOS comparison of complete production video color sampling sources.

Builds production code in separate modules, compares every returned RGB bit,
runs both test suites against both variants, then measures fresh processes in
balanced AB/BA pairs. Fixture setup/verification are outside timed regions;
sampling, output consumption, and ordinary buffer locks are inside.
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
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SAMPLER = "Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift"
CORE = "Sources/IlliquidCore/Player/VideoColorSample.swift"
MAPPING = "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift"
TESTS = ["VideoFrameColorSamplerTests.swift", "VideoFrameColorSamplerLayoutTests.swift"]
CASES = [
    "bgra-1080", "nv12-video-1080", "nv12-full-1080", "p010-video-1080", "p010-full-1080",
    "bgra-4k", "nv12-video-4k", "p010-video-4k", "mixed-layouts",
    "nv12-video-iosurface", "p010-video-iosurface",
    "admitted-nv12", "steady-nv12", "throttled", "unsupported",
]


def digest(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.work = self.output / "work"
        self.work.mkdir()
        self.commands = []
        self.binaries = {}
        self.manifest = {}
        self.calibrations = []
        self.observations = []

    def write(self, name, data):
        (self.output / name).write_text(json.dumps(data, sort_keys=True, indent=2) + "\n")

    def command(self, args, *, timeout=600, log=None):
        args = [str(x) for x in args]
        start = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        self.commands.append({
            "argv": args, "exit_code": result.returncode,
            "seconds": time.monotonic() - start,
            "stdout_sha256": digest(result.stdout), "stderr_sha256": digest(result.stderr),
        })
        self.write("commands.json", self.commands)
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {args}\n{result.stdout[-4000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def prepare(self):
        if platform.system() != "Darwin":
            raise RuntimeError("Native CoreVideo requires macOS; no substitute implementation is used.")
        self.swiftc = self.command(["xcrun", "--find", "swiftc"]).strip()
        self.swift = self.command(["xcrun", "--find", "swift"]).strip()
        baseline = (HERE / "baseline/VideoFrameColorSampler.swift").read_bytes()
        if self.command(["git", "show", f"{BASELINE}:{SAMPLER}"]).encode() != baseline:
            raise RuntimeError("Frozen baseline differs from the pinned Git commit")
        self.manifest = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree_status": self.command(["git", "status", "--short"]),
            "platform": platform.platform(), "architecture": platform.machine(),
            "macos": self.command(["sw_vers"]).strip(),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "swift": self.command([self.swiftc, "--version"]).strip(),
            "sdk": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "run_url": (f"https://github.com/{os.environ.get('GITHUB_REPOSITORY')}/actions/runs/"
                        f"{os.environ.get('GITHUB_RUN_ID')}" if os.environ.get("GITHUB_RUN_ID") else None),
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
            "source_sha256": {
                "baseline_sampler": digest(baseline),
                "candidate_sampler": digest((ROOT / SAMPLER).read_bytes()),
                CORE: digest((ROOT / CORE).read_bytes()),
                MAPPING: digest((ROOT / MAPPING).read_bytes()),
                "Harness.swift": digest((HERE / "Harness.swift").read_bytes()),
                "run.py": digest(Path(__file__).read_bytes()),
                **{name: digest((ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes())
                   for name in TESTS},
            },
            "scope": "Native component; no decoding, UI, GPU presentation, FPS, memory or energy claim.",
            "binaries": {},
        }
        self.write("manifest.json", self.manifest)
        for variant in ("baseline", "candidate"):
            for configuration in ("debug", "release"):
                self.build(variant, configuration)

    def build(self, variant, configuration):
        directory = self.work / variant / configuration
        directory.mkdir(parents=True)
        source = HERE / "baseline/VideoFrameColorSampler.swift" if variant == "baseline" else ROOT / SAMPLER
        snapshots = [ROOT / CORE, ROOT / MAPPING, source, HERE / "Harness.swift"]
        for path in snapshots:
            shutil.copyfile(path, directory / path.name)
        flags = (["-Onone", "-g"] if configuration == "debug" else ["-O", "-whole-module-optimization"])
        flags += ["-swift-version", "6", "-target", f"{platform.machine()}-apple-macos26.0",
                  "-module-cache-path", self.work / "module-cache", "-warnings-as-errors"]
        for module, files, dependencies in [
            ("IlliquidCore", ["VideoColorSample.swift"], []),
            ("IlliquidNativePlayback", ["PiPVideoMapping.swift", "VideoFrameColorSampler.swift"], ["IlliquidCore"]),
        ]:
            command = [self.swiftc, *flags, "-enable-testing", "-emit-library", "-emit-module",
                       "-module-name", module, "-emit-module-path", directory / f"{module}.swiftmodule",
                       "-I", directory, "-L", directory, "-Xlinker", "-rpath", "-Xlinker", directory]
            command += [f"-l{name}" for name in dependencies]
            command += [directory / name for name in files]
            command += ["-o", directory / f"lib{module}.dylib"]
            self.command(command, log=f"build-{variant}-{configuration}-{module}.log")
        binary = directory / "sampler"
        self.command([
            self.swiftc, *flags, "-parse-as-library", "-I", directory, "-L", directory,
            "-lIlliquidCore", "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", directory,
            directory / "Harness.swift", "-o", binary,
        ], log=f"build-{variant}-{configuration}-harness.log")
        self.binaries[variant, configuration] = binary
        self.manifest["binaries"][f"{variant}-{configuration}"] = {
            "harness_sha256": digest(binary.read_bytes()),
            "core_library_sha256": digest((directory / "libIlliquidCore.dylib").read_bytes()),
            "native_library_sha256": digest((directory / "libIlliquidNativePlayback.dylib").read_bytes()),
            "flags": [str(x) for x in flags],
        }
        self.write("manifest.json", self.manifest)
        print(f"Built {variant} {configuration}", flush=True)

    def invoke(self, variant, configuration, *arguments):
        return json.loads(self.command([self.binaries[variant, configuration], *arguments], timeout=180))

    def verify(self):
        comparisons = []
        for configuration in ("debug", "release"):
            traces = {}
            for variant in ("baseline", "candidate"):
                traces[variant] = self.invoke(variant, configuration, "verify")
                self.write(f"trace-{variant}-{configuration}.json", traces[variant])
            if traces["baseline"] != traces["candidate"]:
                raise RuntimeError(f"Full RGB bit-pattern or stateful trace mismatch: {configuration}")
            comparisons.append({
                "configuration": configuration, "equal": True,
                "trace_count": traces["baseline"]["trace_count"],
                "trace_sha256": digest(json.dumps(traces["baseline"], sort_keys=True)),
            })
        self.write("parity.json", {"equal": True, "comparisons": comparisons})
        print("All complete baseline/candidate RGB and stateful traces match", flush=True)

    def test(self):
        receipts = []
        for variant in ("baseline", "candidate"):
            package = self.work / f"tests-{variant}"
            for module in ("IlliquidCore", "IlliquidNativePlayback"):
                destination = package / "Sources" / module
                destination.mkdir(parents=True)
                names = ["VideoColorSample.swift"] if module == "IlliquidCore" else [
                    "VideoFrameColorSampler.swift", "PiPVideoMapping.swift"]
                for name in names:
                    shutil.copyfile(self.work / variant / "debug" / name, destination / name)
            test_dir = package / "Tests/IlliquidNativePlaybackTests"
            test_dir.mkdir(parents=True)
            for name in TESTS:
                shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / name, test_dir / name)
            (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "VideoColorSamplerRegressionTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidCore", "IlliquidNativePlayback"]),
    ]
)
""")
            for configuration in ("debug", "release"):
                log = f"tests-{variant}-{configuration}.log"
                self.command([self.swift, "test", "--package-path", package, "--jobs", "2",
                    "--no-parallel", "-c", configuration, "-Xswiftc", "-warnings-as-errors"], log=log)
                receipts.append({"variant": variant, "configuration": configuration, "passed": True,
                                 "log_sha256": digest((self.output / log).read_bytes())})
                print(f"Tests passed: {variant} {configuration}", flush=True)
        self.write("tests.json", receipts)

    def measurement(self, variant, case, count, seed):
        value = self.invoke(variant, "release", "measure", case, str(count), str(seed))
        if value["case"] != case or value["iterations"] != count or value["seed"] != seed:
            raise RuntimeError("Driver command/receipt mismatch")
        if value["wall_ns"] <= 0 or value["cpu_ns"] <= 0:
            raise RuntimeError("Nonpositive measurement")
        return {"variant": variant, **value}

    def measure(self):
        summary = {}
        for case in CASES:
            count = 2048
            for attempt in range(5):
                probes = [self.measurement(variant, case, count, 7)
                          for variant in ("baseline", "candidate")]
                self.calibrations.extend({"attempt": attempt, **p} for p in probes)
                self.write("calibration.json", self.calibrations)
                minimum = min(p["wall_ns"] for p in probes)
                if minimum >= self.args.target_ms * 1_000_000:
                    break
                count = max(count + 1, math.ceil(count * self.args.target_ms * 1_000_000 / minimum * 1.1))
            else:
                raise RuntimeError(f"Calibration failed for {case}")
            pairs = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                values = {}
                for variant in order:
                    value = self.measurement(variant, case, count, 100 + pair)
                    value.update(pair=pair, order=list(order))
                    self.observations.append(value)
                    self.write("observations.json", self.observations)
                    values[variant] = value
                for field in ("checksum", "published", "layouts", "iterations", "seed"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise RuntimeError(f"Timed receipt mismatch: {case}/{pair}/{field}")
                pairs.append(values)
            metrics = {}
            for metric in ("wall_ns", "cpu_ns"):
                medians = {
                    variant: statistics.median(p[variant][metric] / count for p in pairs)
                    for variant in ("baseline", "candidate")
                }
                reductions = [100 * (1 - p["candidate"][metric] / p["baseline"][metric]) for p in pairs]
                metrics[metric] = {
                    "baseline_ns_per_call": medians["baseline"],
                    "candidate_ns_per_call": medians["candidate"],
                    "median_reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                    "paired_reduction_percent": reductions,
                    "median_paired_reduction_percent": statistics.median(reductions),
                    "candidate_faster_pairs": sum(v > 0 for v in reductions),
                }
            summary[case] = {"pairs": len(pairs), "iterations": count, **metrics}
            self.write("summary.json", summary)
            print(case, json.dumps(summary[case]), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=int, default=250)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 100:
        parser.error("Use an even number of pairs >= 2 and target-ms >= 100")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.verify()
        runner.test()
        if not args.tests_only:
            runner.measure()
        runner.write("completion.json", {
            "complete": True, "tests_only": args.tests_only,
            "parity": "all RGB bits and stateful outputs equal",
            "candidate_revision": runner.manifest["candidate_revision"],
            "candidate_sampler_sha256": runner.manifest["source_sha256"]["candidate_sampler"],
            "cases": [] if args.tests_only else CASES,
            "observations": len(runner.observations),
            "minimum_observed_wall_ns": min((row["wall_ns"] for row in runner.observations), default=None),
            "observations_under_target": [
                {"case": row["case"], "pair": row["pair"], "variant": row["variant"],
                 "wall_ns": row["wall_ns"]}
                for row in runner.observations if row["wall_ns"] < args.target_ms * 1_000_000
            ],
        })
    except Exception as error:
        runner.write("failure.json", {"error": str(error)})
        raise


if __name__ == "__main__":
    main()
