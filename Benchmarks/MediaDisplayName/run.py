#!/usr/bin/env python3
"""Qualify and time complete production media display-name implementations."""

from __future__ import annotations

import argparse
import gzip
import regression
import hashlib
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
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
NATIVE = sys.platform == "darwin"
VARIANTS = ("baseline", "candidate")
TESTS = ("MediaNameRecognitionTests.swift", "MediaNameRecognitionFastPathTests.swift",
         "MediaNameRecognitionPerformanceRegressionTests.swift",
         "EpisodeDisplayNameTests.swift", "MediaDisplayNameTests.swift")
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "MediaDisplayNameQualification", platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def execute(command: list, output: Path, env: dict, log_name: str) -> str:
    command = [str(argument) for argument in command]
    log = output / log_name
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=600)
    log.write_text(json.dumps(command) + "\n\n" + result.stdout + "\nSTDERR\n" + result.stderr)
    append_json(output / "commands.jsonl", {
        "command": command, "returncode": result.returncode,
        "wall_seconds": time.monotonic() - started,
        "stdout_sha256": digest(result.stdout.encode()),
        "stderr_sha256": digest(result.stderr.encode()),
        "log": log_name, "log_sha256": file_digest(log),
    })
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n"
                           + result.stdout[-3000:] + result.stderr[-5000:])
    return result.stdout


def executable(choice: str | None, name: str) -> str:
    selected = shutil.which(choice or name)
    if not selected:
        raise RuntimeError(f"Cannot find {choice or name}; specify --{name}")
    # Preserve the swift/swiftc symlink name: it selects driver behavior.
    return str(Path(selected).absolute())


def toolchain(args: argparse.Namespace, output: Path, env: dict) -> dict:
    swiftc_choice = args.swiftc or os.environ.get("SWIFTC")
    if NATIVE and swiftc_choice is None:
        swiftc_choice = execute(["xcrun", "--find", "swiftc"], output, env,
                                "environment/compiler-path.log").strip()
    swiftc = executable(swiftc_choice, "swiftc")
    swift_choice = args.swift or os.environ.get("SWIFT")
    sibling = Path(swiftc).parent / "swift"
    swift = executable(swift_choice or (str(sibling) if sibling.exists() else None), "swift")
    receipt = {
        "swiftc": swiftc, "swift": swift,
        "version": execute([swiftc, "--version"], output, env, "environment/compiler.log").strip(),
        "swift_version": execute([swift, "--version"], output, env, "environment/swift.log").strip(),
        "swiftc_sha256": file_digest(Path(swiftc).resolve()),
        "swift_sha256": file_digest(Path(swift).resolve()),
    }
    frontend = Path(swiftc).parent / "swift-frontend"
    if frontend.exists():
        receipt["swift_frontend_sha256"] = file_digest(frontend.resolve())
    if NATIVE:
        receipt["sdk_path"] = execute(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                       output, env, "environment/sdk-path.log").strip()
        receipt["sdk_version"] = execute(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                                          output, env, "environment/sdk-version.log").strip()
    return receipt


def snapshot(output: Path, current_source_regression: bool = False) -> tuple[dict, dict]:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    if pinned["revision"] != BASELINE:
        raise RuntimeError("Unexpected frozen baseline revision")
    inputs = {}
    original, candidate = {}, {}
    for name, entry in pinned["files"].items():
        baseline_data = (HERE / "baseline" / name).read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(baseline_data)).encode()
                            + b"\0" + baseline_data).hexdigest()
        if digest(baseline_data) != entry["sha256"] or blob != entry["git_blob"]:
            raise RuntimeError(f"Frozen baseline does not match its manifest: {name}")
        candidate_data = (ROOT / entry["path"]).read_bytes()
        original[name], candidate[name] = baseline_data, candidate_data
    if current_source_regression:
        original, comparison = regression.select_sources(original, candidate, "MediaNameRecognition.swift")
        write_json(output / "comparison.json", comparison)
    for name in original:
        if name == "MediaMetadataHints.swift" and candidate[name] != original[name]:
            raise RuntimeError("Shared MediaMetadataHints.swift changed; requalify the baseline")
        inputs[f"baseline/{name}"] = original[name]
        inputs[f"candidate/{name}"] = candidate[name]
    for name in ("run.py", "regression.py", "Driver.swift", "Corpus.swift"):
        inputs[name] = (HERE / name).read_bytes()
    inputs["baseline-manifest.json"] = (HERE / "baseline/manifest.json").read_bytes()
    for name in TESTS:
        inputs[f"tests/{name}"] = (ROOT / "Tests/IlliquidCoreTests" / name).read_bytes()
    hashes = {}
    for name, data in inputs.items():
        destination = output / "inputs" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        hashes[name] = file_digest(destination)
    write_json(output / "source-receipts.json", hashes)
    return pinned, hashes


def verify_inputs(output: Path, hashes: dict) -> None:
    for name, expected in hashes.items():
        if file_digest(output / "inputs" / name) != expected:
            raise RuntimeError(f"Staged source changed: {name}")


def run_tests(output: Path, compiler: dict, env: dict) -> dict:
    receipts = []
    for variant in VARIANTS:
        package = output / "packages" / variant
        source_dir, tests_dir = package / "Sources/IlliquidCore", package / "Tests/IlliquidCoreTests"
        source_dir.mkdir(parents=True)
        tests_dir.mkdir(parents=True)
        for source in (output / "inputs" / variant).glob("*.swift"):
            shutil.copyfile(source, source_dir / source.name)
        for name in TESTS:
            shutil.copyfile(output / "inputs/tests" / name, tests_dir / name)
        (package / "Package.swift").write_text(PACKAGE)
        package_hashes = {str(path.relative_to(package)): file_digest(path)
                          for path in [package / "Package.swift", *source_dir.glob("*.swift"),
                                       *tests_dir.glob("*.swift")]}
        for configuration in ("debug", "release"):
            command = [compiler["swift"], "test", "--package-path", package,
                       "--scratch-path", output / "test-build" / variant,
                       "--cache-path", output / "cache/packages",
                       "--config-path", output / "cache/config",
                       "--security-path", output / "cache/security",
                       "--configuration", configuration, "--jobs", "2", "--no-parallel",
                       "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-module-cache-path",
                       "-Xswiftc", output / "cache/modules"]
            if not NATIVE:
                command.append("--use-integrated-swift-driver")
            log_name = f"tests/{variant}-{configuration}.log"
            print(f"Testing {variant} ({configuration})", flush=True)
            execute(command, output, env, log_name)
            log = output / log_name
            counts = re.findall(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log.read_text())
            if len(counts) != 1 or int(counts[0]) == 0:
                raise RuntimeError(f"Missing nonempty Swift Testing completion receipt: {log}")
            for name, expected in package_hashes.items():
                if file_digest(package / name) != expected:
                    raise RuntimeError(f"Test input changed: {package / name}")
            receipts.append({"variant": variant, "configuration": configuration,
                             "passed": True, "tests_executed": int(counts[0]),
                             "source_sha256": package_hashes,
                             "command": list(map(str, command)), "log": log_name,
                             "log_sha256": file_digest(log)})
            write_json(output / "tests.json", {"passed": len(receipts) == 4, "runs": receipts})
    return {"passed": True, "runs": receipts}


def build(variant: str, output: Path, compiler: dict, env: dict) -> tuple[Path, dict]:
    directory = output / "build" / variant
    directory.mkdir(parents=True)
    sources = sorted((output / "inputs" / variant).glob("*.swift"))
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
             "-module-cache-path", output / "cache/modules"]
    if NATIVE:
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", compiler["sdk_path"]]
    library = directory / ("libIlliquidCore.dylib" if NATIVE else "libIlliquidCore.so")
    module = directory / "IlliquidCore.swiftmodule"
    module_command = [compiler["swiftc"], *flags, "-emit-library", "-emit-module",
                      "-module-name", "IlliquidCore", "-emit-module-path", module,
                      "-o", library, *sources]
    execute(module_command, output, env, f"build/{variant}/module.log")
    binary = directory / "MediaDisplayNameBenchmark"
    driver_command = [compiler["swiftc"], *flags, "-parse-as-library", "-I", directory,
                      "-L", directory, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory,
                      output / "inputs/Driver.swift", output / "inputs/Corpus.swift", "-o", binary]
    execute(driver_command, output, env, f"build/{variant}/driver.log")
    receipt = {"module_command": list(map(str, module_command)),
               "driver_command": list(map(str, driver_command)),
               "executable": str(binary.relative_to(output)), "executable_sha256": file_digest(binary),
               "library": str(library.relative_to(output)), "library_sha256": file_digest(library),
               "swiftmodule_sha256": file_digest(module)}
    write_json(directory / "manifest.json", receipt)
    return binary, receipt


def metric_summary(selected: list[dict], field: str) -> dict:
    by_variant = {variant: [row[field] / row["operations"] for row in selected
                            if row["variant"] == variant] for variant in VARIANTS}
    reductions = []
    for pair in sorted({row["pair"] for row in selected}):
        rows = [row for row in selected if row["pair"] == pair]
        if len(rows) != 2 or {row["variant"] for row in rows} != set(VARIANTS):
            raise RuntimeError("Incomplete or duplicated final measurement pair")
        for name in ("case", "iterations", "operations", "checksum", "semantic_checksum"):
            if rows[0][name] != rows[1][name]:
                raise RuntimeError(f"Mismatched {name} in final measurement pair")
        values = {row["variant"]: row[field] / row["operations"] for row in rows}
        reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
    medians = {variant: statistics.median(values) for variant, values in by_variant.items()}
    return {
        "ns_per_operation": {variant: {"median": medians[variant], "min": min(values),
                                        "max": max(values), "samples": len(values)}
                             for variant, values in by_variant.items()},
        "saved_ns_from_separate_medians": medians["baseline"] - medians["candidate"],
        "reduction_from_separate_medians_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
        "paired_reduction_percent": {"median": statistics.median(reductions), "min": min(reductions),
                                     "max": max(reductions), "values": reductions},
        "candidate_faster_pairs": sum(value > 0 for value in reductions),
    }


def summarize(rows: list[dict], cases: list[dict]) -> dict:
    summaries = []
    for case in cases:
        selected = [row for row in rows if row["case"] == case["name"]]
        summaries.append({"case": case["name"], "inputs_per_batch": case["count"],
                          "iterations": selected[0]["iterations"],
                          "pairs": len({row["pair"] for row in selected}),
                          **metric_summary(selected, "elapsed_ns"),
                          "process_cpu": metric_summary(selected, "cpu_ns")})
    return {"measurements": len(rows), "cases": summaries}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new or empty output directory")
    parser.add_argument("--swift")
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--skip-tests", action="store_true", help="exploratory timing only; not full qualification")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--tests-only", action="store_true")
    modes.add_argument("--correctness-only", action="store_true")
    modes.add_argument("--summarize-only", action="store_true", help="rebuild summary from retained measurements")
    parser.add_argument("--current-source-regression", action="store_true",
                        help="Correctness only: frozen focal baseline with identical current support")
    args = parser.parse_args()
    try:
        regression.validate_mode(args.current_source_regression, args.correctness_only,
                                 skip_tests=args.skip_tests, summarize_only=args.summarize_only)
    except ValueError as error:
        parser.error(str(error))
    if args.pairs < 2 or args.pairs > 40 or args.pairs % 2:
        parser.error("pairs must be an even number from 2 to 40")
    if not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 2000:
        parser.error("target-ms must be from 10 to 2000")
    if args.tests_only and args.skip_tests:
        parser.error("tests-only cannot be combined with skip-tests")
    output = args.output.resolve()
    if args.summarize_only:
        rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
        write_json(output / "summary.json", summarize(rows, json.loads((output / "cases.json").read_text())))
        return
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("output must be new or empty; existing evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key, directory in {
        "SWIFTPM_MODULECACHE_OVERRIDE": output / "cache/swift",
        "CLANG_MODULE_CACHE_PATH": output / "cache/clang",
        "XDG_CACHE_HOME": output / "cache/xdg", "TMPDIR": output / "cache/tmp",
    }.items():
        directory.mkdir(parents=True, exist_ok=True)
        env[key] = str(directory)
    pinned, hashes = snapshot(output, args.current_source_regression)
    compiler = toolchain(args, output, env)
    manifest = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(), "logical_cpus": os.cpu_count(),
        "python": sys.version, "compiler": compiler,
        "head": execute(["git", "rev-parse", "HEAD"], output, env, "environment/head.log").strip(),
        "working_tree_status": execute(["git", "status", "--short"], output, env, "environment/status.log"),
        "locale": execute(["locale"], output, env, "environment/locale.log").strip(),
        "baseline": pinned, "source_sha256": hashes, "pairs": args.pairs, "target_ms": args.target_ms,
        "comparison_mode": "current-source-regression" if args.current_source_regression else "historical-strict",
        "skip_tests": args.skip_tests,
        "mode": "tests-only" if args.tests_only else "correctness-only" if args.correctness_only else "benchmark",
        "production_linkage": "Separate optimized shared IlliquidCore modules; independently optimized common driver; no cross-module optimization",
        "ordering": "Rotate cases per pair; alternate baseline/candidate order for each case and pair",
        "calibration": "Balanced fresh-process pilots; adapt equal iterations until the faster variant reaches target; pilots excluded from final summary",
        "timing": "DispatchTime uptime and process CPU; warmed in-memory workloads and bounded batch result handling; see Driver.swift for exact boundary",
    }
    if NATIVE:
        manifest["macos"] = execute(["sw_vers"], output, env, "environment/macos.log").strip()
        manifest["hardware"] = execute(["sysctl", "-n", "machdep.cpu.brand_string", "hw.model", "hw.memsize"],
                                        output, env, "environment/hardware.log").strip()
        manifest["xcode"] = execute(["xcodebuild", "-version"], output, env, "environment/xcode.log").strip()
    write_json(output / "manifest.json", manifest)
    if args.skip_tests:
        write_json(output / "tests.json", {"passed": None, "skipped": True, "runs": []})
    else:
        run_tests(output, compiler, env)
    verify_inputs(output, hashes)
    if args.tests_only:
        return

    binaries, builds = {}, {}
    for variant in VARIANTS:
        binaries[variant], builds[variant] = build(variant, output, compiler, env)
    write_json(output / "build-receipts.json", builds)
    cases = json.loads(execute([binaries["baseline"], "--list"], output, env, "list-baseline.log"))
    if cases != json.loads(execute([binaries["candidate"], "--list"], output, env, "list-candidate.log")):
        raise RuntimeError("Workload definitions differ")
    if (not cases or len({case["name"] for case in cases}) != len(cases)
            or any(type(case["count"]) is not int or case["count"] <= 0 for case in cases)):
        raise RuntimeError("Invalid workload definitions")
    write_json(output / "cases.json", cases)
    differential = {}
    for variant in VARIANTS:
        raw = execute([binaries[variant], "--differential"], output, env, f"differential-{variant}.log")
        (output / f"differential-{variant}.json.gz").write_bytes(gzip.compress(raw.encode(), mtime=0))
        differential[variant] = json.loads(raw)
    if not differential["baseline"] or differential["baseline"] != differential["candidate"]:
        raise RuntimeError("Complete differential outputs differ or are empty; inspect differential logs")
    write_json(output / "differential.json", {
        "passed": True, "cases": len(differential["baseline"]),
        "comparison": "Complete JSON output equality, including all input and derived output fields emitted by Driver.swift",
        "archives": {variant: file_digest(output / f"differential-{variant}.json.gz") for variant in VARIANTS},
    })
    print(f"Exact output parity: {len(differential['baseline'])} records", flush=True)
    if args.correctness_only:
        verify_inputs(output, hashes)
        return

    expected, iterations, rows = {}, {}, []

    def measure(variant: str, case: dict, count: int, label: str) -> dict:
        log_name = f"processes/{label}-{case['name']}-{variant}.log"
        row = json.loads(execute([binaries[variant], "--case", case["name"], "--iterations", count],
                                 output, env, log_name))
        if (row["case"] != case["name"] or row["iterations"] != count
                or row["operations"] != count * case["count"]
                or type(row["elapsed_ns"]) is not int or row["elapsed_ns"] <= 0
                or type(row["cpu_ns"]) is not int or row["cpu_ns"] <= 0):
            raise RuntimeError(f"Invalid benchmark record: {row}")
        key, checksums = (case["name"], count), (row["checksum"], row["semantic_checksum"])
        if key in expected and expected[key] != checksums:
            raise RuntimeError(f"Timed output differs: {case['name']}")
        expected[key] = checksums
        row.update(variant=variant, log=log_name, log_sha256=file_digest(output / log_name))
        return row

    for index, case in enumerate(cases):
        count = 1
        for attempt in range(10):
            order = VARIANTS if (index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
            pilots = []
            for position, variant in enumerate(order):
                row = measure(variant, case, count, f"pilot-{attempt:02d}")
                row.update(attempt=attempt, position=position, order=list(order))
                pilots.append(row)
                append_json(output / "calibration.jsonl", row)
            fastest = min(row["elapsed_ns"] for row in pilots)
            if fastest >= args.target_ms * 1e6:
                break
            count = max(count + 1, math.ceil(count * args.target_ms * 1e6 / fastest * 1.1))
        else:
            raise RuntimeError(f"Unable to calibrate {case['name']}")
        iterations[case["name"]] = count
    write_json(output / "iterations.json", iterations)
    for pair in range(args.pairs):
        offset = pair % len(cases)
        for case in cases[offset:] + cases[:offset]:
            index = cases.index(case)
            order = VARIANTS if (pair + index) % 2 == 0 else tuple(reversed(VARIANTS))
            for position, variant in enumerate(order):
                row = measure(variant, case, iterations[case["name"]], f"pair-{pair:02d}")
                row.update(pair=pair, position=position, order=list(order))
                rows.append(row)
                append_json(output / "measurements.jsonl", row)
        print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)
    verify_inputs(output, hashes)
    for variant, receipt in builds.items():
        for field in ("executable", "library"):
            if file_digest(output / receipt[field]) != receipt[field + "_sha256"]:
                raise RuntimeError(f"Build product changed: {variant} {field}")
    results = summarize(rows, cases)
    write_json(output / "summary.json", results)
    print(json.dumps(results, indent=2), flush=True)


if __name__ == "__main__":
    main()
