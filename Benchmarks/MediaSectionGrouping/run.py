#!/usr/bin/env python3
"""Test and measure full cached media projection using exact production sources."""
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
BASELINE = "6dc482129373da1c611b6e8cc7ea7906c381912c"
SNAPSHOT_HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
CASES = ["movies", "seasons", "unicode_groups", "unique_sections",
         "broad_search", "narrow_search", "files_control", "tree_control"]
TESTS = ["SourceBrowserFilterTests.swift", "SourceBrowserSearchTests.swift",
         "SourceMediaOrganizationTests.swift", "SourceMediaGroupingTests.swift"]


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_snapshot_helper():
    spec = importlib.util.spec_from_file_location("media_grouping_source_snapshot", SNAPSHOT_HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory; evidence is never overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        for variable, name in [("CLANG_MODULE_CACHE_PATH", "clang"),
                               ("SWIFTPM_MODULECACHE_OVERRIDE", "swift")]:
            path = self.output / "cache" / name
            path.mkdir(parents=True)
            self.env[variable] = str(path)
        self.swift = args.swift or shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift 6.1+ is required; supply --swift or put swift on PATH")
        self.packages = {variant: self.output / "packages" / variant for variant in ["baseline", "candidate"]}
        self.manifests, self.binaries, self.oracles = {}, {}, {}
        self.commands = 0

    def execute(self, command, label, timeout=1200):
        command = [str(value) for value in command]
        log = self.output / "logs" / label
        log.parent.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        stdout_path, stderr_path = log.with_suffix(".stdout"), log.with_suffix(".stderr")
        stdout_path.write_text(result.stdout); stderr_path.write_text(result.stderr)
        record = {"label": label, "command": command, "returncode": result.returncode,
                  "seconds": time.monotonic() - started,
                  "stdout": str(stdout_path.relative_to(self.output)),
                  "stderr": str(stderr_path.relative_to(self.output)),
                  "stdout_sha256": digest(result.stdout.encode()),
                  "stderr_sha256": digest(result.stderr.encode())}
        with (self.output / "commands.jsonl").open("a") as log_file:
            log_file.write(json.dumps(record, sort_keys=True) + "\n")
        self.commands += 1
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n" + (result.stdout + result.stderr)[-10000:])
        return result, stdout_path

    def prepare(self):
        helper = load_snapshot_helper()
        baseline_files, baseline_records = helper.snapshot(
            lambda path: subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT))
        candidate_files, candidate_records = helper.snapshot(lambda path: (ROOT / path).read_bytes())
        for name in baseline_files:
            if name != "Sources/IlliquidApp/SourceBrowserFilter.swift" and baseline_files[name] != candidate_files[name]:
                raise ValueError(f"Unrelated production dependency changed: {name}")
        package_text = helper.PACKAGE.replace("SourceTreeVisibilityQualification", "MediaSectionGroupingQualification")
        package_text = package_text.replace("SourceTreeBenchmark", "MediaSectionBenchmark")
        driver = (HERE / "Harness.swift").read_bytes()
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            staged = dict(files)
            staged["Sources/MediaSectionBenchmark/Harness.swift"] = driver
            staged["Package.swift"] = package_text.encode()
            for name in TESTS:
                staged[f"Tests/IlliquidAppTests/{name}"] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            manifest = {"variant": variant, "baseline_revision": BASELINE,
                        "production": records, "staged": {}, "adaptations": []}
            for relative, raw in staged.items():
                compiled = raw
                if platform.system() == "Linux":
                    before, after = None, None
                    if relative.endswith("/MediaSidecarReader.swift"):
                        before, after = b"import Darwin\n", b"import Glibc\n"
                    elif relative.endswith("/NFOMetadataHints.swift"):
                        before, after = b"import Foundation\n", b"import Foundation\nimport FoundationXML\n"
                    elif relative.endswith("/SourceMediaOrganizationTests.swift"):
                        before = b'appendingPathComponent("media-sidecars-" + UUID().uuidString)'
                        after = b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'
                    if before is not None:
                        if raw.count(before) != 1:
                            raise ValueError(f"Linux compatibility boundary changed: {relative}")
                        compiled = raw.replace(before, after, 1)
                        manifest["adaptations"].append({"path": relative, "before": before.decode(), "after": after.decode()})
                destination = self.packages[variant] / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(compiled)
                manifest["staged"][relative] = {"source_sha256": digest(raw), "compiled_sha256": digest(compiled)}
            self.manifests[variant] = manifest
            write_json(self.output / f"{variant}-sources.json", manifest)
        driver_hashes = {}
        for name, source in [("run.py", Path(__file__)), ("Harness.swift", HERE / "Harness.swift"),
                             ("source-snapshot-helper.py", SNAPSHOT_HELPER)]:
            data = source.read_bytes()
            (self.output / name).write_bytes(data)
            driver_hashes[name] = digest(data)
        environment = {"started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "platform": platform.platform(), "machine": platform.machine(),
                       "python": sys.version, "cpu_count": os.cpu_count(),
                       "swift": self.execute([self.swift, "--version"], "swift-version")[0].stdout.strip(),
                       "head": self.execute(["git", "rev-parse", "HEAD"], "head")[0].stdout.strip(),
                       "worktree": self.execute(["git", "status", "--short"], "worktree")[0].stdout,
                       "baseline": BASELINE, "driver_hashes": driver_hashes,
                       "cases": self.args.cases, "sizes": self.args.sizes,
                       "pairs": self.args.pairs, "target_ms": self.args.target_ms,
                       "timing": "Complete warm-cache actor.project(input:) loop; output checks and fixtures excluded",
                       "fixture": "Synthetic local URLs with actual recognition prepopulated; no timed filesystem I/O"}
        if Path("/proc/cpuinfo").exists():
            environment["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
        if sys.platform == "darwin":
            environment["cpu_model"] = self.execute(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model")[0].stdout.strip()
            environment["macos"] = self.execute(["sw_vers"], "macos")[0].stdout.strip()
        write_json(self.output / "environment.json", environment)

    def swift_command(self, variant, action, configuration):
        result = [self.swift, action, "--package-path", self.packages[variant],
                  "--scratch-path", self.output / "build" / variant,
                  "--cache-path", self.output / "cache" / "packages",
                  "--config-path", self.output / "cache" / "config",
                  "--security-path", self.output / "cache" / "security",
                  "--jobs", str(self.args.jobs), "--configuration", configuration]
        if sys.platform == "linux":
            result.append("--use-integrated-swift-driver")
        return result

    def test(self):
        records = []
        for configuration in ["debug", "release"]:
            for variant in ["baseline", "candidate"]:
                print(f"Testing {variant} {configuration}", flush=True)
                command = self.swift_command(variant, "test", configuration) + ["--no-parallel", "-Xswiftc", "-warnings-as-errors"]
                result, _ = self.execute(command, f"tests-{variant}-{configuration}")
                counts = re.findall(r"Test run with (\d+) tests?", result.stdout + result.stderr)
                if not counts or int(counts[-1]) == 0:
                    raise ValueError("No completed Swift Testing tests were reported")
                records.append({"variant": variant, "configuration": configuration, "count": int(counts[-1]), "passed": True})
        write_json(self.output / "tests.json", records)

    def build_and_verify(self):
        builds = {}
        for variant in ["baseline", "candidate"]:
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "MediaSectionBenchmark", "-Xswiftc", "-whole-module-optimization"], f"build-{variant}")
            directory = self.execute(command + ["--show-bin-path"], f"bin-path-{variant}")[0].stdout.strip()
            self.binaries[variant] = Path(directory) / "MediaSectionBenchmark"
            builds[variant] = {"path": str(self.binaries[variant]), "sha256": digest(self.binaries[variant].read_bytes())}
        write_json(self.output / "binaries.json", builds)
        verification = []
        for size in self.args.sizes:
            for scenario in self.args.cases:
                traces, paths = {}, {}
                for variant in ["baseline", "candidate"]:
                    result, paths[variant] = self.execute([self.binaries[variant], "verify", scenario, size], f"verify-{scenario}-{size}-{variant}")
                    traces[variant] = json.loads(result.stdout)
                if traces["baseline"] != traces["candidate"]:
                    raise ValueError(f"Complete projection differs: {scenario}/{size}")
                self.oracles[(scenario, size)] = paths["baseline"]
                verification.append({"case": scenario, "size": size, "complete_output_equal": True,
                                     "rows": len(traces["baseline"]["rows"]),
                                     "trace_sha256": digest(paths["baseline"].read_bytes()),
                                     "trace": str(paths["baseline"].relative_to(self.output))})
        write_json(self.output / "verification.json", verification)

    def measure(self, variant, scenario, size, iterations, label):
        result, _ = self.execute([self.binaries[variant], "measure", scenario, size, iterations,
                                  self.oracles[(scenario, size)]], label)
        row = json.loads(result.stdout)
        if (row["case"], row["size"], row["iterations"]) != (scenario, size, iterations):
            raise ValueError("Measurement identity mismatch")
        if not row["complete_output_verified"] or min(row["elapsed_ns"], row["cpu_ns"]) <= 0:
            raise ValueError("Invalid timing or output verification")
        row.update(variant=variant, label=label)
        return row

    def benchmark(self):
        rows = []
        for case_index, scenario in enumerate(self.args.cases):
            for size in self.args.sizes:
                calibration = []
                for variant in ["baseline", "candidate"]:
                    row = self.measure(variant, scenario, size, 1, f"calibrate-{scenario}-{size}-{variant}")
                    calibration.append(row)
                    with (self.output / "calibration.jsonl").open("a") as log:
                        log.write(json.dumps(row, sort_keys=True) + "\n")
                fastest = min(row["elapsed_ns"] for row in calibration)
                iterations = min(65_536, max(1, math.ceil(self.args.target_ms * 1_000_000 / fastest)))
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if (pair + case_index) % 2 == 0 else ["candidate", "baseline"]
                    pair_rows = []
                    for variant in order:
                        row = self.measure(variant, scenario, size, iterations, f"pair-{scenario}-{size}-{pair:02d}-{variant}")
                        row.update(pair=pair, order=order)
                        rows.append(row); pair_rows.append(row)
                        with (self.output / "measurements.jsonl").open("a") as log:
                            log.write(json.dumps(row, sort_keys=True) + "\n")
                    for key in ["checksum", "rows", "sections", "iterations", "warmup"]:
                        if pair_rows[0][key] != pair_rows[1][key]:
                            raise ValueError(f"Paired receipt differs: {key}")
                print(f"Measured {scenario}/{size}: {self.args.pairs} pairs × {iterations} operations", flush=True)
        summaries = []
        for scenario in self.args.cases:
            for size in self.args.sizes:
                selected = [row for row in rows if row["case"] == scenario and row["size"] == size]
                summary = {"case": scenario, "size": size, "pairs": self.args.pairs}
                for metric in ["elapsed_ns", "cpu_ns"]:
                    values = {variant: [row[metric] / row["iterations"] for row in selected if row["variant"] == variant]
                              for variant in ["baseline", "candidate"]}
                    changes = []
                    for pair in range(self.args.pairs):
                        match = {row["variant"]: row for row in selected if row["pair"] == pair}
                        changes.append((match["candidate"][metric] / match["baseline"][metric] - 1) * 100)
                    summary[metric] = {variant: {"median": statistics.median(value), "min": min(value), "max": max(value)}
                                       for variant, value in values.items()}
                    summary[metric].update(paired_change_percent=changes,
                        median_paired_change_percent=statistics.median(changes),
                        faster_pairs=sum(change < 0 for change in changes))
                summaries.append(summary)
        write_json(self.output / "summary.json", summaries)

    def check_sources(self):
        for variant, manifest in self.manifests.items():
            for relative, record in manifest["staged"].items():
                if digest((self.packages[variant] / relative).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{relative}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--mode", choices=["all", "tests", "benchmark", "verify", "prepare"], default="all")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--sizes", nargs="+", type=int, default=[100, 1000, 10000])
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=60)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or min(args.sizes) < 1 or args.target_ms <= 0 or args.jobs < 1:
        parser.error("Use positive sizes/jobs/target-ms and a positive even pair count of at least two")
    runner = Runner(args)
    runner.prepare()
    if args.mode in {"all", "tests"}:
        runner.test()
    if args.mode in {"all", "benchmark", "verify"}:
        runner.build_and_verify()
    if args.mode in {"all", "benchmark"}:
        runner.benchmark()
    runner.check_sources()
    write_json(runner.output / "completion.json", {"mode": args.mode, "complete": True, "commands": runner.commands})
    print(f"Completed {args.mode}: {runner.output}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
