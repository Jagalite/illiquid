#!/usr/bin/env python3
"""Exact-source, fresh-process qualification of media filename recognition."""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
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
SOURCE = Path("Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift")
BASE_REVISION = "68274d1b09dcc866296321a5a8858efc297c4f19"
WORKLOADS = ["dated-forward", "dated-reverse", "dated-invalid", "dated-unicode",
             "movies", "episodes", "ambiguous", "tags"]
VARIANTS = ("baseline", "candidate")
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MediaNameRecognitionQualification",
    products: [.library(name: "IlliquidCore", targets: ["IlliquidCore"])],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
    ]
)
'''


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path):
    return json.loads(path.read_text())


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def append_json(path: Path, value) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True, ensure_ascii=False) + "\n")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run_tool(command: list[str], output: Path, name: str, cwd: Path = ROOT) -> str:
    print(f"{name}", flush=True)
    started = time.perf_counter()
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    log = output / "logs" / f"{name}.log"
    log.write_text("COMMAND " + json.dumps(command) + "\n\nSTDOUT\n" + result.stdout
                   + "\nSTDERR\n" + result.stderr)
    append_json(output / "commands.jsonl", {
        "name": name, "command": command, "cwd": str(cwd),
        "elapsedSeconds": time.perf_counter() - started, "returncode": result.returncode,
        "log": str(log.relative_to(output)),
    })
    require(result.returncode == 0, f"{name} failed; see {log}")
    if name.startswith("tests-"):
        summaries = [line for line in (result.stdout + result.stderr).splitlines()
                     if "Test run with" in line or "tests passed" in line]
        print(f"PASS {name}" + (": " + summaries[-1].strip() if summaries else " (exit 0; complete log retained)"), flush=True)
    return result.stdout


def snapshot(args, output: Path) -> dict:
    frozen = HERE / "baseline" / "MediaNameRecognition.swift"
    manifest = read_json(HERE / "baseline" / "manifest.json")
    require(manifest["revision"] == BASE_REVISION, "Unexpected frozen baseline revision")
    require(manifest["sourcePath"] == str(SOURCE), "Unexpected frozen baseline path")
    require(sha256(frozen) == manifest["sha256"], "Frozen baseline SHA-256 mismatch")
    tests = sorted((ROOT / "Tests/IlliquidCoreTests").glob("MediaNameRecognition*Tests.swift"))
    require(bool(tests), "No actual media-name recognition tests found")
    inputs = [("baseline", frozen, "sources/baseline.swift"),
              ("candidate", args.candidate_source, "sources/candidate.swift"),
              ("harness", HERE / "Harness.swift", "sources/Harness.swift"),
              ("runner", Path(__file__).resolve(), "sources/run.py"),
              ("baselineManifest", HERE / "baseline/manifest.json", "sources/baseline-manifest.json")]
    inputs += [("test", test, f"sources/tests/{test.name}") for test in tests]
    files = []
    for role, source, relative in inputs:
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        files.append({"role": role, "origin": str(source), "path": relative,
                      "sha256": sha256(destination), "bytes": destination.stat().st_size})
    package = output / "sources/Package.swift"
    package.write_text(PACKAGE)
    files.append({"role": "generatedPackage", "path": "sources/Package.swift",
                  "sha256": sha256(package), "bytes": package.stat().st_size})
    sources = {"schemaVersion": 1, "baselineRevision": BASE_REVISION, "files": files}
    write_json(output / "sources.json", sources)
    return sources


def build_binaries(args, output: Path) -> dict[str, Path]:
    result = {}
    products = []
    require(platform.system() in ("Darwin", "Linux"), "This runner supports macOS and Linux")
    extension = "dylib" if platform.system() == "Darwin" else "so"
    for variant in VARIANTS:
        directory = output / "build" / variant
        directory.mkdir()
        binary = directory / "harness"
        library = directory / f"libIlliquidCore.{extension}"
        module = directory / "IlliquidCore.swiftmodule"
        module_cache = output / "build" / "module-cache" / variant
        module_cache.mkdir(parents=True, exist_ok=True)
        flags = [str(args.swiftc), "-O", "-whole-module-optimization", "-swift-version", "6",
                 "-warnings-as-errors", "-module-cache-path", str(module_cache)]
        run_tool(flags + ["-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                          "-emit-module-path", str(module), str(output / f"sources/{variant}.swift"),
                          "-o", str(library)], output, f"build-{variant}-library")
        # Match the production module boundary: the client imports IlliquidCore,
        # so the recognizer cannot specialize to benchmark fixtures through WMO.
        run_tool(flags + ["-parse-as-library", "-I", str(directory), "-L", str(directory),
                          "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(directory),
                          str(output / "sources/Harness.swift"), "-o", str(binary)],
                 output, f"build-{variant}-harness")
        for role, path in (("library", library), ("module", module), ("harness", binary)):
            products.append({"variant": variant, "role": role, "path": str(path.relative_to(output)),
                             "sha256": sha256(path), "bytes": path.stat().st_size})
        result[variant] = binary
    write_json(output / "build-products.json", {"schemaVersion": 1, "products": products})
    return result


def component_tests(args, output: Path) -> None:
    results = []
    for variant in VARIANTS:
        package = output / "build" / f"package-{variant}"
        source_dir = package / "Sources/IlliquidCore"
        test_dir = package / "Tests/IlliquidCoreTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        shutil.copyfile(output / "sources/Package.swift", package / "Package.swift")
        shutil.copyfile(output / f"sources/{variant}.swift", source_dir / "MediaNameRecognition.swift")
        for test in sorted((output / "sources/tests").glob("*.swift")):
            shutil.copyfile(test, test_dir / test.name)
        for configuration in ("debug", "release"):
            name = f"tests-{variant}-{configuration}"
            command = [str(args.swiftc.parent / "swift"), "test", "--package-path", str(package),
                       "--scratch-path", str(output / "build" / f"package-build-{variant}"),
                       "--cache-path", str(output / "build/package-cache"),
                       "--config-path", str(output / "build/package-config"),
                       "--configuration", configuration, "--enable-swift-testing", "--disable-xctest",
                       "-Xswiftc", "-warnings-as-errors"]
            run_tool(command, output, name)
            results.append({"variant": variant, "configuration": configuration,
                            "returncode": 0, "log": f"logs/{name}.log"})
            write_json(output / "test-results.json", results)


def corpus(binary: Path, output: Path, variant: str, exhaustive: bool) -> dict:
    command = [str(binary), "corpus"] + (["--exhaustive-dates"] if exhaustive else [])
    name = f"corpus-{variant}"
    print(name + (" (all valid dates and invalid boundaries)" if exhaustive else ""), flush=True)
    destination = output / "differential" / f"{variant}.jsonl.gz"
    stderr_path = output / "logs" / f"{name}.log"
    digest = hashlib.sha256()
    count = 0
    started = time.perf_counter()
    with stderr_path.open("wb") as stderr, gzip.open(destination, "wb") as zipped:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=stderr)
        assert process.stdout is not None
        try:
            for line in process.stdout:
                json.loads(line)  # Require complete, valid serialized records.
                digest.update(line)
                zipped.write(line)
                count += 1
        except BaseException:
            process.kill()
            process.wait()
            raise
        finally:
            process.stdout.close()
        code = process.wait()
    append_json(output / "commands.jsonl", {
        "name": name, "command": command, "cwd": str(ROOT),
        "elapsedSeconds": time.perf_counter() - started, "returncode": code,
        "log": str(stderr_path.relative_to(output)), "stdout": str(destination.relative_to(output)),
    })
    require(code == 0, f"{name} failed; see {stderr_path}")
    require(count > 0, f"{name} produced no corpus records")
    return {"variant": variant, "records": count, "canonicalSHA256": digest.hexdigest(),
            "path": str(destination.relative_to(output)), "sha256": sha256(destination)}


def compare_corpora(output: Path, receipts: list[dict]) -> int:
    count = 0
    baseline, candidate = receipts
    with gzip.open(output / baseline["path"], "rb") as left, gzip.open(output / candidate["path"], "rb") as right:
        for line in left:
            other = right.readline()
            require(line == other,
                    f"Corpus differs at record {count + 1}: baseline={line[:500]!r}, candidate={other[:500]!r}")
            count += 1
        require(right.read(1) == b"", "Candidate corpus has extra records")
    require(count == baseline["records"] == candidate["records"], "Corpus record count mismatch")
    return count


def differential(args, output: Path, binaries: dict[str, Path]) -> None:
    receipts = [corpus(binaries[variant], output, variant, args.exhaustive_dates) for variant in VARIANTS]
    count = compare_corpora(output, receipts)
    write_json(output / "differential/report.json", {
        "schemaVersion": 1, "exhaustiveDates": args.exhaustive_dates, "records": count,
        "byteExactEqual": True, "receipts": receipts,
    })
    print(f"Differential: {count} complete results match byte for byte", flush=True)


def benchmark(args, output: Path, binaries: dict[str, Path]) -> None:
    process_index = 0
    for pair in range(args.pairs):
        offset = pair % len(WORKLOADS)
        order = WORKLOADS[offset:] + WORKLOADS[:offset]
        variants = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
        for workload in order:
            for position, variant in enumerate(variants):
                name = f"timing-{process_index:03d}-{workload}-{variant}"
                text = run_tool([str(binaries[variant]), "benchmark", workload,
                                 str(args.iterations), str(args.warmup)], output, name)
                record = json.loads(text)
                require(record["workload"] == workload and record["iterations"] == args.iterations
                        and record["warmupCount"] == args.warmup, "Harness identity mismatch")
                record.update({"variant": variant, "pair": pair, "position": position,
                               "processIndex": process_index})
                append_json(output / "measurements.jsonl", record)
                process_index += 1


def summarize(output: Path, environment: dict) -> dict:
    records = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
    settings = environment["settings"]
    pairs = settings["pairs"]
    require(len(records) == len(WORKLOADS) * pairs * 2, "Incomplete timing matrix")
    expected_order = []
    for pair in range(pairs):
        offset = pair % len(WORKLOADS)
        for workload in WORKLOADS[offset:] + WORKLOADS[:offset]:
            for position, variant in enumerate(VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))):
                expected_order.append((pair, workload, position, variant))
    lookup = {}
    for index, (record, expected) in enumerate(zip(records, expected_order)):
        require((record["pair"], record["workload"], record["position"], record["variant"]) == expected,
                f"Unexpected process order at {index}")
        require(record["processIndex"] == index, "Process indexes are not consecutive")
        require(record["iterations"] == settings["iterations"] and record["warmupCount"] == settings["warmup"],
                "Measurement settings changed within cohort")
        require(record["wallNanoseconds"] > 0 and record["cpuNanoseconds"] > 0, "Nonpositive duration")
        lookup[(record["workload"], record["pair"], record["variant"])] = record
    groups = {}
    for workload in WORKLOADS:
        selected = [record for record in records if record["workload"] == workload]
        require(len({record["checksum"] for record in selected}) == 1, f"Full-result checksum mismatch: {workload}")
        require(len({record["warmupChecksum"] for record in selected}) == 1, f"Warmup mismatch: {workload}")
        group = {"pairs": pairs, "iterationsPerProcess": settings["iterations"],
                 "checksum": selected[0]["checksum"]}
        for metric in ("wallNanoseconds", "cpuNanoseconds"):
            values = {variant: [record[metric] / record["iterations"] for record in selected
                                if record["variant"] == variant] for variant in VARIANTS}
            ratios = [lookup[(workload, pair, "candidate")][metric]
                      / lookup[(workload, pair, "baseline")][metric] for pair in range(pairs)]
            group[metric] = {
                "perOperation": {variant: {"median": statistics.median(samples), "min": min(samples), "max": max(samples)}
                                 for variant, samples in values.items()},
                "pairedCandidateOverBaseline": ratios,
                "medianPairedRatio": statistics.median(ratios),
                "medianPairedReductionPercent": 100 * (1 - statistics.median(ratios)),
            }
        groups[workload] = group
    return {"schemaVersion": 1, "processes": len(records), "balancedVariantOrder": pairs % 2 == 0,
            "scope": "Optimized full recognizer calls plus append into a pre-reserved result array; all-field serialization and validation outside timing.",
            "workloads": groups}


def verify(output: Path) -> dict:
    environment = read_json(output / "environment.json")
    sources = read_json(output / "sources.json")
    require(sources["baselineRevision"] == BASE_REVISION, "Baseline revision changed")
    for source in sources["files"]:
        path = output / source["path"]
        require(path.stat().st_size == source["bytes"] and sha256(path) == source["sha256"],
                f"Source snapshot changed: {path}")
    build_products = read_json(output / "build-products.json")["products"]
    products_verified = 0
    for product in build_products:
        path = output / product["path"]
        # Build directories may be removed from archived evidence; their original
        # hashes remain receipts, not claims that removed bytes were rechecked.
        if path.exists():
            require(path.stat().st_size == product["bytes"] and sha256(path) == product["sha256"],
                    f"Build product changed: {path}")
            products_verified += 1
    report = read_json(output / "differential/report.json")
    for receipt in report["receipts"]:
        path = output / receipt["path"]
        require(sha256(path) == receipt["sha256"], f"Corpus artifact changed: {path}")
        with gzip.open(path, "rb") as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        require(digest.hexdigest() == receipt["canonicalSHA256"], "Canonical corpus hash changed")
    count = compare_corpora(output, report["receipts"])
    commands = [json.loads(line) for line in (output / "commands.jsonl").read_text().splitlines()]
    require(all(command["returncode"] == 0 for command in commands), "A recorded command failed")
    mode = environment["settings"]["mode"]
    tests = None
    if mode in ("all", "test"):
        tests = read_json(output / "test-results.json")
        require({(test["variant"], test["configuration"]) for test in tests}
                == {(variant, configuration) for variant in VARIANTS for configuration in ("debug", "release")},
                "Incomplete component test matrix")
        require(len(tests) == 4 and all(test["returncode"] == 0 for test in tests), "Failed component test receipt")
    if mode in ("all", "benchmark"):
        expected = summarize(output, environment)
        if (output / "summary.json").exists():
            require(read_json(output / "summary.json") == expected, "Summary differs from raw measurements")
        else:
            write_json(output / "summary.json", expected)
    result = {"schemaVersion": 1, "success": True, "mode": mode, "sourceSnapshotsVerified": len(sources["files"]),
              "byteExactDifferentialRecords": count, "componentTestRuns": len(tests or []),
              "buildProductHashReceipts": len(build_products), "presentBuildProductsVerified": products_verified,
              "timingMatrixVerified": mode in ("all", "benchmark")}
    write_json(output / "verification.json", result)
    return result


def print_summary(output: Path, result: dict) -> None:
    print(f"Verified {result['byteExactDifferentialRecords']} byte-exact recognizer results; "
          f"{result['componentTestRuns']} component test runs passed.", flush=True)
    if result["timingMatrixVerified"]:
        summary = read_json(output / "summary.json")
        print(f"Timing cohort: {summary['processes']} fresh processes; "
              f"balanced variant order={summary['balancedVariantOrder']}", flush=True)
        print("Workload | baseline ns/op | candidate ns/op | median paired candidate/baseline", flush=True)
        for workload, group in summary["workloads"].items():
            wall = group["wallNanoseconds"]
            print(f"{workload} | {wall['perOperation']['baseline']['median']:.1f} | "
                  f"{wall['perOperation']['candidate']['median']:.1f} | {wall['medianPairedRatio']:.4f}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("all", "test", "benchmark", "verify"), default="all")
    parser.add_argument("--swiftc", type=Path, default=Path(shutil.which("swiftc") or "swiftc"))
    parser.add_argument("--candidate-source", type=Path, default=ROOT / SOURCE)
    parser.add_argument("--pairs", type=int, default=6, help="Positive even count for balanced timing order")
    parser.add_argument("--iterations", type=int, default=4000, help="Recognizer calls per workload and process")
    parser.add_argument("--warmup", type=int, default=128)
    parser.add_argument("--exhaustive-dates", action="store_true",
                        help="Also compare every valid calendar date 1900...2099 and nearby invalid bounds, in both field orders")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if args.mode == "verify":
        result = verify(output)
        print_summary(output, result)
        print(json.dumps(result, indent=2))
        return
    require(args.pairs > 0 and args.iterations > 0 and args.warmup > 0, "Pairs, iterations, and warmup must be positive")
    require(args.mode == "test" or args.pairs % 2 == 0, "Measured modes require a positive even --pairs count")
    require(not output.exists() or not any(output.iterdir()), "Output directory must be new or empty")
    args.swiftc = args.swiftc.expanduser().absolute()
    require(args.swiftc.is_file(), f"Compiler is unavailable: {args.swiftc}; supply --swiftc")
    args.candidate_source = args.candidate_source.expanduser().resolve()
    for directory in (output, output / "logs", output / "build", output / "sources", output / "differential"):
        directory.mkdir(parents=True, exist_ok=True)
    snapshot(args, output)
    compiler_version = run_tool([str(args.swiftc), "--version"], output, "compiler-version").strip()
    git_revision = run_tool(["git", "rev-parse", "HEAD"], output, "git-revision").strip()
    git_status = run_tool(["git", "status", "--porcelain"], output, "git-status").splitlines()
    environment = {"schemaVersion": 1, "timestampUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
                   "platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor(),
                   "logicalCPUs": os.cpu_count(), "python": sys.version, "compilerVersion": compiler_version,
                   "swiftc": str(args.swiftc), "gitRevision": git_revision, "gitStatus": git_status,
                   "settings": {"mode": args.mode, "pairs": args.pairs, "iterations": args.iterations,
                                "warmup": args.warmup, "exhaustiveDates": args.exhaustive_dates,
                                "workloads": WORKLOADS, "optimization": "Separate IlliquidCore library and importing harness, each -O -whole-module-optimization -swift-version 6 -warnings-as-errors"}}
    write_json(output / "environment.json", environment)
    if args.mode in ("all", "test"):
        component_tests(args, output)
    binaries = build_binaries(args, output)
    differential(args, output, binaries)
    if args.mode in ("all", "benchmark"):
        benchmark(args, output, binaries)
    result = verify(output)
    print_summary(output, result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
