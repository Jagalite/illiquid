#!/usr/bin/env python3
"""Compare exact source-root matching implementations in an offline Swift package."""
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
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
FOCAL = "Sources/IlliquidApp/SidebarValues.swift"
PRODUCT = "SourceRootMatchingBenchmark"
TESTS = [
    "SourceRootMatchingTests.swift", "SourceBrowserSearchTests.swift",
    "SourceBrowserFilterTests.swift", "FlatFileProjectionTests.swift",
    "SourceTreeVisibilityCacheTests.swift",
]
spec = importlib.util.spec_from_file_location("source_tree_staging", HELPER)
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
PACKAGE = staging.PACKAGE.replace(
    "SourceTreeVisibilityQualification", "SourceRootMatchingQualification"
).replace("SourceTreeBenchmark", PRODUCT)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def file_digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def without_matcher(raw):
    start, end = b"struct SourceVisibilityMatcher {", b"\nenum SourceVisibilityProjection {"
    if raw.count(start) != 1 or raw.count(end) != 1:
        raise ValueError("SourceVisibilityMatcher extraction boundary changed")
    first, last = raw.index(start), raw.index(end)
    if last <= first:
        raise ValueError("Reversed SourceVisibilityMatcher extraction boundary")
    return raw[:first] + b"// MATCHER\n" + raw[last:]


def adapt(name, raw):
    if platform.system() != "Linux":
        return raw, []
    changes = {
        "MediaSidecarReader.swift": (b"import Darwin\n", b"import Glibc\n"),
        "NFOMetadataHints.swift": (b"import Foundation\n", b"import Foundation\nimport FoundationXML\n"),
    }
    if Path(name).name not in changes:
        return raw, []
    before, after = changes[Path(name).name]
    if raw.count(before) != 1:
        raise ValueError(f"Linux import adaptation boundary changed: {name}")
    return raw.replace(before, after, 1), [{"from": before.decode(), "to": after.decode()}]


class Runner:
    def __init__(self, args):
        self.args, self.output = args, args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("--output must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = shutil.which(args.swift) or str(Path(args.swift).absolute())
        if not Path(self.swift).is_file():
            raise ValueError(f"Swift executable not found: {args.swift}")
        self.env = dict(os.environ, SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                        CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"))
        self.manifests, self.binaries, self.binary_hashes = {}, {}, {}
        self.commands, self.tests, self.cases = [], [], []
        self.driver_paths = [Path(__file__).resolve(), HELPER, HERE / "Harness.swift"]
        self.driver_hashes = {str(path.relative_to(ROOT)): file_digest(path) for path in self.driver_paths}
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        if kyoto.exists() and not args.kyoto_job:
            raise RuntimeError(
                "Kyoto is available. Submit this complete runner through it, adding --kyoto-job: "
                "python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 "
                "Benchmarks/SourceRootMatching/run.py --kyoto-job [the same arguments]. "
                "Inspect show/logs/wait for that job before reporting its result."
            )
        self.kyoto = "whole runner submitted through Kyoto" if kyoto.exists() else "unavailable"
        if not kyoto.exists():
            print("Kyoto shared queue is unavailable on this host; building directly with serialized commands.", flush=True)

    def command(self, argv, label, timeout=900):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True,
                                    capture_output=True, timeout=timeout)
            stdout, stderr, code = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or b""
            stderr = error.stderr or b""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            stderr += f"\nTimed out after {timeout} seconds\n"
            code = -1
        destination = self.output / "logs" / (label + ".log")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(stdout + stderr)
        self.commands.append({
            "label": label, "argv": argv, "returncode": code,
            "elapsed_seconds": time.monotonic() - started,
            "log": str(destination.relative_to(self.output)), "log_sha256": file_digest(destination),
        })
        save(self.output / "commands.json", self.commands)
        if code:
            raise RuntimeError(f"{label} failed ({code}): {(stdout + stderr)[-12000:]}")
        return stdout

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.output / "packages" / variant,
                   "--scratch-path", self.output / "build" / variant,
                   "--cache-path", self.output / "swiftpm-cache",
                   "--config-path", self.output / "swiftpm-config",
                   "--security-path", self.output / "swiftpm-security",
                   "--jobs", "2", "--configuration", configuration]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def prepare(self):
        baseline = self.command(
            ["git", "rev-parse", "--verify", self.args.baseline + "^{commit}"], "baseline"
        ).strip()
        baseline_files, baseline_records = staging.snapshot(lambda name: subprocess.check_output(
            ["git", "show", f"{baseline}:{name}"], cwd=ROOT))
        candidate_files, candidate_records = staging.snapshot(lambda name: (ROOT / name).read_bytes())
        head = self.command(["git", "rev-parse", "HEAD"], "head").strip()
        baseline_files, baseline_records, candidate_records, comparison = staging.comparison_sources(
            baseline_files, baseline_records, candidate_files, candidate_records,
            focal_sources={FOCAL}, baseline_revision=baseline, worktree_head=head,
        )
        for name in baseline_files:
            if name != FOCAL and baseline_files[name] != candidate_files[name]:
                raise ValueError(f"Unrelated production support changed: {name}")
        if without_matcher(baseline_files[FOCAL]) != without_matcher(candidate_files[FOCAL]):
            raise ValueError("SidebarValues differs outside SourceVisibilityMatcher")
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            staged = dict(files)
            staged["Package.swift"] = PACKAGE.encode()
            staged[f"Sources/{PRODUCT}/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            for name in TESTS:
                staged["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            manifest = {"comparison": comparison, "production": records, "staged": {}}
            for name, raw in staged.items():
                compiled, adaptations = adapt(name, raw)
                path = self.output / "packages" / variant / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(compiled)
                manifest["staged"][name] = {
                    "source_sha256": digest(raw), "compiled_sha256": digest(compiled),
                    "adaptations": adaptations,
                }
            self.manifests[variant] = manifest
        save(self.output / "sources.json", self.manifests)
        for path, name in zip(self.driver_paths, ["runner.py", "staging-helper.py", "Harness.swift"]):
            shutil.copyfile(path, self.output / name)
        environment = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "architecture": platform.machine(), "python": sys.version,
            "swift": self.command([self.swift, "--version"], "swift-version").strip(),
            "baseline": baseline, "head": head, "comparison": comparison,
            "worktree": self.command(["git", "status", "--short"], "worktree"),
            "driver_sha256": self.driver_hashes, "kyoto": self.kyoto,
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.args).items()},
            "logical_cpus": os.cpu_count(),
            "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
            "sampling": "Fresh processes, balanced AB/BA pairs, same iterations, all calibration and timed observations retained",
            "measurement": "Harness process CPU and monotonic wall time; fixture setup and two warmup iterations excluded",
            "scope": "Synthetic source browser component workloads; no live UI, playback, energy or allocation-count claim",
        }
        if platform.system() == "Darwin":
            environment["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model").strip()
            environment["macos"] = self.command(["sw_vers"], "macos-version").strip()
            environment["sdk"] = self.command(["xcrun", "--show-sdk-version"], "sdk-version").strip()
        save(self.output / "environment.json", environment)

    def check_sources(self):
        for relative, expected in self.driver_hashes.items():
            if file_digest(ROOT / relative) != expected:
                raise ValueError(f"Benchmark driver changed: {relative}")
        for variant, manifest in self.manifests.items():
            for name, record in manifest["staged"].items():
                if file_digest(self.output / "packages" / variant / name) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{name}")

    def build_and_verify(self):
        reference = None
        comparisons = []
        for configuration in (["debug", "release"] if self.args.mode == "all" else ["release"]):
            for variant in ["baseline", "candidate"]:
                self.check_sources()
                print(f"Build/verify {variant} {configuration}", flush=True)
                if self.args.mode == "all":
                    label = f"tests-{variant}-{configuration}"
                    self.command(self.swift_command(variant, "test", configuration)
                                 + ["--no-parallel", "--disable-xctest", "--enable-swift-testing"], label)
                    log = (self.output / "logs" / (label + ".log")).read_text()
                    counts = re.findall(r"Test run with (\d+) tests?\b", log)
                    if not counts or int(counts[-1]) == 0:
                        raise ValueError("No completed Swift Testing test count was reported")
                    self.tests.append({"variant": variant, "configuration": configuration,
                                       "count": int(counts[-1]), "passed": True})
                    save(self.output / "tests.json", self.tests)
                    print("TEST " + json.dumps(self.tests[-1], sort_keys=True), flush=True)
                if configuration == "debug":
                    continue
                self.command(self.swift_command(variant, "build", configuration)
                             + ["--product", PRODUCT], f"build-{variant}-{configuration}")
                directory = self.command(self.swift_command(variant, "build", configuration)
                                         + ["--show-bin-path"], f"bin-path-{variant}-{configuration}").strip()
                binary = Path(directory) / PRODUCT
                key = f"{variant}-{configuration}"
                self.binaries[key], self.binary_hashes[key] = binary, file_digest(binary)
                trace_output = self.command([binary, "verify"], "verify-" + key, timeout=180)
                trace = json.loads(trace_output)
                if reference is None:
                    reference = trace
                elif trace != reference:
                    raise ValueError(f"Complete deterministic verification trace differs: {key}")
                comparisons.append({"variant": variant, "configuration": configuration,
                                    "complete_trace_equal": True,
                                    "trace_log": "logs/verify-" + key + ".log",
                                    "trace_stdout_sha256": digest(trace_output.encode())})
        if self.tests and len({record["count"] for record in self.tests}) != 1:
            raise ValueError("Baseline/candidate debug/release test counts differ")
        inventories = {
            variant: json.loads(self.command([self.binaries[variant + "-release"], "cases"], "cases-" + variant))
            for variant in ["baseline", "candidate"]
        }
        if inventories["baseline"] != inventories["candidate"]:
            raise ValueError("Baseline/candidate workload inventory differs")
        self.cases = inventories["baseline"]
        if not self.cases or len({case["name"] for case in self.cases}) != len(self.cases):
            raise ValueError("Workload inventory must be nonempty and uniquely named")
        if any(not re.fullmatch(r"[a-z0-9_]+", case["name"]) for case in self.cases):
            raise ValueError("Unsafe workload name")
        save(self.output / "cases.json", self.cases)
        save(self.output / "tests.json", self.tests)
        save(self.output / "parity.json", comparisons)
        save(self.output / "binaries.json", {
            key: {"path": str(binary), "sha256": self.binary_hashes[key]}
            for key, binary in self.binaries.items()
        })
        print("PARITY " + json.dumps({"complete_trace_equal": True, "binaries": len(comparisons),
                                      "cases": len(self.cases)}, sort_keys=True), flush=True)

    def sample(self, variant, case, iterations, label):
        value = json.loads(self.command(
            [self.binaries[variant + "-release"], "measure", case["name"], iterations], label, timeout=90))
        if value["case"] != case["name"] or value["iterations"] != iterations:
            raise ValueError("Measurement request/response mismatch")
        operations = value["operations_per_iteration"]
        if operations != case["operations_per_iteration"] or operations <= 0:
            raise ValueError("Invalid operation count")
        if value["operation_count"] != operations * iterations or value["warmup_iterations"] != 2:
            raise ValueError("Incomplete measurement or unexpected warmup")
        for metric in ["wall_ns", "cpu_ns"]:
            if not math.isfinite(value[metric]) or value[metric] <= 0:
                raise ValueError(f"Invalid {metric}")
        return value

    def measure(self):
        summaries, calibrations = [], []
        for case in self.cases:
            name, iterations = case["name"], 1
            calibration_samples = []
            target = self.args.target_ms * 1e6
            for attempt in range(6):
                values = {
                    variant: self.sample(variant, case, iterations, f"calibrate-{name}-{attempt}-{variant}")
                    for variant in ["baseline", "candidate"]
                }
                if values["baseline"]["checksum"] != values["candidate"]["checksum"]:
                    raise ValueError("Calibration output checksums differ")
                calibration_samples.append({"iterations": iterations, "observations": values})
                fastest = min(value["wall_ns"] for value in values.values())
                if fastest >= target * 1.25:
                    break
                next_iterations = max(iterations + 1, math.ceil(iterations * target * 1.5 / fastest))
                iterations = min(100000, next_iterations)
            else:
                raise ValueError(f"Could not calibrate a sufficiently long sample: {name}")
            calibrations.append({"case": name, "iterations": iterations, "samples": calibration_samples})
            save(self.output / "calibration.json", calibrations)
            paired, times = {"wall": [], "cpu": []}, {
                variant: {"wall": [], "cpu": []} for variant in ["baseline", "candidate"]
            }
            below_target = 0
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                results = {}
                for position, variant in enumerate(order):
                    value = self.sample(variant, case, iterations, f"measure-{name}-{pair}-{variant}")
                    record = dict(value, variant=variant, pair=pair, execution_position=position, execution_order=order)
                    with (self.output / "measurements.jsonl").open("a") as output:
                        output.write(json.dumps(record, sort_keys=True) + "\n")
                    results[variant] = value
                    below_target += value["wall_ns"] < target
                    for metric in paired:
                        times[variant][metric].append(value[metric + "_ns"] / iterations)
                if results["baseline"]["checksum"] != results["candidate"]["checksum"]:
                    raise ValueError("Timed output checksums differ")
                for metric in paired:
                    paired[metric].append(times["candidate"][metric][-1] / times["baseline"][metric][-1])
            summary = dict(case, pairs=self.args.pairs, iterations=iterations, samples_below_target=below_target)
            for metric in paired:
                a, b = times["baseline"][metric], times["candidate"][metric]
                summary[metric] = {
                    "baseline_median_ns_per_iteration": statistics.median(a),
                    "candidate_median_ns_per_iteration": statistics.median(b),
                    "baseline_median_ns_per_operation": statistics.median(a) / case["operations_per_iteration"],
                    "candidate_median_ns_per_operation": statistics.median(b) / case["operations_per_iteration"],
                    "baseline_range_ns_per_iteration": [min(a), max(a)],
                    "candidate_range_ns_per_iteration": [min(b), max(b)],
                    "paired_ratios": paired[metric],
                    "median_paired_ratio": statistics.median(paired[metric]),
                    "paired_ratio_range": [min(paired[metric]), max(paired[metric])],
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(paired[metric])),
                    "faster_pairs": sum(ratio < 1 for ratio in paired[metric]),
                }
            summaries.append(summary)
            save(self.output / "summary.json", summaries)
            print("SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)

    def finish(self):
        self.check_sources()
        for key, binary in self.binaries.items():
            if file_digest(binary) != self.binary_hashes[key]:
                raise ValueError(f"Measured binary changed: {key}")
        completion = {"completed": True, "mode": self.args.mode, "case_count": len(self.cases),
                      "tests_executed": bool(self.tests), "sources_and_binaries_unchanged": True}
        save(self.output / "completion.json", completion)
        print("COMPLETION " + json.dumps(completion, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=120)
    parser.add_argument("--mode", choices=["all", "benchmark"], default="all")
    parser.add_argument("--kyoto-job", action="store_true",
                        help="The complete runner was submitted through the shared Kyoto queue")
    args = parser.parse_args()
    if platform.system() not in {"Darwin", "Linux"}:
        parser.error("Only macOS and Linux are supported")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.baseline):
        parser.error("--baseline must be a full commit SHA")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be even and between 2 and 20")
    if not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 1000:
        parser.error("--target-ms must be finite and between 10 and 1000")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.build_and_verify()
        runner.measure()
        runner.finish()
    except Exception as error:
        save(runner.output / "completion.json", {"completed": False, "error": str(error)})
        raise


if __name__ == "__main__":
    main()
