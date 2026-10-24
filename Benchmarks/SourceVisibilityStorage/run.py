#!/usr/bin/env python3
"""Compare retained allocations in exact-source source-browser projections."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
FOCAL = "Sources/IlliquidApp/SourceBrowserFilter.swift"
CASES = ["unchanged", "nonmatching_rule", "hide_half", "hide_last", "preview", "tree_input"]
TESTS = ["SourceBrowserFilterTests.swift", "SourceMediaOrganizationTests.swift",
         "SourceTreeVisibilityCacheTests.swift", "SourceBrowserSearchTests.swift",
         "SourceVisibilityStorageTests.swift"]
METRICS = ["retained_allocator_delta_bytes", "wall_nanoseconds", "cpu_nanoseconds"]
SEMANTIC = ["scenario", "size", "row_stride", "output_rows", "hidden_count", "regex_counts",
            "thumbnail_count", "media_path_count", "snapshot_bytes", "snapshot_checksum"]
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
spec = importlib.util.spec_from_file_location("source_tree_snapshot", HELPER)
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH")
        self.environment = os.environ.copy()
        self.environment.update(CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
                                SWIFT_MODULECACHE_PATH=str(self.output / "module-cache"),
                                SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                                TERM="dumb", NO_COLOR="1")
        self.packages, self.binaries, self.sources = {}, {}, {}
        self.manifest = {"schema": 1, "baseline": BASELINE, "complete": False,
                         "platform": platform.platform(), "machine": platform.machine(),
                         "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                         "sizes": args.sizes, "cases": CASES, "pairs": args.pairs,
                         "exploratory": args.smoke, "support_helper_sha256": sha(HELPER.read_bytes()),
                         "measurement_boundary": {
                             "included": "Live allocator growth from a cold production filter/projection with the input fixture retained",
                             "excluded": ["fixture construction", "output encoding/checksums", "RSS", "physical footprint", "whole-player memory", "peak allocations"],
                             "timing": "One awaited cold production projection, after three independent 8-row warmups",
                             "ordering": "Fresh process per variant; balanced alternating AB/BA pairs",
                             "tree_input": "Includes production row construction/sorting and visibility; other cases accept prepared rows",
                         }, "source_manifests": {}, "harness_hashes": {}, "binary_hashes": {}}

    def command(self, argv, label, allowed=(0,), timeout=600):
        argv = [str(x) for x in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.environment, capture_output=True, timeout=timeout)
        stdout = result.stdout.decode(errors="replace")
        stderr = result.stderr.decode(errors="replace")
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"label": label, "argv": argv, "exit_status": result.returncode,
                                     "seconds": time.monotonic() - start, "stdout": stdout, "stderr": stderr}) + "\n")
        if label.startswith(("tests-", "build-", "negative-")):
            (self.output / (label + ".log")).write_text(stdout + stderr)
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n" + (stdout + stderr)[-12000:])
        return stdout, stderr, result.returncode

    def prepare(self):
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head")[0].strip()
        self.manifest["worktree"] = self.command(["git", "status", "--short"], "worktree")[0]
        self.manifest["swift"] = self.command([self.swift, "--version"], "swift")[0].strip()
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestry")
        if platform.system() == "Darwin":
            self.manifest["macos"] = self.command(["sw_vers"], "macos")[0]
            self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu")[0].strip()
        elif Path("/proc/cpuinfo").exists():
            self.manifest["cpu"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")

        def historical(path):
            return subprocess.check_output(["git", "-C", str(ROOT), "show", f"{BASELINE}:{path}"])
        baseline, baseline_records = support.snapshot(historical)
        candidate, candidate_records = support.snapshot(lambda path: (ROOT / path).read_bytes())
        if baseline.keys() != candidate.keys():
            raise ValueError("Source inventories differ")
        for path in baseline:
            if path != FOCAL and baseline[path] != candidate[path]:
                raise ValueError(f"Unrelated support source changed: {path}; review and requalify explicitly")
        package = support.PACKAGE.replace("SourceTreeVisibilityQualification", "SourceVisibilityStorage")
        package = package.replace("SourceTreeBenchmark", "SourceVisibilityBenchmark")
        package = package.replace("targets: [\n", 'targets: [\n        .target(name: "CVisibilityHeap", publicHeadersPath: "include"),\n', 1)
        package = package.replace('dependencies: ["IlliquidCore", "IlliquidApp"]),',
                                  'dependencies: ["IlliquidCore", "IlliquidApp", "CVisibilityHeap"]),', 1)
        harness = {"Sources/SourceVisibilityBenchmark/Harness.swift": (HERE / "Harness.swift").read_bytes(),
                   "Sources/CVisibilityHeap/heap.c": (HERE / "CVisibilityHeap/heap.c").read_bytes(),
                   "Sources/CVisibilityHeap/include/CVisibilityHeap.h": (HERE / "CVisibilityHeap/include/CVisibilityHeap.h").read_bytes(),
                   "Package.swift": package.encode()}
        self.manifest["harness_hashes"] = {name: sha(data) for name, data in harness.items()}
        self.manifest["runner_sha256"] = sha(Path(__file__).read_bytes())
        for variant, files, records in [("baseline", baseline, baseline_records),
                                        ("candidate", candidate, candidate_records)]:
            folder = self.output / "packages" / variant
            staging = dict(files)
            staging.update(harness)
            for name in TESTS:
                staging["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            manifest = {"production": records, "staged": {}, "adaptations": []}
            for path, data in staging.items():
                adapted = data
                change = None
                if platform.system() == "Linux":
                    if path.endswith("/MediaSidecarReader.swift"):
                        if data.count(b"import Darwin\n") != 1:
                            raise ValueError("Darwin import boundary changed")
                        adapted = data.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        change = "Darwin import -> Glibc"
                    elif path.endswith("/NFOMetadataHints.swift"):
                        adapted = data.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        change = "add FoundationXML import"
                    elif path.endswith("/SourceMediaOrganizationTests.swift"):
                        old = b'appendingPathComponent("media-sidecars-" + UUID().uuidString)'
                        new = b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'
                        if data.count(old) != 1:
                            raise ValueError("Legacy test fixture boundary changed")
                        adapted = data.replace(old, new, 1)
                        change = "explicit directory hint for existing Linux sidecar fixture"
                target = folder / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(adapted)
                manifest["staged"][path] = {"original_sha256": sha(data), "compiled_sha256": sha(adapted)}
                if change:
                    manifest["adaptations"].append({"path": path, "change": change})
            self.packages[variant] = folder
            self.sources[variant] = manifest
            self.manifest["source_manifests"][variant] = manifest
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

    def test(self):
        results = []
        for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
            print(f"Test {variant}/{configuration}", flush=True)
            args = self.swift_command(variant, "test", configuration)
            args += ["--disable-xctest", "--enable-swift-testing", "--no-parallel"]
            if variant == "baseline":
                args += ["--skip", "unchangedProjectionSharesInputStorage"]
            out, err, code = self.command(args, f"tests-{variant}-{configuration}")
            completed = re.search(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", out + err)
            if not completed or int(completed.group(1)) == 0:
                raise ValueError("Swift Testing did not report completed tests")
            results.append({"variant": variant, "configuration": configuration, "passed": True,
                            "completed_test_functions": int(completed.group(1)),
                            "skip": "unchangedProjectionSharesInputStorage" if variant == "baseline" else None})
        args = self.swift_command("baseline", "test", "release") + [
            "--disable-xctest", "--enable-swift-testing", "--no-parallel",
            "--filter", "unchangedProjectionSharesInputStorage"]
        out, err, code = self.command(args, "negative-baseline-sharing", allowed=(1,))
        if "unchangedProjectionSharesInputStorage" not in out + err or "failed" not in out + err:
            raise ValueError("Negative control did not fail the storage-sharing assertion")
        save(self.output / "tests.json", {"suites": TESTS, "runs": results,
                                         "baseline_sharing_negative_control": "failed as expected"})

    def build(self):
        for variant in ["baseline", "candidate"]:
            print(f"Build {variant}", flush=True)
            args = self.swift_command(variant, "build", "release")
            self.command(args + ["--product", "SourceVisibilityBenchmark"], f"build-{variant}")
            folder = self.command(args + ["--show-bin-path"], f"bin-path-{variant}")[0].strip()
            self.binaries[variant] = Path(folder) / "SourceVisibilityBenchmark"
            self.manifest["binary_hashes"][variant] = sha(self.binaries[variant].read_bytes())

    def verify(self):
        values = []
        for scenario in CASES:
            for size in [0, 1, 31, 257]:
                outputs = []
                for variant in ["baseline", "candidate"]:
                    path = self.output / f"verify-{scenario}-{size}-{variant}.bin"
                    out = self.command([self.binaries[variant], "verify", scenario, size, path],
                                       f"verify-{scenario}-{size}-{variant}")[0]
                    observation = json.loads(out)
                    data = path.read_bytes()
                    if len(data) != observation["snapshot_bytes"]:
                        raise ValueError("Incomplete verification snapshot")
                    outputs.append(data)
                    path.with_suffix(".bin.gz").write_bytes(gzip.compress(data, mtime=0))
                    path.unlink()
                if outputs[0] != outputs[1]:
                    raise ValueError(f"Projection bytes differ: {scenario}/{size}")
                values.append({"scenario": scenario, "size": size, "exact_bytes_equal": True,
                               "bytes": len(outputs[0]), "sha256": sha(outputs[0])})
        save(self.output / "verification.json", values)

    def measure(self):
        observations, summary = [], []
        for size in self.args.sizes:
            for scenario in CASES:
                pairs = []
                reference = None
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    results = {}
                    for position, variant in enumerate(order):
                        out = self.command([self.binaries[variant], "measure", scenario, size],
                                           f"measure-{scenario}-{size}-{pair}-{variant}")[0]
                        value = json.loads(out)
                        semantic = {key: value[key] for key in SEMANTIC}
                        if reference is not None and semantic != reference:
                            raise ValueError(f"Measured output differs: {scenario}/{size}")
                        reference = semantic
                        if scenario in ["unchanged", "nonmatching_rule"]:
                            if value["input_output_share_rows"] != (variant == "candidate"):
                                raise ValueError("Unchanged projection storage identity is unexpected")
                        value.update(variant=variant, pair=pair, process_order=position)
                        results[variant] = value
                        observations.append(value)
                        with (self.output / "observations.jsonl").open("a") as stream:
                            stream.write(json.dumps(value, sort_keys=True) + "\n")
                    pairs.append(results)
                metrics = {}
                for metric in METRICS:
                    before = [p["baseline"][metric] for p in pairs]
                    after = [p["candidate"][metric] for p in pairs]
                    metrics[metric] = {"baseline_median": statistics.median(before),
                                       "candidate_median": statistics.median(after),
                                       "baseline_range": [min(before), max(before)],
                                       "candidate_range": [min(after), max(after)],
                                       "median_paired_difference": statistics.median(b - a for b, a in zip(before, after)),
                                       "median_paired_reduction_percent": statistics.median(100 * (b - a) / b for b, a in zip(before, after)) if all(b > 0 for b in before) else None,
                                       "favorable_pairs": sum(a < b for b, a in zip(before, after))}
                summary.append({"scenario": scenario, "size": size, "pairs": len(pairs), "metrics": metrics})
                save(self.output / "summary.json", summary)
                print(f"Measured {scenario}/{size}: {metrics['retained_allocator_delta_bytes']}", flush=True)
        self.manifest["observations"] = len(observations)

    def finish(self):
        for variant, manifest in self.sources.items():
            for name, record in manifest["staged"].items():
                if sha((self.packages[variant] / name).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Measured sources changed: {variant}/{name}")
        for variant, path in self.binaries.items():
            if sha(path.read_bytes()) != self.manifest["binary_hashes"][variant]:
                raise ValueError(f"Measured binary changed: {variant}")
        if sha(Path(__file__).read_bytes()) != self.manifest["runner_sha256"]:
            raise ValueError("Runner changed during measurement")
        self.manifest["complete"] = True
        save(self.output / "manifest.json", self.manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sizes", default="1000,10000,100000")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    args.sizes = [int(n) for n in args.sizes.split(",")]
    if not args.sizes or any(n < 1 for n in args.sizes):
        parser.error("Sizes must be positive")
    if args.pairs < 1 or (not args.smoke and (args.pairs < 6 or args.pairs % 2)):
        parser.error("Use at least six balanced pairs; --smoke permits an exploratory run")
    study = Study(args)
    study.prepare()
    if not args.skip_tests:
        study.test()
    if not args.tests_only:
        study.build()
        study.verify()
        study.measure()
    study.finish()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Visibility storage qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
