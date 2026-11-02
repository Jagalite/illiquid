#!/usr/bin/env python3
"""Qualify the real CoreMedia cache, then compare fresh-process paired timings."""

import argparse
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

ROOT = Path(__file__).resolve().parents[2]
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PRESENTER = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
CACHE = "Sources/IlliquidNativePlayback/Presentation/VideoFormatDescriptionCache.swift"
SIGNPOSTS = "Sources/IlliquidNativePlayback/Diagnostics/NativePlaybackSignposts.swift"
TESTS = "Tests/IlliquidNativePlaybackTests/VideoFormatDescriptionCacheTests.swift"
DRIVER = "Benchmarks/VideoFormatDescription/Driver.swift"
CASES = ["stable-bgra", "stable-nv12", "stable-p010-hdr", "alternating-size", "alternating-color"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("Use a positive target and an even number of at least two pairs")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    for name in ["logs", "sources", "build", "module-cache"]:
        (output / name).mkdir()
    commands = []
    environment = dict(os.environ)
    environment["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")

    def save(name, value):
        (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def run(label, command, timeout=300):
        command = [str(part) for part in command]
        started = time.time()
        print(f"Running {label}", flush=True)
        result = subprocess.run(
            command, cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
        )
        log = output / "logs" / (label + ".log")
        log.write_text(result.stdout)
        commands.append({
            "label": label, "argv": command, "exit_code": result.returncode,
            "started_unix_seconds": started, "elapsed_seconds": time.time() - started,
            "log": str(log.relative_to(output)), "log_sha256": digest(log),
        })
        save("commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{result.stdout[-8000:]}")
        return result.stdout

    try:
        if sys.platform != "darwin":
            raise RuntimeError("CoreMedia validation requires macOS; no native tests were executed")
        swift = shutil.which("swift")
        swiftc = shutil.which("swiftc")
        if not swift or not swiftc:
            raise RuntimeError("Swift toolchain is unavailable")
        sdk = run("sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        source_paths = [PRESENTER, CACHE, SIGNPOSTS, TESTS, DRIVER, "Benchmarks/VideoFormatDescription/run.py"]
        manifest = {
            "baseline_commit": BASE,
            "head_commit": run("head", ["git", "rev-parse", "HEAD"]).strip(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "os": run("os", ["sw_vers"]).strip(),
            "cpu": run("cpu", ["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "swift": run("swift-version", [swift, "--version"]).strip(),
            "sdk": sdk, "developer_dir": environment.get("DEVELOPER_DIR"),
            "source_sha256": {path: digest(ROOT / path) for path in source_paths},
            "kyoto_path_available": Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists(),
            "scope": "CoreMedia metadata preparation; excludes decoding, renderer, and live UI",
            "protocol": {
                "pairs": args.pairs, "target_ms": args.target_ms,
                "fresh_process_per_observation": True, "balanced_order": "AB/BA",
                "warmup_iterations": 2048, "autorelease_pool_batch": 256,
                "timing": "wall and process CPU; construction counters outside timed passes",
                "success": "all correctness checks; every stable case median CPU ratio < 0.95, at least 7/8 CPU pairs faster, median wall ratio < 0.95",
            },
        }
        save("manifest.json", manifest)
        if not manifest["kyoto_path_available"]:
            print("Kyoto is unavailable on this host; using isolated, serialized direct builds.", flush=True)
        run("diff-check", ["git", "diff", "--check", BASE, "--", *source_paths])

        # Extract the pinned production factory, preserving checks and signposts.
        baseline = run("baseline-presenter", ["git", "show", f"{BASE}:{PRESENTER}"])
        start_marker = "        var formatDescription: CMVideoFormatDescription?\n"
        end_marker = "\n\n        var timing = CMSampleTimingInfo("
        if baseline.count(start_marker) != 1 or baseline.count(end_marker) != 1:
            raise RuntimeError("Pinned baseline factory anchors changed")
        block = baseline.split(start_marker, 1)[1].split(end_marker, 1)[0]
        block = start_marker + block
        block = "\n".join(line[4:] if line.startswith("    ") else line for line in block.splitlines())
        block = block.replace("frame.pixelBuffer", "imageBuffer")
        errors = baseline[baseline.index("struct PresentationError: LocalizedError {"):]
        factory = (
            "import CoreMedia\nimport CoreVideo\nimport Foundation\n\n"
            "func createFormatDescription(_ imageBuffer: CVPixelBuffer) throws -> CMVideoFormatDescription {\n"
            + block + "\n    return formatDescription\n}\n\n" + errors
        )
        baseline_path = output / "sources" / "BaselineFactory.swift"
        baseline_path.write_text(factory)
        for path in [CACHE, SIGNPOSTS, TESTS, DRIVER]:
            shutil.copy2(ROOT / path, output / "sources" / Path(path).name)
        pinned_signposts = run("baseline-signposts", ["git", "show", f"{BASE}:{SIGNPOSTS}"])
        if pinned_signposts != (ROOT / SIGNPOSTS).read_text():
            raise RuntimeError("Signpost implementation differs from pinned baseline")
        manifest["baseline_presenter_sha256"] = hashlib.sha256(baseline.encode()).hexdigest()
        manifest["baseline_factory_sha256"] = digest(baseline_path)

        package = output / "build" / "package"
        module = package / "Sources" / "IlliquidNativePlayback"
        tests = package / "Tests" / "VideoFormatDescriptionTests"
        module.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copy2(ROOT / CACHE, module / Path(CACHE).name)
        shutil.copy2(ROOT / TESTS, tests / Path(TESTS).name)
        (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "VideoFormatDescriptionQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "VideoFormatDescriptionTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
""")
        test_results = []
        for configuration in ["debug", "release"]:
            result = run("tests-" + configuration, [
                swift, "test", "--package-path", package, "-c", configuration,
                "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors",
            ], timeout=600)
            passed = re.search(r"Test run with (\d+) tests? (?:in .*? )?passed", result)
            if not passed or int(passed.group(1)) < 11:
                raise RuntimeError("Expected at least 11 executed Swift Testing test functions")
            test_results.append({"configuration": configuration, "passed_tests": int(passed.group(1))})
            save("tests.json", test_results)

        binary = output / "build" / "benchmark"
        target = platform.machine() + "-apple-macosx26.0"
        run("compile-benchmark", [
            swiftc, "-O", "-whole-module-optimization", "-parse-as-library",
            "-swift-version", "6", "-warnings-as-errors", "-sdk", sdk, "-target", target,
            output / "sources" / Path(CACHE).name, baseline_path,
            output / "sources" / Path(SIGNPOSTS).name, output / "sources" / Path(DRIVER).name,
            "-o", binary,
        ], timeout=600)
        manifest["binary_sha256"] = digest(binary)
        save("manifest.json", manifest)

        def observation(label, mode, case, iterations):
            text = run(label, [binary, mode, case, iterations])
            value = json.loads(text.strip().splitlines()[-1])
            if value["iterations"] != iterations or value["workload"] != case:
                raise RuntimeError("Observation identity mismatch")
            if mode != "verify" and (value["cpu_ns"] <= 0 or value["wall_ns"] <= 0):
                raise RuntimeError("Invalid timing observation")
            return value

        verification = [
            observation("verify-" + case, "verify", case, 64) for case in CASES
        ]
        save("verification.json", verification)
        if args.tests_only:
            save("completion.json", {"complete": True, "mode": "tests-only", "tests_passed": True,
                                     "parity_passed": True, "performance_measured": False})
            return

        calibrations = []
        observations = []
        summaries = []
        for case_index, case in enumerate(CASES):
            probes = [
                observation(f"calibrate-{case}-{mode}", mode, case, 8192)
                for mode in ["baseline", "cached"]
            ]
            fastest = min(row["wall_ns_per_operation"] for row in probes)
            count = math.ceil(args.target_ms * 1_000_000 / fastest / 256) * 256
            count = max(8192, min(2_000_128, count))
            calibrations.append({"workload": case, "iterations": count, "probes": probes})
            save("calibrations.json", calibrations)
            ratios = []
            for pair in range(args.pairs):
                order = ["baseline", "cached"] if pair % 2 == 0 else ["cached", "baseline"]
                values = {}
                for position, mode in enumerate(order):
                    row = observation(f"{case}-pair-{pair + 1}-{mode}", mode, case, count)
                    expected_checksum = verification[case_index]["checksum"] * count // 64
                    if row["checksum"] != expected_checksum:
                        raise RuntimeError("Timing checksum differs from verified output")
                    row.update({"pair": pair + 1, "position": position})
                    observations.append(row)
                    values[mode] = row
                    save("observations.json", observations)
                ratios.append({
                    "pair": pair + 1,
                    "cpu_ratio": values["cached"]["cpu_ns"] / values["baseline"]["cpu_ns"],
                    "wall_ratio": values["cached"]["wall_ns"] / values["baseline"]["wall_ns"],
                })
            rows = [row for row in observations if row["workload"] == case]
            summary = {"workload": case, "iterations": count, "pairs": args.pairs, "paired_ratios": ratios}
            for metric in ["cpu", "wall"]:
                summary[metric + "_median_ratio"] = statistics.median(row[metric + "_ratio"] for row in ratios)
                summary[metric + "_faster_pairs"] = sum(row[metric + "_ratio"] < 1 for row in ratios)
                for mode in ["baseline", "cached"]:
                    summary[mode + "_" + metric + "_median_ns"] = statistics.median(
                        row[metric + "_ns_per_operation"] for row in rows if row["mode"] == mode
                    )
            summaries.append(summary)
            save("summary.json", summaries)

        stable = [row for row in summaries if row["workload"].startswith("stable-")]
        performance_success = all(
            row["cpu_median_ratio"] < 0.95 and row["wall_median_ratio"] < 0.95
            and row["cpu_faster_pairs"] >= math.ceil(args.pairs * 7 / 8)
            for row in stable
        )
        save("completion.json", {
            "complete": True, "mode": "paired-benchmark", "tests_passed": True,
            "parity_passed": True, "performance_measured": True,
            "observations": len(observations),
            "stable_performance_criterion_met": performance_success,
            "miss_overhead_reported_in": ["alternating-size", "alternating-color"],
            "player_rss_measured": False, "live_playback_qualified": False,
        })
        print(json.dumps(summaries, indent=2), flush=True)
    except Exception as error:
        save("completion.json", {"complete": False, "error": str(error)})
        raise


if __name__ == "__main__":
    main()
