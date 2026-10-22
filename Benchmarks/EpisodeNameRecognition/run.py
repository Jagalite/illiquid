#!/usr/bin/env python3
"""Qualify episode-folder parsing with exact production Swift and a pinned baseline."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
TESTS = ["MediaNameRecognitionTests.swift", "EpisodeNameRecognitionRegressionTests.swift"]
SCENARIOS = [
    "named-episode-no-year", "named-episode-with-year", "bare-season-episode",
    "bare-parent-year-episode", "unclassified-bare-episode", "mixed-library", "movie-controls",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "EpisodeNameRecognitionQualification", targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(command: list[str], output: Path, label: str) -> str:
    with (output / "commands.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps({"label": label, "command": command}) + "\n")
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    (output / f"{label}.log").write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        print(result.stdout, flush=True)
        raise RuntimeError(f"{label} exited {result.returncode}; see {output / (label + '.log')}")
    return result.stdout


def environment(output: Path, reference: str) -> dict:
    reference_directory = HERE / ("baseline" if reference == "main" else "folder-reuse")
    reference_source = reference_directory / "MediaNameRecognition.swift"
    manifest = json.loads((reference_directory / "manifest.json").read_text())
    if sha256(reference_source) != manifest["sha256"]:
        raise RuntimeError("Pinned baseline failed its SHA-256 receipt")
    swift = shutil.which("swift")
    swiftc = shutil.which("swiftc")
    if not swift or not swiftc:
        raise RuntimeError("Swift 6.1+ must be installed and on PATH")
    result = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "processor": platform.processor(), "cpu_count": os.cpu_count(),
        "swift": swift, "swiftc": swiftc,
        "toolchain": run([swiftc, "--version"], output, "toolchain").strip(),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "baseline": manifest,
        "reference_name": reference,
        "reference_source": str(reference_source.relative_to(ROOT)),
        "source_sha256": {
            str(path.relative_to(ROOT)): sha256(path)
            for path in [SOURCE, reference_source, HERE / "Driver.swift", Path(__file__).resolve()]
        },
    }
    if platform.system() == "Darwin":
        result["hardware"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], output, "hardware").strip()
        result["os_version"] = run(["sw_vers"], output, "os-version").strip()
    return result


def test(args: argparse.Namespace, metadata: dict) -> None:
    original = ROOT / metadata["reference_source"] if args.implementation == "baseline" else SOURCE
    with tempfile.TemporaryDirectory(prefix="episode-recognition-tests-") as work:
        package = Path(work)
        (package / "Package.swift").write_text(PACKAGE, encoding="utf-8")
        sources = package / "Sources/IlliquidCore"
        tests = package / "Tests/IlliquidCoreTests"
        sources.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(original, sources / "MediaNameRecognition.swift")
        for name in TESTS:
            shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name, tests / name)
        command = [metadata["swift"], "test", "--package-path", str(package),
                   "--configuration", args.configuration, "--no-parallel"]
        text = run(command, args.output, "tests")
        print(text, end="", flush=True)
        write_json(args.output / "receipt.json", {
            "environment": metadata, "implementation": args.implementation,
            "configuration": args.configuration, "exit_code": 0,
            "compiled_source_sha256": sha256(original),
            "test_sha256": {name: sha256(tests / name) for name in TESTS},
            "source_adaptations": [],
        })


def benchmark(args: argparse.Namespace, metadata: dict) -> None:
    # Only type names differ in the benchmark's baseline copy. The original is
    # retained verbatim and checked above; the candidate is compiled in place.
    with tempfile.TemporaryDirectory(prefix="episode-recognition-benchmark-") as work:
        build = Path(work)
        reference_source = ROOT / metadata["reference_source"]
        renamed = re.sub(r"\bRecognizedMediaName\b", "BaselineRecognizedMediaName", reference_source.read_text())
        renamed = re.sub(r"\bMediaNameRecognition\b", "BaselineMediaNameRecognition", renamed)
        baseline_source = build / "Baseline.swift"
        baseline_source.write_text(renamed, encoding="utf-8")
        metadata["compiled_baseline_sha256"] = sha256(baseline_source)
        metadata["baseline_adaptation"] = "Rename the two top-level types only"
        executable = build / "recognition"
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library", "-j", "2"]
        metadata["compiler_flags"] = flags
        run([metadata["swiftc"], *flags, str(SOURCE), str(baseline_source),
             str(HERE / "Driver.swift"), "-o", str(executable)], args.output, "compile")
        differential = json.loads(run([str(executable), "--differential"], args.output, "differential"))
        if differential.get("ok") is not True:
            raise RuntimeError("Differential comparison did not pass")
        if args.command == "differential":
            write_json(args.output / "results.json", {
                "environment": metadata, "differential": differential,
            })
            print(json.dumps(differential, indent=2), flush=True)
            return
        observations = []
        for scenario in args.scenarios:
            for repeat in range(args.repeats):
                pair = []
                order = ["baseline", "candidate"] if repeat % 2 == 0 else ["candidate", "baseline"]
                for implementation in order:
                    label = f"{scenario}-{repeat:02d}-{implementation}"
                    value = json.loads(run([str(executable), "--benchmark", implementation, scenario,
                                            str(args.iterations), str(args.rounds)], args.output, label))
                    value["repeat"] = repeat
                    value["execution_order"] = order
                    pair.append(value)
                    observations.append(value)
                if pair[0]["checksum"] != pair[1]["checksum"]:
                    raise RuntimeError(f"Timed result checksum mismatch in {scenario}, pair {repeat}")
                print(f"Completed {scenario} pair {repeat + 1}/{args.repeats}", flush=True)
        summaries = {}
        rng = random.Random(20261017)
        for scenario in args.scenarios:
            values = {name: [] for name in ["baseline", "candidate"]}
            for observation in observations:
                if observation["scenario"] == scenario:
                    values[observation["implementation"]].append(statistics.median(
                        observation["nanoseconds_per_operation"]))
            ratios = [candidate / baseline for baseline, candidate in
                      zip(values["baseline"], values["candidate"])]
            bootstraps = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            summaries[scenario] = {
                "baseline_median_ns_per_file": statistics.median(values["baseline"]),
                "candidate_median_ns_per_file": statistics.median(values["candidate"]),
                "paired_median_candidate_over_baseline": statistics.median(ratios),
                "paired_median_reduction_percent": 100 * (1 - statistics.median(ratios)),
                "paired_ratio_bootstrap_95_percent_interval": [bootstraps[249], bootstraps[9749]],
                "pairs": len(ratios),
            }
        evidence = {"environment": metadata, "differential": differential,
                    "summary": summaries, "observations": observations,
                    "method": "Median of per-process medians; paired candidate/baseline ratios; balanced alternating order; all observations retained"}
        write_json(args.output / "results.json", evidence)
        print(json.dumps(summaries, indent=2), flush=True)


def positive(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    tests = subparsers.add_parser("test")
    tests.add_argument("--configuration", choices=["debug", "release"], default="debug")
    tests.add_argument("--implementation", choices=["baseline", "candidate"], default="candidate")
    differential = subparsers.add_parser("differential", help="Compare the full corpus without running timings")
    bench = subparsers.add_parser("benchmark")
    bench.add_argument("--repeats", type=positive, default=12)
    bench.add_argument("--iterations", type=positive, default=128,
                       help="Complete scans of the 64-path corpus per timed round")
    bench.add_argument("--rounds", type=positive, default=3)
    bench.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=SCENARIOS)
    for command in [tests, differential, bench]:
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--reference", choices=["main", "folder-reuse"], default="main")
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("--output must be empty; use a fresh directory for each run")
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = environment(args.output, args.reference)
    write_json(args.output / "environment.json", metadata)
    if args.command == "test":
        test(args, metadata)
    else:
        benchmark(args, metadata)


if __name__ == "__main__":
    main()
