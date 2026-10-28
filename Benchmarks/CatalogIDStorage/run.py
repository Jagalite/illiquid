#!/usr/bin/env python3
"""Compare catalog-ID merging with retained-output and paired timing probes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCES = [
    "Sources/IlliquidCore/MediaLibrary/MediaMetadataHints.swift",
    "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift",
    "Sources/IlliquidCore/MediaLibrary/PlexMatchHints.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/MediaNameRecognitionTests.swift",
    "Tests/IlliquidCoreTests/PlexMatchHintsRegressionTests.swift",
    "Tests/IlliquidCoreTests/CatalogIDStorageTests.swift",
]
FLAGS = ["-swift-version", "6", "-O", "-whole-module-optimization"]
SEED = 20261028
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "CatalogIDStorageQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
'''


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")


def bootstrap_median_interval(values: list[float]) -> list[float]:
    """Descriptive paired bootstrap, not a universal performance guarantee."""
    rng = random.Random(SEED)
    estimates = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(5000))
    return [estimates[124], estimates[4874]]


def comparison(pairs: list[dict], field: str) -> dict:
    before = [pair["baseline"][field] for pair in pairs]
    after = [pair["candidate"][field] for pair in pairs]
    differences = [b - a for b, a in zip(before, after)]
    result = {
        "baseline_median": statistics.median(before),
        "candidate_median": statistics.median(after),
        "baseline_range": [min(before), max(before)],
        "candidate_range": [min(after), max(after)],
        "paired_savings_median": statistics.median(differences),
        "paired_savings_bootstrap_95_percent_interval": bootstrap_median_interval(differences),
        "candidate_lower_pairs": sum(a < b for a, b in zip(after, before)),
        "pairs": len(pairs),
    }
    if all(value > 0 for value in before):
        ratios = [a / b for a, b in zip(after, before)]
        result.update(
            paired_ratio_median=statistics.median(ratios),
            paired_ratio_range=[min(ratios), max(ratios)],
            paired_ratio_bootstrap_95_percent_interval=bootstrap_median_interval(ratios),
            median_reduction_percent=100 * (1 - statistics.median(after) / statistics.median(before)),
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=int, default=250)
    parser.add_argument("--max-iterations", type=int, default=100_000)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or args.max_iterations <= 0:
        parser.error("pairs must be even and >= 2; target-ms and max-iterations must be positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    swift, compiler, cc = (shutil.which(name) for name in ("swift", "swiftc", "cc"))
    if not swift or not compiler or not cc:
        parser.error("swift, swiftc (Swift 6.1+ from the same toolchain), and cc are required")

    environment = os.environ.copy()
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    commands: list[dict] = []

    def command(argv, *, log=None, cwd=ROOT, timeout=600) -> str:
        argv = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=cwd, env=environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        commands.append(dict(argv=argv, cwd=str(cwd), returncode=result.returncode,
                             elapsed_seconds=time.monotonic() - started))
        write_json(output / "commands.json", commands)
        if log:
            (output / log).write_text(result.stdout)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n{result.stdout[-12000:]}")
        return result.stdout

    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    entries = {entry["path"]: entry for entry in baseline["files"]}
    if set(entries) != set(SOURCES) or len(baseline["files"]) != len(SOURCES):
        raise ValueError("Baseline manifest must identify exactly the three production sources")
    for path, entry in entries.items():
        data = (HERE / "baseline" / entry["file"]).read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if blob != entry["git_blob_sha"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Frozen baseline mismatch: " + path)

    inputs = [*SOURCES, *TESTS, *(str((HERE / name).relative_to(ROOT)) for name in
                                  ("Driver.swift", "MemoryProbe.c", "MemoryProbe.h", "run.py"))]
    manifest = dict(
        started_utc=datetime.now(timezone.utc).isoformat(),
        platform=platform.platform(), machine=platform.machine(),
        swift=command([swift, "--version"]).strip(),
        compiler=command([compiler, "--version"]).strip(),
        c_compiler=command([cc, "--version"]).strip(),
        candidate_commit=command(["git", "rev-parse", "HEAD"]).strip(),
        working_tree=command(["git", "status", "--porcelain"]).splitlines(),
        baseline=baseline, source_sha256={path: digest(ROOT / path) for path in inputs},
        flags=FLAGS, pairs=args.pairs, target_cpu_ms=args.target_ms, mode=args.mode,
        hashing="SWIFT_DETERMINISTIC_HASHING=1", shuffle_seed=SEED,
        method="separate optimized production libraries; fresh process per sample; serial balanced AB/BA pairs; variant-specific CPU calibration and normalized time per batch; complete batch creation, consumption, and release; retained live-heap deltas measured separately; no overhead subtraction",
        uncertainty="95% paired nonparametric bootstrap intervals for sample medians; describe this cohort only; performance is reported rather than a noisy CI gate",
        github={name: os.environ[name] for name in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT") if name in os.environ},
    )
    if platform.system() == "Darwin":
        manifest["hardware"] = command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        manifest["os_version"] = command(["sw_vers"]).strip()
    elif Path("/proc/cpuinfo").is_file():
        manifest["hardware"] = next((line.split(":", 1)[1].strip()
                                     for line in Path("/proc/cpuinfo").read_text().splitlines()
                                     if line.startswith("model name")), platform.machine())
    write_json(output / "manifest.json", manifest)

    for path in inputs:
        destination = output / "inputs" / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, destination)
        if digest(destination) != manifest["source_sha256"][path]:
            raise RuntimeError("Source changed while taking snapshot: " + path)
    for variant in ("baseline", "candidate"):
        folder = output / "sources" / variant
        folder.mkdir(parents=True)
        for path in SOURCES:
            source = HERE / "baseline" / entries[path]["file"] if variant == "baseline" else output / "inputs" / path
            shutil.copyfile(source, folder / Path(path).name)

    test_results, binaries = [], {}
    with tempfile.TemporaryDirectory(prefix="illiquid-catalog-id-storage-") as temporary:
        work = Path(temporary)
        (work / "tmp").mkdir()
        environment["TMPDIR"] = str(work / "tmp")
        environment["CLANG_MODULE_CACHE_PATH"] = str(work / "module-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(work / "module-cache")
        probe = work / "probe"
        probe.mkdir()
        for name in ("MemoryProbe.c", "MemoryProbe.h"):
            shutil.copyfile(output / "inputs" / HERE.relative_to(ROOT) / name, probe / name)
        (probe / "module.modulemap").write_text('module CMemoryProbe { header "MemoryProbe.h" export * }\n')
        if args.mode != "tests":
            command([cc, "-O2", "-c", probe / "MemoryProbe.c", "-o", probe / "MemoryProbe.o"], log="memory-probe-build.log")
        for variant in ("baseline", "candidate"):
            sources = sorted((output / "sources" / variant).glob("*.swift"))
            if args.mode != "benchmark":
                package = work / (variant + "-tests")
                (package / "Sources/IlliquidCore").mkdir(parents=True)
                (package / "Tests/IlliquidCoreTests").mkdir(parents=True)
                (package / "Package.swift").write_text(PACKAGE)
                for source in sources:
                    shutil.copyfile(source, package / "Sources/IlliquidCore" / source.name)
                for test in TESTS:
                    shutil.copyfile(output / "inputs" / test, package / "Tests/IlliquidCoreTests" / Path(test).name)
                for configuration in ("debug", "release"):
                    print(f"Testing {variant} {configuration}", flush=True)
                    argv = [swift, "test", "--package-path", package, "--configuration", configuration,
                            "--no-parallel", "--jobs", "2", "-Xswiftc", "-warnings-as-errors",
                            "--cache-path", work / "package-cache", "--config-path", work / "package-config",
                            "--security-path", work / "package-security"]
                    if platform.system() == "Linux":
                        argv.append("--use-integrated-swift-driver")
                    log = f"{variant}-{configuration}-tests.log"
                    result = command(argv, log=log)
                    counts = re.findall(r"Test run with (\d+) tests? passed", result)
                    if not counts or int(counts[-1]) <= 0:
                        raise RuntimeError("Swift Testing did not report a nonempty passing run: " + log)
                    test_results.append(dict(variant=variant, configuration=configuration,
                                             passed=int(counts[-1]), log=log, sha256=digest(output / log)))
                    write_json(output / "tests.json", test_results)
                    print(f"TEST {variant} {configuration}: {counts[-1]} passed", flush=True)
                shutil.rmtree(package / ".build")
            if args.mode == "tests":
                continue
            build = work / (variant + "-benchmark")
            build.mkdir()
            extension = "dylib" if platform.system() == "Darwin" else "so"
            library = build / f"libIlliquidCore.{extension}"
            command([compiler, *FLAGS, "-parse-as-library", "-emit-library", "-emit-module",
                     "-module-name", "IlliquidCore", "-emit-module-path", build / "IlliquidCore.swiftmodule",
                     "-module-cache-path", work / "module-cache", *sources, "-o", library],
                    log=f"{variant}-library-build.log")
            executable = build / "catalog-id-storage"
            command([compiler, *FLAGS, "-I", build, "-I", probe,
                     "-L", build, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", build,
                     "-module-cache-path", work / "module-cache",
                     output / "inputs" / HERE.relative_to(ROOT) / "Driver.swift", probe / "MemoryProbe.o",
                     "-o", executable], log=f"{variant}-driver-build.log")
            binaries[variant] = executable
            manifest.setdefault("binaries", {})[variant] = dict(library_sha256=digest(library), executable_sha256=digest(executable))
            write_json(output / "manifest.json", manifest)

        if args.mode == "tests":
            write_json(output / "completion.json", dict(status="passed", test_configurations=len(test_results)))
            return

        parity = {variant: json.loads(command([executable, "--parity"], log=f"{variant}-parity.json"))
                  for variant, executable in binaries.items()}
        if parity["baseline"] != parity["candidate"]:
            raise RuntimeError("Canonical edge cases, whole-cohort fingerprints, or correctness checks differ")
        encoded = json.dumps(parity["baseline"], sort_keys=True, ensure_ascii=False).encode()
        write_json(output / "parity.json", dict(status="passed", sha256=hashlib.sha256(encoded).hexdigest(),
                                               bytes=len(encoded), comparison="complete canonical edge cases, whole-cohort fingerprints, and correctness records"))
        cases = json.loads(command([binaries["baseline"], "--list"]))
        if cases != json.loads(command([binaries["candidate"], "--list"])) or not cases:
            raise RuntimeError("Benchmark case lists differ or are empty")
        names = [case["name"] for case in cases]
        if len(set(names)) != len(names):
            raise RuntimeError("Duplicate case names")
        random.Random(SEED).shuffle(cases)
        write_json(output / "cases.json", cases)
        summaries, calibration = [], []

        def measure(variant, name, iterations):
            row = json.loads(command([binaries[variant], "--case", name, "--iterations", iterations, "--warmup", 2]))
            if (row["case"] != name or row["iterations"] != iterations or row["outputCount"] <= 0
                    or row["elapsedNanoseconds"] <= 0 or row["cpuNanoseconds"] <= 0):
                raise RuntimeError("Invalid timing observation: " + json.dumps(row))
            row["wall_ns_per_batch"] = row["elapsedNanoseconds"] / iterations
            row["cpu_ns_per_batch"] = row["cpuNanoseconds"] / iterations
            return row

        for case_index, case in enumerate(cases):
            name = case["name"]
            print("Measuring " + name, flush=True)
            memory_pairs = []
            for pair in range(args.pairs):
                rows = {}
                order = ("baseline", "candidate") if (pair + case_index) % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = json.loads(command([binaries[variant], "--memory", name]))
                    if (row["case"] != name or row["outputCount"] != case["outputCount"]
                            or row["retainedBytes"] != row["heapRetainedBytes"] - row["heapBeforeBytes"]
                            or row["releasedRetainedBytes"] != row["heapAfterReleaseBytes"] - row["heapBeforeBytes"]):
                        raise RuntimeError("Invalid retained-output observation: " + json.dumps(row))
                    row.update(variant=variant, pair=pair, order=position)
                    rows[variant] = row
                    append_json(output / "memory.jsonl", row)
                for field in ("outputCount", "idCount", "resultChecksum", "memoryAllocator"):
                    if rows["baseline"][field] != rows["candidate"][field]:
                        raise RuntimeError(f"Memory output mismatch for {name}: {field}")
                memory_pairs.append(rows)

            iterations_by_variant, probes = {}, {}
            for variant in ("baseline", "candidate"):
                pilot = measure(variant, name, 1)
                iterations = max(1, min(args.max_iterations,
                    math.ceil(1.1 * args.target_ms * 1_000_000 / pilot["cpu_ns_per_batch"])))
                confirmation = measure(variant, name, iterations)
                if confirmation["cpuNanoseconds"] < args.target_ms * 1_000_000:
                    iterations = max(iterations, min(args.max_iterations,
                        math.ceil(1.1 * args.target_ms * 1_000_000 / confirmation["cpu_ns_per_batch"])))
                iterations_by_variant[variant] = iterations
                probes[variant] = dict(pilot=pilot, confirmation=confirmation, measured_iterations=iterations)
            calibration.append(dict(case=name, variants=probes))
            write_json(output / "calibration.json", calibration)
            timing_pairs = []
            for pair in range(args.pairs):
                rows = {}
                order = ("baseline", "candidate") if (pair + case_index) % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = measure(variant, name, iterations_by_variant[variant])
                    if row["outputCount"] != case["outputCount"]:
                        raise RuntimeError("Output count changed during timing")
                    row.update(variant=variant, pair=pair, order=position)
                    rows[variant] = row
                    append_json(output / "timing.jsonl", row)
                for field in ("outputCount", "idCount", "resultChecksum"):
                    if rows["baseline"][field] != rows["candidate"][field]:
                        raise RuntimeError(f"Timed output mismatch for {name}: {field}")
                if (rows["baseline"]["consumedCount"] * rows["candidate"]["iterations"]
                        != rows["candidate"]["consumedCount"] * rows["baseline"]["iterations"]):
                    raise RuntimeError("Per-batch output consumption differs during timing")
                if rows["baseline"]["resultChecksum"] != memory_pairs[0]["baseline"]["resultChecksum"]:
                    raise RuntimeError("Timed and retained-output probes produced different results")
                timing_pairs.append(rows)
            summary = dict(case=case, retained_bytes=comparison(memory_pairs, "retainedBytes"),
                           cpu_ns_per_batch=comparison(timing_pairs, "cpu_ns_per_batch"),
                           wall_ns_per_batch=comparison(timing_pairs, "wall_ns_per_batch"),
                           after_release_bytes=comparison(memory_pairs, "releasedRetainedBytes"))
            summaries.append(summary)
            write_json(output / "summary.json", summaries)
            print("SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)

        write_json(output / "completion.json", dict(status="passed", cases=len(cases), pairs=args.pairs,
                                                    memory_observations=len(cases) * args.pairs * 2,
                                                    timing_observations=len(cases) * args.pairs * 2,
                                                    test_configurations=len(test_results)))


if __name__ == "__main__":
    main()
