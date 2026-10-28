#!/usr/bin/env python3
"""Compare exact production root selection and visibility projection."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
FOCAL = "Sources/IlliquidApp/SidebarValues.swift"
CASES = [
    "lookup-empty", "lookup-single", "lookup-eight", "lookup-sixtyfour",
    "lookup-nested", "lookup-unicode", "lookup-miss", "lookup-exact",
    "project-tree-one", "project-files-one", "project-tree-many",
    "project-files-many", "project-no-rules",
]
TESTS = [
    "SourceBrowserFilterTests.swift", "SourceTreeVisibilityCacheTests.swift",
    "SourceBrowserSearchTests.swift", "SourceVisibilityStorageTests.swift",
    "SourceRootSelectionTests.swift",
]
OLD = b"""    private func matchingRootPath(for normalizedPath: String) -> String? {
        rootPaths
            .filter { rootPath in
                SourceTreeIdentity.contains(normalizedPath, within: rootPath)
            }
            .max { $0.count < $1.count }
    }"""
NEW = b"""    private func matchingRootPath(for normalizedPath: String) -> String? {
        // Select the longest match without allocating an intermediate array for
        // each row and ancestor. Keep max's comparison and root-order semantics.
        rootPaths.lazy
            .filter { rootPath in
                SourceTreeIdentity.contains(normalizedPath, within: rootPath)
            }
            .max { $0.count < $1.count }
    }"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be empty")
        self.output.mkdir(parents=True, exist_ok=True)
        if platform.system() not in ["Darwin", "Linux"]:
            raise ValueError("This study supports macOS and Linux")
        self.swift = shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift is unavailable")
        self.env = dict(os.environ, TERM="dumb", NO_COLOR="1")
        for name in ["CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"]:
            self.env[name] = str(self.output / "module-cache")
        self.packages, self.binaries, self.staged = {}, {}, {}
        self.manifest = {
            "schema": 1, "baseline": BASELINE, "complete": False,
            "platform": platform.platform(), "machine": platform.machine(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "pairs": 0 if args.tests_only else args.pairs,
            "target_ms": None if args.tests_only else args.target_ms,
            "cases": [] if args.tests_only else CASES,
            "mode": "current-source-regressions" if args.tests_only else "pinned-baseline-performance-study",
            "native_macos": platform.system() == "Darwin",
            "measurement": {
                "lookup": "Production relativePath(normalizedPath:) plus consuming UTF-8 length; matcher construction excluded",
                "projection": "Complete production project(rows:configuration:roots:revealsRulePreview:query:); alternating rules force visibility rebuilds",
                "excluded": ["fixture setup", "compilation", "verification snapshots", "filesystem I/O", "SwiftUI", "tree construction/sorting"],
                "clocks": "DispatchTime uptime and CLOCK_PROCESS_CPUTIME_ID around identical loop boundaries",
                "ordering": "Fresh process per observation; alternating AB/BA order for each paired case",
                "controls": ["empty roots", "no matching roots", "exact root", "projection with no active visibility rules"],
                "scope": "Component CPU/wall timing; no whole-player latency, RSS, frame-rate or battery claim",
            },
        }

    def command(self, argv, label, timeout=600):
        argv = [str(value) for value in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        record = {"label": label, "argv": argv, "returncode": result.returncode,
                  "seconds": time.monotonic() - start,
                  "stdout": result.stdout, "stderr": result.stderr}
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if label.startswith(("test-", "build-")):
            (self.output / (label + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n"
                               + (result.stdout + result.stderr)[-16000:])
        return result.stdout + result.stderr if label.startswith("test-") else result.stdout

    def historical(self, path):
        return subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)

    def prepare(self):
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head").strip()
        self.manifest["worktree"] = self.command(["git", "status", "--short"], "worktree")
        self.manifest["swift"] = self.command([self.swift, "--version"], "swift").strip()
        if platform.system() == "Darwin":
            self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
            self.manifest["macos"] = self.command(["sw_vers"], "macos").strip()
        elif Path("/proc/cpuinfo").is_file():
            self.manifest["cpu"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
        spec = importlib.util.spec_from_file_location("root_selection_support", HELPER)
        support = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(support)
        after, after_records = support.snapshot(lambda path: (ROOT / path).read_bytes())
        if self.args.tests_only:
            self.manifest["baseline"] = None
            variants = [("candidate", after, after_records)]
        else:
            self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestry")
            if HELPER.read_bytes() != self.historical(str(HELPER.relative_to(ROOT))):
                raise ValueError("Shared extraction helper changed since the pinned baseline")
            before, before_records = support.snapshot(self.historical)
            if before.keys() != after.keys():
                raise ValueError("Production source inventories differ")
            for path in before:
                if path == FOCAL:
                    if before[path].count(OLD) != 1 or after[path] != before[path].replace(OLD, NEW, 1):
                        raise ValueError("Focal changes exceed the declared lazy-filter experiment")
                elif before[path] != after[path]:
                    raise ValueError(f"Unrelated production support changed: {path}")
            variants = [("baseline", before, before_records), ("candidate", after, after_records)]
        package = support.PACKAGE.replace("SourceTreeVisibilityQualification", "SourceRootSelection")
        package = package.replace("SourceTreeBenchmark", "SourceRootBenchmark")
        harness = {
            "Package.swift": package.encode(),
            "Sources/SourceRootBenchmark/Harness.swift": (HERE / "Harness.swift").read_bytes(),
        }
        for test in TESTS:
            harness["Tests/IlliquidAppTests/" + test] = (ROOT / "Tests/IlliquidAppTests" / test).read_bytes()
        self.manifest["harness_sha256"] = {path: digest(data) for path, data in harness.items()}
        self.manifest["helper_sha256"] = digest(HELPER.read_bytes())
        self.manifest["runner_sha256"] = digest(Path(__file__).read_bytes())
        self.manifest["sources"] = {}
        self.manifest["platform_adaptations"] = {}
        for variant, files, records in variants:
            folder = self.output / "packages" / variant
            self.packages[variant] = folder
            staged = dict(files, **harness)
            self.staged[variant] = {}
            adaptations = []
            for path, data in staged.items():
                if platform.system() == "Linux":
                    if path.endswith("/MediaSidecarReader.swift"):
                        if data.count(b"import Darwin\n") != 1:
                            raise ValueError("POSIX import boundary changed")
                        data = data.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        adaptations.append({"path": path, "change": "Darwin import -> Glibc"})
                    elif path.endswith("/NFOMetadataHints.swift"):
                        if data.count(b"import Foundation\n") != 1:
                            raise ValueError("XML import boundary changed")
                        data = data.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        adaptations.append({"path": path, "change": "add FoundationXML import"})
                destination = folder / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                self.staged[variant][path] = digest(data)
            self.manifest["sources"][variant] = {"production": records, "staged": self.staged[variant]}
            self.manifest["platform_adaptations"][variant] = adaptations
        save(self.output / "manifest.json", self.manifest)

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.packages[variant],
                "--scratch-path", self.output / "build" / variant,
                "--cache-path", self.output / "cache", "--config-path", self.output / "config",
                "--security-path", self.output / "security", "--jobs", "2", "-c", configuration,
                "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def test_and_build(self):
        tests = []
        variants = [("candidate", "debug"), ("candidate", "release")]
        if not self.args.tests_only:
            variants.insert(0, ("baseline", "release"))
        for variant, configuration in variants:
            print(f"Testing {variant}/{configuration}", flush=True)
            log = self.command(self.swift_command(variant, "test", configuration) + ["--no-parallel"],
                               f"test-{variant}-{configuration}")
            completed = re.search(r"Test run with (\d+) tests.*?passed", log)
            if completed is None or int(completed.group(1)) == 0:
                raise ValueError("No nonzero completed Swift Testing result")
            tests.append({"variant": variant, "configuration": configuration, "passed": True,
                          "completed_tests": int(completed.group(1)),
                          "summary": [line for line in log.splitlines() if "tests passed" in line or "Test run with" in line]})
        save(self.output / "tests.json", tests)
        if self.args.tests_only:
            return
        self.manifest["binary_sha256"] = {}
        for variant in ["baseline", "candidate"]:
            command = self.swift_command(variant, "build", "release")
            self.command(command + ["--product", "SourceRootBenchmark"], f"build-{variant}")
            folder = self.command(command + ["--show-bin-path"], f"bin-{variant}").strip()
            self.binaries[variant] = Path(folder) / "SourceRootBenchmark"
            self.manifest["binary_sha256"][variant] = digest(self.binaries[variant].read_bytes())

    def sample(self, variant, mode, case, size, iterations, label):
        text = self.command([self.binaries[variant], mode, case, size, iterations], label)
        return json.loads(text)

    def verify(self):
        results = []
        for case in CASES:
            for size in [1, 31, 128]:
                records = [self.sample(v, "verify", case, size, 2, f"verify-{case}-{size}-{v}")
                           for v in ["baseline", "candidate"]]
                if records[0]["receipt"] != records[1]["receipt"]:
                    raise ValueError(f"Output bytes/values differ: {case}/{size}")
                # JSON text preserves canonical Unicode spelling byte differences.
                snapshots = [json.dumps(r["receipt"], sort_keys=True, ensure_ascii=False).encode() for r in records]
                if snapshots[0] != snapshots[1]:
                    raise ValueError(f"Output Unicode bytes differ: {case}/{size}")
                results.append({"case": case, "size": size, "equal": True,
                                "bytes": len(snapshots[0]), "sha256": digest(snapshots[0])})
        save(self.output / "verification.json", results)

    def measure(self):
        summaries = []
        for case in CASES:
            size = 1000 if case.startswith("project-") else 256
            calibration = {v: self.sample(v, "measure", case, size, 2, f"calibrate-{case}-{v}")
                           for v in ["baseline", "candidate"]}
            fastest_per_iteration = min(r["wall_ns"] / r["iterations"] for r in calibration.values())
            iterations = max(2, min(100000, math.ceil(self.args.target_ms * 1e6 / fastest_per_iteration)))
            if iterations % 2: iterations += 1
            pairs = []
            reference = None
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                records = {}
                for order_index, variant in enumerate(order):
                    record = self.sample(variant, "measure", case, size, iterations,
                                         f"measure-{case}-{pair}-{variant}")
                    semantic = (record["checksum"], record["fingerprint"], record["operations"])
                    if reference is not None and semantic != reference:
                        raise ValueError(f"Timed output changed: {case}")
                    reference = semantic
                    record.update(variant=variant, pair=pair, order_index=order_index)
                    records[variant] = record
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                pairs.append(records)
            metrics = {}
            for name in ["wall_ns", "cpu_ns"]:
                b = [p["baseline"][name] / p["baseline"]["operations"] for p in pairs]
                a = [p["candidate"][name] / p["candidate"]["operations"] for p in pairs]
                changes = [100 * (x - y) / x for x, y in zip(b, a)]
                metrics[name] = {
                    "baseline_median_per_operation": statistics.median(b),
                    "candidate_median_per_operation": statistics.median(a),
                    "baseline_range": [min(b), max(b)], "candidate_range": [min(a), max(a)],
                    "median_paired_reduction_percent": statistics.median(changes),
                    "paired_reduction_range_percent": [min(changes), max(changes)],
                    "favorable_pairs": sum(x > y for x, y in zip(b, a)),
                }
            summary = {"case": case, "size": size, "pairs": len(pairs), "iterations": iterations,
                       "operations_per_sample": pairs[0]["baseline"]["operations"],
                       "minimum_sample_ms": min(r[v]["wall_ns"] / 1e6 for r in pairs for v in ["baseline", "candidate"]),
                       "metrics": metrics}
            summaries.append(summary)
            save(self.output / "summary.json", summaries)
            print("ROOT_SELECTION_CASE " + json.dumps(summary, sort_keys=True), flush=True)

    def finish(self):
        for variant, files in self.staged.items():
            for path, expected in files.items():
                if digest((self.packages[variant] / path).read_bytes()) != expected:
                    raise ValueError("Staged sources changed during the run")
        self.manifest["complete"] = True
        self.manifest["tests_only"] = self.args.tests_only
        self.manifest["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        save(self.output / "manifest.json", self.manifest)
        evidence = {}
        for name in ["manifest.json", "tests.json", "verification.json", "summary.json", "observations.jsonl"]:
            path = self.output / name
            if path.exists():
                evidence[name] = [json.loads(line) for line in path.read_text().splitlines()] if name.endswith(".jsonl") else json.loads(path.read_text())
        print("ROOT_SELECTION_EVIDENCE " + json.dumps(evidence, sort_keys=True, separators=(",", ":")), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=120)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 4 or args.pairs % 2 or not 20 <= args.target_ms <= 2000:
        parser.error("Use an even number of at least four pairs and a 20–2000 ms target")
    print("Builds are serialized in private scratch paths; submit this runner through Kyoto when available.", flush=True)
    study = Study(args)
    study.prepare()
    study.test_and_build()
    if not args.tests_only:
        study.verify()
        study.measure()
    study.finish()


if __name__ == "__main__":
    main()
