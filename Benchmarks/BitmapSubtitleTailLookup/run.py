#!/usr/bin/env python3
"""Compare exact bitmap-subtitle lookup sources on native macOS.

The optimized production module is compiled separately from the query driver.
Tests use the same complete timeline/budget sources and actual ASSRenderedRegion
declaration. No FFmpeg, libass, model stubs or third-party downloads are needed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NATIVE = ROOT / "Sources/IlliquidNativePlayback"
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TIMELINE = "Subtitles/BitmapSubtitleTimeline.swift"
BUDGET = "Subtitles/SubtitleMemoryBudget.swift"
REGIONS = "Subtitles/LibassContext.swift"
SOURCE_NAMES = ["BitmapSubtitleTimeline.swift", "SubtitleMemoryBudget.swift", "ASSRenderedRegion.swift"]
TESTS = ["BitmapSubtitleTimelineOrderingTests.swift", "SubtitleMemoryBudgetAccountingTests.swift",
         "BitmapSubtitleTimelineLookupTests.swift"]
CASES = (
    ["empty", "single-latest", "single-before"]
    + [f"first-{n}" for n in [2, 4, 8, 32, 128]]
    + [f"middle-{n}" for n in [8, 32, 128]]
    + [f"penultimate-{n}" for n in [2, 4, 8, 32, 128]]
    + [f"latest-{n}" for n in [2, 4, 8, 32, 128]]
    + [f"before-{n}" for n in [8, 128]]
    + [f"frames-{n}" for n in [4, 8, 32, 128]]
    + ["expired-128", "clear-128", "invalid-128", "sweep-128"]
    + [f"fourth-{n}" for n in [8, 32, 128]]
    + [f"tail-{n}" for n in [8, 32, 128]]
    + ["fifth-128", "eighth-128"]
)
VARIANTS = ("baseline", "candidate")
COMMAND_NUMBER = 0
UINT64_MASK = (1 << 64) - 1


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def run(command: list, output: Path, *, timeout: int = 300, combined: bool = False) -> str:
    """Preserve exact output bytes, including every JSON UInt64, before parsing."""
    global COMMAND_NUMBER
    COMMAND_NUMBER += 1
    command = [str(part) for part in command]
    cache = str(output / "build/module-cache")
    overrides = {"CLANG_MODULE_CACHE_PATH": cache, "SWIFT_MODULECACHE_PATH": cache,
                 "SWIFTPM_MODULECACHE_OVERRIDE": cache, "TERM": "dumb", "NO_COLOR": "1"}
    environment = {**os.environ, **overrides}
    started = time.time()
    timed_out = False
    try:
        result = subprocess.run(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout)
        stdout, stderr, returncode = result.stdout, result.stderr, result.returncode
    except subprocess.TimeoutExpired as error:
        stdout, stderr, returncode = error.stdout or b"", error.stderr or b"", None
        timed_out = True
    stdout_path = f"logs/{COMMAND_NUMBER:04d}.stdout.txt"
    stderr_path = f"logs/{COMMAND_NUMBER:04d}.stderr.txt"
    (output / stdout_path).write_bytes(stdout)
    (output / stderr_path).write_bytes(stderr)
    append_json(output / "commands.jsonl", {
        "command": command, "cwd": str(ROOT), "environment_overrides": overrides,
        "returncode": returncode, "timed_out": timed_out, "timeout_seconds": timeout,
        "started_unix": started, "elapsed_seconds": time.time() - started,
        "stdout": stdout_path, "stdout_sha256": digest(stdout), "stdout_bytes": len(stdout),
        "stderr": stderr_path, "stderr_sha256": digest(stderr), "stderr_bytes": len(stderr),
    })
    if returncode != 0:
        raise RuntimeError(f"Command failed ({returncode}, timeout={timed_out}): {command!r}; "
                           f"see {stdout_path} and {stderr_path}")
    return (stdout + stderr if combined else stdout).decode("utf-8")


def snapshot(path: Path, data: bytes, output: Path, hashes: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    hashes[str(path.relative_to(output))] = digest(data)


def method_span(source: str) -> tuple[int, int]:
    signature = "    func composition(at seconds: Double) -> (start: Double, value: NativeBitmapSubtitleComposition)? {"
    if source.count(signature) != 1:
        raise ValueError("Expected exactly one production composition(at:) declaration")
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return start, index + 1
    raise ValueError("Unbalanced composition(at:) declaration; review source boundary")


def require_lookup_only_change(baseline: bytes, candidate: bytes) -> None:
    old, new = baseline.decode(), candidate.decode()
    old_start, old_end = method_span(old)
    new_start, new_end = method_span(new)
    if old[:old_start] != new[:new_start] or old[old_end:] != new[new_end:]:
        raise ValueError("Production changes outside composition(at:) would confound this experiment")
    if old[old_start:old_end] == new[new_start:new_end]:
        raise ValueError("Baseline and candidate lookup implementations are identical")


def region_source(original: bytes) -> bytes:
    source = original.decode()
    start, end = "struct ASSRenderedRegion: Sendable {", "struct ASSRenderResult: Sendable {"
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("ASSRenderedRegion extraction boundaries changed")
    return ("import Foundation\nimport CoreGraphics\n\n"
            + source[source.index(start):source.index(end)]).encode()


def prepare(output: Path, manifest: dict) -> None:
    hashes = manifest["snapshot_sha256"]
    inputs = manifest["worktree_input_sha256"]
    baseline = run(["git", "show", f"{BASELINE}:Sources/IlliquidNativePlayback/{TIMELINE}"],
                   output).encode()
    candidate = (NATIVE / TIMELINE).read_bytes()
    require_lookup_only_change(baseline, candidate)
    budget, regions = (NATIVE / BUDGET).read_bytes(), (NATIVE / REGIONS).read_bytes()
    # The exact same current native support bytes are used by both arms.
    region = region_source(regions)
    manifest["production_source_sha256"] = {
        "baseline": {TIMELINE: digest(baseline), BUDGET: digest(budget), REGIONS: digest(regions)},
        "candidate": {TIMELINE: digest(candidate), BUDGET: digest(budget), REGIONS: digest(regions)},
    }
    manifest["region_declaration_sha256"] = digest(region)
    for variant, timeline in [("baseline", baseline), ("candidate", candidate)]:
        for name, data in [(SOURCE_NAMES[0], timeline), (SOURCE_NAMES[1], budget),
                           (SOURCE_NAMES[2], region)]:
            snapshot(output / "sources" / variant / name, data, output, hashes)
    snapshot(output / "sources/LibassContext.original.swift", regions, output, hashes)
    for relative in [TIMELINE, BUDGET, REGIONS]:
        path = NATIVE / relative
        inputs[str(path.relative_to(ROOT))] = file_digest(path)
    for name in TESTS:
        path = ROOT / "Tests/IlliquidNativePlaybackTests" / name
        data = path.read_bytes()
        snapshot(output / "tests" / name, data, output, hashes)
        inputs[str(path.relative_to(ROOT))] = digest(data)
    for name in ["Driver.swift", "run.py"]:
        path = HERE / name
        data = path.read_bytes()
        snapshot(output / "harness" / name, data, output, hashes)
        inputs[str(path.relative_to(ROOT))] = digest(data)
    package = b'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "BitmapSubtitleTailLookupRegressionTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
'''
    snapshot(output / "harness/Tests.Package.swift", package, output, hashes)


def build(variant: str, output: Path, manifest: dict) -> Path:
    destination = output / "build" / variant
    destination.mkdir()
    library = destination / "libIlliquidNativePlayback.dylib"
    paths = [output / "sources" / variant / name for name in SOURCE_NAMES]
    flags = ["-swift-version", "6", "-O", "-warnings-as-errors",
             "-target", f"{platform.machine()}-apple-macos26.0",
             "-sdk", manifest["sdk_path"], "-module-cache-path", output / "build/module-cache"]
    run([manifest["tools"]["swiftc"]["path"], *flags, "-whole-module-optimization",
         "-enable-testing", "-emit-library", "-emit-module", "-module-name", "IlliquidNativePlayback",
         "-emit-module-path", destination / "IlliquidNativePlayback.swiftmodule",
         *paths, "-o", library], output)
    executable = destination / "benchmark"
    run([manifest["tools"]["swiftc"]["path"], *flags, "-parse-as-library",
         "-I", destination, "-L", destination, "-lIlliquidNativePlayback",
         "-Xlinker", "-rpath", "-Xlinker", destination,
         output / "harness/Driver.swift", "-o", executable], output)
    for path in destination.iterdir():
        if path.is_file():
            manifest["binary_sha256"][str(path.relative_to(output))] = file_digest(path)
    return executable


def test_variant(variant: str, output: Path, manifest: dict) -> list[dict]:
    package = output / "build" / f"tests-{variant}"
    copies = manifest["compiled_copy_sha256"]
    files = [(output / "sources" / variant / name,
              package / "Sources/IlliquidNativePlayback" / name) for name in SOURCE_NAMES]
    files += [(output / "tests" / name,
               package / "Tests/IlliquidNativePlaybackTests" / name) for name in TESTS]
    files.append((output / "harness/Tests.Package.swift", package / "Package.swift"))
    for original, destination in files:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, destination)
        copies[str(destination.relative_to(output))] = file_digest(destination)
        if copies[str(destination.relative_to(output))] != file_digest(original):
            raise ValueError("Test staging changed a source file")
    results = []
    for configuration in ("debug", "release"):
        log = run([manifest["tools"]["swift"]["path"], "test", "--package-path", package,
                   "--cache-path", output / "build/cache", "--config-path", output / "build/config",
                   "--security-path", output / "build/security",
                   "--jobs", "2", "--no-parallel", "-c", configuration,
                   "-Xswiftc", "-warnings-as-errors"], output, timeout=600, combined=True)
        log_path = f"{variant}-{configuration}-tests.txt"
        (output / log_path).write_text(log)
        counts = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", log)
        if len(counts) != 1 or int(counts[0]) < 1:
            raise ValueError(f"Expected a successful nonempty Swift Testing run: {log_path}")
        results.append({"variant": variant, "configuration": configuration,
                        "tests_passed": int(counts[0]), "log": log_path,
                        "log_sha256": file_digest(output / log_path)})
        print(f"{variant} {configuration}: {counts[0]} tests passed", flush=True)
    return results


def validate_record(record: dict, case: str, iterations: int, seed: int) -> None:
    if record["case"] != case or record["iterations"] != iterations or record["seed"] != seed:
        raise ValueError("Driver receipt does not match its command")
    for field in ["elapsed_ns", "cpu_ns", "checksum", "present_queries", "seed"]:
        if type(record[field]) is not int or not 0 <= record[field] <= UINT64_MASK:
            raise ValueError(f"Driver field is not an exact UInt64: {field}")
    if record["elapsed_ns"] <= 0 or record["cpu_ns"] <= 0:
        raise ValueError("Driver reported a nonpositive timing")
    queries = 120 if case.startswith("frames-") else 128 if case == "sweep-128" else 64
    if record["operations_per_iteration"] != queries or record["queries_per_iteration"] != queries:
        raise ValueError("Unexpected lookup count")
    count = 0 if case == "empty" else 1 if case.startswith("single-") else int(case.split("-")[1])
    receipt = record["receipt"]
    expected_bytes = 16 * (count - (count + 1) // 4)
    if (receipt["generation"] != 7 or receipt["revision"] != count + 1
            or receipt["retainedBytes"] != expected_bytes or receipt["reservedBytes"] != expected_bytes
            or len(receipt["queries"]) != queries):
        raise ValueError("Unexpected timeline, lease or query receipt")
    checksum, present = 0, 0
    for query in receipt["queries"]:
        if type(query["queryBits"]) is not int or not 0 <= query["queryBits"] <= UINT64_MASK:
            raise ValueError("Query bit pattern is not an exact UInt64")
        value = query.get("value")
        if value is None:
            if query.get("startBits") is not None:
                raise ValueError("Absent composition has a start")
            score = 0x42D003199AA787D5
        else:
            present += 1
            duration = value.get("durationBits")
            regions = value["regions"]
            pixel = regions[0]["pixels"][0] if regions and regions[0]["pixels"] else 0
            score = query["startBits"] + (duration if duration is not None else 0x19D63AD417600EC7)
            score += len(regions) + pixel
        checksum = (checksum + score) & UINT64_MASK
    if (record["checksum"] != ((checksum * iterations) & UINT64_MASK)
            or record["present_queries"] != present * iterations):
        raise ValueError("Timed counts/checksum disagree with the complete query receipt")


def measure(executable: Path, case: str, iterations: int, seed: int, output: Path) -> dict:
    record = json.loads(run([executable, case, iterations, seed], output, timeout=120))
    validate_record(record, case, iterations, seed)
    receipt = record.pop("receipt")
    data = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode()
    relative = f"receipts/{executable.parent.name}-{case}-{seed}.json"
    path = output / relative
    if path.exists() and path.read_bytes() != data:
        raise ValueError("Immutable fixture receipt changed between calibration invocations")
    path.write_bytes(data)
    record["receipt_path"], record["receipt_sha256"] = relative, digest(data)
    total = iterations * record["operations_per_iteration"]
    record["ns_per_iteration"] = record["elapsed_ns"] / iterations
    record["wall_ns_per_query"] = record["elapsed_ns"] / total
    record["cpu_ns_per_query"] = record["cpu_ns"] / total
    return record


def summarize(records: list[dict], output: Path, target_ms: float) -> dict:
    summaries = {}
    for case in dict.fromkeys(row["case"] for row in records):
        rows = [row for row in records if row["case"] == case]
        pairs = sorted({row["pair"] for row in rows})
        for pair in pairs:
            paired_rows = [row for row in rows if row["pair"] == pair]
            paired = {row["variant"]: row for row in paired_rows}
            if len(paired_rows) != 2 or set(paired) != set(VARIANTS):
                raise ValueError("Incomplete or duplicated paired observation")
            for field in ["checksum", "present_queries", "iterations", "seed",
                          "operations_per_iteration", "queries_per_iteration", "receipt_sha256"]:
                if paired["baseline"][field] != paired["candidate"][field]:
                    raise ValueError(f"Paired mismatch: {case}/{pair}/{field}")
            first = (output / paired["baseline"]["receipt_path"]).read_bytes()
            second = (output / paired["candidate"]["receipt_path"]).read_bytes()
            if first != second:
                raise ValueError(f"Complete query receipt differs: {case}/{pair}")
        summary = {}
        for metric in ["wall", "cpu"]:
            field = f"{metric}_ns_per_query"
            values = {variant: [row[field] for row in rows if row["variant"] == variant]
                      for variant in VARIANTS}
            result = {variant: {"median_ns": statistics.median(data), "min_ns": min(data),
                                "max_ns": max(data)} for variant, data in values.items()}
            reductions = []
            for pair in pairs:
                paired = {row["variant"]: row for row in rows if row["pair"] == pair}
                reductions.append(100 * (1 - paired["candidate"][field] / paired["baseline"][field]))
            result["paired_reduction_percent"] = {
                "median": statistics.median(reductions), "min": min(reductions), "max": max(reductions),
                "candidate_faster_pairs": sum(value > 0 for value in reductions), "pairs": len(pairs),
                "values": reductions,
            }
            result["median_reduction_percent"] = 100 * (
                1 - result["candidate"]["median_ns"] / result["baseline"]["median_ns"])
            summary[metric] = result
        summary["under_target"] = [
            {"variant": row["variant"], "pair": row["pair"], "milliseconds": row["elapsed_ns"] / 1e6}
            for row in rows if row["elapsed_ns"] < target_ms * 1e6
        ]
        summaries[case] = summary
    return summaries


def verify_inputs(output: Path, manifest: dict) -> None:
    for key in ["snapshot_sha256", "compiled_copy_sha256", "binary_sha256"]:
        for relative, expected in manifest[key].items():
            if file_digest(output / relative) != expected:
                raise ValueError(f"Measured/staged file changed during run: {relative}")
    for relative, expected in manifest["worktree_input_sha256"].items():
        if file_digest(ROOT / relative) != expected:
            raise ValueError(f"Worktree input changed during run: {relative}")
    for name, receipt in manifest["tools"].items():
        if file_digest(Path(receipt["resolved_path"])) != receipt["sha256"]:
            raise ValueError(f"Compiler changed during run: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--max-sample-ms", type=float, default=1500)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    cases = args.cases.split(",")
    if platform.system() != "Darwin":
        parser.error("This native component experiment requires macOS CoreGraphics")
    if (args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms)
            or not math.isfinite(args.max_sample_ms) or args.target_ms <= 0
            or args.max_sample_ms < args.target_ms or len(set(cases)) != len(cases)
            or any(case not in CASES for case in cases)):
        parser.error("Use an even pair count >= 2, valid cases and positive finite timing bounds")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new, empty output directory; preserve earlier attempts separately")
    output.mkdir(parents=True, exist_ok=True)
    for folder in ["build", "logs", "receipts"]:
        (output / folder).mkdir()
    complete = False
    manifest = {
        "schema": 1, "baseline_commit": BASELINE,
        "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(),
        "arguments": {**vars(args), "output": str(output)}, "tools": {},
        "snapshot_sha256": {}, "compiled_copy_sha256": {}, "binary_sha256": {},
        "worktree_input_sha256": {},
        "extraction": "Complete native timeline and budget; exact ASSRenderedRegion declaration "
                      "with Foundation/CoreGraphics imports. Only composition(at:) differs.",
        "method": "Separate optimized production module; warm immutable query fixtures; "
                  "equal-iteration fresh-process AB/BA pairs; no discarded samples or control subtraction.",
        "scope": "Native component lookup, including identical query-loop/result-consumption overhead; "
                 "not decoder, prune, renderer or whole-player frame time.",
    }
    try:
        manifest["git_head"] = run(["git", "rev-parse", "HEAD"], output).strip()
        manifest["git_status"] = run(["git", "status", "--porcelain"], output).strip()
        manifest["developer_dir"] = os.environ.get("DEVELOPER_DIR")
        manifest["sw_vers"] = run(["sw_vers"], output).strip()
        manifest["hardware"] = run(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip()
        manifest["sdk_path"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], output).strip()
        manifest["sdk_version"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], output).strip()
        for name in ["swiftc", "swift", "swift-frontend"]:
            path = Path(run(["xcrun", "--find", name], output).strip())
            resolved = path.resolve()
            manifest["tools"][name] = {"path": str(path), "resolved_path": str(resolved),
                                      "sha256": file_digest(resolved),
                                      "version": run([path, "--version"], output).strip()}
        prepare(output, manifest)
        write_json(output / "manifest.json", manifest)
        if args.tests_only:
            tests = []
            for variant in VARIANTS:
                tests.extend(test_variant(variant, output, manifest))
            if len({row["tests_passed"] for row in tests}) != 1:
                raise ValueError("The four runs did not execute the same test count")
            verification = {"mode": "tests-only", "tests": tests}
        else:
            executables = {variant: build(variant, output, manifest) for variant in VARIANTS}
            write_json(output / "manifest.json", manifest)
            records = []
            for case in cases:
                calibration = {}
                for variant, executable in executables.items():
                    first = measure(executable, case, 1, 1000, output)
                    probe_iterations = max(1, min(10000, math.ceil(20_000_000 / first["elapsed_ns"])))
                    probe = measure(executable, case, probe_iterations, 1000, output)
                    calibration[variant] = probe["ns_per_iteration"]
                    append_json(output / "calibration.jsonl", {"variant": variant, "stage": "single", **first})
                    append_json(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **probe})
                requested = math.ceil(args.target_ms * 1e6 / min(calibration.values()))
                bound = math.floor(args.max_sample_ms * 1e6 / max(calibration.values()))
                iterations = max(1, min(requested, bound))
                append_json(output / "calibration.jsonl", {
                    "case": case, "stage": "selection", "ns_per_iteration": calibration,
                    "requested_iterations": requested, "slower_arm_bound": bound,
                    "iterations": iterations, "slow_arm_cap_applied": requested > bound,
                })
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    for position, variant in enumerate(order):
                        record = measure(executables[variant], case, iterations, 2000 + pair, output)
                        record.update(variant=variant, pair=pair, position=position, order=list(order))
                        records.append(record)
                        append_json(output / "measurements.jsonl", record)
                    summarize(records[-2:], output, args.target_ms)
                summary = summarize(records, output, args.target_ms)
                write_json(output / "summary.json", summary)
                print(case, json.dumps(summary[case], sort_keys=True), flush=True)
            if len(records) != len(cases) * args.pairs * 2:
                raise ValueError("Incomplete cohort")
            verification = {"mode": "measure", "all_pairs_equal": True, "records": len(records),
                            "cases": len(cases), "pairs_per_case": args.pairs,
                            "minimum_duration_met": all(not cell["under_target"] for cell in summary.values())}
        verify_inputs(output, manifest)
        manifest["build_directory_removed_after_verification"] = True
        write_json(output / "manifest.json", manifest)
        verification.update(complete=True, sources_tests_harness_compilers_and_binaries_unchanged=True)
        write_json(output / "verification.json", verification)
        complete = True
    except Exception as error:
        write_json(output / "manifest.json", manifest)
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        if complete:
            shutil.rmtree(output / "build")


if __name__ == "__main__":
    main()
