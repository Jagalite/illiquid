#!/usr/bin/env python3
"""Native component regressions and paired timings for thumbnail neighbor planning."""
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
TESTS = "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
]
WORKLOADS = [(0, "nil"), (1, "first")]
WORKLOADS += [(n, case) for n in [32, 10_000, 100_000]
              for case in ["first", "middle", "last", "missing", "nil"]]
WORKLOADS += [(1_000, case) for case in ["middle", "last"]]


def digest(value):
    if isinstance(value, str):
        value = value.encode()
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def emit(kind, value):
    print(kind + "_JSON " + canonical(value), flush=True)


def baseline_helper(source):
    # Extract the two actual blocks from the pinned scheduler. Only the input
    # expression and enclosing function/type are adapted for this component probe.
    start = "        let playlist = player.viewStore.playlist.map(\\.url)\n"
    boundary = "        var urls = current.map { [$0] } ?? []\n"
    distance_start = "        var distances: [URL: Int] = [:]\n"
    end = "        let candidates = urls.map { url in\n"
    for marker in [start, boundary, distance_start, end]:
        if source.count(marker) != 1:
            raise RuntimeError("Baseline extraction boundary changed: " + marker.strip())
    first = source[source.index(start):source.index(boundary)]
    second = source[source.index(distance_start):source.index(end)]
    first = first.replace("player.viewStore.playlist", "items", 1)
    return (
        "import Foundation\nimport IlliquidCore\n\n"
        "struct ThumbnailPlaylistNeighborhood {\n"
        "    let urls: [URL]\n    let distances: [URL: Int]\n"
        "    init(playlist items: [FolderPlaylistItem], current: URL?) {\n"
        + first + second
        + "        self.urls = neighbors\n        self.distances = distances\n    }\n}\n"
    )


class Runner:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise RuntimeError("Output directory must be new or empty")
        self.out.mkdir(parents=True, exist_ok=True)
        for directory in ["logs", "sources", "binaries"]:
            (self.out / directory).mkdir()
        self.commands = []
        self.tests = []
        self.calibrations = []
        self.samples = []
        self.summaries = []
        self.binaries = {}
        self.swift = shutil.which("swift")
        self.swiftc = shutil.which("swiftc")
        if not self.swift or not self.swiftc or platform.system() != "Darwin":
            raise RuntimeError("A native macOS Swift toolchain is required")

    def write(self, name, value):
        (self.out / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, argv, name):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        completed = subprocess.run(argv, cwd=ROOT, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=900)
        log = self.out / "logs" / f"{len(self.commands):04d}-{name}.log"
        log.write_text(completed.stdout)
        self.commands.append({"argv": argv, "returncode": completed.returncode,
                              "seconds": time.monotonic() - started,
                              "log": str(log.relative_to(self.out)),
                              "log_sha256": digest(completed.stdout)})
        self.write("commands.json", self.commands)
        if completed.returncode:
            raise RuntimeError(f"{name} failed:\n{completed.stdout[-12000:]}")
        return completed.stdout

    def prepare(self):
        baseline_source = self.command(["git", "show", f"{BASELINE}:{SCHEDULER}"], "baseline")
        (self.out / "sources" / "baseline-scheduler.swift").write_text(baseline_source)
        variants = {"baseline": baseline_helper(baseline_source),
                    "candidate": (ROOT / HELPER).read_text()}
        source_receipts = []
        for path in [*CORE, HELPER, SCHEDULER, TESTS]:
            data = (ROOT / path).read_bytes()
            destination = self.out / "sources" / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            source_receipts.append({"path": path, "sha256": digest(data)})
        for name in ["Harness.swift", "Probe.swift", "run.py"]:
            shutil.copyfile(HERE / name, self.out / "sources" / name)
        self.manifest = {
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "working_tree_status": self.command(["git", "status", "--short"], "status").strip(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "macos": self.command(["sw_vers"], "macos").strip(),
            "swift": self.command([self.swiftc, "--version"], "swift").strip(),
            "xcode": self.command(["xcodebuild", "-version"], "xcode").strip(),
            "sdk": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk").strip(),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip(),
            "architecture": platform.machine(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "pairs": self.args.pairs, "target_ms": self.args.target_ms,
            "source_receipts": source_receipts,
            "baseline_scheduler_sha256": digest(baseline_source),
            "baseline_adapted_helper_sha256": digest(variants["baseline"]),
            "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
            "probe_sha256": digest((HERE / "Probe.swift").read_bytes()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "timing_scope": "neighbor extraction plus result witness and autorelease-pool cleanup",
            "process_policy": "fresh process per observation; alternating AB/BA pairs",
            "iteration_policy": "calibrated separately per variant, then fixed for all retained pairs",
            "memory_scope": "no RSS/allocation-counter claim; URL stride and eliminated full projection are structural",
        }
        self.write("manifest.json", self.manifest)
        emit("MANIFEST", self.manifest)

        package_text = (
            "// swift-tools-version: 6.1\nimport PackageDescription\n"
            'let package = Package(name: "ThumbnailNeighborhoodQualification", '
            'platforms: [.macOS("26.0")], targets: ['
            '.target(name: "IlliquidCore"), '
            '.target(name: "IlliquidApp", dependencies: ["IlliquidCore"]), '
            '.testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"])])\n'
        )
        for variant, helper in variants.items():
            package = self.out / variant / "package"
            for target in ["Sources/IlliquidCore", "Sources/IlliquidApp", "Tests/IlliquidAppTests"]:
                (package / target).mkdir(parents=True, exist_ok=True)
            (package / "Package.swift").write_text(package_text)
            for path in CORE:
                shutil.copyfile(ROOT / path, package / "Sources/IlliquidCore" / Path(path).name)
            (package / "Sources/IlliquidApp/ThumbnailPlaylistNeighborhood.swift").write_text(helper)
            shutil.copyfile(ROOT / TESTS, package / "Tests/IlliquidAppTests" / Path(TESTS).name)
            (self.out / "sources" / f"{variant}-helper.swift").write_text(helper)
            for configuration in ["debug", "release"]:
                stdout = self.command([self.swift, "test", "--package-path", package,
                    "--jobs", "2", "--no-parallel", "-c", configuration], f"tests-{variant}-{configuration}")
                counts = re.findall(r"Test run with (\d+) tests.*passed", stdout)
                if not counts or int(counts[-1]) < 6:
                    raise RuntimeError("Expected all six Swift Testing functions to execute")
                result = {"variant": variant, "configuration": configuration,
                          "test_functions_passed": int(counts[-1]), "passed": True}
                self.tests.append(result)
                emit("TEST", result)
        self.write("tests.json", self.tests)

        common = self.out / "binaries" / "common"
        common.mkdir()
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6",
                 "-target", f"{platform.machine()}-apple-macos26.0",
                 "-module-cache-path", self.out / "module-cache"]
        self.command([self.swiftc, *flags, "-emit-library", "-emit-module",
            "-module-name", "IlliquidCore", "-emit-module-path", common / "IlliquidCore.swiftmodule",
            *[ROOT / path for path in CORE], "-o", common / "libIlliquidCore.dylib"], "compile-core")
        for variant in variants:
            build = self.out / "binaries" / variant
            build.mkdir()
            helper = self.out / "sources" / f"{variant}-helper.swift"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module",
                "-module-name", "NeighborhoodProbe", "-emit-module-path", build / "NeighborhoodProbe.swiftmodule",
                "-I", common, "-L", common, "-lIlliquidCore",
                helper, HERE / "Probe.swift", "-o", build / "libNeighborhoodProbe.dylib",
                "-Xlinker", "-rpath", "-Xlinker", common], f"compile-probe-{variant}")
            binary = build / "harness"
            self.command([self.swiftc, *flags, "-parse-as-library",
                "-I", common, "-I", build, "-L", common, "-L", build,
                "-lIlliquidCore", "-lNeighborhoodProbe", HERE / "Harness.swift", "-o", binary,
                "-Xlinker", "-rpath", "-Xlinker", common,
                "-Xlinker", "-rpath", "-Xlinker", build], f"compile-driver-{variant}")
            self.binaries[variant] = binary
        self.manifest["binary_sha256"] = {
            variant: {"harness": digest(binary.read_bytes()),
                      "probe": digest((binary.parent / "libNeighborhoodProbe.dylib").read_bytes())}
            for variant, binary in self.binaries.items()
        }
        self.manifest["core_binary_sha256"] = digest((common / "libIlliquidCore.dylib").read_bytes())
        self.write("manifest.json", self.manifest)
        emit("MANIFEST", self.manifest)

    def invoke(self, variant, *args):
        return json.loads(self.command([self.binaries[variant], *args], f"run-{variant}-{args[0]}"))

    def verify(self):
        outputs = {variant: self.invoke(variant, "verify") for variant in self.binaries}
        if outputs["baseline"] != outputs["candidate"]:
            raise RuntimeError("Complete baseline/candidate output parity failed")
        self.parity = {"equal": True, "cases": len(outputs["candidate"]["rows"]),
                       "trace_sha256": digest(canonical(outputs["candidate"])),
                       "url_stride": outputs["candidate"]["urlStride"]}
        self.write("verification.json", outputs)
        self.write("parity.json", self.parity)
        emit("PARITY", self.parity)

    def compact(self, row):
        row = dict(row)
        output = row.pop("result")
        row["result_sha256"] = digest(canonical(output))
        row["result_url_count"] = len(output["urls"])
        return row

    def calibrate(self, variant, count, scenario):
        iterations = 1
        while True:
            row = self.invoke(variant, "measure", count, scenario, iterations)
            sample = {"variant": variant, **self.compact(row)}
            self.calibrations.append(sample)
            emit("CALIBRATION", sample)
            if row["elapsedNanoseconds"] >= 2_000_000 or iterations >= 1_000_000:
                estimate = math.ceil(self.args.target_ms * 1_000_000 * iterations
                                     / max(1, row["elapsedNanoseconds"]))
                return max(1, min(1_000_000, estimate))
            iterations = min(1_000_000, max(iterations + 1, iterations * 10))

    def measure(self):
        for count, scenario in WORKLOADS:
            iterations = {variant: self.calibrate(variant, count, scenario)
                          for variant in ["baseline", "candidate"]}
            rows = []
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                paired = {}
                for position, variant in enumerate(order):
                    row = self.invoke(variant, "measure", count, scenario, iterations[variant])
                    row = {"variant": variant, "pair": pair, "process_order": position,
                           **self.compact(row)}
                    paired[variant] = row
                    rows.append(row)
                    self.samples.append(row)
                    emit("SAMPLE", row)
                    with (self.out / "measurements.jsonl").open("a") as stream:
                        stream.write(canonical(row) + "\n")
                for field in ["result_sha256", "witness", "urlStride"]:
                    if paired["baseline"][field] != paired["candidate"][field]:
                        raise RuntimeError(f"Timed output mismatch: {count}/{scenario}/{field}")
            summary = {"input_count": count, "scenario": scenario, "pairs": self.args.pairs,
                       "iterations": iterations, "url_stride": rows[0]["urlStride"],
                       "result_url_count": rows[0]["result_url_count"]}
            for metric in ["elapsedNanoseconds", "cpuNanoseconds"]:
                values = {v: [r[metric] / r["iterations"] for r in rows if r["variant"] == v]
                          for v in ["baseline", "candidate"]}
                medians = {v: statistics.median(samples) for v, samples in values.items()}
                reductions = [100 * (1 - c / b) for b, c in
                              zip(values["baseline"], values["candidate"]) if b > 0]
                summary[metric] = {
                    "median_ns_per_call": medians,
                    "range_ns_per_call": {v: [min(samples), max(samples)] for v, samples in values.items()},
                    "reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"])
                        if medians["baseline"] > 0 else None,
                    "median_paired_reduction_percent": statistics.median(reductions) if reductions else None,
                    "faster_pairs": sum(c < b for b, c in zip(values["baseline"], values["candidate"])),
                }
            summary["observations_below_10ms"] = sum(
                r["elapsedNanoseconds"] < 10_000_000 for r in rows)
            self.summaries.append(summary)
            self.write("summary.json", self.summaries)
            emit("SUMMARY", summary)
        self.write("calibrations.json", self.calibrations)
        self.write("evidence.json", {"manifest": self.manifest, "tests": self.tests,
            "parity": self.parity, "calibrations": self.calibrations,
            "samples": self.samples, "summary": self.summaries, "complete": True})
        emit("COMPLETE", {"complete": True, "measured_observations": len(self.samples),
                          "workloads": len(self.summaries), "pairs": self.args.pairs})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=30)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even number of pairs >= 2 and a finite positive target-ms")
    runner = Runner(args)
    runner.prepare()
    runner.verify()
    runner.measure()


if __name__ == "__main__":
    main()
