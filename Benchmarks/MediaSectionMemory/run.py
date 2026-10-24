#!/usr/bin/env python3
"""Measure complete production media projections before allocating output traces."""
from __future__ import annotations

import argparse
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
SNAPSHOT_HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
CASES = ["movies", "seasons", "unicode_groups", "unique_sections",
         "broad_search", "narrow_search", "files_control", "tree_control"]
TESTS = ["SourceBrowserFilterTests.swift", "SourceBrowserSearchTests.swift",
         "SourceMediaOrganizationTests.swift", "SourceMediaGroupingTests.swift",
         "MediaSectionGroupingMemoryTests.swift"]
RSS_METRICS = ["process_peak_rss_before_bytes", "process_peak_rss_after_bytes",
               "process_peak_rss_growth_bytes"]


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def files_equal(left, right):
    with left.open("rb") as a, right.open("rb") as b:
        while True:
            first, second = a.read(1024 * 1024), b.read(1024 * 1024)
            if first != second:
                return False
            if not first:
                return True


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, args):
        self.args, self.output = args, args.output.resolve()
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
        self.packages = {v: self.output / "packages" / v for v in ["baseline", "candidate"]}
        self.manifests, self.binaries, self.oracles, self.source_hashes = {}, {}, {}, {}
        self.commands = 0

    def execute(self, command, label, timeout=1200, read=True):
        command = [str(value) for value in command]
        stdout, stderr = self.output / "logs" / (label + ".stdout"), self.output / "logs" / (label + ".stderr")
        stdout.parent.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        # Stream even verification JSON to disk. The parent never retains full
        # traces that could inflate a forked child's initial resident footprint.
        with stdout.open("wb") as out, stderr.open("wb") as err:
            result = subprocess.run(command, cwd=ROOT, env=self.env, stdout=out, stderr=err, timeout=timeout)
        record = {"label": label, "command": command, "returncode": result.returncode,
                  "seconds": time.monotonic() - started,
                  "stdout": str(stdout.relative_to(self.output)), "stderr": str(stderr.relative_to(self.output)),
                  "stdout_sha256": file_digest(stdout), "stderr_sha256": file_digest(stderr)}
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps(record, sort_keys=True) + "\n")
        self.commands += 1
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n" + stderr.read_text()[-10000:])
        return (stdout.read_text() if read else None), stdout

    def prepare(self):
        spec = importlib.util.spec_from_file_location("media_memory_snapshot", SNAPSHOT_HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        baseline_files, baseline_records = helper.snapshot(
            lambda path: subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT))
        candidate_files, candidate_records = helper.snapshot(lambda path: (ROOT / path).read_bytes())
        head = self.execute(["git", "rev-parse", "HEAD"], "head")[0].strip()
        baseline_files, baseline_records, candidate_records, comparison = helper.comparison_sources(
            baseline_files, baseline_records, candidate_files, candidate_records,
            focal_sources={"Sources/IlliquidApp/SourceBrowserFilter.swift"},
            baseline_revision=BASELINE, worktree_head=head,
            current_support=self.args.current_support)
        for name in baseline_files:
            if name != "Sources/IlliquidApp/SourceBrowserFilter.swift" and baseline_files[name] != candidate_files[name]:
                raise ValueError(f"Unrelated production dependency changed: {name}")
        for record in candidate_records.values():
            self.source_hashes[record["repository_path"]] = record["source_sha256"]
        package = helper.PACKAGE.replace("SourceTreeVisibilityQualification", "MediaSectionMemoryQualification")
        package = package.replace("SourceTreeBenchmark", "MediaSectionMemoryBenchmark")
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            staged = dict(files)
            staged["Sources/MediaSectionMemoryBenchmark/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            staged["Package.swift"] = package.encode()
            for name in TESTS:
                path = "Tests/IlliquidAppTests/" + name
                staged[path] = (ROOT / path).read_bytes()
                self.source_hashes[path] = digest(staged[path])
            manifest = {"variant": variant, "baseline_revision": BASELINE, "comparison": comparison,
                        "production": records, "staged": {}, "adaptations": []}
            for relative, raw in staged.items():
                compiled, before, after = raw, None, None
                if sys.platform == "linux":
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
        drivers = {}
        for name, path in [("run.py", Path(__file__)), ("Harness.swift", HERE / "Harness.swift"),
                           ("source-snapshot-helper.py", SNAPSHOT_HELPER)]:
            raw = path.read_bytes()
            (self.output / name).write_bytes(raw)
            drivers[name] = digest(raw)
            self.source_hashes[str(path.relative_to(ROOT))] = digest(raw)
        environment = {"started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
                       "swift": self.execute([self.swift, "--version"], "swift-version")[0].strip(),
                       "cpu_count": os.cpu_count(), "head": head, "comparison": comparison,
                       "baseline": BASELINE, "driver_hashes": drivers,
                       "worktree": self.execute(["git", "status", "--short"], "worktree")[0],
                       "cases": self.args.cases, "sizes": self.args.sizes, "pairs": self.args.pairs,
                       "measurements": self.args.measurements, "refresh_iterations": self.args.refresh_iterations,
                       "exploratory": self.args.smoke, "mode": self.args.mode,
                       "memory": "getrusage process high-water RSS before and immediately after projection; includes runtime, fixtures, cached rows and output; not whole-player memory",
                       "growth_caveat": "Difference of process high-water marks, not current RSS, live allocations, or bytes allocated",
                       "timing": "Awaited full actor.project(input:) loop plus O(1) receipts and final getrusage; all trace/oracle work follows RSS sampling",
                       "cold": "One first projection with a fresh actor after fixture construction",
                       "refresh": "One untimed priming projection, then repeated cache hits while retaining previous output during replacement",
                       "ordering": "Balanced AB/BA fresh-process pairs; all samples retained",
                       "verification": "Separate exact streamed UTF-8 trace equality, plus byte-identical sorted-key JSON for the full final projection after every measured process sample"}
        if Path("/proc/cpuinfo").exists():
            environment["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
            environment["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        elif sys.platform == "darwin":
            environment["cpu_model"] = self.execute(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model")[0].strip()
            environment["macos"] = self.execute(["sw_vers"], "macos")[0].strip()
        write_json(self.output / "environment.json", environment)

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.packages[variant],
                   "--scratch-path", self.output / "build" / variant,
                   "--cache-path", self.output / "cache" / "packages",
                   "--config-path", self.output / "cache" / "config",
                   "--security-path", self.output / "cache" / "security",
                   "--jobs", str(self.args.jobs), "--configuration", configuration]
        return command + (["--use-integrated-swift-driver"] if sys.platform == "linux" else [])

    def test(self):
        records = []
        for configuration in ["debug", "release"]:
            for variant in ["baseline", "candidate"]:
                print(f"Testing {variant} {configuration}", flush=True)
                command = self.swift_command(variant, "test", configuration) + ["--no-parallel", "-Xswiftc", "-warnings-as-errors"]
                output, path = self.execute(command, f"tests-{variant}-{configuration}")
                counts = re.findall(r"Test run with (\d+) tests?", output + path.with_suffix(".stderr").read_text())
                if not counts or int(counts[-1]) == 0:
                    raise ValueError("No completed Swift Testing tests were reported")
                records.append({"variant": variant, "configuration": configuration, "count": int(counts[-1]), "passed": True})
        write_json(self.output / "tests.json", records)

    def build_and_verify(self):
        binaries, verification = {}, []
        for variant in ["baseline", "candidate"]:
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "MediaSectionMemoryBenchmark", "-Xswiftc", "-warnings-as-errors"], f"build-{variant}")
            directory = self.execute(command + ["--show-bin-path"], f"bin-path-{variant}")[0].strip()
            self.binaries[variant] = Path(directory) / "MediaSectionMemoryBenchmark"
            binaries[variant] = {"path": str(self.binaries[variant]), "sha256": file_digest(self.binaries[variant])}
        write_json(self.output / "binaries.json", binaries)
        for size in self.args.sizes:
            for scenario in self.args.cases:
                paths = {v: self.execute([self.binaries[v], "verify", scenario, size],
                                        f"verify-{scenario}-{size}-{v}", read=False)[1] for v in ["baseline", "candidate"]}
                if not files_equal(paths["baseline"], paths["candidate"]):
                    raise ValueError(f"Complete projection differs: {scenario}/{size}")
                self.oracles[(scenario, size)] = paths["baseline"]
                verification.append({"case": scenario, "size": size, "complete_output_equal": True,
                                     "trace_bytes": paths["baseline"].stat().st_size,
                                     "trace_sha256": file_digest(paths["baseline"])})
        write_json(self.output / "verification.json", verification)

    def benchmark(self):
        rows = []
        for scenario in self.args.cases:
            for size in self.args.sizes:
                for measurement in self.args.measurements:
                    iterations = 1 if measurement == "cold" else self.args.refresh_iterations
                    for pair in range(self.args.pairs):
                        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                        paired = []
                        for variant in order:
                            label = f"pair-{scenario}-{size}-{measurement}-{pair:02d}-{variant}"
                            output, _ = self.execute([self.binaries[variant], "measure", scenario, size,
                                measurement, iterations, self.oracles[(scenario, size)]], label)
                            row = json.loads(output)
                            if (row["case"], row["size"], row["measurement"], row["iterations"]) != (scenario, size, measurement, iterations):
                                raise ValueError("Measurement identity mismatch")
                            if not row["complete_output_byte_verified"] or min(row["elapsed_ns"], row["cpu_ns"]) <= 0:
                                raise ValueError("Invalid timing or output verification")
                            if row[RSS_METRICS[1]] < row[RSS_METRICS[0]] or row[RSS_METRICS[1]] <= 0:
                                raise ValueError("Invalid high-water RSS readings")
                            row.update(variant=variant, pair=pair, order=order, label=label)
                            rows.append(row); paired.append(row)
                            with (self.output / "observations.jsonl").open("a") as log:
                                log.write(json.dumps(row, sort_keys=True) + "\n")
                        for key in ["checksum", "rows", "sections", "tree_build_count", "visibility_build_count"]:
                            if paired[0][key] != paired[1][key]:
                                raise ValueError(f"Paired output receipt differs: {key}")
                    print(f"Measured {scenario}/{size}/{measurement}: {self.args.pairs} pairs", flush=True)
        summaries = []
        for scenario in self.args.cases:
            for size in self.args.sizes:
                for measurement in self.args.measurements:
                    selected = [r for r in rows if (r["case"], r["size"], r["measurement"]) == (scenario, size, measurement)]
                    summary = {"case": scenario, "size": size, "measurement": measurement, "pairs": self.args.pairs}
                    for metric in RSS_METRICS + ["elapsed_ns", "cpu_ns"]:
                        values = {v: [r[metric] / (r["iterations"] if metric.endswith("_ns") else 1)
                                      for r in selected if r["variant"] == v] for v in ["baseline", "candidate"]}
                        changes = []
                        for pair in range(self.args.pairs):
                            matched = {r["variant"]: r[metric] for r in selected if r["pair"] == pair}
                            changes.append((matched["candidate"] / matched["baseline"] - 1) * 100 if matched["baseline"] else None)
                        defined = [x for x in changes if x is not None]
                        summary[metric] = {v: {"median": statistics.median(x), "min": min(x), "max": max(x)} for v, x in values.items()}
                        summary[metric].update(paired_change_percent=changes,
                            median_paired_change_percent=statistics.median(defined) if defined else None,
                            lower_pairs=sum(x < 0 for x in defined))
                    summaries.append(summary)
        write_json(self.output / "summary.json", summaries)

    def check_sources(self):
        for path, expected in self.source_hashes.items():
            if file_digest(ROOT / path) != expected:
                raise ValueError(f"Source changed during measurement: {path}")
        for variant, manifest in self.manifests.items():
            for path, record in manifest["staged"].items():
                if file_digest(self.packages[variant] / path) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift")
    parser.add_argument("--current-support", action="store_true",
                        help="Keep the pinned grouping implementation; share identical current support sources in both variants")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--mode", choices=["all", "tests", "benchmark", "verify", "prepare"], default="all")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--sizes", nargs="+", type=int, default=[1000, 10000])
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--measurements", nargs="+", choices=["cold", "refresh"], default=["cold", "refresh"])
    parser.add_argument("--refresh-iterations", type=int, default=3)
    parser.add_argument("--smoke", action="store_true", help="Mark this run as exploratory")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or min(args.sizes) < 1 or args.jobs < 1 or args.refresh_iterations < 1:
        parser.error("Use positive sizes/jobs/iterations and a positive even pair count of at least two")
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
