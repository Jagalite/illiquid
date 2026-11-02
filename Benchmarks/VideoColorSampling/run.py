#!/usr/bin/env python3
"""Qualify and time exact production VideoFrameColorSampler sources on macOS."""
import argparse
import hashlib
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CORE = "Sources/IlliquidCore/Player/VideoColorSample.swift"
NATIVE = [
    "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift",
    "Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift",
]
CHANGED = NATIVE[-1]
TEST = "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerTests.swift"
VARIANTS = ("baseline", "candidate")
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "VideoColorSamplingRegressions",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidCore", "IlliquidNativePlayback"]),
    ]
)
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def append_json(path, value):
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=30)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Native macOS CoreVideo is required; no platform adapters are used.")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be even and between 2 and 20 for balanced AB/BA order.")
    if not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 1000:
        parser.error("--target-ms must be between 10 and 1000.")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty.")
    output.mkdir(parents=True, exist_ok=True)
    for child in ("sources", "build", "module-cache", "logs", "driver"):
        (output / child).mkdir()
    environment = os.environ.copy()
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    commands, rows, tests = [], [], []
    manifest = {
        "baseline_commit": BASELINE,
        "pairs": args.pairs,
        "minimum_calibration_ms": args.target_ms,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "environment": {key: environment.get(key) for key in (
            "DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING", "LANG", "LC_ALL")},
        "source_sha256": {},
        "tests": tests,
    }
    summary = {"status": "running", "tests": tests, "cases": []}
    write_json(output / "manifest.json", manifest)
    write_json(output / "summary.json", summary)

    def run(command, *, timeout=600, log_name=None, check=True):
        command = [str(part) for part in command]
        started = time.monotonic()
        process = subprocess.run(command, cwd=ROOT, env=environment,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 timeout=timeout)
        log_name = log_name or f"logs/{len(commands):04d}.log"
        (output / log_name).write_bytes(process.stdout)
        receipt = {
            "index": len(commands), "command": command, "cwd": str(ROOT),
            "exit": process.returncode, "seconds": time.monotonic() - started,
            "log": log_name,
        }
        commands.append(receipt)
        append_json(output / "commands.jsonl", receipt)
        if check and process.returncode:
            raise RuntimeError(f"Command failed ({process.returncode}); see {log_name}:\n"
                               + process.stdout.decode(errors="replace")[-12000:])
        return process

    def read(command):
        return run(command).stdout.decode().strip()

    try:
        manifest.update(
            candidate_commit=read(["git", "rev-parse", "HEAD"]),
            working_tree=read(["git", "status", "--porcelain"]),
            compiler=read(["xcrun", "swiftc", "--version"]),
            sdk=read(["xcrun", "--sdk", "macosx", "--show-sdk-path"]),
            xcode=read(["xcodebuild", "-version"]),
            os_version=read(["sw_vers"]),
            hardware=read(["sysctl", "hw.model", "hw.ncpu", "hw.memsize",
                           "machdep.cpu.brand_string"]),
        )
        swiftc = read(["xcrun", "--find", "swiftc"])
        source_paths = {variant: {} for variant in VARIANTS}
        for path in [CORE, *NATIVE]:
            baseline = run(["git", "show", f"{BASELINE}:{path}"]).stdout
            candidate = (ROOT / path).read_bytes()
            if path != CHANGED and baseline != candidate:
                raise RuntimeError(f"Supporting production source differs from baseline: {path}")
            for variant, content in (("baseline", baseline), ("candidate", candidate)):
                target = "IlliquidCore" if path == CORE else "IlliquidNativePlayback"
                destination = output / "sources" / variant / "Sources" / target / Path(path).name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(content)
                source_paths[variant][path] = destination
                manifest["source_sha256"][f"{variant}/{path}"] = digest(content)
        test_bytes = (ROOT / TEST).read_bytes()
        manifest["source_sha256"][TEST] = digest(test_bytes)
        for name in ("run.py", "Harness.swift"):
            content = (HERE / name).read_bytes()
            (output / "driver" / name).write_bytes(content)
            manifest["source_sha256"][f"driver/{name}"] = digest(content)
        manifest["fixture_package_sha256"] = digest(PACKAGE.encode())
        write_json(output / "manifest.json", manifest)

        # The same current tests exercise both the frozen and proposed sources.
        # These isolated packages deliberately have no player/FFmpeg dependencies.
        for variant in VARIANTS:
            package = output / "sources" / variant
            (package / "Package.swift").write_text(PACKAGE)
            test_path = package / "Tests" / "IlliquidNativePlaybackTests" / Path(TEST).name
            test_path.parent.mkdir(parents=True, exist_ok=True)
            test_path.write_bytes(test_bytes)
            for configuration in ("debug", "release"):
                print(f"Testing {variant} / {configuration}", flush=True)
                log_name = f"test-{variant}-{configuration}.log"
                result = run(
                    ["xcrun", "swift", "test", "--package-path", package,
                     "--configuration", configuration, "--jobs", "2", "--no-parallel"],
                    timeout=900, log_name=log_name, check=False,
                )
                counts = re.findall(r"Test run with (\d+) tests?.*passed",
                                    result.stdout.decode(errors="replace"))
                count = int(counts[-1]) if counts else 0
                tests.append({"variant": variant, "configuration": configuration,
                              "exit": result.returncode, "passed_tests": count, "log": log_name})
                write_json(output / "manifest.json", manifest)
                write_json(output / "summary.json", summary)
                if result.returncode or count == 0:
                    raise RuntimeError(f"Regression run failed or ran no tests: {log_name}\n"
                                       + result.stdout.decode(errors="replace")[-12000:])

        print("Compiling exact-source optimized benchmark executables", flush=True)
        flags = [
            "-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
            "-sdk", manifest["sdk"], "-target", f"{platform.machine()}-apple-macosx26.0",
            "-module-cache-path", output / "module-cache",
        ]
        core_dir = output / "build" / "core"
        core_dir.mkdir()
        core_library = core_dir / "libIlliquidCore.dylib"
        run([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
             "-emit-module-path", core_dir / "IlliquidCore.swiftmodule",
             source_paths["baseline"][CORE], "-o", core_library])
        binaries = {}
        for variant in VARIANTS:
            binary = output / "build" / variant
            run([swiftc, *flags, "-I", core_dir, "-L", core_dir, "-lIlliquidCore",
                 "-Xlinker", "-rpath", "-Xlinker", core_dir,
                 *[source_paths[variant][path] for path in NATIVE],
                 output / "driver" / "Harness.swift", "-o", binary])
            binaries[variant] = binary
        manifest["compiler_flags"] = [str(flag) for flag in flags]
        manifest["binary_sha256"] = {
            **{variant: digest(binary.read_bytes()) for variant, binary in binaries.items()},
            "shared_core": digest(core_library.read_bytes()),
        }
        write_json(output / "manifest.json", manifest)

        listed = {variant: json.loads(run([binary, "--list"]).stdout)
                  for variant, binary in binaries.items()}
        if listed["baseline"] != listed["candidate"]:
            raise RuntimeError("Baseline and candidate workload declarations differ.")
        cases = listed["baseline"]["cases"]
        if len(cases) != 15 or len(set(cases)) != len(cases):
            raise RuntimeError("Expected exactly 15 distinct native workload cases.")
        manifest["cases"] = cases
        verification = {
            variant: json.loads(run([binary, "--verify"]).stdout)
            for variant, binary in binaries.items()
        }
        write_json(output / "verification.json", verification)
        if verification["baseline"] != verification["candidate"]:
            raise RuntimeError("Exact grid-bit or temporal output parity failed.")
        summary["verification"] = {
            "exact_baseline_candidate_parity": True,
            "sha256": digest(canonical(verification["baseline"])),
            "artifact": "verification.json",
        }
        print("Exact output and temporal parity passed", flush=True)
        write_json(output / "summary.json", summary)

        def measure(variant, case, iterations):
            result = json.loads(run([binaries[variant], "--benchmark", "--case", case,
                                     "--iterations", iterations], timeout=120).stdout)
            if (result["case"] != case or result["iterations"] != iterations
                    or result["elapsed_ns"] <= 0 or "checksum" not in result):
                raise RuntimeError(f"Invalid benchmark result: {result}")
            return result

        # Calibration is excluded from the reported timings. Both implementations
        # receive identical work, chosen so the faster one exceeds the target.
        iterations_by_case, expected_checksums = {}, {}
        for case in cases:
            iterations = 64
            for attempt in range(12):
                calibration = {variant: measure(variant, case, iterations) for variant in VARIANTS}
                for variant, result in calibration.items():
                    append_json(output / "calibration.jsonl",
                                {**result, "variant": variant, "attempt": attempt})
                if calibration["baseline"]["checksum"] != calibration["candidate"]["checksum"]:
                    raise RuntimeError(f"Calibration checksum differs for {case}.")
                shortest = min(row["elapsed_ns"] for row in calibration.values())
                if shortest >= args.target_ms * 1e6:
                    break
                proposed = math.ceil(iterations * args.target_ms * 1e6 / shortest * 1.2)
                iterations = max(iterations + 1, proposed)
                if iterations > 2_000_000:
                    raise RuntimeError(f"Calibration iteration cap reached: {case}")
            else:
                raise RuntimeError(f"Calibration did not converge: {case}")
            iterations_by_case[case] = iterations
            expected_checksums[case] = calibration["baseline"]["checksum"]
        manifest["iterations_by_case"] = iterations_by_case
        write_json(output / "manifest.json", manifest)

        schedule = []
        for pair in range(args.pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            rotated = cases[pair % len(cases):] + cases[:pair % len(cases)]
            for case in rotated:
                for variant in order:
                    schedule.append({"pair": pair, "case": case, "variant": variant})
        write_json(output / "schedule.json", schedule)
        for entry in schedule:
            result = measure(entry["variant"], entry["case"], iterations_by_case[entry["case"]])
            if result["checksum"] != expected_checksums[entry["case"]]:
                raise RuntimeError(f"Measured output differs from preflight: {entry}")
            row = {**result, **entry, "ordinal": len(rows)}
            rows.append(row)
            append_json(output / "observations.jsonl", row)
            if len(rows) % (len(cases) * 2) == 0:
                print(f"Completed pair {entry['pair'] + 1}/{args.pairs}", flush=True)
        persisted = [json.loads(line) for line in (output / "observations.jsonl").read_text().splitlines()]
        if persisted != rows or [{key: row[key] for key in ("pair", "case", "variant")}
                                for row in rows] != schedule:
            raise RuntimeError("Persisted measurements differ from the intended schedule.")

        for case in cases:
            subset = [row for row in rows if row["case"] == case]
            values = {variant: [row["elapsed_ns"] / row["iterations"]
                               for row in subset if row["variant"] == variant]
                      for variant in VARIANTS}
            ratios = [candidate / baseline for baseline, candidate in
                      zip(values["baseline"], values["candidate"])]
            result = {
                "case": case, "iterations": iterations_by_case[case], "pairs": args.pairs,
                **{variant + "_ns_per_sample": {
                    "median": statistics.median(samples), "min": min(samples), "max": max(samples)}
                   for variant, samples in values.items()},
                "paired_candidate_over_baseline": ratios,
                "median_paired_reduction_percent": statistics.median([(1 - ratio) * 100 for ratio in ratios]),
                "improved_pairs": sum(ratio < 1 for ratio in ratios),
                "median_saved_ns_per_sample": statistics.median([
                    baseline - candidate for baseline, candidate in
                    zip(values["baseline"], values["candidate"])]),
            }
            summary["cases"].append(result)
        # Check that qualification did not mutate the measured sources or binaries.
        for variant in VARIANTS:
            for path, staged in source_paths[variant].items():
                if digest(staged.read_bytes()) != manifest["source_sha256"][f"{variant}/{path}"]:
                    raise RuntimeError(f"Staged production source changed: {variant}/{path}")
            if digest(binaries[variant].read_bytes()) != manifest["binary_sha256"][variant]:
                raise RuntimeError(f"Benchmark executable changed: {variant}")
        if digest(core_library.read_bytes()) != manifest["binary_sha256"]["shared_core"]:
            raise RuntimeError("Shared production core library changed.")
        summary.update(
            status="passed", observations=len(rows), source_integrity_passed=True,
            all_case_medians_improved=all(case["median_paired_reduction_percent"] > 0
                                         for case in summary["cases"]),
            measured_scope="Elapsed wall time for synchronous sample(), including lock, metadata, "
                           "96-point sampling, allocation and checksum; fixture setup excluded.",
            limitations="Warm native component microbenchmark, not end-to-end playback, GPU, "
                        "energy or UI qualification. Production sampling is throttled to 4 Hz.",
        )
        for case in summary["cases"]:
            baseline = case["baseline_ns_per_sample"]["median"] / 1000
            candidate = case["candidate_ns_per_sample"]["median"] / 1000
            print(f"{case['case']}: {baseline:.3f} -> {candidate:.3f} us/sample; "
                  f"{case['median_paired_reduction_percent']:.1f}% paired reduction "
                  f"({case['improved_pairs']}/{args.pairs} pairs faster)", flush=True)
    except Exception as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        write_json(output / "manifest.json", manifest)
        write_json(output / "summary.json", summary)
        print("VIDEO_COLOR_SAMPLING_OBSERVATIONS_JSON "
              + json.dumps(rows, sort_keys=True, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
