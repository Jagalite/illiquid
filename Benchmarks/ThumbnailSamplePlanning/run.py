#!/usr/bin/env python3
"""Compare the real thumbnail sample planner with a pinned production baseline."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shlex
import shutil
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
POLICY = Path("Sources/IlliquidCore/Player/ThumbnailPolicy.swift")
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "cf3b96706f34ba5c43041d650f4c9f6217e340cc"
WORKLOADS = [
    "storyboard-24", "economical-6", "balanced-12", "extensive-24",
    "maximum-64", "boundary-33", "exact-level-32", "exact-level-64",
    "one-sample", "short-duration",
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if not 2 <= args.pairs <= 30:
        parser.error("--pairs must be 2..30")
    if not 50 <= args.target_ms <= 2_000:
        parser.error("--target-ms must be 50..2000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    evidence = output / "evidence"
    build = output / "build"
    evidence.mkdir(parents=True, exist_ok=True)
    build.mkdir()
    command_count = 0

    def run(command: list, label: str, timeout: int = 180) -> str:
        nonlocal command_count
        command_count += 1
        command = [str(value) for value in command]
        process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        log = evidence / f"{command_count:03d}-{label}.log"
        log.write_text("$ " + shlex.join(command) + "\n" + process.stdout + process.stderr)
        if process.returncode:
            print(process.stdout, file=sys.stderr)
            print(process.stderr, file=sys.stderr)
            raise RuntimeError(f"{label} failed ({process.returncode}); see {log}")
        return process.stdout

    print("Kyoto is unavailable on this isolated runner; building serially in a private output directory.", flush=True)
    baseline = run(["git", "show", f"{BASELINE}:{POLICY}"], "baseline-source")
    raw_baseline = baseline.encode()
    actual_blob = hashlib.sha1(f"blob {len(raw_baseline)}\0".encode() + raw_baseline).hexdigest()
    if actual_blob != BASELINE_BLOB:
        raise RuntimeError(f"Baseline blob mismatch: {actual_blob}")
    candidate = (ROOT / POLICY).read_bytes()
    baseline_source = build / "Baseline.swift"
    baseline_source.write_bytes(raw_baseline)
    (evidence / "baseline.swift").write_bytes(raw_baseline)
    (evidence / "candidate.swift").write_bytes(candidate)
    flags = ["-swift-version", "6", "-warnings-as-errors"]
    if sys.platform == "darwin":
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]

    environment = {
        "baseline_commit": BASELINE, "baseline_git_blob": BASELINE_BLOB,
        "candidate_commit": run(["git", "rev-parse", "HEAD"], "revision").strip(),
        "baseline_sha256": sha256(raw_baseline), "candidate_sha256": sha256(candidate),
        "platform": platform.platform(), "machine": platform.machine(),
        "python": sys.version, "swift": run(["swiftc", "--version"], "swift-version").strip(),
        "compiler_flags": flags, "pairs": args.pairs, "target_ms": args.target_ms,
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "inputs": {str(path.relative_to(ROOT)): sha256(path.read_bytes())
                   for path in sorted(HERE.glob("*.swift")) + [Path(__file__).resolve()]},
    }
    if sys.platform == "darwin":
        environment["macos"] = run(["sw_vers"], "macos").strip()
        environment["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()

    # Rename types only in the differential reference. Timing uses the untouched
    # production file in two identically named, separately compiled modules.
    legacy = baseline
    for name in ("ThumbnailPreferences", "ThumbnailPolicy", "ThumbnailCacheUsage"):
        legacy = legacy.replace(name, "Baseline" + name)
    legacy_source = build / "LegacyPolicy.swift"
    legacy_source.write_text(legacy)
    validations = {"differential": {}, "unit_tests": {}, "timing_corpora": {}}
    for configuration, optimization in (("debug", "-Onone"), ("release", "-O")):
        binary = build / f"validate-{configuration}"
        run(["swiftc", *flags, optimization, "-parse-as-library",
             ROOT / POLICY, legacy_source, HERE / "Validate.swift", "-o", binary],
            f"compile-validation-{configuration}")
        validations["differential"][configuration] = json.loads(
            run([binary], f"validate-{configuration}")
        )
        print(f"PASS {configuration} differential: {validations['differential'][configuration]}", flush=True)

    package = build / "tests"
    source_dir = package / "Sources" / "IlliquidCore"
    test_dir = package / "Tests" / "IlliquidCoreTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    for name in ("ThumbnailPolicy", "ThumbnailPassCursor", "ThumbnailVisibilityPolicy"):
        source = ROOT / "Sources" / "IlliquidCore" / "Player" / f"{name}.swift"
        shutil.copy2(source, source_dir)
        environment["inputs"][str(source.relative_to(ROOT))] = sha256(source.read_bytes())
    for name in ("ThumbnailPolicyTests", "ThumbnailSchedulingPolicyRegressionTests", "ThumbnailSamplePlanningTests"):
        source = ROOT / "Tests" / "IlliquidCoreTests" / f"{name}.swift"
        shutil.copy2(source, test_dir)
        environment["inputs"][str(source.relative_to(ROOT))] = sha256(source.read_bytes())
    (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailSamplePlanningTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
    ]
)
""")
    for configuration in ("debug", "release"):
        log = run(["swift", "test", "--package-path", package, "-c", configuration,
                   "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"],
                  f"unit-tests-{configuration}", timeout=300)
        validations["unit_tests"][configuration] = {"passed": True, "sources": 3, "suites": 3}
        print(f"PASS {configuration} selected-source unit tests", flush=True)

    if args.tests_only:
        receipt = {"environment": environment, "validation": validations}
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("RESEARCH_RECEIPT_JSON=" + json.dumps(receipt, separators=(",", ":")), flush=True)
        return

    binaries = {}
    for variant, source in (("baseline", baseline_source), ("candidate", ROOT / POLICY)):
        directory = build / variant
        directory.mkdir()
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        library = directory / ("libThumbnailSamplePolicy" + suffix)
        run(["swiftc", *flags, "-O", "-parse-as-library", "-module-name", "ThumbnailSamplePolicy",
             "-emit-library", "-emit-module", "-emit-module-path", directory / "ThumbnailSamplePolicy.swiftmodule",
             source, "-o", library], f"compile-library-{variant}")
        binary = directory / "benchmark"
        run(["swiftc", *flags, "-O", "-parse-as-library", "-I", directory, "-L", directory,
             "-lThumbnailSamplePolicy", "-Xlinker", "-rpath", "-Xlinker", directory,
             HERE / "Benchmark.swift", "-o", binary], f"compile-benchmark-{variant}")
        binaries[variant] = binary
        environment[f"{variant}_binary_sha256"] = sha256(binary.read_bytes())
        environment[f"{variant}_library_sha256"] = sha256(library.read_bytes())

    for workload in WORKLOADS:
        original = json.loads(run([binaries["baseline"], workload, "outputs"], f"outputs-baseline-{workload}"))
        updated = json.loads(run([binaries["candidate"], workload, "outputs"], f"outputs-candidate-{workload}"))
        if original != updated:
            raise RuntimeError(f"Timing corpus differs: {workload}")
        validations["timing_corpora"][workload] = {
            "inputs": len(original), "bitwise_equal": True,
            "output_sha256": sha256(json.dumps(original, separators=(",", ":")).encode()),
        }

    calibrations, observations, iteration_counts = [], [], {}
    for workload in WORKLOADS:
        iterations = 10_000
        for attempt in range(3):
            value = json.loads(run([binaries["baseline"], workload, iterations], f"calibrate-{workload}-{attempt}"))
            value.update(variant="baseline", attempt=attempt)
            calibrations.append(value)
            elapsed_ms = value["wall_ns"] / 1_000_000
            if elapsed_ms >= 50 or iterations >= 10_000_000:
                break
            iterations = min(10_000_000, math.ceil(iterations * 60 / max(elapsed_ms, 0.01)))
        desired = math.ceil(value["iterations"] * args.target_ms / max(elapsed_ms, 0.01))
        iteration_counts[workload] = min(10_000_000, max(1_024, math.ceil(desired / 32) * 32))

    for pair in range(args.pairs):
        # Rotate workloads and alternate process order; both variants get the
        # same corpus, warmup count and baseline-calibrated iteration count.
        offset = pair % len(WORKLOADS)
        workloads = WORKLOADS[offset:] + WORKLOADS[:offset]
        order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        for workload in workloads:
            paired = {}
            for order_index, variant in enumerate(order):
                value = json.loads(run([binaries[variant], workload, iteration_counts[workload]],
                                       f"pair-{pair:02d}-{workload}-{variant}"))
                value.update(variant=variant, pair=pair, order=order_index)
                observations.append(value)
                paired[variant] = value
            for field in ("checksum", "warmup_checksum", "iterations"):
                if paired["baseline"][field] != paired["candidate"][field]:
                    raise RuntimeError(f"Paired {field} mismatch: {workload}, pair {pair}")
        print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)

    summary = []
    for workload in WORKLOADS:
        rows = [value for value in observations if value["workload"] == workload]
        item = {"workload": workload, "iterations": iteration_counts[workload]}
        for clock in ("wall", "cpu"):
            values = {}
            for variant in ("baseline", "candidate"):
                values[variant] = [row[f"{clock}_ns"] / row["iterations"]
                                   for row in rows if row["variant"] == variant]
                samples = values[variant]
                item[f"{variant}_{clock}_ns_per_call"] = statistics.median(samples)
                item[f"{variant}_{clock}_range_ns"] = [min(samples), max(samples)]
            changes = [100 * (1 - candidate / baseline)
                       for baseline, candidate in zip(values["baseline"], values["candidate"])]
            item[f"paired_{clock}_reductions_percent"] = changes
            item[f"median_paired_{clock}_reduction_percent"] = statistics.median(changes)
            item[f"{clock}_winning_pairs"] = sum(change > 0 for change in changes)
        summary.append(item)

    by_name = {item["workload"]: item for item in summary}
    primary = ("storyboard-24", "balanced-12")
    controls = ("exact-level-32", "exact-level-64", "one-sample", "short-duration")
    gate = {
        "rule": "Both primary workloads: >=15% median paired CPU reduction and >=90% winning pairs; "
                "each control: <=10% median paired CPU regression. This is a practical consistency "
                "rule, not a statistical significance test.",
        "primary_workloads": list(primary), "control_workloads": list(controls),
        "passed": all(by_name[name]["median_paired_cpu_reduction_percent"] >= 15
                      and by_name[name]["cpu_winning_pairs"] >= math.ceil(0.9 * args.pairs)
                      for name in primary)
                  and all(by_name[name]["median_paired_cpu_reduction_percent"] >= -10
                          for name in controls),
    }
    if (ROOT / POLICY).read_bytes() != candidate:
        raise RuntimeError("Production source changed during measurement")
    receipt = {"environment": environment, "validation": validations, "gate": gate,
               "summary": summary, "calibrations": calibrations, "observations": observations}
    (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for item in summary:
        print(f"{item['workload']}: {item['baseline_cpu_ns_per_call']:.1f} -> "
              f"{item['candidate_cpu_ns_per_call']:.1f} ns/call CPU; "
              f"{item['median_paired_cpu_reduction_percent']:.1f}% median paired reduction; "
              f"{item['cpu_winning_pairs']}/{args.pairs} pairs", flush=True)
    print(f"Practical performance gate passed: {gate['passed']}", flush=True)
    # Preserve a machine-readable receipt in both the artifact and job log.
    print("RESEARCH_RECEIPT_JSON=" + json.dumps(receipt, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
