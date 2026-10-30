#!/usr/bin/env python3
"""Measure complete production media-row construction and a cached-projection control."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
FOCAL = "Sources/IlliquidCore/MediaNameRecognition.swift"
CASES = ["precomputed_episodes", "unprepared_episodes", "mixed_library",
         "movies_control", "cached_projection_control"]
VARIANTS = ("baseline", "candidate")
REGRESSION_HELPER = ROOT / "Benchmarks/MediaDisplayName/regression.py"
spec = importlib.util.spec_from_file_location("media_display_regression", REGRESSION_HELPER)
regression = importlib.util.module_from_spec(spec)
spec.loader.exec_module(regression)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC") or shutil.which("swiftc"))
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--sizes", nargs="+", type=int, default=[100, 1000])
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--current-source-regression", action="store_true",
                        help="Verification only: frozen focal baseline with identical current support")
    args = parser.parse_args()
    try:
        regression.validate_mode(args.current_source_regression, args.verify_only)
    except ValueError as error:
        parser.error(str(error))
    if not args.swiftc or not 2 <= args.pairs <= 40 or args.pairs % 2:
        parser.error("Swift is required and pairs must be even from 2 through 40")
    if not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 2000:
        parser.error("target-ms must be finite and from 10 through 2000")
    if any(size <= 0 for size in args.sizes) or len(set(args.sizes)) != len(args.sizes):
        parser.error("sizes must be positive and unique")
    if len(set(args.cases)) != len(args.cases):
        parser.error("cases must be unique")
    out = args.output.resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("Use a new or empty output directory; previous results are never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(out / "cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(out / "cache")
    command_count = 0

    def run(command, label):
        nonlocal command_count
        command = list(map(str, command))
        stdout = out / "logs" / (label + ".stdout")
        stderr = out / "logs" / (label + ".stderr")
        stdout.parent.mkdir(parents=True, exist_ok=True)
        start = time.monotonic()
        with stdout.open("wb") as left, stderr.open("wb") as right:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=left, stderr=right, timeout=1200)
        record = {"label": label, "command": command, "returncode": result.returncode,
                  "seconds": time.monotonic() - start,
                  "stdout": str(stdout.relative_to(out)), "stderr": str(stderr.relative_to(out)),
                  "stdout_sha256": digest(stdout.read_bytes()), "stderr_sha256": digest(stderr.read_bytes())}
        with (out / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        command_count += 1
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}): {stderr.read_text()[-6000:]}")
        return stdout

    spec = importlib.util.spec_from_file_location("display_projection_snapshot", HELPER)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    historical = {}

    def read_baseline(name):
        if name not in historical:
            historical[name] = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT)
        return historical[name]

    original, baseline_records = helper.snapshot(read_baseline)
    candidate, candidate_records = helper.snapshot(lambda name: (ROOT / name).read_bytes())
    if args.current_source_regression:
        original, comparison = regression.select_sources(original, candidate, FOCAL)
        save(out / "comparison.json", comparison)
        baseline_records = {name: baseline_records[name] if name == FOCAL else dict(record)
                            for name, record in candidate_records.items()}
    if original.keys() != candidate.keys():
        raise RuntimeError("Production source inventory differs")
    for name in original:
        if name != FOCAL and original[name] != candidate[name]:
            raise RuntimeError(f"Unexpected unrelated production difference: {name}")
    tracked = {record["repository_path"]: record["source_sha256"] for record in candidate_records.values()}
    for name, path in [("runner.py", Path(__file__)), ("Harness.swift", HERE / "Harness.swift"),
                       ("source-snapshot-helper.py", HELPER), ("regression.py", REGRESSION_HELPER)]:
        raw = path.read_bytes()
        (out / name).write_bytes(raw)
        tracked[str(path.relative_to(ROOT))] = digest(raw)
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
             "-module-cache-path", str(out / "cache")]
    native = sys.platform == "darwin"
    if native:
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").read_text().strip()
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    environment = {"comparison_mode": "current-source-regression" if args.current_source_regression else "historical-strict",
                   "baseline_revision": BASELINE,
                   "head": run(["git", "rev-parse", "HEAD"], "head").read_text().strip(),
                   "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
                   "swift": run([args.swiftc, "--version"], "swift").read_text().strip(),
                   "flags": flags, "pairs": args.pairs, "sizes": args.sizes, "cases": args.cases,
                   "target_ms": args.target_ms, "sources": tracked,
                   "ordering": "Balanced AB/BA; fresh process for each observation; no omitted samples",
                   "timing_scope": "Complete input.rows(), or cached actor.project() control; one untimed warmup; fixtures and complete output verification excluded",
                   "timers": "DispatchTime.uptimeNanoseconds and CLOCK_PROCESS_CPUTIME_ID",
                   "sort": "Production default: name off, creation date descending, type off",
                   "qualification": "Foundation component; no filesystem reads, SwiftUI rendering, playback or full-app latency measured"}
    if native:
        environment["macos"] = run(["sw_vers"], "macos").read_text().strip()
        environment["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").read_text().strip()
    save(out / "environment.json", environment)
    binaries, source_receipts = {}, {}
    for variant, sources, records in [("baseline", original, baseline_records), ("candidate", candidate, candidate_records)]:
        folder = out / "build" / variant
        folder.mkdir(parents=True)
        receipt = {"production": records, "staged": {}, "adaptations": []}
        for relative, raw in sources.items():
            staged = raw
            if not native:
                replacements = [(b"import Darwin\n", b"import Glibc\n")] if relative.endswith("/MediaSidecarReader.swift") else (
                    [(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n")] if relative.endswith("/NFOMetadataHints.swift") else [])
                for old, new in replacements:
                    if staged.count(old) != 1:
                        raise RuntimeError(f"Linux compatibility boundary changed: {relative}")
                    staged = staged.replace(old, new, 1)
                    receipt["adaptations"].append({"path": relative, "old": old.decode(), "new": new.decode()})
            destination = out / "sources" / variant / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(staged)
            receipt["staged"][relative] = {"source_sha256": digest(raw), "compiled_sha256": digest(staged)}
        libraries = []
        for module in ["IlliquidCore", "IlliquidApp"]:
            library = folder / ("lib" + module + (".dylib" if native else ".so"))
            files = sorted((out / "sources" / variant / "Sources" / module).glob("*.swift"))
            linking = [] if module == "IlliquidCore" else ["-I", folder, "-L", folder, "-lIlliquidCore",
                                                         "-Xlinker", "-rpath", "-Xlinker", folder]
            run([args.swiftc, *flags, "-enable-testing", "-emit-library", "-emit-module", "-module-name", module,
                 "-emit-module-path", folder / (module + ".swiftmodule"), *linking, *files, "-o", library],
                f"build-{variant}-{module}")
            libraries.append({"path": str(library.relative_to(out)), "sha256": digest(library.read_bytes())})
        binary = folder / "projection"
        run([args.swiftc, *flags, "-parse-as-library", "-I", folder, "-L", folder,
             "-lIlliquidCore", "-lIlliquidApp", "-Xlinker", "-rpath", "-Xlinker", folder,
             out / "Harness.swift", "-o", binary], f"build-{variant}-harness")
        binaries[variant] = binary
        receipt["libraries"] = libraries
        receipt["binary"] = {"path": str(binary.relative_to(out)), "sha256": digest(binary.read_bytes())}
        source_receipts[variant] = receipt
        save(out / f"{variant}-sources.json", receipt)
    expected, verification = {}, []
    for name in args.cases:
        for size in args.sizes:
            paths = {variant: run([binary, "verify", name, size], f"verify-{name}-{size}-{variant}")
                     for variant, binary in binaries.items()}
            raw = paths["baseline"].read_bytes()
            if raw != paths["candidate"].read_bytes():
                raise RuntimeError(f"Full production output differs: {name}/{size}")
            expected[(name, size)] = paths["baseline"]
            verification.append({"case": name, "size": size, "complete_output_equal": True, "sha256": digest(raw)})
    save(out / "verification.json", verification)
    measurements, calibrations = [], []

    def measure(variant, name, size, iterations, label):
        result = json.loads(run([binaries[variant], "measure", name, size, iterations, expected[(name, size)]], label).read_text())
        if (result["case"] != name or result["size"] != size or result["iterations"] != iterations
                or not result["full_output_equal"] or result["checksum"] != result["rows"] * iterations
                or any(type(result[key]) is not int or result[key] <= 0 for key in ("elapsed_ns", "cpu_ns"))):
            raise RuntimeError(f"Invalid measurement receipt: {label}")
        return result

    if not args.verify_only:
        for case_index, name in enumerate(args.cases):
            for size in args.sizes:
                iterations = 1
                for attempt in range(10):
                    order = VARIANTS if (case_index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
                    calibration = {variant: measure(variant, name, size, iterations,
                                   f"calibrate-{name}-{size}-{attempt}-{variant}") for variant in order}
                    calibrations.append({"case": name, "size": size, "attempt": attempt,
                                         "iterations": iterations, "order": list(order), "observations": calibration})
                    save(out / "calibration.json", calibrations)
                    fastest = min(value["elapsed_ns"] for value in calibration.values())
                    if fastest >= args.target_ms * 1_000_000:
                        break
                    iterations = max(iterations + 1, math.ceil(iterations * args.target_ms * 1_000_000 / fastest * 1.1))
                    if iterations > 10000:
                        raise RuntimeError("Calibration produced more than 10,000 iterations")
                else:
                    raise RuntimeError(f"Calibration did not reach target: {name}/{size}")
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    for ordinal, variant in enumerate(order):
                        result = measure(variant, name, size, iterations, f"measure-{name}-{size}-{pair}-{variant}")
                        result.update(variant=variant, pair=pair, ordinal=ordinal)
                        measurements.append(result)
                        with (out / "measurements.jsonl").open("a") as stream:
                            stream.write(json.dumps(result, sort_keys=True) + "\n")
                print(f"Completed {name}/{size}: {args.pairs} pairs x {iterations} projections", flush=True)
    summaries = []
    for name in args.cases:
        for size in args.sizes:
            rows = [row for row in measurements if row["case"] == name and row["size"] == size]
            if not rows:
                continue
            paired, cpu_paired = [], []
            for pair in range(args.pairs):
                observations = [row for row in rows if row["pair"] == pair]
                order = list(VARIANTS) if pair % 2 == 0 else list(reversed(VARIANTS))
                if [row["variant"] for row in observations] != order:
                    raise RuntimeError("Measurement pair ordering differs")
                values = {row["variant"]: row for row in observations}
                for field in ["rows", "checksum", "iterations", "tree_builds", "visibility_builds", "full_output_equal"]:
                    if values["baseline"][field] != values["candidate"][field]:
                        raise RuntimeError(f"Measured receipt differs for {field}")
                paired.append(100 * (1 - values["candidate"]["elapsed_ns"] / values["baseline"]["elapsed_ns"]))
                cpu_paired.append(100 * (1 - values["candidate"]["cpu_ns"] / values["baseline"]["cpu_ns"]))
            summary = {"case": name, "size": size, "pairs": args.pairs, "paired_reduction_percent": paired,
                       "median_paired_reduction_percent": statistics.median(paired),
                       "cpu_paired_reduction_percent": cpu_paired,
                       "median_cpu_paired_reduction_percent": statistics.median(cpu_paired)}
            for variant in VARIANTS:
                values = [row["elapsed_ns"] / row["iterations"] for row in rows if row["variant"] == variant]
                cpu_values = [row["cpu_ns"] / row["iterations"] for row in rows if row["variant"] == variant]
                summary[variant] = {"median_ns_per_projection": statistics.median(values),
                                    "min_ns_per_projection": min(values), "max_ns_per_projection": max(values),
                                    "median_cpu_ns_per_projection": statistics.median(cpu_values)}
            summaries.append(summary)
    save(out / "summary.json", summaries)
    for name, expected_hash in tracked.items():
        if digest((ROOT / name).read_bytes()) != expected_hash:
            raise RuntimeError(f"Source changed during qualification: {name}")
    for variant, receipt in source_receipts.items():
        for name, expected_hash in receipt["staged"].items():
            if digest((out / "sources" / variant / name).read_bytes()) != expected_hash["compiled_sha256"]:
                raise RuntimeError(f"Staged source changed: {variant}/{name}")
        for binary in [receipt["binary"], *receipt["libraries"]]:
            if digest((out / binary["path"]).read_bytes()) != binary["sha256"]:
                raise RuntimeError("Measured binary changed")
    if measurements:
        retained = [json.loads(line) for line in (out / "measurements.jsonl").read_text().splitlines()]
        if measurements != retained:
            raise RuntimeError("Retained measurements differ")
    save(out / "completion.json", {"success": True, "commands": command_count,
                                  "verified_cases": len(verification), "observations": len(measurements),
                                  "source_and_binary_hashes_rechecked": True})


if __name__ == "__main__":
    main()
