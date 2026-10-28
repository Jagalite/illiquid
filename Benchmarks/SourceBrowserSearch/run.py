#!/usr/bin/env python3
"""Compare exact source-browser search implementations, retaining all observations.

No network access or production edits. Timings and Linux allocation requests are
separate cohorts. See README.md for scope and reproduction instructions.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
FILTER = "Sources/IlliquidApp/UI/SourceBrowserFilter.swift"

# Each tuple is (operation, media rows, ancestor depth, matching scenario).
# Folder rows are present in input order, with 100 siblings per branch.
CASES = [
    ("search", 1_000, 2, "broad"),
    ("search", 10_000, 0, "broad"),
    ("search", 10_000, 2, "broad"),
    ("search", 100_000, 0, "broad"),
    ("search", 100_000, 2, "broad"),
    ("search", 100_000, 8, "broad"),
    ("search", 100_000, 0, "sparse"),
    ("search", 100_000, 2, "sparse"),
    ("search", 100_000, 0, "none"),
    ("search", 100_000, 2, "none"),
    ("search", 100_000, 2, "blank"),
    ("search", 10_000, 2, "metadata"),
    ("search", 10_000, 2, "unicode"),
    ("project", 100_000, 0, "broad"),
    ("project", 100_000, 2, "broad"),
    ("project", 100_000, 2, "sparse"),
    ("project", 100_000, 2, "none"),
    ("project", 100_000, 2, "blank"),
]

PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceSearchQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SearchBenchmark", targets: ["SearchBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        EXTRA_TARGET
        .executableTarget(name: "SearchBenchmark", dependencies: ["IlliquidApp", "IlliquidCore"EXTRA_DEPENDENCY]),
    ]
)
'''


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def execute(argv: list[str | Path], out: Path, env: dict[str, str], timeout: int = 600) -> str:
    args = list(map(str, argv))
    started = time.monotonic()
    result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    with (out / "commands.jsonl").open("a") as log:
        log.write(json.dumps({"argv": args, "returncode": result.returncode,
                              "wall_seconds": time.monotonic() - started,
                              "stdout": result.stdout, "stderr": result.stderr}) + "\n")
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def build(out: Path, variant: str, swift: str, env: dict[str, str], meter: bool, baseline_ref: str = BASELINE) -> Path:
    spec = importlib.util.spec_from_file_location(
        "search_tests", ROOT / "Scripts/test-source-browser-search.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    package = module.prepare_package(out / variant, baseline_ref if variant == "baseline" else None,
                                     include_tests=False)
    source = execute(["git", "show", f"{baseline_ref}:{FILTER}"], out, env)
    marker = "    static func search(_ rows: [SourceTreeDisplayRow], query: String)"
    if source.count(marker) != 1 or not source.endswith("    }\n}\n"):
        raise ValueError("Search declaration moved; review the exact-source oracle extraction")
    oracle = "import Foundation\nenum BaselineSourceBrowserSearch {\n" + source[source.index(marker):-2] + "}\n"
    (package / "Sources/IlliquidApp/BaselineSearch.swift").write_text(oracle)
    harness = package / "Sources/SearchBenchmark"
    harness.mkdir(parents=True)
    shutil.copy2(HERE / "Harness.swift", harness / "Harness.swift")
    manifest = PACKAGE.replace("EXTRA_TARGET", '.target(name: "CAllocationMeter"),' if meter else "")
    manifest = manifest.replace("EXTRA_DEPENDENCY", ', "CAllocationMeter"' if meter else "")
    (package / "Package.swift").write_text(manifest)
    if meter:
        ctarget = package / "Sources/CAllocationMeter"
        (ctarget / "include").mkdir(parents=True)
        shutil.copy2(ROOT / "Benchmarks/NonDecodePerformance/allocmeter.c", ctarget / "allocmeter.c")
        (ctarget / "include/AllocationMeter.h").write_text(
            "#include <stdint.h>\nvoid meter_begin(void);\nvoid meter_end(void);\n"
            "uint64_t meter_requests(void);\nuint64_t meter_bytes(void);\n")
    flags = ["-Xswiftc", "-enable-testing", "-Xswiftc", "-warnings-as-errors"]
    if meter:
        flags += ["-Xswiftc", "-DALLOCATION_METER"]
    execute([swift, "build", "--package-path", package, "--cache-path", package / "cache",
             "-c", "release", "--product", "SearchBenchmark", *flags], out, env)
    binary_dir = execute([swift, "build", "--package-path", package,
                          "--show-bin-path", "-c", "release"], out, env).strip()
    binary = Path(binary_dir) / "SearchBenchmark"
    save(out / f"{variant}-build.json", {
        "binary_sha256": digest(binary),
        "source_receipt_sha256": digest(package / "source-receipt.json"),
        "benchmark_manifest_sha256": digest(package / "Package.swift"),
        "oracle_sha256": hashlib.sha256(oracle.encode()).hexdigest(),
        "harness_sha256": digest(harness / "Harness.swift"),
        "compiled_sources": {str(path.relative_to(package)): digest(path)
                             for path in sorted((package / "Sources").rglob("*"))
                             if path.is_file() and path.suffix in (".swift", ".c", ".h")},
        "allocation_instrumented": meter,
    })
    return binary


def summarize(rows: list[dict]) -> list[dict]:
    groups = []
    for key in dict.fromkeys(row["case"] for row in rows):
        selected = [row for row in rows if row["case"] == key]
        group = {"case": key, "pairs": len(selected) // 2, "variants": {}}
        metrics = ["elapsed_ns", "cpu_ns"]
        if selected[0]["allocation_instrumented"]:
            metrics += ["allocation_requests", "allocation_requested_bytes"]
        for variant in ("baseline", "candidate"):
            values = [row for row in selected if row["variant"] == variant]
            entry = {"input_rows": values[0]["input_rows"], "output_rows": values[0]["output_rows"]}
            for metric in metrics:
                samples = [row[metric] / row["iterations"] for row in values]
                entry[metric + "_per_operation"] = {"median": statistics.median(samples),
                    "minimum": min(samples), "maximum": max(samples)}
            group["variants"][variant] = entry
        group["paired_reduction_percent"] = {}
        for metric in metrics:
            deltas = []
            for pair in sorted({row["pair"] for row in selected}):
                ab = {row["variant"]: row[metric] / row["iterations"]
                      for row in selected if row["pair"] == pair}
                if ab["baseline"]:
                    deltas.append(100 * (1 - ab["candidate"] / ab["baseline"]))
            group["paired_reduction_percent"][metric] = {
                "median": statistics.median(deltas) if deltas else None,
                "all": deltas, "candidate_faster_pairs": sum(value > 0 for value in deltas),
            }
        groups.append(group)
    return groups


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-ref", default=BASELINE,
                        help="Git commit/ref for the baseline Filter and search oracle")
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=120)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--allocations", action="store_true")
    parser.add_argument("--case", action="append", help="Exact operation/count/depth/kind case ID; repeat to select")
    args = parser.parse_args()
    if not args.swift:
        parser.error("swift is unavailable; provide --swift")
    if not 2 <= args.pairs <= 20 or args.pairs % 2:
        parser.error("--pairs must be even and between 2 and 20 for balanced AB/BA")
    if not 1 <= args.target_ms <= 1000:
        parser.error("--target-ms must be between 1 and 1000")
    if args.allocations and platform.system() != "Linux":
        parser.error("allocation instrumentation is Linux/glibc only")
    if args.cpu is not None:
        if not hasattr(os, "sched_setaffinity") or args.cpu not in os.sched_getaffinity(0):
            parser.error("requested CPU is unavailable")
        os.sched_setaffinity(0, {args.cpu})
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("output must be new or empty; evidence is never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE / "run.py", out / "runner.snapshot.py")
    shutil.copy2(ROOT / "Scripts/test-source-browser-search.py", out / "tests-runner.snapshot.py")
    cases = [("/".join(map(str, case)), case) for case in CASES]
    if args.case:
        unknown = set(args.case) - {name for name, _ in cases}
        if unknown:
            parser.error(f"Unknown cases: {sorted(unknown)}")
        cases = [(name, case) for name, case in cases if name in args.case]
    env = os.environ.copy()
    env["SWIFT_MODULECACHE_PATH"] = str(out / "module-cache")
    env["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    env["LC_ALL"] = "en_US.UTF-8" if platform.system() == "Darwin" else "C.UTF-8"
    swift = os.path.abspath(args.swift)
    baseline_ref = execute(["git", "rev-parse", "--verify", args.baseline_ref + "^{commit}"], out, env).strip()
    save(out / "environment.json", {
        "started_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
        "compiler": execute([swift, "--version"], out, env).strip(),
        "baseline_ref": baseline_ref, "git_head": execute(["git", "rev-parse", "HEAD"], out, env).strip(),
        "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "cpu_description": (Path("/proc/cpuinfo").read_text().split("\n\n")[0]
                            if Path("/proc/cpuinfo").exists() else execute(["sysctl", "-n", "machdep.cpu.brand_string"], out, env).strip()),
        "locale": env["LC_ALL"], "pairs": args.pairs, "target_ms": args.target_ms,
        "allocation_instrumented": args.allocations, "cases": [name for name, _ in cases],
        "source_hashes": {str(path.relative_to(ROOT)): digest(path) for path in
            [HERE / "run.py", HERE / "Harness.swift", ROOT / FILTER,
             ROOT / "Scripts/test-source-browser-search.py"]},
    })
    binaries = {variant: build(out, variant, swift, env, args.allocations, baseline_ref)
                for variant in ("baseline", "candidate")}
    receipts = {variant: json.loads((out / f"{variant}-build.json").read_text())
                for variant in binaries}
    for key in ("harness_sha256", "oracle_sha256", "benchmark_manifest_sha256"):
        if receipts["baseline"][key] != receipts["candidate"][key]:
            raise RuntimeError(f"Baseline/candidate benchmark input differs: {key}")
    changed = [path for path in receipts["baseline"]["compiled_sources"]
               if receipts["baseline"]["compiled_sources"][path]
               != receipts["candidate"]["compiled_sources"].get(path)]
    if changed != ["Sources/IlliquidApp/SourceBrowserFilter.swift"]:
        raise RuntimeError(f"Expected only the production Filter to differ: {changed}")
    rows = []
    for name, case in cases:
        calibration = [json.loads(execute([binary, *map(str, case), "1", "1"], out, env))
                       for binary in binaries.values()]
        for key in ("fingerprint", "output_rows", "checksum"):
            if calibration[0][key] != calibration[1][key]:
                raise RuntimeError(f"Calibration mismatch: {name} {key}")
        longest = max(row["elapsed_ns"] for row in calibration)
        iterations = max(1, min(100_000, math.ceil(args.target_ms * 1_000_000 / max(1, longest))))
        if args.allocations:
            iterations = max(1, min(10, 100_000 // case[1]))
        save(out / (name.replace("/", "-") + "-calibration.json"), calibration)
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            pair_rows = []
            for sequence, variant in enumerate(order):
                row = json.loads(execute([binaries[variant], *map(str, case), str(iterations), "1"], out, env))
                row.update(case=name, pair=pair, sequence=sequence, variant=variant)
                pair_rows.append(row)
                rows.append(row)
                with (out / "measurements.jsonl").open("a") as log:
                    log.write(json.dumps(row, sort_keys=True) + "\n")
            for key in ("fingerprint", "output_rows", "checksum", "input_rows", "iterations"):
                if pair_rows[0][key] != pair_rows[1][key]:
                    raise RuntimeError(f"Paired result differs: {name} {key}")
        groups = summarize(rows)
        save(out / "summary.json", groups)
        last = groups[-1]
        timings = {variant: round(last["variants"][variant]["elapsed_ns_per_operation"]["median"] / 1_000_000, 3)
                   for variant in ("baseline", "candidate")}
        print(name, "median_ms", timings, "paired_reduction_percent",
              round(last["paired_reduction_percent"]["elapsed_ns"]["median"], 2), flush=True)
    save(out / "completion.json", {"complete": True, "cases": len(cases), "measurements": len(rows)})
    print(f"Completed {len(rows)} measurements", flush=True)


if __name__ == "__main__":
    main()
