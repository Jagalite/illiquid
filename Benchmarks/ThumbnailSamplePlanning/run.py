#!/usr/bin/env python3
"""Compare actual production sources at a pinned baseline and the checkout."""
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE = "Sources/IlliquidCore/Player/ThumbnailPolicy.swift"
SUPPORT = ["ThumbnailPassCursor.swift", "ThumbnailVisibilityPolicy.swift"]
TESTS = ["ThumbnailPolicyTests.swift", "ThumbnailSchedulingPolicyRegressionTests.swift",
         "ThumbnailSamplePlanningTests.swift"]
CASES = ["storyboard-movie", "storyboard-clip", "background-balanced",
         "background-economical", "background-extensive", "subsecond", "short-clip",
         "full-budget-control", "one-sample", "invalid-control"]
MANIFEST = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailSamplePlanningTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
"""


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Campaign:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.env = os.environ.copy()
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(self.output / "module-cache")
        self.swift = shutil.which("swift")
        self.swiftc = shutil.which("swiftc")
        if not self.swift or not self.swiftc:
            raise RuntimeError("swift and swiftc must be on PATH")
        self.commands = []
        self.packages = {}
        self.binaries = {}

    def command(self, args, log=None):
        command = [str(arg) for arg in args]
        self.commands.append(command)
        write_json(self.output / "commands.json", self.commands)
        result = subprocess.run(command, cwd=ROOT, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if log:
            log.write_text(result.stdout)
        if result.returncode:
            print(result.stdout[-20000:], flush=True)
            raise RuntimeError(f"command failed ({result.returncode}): {command}")
        return result.stdout

    def prepare(self):
        baseline = self.command(["git", "show", f"{BASELINE}:{SOURCE}"])
        candidate = (ROOT / SOURCE).read_text()
        receipt = {
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree_status": self.command(["git", "status", "--porcelain"]),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "source_sha256": {"baseline": digest(baseline.encode()),
                              "candidate": digest(candidate.encode())},
            "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "tests_sha256": {name: digest((ROOT / "Tests/IlliquidCoreTests" / name).read_bytes())
                             for name in TESTS},
            "pairs": self.args.pairs,
            "target_ms": self.args.target_ms,
        }
        if sys.platform == "darwin":
            receipt["macos"] = self.command(["sw_vers"]).strip()
            receipt["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        write_json(self.output / "environment.json", receipt)
        print("ENVIRONMENT " + json.dumps(receipt, sort_keys=True), flush=True)
        harness = self.output / "Harness.swift"
        shutil.copyfile(HERE / "Harness.swift", harness)
        for variant, source in (("baseline", baseline), ("candidate", candidate)):
            package = self.output / (variant + "-package")
            sources = package / "Sources/IlliquidCore"
            tests = package / "Tests/IlliquidCoreTests"
            sources.mkdir(parents=True)
            tests.mkdir(parents=True)
            (package / "Package.swift").write_text(MANIFEST)
            staged = sources / "ThumbnailPolicy.swift"
            staged.write_text(source)
            for name in SUPPORT:
                path = f"Sources/IlliquidCore/Player/{name}"
                original = self.command(["git", "show", f"{BASELINE}:{path}"])
                current = (ROOT / path).read_text()
                if original != current:
                    raise RuntimeError(f"support source changed since baseline: {path}")
                (sources / name).write_text(current)
            for name in TESTS:
                shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name, tests / name)
            self.packages[variant] = package
            if self.args.mode != "tests":
                binary = self.output / (variant + "-benchmark")
                flags = ["-O", "-whole-module-optimization", "-swift-version", "6",
                         "-parse-as-library", "-module-cache-path", self.output / "module-cache"]
                self.command([self.swiftc, *flags, staged, harness, "-o", binary],
                             self.output / (variant + "-compile.log"))
                self.binaries[variant] = binary

    def test(self):
        for variant, package in self.packages.items():
            for configuration in ("debug", "release"):
                log = self.output / f"{variant}-{configuration}-tests.log"
                output = self.command([
                    self.swift, "test", "--package-path", package,
                    "--scratch-path", package / "build", "--cache-path", package / "cache",
                    "--config-path", package / "config", "--security-path", package / "security",
                    "--configuration", configuration, "--no-parallel",
                ], log)
                summary = [line for line in output.splitlines() if "Test run with" in line]
                if not summary:
                    raise RuntimeError(f"missing Swift Testing completion in {log}")
                print(f"TESTS {variant} {configuration}: {summary[-1]}", flush=True)

    def sample(self, variant, case, iterations):
        output = self.command([self.binaries[variant], case, iterations])
        row = json.loads(output)
        if row["workload"] != case or row["iterations"] != iterations:
            raise RuntimeError("benchmark receipt does not match requested workload")
        if row["elapsedNanoseconds"] <= 0 or row["cpuNanoseconds"] <= 0:
            raise RuntimeError("invalid benchmark timer")
        return row

    def measure(self):
        summaries = {}
        raw = []
        calibrations = {}
        for case in CASES:
            pilots = {variant: self.sample(variant, case, 20000)
                      for variant in ("baseline", "candidate")}
            fastest = min(row["elapsedNanoseconds"] / row["iterations"] for row in pilots.values())
            iterations = max(10000, min(2000000, math.ceil(self.args.target_ms * 1_000_000 / fastest)))
            calibrations[case] = {"pilots": pilots, "iterations": iterations}
            write_json(self.output / "calibration.json", calibrations)
            print("CALIBRATION " + json.dumps({"workload": case, **calibrations[case]}, sort_keys=True), flush=True)
            pairs = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                rows = {}
                for variant in order:
                    rows[variant] = self.sample(variant, case, iterations)
                    raw.append({"case": case, "pair": pair, "variant": variant,
                                "execution_order": list(order), **rows[variant]})
                    write_json(self.output / "raw.json", raw)
                    print("SAMPLE " + json.dumps(raw[-1], sort_keys=True), flush=True)
                for key in ("checksum", "outputCount", "iterations"):
                    if rows["baseline"][key] != rows["candidate"][key]:
                        raise RuntimeError(f"{case}: mismatched output field {key}")
                pairs.append(rows)
            metrics = {}
            for metric, field in (("wall", "elapsedNanoseconds"), ("cpu", "cpuNanoseconds")):
                values = {variant: [p[variant][field] / iterations for p in pairs]
                          for variant in ("baseline", "candidate")}
                medians = {variant: statistics.median(samples) for variant, samples in values.items()}
                changes = [(p["candidate"][field] / p["baseline"][field] - 1) * 100 for p in pairs]
                metrics[metric] = {
                    "baseline_ns_per_plan": medians["baseline"],
                    "candidate_ns_per_plan": medians["candidate"],
                    "change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                    "paired_changes_percent": changes,
                    "improved_pairs": sum(change < 0 for change in changes),
                    "baseline_range_ns": [min(values["baseline"]), max(values["baseline"])],
                    "candidate_range_ns": [min(values["candidate"]), max(values["candidate"])],
                }
            summaries[case] = {"iterations": iterations, "pairs": self.args.pairs, **metrics}
            write_json(self.output / "summary.json", summaries)
            print("RESULT " + json.dumps({"workload": case, **summaries[case]}, sort_keys=True), flush=True)
        return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new result directory")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("use an even pair count >= 2 and a positive finite target duration")
    campaign = Campaign(args)
    campaign.prepare()
    if args.mode != "benchmark":
        campaign.test()
    if args.mode != "tests":
        campaign.measure()
    write_json(campaign.output / "completion.json",
               {"complete": True, "mode": args.mode, "pairs": args.pairs})
    print("CAMPAIGN COMPLETE", flush=True)


if __name__ == "__main__":
    main()
