#!/usr/bin/env python3
"""Qualify exact episode display-name sources, then measure equal-work AB/BA pairs.

Submit this runner through Kyoto when the shared queue is available. Packages,
builds, and caches are isolated under output/work; no network packages are used.
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
SOURCE = "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
TESTS = ["MediaNameRecognitionTests", "MediaNameRecognitionPerformanceRegressionTests",
         "MediaNameRecognitionFastPathTests", "EpisodeDisplayNameTests"]
VARIANTS = ("baseline", "candidate")
MAX_ITERATIONS = 1_000_000
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "EpisodeDisplayNameQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "EpisodeDisplayNameProbe", targets: ["EpisodeDisplayNameDriver"])],
    targets: [
        .target(name: "IlliquidCore", swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "EpisodeDisplayNameDriver", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
'''


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def record(raw):
    return {"bytes": len(raw), "sha256": sha(raw),
            "git_blob": hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def checked(raw, expected, label):
    if any(record(raw)[key] != expected[key] for key in ("bytes", "sha256", "git_blob")):
        raise ValueError(f"Pinned source changed: {label}; explicitly review and requalify the baseline")


def distribution(values):
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values), "samples": len(values)}


def interval(values, label):
    rng = random.Random(20261028 ^ int.from_bytes(hashlib.sha256(label.encode()).digest()[:8], "big"))
    samples = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10_000))
    def quantile(p):
        position = (len(samples) - 1) * p
        low, high = math.floor(position), math.ceil(position)
        return samples[low] + (samples[high] - samples[low]) * (position - low)
    return [quantile(0.025), quantile(0.975)]


def signed64(value):
    return (value + (1 << 63)) % (1 << 64) - (1 << 63)


class Study:
    def __init__(self, args):
        self.args, self.output = args, args.output.resolve()
        if self.output.exists():
            raise ValueError(f"Use a new output path; evidence is never overwritten: {self.output}")
        self.swift = shutil.which(args.swift)
        if not self.swift:
            raise ValueError(f"Swift executable not found: {args.swift}")
        self.swift = str(Path(self.swift).absolute())
        self.output.mkdir(parents=True)
        self.work, self.environment = self.output / "work", os.environ.copy()
        for key, suffix in {"CLANG_MODULE_CACHE_PATH": "cache/clang", "SWIFTPM_MODULECACHE_OVERRIDE": "cache/swift",
                            "XDG_CACHE_HOME": "cache/xdg", "TMPDIR": "tmp"}.items():
            path = self.work / suffix
            path.mkdir(parents=True, exist_ok=True)
            self.environment[key] = str(path)
        self.environment.update(TERM="dumb", NO_COLOR="1")
        self.sequence, self.packages, self.binaries, self.expected = 0, {}, {}, {}
        self.manifest = {"schema": 1, "complete": False, "status": "preparing",
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "arguments": {**vars(args), "output": str(self.output)}, "platform": platform.platform(),
            "uname": platform.uname()._asdict(), "python": sys.version, "cpu_count": os.cpu_count(),
            "environment": {key: self.environment.get(key) for key in (
                "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "TZ", "SWIFT_DETERMINISTIC_HASHING",
                "LD_LIBRARY_PATH", "DEVELOPER_DIR", "SDKROOT")},
            "design": {"scope": "Case-dependent displayName or recognize+display batches, output consumption, and temporary-object cleanup",
                "recognition": "Included only in recognize-* workloads; labels-* accepts prepared recognized values",
                "excluded": ["fixture construction", "startup", "UI rendering", "whole-player performance"],
                "modules": "Separate IlliquidCore and driver targets, testing enabled, no cross-module optimization",
                "calibration": "Baseline process CPU determines one fixed iteration count shared by both variants",
                "order": "Fresh process per sample; even AB/BA pairs and rotated case order; every sample retained"},
            "statistics": {"reduction": "100 * (1 - candidate_ns_per_label / baseline_ns_per_label)",
                "bootstrap": "10,000 paired resamples; percentile 95% interval for median reduction; seed 20261028 plus case hash",
                "multiple_comparisons": "Descriptive intervals; no family-wise adjustment"}}
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        if hasattr(os, "getloadavg"):
            self.manifest["load_average_start"] = os.getloadavg()
        if Path("/proc/cpuinfo").is_file():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
        self.update()

    def update(self):
        save(self.output / "manifest.json", self.manifest)

    def command(self, argv, label, *, compressed=False, allowed=(0,)):
        argv = [str(value) for value in argv]
        self.sequence += 1
        logs = self.output / "logs"
        logs.mkdir(exist_ok=True)
        stem = f"{self.sequence:04d}-" + re.sub(r"[^A-Za-z0-9_.-]", "_", label)
        out, err = logs / (stem + (".stdout.json.gz" if compressed else ".stdout.log")), logs / (stem + ".stderr.log")
        started, utc = time.monotonic(), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        try:
            result = subprocess.run(argv, cwd=ROOT, env=self.environment, capture_output=True, timeout=1800)
        except subprocess.TimeoutExpired as error:
            result = subprocess.CompletedProcess(argv, 124, error.stdout or b"", error.stderr or b"")
        out.write_bytes(gzip.compress(result.stdout, mtime=0) if compressed else result.stdout)
        err.write_bytes(result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"sequence": self.sequence, "label": label, "argv": argv, "cwd": str(ROOT),
                "started_utc": utc, "elapsed_seconds": time.monotonic() - started, "returncode": result.returncode,
                "stdout": str(out.relative_to(self.output)), "stderr": str(err.relative_to(self.output)),
                "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)}, sort_keys=True) + "\n")
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {err}\n"
                               + (result.stdout + result.stderr).decode(errors="replace")[-6000:])
        return result.stdout

    def prepare(self):
        pinned = json.loads((HERE / "baseline/manifest.json").read_bytes())
        baseline = (HERE / "baseline" / pinned["source"]["snapshot"]).read_bytes()
        checked(baseline, pinned["source"], "frozen MediaNameRecognition.swift")
        original = self.command(["git", "show", f"{pinned['commit']}:{SOURCE}"], "baseline-provenance", compressed=True, allowed=(0, 128))
        if original:
            checked(original, pinned["source"], "original production source")
        tests = {f"Tests/IlliquidCoreTests/{name}.swift": (ROOT / f"Tests/IlliquidCoreTests/{name}.swift").read_bytes() for name in TESTS}
        for path, expected in pinned["existing_tests"].items():
            checked(tests[path], expected, path)
        candidate, driver = (ROOT / SOURCE).read_bytes(), (HERE / "Driver.swift").read_bytes()
        inputs = {"baseline/MediaNameRecognition.swift": baseline,
                  "baseline/manifest.json": (HERE / "baseline/manifest.json").read_bytes(),
                  "candidate/MediaNameRecognition.swift": candidate, "Driver.swift": driver,
                  "run.py": Path(__file__).read_bytes(), "Package.swift": PACKAGE.encode(), **tests}
        self.manifest.update(baseline_commit=pinned["commit"], baseline_git_history_verified=bool(original), input_sources={})
        for path, data in inputs.items():
            destination = self.output / "inputs" / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            self.manifest["input_sources"][path] = record(data)
        for variant, source in (("baseline", baseline), ("candidate", candidate)):
            package = self.work / "packages" / variant
            for path, data in {"Package.swift": PACKAGE.encode(), "Sources/IlliquidCore/MediaNameRecognition.swift": source,
                               "Sources/EpisodeDisplayNameDriver/Driver.swift": driver, **tests}.items():
                destination = package / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            self.packages[variant] = package
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head").decode().strip()
        self.manifest["worktree"] = self.command(["git", "status", "--short"], "worktree").decode()
        self.manifest["swift"] = {"path": self.swift, "version": self.command([self.swift, "--version"], "swift-version").decode().strip(),
                                  "sha256": sha(Path(self.swift).read_bytes())}
        frontend = Path(self.swift).parent / "swift-frontend"
        if frontend.is_file():
            self.manifest["swift"]["frontend_sha256"] = sha(frontend.read_bytes())
        if sys.platform == "darwin":
            self.manifest["macos"] = self.command(["sw_vers"], "macos").decode().strip()
            self.manifest["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model").decode().strip()
        self.update()

    def swift_command(self, variant, action, configuration):
        return [self.swift, action, "--package-path", self.packages[variant], "--scratch-path", self.work / "build" / variant,
                "--cache-path", self.work / "cache/packages", "--config-path", self.work / "cache/config",
                "--security-path", self.work / "cache/security", "--jobs", self.args.jobs, "--configuration", configuration]

    def qualify(self):
        tests = []
        for configuration in ("debug", "release"):
            for variant in VARIANTS:
                print(f"Testing {variant} ({configuration})", flush=True)
                self.command(self.swift_command(variant, "test", configuration) + ["--no-parallel", "-Xswiftc", "-warnings-as-errors"],
                             f"tests-{variant}-{configuration}")
                logs = self.output / "logs"
                text = "".join(path.read_text(errors="replace") for path in logs.glob(f"{self.sequence:04d}-*.log"))
                counts = re.findall(r"Test run with (\d+) tests?", text)
                if not counts or int(counts[-1]) == 0:
                    raise ValueError("No completed Swift Testing tests reported")
                tests.append({"variant": variant, "configuration": configuration, "count": int(counts[-1]), "passed": True})
                save(self.output / "tests.json", tests)
        if len({row["count"] for row in tests}) != 1:
            raise ValueError("Debug/release or baseline/candidate test counts differ")
        binaries, lists, receipts = {}, {}, {}
        for variant in VARIANTS:
            build = self.swift_command(variant, "build", "release")
            self.command(build + ["--product", "EpisodeDisplayNameProbe"], f"build-{variant}")
            directory = self.command(build + ["--show-bin-path"], f"bin-path-{variant}").decode().strip()
            self.binaries[variant] = Path(directory) / "EpisodeDisplayNameProbe"
            binaries[variant] = {"path": str(self.binaries[variant]), "sha256": sha(self.binaries[variant].read_bytes())}
            lists[variant] = json.loads(self.command([self.binaries[variant], "--list"], f"list-{variant}"))
            receipts[variant] = json.loads(self.command([self.binaries[variant], "--verify"], f"verify-{variant}", compressed=True))
        save(self.output / "binaries.json", binaries)
        if lists["baseline"] != lists["candidate"] or receipts["baseline"] != receipts["candidate"]:
            raise ValueError("Complete output receipts or workload lists differ")
        cases, verified = lists["candidate"], receipts["candidate"]
        by_name = {row["name"]: row for row in verified}
        if not cases or len(by_name) != len(verified) or len({row["name"] for row in cases}) != len(cases):
            raise ValueError("Empty or duplicate workload/receipt names")
        for receipt in verified:
            calculated = sum((index + 1) * len(label.encode("utf-8")) for index, label in enumerate(receipt["labels"]))
            if type(receipt["checksum"]) is not int or receipt["checksum"] != calculated:
                raise ValueError(f"Verification checksum disagrees with full UTF-8 output: {receipt['name']}")
        for case in cases:
            receipt = by_name[case["name"]]
            if type(case["batch_size"]) is not int or case["batch_size"] <= 0 or len(receipt["labels"]) != case["batch_size"]:
                raise ValueError("Verification label count does not match workload batch size")
            # Python strings preserve code points: this also explicitly checks
            # UTF-8 bytes without Swift's canonically equivalent String equality.
            baseline = next(row for row in receipts["baseline"] if row["name"] == case["name"])
            if [label.encode("utf-8") for label in baseline["labels"]] != [label.encode("utf-8") for label in receipt["labels"]]:
                raise ValueError("Exact UTF-8 label bytes differ")
            self.expected[case["name"]] = {"batch_size": case["batch_size"], "checksum": receipt["checksum"]}
        complete = canonical(verified)
        (self.output / "verification-receipts.json.gz").write_bytes(gzip.compress(complete, mtime=0))
        save(self.output / "parity.json", {"equal": True, "exact_utf8": True, "receipts": len(verified),
            "labels": sum(len(row["labels"]) for row in verified), "sha256": sha(complete), "expected": self.expected})
        save(self.output / "cases.json", cases)
        if self.args.case:
            unknown = set(self.args.case) - {row["name"] for row in cases}
            if unknown:
                raise ValueError(f"Unknown --case values: {sorted(unknown)}")
            cases = [row for row in cases if row["name"] in self.args.case]
        self.manifest["selected_cases"] = cases
        self.update()
        print(f"PASS exact UTF-8 parity: {len(verified)} receipts; {len(cases)} selected workloads", flush=True)
        return cases

    def measure(self, variant, case, count, label):
        row = json.loads(self.command([self.binaries[variant], "--measure", case["name"], count], label))
        expected = self.expected[case["name"]]
        checksum = signed64(expected["checksum"] * count)
        if (row.get("case") != case["name"] or row.get("iterations") != count
                or row.get("labels_per_iteration") != expected["batch_size"]
                or row.get("checksum") != checksum or row.get("expected_checksum") != checksum
                or row.get("postflight_matches") is not True
                or any(type(row.get(key)) is not int or row[key] <= 0 for key in ("cpu_ns", "wall_ns"))):
            raise ValueError(f"Invalid measurement identity, output, or timing: {label}")
        return {**row, "variant": variant, "command_sequence": self.sequence,
                **{f"{metric}_per_batch": row[metric] / count for metric in ("cpu_ns", "wall_ns")},
                **{f"{metric}_per_label": row[metric] / count / expected["batch_size"] for metric in ("cpu_ns", "wall_ns")}}

    def benchmark(self, cases):
        iterations, rows = {}, []
        target = self.args.target_ms * 1_000_000
        threshold = min(target, max(1_000_000, target / 4))
        for case in cases:
            count, attempt = 1, 0
            while True:
                row = self.measure("baseline", case, count, f"calibrate-{case['name']}-{attempt}")
                with (self.output / "calibration.jsonl").open("a") as stream:
                    stream.write(json.dumps({**row, "attempt": attempt, "target_cpu_ns": target}, sort_keys=True) + "\n")
                if row["cpu_ns"] >= threshold or count == MAX_ITERATIONS:
                    iterations[case["name"]] = min(MAX_ITERATIONS, max(1, math.ceil(count * target / row["cpu_ns"])))
                    break
                count = min(MAX_ITERATIONS, count * min(32, max(2, math.ceil(threshold / row["cpu_ns"]))))
                attempt += 1
        save(self.output / "iterations.json", iterations)
        indexed = list(enumerate(cases))
        for pair in range(self.args.pairs):
            offset = pair % len(indexed)
            for index, case in indexed[offset:] + indexed[:offset]:
                order = VARIANTS if (pair + index) % 2 == 0 else tuple(reversed(VARIANTS))
                for position, variant in enumerate(order):
                    row = self.measure(variant, case, iterations[case["name"]], f"pair-{pair:02d}-{case['name']}-{variant}")
                    row.update(pair=pair, position_in_pair=position, order=list(order))
                    rows.append(row)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Completed balanced pair {pair + 1}/{self.args.pairs}", flush=True)
        summaries = []
        for case in cases:
            samples = [row for row in rows if row["case"] == case["name"]]
            result = {**case, "pairs": self.args.pairs, "iterations_both_variants": iterations[case["name"]]}
            for variant in VARIANTS:
                subset = [row for row in samples if row["variant"] == variant]
                if len(subset) != self.args.pairs:
                    raise ValueError("Missing observations")
                result[variant] = {metric: distribution([row[metric] for row in subset]) for metric in (
                    "cpu_ns_per_batch", "wall_ns_per_batch", "cpu_ns_per_label", "wall_ns_per_label")}
            for metric in ("cpu_ns_per_label", "wall_ns_per_label"):
                reductions = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[metric] for row in samples if row["pair"] == pair}
                    if set(values) != set(VARIANTS):
                        raise ValueError("Incomplete observation pair")
                    reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
                result[metric.replace("_ns_per_label", "_reduction_percent")] = {
                    **distribution(reductions), "paired_values": reductions, "faster_pairs": sum(x > 0 for x in reductions),
                    "bootstrap_median_95_ci": interval(reductions, case["name"] + metric),
                    "ratio_of_medians": 100 * (1 - result["candidate"][metric]["median"] / result["baseline"][metric]["median"])}
            summaries.append(result)
        save(self.output / "summary.json", summaries)

    def run(self):
        if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
            print("Shared Kyoto queue unavailable; compiling isolated packages directly and serially.", flush=True)
        self.prepare()
        cases = self.qualify()
        if not self.args.verify_only:
            self.benchmark(cases)
        self.manifest.update(complete=True, status="verified_only" if self.args.verify_only else "measured",
                             finished_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        if hasattr(os, "getloadavg"):
            self.manifest["load_average_end"] = os.getloadavg()
        self.update()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--case", action="append")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.jobs < 1 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("pairs must be positive and even (at least 2); jobs and target-ms must be positive")
    study = None
    try:
        study = Study(args)
        study.run()
        return 0
    except Exception as error:
        if study:
            save(study.output / "failure.json", {"error": str(error), "traceback": traceback.format_exc()})
            study.manifest.update(complete=False, status="failed", error=str(error))
            study.update()
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
