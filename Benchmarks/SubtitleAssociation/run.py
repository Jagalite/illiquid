#!/usr/bin/env python3
"""Compare exact production external-subtitle association in fresh processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCES = [
    "Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/ExternalSubtitleMatcherTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleMatcherEmptyTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleAssociationTests.swift",
]
FLAGS = ["-swift-version", "6", "-O", "-whole-module-optimization"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleAssociationQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark"), default="all")
    parser.add_argument("--pairs", type=positive_int, default=8)
    parser.add_argument("--target-ms", type=positive_int, default=100)
    parser.add_argument("--max-iterations", type=positive_int, default=2_000_000)
    parser.add_argument("--cases", help="Comma-separated timed cases; parity still checks all fixtures")
    parser.add_argument("--candidate-matcher", type=Path, help="Alternate candidate matcher for isolated experiments")
    args = parser.parse_args()
    if args.pairs % 2:
        parser.error("--pairs must be even for balanced AB/BA order")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be empty")
    compiler, swift = shutil.which("swiftc"), shutil.which("swift")
    if not compiler or not swift:
        parser.error("swiftc and swift must be on PATH from the same toolchain")
    # Capture every compilation input once. Hash and compile only these copies,
    # so edits to the checkout cannot change one variant halfway through a run.
    inputs = output / "inputs"
    for path in [*TESTS, "Benchmarks/SubtitleAssociation/Driver.swift",
                 "Benchmarks/SubtitleAssociation/run.py",
                 "Benchmarks/SubtitleAssociation/baseline/manifest.json"]:
        destination = inputs / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((ROOT / path).read_bytes())
    baseline_manifest = inputs / "Benchmarks/SubtitleAssociation/baseline/manifest.json"
    baseline = json.loads(baseline_manifest.read_text())
    for variant in ("baseline", "candidate"):
        folder = output / "sources" / variant
        folder.mkdir(parents=True)
        for source in SOURCES:
            original = (HERE / "baseline" / baseline["sources"][source]["file"]
                        if variant == "baseline" else ROOT / source)
            if variant == "candidate" and source == SOURCES[0] and args.candidate_matcher:
                original = args.candidate_matcher.resolve()
            (folder / Path(source).name).write_bytes(original.read_bytes())
    for source in SOURCES:
        entry = baseline["sources"][source]
        data = (output / "sources/baseline" / Path(source).name).read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if blob != entry["git_blob"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise RuntimeError(f"Frozen baseline Git blob mismatch: {source}")

    def command(argv: list[str], *, log: str | None = None,
                cwd: Path | None = None, env: dict | None = None) -> str:
        started = time.monotonic()
        process = subprocess.run(argv, cwd=cwd or ROOT, env=env, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with (output / "commands.jsonl").open("a") as receipt:
            receipt.write(json.dumps(dict(argv=argv, cwd=str(cwd or ROOT),
                                         returncode=process.returncode,
                                         elapsed_seconds=time.monotonic() - started)) + "\n")
        if log:
            (output / log).write_text(process.stdout)
        if process.returncode:
            raise RuntimeError(f"Command failed ({process.returncode}): {argv}\n{process.stdout}")
        return process.stdout

    manifest = dict(
        platform=platform.platform(), machine=platform.machine(),
        compiler=command([compiler, "--version"]).strip(),
        swift=command([swift, "--version"]).strip(),
        compiler_sha256=sha256(Path(compiler).resolve()),
        candidate_matcher_override=str(args.candidate_matcher) if args.candidate_matcher else None,
        revision=command(["git", "rev-parse", "HEAD"], cwd=ROOT).strip(),
        working_tree=command(["git", "status", "--porcelain"], cwd=ROOT).splitlines(),
        baseline=baseline, baseline_manifest_sha256=sha256(baseline_manifest),
        baseline_sha256={path: sha256(output / "sources/baseline" / Path(path).name) for path in SOURCES},
        flags=FLAGS, pairs=args.pairs, target_ms=args.target_ms, mode=args.mode, requested_cases=args.cases,
        method="separate optimized production libraries; fresh process per variant/case/pair; balanced AB/BA; same iterations per pair; serial timing; baseline CPU calibration; full independent oracle and baseline parity before timing; result-count consumption included; no control subtraction",
        source_sha256={
            **{path: sha256(output / "sources/candidate" / Path(path).name) for path in SOURCES},
            **{path: sha256(inputs / path) for path in TESTS},
        },
        harness_sha256={name: sha256(inputs / "Benchmarks/SubtitleAssociation" / name)
                       for name in ("Driver.swift", "run.py")},
        input_snapshot="All source, driver, and test compilation inputs are staged before hashing; builds use only staged bytes.",
        github={name: os.environ[name] for name in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT") if name in os.environ},
    )
    if platform.system() == "Darwin":
        manifest["hardware"] = command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        manifest["os_version"] = command(["sw_vers"]).strip()
    else:
        cpuinfo = Path("/proc/cpuinfo").read_text()
        manifest["hardware"] = next((line.split(":", 1)[1].strip() for line in cpuinfo.splitlines()
                                     if line.startswith("model name")), platform.machine())
    write_json(output / "manifest.json", manifest)
    print("MANIFEST " + json.dumps(manifest), flush=True)

    with tempfile.TemporaryDirectory(prefix="illiquid-subtitle-association-") as temporary:
        work = Path(temporary)
        environment = os.environ.copy()
        (work / "tmp").mkdir()
        environment["TMPDIR"] = str(work / "tmp")
        environment["CLANG_MODULE_CACHE_PATH"] = str(work / "module-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(work / "module-cache")
        executables, build_hashes = {}, {}
        for variant in ("baseline", "candidate"):
            sources = sorted((output / "sources" / variant).glob("*.swift"))
            if args.mode in ("all", "tests"):
                package = work / (variant + "-tests")
                (package / "Sources/IlliquidCore").mkdir(parents=True)
                (package / "Tests/IlliquidCoreTests").mkdir(parents=True)
                (package / "Package.swift").write_text(PACKAGE)
                for source in sources:
                    shutil.copyfile(source, package / "Sources/IlliquidCore" / source.name)
                for test in TESTS:
                    shutil.copyfile(inputs / test, package / "Tests/IlliquidCoreTests" / Path(test).name)
                for configuration in ("debug", "release"):
                    print(f"Testing {variant} {configuration}", flush=True)
                    argv = [swift, "test", "--package-path", str(package), "--configuration", configuration,
                            "--no-parallel", "--jobs", "2", "--cache-path", str(work / "package-cache"),
                            "--config-path", str(work / "package-config"), "--security-path", str(work / "package-security")]
                    if platform.system() == "Linux":
                        argv.append("--use-integrated-swift-driver")
                    log = f"{variant}-{configuration}-tests.txt"
                    result = command(argv, log=log, env=environment)
                    for line in result.splitlines():
                        if "Test run with" in line:
                            print(f"TEST {variant} {configuration}: {line}", flush=True)
                    shutil.rmtree(package / ".build")
            if args.mode in ("all", "benchmark"):
                build = work / (variant + "-benchmark")
                build.mkdir()
                extension = "dylib" if platform.system() == "Darwin" else "so"
                library = build / f"libIlliquidCore.{extension}"
                command([compiler, *FLAGS, "-parse-as-library", "-emit-library", "-emit-module",
                         "-module-name", "IlliquidCore", "-emit-module-path", str(build / "IlliquidCore.swiftmodule"),
                         "-module-cache-path", str(work / "module-cache"), *(str(source) for source in sources), "-o", str(library)],
                        log=f"{variant}-library-build.txt", env=environment)
                executable = build / "associate"
                command([compiler, *FLAGS, "-parse-as-library", "-I", str(build), "-L", str(build),
                         "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(build),
                         "-module-cache-path", str(work / "module-cache"),
                         str(inputs / "Benchmarks/SubtitleAssociation/Driver.swift"),
                         "-o", str(executable)], log=f"{variant}-driver-build.txt", env=environment)
                executables[variant] = executable
                build_hashes[variant] = dict(library_sha256=sha256(library),
                                             executable_sha256=sha256(executable))
                write_json(output / "build-products.json", build_hashes)

        print("BUILD_PRODUCTS " + json.dumps(build_hashes), flush=True)
        if args.mode == "tests":
            write_json(output / "result.json", {"status": "passed", "configurations": 4})
            return

        verification = {}
        for variant in ("baseline", "candidate"):
            verification[variant] = json.loads(command([str(executables[variant]), "--verify"],
                                                       log=f"{variant}-verification.json", env=environment))
        if verification["baseline"] != verification["candidate"]:
            raise RuntimeError("Full association outputs differ")
        verify_bytes = json.dumps(verification["baseline"], sort_keys=True, ensure_ascii=False).encode()
        parity = dict(status="passed", record_count=verification["baseline"]["recordCount"],
                      sha256=hashlib.sha256(verify_bytes).hexdigest(),
                      output_shape="every exact media URL key and ordered subtitle URL array; independent expected associations checked for every record")
        write_json(output / "parity.json", parity)
        print("PARITY " + json.dumps(parity), flush=True)
        cases = json.loads(command([str(executables["baseline"]), "--list-cases"], env=environment))
        candidate_cases = json.loads(command([str(executables["candidate"]), "--list-cases"], env=environment))
        if cases != candidate_cases or not isinstance(cases, list) or not all(isinstance(x, str) for x in cases):
            raise RuntimeError("Case lists differ or have an invalid shape")
        if len(cases) != len(set(cases)):
            raise RuntimeError("Duplicate case names")
        if args.cases:
            selected = args.cases.split(",")
            if len(selected) != len(set(selected)) or any(case not in cases for case in selected):
                raise RuntimeError(f"Unknown or duplicate --cases selection: {selected}")
            cases = selected
        write_json(output / "cases.json", cases)
        summaries, pilots = [], []

        def measure(variant: str, case: str, iterations: int) -> dict:
            argv = [str(executables[variant]), "--case", case, "--iterations", str(iterations), "--warmup", "4"]
            row = json.loads(command(argv, env=environment))
            if row["caseName"] != case or row["checksum"] != row["expectedChecksum"] or row["count"] != iterations:
                raise RuntimeError(f"Invalid benchmark output: {row}")
            if row["nsPerLookup"] <= 0 or row["cpuNsPerLookup"] <= 0:
                raise RuntimeError("Nonpositive timing")
            return row

        for case_index, case in enumerate(cases):
            pilot = measure("baseline", case, 32)
            iterations = max(1, min(args.max_iterations,
                             math.ceil(args.target_ms * 1_000_000 / pilot["cpuNsPerLookup"])))
            pilots.append(dict(case=case, result=pilot, measured_iterations=iterations))
            write_json(output / "calibration.json", pilots)
            print("CALIBRATION " + json.dumps(pilots[-1]), flush=True)
            paired = []
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if (pair + case_index) % 2 == 0 else ("candidate", "baseline")
                results = {}
                for order_index, variant in enumerate(order):
                    row = measure(variant, case, iterations)
                    row.update(variant=variant, case_id=case, pair=pair, order=order_index)
                    results[variant] = row
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, ensure_ascii=False) + "\n")
                    print("MEASUREMENT " + json.dumps(row), flush=True)
                for field in ("checksum", "expectedChecksum", "count", "preflightChecksum", "verifiedQueries"):
                    if results["baseline"][field] != results["candidate"][field]:
                        raise RuntimeError(f"Paired outputs disagree for {case}: {field}")
                paired.append(results)
            summary = dict(case_id=case, iterations=iterations, pairs=args.pairs)
            for clock, value in (("", "nsPerLookup"), ("cpu_", "cpuNsPerLookup")):
                before = [pair["baseline"][value] for pair in paired]
                after = [pair["candidate"][value] for pair in paired]
                ratios = [a / b for a, b in zip(after, before)]
                b, a = statistics.median(before), statistics.median(after)
                summary.update({
                    f"baseline_{clock}median_ns": b, f"candidate_{clock}median_ns": a,
                    f"{clock}reduction_percent": 100 * (1 - a / b),
                    f"paired_{clock}ratio_median": statistics.median(ratios),
                    f"paired_{clock}ratio_min": min(ratios), f"paired_{clock}ratio_max": max(ratios),
                    f"faster_{clock}pairs": sum(a < b for a, b in zip(after, before)),
                    f"baseline_{clock}range_ns": [min(before), max(before)],
                    f"candidate_{clock}range_ns": [min(after), max(after)],
                })
            summaries.append(summary)
            write_json(output / "summary.json", summaries)
            print("SUMMARY " + json.dumps(summary), flush=True)
        result = dict(status="passed", cases=len(cases), pairs=args.pairs,
                      measured_records=len(cases) * args.pairs * 2, test_configurations=4 if args.mode == "all" else 0)
        write_json(output / "result.json", result)
        print("RESULT " + json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
