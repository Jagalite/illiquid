#!/usr/bin/env python3
"""Measure manual visibility rebuilds using exact production projection sources.

Requires macOS and Swift 6.1+. The offline component package has no dependencies.
Baseline and candidate differ only in SourceVisibilityMatcher; all support sources
must be byte-identical. Timings are observations, never flaky pass/fail assertions.
"""
from __future__ import annotations

import argparse
import copy
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
FOCAL = "Sources/IlliquidApp/SidebarValues.swift"
CASES = [
    "tree_manual", "tree_manual_ascii", "tree_preview", "tree_always_show", "tree_disabled_manual",
    "tree_invalid", "tree_nested_manual", "files_nested_manual", "media_nested_manual",
    "tree_default_control", "tree_disabled_control", "tree_regex_control",
    "files_nested_regex_control",
]
TESTS = [
    "SourceBrowserFilterTests.swift", "SourceMediaOrganizationTests.swift",
    "SourceTreeVisibilityCacheTests.swift", "SourceBrowserSearchTests.swift",
    "SourceVisibilityStorageTests.swift", "SourceVisibilityMatcherTests.swift",
]
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
spec = importlib.util.spec_from_file_location("source_tree_snapshot", HELPER)
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def matcher_range(raw):
    start_marker = b"struct SourceVisibilityMatcher {"
    end_marker = b"\nenum SourceVisibilityProjection {"
    if raw.count(start_marker) != 1 or raw.count(end_marker) != 1:
        raise ValueError("Ambiguous or missing SourceVisibilityMatcher boundary")
    start, end = raw.index(start_marker), raw.index(end_marker)
    if end <= start:
        raise ValueError("Reversed SourceVisibilityMatcher boundary")
    return start, end


def outside_matcher(raw):
    start, end = matcher_range(raw)
    return raw[:start] + raw[end:]


# PR212's reviewed projection calls the evaluator API added after BASELINE.
# The reference adapter delegates every call to the untouched historical matcher.
# It owns no cache and is never used for historical performance measurements.
REVIEWED_FILTER_SHA256 = "3d0ffefc80607a38c57bcfd4d714b5a3feee3c1b91a6ff48af49957f425f526a"
HISTORICAL_MATCHER_SHA256 = "0a93951f274f4d9b72868d8175bc6cb8542faae45aed342ef3805e5a81a76599"
REFERENCE_ADAPTER = b"""
extension SourceVisibilityMatcher {
    func makeAncestorEvaluator() -> AncestorEvaluator {
        AncestorEvaluator(matcher: self)
    }

    struct AncestorEvaluator {
        let matcher: SourceVisibilityMatcher

        mutating func evaluate(_ url: URL) -> SourceVisibilityEvaluation {
            matcher.evaluateIncludingAncestors(url)
        }

        mutating func evaluate(normalizedPath: String) -> SourceVisibilityEvaluation {
            matcher.evaluateIncludingAncestors(normalizedPath: normalizedPath)
        }
    }
}
"""


def reference_adapter(candidate, matcher):
    source = candidate.get("Sources/IlliquidApp/SourceBrowserFilter.swift", b"")
    if b"makeAncestorEvaluator" not in source:
        return b""
    if sha(source) != REVIEWED_FILTER_SHA256 or sha(matcher) != HISTORICAL_MATCHER_SHA256:
        raise ValueError("Unreviewed ancestor evaluator compatibility inputs")
    return REFERENCE_ADAPTER


class Study:
    def __init__(self, args):
        self.args = args
        if platform.system() != "Darwin":
            raise ValueError("This qualification requires macOS; no platform substitutions are made")
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH")
        self.env = os.environ.copy()
        self.env.update(CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
                        SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                        TERM="dumb", NO_COLOR="1")
        self.packages, self.binaries, self.expected = {}, {}, {}
        self.manifest = {
            "schema": 1, "complete": False, "baseline": BASELINE,
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(),
            "cases": args.cases, "sizes": args.sizes, "pairs": args.pairs,
            "target_ms": args.target_ms, "sources": {}, "binary_sha256": {},
            "support_helper_sha256": sha(HELPER.read_bytes()),
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "boundary": {
                "included": "One awaited production SourceBrowserFilter.project(input:) call per duration",
                "excluded": ["fixture and recognition setup", "warmups", "receipt hashing", "filesystem I/O",
                             "compilation", "process startup", "UI rendering and playback"],
                "cache": "Raw tree warm; alternate visibility settings or preview so every measured projection rebuilds visibility",
                "ordering": "Balanced AB/BA pairs, fresh process per member, equal iteration counts",
                "fixtures": "Synthetic lexical local URLs; one root; flat or two directory levels; no files read",
                "statistics": "Per-process mean latency; median paired baseline/candidate ratio; all samples retained",
            },
        }

    def command(self, argv, label, timeout=900):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({
                "label": label, "argv": argv, "exit_status": result.returncode,
                "seconds": time.monotonic() - started,
                "stdout": result.stdout, "stderr": result.stderr,
            }) + "\n")
        if label.startswith(("tests-", "build-")):
            (self.output / (label + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n"
                               + (result.stdout + result.stderr)[-16000:])
        return result.stdout

    def source_variants(self, historical):
        if self.args.tests_only and self.args.cases != CASES:
            raise ValueError("Current-source regressions require every case and negative control")
        candidate, candidate_records = support.snapshot(lambda path: (ROOT / path).read_bytes())
        self.manifest["mode"] = (
            "current-source-regressions" if self.args.tests_only else "pinned-baseline-performance-study")
        if self.args.tests_only:
            # This is a behavioral oracle, never an original performance baseline.
            # Only the matcher is historical; all surrounding declarations and
            # supporting files come from the same current snapshot as candidate.
            source_path = candidate_records[FOCAL]["repository_path"]
            original = historical(source_path)
            old_start, old_end = matcher_range(original)
            start, end = matcher_range(candidate[FOCAL])
            matcher = original[old_start:old_end]
            adapter = reference_adapter(candidate, matcher)
            reference = dict(candidate)
            reference[FOCAL] = candidate[FOCAL][:start] + matcher + adapter + candidate[FOCAL][end:]
            reference_records = copy.deepcopy(candidate_records)
            reference_records[FOCAL] = {
                "origin": "historical-matcher-on-current-support",
                "current_source": copy.deepcopy(candidate_records[FOCAL]),
                "historical_revision": BASELINE,
                "historical_repository_path": source_path,
                "historical_source_sha256": sha(original),
                "historical_matcher_sha256": sha(matcher),
                "compatibility_adapter": {
                    "kind": "uncached-historical-ancestor-forwarder" if adapter else "none",
                    "sha256": sha(adapter),
                    "reviewed_filter_sha256": REVIEWED_FILTER_SHA256 if adapter else None,
                },
                "snapshot_sha256": sha(reference[FOCAL]),
            }
            self.manifest.update(
                baseline=None, pairs=0, target_ms=None, sizes=[1, 31, 257],
                qualification="Current-source behavior only; no performance qualification",
                reference={"kind": "historical-matcher-on-current-support", "matcher_revision": BASELINE},
            )
            self.manifest.pop("boundary", None)
            self.manifest["verification"] = {
                "variants": ["reference", "candidate"], "configurations": ["debug", "release"],
                "workloads": "All selected cases, including negative controls; no timed samples",
            }
            return [("reference", reference, reference_records), ("candidate", candidate, candidate_records)]

        baseline, baseline_records = support.snapshot(historical)
        if baseline.keys() != candidate.keys():
            raise ValueError("Source inventories differ")
        for path in baseline:
            if path != FOCAL and baseline[path] != candidate[path]:
                raise ValueError(f"Unrelated production source changed: {path}; requalify explicitly")
        if outside_matcher(baseline[FOCAL]) != outside_matcher(candidate[FOCAL]):
            raise ValueError("Production changes extend outside SourceVisibilityMatcher")
        if baseline[FOCAL] == candidate[FOCAL]:
            raise ValueError("No focal production change")
        return [("baseline", baseline, baseline_records), ("candidate", candidate, candidate_records)]

    def prepare(self):
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head").strip()
        self.manifest["worktree"] = self.command(["git", "status", "--short"], "worktree")
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestry")
        self.manifest["swift"] = self.command([self.swift, "--version"], "swift").strip()
        self.manifest["macos"] = self.command(["sw_vers"], "macos")
        self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()

        def historical(path):
            return subprocess.check_output(["git", "-C", str(ROOT), "show", f"{BASELINE}:{path}"])
        variants = self.source_variants(historical)

        package = support.PACKAGE.replace("SourceTreeVisibilityQualification", "ManualVisibilityQualification")
        package = package.replace("SourceTreeBenchmark", "ManualVisibilityBenchmark")
        shared = {
            "Package.swift": package.encode(),
            "Sources/ManualVisibilityBenchmark/Harness.swift": (HERE / "Harness.swift").read_bytes(),
        }
        for name in TESTS:
            shared["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
        self.manifest["shared_sha256"] = {path: sha(raw) for path, raw in shared.items()}
        for variant, files, records in variants:
            folder = self.output / "packages" / variant
            staged = dict(files)
            staged.update(shared)
            compiled = {}
            for path, raw in staged.items():
                destination = folder / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(raw)
                compiled[path] = sha(raw)
            self.packages[variant] = folder
            self.manifest["sources"][variant] = {"production": records, "compiled_sha256": compiled,
                                                "adaptations": []}
        save(self.output / "manifest.json", self.manifest)

    def check_sources(self):
        if sha(HELPER.read_bytes()) != self.manifest["support_helper_sha256"]:
            raise ValueError("Snapshot helper changed")
        for variant, record in self.manifest["sources"].items():
            for path, expected in record["compiled_sha256"].items():
                if sha((self.packages[variant] / path).read_bytes()) != expected:
                    raise ValueError(f"Staged source changed: {variant}/{path}")

    def swift_command(self, variant, action, configuration):
        return [
            self.swift, action, "--package-path", self.packages[variant],
            "--scratch-path", self.output / "build" / variant,
            "--cache-path", self.output / "cache", "--config-path", self.output / "config",
            "--security-path", self.output / "security", "--jobs", "2", "-c", configuration,
        ]

    def test(self):
        records = []
        for configuration in ["debug", "release"]:
            for variant in self.packages:
                self.check_sources()
                print(f"Test {variant}/{configuration}", flush=True)
                out = self.command(self.swift_command(variant, "test", configuration) + [
                    "--disable-xctest", "--enable-swift-testing", "--no-parallel",
                ], f"tests-{variant}-{configuration}")
                log = (self.output / f"tests-{variant}-{configuration}.log").read_text()
                completed = re.search(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", log)
                if not completed or int(completed.group(1)) == 0:
                    raise ValueError("Swift Testing did not report completed tests")
                records.append({"variant": variant, "configuration": configuration,
                                "passed": True, "test_functions": int(completed.group(1))})
        save(self.output / "tests.json", {"suites": TESTS, "runs": records})

    def build(self):
        for variant in self.packages:
            self.command(self.swift_command(variant, "build", "release") + [
                "--product", "ManualVisibilityBenchmark",
            ], f"build-{variant}")
            folder = self.command(self.swift_command(variant, "build", "release") + [
                "--show-bin-path",
            ], f"bin-path-{variant}").strip()
            self.binaries[variant] = Path(folder) / "ManualVisibilityBenchmark"
            self.manifest["binary_sha256"][variant] = sha(self.binaries[variant].read_bytes())

    def run_case(self, variant, mode, case, size, iterations, label):
        result = json.loads(self.command([
            self.binaries[variant], mode, case, size, iterations,
        ], label))
        if result["case"] != case or result["size"] != size or result["iterations"] != iterations:
            raise ValueError("Harness returned mismatched workload")
        receipts = result.pop("receipts")
        if len(receipts) != iterations or any(receipt != receipts[index % 2]
                                              for index, receipt in enumerate(receipts)):
            raise ValueError("Alternating projections were not deterministic")
        key = (case, size)
        cycle = receipts[:2]
        if key in self.expected and self.expected[key] != cycle:
            raise ValueError(f"Projection parity failed: {variant}/{case}/{size}")
        self.expected[key] = cycle
        result["receipt_cycle"] = cycle
        warmups = 3 if mode == "measure" else 1
        if result["tree_build_count"] != 1 or result["visibility_build_count"] != iterations + warmups:
            raise ValueError("A timed or diagnostic call failed to rebuild visibility")
        if mode == "measure":
            if (len(result["durations_ns"]) != iterations
                    or any(value <= 0 for value in result["durations_ns"])
                    or sum(result["durations_ns"]) != result["elapsed_ns"]):
                raise ValueError("Invalid timing observations")
            result["mean_ns"] = result["elapsed_ns"] / iterations
        return result

    def verify(self):
        records = []
        for case in self.args.cases:
            for size in [1, 31, 257]:
                for variant in self.packages:
                    result = self.run_case(variant, "diagnose", case, size, 4,
                                           f"verify-{variant}-{case}-{size}")
                    if result["tree_build_count"] != 1 or result["visibility_build_count"] != 5:
                        raise ValueError("Benchmark cache boundary was not exercised")
                    records.append({"variant": variant, **result})
        save(self.output / "verification.json", {"passed": True, "observations": records})

    def measure(self):
        if self.args.tests_only:
            raise ValueError("Current-source regressions cannot produce performance measurements")
        calibrations, summaries = [], []
        for case in self.args.cases:
            for size in self.args.sizes:
                pilots = [self.run_case(variant, "measure", case, size, 2,
                                         f"pilot-{variant}-{case}-{size}")
                          for variant in ["baseline", "candidate"]]
                fastest = min(result["mean_ns"] for result in pilots)
                iterations = min(1024, max(2, 2 * math.ceil(
                    self.args.target_ms * 1_000_000 / fastest / 2)))
                calibrations.append({"case": case, "size": size, "iterations": iterations, "pilots": pilots})
                save(self.output / "calibrations.json", calibrations)
                samples, ratios = {"baseline": [], "candidate": []}, []
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    pair_samples = {}
                    for variant in order:
                        result = self.run_case(variant, "measure", case, size, iterations,
                                               f"measure-{case}-{size}-{pair}-{variant}")
                        samples[variant].append(result["mean_ns"])
                        pair_samples[variant] = result["mean_ns"]
                        with (self.output / "measurements.jsonl").open("a") as stream:
                            stream.write(json.dumps({"variant": variant, "pair": pair, "order": order, **result}) + "\n")
                    ratios.append(pair_samples["baseline"] / pair_samples["candidate"])
                speedup = statistics.median(ratios)
                summary = {
                    "case": case, "size": size, "iterations": iterations, "pairs": self.args.pairs,
                    "baseline_median_ms": statistics.median(samples["baseline"]) / 1_000_000,
                    "candidate_median_ms": statistics.median(samples["candidate"]) / 1_000_000,
                    "median_paired_speedup": speedup,
                    "median_paired_reduction_percent": 100 * (1 - 1 / speedup),
                    "paired_speedups": ratios,
                    "min_paired_speedup": min(ratios), "max_paired_speedup": max(ratios),
                    "process_mean_ns": samples,
                }
                summaries.append(summary)
                save(self.output / "summary.json", summaries)
                print(json.dumps(summary), flush=True)
        self.check_sources()

    def run(self):
        self.prepare()
        self.test()
        self.build()
        self.verify()
        if not self.args.tests_only:
            self.measure()
        self.check_sources()
        self.manifest["complete"] = True
        self.manifest["tests_only"] = self.args.tests_only
        save(self.output / "manifest.json", self.manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sizes", default="100,1000,10000")
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--tests-only", action="store_true",
                        help="Current-source tests and differential controls using an adapted historical matcher; no timings")
    args = parser.parse_args()
    args.sizes = [int(value) for value in args.sizes.split(",")]
    args.cases = args.cases.split(",")
    if (args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0
            or any(value <= 0 for value in args.sizes)
            or len(set(args.cases)) != len(args.cases)
            or not set(args.cases) <= set(CASES)):
        parser.error("Use positive sizes/target, an even pair count >=2, and unique known cases")
    study = Study(args)
    try:
        study.run()
    except Exception as error:
        save(study.output / "failure.json", {"type": type(error).__name__, "error": str(error)})
        raise


if __name__ == "__main__":
    main()
