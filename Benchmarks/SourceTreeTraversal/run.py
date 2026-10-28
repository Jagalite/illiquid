#!/usr/bin/env python3
"""Qualify the production source-tree traversal with identical support sources.

Runs isolated macOS Swift packages without remote SwiftPM dependencies. The
baseline changes only SourceTreeProjectionInput.swift back to the pinned commit.
Timing and memory observations come from fresh processes in balanced AB/BA order.
"""
from __future__ import annotations

import argparse
import copy
import gzip
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
import sys
import tarfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
FOCAL = "Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift"
STAGED_FOCAL = "Sources/IlliquidApp/SourceTreeProjectionInput.swift"
TESTS = ["SourceBrowserFilterTests.swift", "SourceTreeVisibilityCacheTests.swift",
         "SourceTreeTraversalTests.swift"]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceTreeTraversalQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "TraversalBenchmark", targets: ["TraversalBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "TraversalBenchmark", dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
"""


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def distribution(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty; earlier evidence is not overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        cache = self.output / "module-cache"
        cache.mkdir()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache),
                        CLANG_MODULE_CACHE_PATH=str(cache))
        self.swift = shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH")
        self.queue = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        self.packages, self.manifests, self.binaries = {}, {}, {}
        self.binary_hashes, self.test_runs = {}, []
        self.parity = None
        self.driver_paths = [HERE / "run.py", HERE / "Harness.swift",
                             ROOT / "Benchmarks/SourceTreeVisibility/run.py"]
        self.driver_hashes = {str(p.relative_to(ROOT)): file_digest(p) for p in self.driver_paths}
        if not self.queue.is_file():
            print("Shared Kyoto queue is unavailable on this host; compiling isolated "
                  "components directly and serially.", flush=True)

    def execute(self, command, label, *, stdout_file=None, timeout=600):
        command = [str(item) for item in command]
        started = time.monotonic()
        if stdout_file is None:
            result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True,
                                    text=True, timeout=timeout)
            stdout_bytes = result.stdout.encode()
            stdout_hash, stdout_size = digest(stdout_bytes), len(stdout_bytes)
            (self.output / (label + ".log")).write_text(result.stdout + result.stderr)
        else:
            with stdout_file.open("wb") as destination:
                result = subprocess.run(command, cwd=ROOT, env=self.env, stdout=destination,
                                        stderr=subprocess.PIPE, text=True, timeout=timeout)
            stdout_hash, stdout_size = file_digest(stdout_file), stdout_file.stat().st_size
            (self.output / (label + ".log")).write_text(result.stderr)
        record = {"label": label, "command": command, "returncode": result.returncode,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout_bytes": stdout_size, "stdout_sha256": stdout_hash}
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(label + " failed:\n" +
                               ((result.stdout or "") + result.stderr)[-16000:])
        return result

    def compile(self, command, label):
        self.check_sources()
        if self.queue.is_file():
            cli = [sys.executable, str(self.queue)]
            submitted = self.execute([*cli, "submit", "--", *command], label + "-submit")
            job_id = str(json.loads(submitted.stdout)["id"])
            self.execute([*cli, "show", job_id], label + "-show")
            try:
                self.execute([*cli, "wait", job_id], label + "-wait", timeout=1200)
            finally:
                self.execute([*cli, "logs", job_id], label + "-logs")
        else:
            self.execute(command, label)
        self.check_sources()

    def prepare(self):
        if platform.system() != "Darwin":
            raise ValueError("This harness qualifies native Darwin/Foundation; run on macOS")
        helper_path = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
        spec = importlib.util.spec_from_file_location("source_tree_snapshot", helper_path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        current, current_records = helper.snapshot(lambda name: (ROOT / name).read_bytes())
        revision = self.execute(["git", "rev-parse", BASELINE + "^{commit}"], "baseline-revision").stdout.strip()
        if revision != BASELINE:
            raise ValueError("Unexpected baseline commit")
        head = self.execute(["git", "rev-parse", "HEAD"], "head-revision").stdout.strip()
        baseline_path = self.output / "baseline-source.swift"
        self.execute(["git", "show", BASELINE + ":" + FOCAL], "baseline-source", stdout_file=baseline_path)
        old = baseline_path.read_bytes()
        if old == current[STAGED_FOCAL]:
            raise ValueError("Baseline and candidate focal sources are identical")
        baseline_files = dict(current)
        baseline_files[STAGED_FOCAL] = old
        baseline_records = copy.deepcopy(current_records)
        baseline_records[STAGED_FOCAL].update(
            source_sha256=digest(old), snapshot_sha256=digest(old),
            git_blob=hashlib.sha1(b"blob " + str(len(old)).encode() + b"\0" + old).hexdigest())
        for variant, files, records in [
            ("baseline", baseline_files, baseline_records),
            ("candidate", current, copy.deepcopy(current_records)),
        ]:
            package = self.output / "packages" / variant
            staging = dict(files)
            staging["Package.swift"] = PACKAGE.encode()
            staging["Sources/TraversalBenchmark/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            for name in TESTS:
                staging["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            manifest = {"variant": variant, "baseline_commit": BASELINE, "checkout_head": head,
                        "production": records, "staged": {}, "adaptations": []}
            for name, record in records.items():
                is_baseline_focal = variant == "baseline" and name == STAGED_FOCAL
                record.update(origin="pinned-baseline" if is_baseline_focal else "working-tree",
                              revision=BASELINE if is_baseline_focal else None,
                              comparison_role="focal" if name == STAGED_FOCAL else "support")
            for name, raw in staging.items():
                destination = package / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(raw)
                manifest["staged"][name] = digest(raw)
            self.packages[variant] = package
            self.manifests[variant] = manifest
            write_json(self.output / (variant + "-sources.json"), manifest)
        for name, raw in current.items():
            if name != STAGED_FOCAL and baseline_files[name] != raw:
                raise ValueError("Unequal support source: " + name)
        environment = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
            "swift": self.execute([self.swift, "--version"], "swift-version").stdout.strip(),
            "head": head, "baseline_commit": BASELINE, "driver_hashes": self.driver_hashes,
            "worktree": self.execute(["git", "status", "--short"], "worktree").stdout,
            "developer_dir": self.env.get("DEVELOPER_DIR"),
            "jobs": self.args.jobs, "pairs": self.args.pairs, "target_ms": self.args.target_ms,
            "comparison": "Pinned focal source; all supporting files, harness and tests identical",
            "timing": "Production rows() construction only; fixture, warmup, full receipts and destruction excluded",
            "order": "Fresh processes; alternating AB/BA pairs separately for timing and memory",
            "memory": "Darwin process maxRSS and malloc live bytes around one cold rows() call; "
                      "fixture high-water can mask transient allocation; retained rows included",
            "queue_available": self.queue.is_file(),
        }
        write_json(self.output / "environment.json", environment)
        with tarfile.open(self.output / "staged-sources.tar.gz", "w:gz") as archive:
            archive.add(self.output / "packages", arcname="packages")
        print("TRAVERSAL_ENVIRONMENT " + json.dumps(environment, sort_keys=True), flush=True)

    def check_sources(self):
        for path, expected in self.driver_hashes.items():
            if file_digest(ROOT / path) != expected:
                raise ValueError("Driver changed during run: " + path)
        for variant, manifest in self.manifests.items():
            for name, expected in manifest["staged"].items():
                if file_digest(self.packages[variant] / name) != expected:
                    raise ValueError("Staged source changed: " + variant + "/" + name)
        for variant, expected in self.binary_hashes.items():
            if file_digest(self.binaries[variant]) != expected:
                raise ValueError("Benchmark binary changed: " + variant)

    def swift_command(self, variant, action, configuration):
        return [self.swift, action, "--package-path", str(self.packages[variant]),
                "--scratch-path", str(self.output / "build" / variant),
                "--cache-path", str(self.output / "swiftpm-cache"),
                "--config-path", str(self.output / "swiftpm-config"),
                "--security-path", str(self.output / "swiftpm-security"),
                "--jobs", str(self.args.jobs), "--configuration", configuration]

    def test(self):
        for configuration in ["debug", "release"]:
            for variant in ["baseline", "candidate"]:
                label = "tests-" + variant + "-" + configuration
                print("Running " + label, flush=True)
                self.compile(self.swift_command(variant, "test", configuration) +
                             ["--disable-xctest", "--enable-swift-testing", "--no-parallel"], label)
                log_path = self.output / (label + ("-logs" if self.queue.is_file() else "") + ".log")
                matches = [match for match in re.finditer(
                    r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", log_path.read_text())
                           if int(match.group(1)) > 0]
                if not matches:
                    raise ValueError("Missing nonempty Swift Testing success receipt: " + label)
                match = matches[-1]
                receipt = {"variant": variant, "configuration": configuration, "passed": True,
                           "tests_passed": int(match.group(1)), "summary": match.group(0)}
                self.test_runs.append(receipt)
                print("TRAVERSAL_TEST " + json.dumps(receipt, sort_keys=True), flush=True)
                write_json(self.output / "tests.json", {"suites": TESTS, "runs": self.test_runs})

    def build(self):
        for variant in ["baseline", "candidate"]:
            self.compile(self.swift_command(variant, "build", "release") +
                         ["--product", "TraversalBenchmark"], "build-" + variant)
            bin_dir = self.execute(self.swift_command(variant, "build", "release") +
                                   ["--show-bin-path"], "bin-path-" + variant).stdout.strip()
            self.binaries[variant] = Path(bin_dir) / "TraversalBenchmark"
            self.binary_hashes[variant] = file_digest(self.binaries[variant])
        write_json(self.output / "binaries.json", self.binary_hashes)

    def verify(self):
        receipts = {}
        paths = []
        for variant in ["baseline", "candidate"]:
            path = self.output / ("verify-" + variant + ".json")
            self.execute([self.binaries[variant], "verify"], "verify-" + variant, stdout_file=path)
            receipts[variant] = {"sha256": file_digest(path), "bytes": path.stat().st_size}
            paths.append(path)
        # Compare the complete ordered rows, not merely a checksum.
        with paths[0].open("rb") as left, paths[1].open("rb") as right:
            while True:
                a, b = left.read(1024 * 1024), right.read(1024 * 1024)
                if a != b:
                    raise ValueError("Full row receipts differ between variants")
                if not a:
                    break
        for path in paths:
            with path.open("rb") as source, gzip.open(str(path) + ".gz", "wb") as destination:
                shutil.copyfileobj(source, destination)
            path.unlink()
        self.parity = {"complete_ordered_rows_equal": True, "receipts": receipts}
        write_json(self.output / "parity.json", self.parity)
        print("TRAVERSAL_PARITY " + json.dumps(self.parity, sort_keys=True), flush=True)

    def measure(self):
        cases = json.loads(self.execute([self.binaries["candidate"], "list"], "cases").stdout)
        baseline_cases = json.loads(self.execute([self.binaries["baseline"], "list"], "baseline-cases").stdout)
        if cases != baseline_cases:
            raise ValueError("Baseline/candidate scenario inventories differ")
        write_json(self.output / "cases.json", cases)
        expected, calibration, observations = {}, [], []
        for case in cases:
            name = case["name"]
            samples = []
            for variant in ["baseline", "candidate"]:
                row = json.loads(self.execute([self.binaries[variant], "sample", name, "1"],
                                              "calibrate-" + name + "-" + variant).stdout)
                if row["elapsed_ns"] <= 0 or row["count"] <= 0:
                    raise ValueError("Invalid calibration measurement")
                receipt = (row["count"], row["checksum"])
                if name in expected and expected[name] != receipt:
                    raise ValueError("Calibration output differs: " + name)
                expected[name] = receipt
                samples.append(row["elapsed_ns"])
                calibration.append({"variant": variant, **row})
            iterations = min(100, max(1, math.ceil(self.args.target_ms * 1_000_000 / min(samples))))
            calibration.append({"scenario": name, "selected_iterations": iterations, "cap": 100})
            write_json(self.output / "calibration.json", calibration)
            for kind in ["sample", "memory"]:
                for pair in range(self.args.pairs):
                    variants = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    for position, variant in enumerate(variants):
                        args = [self.binaries[variant], kind, name]
                        if kind == "sample":
                            args.append(str(iterations))
                        label = kind + "-" + name + "-" + str(pair) + "-" + variant
                        row = json.loads(self.execute(args, label).stdout)
                        if row["scenario"] != name or (row["count"], row["checksum"]) != expected[name]:
                            raise ValueError("Measured output differs: " + label)
                        if kind == "sample":
                            if row["iterations"] != iterations or row["observedRows"] != row["count"] * iterations:
                                raise ValueError("Measured operation count differs: " + label)
                            if row["elapsed_ns"] <= 0 or row["cpu_ns"] < 0:
                                raise ValueError("Invalid timing: " + label)
                        row.update(kind=kind, variant=variant, pair=pair, process_order=position)
                        observations.append(row)
                        with (self.output / "observations.jsonl").open("a") as output:
                            output.write(json.dumps(row, sort_keys=True) + "\n")
                        print("TRAVERSAL_OBSERVATION " + json.dumps(row, sort_keys=True), flush=True)
        summaries = []
        for case in cases:
            name = case["name"]
            cell = {"scenario": name, "description": case["description"], "pairs": self.args.pairs,
                    "count": expected[name][0], "checksum": expected[name][1]}
            for metric in ["elapsed_ns", "cpu_ns"]:
                values = {}
                for variant in ["baseline", "candidate"]:
                    values[variant] = [row[metric] / row["iterations"] for row in observations
                                       if row["kind"] == "sample" and row["scenario"] == name
                                       and row["variant"] == variant]
                ratios = [c / b for b, c in zip(values["baseline"], values["candidate"]) if b > 0]
                cell[metric + "_per_call"] = {
                    "baseline": distribution(values["baseline"]), "candidate": distribution(values["candidate"]),
                    "median_paired_candidate_over_baseline": statistics.median(ratios) if ratios else None,
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)) if ratios else None,
                }
            for metric in ["peak_rss_before_bytes", "peak_rss_after_bytes", "peak_rss_growth_bytes",
                           "live_heap_before_bytes", "live_heap_after_bytes", "live_heap_growth_bytes"]:
                cell[metric] = {
                    variant: distribution([row[metric] for row in observations
                                           if row["kind"] == "memory" and row["scenario"] == name
                                           and row["variant"] == variant])
                    for variant in ["baseline", "candidate"]
                }
            summaries.append(cell)
        write_json(self.output / "summary.json", summaries)
        print("TRAVERSAL_SUMMARY " + json.dumps(summaries, sort_keys=True), flush=True)
        self.check_sources()

    def finish(self):
        self.check_sources()
        value = {"success": True, "mode": self.args.mode, "tests": self.test_runs,
                 "parity": self.parity, "binaries": self.binary_hashes,
                 "source_manifest_file_sha256": {v: file_digest(self.output / (v + "-sources.json"))
                                                 for v in self.manifests},
                 "focal_sources": {v: m["production"][STAGED_FOCAL]
                                   for v, m in self.manifests.items()},
                 "support_sources_identical": True, "driver_hashes": self.driver_hashes}
        write_json(self.output / "completion.json", value)
        print("TRAVERSAL_QUALIFICATION " + json.dumps(value, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=25)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--mode", choices=["all", "tests", "benchmark"], default="all")
    args = parser.parse_args()
    if (args.pairs < 6 or args.pairs % 2 or not math.isfinite(args.target_ms)
            or args.target_ms <= 0 or args.jobs < 1):
        parser.error("Use an even number of at least six pairs, positive target-ms and jobs")
    runner = Runner(args)
    try:
        runner.prepare()
        if args.mode in ["all", "tests"]:
            runner.test()
        if args.mode in ["all", "benchmark"]:
            runner.build()
            runner.verify()
            runner.measure()
        runner.finish()
    except Exception as error:
        write_json(runner.output / "failure.json", {"type": type(error).__name__, "error": str(error)})
        raise


if __name__ == "__main__":
    main()
