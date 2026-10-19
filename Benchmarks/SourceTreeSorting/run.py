#!/usr/bin/env python3
"""Test and benchmark exact source-browser sort declarations with Foundation.

No dependency downloads or source edits. The native app graph is tested
separately in CI; this component harness needs only Swift, Python, and git.
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
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SIDEBAR = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
MODEL = "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
TEST = "Tests/IlliquidAppTests/SourceTreeSortingTests.swift"


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def section(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError("Source extraction anchors changed; review the harness")
    return source[source.index(start):source.index(end)].rstrip() + "\n"


def selected_tool(name: str) -> str | None:
    configured = os.environ.get(name.upper())
    if configured:
        return configured
    if sys.platform == "darwin":
        return subprocess.check_output(["xcrun", "--find", name], text=True).strip()
    return shutil.which(name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "test", "benchmark"], default="all")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=40)
    parser.add_argument("--swiftc", default=selected_tool("swiftc"))
    parser.add_argument("--swift", default=selected_tool("swift"))
    args = parser.parse_args()
    if not args.swiftc or (args.mode != "benchmark" and not args.swift):
        parser.error("Swift toolchain required; set SWIFTC/SWIFT or use PATH")
    if not 2 <= args.pairs <= 30 or not 5 <= args.target_ms <= 1000:
        parser.error("pairs must be 2...30 and target-ms must be 5...1000")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("output must be new or empty to preserve previous evidence")
    out.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(out / "module-cache")

    def run(argv: list[str | Path], log: Path | None = None, cwd: Path = ROOT) -> str:
        command = [str(value) for value in argv]
        result = subprocess.run(command, cwd=cwd, env=environment, text=True, capture_output=True)
        if log:
            log.write_text(json.dumps(command) + "\n\n" + result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{result.stderr[-6000:]}")
        return result.stdout

    receipt = {
        "baseline": BASELINE, "head": run(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree": run(["git", "status", "--short"]),
        "platform": platform.platform(), "architecture": platform.machine(),
        "compiler": run([args.swiftc, "--version"]).strip(),
        "locale_environment": {key: environment.get(key) for key in ["LANG", "LC_ALL", "LC_COLLATE"]},
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
        "sources": {},
    }
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization",
             "-parse-as-library", "-enable-testing", "-warnings-as-errors",
             "-module-cache-path", str(out / "module-cache")]
    if sys.platform == "darwin":
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        receipt["native_sdk"] = sdk
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    receipt["flags"] = flags
    binaries = {}
    for variant in ["baseline", "candidate"]:
        folder = out / variant
        folder.mkdir()
        source = {}
        for path in [SIDEBAR, MODEL]:
            source[path] = run(["git", "show", f"{BASELINE}:{path}"]) if variant == "baseline" else (ROOT / path).read_text()
        extracted = "import Foundation\n\n"
        extracted += section(source[MODEL], "public struct RecognizedMediaName:", "\npublic enum MediaNameRecognition")
        extracted += "\n" + section(source[SIDEBAR], "struct SourceTreeEntry:", "\nstruct SourceVisibilityRegexMatch:")
        extracted += "\n" + section(source[SIDEBAR], "enum SourceTreeSortCriterion:", "\nstruct SourceDirectoryListing:")
        model_file = folder / "Sorting.swift"
        model_file.write_text(extracted)
        receipt["sources"][variant] = {
            "input_sha256": {path: digest(text.encode()) for path, text in source.items()},
            "extracted_sha256": digest(extracted.encode()),
        }
        if args.mode in ["all", "test"]:
            package = folder / "tests"
            (package / "Sources/IlliquidApp").mkdir(parents=True)
            (package / "Tests/IlliquidAppTests").mkdir(parents=True)
            (package / "Sources/IlliquidApp/Sorting.swift").write_text(extracted)
            shutil.copyfile(ROOT / TEST, package / "Tests/IlliquidAppTests/SourceTreeSortingTests.swift")
            (package / "Package.swift").write_text(
                '// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "SortingTests", platforms: [.macOS("26.0")], targets: ['
                '.target(name: "IlliquidApp"),'
                '.testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])])\n'
            )
            for configuration in ["debug", "release"]:
                print(f"Testing {variant} ({configuration})", flush=True)
                command = [args.swift, "test", "--package-path", package,
                           "--configuration", configuration, "--jobs", "2",
                           "--cache-path", out / "swiftpm-cache",
                           "--config-path", out / "swiftpm-config",
                           "--security-path", out / "swiftpm-security"]
                if sys.platform != "darwin":
                    command += ["--use-integrated-swift-driver"]
                run(command, folder / f"tests-{configuration}.log")
        if args.mode in ["all", "benchmark"]:
            run([args.swiftc, *flags, "-module-name", "IlliquidApp",
                 "-emit-object", "-emit-module", "-emit-module-path", folder / "IlliquidApp.swiftmodule",
                 model_file, "-o", folder / "IlliquidApp.o"], folder / "compile-module.log")
            binary = folder / "benchmark"
            run([args.swiftc, *flags, "-I", folder, HERE / "Harness.swift",
                 folder / "IlliquidApp.o", "-o", binary], folder / "compile-harness.log")
            binaries[variant] = binary
            receipt["sources"][variant]["binary_sha256"] = digest(binary.read_bytes())
    receipt["test_sha256"] = digest((ROOT / TEST).read_bytes())
    receipt["contract_tests_run"] = args.mode in ["all", "test"]
    if binaries:
        receipt["runtime"] = {
            variant: json.loads(run([binary, "environment"]))
            for variant, binary in binaries.items()
        }
        if receipt["runtime"]["baseline"] != receipt["runtime"]["candidate"]:
            raise RuntimeError("Baseline/candidate runtime environment or entry layout differs")
    write_json(out / "receipt.json", receipt)
    if args.mode == "test":
        print("Baseline and candidate contract tests passed in debug and release.", flush=True)
        return

    outputs = {}
    for variant, binary in binaries.items():
        print(f"Comparing complete sorted outputs: {variant}", flush=True)
        outputs[variant] = run([binary, "verify"])
        with gzip.open(out / f"verification-{variant}.jsonl.gz", "wt") as sink:
            sink.write(outputs[variant])
    if outputs["baseline"] != outputs["candidate"]:
        raise RuntimeError("Baseline/candidate complete output order differs")
    verification = {"passed": True, "cases": len(outputs["baseline"].splitlines()),
                    "sha256": digest(outputs["baseline"].encode())}
    write_json(out / "verification.json", verification)
    print(f"Exact output and payload parity: {verification['cases']} cases", flush=True)
    scenarios = json.loads(run([binaries["baseline"], "list"]))
    if scenarios != json.loads(run([binaries["candidate"], "list"])):
        raise RuntimeError("Scenario inventory differs")
    rows, summary = [], []
    for scenario in scenarios:
        name = scenario["name"]

        def sample(variant: str, iterations: int) -> dict:
            row = json.loads(run([binaries[variant], "sample", name, str(iterations)]))
            if (row["scenario"] != name or row["count"] != scenario["count"]
                    or row["iterations"] != iterations or row["elapsed_ns"] <= 0):
                raise RuntimeError("Invalid benchmark output")
            row["variant"] = variant
            return row

        pilots = [sample(variant, 3) for variant in binaries]
        fastest_ns = min(row["elapsed_ns"] / row["iterations"] for row in pilots)
        # Bound long baseline controls when a no-work candidate becomes O(1).
        slowest_ns = max(row["elapsed_ns"] / row["iterations"] for row in pilots)
        iterations = max(1, min(1_000_000, math.ceil(args.target_ms * 1e6 / fastest_ns),
                                math.ceil(250e6 / slowest_ns)))
        paired = []
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            measurements = {}
            for variant in order:
                row = sample(variant, iterations)
                row.update(pair=pair, order=order.index(variant))
                measurements[variant] = row
                rows.append(row)
                with (out / "measurements.jsonl").open("a") as sink:
                    sink.write(json.dumps(row, sort_keys=True) + "\n")
            if measurements["baseline"]["checksum"] != measurements["candidate"]["checksum"]:
                raise RuntimeError(f"Timed output checksum differs for {name}")
            paired.append(measurements["candidate"]["elapsed_ns"] / measurements["baseline"]["elapsed_ns"])
        values = {}
        for variant in binaries:
            times = [row["elapsed_ns"] / row["iterations"] for row in rows
                     if row["scenario"] == name and row["variant"] == variant]
            values[variant] = {"median_ns": statistics.median(times), "min_ns": min(times), "max_ns": max(times)}
        result = {"scenario": name, "count": scenario["count"], "iterations": iterations,
                  "pairs": args.pairs, **values,
                  "paired_reduction_percent": 100 * (1 - statistics.median(paired))}
        summary.append(result)
        print(f"{name}: {values['baseline']['median_ns'] / 1e6:.4f} -> "
              f"{values['candidate']['median_ns'] / 1e6:.4f} ms "
              f"({result['paired_reduction_percent']:.1f}% paired reduction)", flush=True)
        write_json(out / "summary.json", summary)


if __name__ == "__main__":
    main()
