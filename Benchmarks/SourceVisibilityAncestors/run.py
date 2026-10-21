#!/usr/bin/env python3
"""Compare exact production visibility code with its retained parent revision.

Runs offline component tests and alternating fresh-process measurements. The
portable extraction excludes SwiftUI and native playback; macOS app CI remains
the integration gate. Baseline files are frozen, hashed, and never rewritten.
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
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CASES = ["small_library", "shared_one_rule", "shared_eight_rules", "deep_shared", "nearest_hidden",
         "unique_parents", "manual_only", "no_rules", "tree_control", "unicode"]
BASE = "a2de305c8dbcaa81aac1477df7c9a0017c14eae3"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--operations", default="matcher,project")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--cpu", type=int)
    args = parser.parse_args()
    cases, operations = args.cases.split(","), args.operations.split(",")
    if not args.swift or args.pairs < 1 or args.target_ms <= 0:
        parser.error("Swift, a positive pair count, and a positive target duration are required")
    if args.tests_only and args.skip_tests:
        parser.error("--tests-only and --skip-tests cannot be combined")
    if not set(cases) <= set(CASES) or not set(operations) <= {"matcher", "project"}:
        parser.error("Unknown workload or operation")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    if baseline["base_commit"] != BASE:
        raise ValueError("Unexpected baseline commit")
    for item in baseline["files"]:
        if digest((HERE / "baseline" / item["snapshot"]).read_bytes()) != item["snapshot_sha256"]:
            raise ValueError("Retained baseline content changed: " + item["snapshot"])
    spec = importlib.util.spec_from_file_location("browser_support", ROOT / "Scripts/test-source-browser-search.py")
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    input_paths = sorted(set([
        *support.DECLARATIONS,
        "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
        "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift",
        "Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift",
        "Sources/IlliquidApp/UI/SourceBrowserFilter.swift",
        "Tests/IlliquidAppTests/SourceBrowserSearchTests.swift",
        "Tests/IlliquidAppTests/SourceVisibilityAncestorCacheTests.swift",
        "Scripts/test-source-browser-search.py",
        *[str(path.relative_to(ROOT)) for path in HERE.rglob("*")
          if path.is_file() and (path.suffix in {".swift", ".py"} or path.name == "manifest.json")],
    ]))

    def source_hashes():
        return {path: digest((ROOT / path).read_bytes()) for path in input_paths}

    original_hashes = source_hashes()

    def check_unchanged_sources():
        if source_hashes() != original_hashes:
            raise ValueError("Benchmark inputs changed during this run; rerun with stable sources")

    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(output / "clang-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "swift-cache")

    def execute(command: list[str], label: str, timeout=900) -> str:
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout)
        with (output / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"label": label, "command": [str(x) for x in command],
                                  "returncode": result.returncode, "stderr": result.stderr}, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode})\n{result.stdout[-12000:]}\n{result.stderr[-12000:]}")
        return result.stdout

    version = execute([args.swift, "--version"], "toolchain").strip()
    write_json(output / "environment.json", {
        "platform": platform.platform(), "machine": platform.machine(), "swift": version,
        "base_commit": BASE, "head": execute(["git", "rev-parse", "HEAD"], "head").strip(),
        "cpu_affinity": args.cpu, "pairs": args.pairs, "target_ms": args.target_ms,
        "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "support_harness_sha256": digest((ROOT / "Scripts/test-source-browser-search.py").read_bytes()),
        "input_sha256": original_hashes,
    })
    binaries = {}
    with tempfile.TemporaryDirectory(prefix="illiquid-visibility-ancestors-") as temporary:
        temporary = Path(temporary)
        for variant in ("baseline", "candidate"):
            package = support.prepare_package(temporary / variant)
            if variant == "baseline":
                target = package / "Sources/IlliquidApp/SourceBrowserPortableSupport.swift"
                original = target.read_text()
                current, _, _ = support.declaration(original, "SourceVisibilityMatcher")
                retained = (HERE / "baseline/SourceVisibilityMatcher.swift").read_text().rstrip("\n")
                target.write_text(original.replace(current, retained, 1))
                shutil.copyfile(HERE / "baseline/SourceBrowserFilter.swift",
                                package / "Sources/IlliquidApp/SourceBrowserFilter.swift")
            shutil.copyfile(ROOT / "Tests/IlliquidAppTests/SourceVisibilityAncestorCacheTests.swift",
                            package / "Tests/IlliquidAppTests/SourceVisibilityAncestorCacheTests.swift")
            driver = package / "Sources/VisibilityBenchmark/Driver.swift"
            driver.parent.mkdir()
            shutil.copyfile(HERE / "Driver.swift", driver)
            manifest = (package / "Package.swift").read_text()
            manifest = manifest.replace('        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),',
                '        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"], swiftSettings: [.unsafeFlags(["-enable-testing"])]),\n'
                '        .executableTarget(name: "VisibilityBenchmark", dependencies: ["IlliquidApp"]),')
            (package / "Package.swift").write_text(manifest)
            write_json(output / f"{variant}-sources.json", {
                "variant": variant, "base_commit": BASE,
                "retained_baseline": baseline if variant == "baseline" else None,
                "pre_override_extraction_receipt": json.loads((package / "source-receipt.json").read_text()),
                "overrides": (["SourceVisibilityMatcher declaration replaced with retained baseline",
                               "SourceBrowserFilter.swift replaced with retained baseline"]
                              if variant == "baseline" else []),
                "staging_additions": ["SourceVisibilityAncestorCacheTests.swift", "Driver.swift",
                                      "benchmark target and enable-testing manifest settings"],
                "compiled_files": {str(path.relative_to(package)): digest(path.read_bytes())
                                   for path in sorted(package.rglob("*.swift"))},
            })
            check_unchanged_sources()
            flags = ["--package-path", str(package), "--scratch-path", str(package / ".build"),
                     "--cache-path", str(temporary / "package-cache"),
                     "--config-path", str(temporary / "package-config"),
                     "--security-path", str(temporary / "package-security"), "--jobs", "2"]
            if not args.skip_tests:
                for configuration in ("debug", "release"):
                    label = f"{variant}-{configuration}-tests"
                    text = execute([args.swift, "test", *flags, "-c", configuration, "--no-parallel"], label)
                    (output / f"{label}.txt").write_text(text)
                    counts = re.findall(r"Test run with (\d+) tests?\b", text)
                    if not counts or int(counts[-1]) < 16:
                        raise RuntimeError(f"{label} did not complete expected tests")
                    print(f"{label}: {counts[-1]} tests passed", flush=True)
            if args.tests_only:
                continue
            execute([args.swift, "build", *flags, "-c", "release", "--product", "VisibilityBenchmark"],
                    variant + "-build")
            bin_path = execute([args.swift, "build", *flags, "-c", "release", "--show-bin-path"],
                               variant + "-binary-path").strip()
            binaries[variant] = Path(bin_path) / "VisibilityBenchmark"
        if args.tests_only:
            check_unchanged_sources()
            write_json(output / "completion.json", {"tests": "passed", "timing": "not requested"})
            return 0

        check_unchanged_sources()

        if args.cpu is not None:
            if not hasattr(os, "sched_setaffinity"):
                raise ValueError("CPU affinity is supported only on Linux")
            os.sched_setaffinity(0, {args.cpu})
        parity = {}
        for variant in binaries:
            parity[variant] = json.loads(execute([binaries[variant], "parity"], variant + "-parity"))
            write_json(output / f"{variant}-parity.json", parity[variant])
        if parity["baseline"] != parity["candidate"]:
            raise ValueError("Full differential outputs differ")
        write_json(output / "parity.json", {"exact_equal": True, "cases": len(parity["baseline"]),
                                           "input_rows_compared": sum(x["input_count"] for x in parity["baseline"])})
        receipts, measurements = {}, []

        def measure(variant: str, case: str, operation: str, iterations: int, phase: str, pair: int):
            record = json.loads(execute([binaries[variant], case, operation, str(iterations)],
                                        f"{phase}-{variant}-{case}-{operation}-{pair}"))
            if (record["case"], record["operation"], record["iterations"]) != (case, operation, iterations):
                raise ValueError("Benchmark result does not match command")
            receipt = record.pop("receipt")
            key = (case, operation)
            if key in receipts and receipts[key] != receipt:
                raise ValueError(f"Full result changed for {key}")
            receipts[key] = receipt
            path = output / "receipts" / f"{variant}-{case}-{operation}.json"
            if not path.exists():
                write_json(path, receipt)
            record.update(variant=variant, phase=phase, pair=pair,
                          ns_per_pass=record["elapsed_ns"] / iterations,
                          receipt_sha256=digest(json.dumps(receipt, sort_keys=True).encode()))
            if record["elapsed_ns"] <= 0 or record["checksum"] != record["input_count"] * iterations:
                raise ValueError("Empty or invalid measured workload")
            with (output / "measurements.jsonl").open("a") as log:
                log.write(json.dumps(record, sort_keys=True) + "\n")
            return record

        for case in cases:
            for operation in operations:
                trials = [measure(v, case, operation, 1, "calibration", -1) for v in binaries]
                iterations = max(1, min(1000, math.ceil(args.target_ms * 1_000_000 / min(x["elapsed_ns"] for x in trials))))
                for pair in range(args.pairs):
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    for variant in order:
                        measurements.append(measure(variant, case, operation, iterations, "timing", pair))
                print(f"measured {case}/{operation}: {args.pairs} fresh-process pairs", flush=True)
        summary = []
        for case in cases:
            for operation in operations:
                subset = [x for x in measurements if x["case"] == case and x["operation"] == operation]
                baseline_times = {x["pair"]: x["ns_per_pass"] for x in subset if x["variant"] == "baseline"}
                candidate_times = {x["pair"]: x["ns_per_pass"] for x in subset if x["variant"] == "candidate"}
                reductions = [100 * (1 - candidate_times[i] / baseline_times[i]) for i in baseline_times]
                summary.append({"case": case, "operation": operation,
                                "baseline_median_ms": statistics.median(baseline_times.values()) / 1e6,
                                "candidate_median_ms": statistics.median(candidate_times.values()) / 1e6,
                                "paired_reduction_percent_median": statistics.median(reductions),
                                "paired_reduction_percent_min": min(reductions),
                                "paired_reduction_percent_max": max(reductions), "pairs": args.pairs})
        write_json(output / "summary.json", summary)
        check_unchanged_sources()
        write_json(output / "completion.json", {"tests": "skipped" if args.skip_tests else "passed",
                                               "parity": "exact equal", "timing": "complete"})
        print(json.dumps(summary, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Ancestor visibility qualification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
