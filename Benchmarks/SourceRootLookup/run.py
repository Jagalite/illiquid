#!/usr/bin/env python3
"""Compare exact production source-root lookup with its pinned pre-change version.

No Swift package dependencies or network downloads are required. Source staging
reuses the guarded declaration extraction from the source-tree qualification.
Every timed observation is a fresh process; complete JSON outputs are compared
before timing, including the exact Unicode spelling of strings.
"""
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
import tarfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
CASES = ["relative-hit", "relative-miss", "relative-nested", "cold-relative", "cold-single",
         "ancestry", "flat-projection"]
TESTS = ["SourceVisibilityRootLookupTests.swift", "SourceBrowserFilterTests.swift",
         "SourceMediaOrganizationTests.swift", "SourceTreeVisibilityCacheTests.swift",
         "FlatFileProjectionTests.swift"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceRootLookupQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SourceRootBenchmark", targets: ["SourceRootBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "SourceRootBenchmark", dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def load_stager():
    spec = importlib.util.spec_from_file_location("source_tree_stager", HELPER)
    if spec is None or spec.loader is None:
        raise ValueError("Cannot load guarded source staging helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def without_matcher(raw: bytes) -> bytes:
    start = b"struct SourceVisibilityMatcher {"
    end = b"\nenum SourceVisibilityProjection {"
    if raw.count(start) != 1 or raw.count(end) != 1:
        raise ValueError("Missing or ambiguous matcher comparison boundaries")
    begin, finish = raw.index(start), raw.index(end)
    if finish <= begin:
        raise ValueError("Reversed matcher comparison boundaries")
    return raw[:begin] + b"/* focal matcher declaration */\n" + raw[finish:]


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty; previous evidence is not overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        self.swift = args.swift or shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH, or pass --swift /absolute/path/to/swift")
        self.env = os.environ.copy()
        cache = self.output / "module-cache"
        cache.mkdir()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
        self.packages, self.manifests, self.binaries = {}, {}, {}
        self.driver_paths = [HERE / "run.py", HERE / "Harness.swift", HELPER]
        self.driver_hashes = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in self.driver_paths}
        for path in self.driver_paths:
            destination = self.output / "driver" / path.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        self.workloads = [(case, count, args.depth) for count in args.sizes for case in args.cases]
        if not args.no_threshold_controls:
            self.workloads += [(case, count, depth) for count in [4, 5, 8, 16]
                               for depth in [8, 32] for case in ["relative-hit", "relative-miss"]]
        self.workloads = list(dict.fromkeys(self.workloads))

    def execute(self, command, label: str, timeout: int = 360) -> subprocess.CompletedProcess:
        command = [str(value) for value in command]
        started = time.monotonic()
        try:
            result = subprocess.run(command, cwd=ROOT, env=self.env, text=True,
                                    capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            write_json(self.output / "failure.json", {"label": label, "command": command,
                       "timeout_seconds": timeout, "error": str(error)})
            raise
        log_path = self.output / "logs" / (label + ".txt")
        log_path.write_text(result.stdout + result.stderr)
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"label": label, "command": command, "returncode": result.returncode,
                "elapsed_seconds": time.monotonic() - started, "log": str(log_path.relative_to(self.output)),
                "stdout_sha256": digest(result.stdout.encode()), "stderr_sha256": digest(result.stderr.encode())},
                sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n" + (result.stdout + result.stderr)[-12000:])
        return result

    def baseline_source(self, path: str) -> bytes:
        result = subprocess.run(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT, capture_output=True)
        if result.returncode:
            raise ValueError(f"Pinned baseline source unavailable: {path}: {result.stderr.decode()}")
        return result.stdout

    def prepare(self):
        stager = load_stager()
        baseline_files, baseline_records = stager.snapshot(self.baseline_source)
        candidate_files, candidate_records = stager.snapshot(lambda path: (ROOT / path).read_bytes())
        if baseline_files.keys() != candidate_files.keys():
            raise ValueError("Production source inventories differ")
        focal = "Sources/IlliquidApp/SidebarValues.swift"
        for path, raw in candidate_files.items():
            if path == focal:
                if without_matcher(raw) != without_matcher(baseline_files[path]):
                    raise ValueError("A declaration outside SourceVisibilityMatcher changed")
            elif raw != baseline_files[path]:
                raise ValueError(f"Unrelated production dependency changed: {path}")
        head = self.execute(["git", "rev-parse", "HEAD"], "revision").stdout.strip()
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            package = self.output / "packages" / variant
            manifest = {"variant": variant, "baseline_revision": BASELINE, "candidate_ancestor": head,
                        "production": records, "staged": {}, "adaptations": []}
            staging = dict(files)
            staging["Package.swift"] = PACKAGE.encode()
            staging["Sources/SourceRootBenchmark/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            for name in TESTS:
                staging["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            for relative, raw in staging.items():
                adapted, changes = raw, []
                if platform.system() == "Linux":
                    if relative.endswith("/MediaSidecarReader.swift"):
                        if raw.count(b"import Darwin\n") != 1:
                            raise ValueError("POSIX import boundary changed")
                        adapted = raw.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        changes.append("Darwin import -> Glibc")
                    elif relative.endswith("/NFOMetadataHints.swift"):
                        if raw.count(b"import Foundation\n") != 1:
                            raise ValueError("XML import boundary changed")
                        adapted = raw.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        changes.append("add FoundationXML import")
                    elif relative.endswith("/SourceMediaOrganizationTests.swift"):
                        original = b'appendingPathComponent("media-sidecars-" + UUID().uuidString)'
                        if raw.count(original) != 1:
                            raise ValueError("Legacy sidecar directory fixture changed")
                        adapted = raw.replace(original,
                            b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)', 1)
                        changes.append("explicit directory hint for legacy sidecar test fixture")
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(adapted)
                manifest["staged"][relative] = {"source_sha256": digest(raw), "compiled_sha256": digest(adapted)}
                if changes:
                    manifest["adaptations"].append({"file": relative, "changes": changes})
            self.packages[variant], self.manifests[variant] = package, manifest
            write_json(self.output / f"{variant}-sources.json", manifest)
        write_json(self.output / "environment.json", {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
            "swift_path": str(Path(self.swift).resolve()),
            "swift": self.execute([self.swift, "--version"], "swift-version").stdout.strip(),
            "head": head, "baseline": BASELINE, "driver_hashes": self.driver_hashes,
            "worktree": self.execute(["git", "status", "--short"], "worktree").stdout,
            "workloads": [{"scenario": case, "roots": count, "depth": depth} for case, count, depth in self.workloads],
            "pairs": self.args.pairs, "exploratory": self.args.smoke,
            "rows_per_projection": self.args.rows,
            "measurement": "DispatchTime nanoseconds around a batch of 64 lookups/ancestry evaluations, constructor plus 64/1 lookups, or a complete uncached files-only actor projection. Fixture construction, warmup, JSON receipts, hashing, and actor destruction are outside timing.",
            "fixtures": "Synthetic lexical URLs; no filesystem I/O during measured operations. Flat projections include ancestry rules and annotations; sorting is off.",
            "ordering": "Each group has alternating AB/BA pairs; every member is a fresh process.",
            "parity": "Full JSON object equality in Python, preserving Unicode spelling; plus complete edge-case outputs. Timing checksum equality is an additional gate, not the only one.",
            "calibration": {"target_faster_ms": self.args.target_ms, "maximum_slower_ms": self.args.max_interval_ms},
        })
        self.check_sources()

    def check_sources(self):
        for path in self.driver_paths:
            if digest(path.read_bytes()) != self.driver_hashes[str(path.relative_to(ROOT))]:
                raise ValueError(f"Driver changed during execution: {path}")
        for variant, manifest in self.manifests.items():
            for relative, record in manifest["staged"].items():
                if digest((self.packages[variant] / relative).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed during execution: {variant}/{relative}")

    def swift_command(self, variant: str, action: str, configuration: str):
        command = [self.swift, action, "--package-path", self.packages[variant],
                   "--scratch-path", self.output / "build" / variant,
                   "--cache-path", self.output / "swiftpm-cache", "--config-path", self.output / "swiftpm-config",
                   "--security-path", self.output / "swiftpm-security", "--jobs", str(self.args.jobs),
                   "--configuration", configuration]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def test(self):
        records = []
        for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
            print(f"Testing {variant} ({configuration})", flush=True)
            command = self.swift_command(variant, "test", configuration) + [
                "--disable-xctest", "--enable-swift-testing", "--no-parallel"]
            if self.args.test_filter:
                command += ["--filter", self.args.test_filter]
            result = self.execute(command, f"tests-{variant}-{configuration}")
            (self.output / f"tests-{variant}-{configuration}.txt").write_text(result.stdout + result.stderr)
            counts = re.findall(r"Test run with (\d+) tests?\b", result.stdout + result.stderr)
            if not counts or int(counts[-1]) == 0:
                raise ValueError(f"No completed Swift Testing tests: {variant}/{configuration}")
            records.append({"variant": variant, "configuration": configuration, "passed": True,
                            "filter": self.args.test_filter, "test_count": int(counts[-1])})
        write_json(self.output / "tests.json", {"suites": TESTS, "runs": records})
        self.check_sources()

    def build(self):
        for variant in ["baseline", "candidate"]:
            print(f"Building {variant} benchmark (release)", flush=True)
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "SourceRootBenchmark"], f"build-{variant}")
            bin_path = self.execute(command + ["--show-bin-path"], f"bin-path-{variant}").stdout.strip()
            binary = Path(bin_path) / "SourceRootBenchmark"
            self.binaries[variant] = binary
            self.manifests[variant]["binary_sha256"] = digest(binary.read_bytes())
            write_json(self.output / f"{variant}-sources.json", self.manifests[variant])
        self.check_sources()

    def invoke(self, variant: str, mode: str, workload, iterations: int, label: str):
        case, count, depth = workload
        result = self.execute([self.binaries[variant], mode, case, count, self.args.rows, depth, iterations], label)
        data = json.loads(result.stdout)
        if mode == "measure":
            expected = (case, count, self.args.rows, depth, iterations)
            actual = (data["scenario"], data["root_count"], data["row_count"], data["depth"], data["iterations"])
            if expected != actual or data["query_count"] != (1 if case == "cold-single" else 64):
                raise ValueError(f"Unexpected measured workload: {actual}")
            durations = data["durations_ns"]
            if len(durations) != iterations or any(type(n) is not int or n <= 0 for n in durations):
                raise ValueError("Invalid duration observations")
            if data["elapsed_ns"] != sum(durations):
                raise ValueError("Inconsistent total duration")
        return data

    def measure(self):
        (self.output / "parity").mkdir()
        edge_outputs = {}
        for variant in ["baseline", "candidate"]:
            edge_outputs[variant] = json.loads(self.execute([self.binaries[variant], "edges"], f"edges-{variant}").stdout)
            write_json(self.output / "parity" / f"edges-{variant}.json", edge_outputs[variant])
        if edge_outputs["baseline"] != edge_outputs["candidate"]:
            raise ValueError("Full Unicode/containment edge-case output differs")
        observations, calibrations = [], []
        for group, workload in enumerate(self.workloads):
            case, count, depth = workload
            name = f"{case}-{count}-depth{depth}"
            parity = {}
            for variant in ["baseline", "candidate"]:
                parity[variant] = self.invoke(variant, "parity", workload, 1, f"parity-{variant}-{name}")
                write_json(self.output / "parity" / f"{variant}-{name}.json", parity[variant])
            if parity["baseline"] != parity["candidate"]:
                raise ValueError(f"Complete lookup, ancestry, or projection output differs: {name}")
            if self.args.iterations:
                iterations = self.args.iterations
            else:
                pilots = {}
                for variant in (["baseline", "candidate"] if group % 2 == 0 else ["candidate", "baseline"]):
                    pilots[variant] = self.invoke(variant, "measure", workload, 3, f"pilot-{variant}-{name}")
                if pilots["baseline"]["checksum"] != pilots["candidate"]["checksum"]:
                    raise ValueError(f"Pilot output differs: {name}")
                costs = [row["elapsed_ns"] / row["iterations"] for row in pilots.values()]
                target = math.ceil(self.args.target_ms * 1_000_000 / min(costs))
                capped = max(1, math.floor(self.args.max_interval_ms * 1_000_000 / max(costs)))
                iterations = max(1, min(target, capped, 2_000))
                calibrations.append({"scenario": case, "roots": count, "depth": depth, "pilots": pilots,
                    "iterations": iterations, "target_iterations": target, "slower_cap_iterations": capped,
                    "faster_target_limited": iterations < target})
                write_json(self.output / "calibration.json", calibrations)
            expected_checksum = None
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for position, variant in enumerate(order):
                    row = self.invoke(variant, "measure", workload, iterations, f"measure-{variant}-{name}-{pair}")
                    if expected_checksum is not None and row["checksum"] != expected_checksum:
                        raise ValueError(f"Timed outputs differ: {name}")
                    expected_checksum = row["checksum"]
                    row.update(variant=variant, pair=pair, process_order=position)
                    observations.append(row)
                    with (self.output / "observations.jsonl").open("a") as log:
                        log.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Measured {name}: {iterations} iterations, {self.args.pairs} pairs", flush=True)
            self.summarize(observations)
        write_json(self.output / "parity.json", {"passed": True, "complete_workloads": len(self.workloads),
                   "unicode_edge_fixtures": len(edge_outputs["baseline"]), "comparison": "exact JSON string spelling and complete values"})
        self.check_sources()
        for variant, binary in self.binaries.items():
            if digest(binary.read_bytes()) != self.manifests[variant]["binary_sha256"]:
                raise ValueError(f"Measured binary changed: {variant}")

    def summarize(self, observations):
        summaries = []
        for case, count, depth in self.workloads:
            rows = [row for row in observations if (row["scenario"], row["root_count"], row["depth"]) == (case, count, depth)]
            if not rows:
                continue
            groups = {variant: sorted([row for row in rows if row["variant"] == variant], key=lambda r: r["pair"])
                      for variant in ["baseline", "candidate"]}
            if any(len(group) != self.args.pairs for group in groups.values()):
                raise ValueError("Incomplete or duplicated measured pairs")
            for variant, group in groups.items():
                if [row["pair"] for row in group] != list(range(self.args.pairs)):
                    raise ValueError("Missing or duplicated pair identity")
                for row in group:
                    expected_position = (0 if variant == "baseline" else 1) ^ (row["pair"] % 2)
                    if row["process_order"] != expected_position:
                        raise ValueError("Execution order was not alternating AB/BA")
            values = {variant: [row["elapsed_ns"] / row["iterations"] for row in group]
                      for variant, group in groups.items()}
            ratios = [candidate / baseline for baseline, candidate in zip(values["baseline"], values["candidate"])]
            summaries.append({"scenario": case, "roots": count, "depth": depth,
                "rows": self.args.rows, "queries_per_iteration": rows[0]["query_count"], "pairs": self.args.pairs,
                "iterations": rows[0]["iterations"],
                "baseline_ns": {"median": statistics.median(values["baseline"]), "min": min(values["baseline"]), "max": max(values["baseline"])},
                "candidate_ns": {"median": statistics.median(values["candidate"]), "min": min(values["candidate"]), "max": max(values["candidate"])},
                "median_paired_candidate_over_baseline": statistics.median(ratios),
                "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios))})
        write_json(self.output / "summary.json", summaries)

    def export_evidence(self):
        evidence = self.output / "evidence"
        evidence.mkdir(exist_ok=True)
        for source in self.output.iterdir():
            if source.is_file():
                shutil.copyfile(source, evidence / source.name)
        for name in ["parity", "driver", "logs"]:
            source = self.output / name
            if source.exists():
                shutil.copytree(source, evidence / name, dirs_exist_ok=True)
        with tarfile.open(evidence / "staged-sources.tar.gz", "w:gz") as archive:
            for variant, manifest in self.manifests.items():
                for relative in sorted(manifest["staged"]):
                    archive.add(self.packages[variant] / relative, arcname=variant + "/" + relative, recursive=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "test", "benchmark", "build"], default="all")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--swift")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1, 4, 100, 1000])
    parser.add_argument("--case", dest="cases", action="append", choices=CASES)
    parser.add_argument("--depth", type=int, default=2)
    parser.add_argument("--rows", type=int, default=256)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--target-ms", type=float, default=20)
    parser.add_argument("--max-interval-ms", type=float, default=150)
    parser.add_argument("--no-threshold-controls", action="store_true")
    parser.add_argument("--test-filter")
    parser.add_argument("--smoke", action="store_true", help="Allow fewer paired observations; all timings are exploratory")
    args = parser.parse_args()
    args.cases = args.cases or CASES
    if args.tests_only:
        args.mode = "test"
    if args.jobs < 1 or args.pairs < 1 or (not args.smoke and (args.pairs < 6 or args.pairs % 2)):
        parser.error("Use positive jobs and at least six even pairs; --smoke permits fewer")
    if any(count < 1 for count in args.sizes) or args.rows < 1 or args.depth < 0:
        parser.error("Root/row counts must be positive and depth nonnegative")
    if args.iterations is not None and args.iterations < 1:
        parser.error("Iterations must be positive")
    if args.target_ms <= 0 or args.max_interval_ms <= 0:
        parser.error("Calibration intervals must be positive")
    runner = Runner(args)
    try:
        runner.prepare()
        if args.mode in {"all", "test"}:
            runner.test()
        if args.mode in {"all", "benchmark", "build"}:
            runner.build()
        if args.mode in {"all", "benchmark"}:
            runner.measure()
    except Exception as error:
        write_json(runner.output / "failure.json", {"type": type(error).__name__, "error": str(error)})
        raise
    finally:
        runner.export_evidence()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Source root lookup qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
