#!/usr/bin/env python3
"""Qualify and measure the exact thumbnail-pass prefix and playlist neighborhood.

Submit this runner through Kyoto on hosts where the shared queue is available.
All compilation is serial, in isolated SwiftPM packages, without network package
dependencies. Complete receipts must agree before any timings are admitted.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VARIANTS = ("baseline", "candidate")
MAX_ITERATIONS = 10_000_000
BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_SEED = 20261028
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
TESTS = (
    "Tests/IlliquidAppTests/ThumbnailCandidatePlanningTests.swift",
    "Tests/IlliquidCoreTests/ThumbnailPolicyTests.swift",
    "Tests/IlliquidCoreTests/ThumbnailSchedulingPolicyRegressionTests.swift",
)
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ThumbnailPlaylistNeighborhoodQualification",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ThumbnailNeighborhoodProbe", targets: ["ThumbnailNeighborhoodDriver"]),
    ],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .executableTarget(name: "ThumbnailNeighborhoodDriver", dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def source_record(raw: bytes) -> dict:
    return {"bytes": len(raw), "sha256": sha(raw),
            "git_blob": hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()}


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def checked_source(raw: bytes, expected: dict, label: str) -> None:
    actual = source_record(raw)
    if any(actual[key] != expected[key] for key in actual):
        raise ValueError(f"Pinned source drift: {label}; review and requalify the baseline manifest")


def extract_prefix(raw: bytes, manifest: dict) -> bytes:
    start = manifest["prefix"]["start_marker"].encode()
    end = manifest["prefix"]["end_marker"].encode()
    if raw.count(start) != 1 or raw.count(end) != 1:
        raise ValueError("runPass extraction boundary changed or is ambiguous")
    first = raw.index(start) + len(start)
    last = raw.index(end, first)
    if first >= last:
        raise ValueError("runPass extraction boundaries are out of order")
    return raw[first:last]


def baseline_helper(prefix: bytes) -> bytes:
    # These two segments are byte-for-byte statements from the old runPass.
    # Only the surrounding testable value API is synthesized.
    urls = b"        var urls ="
    distances = b"        var distances:"
    candidates = b"        let candidates ="
    if any(prefix.count(marker) != 1 for marker in (urls, distances, candidates)):
        raise ValueError("Frozen baseline neighborhood extraction boundaries changed")
    url_index, distance_index, candidate_index = (
        prefix.index(marker) for marker in (urls, distances, candidates))
    if not url_index < distance_index < candidate_index:
        raise ValueError("Frozen baseline neighborhood statements are out of order")
    return b'''import Foundation
import IlliquidCore

// Synthesized value API around the unchanged, pinned scheduler statements.
enum ThumbnailPlaylistNeighborhood {
    struct Plan: Equatable, Sendable {
        let urls: [URL]
        let distances: [URL: Int]
    }

    static func plan(items: [FolderPlaylistItem], current: URL?) -> Plan {
        let player = ProbePlayer(viewStore: ProbeViewStore(playlist: items))
''' + prefix[:url_index] + prefix[distance_index:candidate_index] + b'''        return Plan(urls: neighbors, distances: distances)
    }
}
'''


def probe_wrapper(prefix: bytes) -> bytes:
    return b'''import Foundation
import IlliquidCore

// The real scheduler reads this immutable playlist value synchronously. These
// containers model that access without bringing AppKit/Observation into timing.
struct ProbeViewStore { let playlist: [FolderPlaylistItem] }
struct ProbePlayer { let viewStore: ProbeViewStore }

public enum ThumbnailNeighborhoodProbe {
    public struct Result: Equatable, Sendable {
        public let urls: [URL]
        public let distances: [URL: Int]
    }

    @inline(never)
    public static func neighborhood(_ items: [FolderPlaylistItem], current: URL?) -> Result {
        let plan = ThumbnailPlaylistNeighborhood.plan(items: items, current: current)
        return Result(urls: plan.urls, distances: plan.distances)
    }

    @inline(never)
    public static func candidates(_ items: [FolderPlaylistItem], current: URL?,
                                  visible: Set<URL>, discovered: [URL],
                                  recent: [URL: Date]) -> [ThumbnailPolicy.Candidate] {
        let player = ProbePlayer(viewStore: ProbeViewStore(playlist: items))
''' + prefix + b'''        return candidates
    }
}
'''


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def bootstrap_interval(values: list[float], case: str, metric: str) -> list[float]:
    case_seed = int.from_bytes(hashlib.sha256(f"{case}/{metric}".encode()).digest()[:8], "big")
    rng = random.Random(BOOTSTRAP_SEED ^ case_seed)
    estimates = [statistics.median(rng.choices(values, k=len(values)))
                 for _ in range(BOOTSTRAP_RESAMPLES)]
    return [percentile(estimates, 0.025), percentile(estimates, 0.975)]


def distribution(values: list[float]) -> dict:
    return {"median": statistics.median(values), "minimum": min(values),
            "maximum": max(values), "samples": len(values)}


class Study:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists():
            raise ValueError(f"Use a new output path; evidence is never overwritten: {self.output}")
        self.swift = shutil.which(args.swift)
        if not self.swift:
            raise ValueError(f"Swift executable not found: {args.swift}")
        self.swift = str(Path(self.swift).absolute())
        self.output.mkdir(parents=True)
        self.work = self.output / "work"
        self.environment = os.environ.copy()
        for key, directory in {
            "CLANG_MODULE_CACHE_PATH": self.work / "cache" / "clang",
            "SWIFTPM_MODULECACHE_OVERRIDE": self.work / "cache" / "swift",
            "XDG_CACHE_HOME": self.work / "cache" / "xdg",
            "TMPDIR": self.work / "tmp",
        }.items():
            directory.mkdir(parents=True, exist_ok=True)
            self.environment[key] = str(directory)
        self.environment.update(TERM="dumb", NO_COLOR="1")
        self.packages: dict[str, Path] = {}
        self.binaries: dict[str, Path] = {}
        self.expected: dict[str, dict] = {}
        self.sequence = 0
        self.manifest = {
            "schema": 1, "complete": False,
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "uname": platform.uname()._asdict(),
            "python": sys.version, "cpu_count": os.cpu_count(),
            "arguments": {**vars(args), "output": str(self.output)},
            "environment": {key: self.environment.get(key) for key in (
                "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "TZ",
                "SWIFT_DETERMINISTIC_HASHING", "SDKROOT", "DEVELOPER_DIR", "LD_LIBRARY_PATH")},
            "measurement_boundary": {
                "neighborhood": "Synchronous playlist URL neighborhood and distance construction",
                "candidates": "Exact runPass statements before its source/location/clock snapshot",
                "included": "Repeated call, returned-value consumption, and per-call temporary-object cleanup",
                "excluded": ["fixture construction", "startup", "ranking", "decoding", "filesystem I/O",
                             "AppKit/Observation", "async scheduler lifetime", "whole-player performance"],
                "process_policy": "Fresh process for every calibration and timed observation",
                "order": "Even AB/BA pairs; rotate case order each pair and starting variant by case and pair",
                "calibration": "Each variant independently targets process CPU time; per-op normalization",
                "max_iterations": MAX_ITERATIONS,
            },
            "statistics": {
                "reduction_sign": "Positive percentages mean less time per operation",
                "paired_reduction": "100 * (1 - candidate_ns_per_op / baseline_ns_per_op)",
                "bootstrap": "Percentile 95% interval for median of paired reductions",
                "bootstrap_resamples": BOOTSTRAP_RESAMPLES, "bootstrap_seed": BOOTSTRAP_SEED,
                "multiple_comparisons": "Intervals are descriptive and not family-wise adjusted",
            },
        }
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        if hasattr(os, "getloadavg"):
            self.manifest["load_average_start"] = os.getloadavg()
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.is_file():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                cpuinfo.read_text().splitlines() if line.startswith("model name")), "")
        self.update_manifest()

    def update_manifest(self) -> None:
        save(self.output / "manifest.json", self.manifest)

    def command(self, argv: list, label: str, *, compressed_stdout: bool = False,
                allowed: tuple[int, ...] = (0,), timeout: int = 1800) -> subprocess.CompletedProcess:
        argv = [str(value) for value in argv]
        self.sequence += 1
        stem = f"{self.sequence:04d}-{label}"
        directory = self.output / "logs"
        directory.mkdir(exist_ok=True)
        stdout_path = directory / (stem + (".stdout.json.gz" if compressed_stdout else ".stdout.log"))
        stderr_path = directory / (stem + ".stderr.log")
        record = {"sequence": self.sequence, "label": label, "argv": argv, "cwd": str(ROOT),
                  "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "stdout": str(stdout_path.relative_to(self.output)),
                  "stderr": str(stderr_path.relative_to(self.output))}
        start = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=self.environment, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            result = subprocess.CompletedProcess(argv, 124, error.stdout or b"", error.stderr or b"")
            record["timed_out"] = True
        stdout_path.write_bytes(gzip.compress(result.stdout, mtime=0) if compressed_stdout else result.stdout)
        stderr_path.write_bytes(result.stderr)
        record.update(elapsed_seconds=time.monotonic() - start, returncode=result.returncode,
                      stdout_sha256=sha(result.stdout), stderr_sha256=sha(result.stderr))
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {stderr_path}\n"
                               + (result.stdout + result.stderr).decode(errors="replace")[-6000:])
        return result

    def snapshot(self) -> None:
        pinned_raw = (HERE / "baseline/manifest.json").read_bytes()
        pinned = json.loads(pinned_raw)
        prefix = (HERE / "baseline" / pinned["prefix"]["snapshot"]).read_bytes()
        checked_source(prefix, pinned["prefix"], "frozen runPass prefix")
        original_check = self.command(["git", "show", f"{pinned['commit']}:{SCHEDULER}"],
                                      "baseline-provenance", compressed_stdout=True, allowed=(0, 128))
        if original_check.returncode == 0:
            checked_source(original_check.stdout, pinned["scheduler"], "original scheduler")
            if extract_prefix(original_check.stdout, pinned) != prefix:
                raise ValueError("Frozen prefix does not match its original scheduler")
        self.manifest["baseline_provenance"] = {
            "commit": pinned["commit"], "original_scheduler": pinned["scheduler"],
            "frozen_prefix": pinned["prefix"],
            "git_history_verified": original_check.returncode == 0,
            "history_note": "The frozen prefix/common hashes also support shallow checkouts without the base object",
        }
        common = {}
        for path, expected in pinned["common_sources"].items():
            data = (ROOT / path).read_bytes()
            checked_source(data, expected, path)
            common[path] = data
        candidate_scheduler = (ROOT / SCHEDULER).read_bytes()
        candidate_prefix = extract_prefix(candidate_scheduler, pinned)
        candidate_helper = (ROOT / HELPER).read_bytes()
        driver = (HERE / "Driver.swift").read_bytes()
        tests = {path: (ROOT / path).read_bytes() for path in TESTS}
        inputs = {
            "run.py": Path(__file__).read_bytes(), "Driver.swift": driver,
            "baseline/manifest.json": pinned_raw, "baseline/runPass-prefix.swift": prefix,
            "candidate/runPass-prefix.swift": candidate_prefix,
            "candidate/ThumbnailBackgroundScheduler.swift": candidate_scheduler,
            "candidate/ThumbnailPlaylistNeighborhood.swift": candidate_helper,
            **common, **tests,
        }
        self.manifest["input_sources"] = {}
        for path, data in inputs.items():
            destination = self.output / "inputs" / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            self.manifest["input_sources"][path] = source_record(data)
        self.manifest["generated_sources"] = {}
        for variant in VARIANTS:
            package = self.work / "packages" / variant
            staged = {f"Sources/IlliquidCore/{Path(path).name}": data for path, data in common.items()}
            staged.update(tests)
            staged.update({
                "Package.swift": PACKAGE.encode(),
                "Sources/ThumbnailNeighborhoodDriver/Driver.swift": driver,
                "Sources/IlliquidApp/ThumbnailPlaylistNeighborhood.swift":
                    baseline_helper(prefix) if variant == "baseline" else candidate_helper,
                "Sources/IlliquidApp/ThumbnailNeighborhoodProbe.swift":
                    probe_wrapper(prefix if variant == "baseline" else candidate_prefix),
            })
            records = {}
            for path, data in staged.items():
                destination = package / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                records[path] = source_record(data)
                if path.startswith("Sources/IlliquidApp/") or path == "Package.swift":
                    retained = self.output / "inputs" / "generated" / variant / path
                    retained.parent.mkdir(parents=True, exist_ok=True)
                    retained.write_bytes(data)
            self.packages[variant] = package
            self.manifest["generated_sources"][variant] = records
        self.manifest["source_adaptations"] = {
            "common_sources": "Byte-for-byte unchanged and identical for both variants; no Linux rewrites",
            "baseline_helper": "Original statements before var urls, plus var distances through before let candidates",
            "candidate_helper": "Exact live ThumbnailPlaylistNeighborhood.swift bytes",
            "candidate_construction": "Exact extracted baseline/live runPass prefixes inside the same public wrapper",
            "value_containers": "ProbePlayer/ProbeViewStore model synchronous playlist access",
            "module_boundary": "Driver, IlliquidApp, and IlliquidCore are separate targets; no cross-module optimization",
        }
        self.manifest["candidate_head"] = self.command(["git", "rev-parse", "HEAD"], "head").stdout.decode().strip()
        self.manifest["candidate_worktree"] = self.command(["git", "status", "--short"], "worktree").stdout.decode()
        self.manifest["swift"] = {"path": self.swift,
            "version": self.command([self.swift, "--version"], "swift-version").stdout.decode().strip(),
            "executable_sha256": sha(Path(self.swift).read_bytes())}
        swiftc = Path(self.swift).parent / "swiftc"
        frontend = Path(self.swift).parent / "swift-frontend"
        for label, path in (("swiftc", swiftc), ("frontend", frontend)):
            if path.is_file():
                self.manifest["swift"][label] = {"path": str(path), "sha256": sha(path.read_bytes())}
        if sys.platform == "darwin":
            self.manifest["macos"] = self.command(["sw_vers"], "macos").stdout.decode().strip()
            self.manifest["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model").stdout.decode().strip()
        self.update_manifest()

    def swift_command(self, variant: str, action: str, configuration: str) -> list:
        return [self.swift, action, "--package-path", self.packages[variant],
                "--scratch-path", self.work / "build" / variant,
                "--cache-path", self.work / "cache" / "packages",
                "--config-path", self.work / "cache" / "config",
                "--security-path", self.work / "cache" / "security",
                "--jobs", self.args.jobs, "--configuration", configuration]

    def tests(self) -> None:
        records = []
        for configuration in ("debug", "release"):
            for variant in VARIANTS:
                print(f"Testing {variant} ({configuration})", flush=True)
                result = self.command(self.swift_command(variant, "test", configuration)
                    + ["--no-parallel", "-Xswiftc", "-warnings-as-errors"], f"tests-{variant}-{configuration}")
                text = (result.stdout + result.stderr).decode(errors="replace")
                counts = re.findall(r"Test run with (\d+) tests?", text)
                if not counts or int(counts[-1]) < 1:
                    raise ValueError(f"No completed Swift Testing tests reported for {variant} {configuration}")
                records.append({"variant": variant, "configuration": configuration,
                                "count": int(counts[-1]), "passed": True})
                save(self.output / "tests.json", records)
        if len({record["count"] for record in records}) != 1:
            raise ValueError("Baseline/candidate debug/release test counts differ")

    def build_and_verify(self) -> list[dict]:
        binary_records = {}
        for variant in VARIANTS:
            build = self.swift_command(variant, "build", "release")
            self.command(build + ["--product", "ThumbnailNeighborhoodProbe"], f"build-{variant}")
            directory = self.command(build + ["--show-bin-path"], f"bin-path-{variant}").stdout.decode().strip()
            binary = Path(directory) / "ThumbnailNeighborhoodProbe"
            self.binaries[variant] = binary
            binary_records[variant] = {"path": str(binary), "sha256": sha(binary.read_bytes())}
        save(self.output / "binaries.json", binary_records)
        lists, receipts, raw_hashes = {}, {}, {}
        for variant in VARIANTS:
            lists[variant] = json.loads(self.command([self.binaries[variant], "--list"], f"list-{variant}").stdout)
            raw = self.command([self.binaries[variant], "--verify"], f"verify-{variant}",
                               compressed_stdout=True).stdout
            receipts[variant] = json.loads(raw)
            raw_hashes[variant] = sha(raw)
        if lists["baseline"] != lists["candidate"]:
            raise ValueError("Baseline/candidate workload inventories differ")
        if receipts["baseline"] != receipts["candidate"]:
            raise ValueError("Complete baseline/candidate verification receipts differ; inspect compressed logs")
        cases = lists["candidate"]
        if not isinstance(cases, list) or not cases or len({row["name"] for row in cases}) != len(cases):
            raise ValueError("Invalid or duplicate workload inventory")
        all_receipts = receipts["candidate"]
        if not isinstance(all_receipts, list) or not all_receipts:
            raise ValueError("Empty or invalid verification receipt array")
        by_name = {row["name"]: row for row in all_receipts}
        if len(by_name) != len(all_receipts):
            raise ValueError("Duplicate verification receipt names")
        for case in cases:
            receipt = by_name[case["name"]]
            if receipt["input_count"] != case["playlist_size"]:
                raise ValueError(f"Preflight input size mismatch: {case['name']}")
            if case["mode"] == "neighborhood":
                count = len(receipt["neighbors"])
                signature = 17 + count * 31 + len(receipt["distances"]) * 7
                signature += sum(row["distance"] for row in receipt["distances"])
            elif case["mode"] == "candidates":
                candidates = receipt["candidates"]
                count = len(candidates)
                first = candidates[0].get("distance") if candidates else None
                last = candidates[-1].get("distance") if candidates else None
                signature = 17 + count * 31 + (first if first is not None else -1) + (last if last is not None else -1)
            else:
                raise ValueError(f"Unknown measurement mode: {case['mode']}")
            self.expected[case["name"]] = {"output_count": count, "signature": signature}
        full = canonical(all_receipts)
        (self.output / "verification-receipts.json.gz").write_bytes(gzip.compress(full, mtime=0))
        save(self.output / "parity.json", {
            "complete_output_equal": True, "receipts": len(all_receipts), "workloads": len(cases),
            "canonical_receipts_sha256": sha(full), "raw_stdout_sha256": raw_hashes,
            "checks": ["neighbor order and exact URL representation", "all URL distances",
                       "every candidate field and order", "all three priority rankings"],
            "expected_measurements": self.expected,
        })
        save(self.output / "cases.json", cases)
        requested = self.args.case
        if requested:
            known = {case["name"] for case in cases}
            unknown = set(requested) - known
            if unknown:
                raise ValueError(f"Unknown --case values: {sorted(unknown)}")
            cases = [case for case in cases if case["name"] in requested]
        self.manifest["selected_cases"] = cases
        self.update_manifest()
        print(f"PASS complete-output parity: {len(all_receipts)} receipts, {len(cases)} selected workloads", flush=True)
        return cases

    def measure(self, variant: str, case: dict, iterations: int, label: str) -> dict:
        raw = self.command([self.binaries[variant], "--measure", case["name"], iterations], label).stdout
        row = json.loads(raw)
        if row.get("case") != case["name"] or row.get("iterations") != iterations:
            raise ValueError(f"Measurement identity mismatch: {label}")
        if any(type(row.get(key)) is not int or row[key] <= 0 for key in ("wall_ns", "cpu_ns")):
            raise ValueError(f"Invalid CPU/wall timing: {label}")
        expected = self.expected[case["name"]]
        checksum = expected["signature"] * iterations
        if (row.get("checksum") != checksum or row.get("expected_checksum") != checksum
                or row.get("output_count") != expected["output_count"]
                or row.get("postflight_matches") is not True):
            raise ValueError(f"Measurement receipt/checksum mismatch: {label}")
        return {**row, "variant": variant, "command_sequence": self.sequence,
                "cpu_ns_per_op": row["cpu_ns"] / iterations,
                "wall_ns_per_op": row["wall_ns"] / iterations}

    def benchmark(self, cases: list[dict]) -> None:
        iterations = {}
        target_ns = self.args.target_ms * 1_000_000
        calibration_ns = min(target_ns, max(1_000_000, target_ns * 0.25))
        for case in cases:
            iterations[case["name"]] = {}
            for variant in VARIANTS:
                count = 1
                attempt = 0
                while True:
                    row = self.measure(variant, case, count, f"calibrate-{case['name']}-{variant}-{attempt}")
                    row.update(attempt=attempt, target_cpu_ns=target_ns)
                    with (self.output / "calibration.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                    if row["cpu_ns"] >= calibration_ns or count == MAX_ITERATIONS:
                        iterations[case["name"]][variant] = min(MAX_ITERATIONS, max(1,
                            math.ceil(count * target_ns / row["cpu_ns"])))
                        break
                    scale = min(32, max(2, math.ceil(calibration_ns / row["cpu_ns"])))
                    count = min(MAX_ITERATIONS, count * scale)
                    attempt += 1
            save(self.output / "iterations.json", iterations)
        rows = []
        for pair in range(self.args.pairs):
            offset = pair % len(cases)
            rotated = list(enumerate(cases))[offset:] + list(enumerate(cases))[:offset]
            for case_index, case in rotated:
                order = VARIANTS if (pair + case_index) % 2 == 0 else tuple(reversed(VARIANTS))
                for position, variant in enumerate(order):
                    row = self.measure(variant, case, iterations[case["name"]][variant],
                                       f"pair-{pair:02d}-{case['name']}-{variant}")
                    row.update(pair=pair, position_in_pair=position, order=list(order))
                    rows.append(row)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Completed balanced pair {pair + 1}/{self.args.pairs}", flush=True)
        summaries = []
        for case in cases:
            selected = [row for row in rows if row["case"] == case["name"]]
            result = {**case, "pairs": self.args.pairs, "iterations": iterations[case["name"]],
                      "output_count": self.expected[case["name"]]["output_count"]}
            for variant in VARIANTS:
                values = [row for row in selected if row["variant"] == variant]
                if len(values) != self.args.pairs:
                    raise ValueError(f"Missing observations for {case['name']} {variant}")
                result[variant] = {metric: distribution([row[metric] for row in values])
                                  for metric in ("cpu_ns_per_op", "wall_ns_per_op")}
            for metric in ("cpu_ns_per_op", "wall_ns_per_op"):
                reductions = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[metric] for row in selected if row["pair"] == pair}
                    if set(values) != set(VARIANTS):
                        raise ValueError("Incomplete baseline/candidate pair")
                    reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
                result[metric.replace("_ns_per_op", "_reduction_percent")] = {
                    **distribution(reductions), "paired_values": reductions,
                    "faster_pairs": sum(value > 0 for value in reductions),
                    "bootstrap_median_95_ci": bootstrap_interval(reductions, case["name"], metric),
                    "ratio_of_medians": 100 * (1 - result["candidate"][metric]["median"]
                                                / result["baseline"][metric]["median"]),
                }
            summaries.append(result)
        save(self.output / "summary.json", summaries)

    def run(self) -> None:
        if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
            print("Shared Kyoto queue unavailable; compiling isolated SwiftPM packages directly and serially.", flush=True)
        self.snapshot()
        self.tests()
        if not self.args.tests_only:
            cases = self.build_and_verify()
            if not self.args.verify_only:
                self.benchmark(cases)
        self.manifest.update(complete=True, status="tests_only" if self.args.tests_only else
                             "verified_only" if self.args.verify_only else "measured",
                             finished_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        if hasattr(os, "getloadavg"):
            self.manifest["load_average_end"] = os.getloadavg()
        self.update_manifest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New evidence output path")
    parser.add_argument("--swift", default="swift", help="Swift driver executable")
    parser.add_argument("--jobs", type=int, default=2, help="Maximum compiler jobs; builds are serialized")
    parser.add_argument("--pairs", type=int, default=12, help="Positive, even number of AB/BA pairs")
    parser.add_argument("--target-ms", type=float, default=80, help="Target process CPU milliseconds per observation")
    parser.add_argument("--case", action="append", help="Exact workload name to time; repeatable; all receipts still verified")
    exclusive = parser.add_mutually_exclusive_group()
    exclusive.add_argument("--tests-only", action="store_true")
    exclusive.add_argument("--verify-only", action="store_true", help="Run tests and full differential receipts without timing")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.jobs < 1 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--pairs must be positive and even (at least 2); --jobs and --target-ms must be positive")
    study = None
    try:
        study = Study(args)
        study.run()
        return 0
    except Exception as error:
        if study is not None:
            save(study.output / "failure.json", {"error": str(error), "traceback": traceback.format_exc()})
            study.manifest.update(complete=False, status="failed", error=str(error))
            study.update_manifest()
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
