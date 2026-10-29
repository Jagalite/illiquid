#!/usr/bin/env python3
"""Exact-source ring-buffer and complete bounded-queue performance research."""
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
RING = "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift"
QUEUE = "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift"
TESTS = ["FixedRingBufferWrapTests.swift", "PacketQueueWakeupTests.swift"]
CASES = (
    [("ring-fifo-int", n) for n in (12, 48, 64, 96, 192)]
    + [("ring-prepend-int", 12), ("ring-prepend-int", 96),
       ("ring-burst-int", 96), ("ring-burst-int", 192), ("ring-fifo-ref", 96)]
    + [("queue-fifo-int", n) for n in (12, 48, 64, 96, 192)]
    + [("queue-prepend-int", 96), ("queue-burst-int", 96),
       ("queue-fifo-ref", 96), ("queue-fifo-ref", 192), ("checksum", 96)]
)

def digest(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()

class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.work = self.output / "work"
        self.work.mkdir()
        self.commands, self.observations, self.calibrations = [], [], []
        self.binaries, self.manifest = {}, {}
        self.env = os.environ.copy()
        # Each driver must load its own variant, independent of a caller's
        # injected library search paths. Record the resolved dependencies too.
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH",
                     "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"):
            self.env.pop(name, None)

    def write(self, name, value):
        (self.output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, args, *, log=None, timeout=600):
        args = [str(x) for x in args]
        start = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        self.commands.append({"argv": args, "exit_code": result.returncode,
            "seconds": time.monotonic() - start,
            "stdout_sha256": digest(result.stdout), "stderr_sha256": digest(result.stderr)})
        self.write("commands.json", self.commands)
        if log: (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {args}\n{result.stdout[-5000:]}\n{result.stderr[-7000:]}")
        return result.stdout

    def prepare(self):
        self.darwin = platform.system() == "Darwin"
        if platform.system() not in ("Darwin", "Linux"):
            raise RuntimeError("This harness supports macOS and Linux")
        self.swiftc = (self.command(["xcrun", "--find", "swiftc"]).strip()
                       if self.darwin else shutil.which("swiftc"))
        self.swift = (self.command(["xcrun", "--find", "swift"]).strip()
                      if self.darwin else shutil.which("swift"))
        if not self.swiftc or not self.swift:
            raise RuntimeError("Swift is not installed")
        self.sdk = (self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
                    if self.darwin else None)
        baseline = (HERE / "baseline/FixedRingBuffer.swift").read_bytes()
        if self.command(["git", "show", f"{BASELINE}:{RING}"]).encode() != baseline:
            raise RuntimeError("Frozen baseline does not match its pinned Git commit")
        self.manifest = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree_status": self.command(["git", "status", "--short"]),
            "platform": platform.platform(), "architecture": platform.machine(),
            "swift": self.command([self.swiftc, "--version"]).strip(),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"] if self.darwin else ["lscpu"]).strip(),
            "run_url": (f"https://github.com/{os.environ.get('GITHUB_REPOSITORY')}/actions/runs/"
                        f"{os.environ.get('GITHUB_RUN_ID')}" if os.environ.get("GITHUB_RUN_ID") else None),
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
            "source_sha256": {
                "baseline_ring": digest(baseline), "candidate_ring": digest((ROOT / RING).read_bytes()),
                QUEUE: digest((ROOT / QUEUE).read_bytes()),
                "Bridge.swift": digest((HERE / "Bridge.swift").read_bytes()),
                "Driver.swift": digest((HERE / "Driver.swift").read_bytes()),
                "run.py": digest(Path(__file__).read_bytes()),
                **{name: digest((ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes()) for name in TESTS},
            },
            "scope": "Ring and uncontended BoundedQueue; no decoder, renderer or end-to-end playback claim.",
            "binaries": {},
        }
        self.write("manifest.json", self.manifest)
        for variant in ("baseline", "candidate"):
            for configuration in ("debug", "release"):
                self.build(variant, configuration)

    def build(self, variant, configuration):
        directory = self.work / variant / configuration
        directory.mkdir(parents=True)
        ring = HERE / "baseline/FixedRingBuffer.swift" if variant == "baseline" else ROOT / RING
        for path in (ring, ROOT / QUEUE, HERE / "Bridge.swift", HERE / "Driver.swift"):
            shutil.copyfile(path, directory / path.name)
        flags = ["-Onone", "-g"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
        flags += ["-swift-version", "6", "-warnings-as-errors", "-module-cache-path", self.work / "module-cache"]
        if self.darwin:
            flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", self.sdk]
        suffix = "dylib" if self.darwin else "so"
        library = directory / f"libIlliquidNativePlayback.{suffix}"
        library_flags = ["-Xlinker", "-install_name", "-Xlinker", library] if self.darwin else []
        self.command([self.swiftc, *flags, "-enable-testing", "-emit-library", "-emit-module",
            "-module-name", "IlliquidNativePlayback", "-emit-module-path", directory / "IlliquidNativePlayback.swiftmodule",
            *library_flags, directory / "FixedRingBuffer.swift", directory / "PacketQueue.swift",
            directory / "Bridge.swift", "-o", library], log=f"build-{variant}-{configuration}-library.log")
        binary = directory / "driver"
        self.command([self.swiftc, *flags, "-parse-as-library", "-I", directory, "-L", directory,
            "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", directory,
            directory / "Driver.swift", "-o", binary], log=f"build-{variant}-{configuration}-driver.log")
        dependencies = self.command(["otool", "-L", binary] if self.darwin else ["ldd", binary],
                                    log=f"dependencies-{variant}-{configuration}.log")
        if str(library) not in dependencies:
            raise RuntimeError(f"Driver does not resolve its own variant library: {dependencies}")
        self.binaries[variant, configuration] = binary
        self.manifest["binaries"][f"{variant}-{configuration}"] = {
            "driver_sha256": digest(binary.read_bytes()), "library_sha256": digest(library.read_bytes()),
            "flags": [str(x) for x in flags], "library_resolution": dependencies}
        self.write("manifest.json", self.manifest)
        print(f"Built {variant} {configuration}", flush=True)

    def invoke(self, variant, configuration, *args):
        return json.loads(self.command([self.binaries[variant, configuration], *args], timeout=180))

    def verify(self):
        reference = None
        comparisons = []
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                trace = self.invoke(variant, configuration, "verify")
                self.write(f"trace-{variant}-{configuration}.json", trace)
                if reference is not None and trace != reference:
                    raise RuntimeError(f"Complete differential trace mismatch: {variant}/{configuration}")
                reference = trace
                comparisons.append({"variant": variant, "configuration": configuration,
                    "cases": len(trace), "values": sum(len(v) for v in trace.values()),
                    "sha256": digest(json.dumps(trace, sort_keys=True))})
        self.write("parity.json", {"equal": True, "comparisons": comparisons})
        print("Exact ring/queue traces match in all four builds", flush=True)

    def test(self):
        receipts = []
        for variant in ("baseline", "candidate"):
            package = self.work / f"tests-{variant}"
            sources = package / "Sources/IlliquidNativePlayback"
            tests = package / "Tests/IlliquidNativePlaybackTests"
            sources.mkdir(parents=True)
            tests.mkdir(parents=True)
            for name in ("FixedRingBuffer.swift", "PacketQueue.swift"):
                shutil.copyfile(self.work / variant / "debug" / name, sources / name)
            for name in TESTS:
                shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / name, tests / name)
            (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "FixedRingBufferRegressionTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
""")
            for configuration in ("debug", "release"):
                log = f"tests-{variant}-{configuration}.log"
                # Preserve the repository test warning policy: newer Swift versions
                # warn about legacy weak-var declarations in the unchanged suite.
                # The production-source driver builds above still reject warnings.
                self.command([self.swift, "test", "--package-path", package, "--jobs", "2",
                    "--no-parallel", "-c", configuration], log=log)
                receipts.append({"variant": variant, "configuration": configuration, "passed": True,
                                 "log_sha256": digest((self.output / log).read_bytes())})
                print(f"Tests passed: {variant} {configuration}", flush=True)
        self.write("tests.json", receipts)

    def measurement(self, variant, workload, capacity, count, seed):
        value = self.invoke(variant, "release", "measure", workload, str(capacity), str(count), str(seed))
        if (value["workload"], value["capacity"], value["iterations"], value["seed"]) != (workload, capacity, count, seed):
            raise RuntimeError("Driver command/receipt mismatch")
        operations = count * capacity if "burst" in workload else count
        if value["operations"] != operations or min(value["wall_ns"], value["cpu_ns"]) <= 0:
            raise RuntimeError("Invalid operation count or timing")
        return {"variant": variant, "case": f"{workload}-{capacity}", **value}

    def measure(self):
        summary = {}
        for workload, capacity in CASES:
            count = 2048
            for attempt in range(5):
                probes = [self.measurement(variant, workload, capacity, count, 7)
                          for variant in ("baseline", "candidate")]
                self.calibrations.extend({"attempt": attempt, **p} for p in probes)
                self.write("calibration.json", self.calibrations)
                minimum = min(p["wall_ns"] for p in probes)
                if minimum >= self.args.target_ms * 1_000_000: break
                count = max(count + 1, math.ceil(count * self.args.target_ms * 1_000_000 / minimum * 1.1))
            else:
                raise RuntimeError(f"Calibration failed: {workload}/{capacity}")
            pairs = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                values = {}
                for variant in order:
                    value = self.measurement(variant, workload, capacity, count, 100 + pair)
                    value.update(pair=pair, order=list(order))
                    self.observations.append(value)
                    self.write("observations.json", self.observations)
                    values[variant] = value
                for field in ("checksum", "tail_checksum", "final_count", "operations", "iterations", "seed"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise RuntimeError(f"Timed receipt mismatch: {workload}/{capacity}/{pair}/{field}")
                pairs.append(values)
            metrics = {}
            for metric in ("wall_ns", "cpu_ns"):
                medians = {variant: statistics.median(p[variant][metric] / p[variant]["operations"] for p in pairs)
                           for variant in ("baseline", "candidate")}
                changes = [100 * (1 - p["candidate"][metric] / p["baseline"][metric]) for p in pairs]
                metrics[metric] = {
                    "baseline_ns_per_operation": medians["baseline"],
                    "candidate_ns_per_operation": medians["candidate"],
                    "median_reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                    "paired_reduction_percent": changes,
                    "median_paired_reduction_percent": statistics.median(changes),
                    "candidate_faster_pairs": sum(v > 0 for v in changes),
                }
            key = f"{workload}-{capacity}"
            summary[key] = {"pairs": len(pairs), "iterations": count, **metrics}
            self.write("summary.json", summary)
            print(key, json.dumps(summary[key]), flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=int, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 100:
        parser.error("Use an even number of pairs >= 2 and target-ms >= 100")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.verify()
        runner.test()
        if not args.tests_only: runner.measure()
        runner.write("completion.json", {
            "complete": True, "tests_only": args.tests_only,
            "candidate_revision": runner.manifest["candidate_revision"],
            "candidate_ring_sha256": runner.manifest["source_sha256"]["candidate_ring"],
            "cases": [] if args.tests_only else CASES,
            "observations": len(runner.observations),
            "minimum_observed_wall_ns": min((r["wall_ns"] for r in runner.observations), default=None),
            "observations_under_target": [
                {"case": r["case"], "pair": r["pair"], "variant": r["variant"], "wall_ns": r["wall_ns"]}
                for r in runner.observations if r["wall_ns"] < args.target_ms * 1_000_000
            ],
        })
    except Exception as error:
        runner.write("failure.json", {"error": str(error)})
        raise

if __name__ == "__main__":
    main()
