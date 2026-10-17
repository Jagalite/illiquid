#!/usr/bin/env python3
"""Reproduce the PCM sanitation experiment using exact production Swift.

Uses only Python's standard library. Generated sources, binaries, output records,
compiler/test logs, and a provenance report go to --output (a temporary directory
by default). The runner never edits production source or fetches dependencies.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import gzip
import base64
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
import tempfile
import time
from typing import Any

BASELINE = "8c3cc3d4008d5d1b8d436bcf2d51d891382b6548"
ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATHS = ("Sources/IlliquidNativePlayback/Media/AudioDecoder.swift",)
TEST_PATH = "Tests/IlliquidNativePlaybackTests/AudioSampleSanitizationTests.swift"
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library", "-enable-testing"]



def sha(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, kind: str, name: str) -> str:
    """Copy one balanced top-level declaration; skip comments/string braces.

    This is a source slicer, not a replacement implementation. Nested block
    comments and ordinary/raw/multiline Swift strings are recognized so their
    braces do not change declaration boundaries. These two declarations contain
    no interpolated string expressions; fail closed if one is introduced.
    """
    matches = list(re.finditer(rf"(?m)^{kind} {re.escape(name)}\b", source))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one top-level {kind} {name}")
    start = matches[0].start()
    index = source.find("{", matches[0].end())
    if index < 0:
        raise ValueError(f"Missing opening brace for {name}")
    depth = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            index = len(source) if end < 0 else end + 1
            continue
        if source.startswith("/*", index):
            nesting = 1
            index += 2
            while nesting and index < len(source):
                if source.startswith("/*", index):
                    nesting += 1
                    index += 2
                elif source.startswith("*/", index):
                    nesting -= 1
                    index += 2
                else:
                    index += 1
            if nesting:
                raise ValueError(f"Unclosed block comment in {name}")
            continue
        string_start = re.match(r'(#+)?("""|")', source[index:])
        if string_start:
            hashes = string_start.group(1) or ""
            quote = string_start.group(2)
            terminator = quote + hashes
            index += len(string_start.group(0))
            while index < len(source):
                if source.startswith("\\" + hashes + "(", index):
                    raise ValueError(f"String interpolation added to {name}; review slicer before extraction")
                if source.startswith("\\" + hashes, index):
                    index += 2 + len(hashes)
                    continue
                if source.startswith(terminator, index):
                    index += len(terminator)
                    break
                index += 1
            else:
                raise ValueError(f"Unclosed string in {name}")
            continue
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1] + "\n"
        index += 1
    raise ValueError(f"Unbalanced declaration {name}")


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.runner_source = Path(__file__).read_bytes()
        (self.output / "runner.snapshot.py").write_bytes(self.runner_source)
        self.commands: list[dict[str, Any]] = []
        self.verified_case_hashes: dict[str, str] = {}
        self.env = os.environ.copy()
        self.env["SWIFT_MODULECACHE_PATH"] = str(self.output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.started = datetime.now(timezone.utc).isoformat()
        # swiftc is usually a symlink to swift-driver; argv[0] selects compiler
        # mode, so make the path absolute without resolving the final symlink.
        self.swiftc = os.path.abspath(args.swiftc)
        self.swift = str(Path(self.swiftc).with_name("swift"))
        self.compiler_version = self.command([self.swiftc, "--version"]).strip()

    def command(self, command: list[str], *, log: Path | None = None,
                cwd: Path = ROOT) -> str:
        started = time.monotonic()
        result = subprocess.run(command, cwd=cwd, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.commands.append({"argv": command, "cwd": str(cwd),
                              "elapsed_seconds": time.monotonic() - started,
                              "returncode": result.returncode,
                              "stdout_sha256": sha(result.stdout),
                              "stderr_sha256": sha(result.stderr)})
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n"
                               f"{result.stdout[-4000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def read_source(self, label: str, path: str) -> str:
        if label == "candidate":
            return (ROOT / path).read_text()
        if self.args.baseline_dir:
            return (self.args.baseline_dir / path).read_text()
        return self.command(["git", "show", f"{self.args.baseline}:{path}"])

    def sources(self, label: str) -> tuple[dict[str, str], dict[str, Any]]:
        raw = self.read_source(label, SOURCE_PATHS[0])
        result = declaration(raw, "struct", "AudioSampleSanitizationResult")
        function = declaration(raw, "func", "sanitizeInterleavedFloatPCM")
        decorated = "@discardableResult\n" + function
        if decorated not in raw:
            raise ValueError("Sanitizer attribute/layout changed; review extraction")
        extracted = {"Sanitizer.swift": "import Foundation\n\n" + result + "\n" + decorated}
        receipt = {
            "source_kind": "working_tree" if label == "candidate" else
                ("directory" if self.args.baseline_dir else "git_revision"),
            "revision": self.args.baseline if label == "baseline" and not self.args.baseline_dir else None,
            "files": {SOURCE_PATHS[0]: {"sha256": sha(raw), "bytes": len(raw.encode())}},
            "declarations": {"AudioSampleSanitizationResult": sha(result),
                             "sanitizeInterleavedFloatPCM": sha(decorated)},
            "generated": {name: sha(content) for name, content in extracted.items()},
        }
        return extracted, receipt

    def prepare(self) -> dict[str, Any]:
        harness = (Path(__file__).parent / "Harness.swift").read_text()
        receipt: dict[str, Any] = {"compiler": self.compiler_version, "flags": FLAGS,
                                   "runner_sha256": sha(self.runner_source),
                                   "harness_sha256": sha(harness), "sources": {}, "binaries": {}}
        old_path = self.output / "build-receipt.json"
        old = json.loads(old_path.read_text()) if old_path.exists() else None
        for label in ("baseline", "candidate"):
            extracted, source_receipt = self.sources(label)
            directory = self.output / label
            directory.mkdir(exist_ok=True)
            for name, content in extracted.items():
                (directory / name).write_text(content)
            (directory / "Harness.swift").write_text(harness)
            receipt["sources"][label] = source_receipt
            binary = directory / "benchmark"
            fingerprint = sha(json.dumps({"source": source_receipt,
                                          "compiler": self.compiler_version,
                                          "flags": FLAGS, "harness": sha(harness),
                                          "runner": receipt["runner_sha256"]}, sort_keys=True))
            if self.args.reuse_build:
                previous = old.get("binaries", {}).get(label, {}) if old else {}
                if not (previous.get("build_fingerprint") == fingerprint and binary.exists()
                        and previous.get("sha256") == sha(binary.read_bytes())):
                    raise ValueError(f"Cannot reuse {label}: sources/compiler/harness/binary changed; rerun without --reuse-build")
            else:
                print(f"Compiling {label} with {self.compiler_version.splitlines()[0]}", flush=True)
                self.command([self.swiftc, *FLAGS, "-module-cache-path", str(self.output / "module-cache"),
                              "-module-name", "IlliquidNativePlayback", "-emit-object", "-emit-module",
                              "-emit-module-path", str(directory / "IlliquidNativePlayback.swiftmodule"),
                              str(directory / "Sanitizer.swift"), "-o", str(directory / "IlliquidNativePlayback.o")],
                             log=directory / "compile-core.log")
                self.command([self.swiftc, *FLAGS, "-module-cache-path", str(self.output / "module-cache"),
                              "-I", str(directory), str(directory / "Harness.swift"),
                              str(directory / "IlliquidNativePlayback.o"), "-o", str(binary)], log=directory / "compile.log")
            receipt["binaries"][label] = {"path": str(binary), "sha256": sha(binary.read_bytes()),
                                           "build_fingerprint": fingerprint}
        write_json(old_path, receipt)
        return receipt

    def binary(self, label: str, options: list[str]) -> list[dict[str, Any]]:
        output = self.command([str(self.output / label / "benchmark"), *options])
        return [json.loads(line) for line in output.splitlines() if line.strip()]

    def verify(self) -> dict[str, Any]:
        records = {}
        for label in ("baseline", "candidate"):
            records[label] = self.binary(label, ["--verify"])
            with gzip.open(self.output / f"verification-{label}.json.gz", "wt") as sink:
                json.dump(records[label], sink, sort_keys=True)
        if records["baseline"] != records["candidate"]:
            left = {item["case"]: item for item in records["baseline"]}
            right = {item["case"]: item for item in records["candidate"]}
            changed = [name for name in sorted(set(left) | set(right)) if left.get(name) != right.get(name)]
            raise ValueError(f"Exact output comparison failed: {changed}")
        count = sum(len(item["outputs"]) for item in records["baseline"])
        compared_bytes = sum(len(base64.b64decode(output["sanitized_base64"]))
                             for item in records["baseline"] for output in item["outputs"])
        self.verified_case_hashes = {item["case"]: sha(json.dumps(item["outputs"], sort_keys=True))
                                    for item in records["baseline"]}
        result = {"exact_byte_equality": True, "cases": len(records["baseline"]),
                  "inputs": count, "compared_output_bytes": compared_bytes,
                  "restoration_and_shared_alias_checks": True,
                  "output_sha256": sha(json.dumps(records["baseline"], sort_keys=True))}
        print(f"Exact output equality: {result['cases']} cases, {count} input variants, {compared_bytes} output bytes", flush=True)
        return result

    def benchmark(self) -> dict[str, Any]:
        probe = self.binary("baseline", ["--iterations", str(self.args.probe_iterations)])
        selected_names = set(self.args.case or [])
        if self.args.case_file:
            selected_names.update(json.loads(self.args.case_file.read_text()))
        known = {item["case"] for item in probe}
        if selected_names - known:
            raise ValueError(f"Unknown case names: {sorted(selected_names - known)}")
        selected = [item for item in probe if not selected_names or item["case"] in selected_names]
        counts = {}
        for item in selected:
            count = max(16, math.ceil(self.args.target_ms * 1_000_000 / item["ns_per_iteration"]))
            # A whole number of sixteen-fixture cycles gives equal weighting.
            counts[item["case"]] = min(self.args.max_iterations // 16 * 16, math.ceil(count / 16) * 16)
        write_json(self.output / "calibration.json", probe)
        iteration_path = self.output / "iterations.json"
        write_json(iteration_path, counts)
        # A complete fresh process evaluates all selected cases. A missing case
        # count is skipped via --cases-file, not silently timed with a default.
        case_path = self.output / "cases.json"
        write_json(case_path, list(counts))
        raw_path = self.output / "measurements.jsonl"
        all_records = []
        with raw_path.open("w") as sink:
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                print(f"Pair {pair + 1}/{self.args.pairs}: {' then '.join(order)}; {len(counts)} cases", flush=True)
                paired = {}
                for position, label in enumerate(order):
                    traversal = ["--reverse"] if pair % 2 else []
                    records = self.binary(label, ["--iterations-file", str(iteration_path),
                                                   "--cases-file", str(case_path), *traversal])
                    if {item["case"] for item in records} != set(counts):
                        raise ValueError("Binary returned an unexpected benchmark case set")
                    for case_position, item in enumerate(records):
                        item.update({"variant": label, "pair": pair + 1,
                                     "order": "AB" if pair % 2 == 0 else "BA",
                                     "position": position + 1,
                                     "case_position": case_position + 1,
                                     "verification_output_sha256": self.verified_case_hashes[item["case"]],
                                     "case_traversal": "reverse" if pair % 2 else "forward"})
                        sink.write(json.dumps(item, sort_keys=True) + "\n")
                        sink.flush()
                        all_records.append(item)
                    paired[label] = {item["case"]: item for item in records}
                for name in counts:
                    for key in ("iterations", "checksum", "warmup_checksum", "replaced_nonfinite", "replaced_subnormal", "expected_nonfinite", "expected_subnormal"):
                        if paired["baseline"][name][key] != paired["candidate"][name][key]:
                            raise ValueError(f"Timed output mismatch in pair {pair + 1}, {name}, {key}")
        summary = []
        for name in counts:
            by_variant = {label: [r for r in all_records if r["case"] == name and r["variant"] == label]
                          for label in ("baseline", "candidate")}
            baseline = [r["ns_per_iteration"] for r in by_variant["baseline"]]
            candidate = [r["ns_per_iteration"] for r in by_variant["candidate"]]
            paired_ratios = [c / b for b, c in zip(baseline, candidate)]
            baseline_cpu = [r["cpu_ns_per_iteration"] for r in by_variant["baseline"]]
            candidate_cpu = [r["cpu_ns_per_iteration"] for r in by_variant["candidate"]]
            paired_cpu_ratios = [c / b for b, c in zip(baseline_cpu, candidate_cpu)]
            row = {"case": name, "iterations_per_process": counts[name],
                   "pairs": self.args.pairs,
                   "baseline_median_ns": statistics.median(baseline),
                   "candidate_median_ns": statistics.median(candidate),
                   "median_paired_ratio": statistics.median(paired_ratios),
                   "median_paired_reduction_percent": 100 * (1 - statistics.median(paired_ratios)),
                   "baseline_median_cpu_ns": statistics.median(baseline_cpu),
                   "candidate_median_cpu_ns": statistics.median(candidate_cpu),
                   "median_paired_cpu_reduction_percent": 100 * (1 - statistics.median(paired_cpu_ratios)),
                   "paired_cpu_ratios": paired_cpu_ratios,
                   "paired_ratios": paired_ratios,
                   "baseline_samples_ns": baseline, "candidate_samples_ns": candidate}
            summary.append(row)
        write_json(self.output / "summary.json", summary)
        print("case | baseline us | candidate us | wall reduction | CPU reduction", flush=True)
        for row in summary:
            print(f"{row['case']} | {row['baseline_median_ns'] / 1000:.3f} | "
                  f"{row['candidate_median_ns'] / 1000:.3f} | "
                  f"{row['median_paired_reduction_percent']:.1f}% | "
                  f"{row['median_paired_cpu_reduction_percent']:.1f}%", flush=True)
        return {"pairs": self.args.pairs, "cases": len(counts),
                "fresh_processes": self.args.pairs * 2,
                "balanced_order": self.args.pairs % 2 == 0,
                "target_ms_per_baseline_case": self.args.target_ms,
                "measurement_records": len(all_records),
                "raw_sha256": sha(raw_path.read_bytes()), "summary": summary}

    def test_variant(self, label: str) -> dict[str, Any]:
        package = self.output / f"tests-{label}"
        target = package / "Sources" / "IlliquidNativePlayback"
        tests = package / "Tests" / "IlliquidNativePlaybackTests"
        for directory in (target, tests):
            directory.mkdir(parents=True, exist_ok=True)
        extracted, receipt = self.sources(label)
        (target / "Sanitizer.swift").write_text(extracted["Sanitizer.swift"])
        test = (ROOT / TEST_PATH).read_text()
        if re.search(r"(?m)^\s*(?:@testable\s+)?import\s+XCTest\b", test):
            raise ValueError("Focused package uses Swift Testing; review framework flags if XCTest tests are added")
        (tests / Path(TEST_PATH).name).write_text(test)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PCMSanitizationValidation", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
        configurations = ["debug", "release"] if self.args.test_configuration == "both" else [self.args.test_configuration]
        for configuration in configurations:
            print(f"Running exact-source tests ({label}, {configuration})", flush=True)
            instrumentation = ["--sanitize", self.args.sanitize] if self.args.sanitize else []
            output = self.command([self.swift, "test", "--package-path", str(package),
                                   "--scratch-path", str(package / "build"),
                                   "--cache-path", str(package / "cache"),
                                   "--disable-sandbox", "--disable-xctest", "--enable-swift-testing",
                                   "--jobs", str(self.args.jobs),
                                   "-c", configuration, *instrumentation], log=self.output / f"tests-{label}-{configuration}.log")
            print(output[-3500:], flush=True)
        return {"configurations": configurations, "sanitizer": self.args.sanitize, "test_sha256": sha(test),
                "test_source": TEST_PATH, "production_sources": receipt,
                "module_shape": {"IlliquidNativePlayback": ["AudioSampleSanitizationResult", "sanitizeInterleavedFloatPCM"]}}

    def tests(self) -> dict[str, Any]:
        labels = ["baseline", "candidate"] if self.args.test_variant == "both" else [self.args.test_variant]
        return {label: self.test_variant(label) for label in labels}

    def report(self, results: dict[str, Any], error: str | None = None) -> None:
        cpu_model = None
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.exists():
            match = re.search(r"(?m)^model name\s*:\s*(.+)$", cpuinfo.read_text())
            cpu_model = match.group(1) if match else None
        try:
            head = self.command(["git", "rev-parse", "HEAD"]).strip()
            status = self.command(["git", "status", "--short", "--", *SOURCE_PATHS, TEST_PATH,
                                   "Benchmarks/PCMSanitization"]).splitlines()
        except RuntimeError:
            head, status = None, []
        report = {
            "started_at_utc": self.started, "finished_at_utc": datetime.now(timezone.utc).isoformat(),
            "error": error, "results": results,
            "environment": {"platform": platform.platform(), "machine": platform.machine(),
                            "cpu_model": cpu_model, "logical_cpus": os.cpu_count(),
                            "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
                            "python": sys.version, "swift": self.compiler_version,
                            "libc": platform.libc_ver(), "candidate_git_head": head,
                            "candidate_git_status": status,
                            "controlled_environment": {key: self.env.get(key) for key in
                                ("LD_LIBRARY_PATH", "SWIFT_MODULECACHE_PATH", "CLANG_MODULE_CACHE_PATH", "ASAN_OPTIONS")}},
            "runner_sha256": sha(self.runner_source),
            "invocation": sys.argv,
            "commands": self.commands,
            "scope": "Exact portable PCM sanitation component work. Dirty envelopes include restoration and expose restore-only controls; shared cases include Data COW. No audio decoding, resampling, playback, app-level CPU, or memory claim.",
        }
        write_json(self.output / "report.json", report)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("verify", "benchmark", "test", "all"), default="benchmark")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--baseline-dir", type=Path,
                        help="Optional unpacked baseline tree if the pinned commit is absent in a shallow checkout")
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--reuse-build", action="store_true", help="Require byte-identical previously compiled sources/binaries")
    parser.add_argument("--pairs", type=int, default=6, help="Balanced AB/BA pairs; formal runs require an even number >=6")
    parser.add_argument("--exploratory", action="store_true", help="Permit fewer than six pairs for pilot work")
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--probe-iterations", type=int, default=512)
    parser.add_argument("--max-iterations", type=int, default=4_000_000)
    parser.add_argument("--case", action="append", help="Exact case name; repeat to select a subset")
    parser.add_argument("--case-file", type=Path, help="JSON array of exact case names")
    parser.add_argument("--test-configuration", choices=("debug", "release", "both"), default="both")
    parser.add_argument("--test-variant", choices=("baseline", "candidate", "both"), default="candidate")
    parser.add_argument("--sanitize", choices=("address",), help="Instrument test builds using SwiftPM AddressSanitizer")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc was not found; supply --swiftc /path/to/swiftc")
    if args.pairs < 1 or not math.isfinite(args.target_ms) or args.target_ms <= 0 or args.probe_iterations < 1 or args.max_iterations < 16 or args.jobs < 1:
        parser.error("pair/iteration/job counts and target duration must be positive")
    if not args.exploratory and (args.pairs < 6 or args.pairs % 2):
        parser.error("Formal runs require an even number of pairs >=6; use --exploratory for a pilot")
    if args.output is None:
        args.output = Path(tempfile.mkdtemp(prefix="illiquid-pcm-sanitization-"))
    return args


def main() -> int:
    args = arguments()
    runner = Runner(args)
    results: dict[str, Any] = {}
    try:
        if args.mode in ("verify", "benchmark", "all"):
            results["build"] = runner.prepare()
            results["verification"] = runner.verify()
        if args.mode in ("test", "all"):
            results["tests"] = runner.tests()
        if args.mode in ("benchmark", "all"):
            results["benchmark"] = runner.benchmark()
    except Exception as error:
        runner.report(results, str(error))
        print(f"ERROR: {error}\nPartial report: {runner.output / 'report.json'}", file=sys.stderr)
        return 1
    runner.report(results)
    print(f"Report: {runner.output / 'report.json'}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
