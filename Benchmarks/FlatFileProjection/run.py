#!/usr/bin/env python3
"""Qualify complete flat-file row construction against pinned main, without network dependencies."""
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
BASELINE = "070c7a4c84a4f00b2ac3e17587a7b5f3857952fd"
CASES = ["folders-files", "folders-media", "mixed-files", "mixed-media", "explicit-files", "explicit-media"]
TESTS = ["SourceBrowserFilterTests.swift", "SourceMediaOrganizationTests.swift", "FlatFileProjectionTests.swift"]
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
spec = importlib.util.spec_from_file_location("source_tree_staging", HELPER)
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
PACKAGE = staging.PACKAGE.replace("SourceTreeVisibilityQualification", "FlatFileProjectionQualification").replace(
    "SourceTreeBenchmark", "FlatFileProjectionBenchmark")


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


def adapt(relative, raw):
    if platform.system() != "Linux":
        return raw, []
    changes = {
        "MediaSidecarReader.swift": (b"import Darwin\n", b"import Glibc\n"),
        "NFOMetadataHints.swift": (b"import Foundation\n", b"import Foundation\nimport FoundationXML\n"),
        "SourceMediaOrganizationTests.swift": (
            b'appendingPathComponent("media-sidecars-" + UUID().uuidString)',
            b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'),
    }
    if Path(relative).name not in changes:
        return raw, []
    before, after = changes[Path(relative).name]
    if raw.count(before) != 1:
        raise ValueError(f"Linux adaptation boundary changed: {relative}")
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
        self.manifests, self.binaries, self.commands, self.binary_hashes = {}, {}, [], {}

    def command(self, argv, label, output=None):
        argv = [str(value) for value in argv]
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=1200)
        destination = output or self.output / "logs" / (label + ".log")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(result.stdout if output else result.stdout + result.stderr)
        self.commands.append({"label": label, "argv": argv, "returncode": result.returncode,
                              "stdout_log": str(destination.relative_to(self.output)), "stderr": result.stderr})
        save(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"{label} failed: {(result.stdout + result.stderr)[-10000:]}")
        return result.stdout

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.output / variant,
                   "--scratch-path", self.output / "build" / variant, "--cache-path", self.output / "swiftpm-cache",
                   "--config-path", self.output / "swiftpm-config", "--security-path", self.output / "swiftpm-security",
                   "--jobs", "2", "--configuration", configuration]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def prepare(self):
        baseline_files, baseline_records = staging.snapshot(lambda name: subprocess.check_output(
            ["git", "show", f"{self.args.baseline}:{name}"], cwd=ROOT))
        candidate_files, candidate_records = staging.snapshot(lambda name: (ROOT / name).read_bytes())
        shared_dependencies = staging.share_current_dependencies(
            baseline_files, baseline_records, candidate_files, candidate_records)
        for name in baseline_files:
            if not name.endswith("/SourceTreeProjectionInput.swift") and baseline_files[name] != candidate_files[name]:
                raise ValueError(f"Unrelated staged production source changed: {name}")
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            files["Package.swift"] = PACKAGE.encode()
            files["Sources/FlatFileProjectionBenchmark/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            for name in TESTS:
                files["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            manifest = {"production": records, "shared_dependencies": shared_dependencies, "staged": {}}
            for name, raw in files.items():
                compiled, adaptations = adapt(name, raw)
                path = self.output / variant / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(compiled)
                manifest["staged"][name] = {"source_sha256": digest(raw), "compiled_sha256": digest(compiled),
                                            "adaptations": adaptations}
            self.manifests[variant] = manifest
        save(self.output / "sources.json", self.manifests)
        for source, name in [(Path(__file__), "runner.py"), (HELPER, "staging-helper.py"), (HERE / "Harness.swift", "Harness.swift")]:
            shutil.copyfile(source, self.output / name)
        compiler_dir = Path(self.swift).parent
        if platform.system() == "Darwin":
            compiler_dir = Path(self.command(["xcrun", "--find", "swiftc"], "selected-swiftc").strip()).parent
        compiler_paths = [Path(self.swift), compiler_dir / "swiftc", compiler_dir / "swift-frontend"]
        environment = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "architecture": platform.machine(), "python": sys.version,
            "swift": self.command([self.swift, "--version"], "swift-version").strip(),
            "compiler_sha256": {str(path): file_digest(path) for path in compiler_paths if path.is_file()},
            "baseline": self.args.baseline, "head": self.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "worktree": self.command(["git", "status", "--short"], "worktree"),
            "driver_sha256": {name: file_digest(self.output / name) for name in ["runner.py", "staging-helper.py", "Harness.swift"]},
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.args).items()},
            "measurement": "Complete rows() calls after two warmups. Fixture setup, result consumption and returned-row destruction excluded. CPU clock surrounds wall timer.",
            "sampling": "Fresh process per member, balanced AB/BA pairs; identical iterations; retain all observations.",
            "fixtures": "Four Unicode folder roots; shuffled names; preloaded media metadata; duplicate explicit items in controls. Explicit Files Only has no loaded entries; explicit Media has loaded metadata.",
            "logical_cpus": os.cpu_count(), "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        }
        if platform.system() == "Darwin":
            environment["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model").strip()
            environment["macos"] = self.command(["sw_vers"], "macos-version").strip()
        save(self.output / "environment.json", environment)

    def build_and_verify(self):
        tests = []
        for configuration in (["debug", "release"] if self.args.mode != "benchmark" else ["release"]):
            for variant in ["baseline", "candidate"]:
                print(f"{variant}: {configuration}", flush=True)
                command = self.swift_command(variant, "test" if self.args.mode != "benchmark" else "build", configuration)
                if self.args.mode != "benchmark":
                    label = f"tests-{variant}-{configuration}"
                    self.command(command + ["--no-parallel", "--disable-xctest", "--enable-swift-testing"], label)
                    result = (self.output / "logs" / (label + ".log")).read_text()
                    counts = re.findall(r"Test run with (\d+) tests?\b", result)
                    if not counts or int(counts[-1]) == 0:
                        raise ValueError("No successful Swift Testing test count was reported")
                    tests.append({"variant": variant, "configuration": configuration, "count": int(counts[-1])})
                else:
                    self.command(command + ["--product", "FlatFileProjectionBenchmark"], "build-" + variant)
                if configuration == "release":
                    self.command(self.swift_command(variant, "build", configuration)
                                 + ["--product", "FlatFileProjectionBenchmark"], "release-product-" + variant)
                    binary_dir = self.command(self.swift_command(variant, "build", configuration) + ["--show-bin-path"], "bin-path-" + variant).strip()
                    self.binaries[variant] = Path(binary_dir) / "FlatFileProjectionBenchmark"
        save(self.output / "tests.json", tests)
        self.binary_hashes = {name: file_digest(path) for name, path in self.binaries.items()}
        save(self.output / "binaries.json", {name: {"path": str(path), "sha256": self.binary_hashes[name]} for name, path in self.binaries.items()})
        comparisons = []
        for size in self.args.sizes:
            for case in self.args.cases:
                traces = {}
                for variant, binary in self.binaries.items():
                    label = f"verify-{case}-{size}-{variant}"
                    traces[variant] = json.loads(self.command([binary, "verify", case, size], label,
                        self.output / "traces" / f"{label}.json"))
                if traces["baseline"] != traces["candidate"]:
                    raise ValueError(f"Complete output trace differs: {case}/{size}")
                comparisons.append({"case": case, "size": size, "complete_rows_equal": True, "rows": len(traces["baseline"]["rows"])})
        save(self.output / "parity.json", comparisons)

    def measure(self):
        observations, summaries, calibrations = [], [], []
        for size in self.args.sizes:
            for case in self.args.cases:
                def sample(variant, iterations, label):
                    value = json.loads(self.command([self.binaries[variant], "measure", case, size, iterations], label))
                    if value["mode"] != "measure" or value["case"] != case or value["size"] != size or value["iterations"] != iterations or len(value["wall_ns"]) != iterations or len(value["cpu_ns"]) != iterations:
                        raise ValueError("Incomplete measurement")
                    if any(not math.isfinite(x) or x <= 0 for x in value["wall_ns"] + value["cpu_ns"]):
                        raise ValueError("Invalid wall/CPU duration")
                    return value
                calibration = {variant: sample(variant, 1, f"calibrate-{case}-{size}-{variant}") for variant in self.binaries}
                fastest = min(value["wall_ns"][0] for value in calibration.values())
                iterations = max(1, min(1000, math.ceil(self.args.target_ms * 1e6 / fastest)))
                calibrations.append({"case": case, "size": size, "iterations": iterations, "observations": calibration})
                times = {variant: {"wall": [], "cpu": []} for variant in self.binaries}
                paired = {metric: [] for metric in ["wall", "cpu"]}
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    results = {}
                    for position, variant in enumerate(order):
                        value = sample(variant, iterations, f"measure-{case}-{size}-{pair}-{variant}")
                        observations.append(dict(value, variant=variant, pair=pair, execution_position=position, execution_order=order))
                        results[variant] = value
                        for metric in times[variant]:
                            times[variant][metric].append(statistics.mean(value[metric + "_ns"]))
                    if results["baseline"]["checksum"] != results["candidate"]["checksum"]:
                        raise ValueError("Timed consumption differs")
                    for metric in paired:
                        a, b = times["baseline"][metric][-1], times["candidate"][metric][-1]
                        paired[metric].append(100 * (b / a - 1))
                    save(self.output / "observations.json", observations)
                summary = {"case": case, "size": size, "pairs": self.args.pairs, "iterations": iterations}
                for metric in paired:
                    a, b = times["baseline"][metric], times["candidate"][metric]
                    summary[metric] = {"baseline_median_ns": statistics.median(a), "candidate_median_ns": statistics.median(b),
                        "baseline_range_ns": [min(a), max(a)], "candidate_range_ns": [min(b), max(b)],
                        "paired_change_percent": paired[metric], "median_paired_change_percent": statistics.median(paired[metric]),
                        "faster_pairs": sum(change < 0 for change in paired[metric])}
                summaries.append(summary)
                save(self.output / "calibration.json", calibrations)
                save(self.output / "summary.json", summaries)
                print(f"{case:16} {size:6}: {summary['wall']['median_paired_change_percent']:+.1f}% paired wall change", flush=True)

    def finish(self):
        for variant, manifest in self.manifests.items():
            for name, record in manifest["staged"].items():
                if file_digest(self.output / variant / name) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{name}")
        for variant, binary in self.binaries.items():
            if file_digest(binary) != self.binary_hashes[variant]:
                raise ValueError(f"Timed binary changed: {variant}")
        for original, archived in [(Path(__file__), "runner.py"), (HELPER, "staging-helper.py"), (HERE / "Harness.swift", "Harness.swift")]:
            if file_digest(original) != file_digest(self.output / archived):
                raise ValueError(f"Benchmark driver changed: {original}")
        save(self.output / "completion.json", {"completed": True, "mode": self.args.mode, "exploratory": self.args.quick})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--sizes", type=int, nargs="+", default=[100, 1000, 10000])
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--mode", choices=["all", "verify", "benchmark"], default="all")
    parser.add_argument("--quick", action="store_true", help="Exploratory 100-entry, two-pair smoke")
    args = parser.parse_args()
    if args.quick:
        args.sizes, args.pairs, args.target_ms = [100], 2, 10
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.baseline):
        parser.error("--baseline must be a full commit SHA")
    if args.pairs < 2 or args.pairs % 2 or args.pairs > 20 or any(size < 1 or size > 100000 for size in args.sizes):
        parser.error("Use 2...20 even pairs and sizes in 1...100000")
    if not math.isfinite(args.target_ms) or not 1 <= args.target_ms <= 1000:
        parser.error("--target-ms must be in 1...1000")
    runner = Runner(args)
    runner.prepare()
    runner.build_and_verify()
    if args.mode != "verify":
        runner.measure()
    runner.finish()
    print(f"Complete: {runner.output}", flush=True)


if __name__ == "__main__":
    main()
