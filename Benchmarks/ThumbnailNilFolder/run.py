#!/usr/bin/env python3
"""Measure exact thumbnail ranking sources on macOS; never launch the player."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "cf3b96706f34ba5c43041d650f4c9f6217e340cc"
POLICY = Path("Sources/IlliquidCore/Player/ThumbnailPolicy.swift")
FLAGS = ["-swift-version", "6", "-warnings-as-errors"]
RELEASE_FLAGS = ["-O", "-whole-module-optimization"]


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=200)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native macOS measurements are required; this runner uses dylibs.")
    if args.pairs < 2 or args.pairs > 32 or args.pairs % 2:
        parser.error("--pairs must be even, between 2 and 32")
    if not math.isfinite(args.target_ms) or not 100 <= args.target_ms <= 2000:
        parser.error("--target-ms must be between 100 and 2000")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("--output must be new or empty; evidence is not overwritten")
    out.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    baseline = here / "baseline" / "ThumbnailPolicy.swift"
    candidate = root / POLICY
    baseline_bytes = baseline.read_bytes()
    if git_blob(baseline_bytes) != BASELINE_BLOB:
        raise RuntimeError("Frozen baseline does not match the pinned production Git blob")
    build = out / "build"
    build.mkdir()

    def write(name: str, value: object) -> None:
        (out / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def append(name: str, value: object) -> None:
        with (out / name).open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")

    def run(command: list, timeout: int = 180) -> str:
        command = [str(value) for value in command]
        started = time.time()
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout, cwd=root)
        append("commands.jsonl", {
            "command": command, "started_unix": started,
            "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
        })
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stderr}")
        return result.stdout

    inputs = [
        baseline, candidate, here / "Driver.swift", Path(__file__).resolve(),
        root / "Benchmarks/NonDecodePerformance/PolicyHarness.swift",
        root / ".github/workflows/thumbnail-nil-folder-performance.yml",
    ]
    manifest = {
        "baseline_commit": BASELINE_COMMIT, "baseline_blob": BASELINE_BLOB,
        "head": run(["git", "rev-parse", "HEAD"]).strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "host": run(["sw_vers"]).strip(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
        "swift": run([args.swiftc, "--version"]).strip(),
        "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "flags": FLAGS, "release_flags": RELEASE_FLAGS,
        "pairs": args.pairs, "target_ms": args.target_ms, "tests_only": args.tests_only,
        "scope": "Exact production ranking component; no decoder, UI, allocation or energy measurement",
        "source_hashes": {
            str(path.relative_to(root)): {
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "git_blob": git_blob(path.read_bytes()),
            } for path in inputs
        },
    }
    write("manifest.json", manifest)

    # Reuse the existing adversarial corpus, but compare against current main
    # rather than the older baseline used by the original non-decoding study.
    legacy = baseline_bytes.decode()
    for name in ["ThumbnailPreferences", "ThumbnailPolicy", "ThumbnailCacheUsage"]:
        legacy = legacy.replace(name, "Legacy" + name)
    legacy_path = build / "LegacyPolicy.swift"
    legacy_path.write_text(legacy)
    tests = {}
    for mode, optimization in [("debug", ["-Onone"]), ("release", RELEASE_FLAGS)]:
        binary = build / f"differential-{mode}"
        run([args.swiftc, *FLAGS, *optimization, "-D", "DIFFERENTIAL",
             candidate, legacy_path, root / "Benchmarks/NonDecodePerformance/PolicyHarness.swift",
             "-o", binary])
        tests[mode] = json.loads(run([binary]))
        if tests[mode].get("checks") != 4218 or tests[mode].get("passed") is not True:
            raise RuntimeError("Incomplete differential corpus")
        write("tests.json", tests)

    binaries = {}
    binary_receipts = {}
    for variant, source in [("baseline", baseline), ("candidate", candidate)]:
        directory = build / variant
        directory.mkdir()
        library = directory / "libThumbnailRanking.dylib"
        module = directory / "ThumbnailRanking.swiftmodule"
        run([args.swiftc, *FLAGS, *RELEASE_FLAGS, "-emit-library", "-emit-module",
             "-module-name", "ThumbnailRanking", "-emit-module-path", module,
             "-Xlinker", "-install_name", "-Xlinker", "@rpath/libThumbnailRanking.dylib",
             source, "-o", library])
        driver = directory / "driver"
        run([args.swiftc, *FLAGS, *RELEASE_FLAGS, "-parse-as-library", here / "Driver.swift",
             "-I", directory, "-L", directory, "-lThumbnailRanking",
             "-Xlinker", "-rpath", "-Xlinker", directory, "-o", driver])
        binaries[variant] = driver
        binary_receipts[variant] = {
            "library": str(library), "driver": str(driver),
            "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
            "driver_sha256": hashlib.sha256(driver.read_bytes()).hexdigest(),
            "linked_libraries": run(["otool", "-L", driver]),
            "load_commands": run(["otool", "-l", driver]),
        }
    write("binaries.json", binary_receipts)

    cases = [
        {"id": f"discovered-{count}_folder-{folder}_exclusions-{exclusions}",
         "discovered_count": count, "folder": folder, "exclusions": exclusions}
        for count in [32, 256, 2048]
        for exclusions in [0, 16]
        for folder in ["none", "present"]
    ]
    write("cases.json", cases)

    def invoke(variant: str, case: dict, iterations: int) -> dict:
        return json.loads(run([
            binaries[variant], case["discovered_count"], case["exclusions"],
            case["folder"], iterations,
        ]))

    parity = {}
    for case in cases:
        a = invoke("baseline", case, 0)
        b = invoke("candidate", case, 0)
        if a != b:
            raise RuntimeError(f"Ordered output mismatch: {case['id']}")
        ordered = json.dumps(a["ordered_urls"], ensure_ascii=True).encode()
        parity[case["id"]] = {
            **a, "ordered_urls_sha256": hashlib.sha256(ordered).hexdigest(), "passed": True,
        }
    write("parity.json", parity)

    if args.tests_only:
        write("completion.json", {"passed": True, "tests_only": True,
                                 "differential_checks_per_mode": 4218, "workload_cases": len(cases)})
        return

    calibration = {}
    for case in cases:
        iterations = 1
        attempts = []
        for _ in range(8):
            observations = {variant: invoke(variant, case, iterations)
                            for variant in ["baseline", "candidate"]}
            attempts.append({"iterations": iterations, "observations": observations})
            elapsed_ms = min(row["elapsed_ns"] for row in observations.values()) / 1e6
            if elapsed_ms >= args.target_ms:
                break
            iterations = max(iterations + 1, math.ceil(
                iterations * args.target_ms / max(0.001, elapsed_ms) * 1.1))
            if iterations > 1_000_000:
                raise RuntimeError("Calibration exceeded its iteration bound")
        else:
            raise RuntimeError("Calibration failed to reach the target duration")
        calibration[case["id"]] = {"iterations": iterations, "attempts": attempts}
        write("calibration.json", calibration)

    rows = []
    for pair in range(args.pairs):
        # Rotate case order as well as balancing each case's AB/BA order.
        offset = pair % len(cases)
        ordered_cases = cases[offset:] + cases[:offset]
        variants = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        for case in ordered_cases:
            iterations = calibration[case["id"]]["iterations"]
            for variant in variants:
                measurement = invoke(variant, case, iterations)
                expected_count = parity[case["id"]]["result_count"]
                if measurement["result_count"] != expected_count or \
                        measurement["checksum"] != expected_count * iterations:
                    raise RuntimeError("Measured workload changed its output")
                row = {
                    "sequence": len(rows), "pair": pair, "case": case["id"],
                    "variant": variant, "order": "/".join(variants), **measurement,
                    "ns_per_call": measurement["elapsed_ns"] / iterations,
                }
                rows.append(row)
                append("observations.jsonl", row)

    expected_rows = len(cases) * args.pairs * 2
    if len(rows) != expected_rows:
        raise RuntimeError("Incomplete timing cohort")
    summary = []
    for case in cases:
        selected = [row for row in rows if row["case"] == case["id"]]
        costs = {variant: [row["ns_per_call"] for row in selected if row["variant"] == variant]
                 for variant in ["baseline", "candidate"]}
        paired_speedups = []
        paired_reductions = []
        by_order = {"baseline/candidate": [], "candidate/baseline": []}
        for pair in range(args.pairs):
            pair_rows = [row for row in selected if row["pair"] == pair]
            if len(pair_rows) != 2 or {row["variant"] for row in pair_rows} != {"baseline", "candidate"}:
                raise RuntimeError("Missing or duplicated paired observation")
            if pair_rows[1]["sequence"] != pair_rows[0]["sequence"] + 1:
                raise RuntimeError("Baseline/candidate measurements were not adjacent")
            a = next(row["ns_per_call"] for row in pair_rows if row["variant"] == "baseline")
            b = next(row["ns_per_call"] for row in pair_rows if row["variant"] == "candidate")
            paired_speedups.append(a / b)
            paired_reductions.append(100 * (1 - b / a))
            by_order[pair_rows[0]["order"]].append(100 * (1 - b / a))
        if any(len(values) != args.pairs // 2 for values in by_order.values()):
            raise RuntimeError("Timing order was not balanced")
        summary.append({
            **case,
            "candidate_count": parity[case["id"]]["candidate_count"],
            "unique_count": parity[case["id"]]["unique_count"],
            "result_count": parity[case["id"]]["result_count"],
            "pairs": args.pairs,
            "baseline_median_ms": statistics.median(costs["baseline"]) / 1e6,
            "candidate_median_ms": statistics.median(costs["candidate"]) / 1e6,
            "median_paired_speedup": statistics.median(paired_speedups),
            "median_paired_reduction_percent": statistics.median(paired_reductions),
            "paired_reduction_range_percent": [min(paired_reductions), max(paired_reductions)],
            "median_reduction_by_order_percent": {
                order: statistics.median(values) for order, values in by_order.items()},
            "baseline_range_ms": [min(costs["baseline"]) / 1e6, max(costs["baseline"]) / 1e6],
            "candidate_range_ms": [min(costs["candidate"]) / 1e6, max(costs["candidate"]) / 1e6],
        })
    write("summary.json", summary)
    write("completion.json", {"passed": True, "tests_only": False, "timing_rows": len(rows),
                             "differential_checks_per_mode": 4218, "workload_cases": len(cases)})
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
