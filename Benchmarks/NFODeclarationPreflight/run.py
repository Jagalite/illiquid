#!/usr/bin/env python3
"""Compare complete NFO parses using a frozen parser and current shared sources."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "051c475fd33bcd16ec33f6b4b93ee98fffdb21d3"
PARSER = "NFOMetadataHints.swift"
SOURCES = ["MediaNameRecognition.swift", "MediaMetadataHints.swift", PARSER,
           "PlexMatchHints.swift", "MediaSidecarReader.swift"]
TESTS = ["MediaSidecarTests.swift", "NFOMetadataFieldSelectionTests.swift",
         "NFOEpisodeScopeRegressionTests.swift", "MediaNameRecognitionTests.swift",
         "NFOTextLimitPerformanceTests.swift", "NFODeclarationPreflightTests.swift"]
VARIANTS = ("baseline", "candidate")
FLAGS = ["-swift-version", "6", "-O", "-whole-module-optimization"]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "NFODeclarationPreflight", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=int, default=100)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 1:
        parser.error("use a positive target-ms and an even pair count >= 2")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be new or empty")
    logs = output / "logs"
    logs.mkdir()
    manifest = {}
    state = {"status": "running", "tests": [], "differential": {}, "summaries": []}

    def save() -> None:
        for name, data in [("manifest.json", manifest), ("summary.json", state)]:
            (output / name).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")

    def append(name: str, data: dict) -> None:
        with (output / name).open("a") as handle:
            handle.write(json.dumps(data, separators=(",", ":"), ensure_ascii=False) + "\n")

    def run(command: list[str], label: str) -> str:
        print("COMMAND " + shlex.join(command), flush=True)
        started = time.monotonic()
        with (logs / (label + ".log")).open("w") as handle:
            result = subprocess.run(command, cwd=ROOT, stdout=handle,
                                    stderr=subprocess.STDOUT, text=True)
        append("commands.jsonl", {"label": label, "command": command,
               "exit_code": result.returncode, "seconds": time.monotonic() - started})
        text = (logs / (label + ".log")).read_text()
        if result.returncode:
            print(text[-25000:], flush=True)
            raise RuntimeError(f"{label} failed: {result.returncode}")
        return text

    def adapt(name: str, content: bytes) -> tuple[bytes, str | None]:
        if sys.platform != "linux":
            return content, None
        if name == PARSER:
            return content.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1), "FoundationXML import"
        if name == "MediaSidecarReader.swift":
            return content.replace(b"import Darwin\n", b"import Glibc\n", 1), "Darwin -> Glibc import"
        if name == "MediaSidecarTests.swift":
            return content.replace(
                b'appendingPathComponent("sidecar-" + UUID().uuidString)',
                b'appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)'
            ), "explicit directory hint on legacy fixture root"
        return content, None

    try:
        frozen = (HERE / "baseline" / PARSER).read_bytes()
        if blob(frozen) != BASELINE_BLOB:
            raise RuntimeError("frozen baseline parser does not match the recorded Git blob")
        manifest.update({
            "protocol": 1, "baseline_commit": BASELINE_COMMIT, "baseline_parser_blob": BASELINE_BLOB,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "revision").strip(),
            "working_tree": run(["git", "status", "--short"], "working-tree").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift-version").strip(),
            "python": platform.python_version(), "locale": run(["locale"], "locale").strip(),
            "flags": FLAGS, "pairs": args.pairs, "target_ms": args.target_ms,
            "linkage": "separate dynamic production module; driver compiled separately; no cross-module optimization",
            "method": "Fresh process per observation; 3 untimed warmups; AB/BA pair order alternates; identical baseline-calibrated iterations; all observations retained.",
            "scope": "Complete warmed in-memory NFOMetadataHints.parse plus identical result consumption. Excludes fixture creation, filesystem I/O, app startup and playback.",
            "runner_sha256": sha256(Path(__file__).read_bytes()),
            "driver_sha256": sha256((HERE / "Driver.swift").read_bytes()),
            "sources": {}, "test_inputs": {}, "binaries": {},
        })
        if sys.platform == "darwin":
            manifest["macos"] = run(["sw_vers"], "macos").strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode").strip()
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        else:
            manifest["cpu"] = run(["lscpu"], "cpu").strip()
        if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
            print("Kyoto unavailable on this isolated host; direct builds run serially in separate directories.", flush=True)

        shared = {name: (ROOT / "Sources/IlliquidCore/MediaLibrary" / name).read_bytes()
                  for name in SOURCES}
        test_bytes = {name: (ROOT / "Tests/IlliquidCoreTests" / name).read_bytes() for name in TESTS}
        packages = {}
        for variant in VARIANTS:
            package = output / "packages" / variant
            packages[variant] = package
            source_dir = package / "Sources/IlliquidCore"
            test_dir = package / "Tests/IlliquidCoreTests"
            source_dir.mkdir(parents=True)
            test_dir.mkdir(parents=True)
            (package / "Package.swift").write_text(PACKAGE)
            for name in SOURCES:
                original = frozen if variant == "baseline" and name == PARSER else shared[name]
                compiled, adaptation = adapt(name, original)
                (source_dir / name).write_bytes(compiled)
                manifest["sources"][variant + "/" + name] = {
                    "repository_path": "Sources/IlliquidCore/MediaLibrary/" + name,
                    "source_sha256": sha256(original), "compiled_sha256": sha256(compiled),
                    "adaptation": adaptation,
                }
            for name, original in test_bytes.items():
                compiled, adaptation = adapt(name, original)
                (test_dir / name).write_bytes(compiled)
                manifest["test_inputs"][name] = {
                    "source_sha256": sha256(original), "compiled_sha256": sha256(compiled),
                    "adaptation": adaptation,
                }
            save()
            for configuration in ("debug", "release"):
                label = f"tests-{variant}-{configuration}"
                text = run(["swift", "test", "--package-path", str(package),
                            "-c", configuration, "--no-parallel", "--jobs", "2"], label)
                counts = re.findall(r"Test run with (\d+) tests? passed", text)
                if not counts or int(counts[-1]) == 0 or "NFO declaration preflight" not in text:
                    raise RuntimeError(f"missing nonempty test receipt: {label}")
                state["tests"].append({"variant": variant, "configuration": configuration,
                                       "passed": True, "count": int(counts[-1]), "log": "logs/" + label + ".log"})
                print("TEST_PASS " + json.dumps(state["tests"][-1]), flush=True)
                save()

        executables = {}
        for variant in VARIANTS:
            work = output / "build" / variant
            work.mkdir(parents=True)
            extension = "dylib" if sys.platform == "darwin" else "so"
            library = work / f"libIlliquidCore.{extension}"
            run(["swiftc", *FLAGS, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                 "-emit-module-path", str(work / "IlliquidCore.swiftmodule"),
                 *(str(packages[variant] / "Sources/IlliquidCore" / name) for name in SOURCES),
                 "-o", str(library)], "compile-library-" + variant)
            executable = work / "nfo-benchmark"
            run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                 "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                 str(HERE / "Driver.swift"), "-o", str(executable)], "compile-driver-" + variant)
            executables[variant] = executable
            manifest["binaries"][variant] = {"library_sha256": sha256(library.read_bytes()),
                                              "driver_sha256": sha256(executable.read_bytes())}
            save()

        differentials = {}
        for variant in VARIANTS:
            text = run([str(executables[variant]), "--differential"], "differential-" + variant)
            value = json.loads(text)
            if value["count"] != len(value["cases"]) or value["count"] < 800:
                raise RuntimeError("incomplete differential corpus")
            if len({case["name"] for case in value["cases"]}) != value["count"]:
                raise RuntimeError("duplicate differential case names")
            differentials[variant] = value
            (output / f"differential-{variant}.json").write_text(json.dumps(value, ensure_ascii=False) + "\n")
            state["differential"][variant] = {"count": value["count"], "sha256": sha256(text.encode())}
        if differentials["baseline"] != differentials["candidate"]:
            raise RuntimeError("baseline/candidate differential result mismatch")
        state["differential"]["equal"] = True
        save()
        print("DIFFERENTIAL_PASS " + json.dumps(state["differential"]), flush=True)

        workloads = json.loads(run([str(executables["baseline"]), "--list"], "workloads"))
        other = json.loads(run([str(executables["candidate"]), "--list"], "candidate-workloads"))
        if workloads != other:
            raise RuntimeError("workload manifests differ")
        manifest["workloads"] = workloads
        save()
        if not args.tests_only:
            for workload in workloads:
                name = workload["name"]
                iterations = 1
                for trial in range(8):
                    row = json.loads(run([str(executables["baseline"]), name, str(iterations)],
                                         f"calibrate-{name}-{trial}"))
                    append("observations.jsonl", {"phase": "calibration", "variant": "baseline", "trial": trial, **row})
                    elapsed_ms = row["elapsed_ns"] / 1_000_000
                    if elapsed_ms >= args.target_ms / 2 or iterations >= 20_000_000:
                        break
                    iterations = min(20_000_000, max(iterations + 1,
                        math.ceil(iterations * args.target_ms / max(elapsed_ms, 0.000001))))
                samples = {variant: [] for variant in VARIANTS}
                ratios = []
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    paired = {}
                    for position, variant in enumerate(order):
                        row = json.loads(run([str(executables[variant]), name, str(iterations)],
                                             f"measure-{name}-{pair}-{variant}"))
                        if row["name"] != name or row["iterations"] != iterations or row["bytes"] != workload["bytes"]:
                            raise RuntimeError("observation fixture receipt mismatch")
                        append("observations.jsonl", {"phase": "measurement", "variant": variant,
                               "pair": pair, "order": position, **row})
                        paired[variant] = row
                        samples[variant].append(row["ns_per_parse"])
                    for field in ("checksum", "result"):
                        if paired["baseline"][field] != paired["candidate"][field]:
                            raise RuntimeError("observation output mismatch")
                    ratios.append(paired["candidate"]["ns_per_parse"] / paired["baseline"]["ns_per_parse"])
                before = statistics.median(samples["baseline"])
                after = statistics.median(samples["candidate"])
                summary = {
                    "name": name, "bytes": workload["bytes"], "iterations": iterations,
                    "pairs": args.pairs, "baseline_median_ns": before, "candidate_median_ns": after,
                    "reduction_percent": 100 * (1 - after / before),
                    "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                    "candidate_faster_pairs": sum(value < 1 for value in ratios),
                    "baseline_min_ns": min(samples["baseline"]), "baseline_max_ns": max(samples["baseline"]),
                    "candidate_min_ns": min(samples["candidate"]), "candidate_max_ns": max(samples["candidate"]),
                }
                state["summaries"].append(summary)
                save()
                print("BENCHMARK_SUMMARY " + json.dumps(summary), flush=True)
        state["status"] = "passed"
        save()
        print("QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        save()
        raise


if __name__ == "__main__":
    main()
