#!/usr/bin/env python3
"""Measure common timestamp parsing through complete subtitle conversion.

The same driver is compiled against each separately optimized module, without
cross-module optimization. Fixtures, full UTF-8 output checks, and warmup are
outside timing; parsing, escaping, output construction, and result consumption
are inside. Run timings serially, without other benchmarks or compilations.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import re
from datetime import datetime, timezone
from pathlib import Path

from TimestampCases import generate_cases


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
VARIANTS = ("baseline", "candidate")
MASK = (1 << 64) - 1
TESTS = (
    "ExternalTextSubtitleConverterTests.swift",
    "ExternalSubtitleEscapingTests.swift",
    "ExternalSubtitleTimestampTests.swift",
)
# Selected before native measurement: ordinary fixed-width cases, payload/size
# variants, and fallback/error controls. Verify still checks every driver case.
TIMED_CASES = (
    "srt-1-plain", "srt-100-plain", "srt-2000-plain", "srt-10000-plain",
    "srt-2000-multilingual", "srt-2000-escaped",
    "vtt-100-plain", "vtt-2000-plain", "vtt-10000-plain",
    "vtt-2000-multilingual", "vtt-short-2000",
    "srt-legacy-2000", "srt-long-hours-2000", "vtt-long-hours-2000",
    "srt-empty", "vtt-missing-signature", "srt-no-valid-cues",
)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args: list[str], log: Path, output: Path) -> str:
    env = dict(os.environ)
    env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
    result = subprocess.run(args, text=True, capture_output=True, env=env, cwd=ROOT)
    log.write_text(json.dumps(args) + "\n" + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): see {log}\n{result.stderr[-4000:]}")
    return result.stdout


def host_metadata() -> dict:
    details = {"logical_cpus": os.cpu_count(), "cpu_model": platform.processor(),
               "environment": {key: os.environ.get(key) for key in
                               ("DEVELOPER_DIR", "SDKROOT", "LANG", "LC_ALL", "SWIFT_DETERMINISTIC_HASHING")}}
    if platform.system() == "Darwin":
        for key, args in (
            ("cpu_model", ["sysctl", "-n", "machdep.cpu.brand_string"]),
            ("os_version", ["sw_vers"]),
            ("sdk_version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        ):
            result = subprocess.run(args, text=True, capture_output=True)
            details[key] = result.stdout.strip() if result.returncode == 0 else result.stderr.strip()
    elif Path("/proc/cpuinfo").is_file():
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                details["cpu_model"] = line.split(":", 1)[1].strip()
                break
    return details


def build(args: argparse.Namespace, output: Path) -> tuple[dict[str, Path], dict]:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline = (HERE / "baseline/ExternalTextSubtitleConverter.swift").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
    if sha(baseline) != pinned["sha256"] or blob != pinned["git_blob"]:
        raise ValueError("Frozen baseline differs from its source manifest")
    selected = shutil.which(args.swiftc) or args.swiftc
    compiler = os.path.abspath(selected)
    version = command([compiler, "--version"], output / "compiler.log", output).strip()
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
             "-module-cache-path", str(output / "module-cache")]
    if platform.system() == "Darwin":
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "host": host_metadata(),
        "python": platform.python_version(), "compiler": version,
        "compiler_path": compiler, "compiler_sha256": sha(Path(compiler).read_bytes()),
        "flags": flags, "runner_sha256": sha(Path(__file__).read_bytes()),
        "driver_sha256": sha((HERE / "Driver.swift").read_bytes()),
        "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "baseline": pinned, "variants": {},
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "working_tree": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
        "timestamp_driver_sha256": sha((HERE / "TimestampParity.swift").read_bytes()),
        "timestamp_cases_generator_sha256": sha((HERE / "TimestampCases.py").read_bytes()),
    }
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    shutil.copyfile(HERE / "Driver.swift", output / "Driver.swift")
    shutil.copyfile(HERE / "TimestampParity.swift", output / "TimestampParity.swift")
    shutil.copyfile(HERE / "TimestampCases.py", output / "TimestampCases.py")
    binaries = {}
    for variant in VARIANTS:
        folder = output / variant
        folder.mkdir()
        original = HERE / "baseline/ExternalTextSubtitleConverter.swift" if variant == "baseline" else SOURCE
        source = folder / "ExternalTextSubtitleConverter.swift"
        shutil.copyfile(original, source)
        extension = "dylib" if platform.system() == "Darwin" else "so"
        library = folder / f"libIlliquidNativePlayback.{extension}"
        module = folder / "IlliquidNativePlayback.swiftmodule"
        module_command = [compiler, *flags, "-parse-as-library", "-emit-library", "-emit-module",
                          "-enable-testing", "-module-name", "IlliquidNativePlayback",
                          "-emit-module-path", str(module), str(source), "-o", str(library)]
        command(module_command, folder / "build-module.log", output)
        binary = folder / "converter-benchmark"
        driver_command = [compiler, *flags, "-parse-as-library", "-I", str(folder), "-L", str(folder),
                          "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                          str(output / "Driver.swift"), "-o", str(binary)]
        command(driver_command, folder / "build-driver.log", output)
        parity_binary = folder / "timestamp-parity"
        parity_command = [*driver_command[:-3], str(output / "TimestampParity.swift"),
                          "-o", str(parity_binary)]
        command(parity_command, folder / "build-timestamp-parity.log", output)
        manifest["variants"][variant] = {
            "source_sha256": sha(source.read_bytes()), "source_path": str(original.relative_to(ROOT)),
            "module_sha256": sha(module.read_bytes()), "library_sha256": sha(library.read_bytes()),
            "binary_sha256": sha(binary.read_bytes()), "module_command": module_command,
            "driver_command": driver_command,
            "timestamp_parity_sha256": sha(parity_binary.read_bytes()),
            "timestamp_parity_command": parity_command,
        }
        binaries[variant] = binary
    write_json(output / "manifest.json", manifest)
    return binaries, manifest


def test_sources(args: argparse.Namespace, output: Path) -> None:
    """Compile identical real regression suites against both complete sources."""
    swift = str(Path(shutil.which(args.swiftc) or args.swiftc).absolute().parent / "swift")
    records = []
    for variant in VARIANTS:
        package = output / "tests" / variant
        sources = package / "Sources/IlliquidNativePlayback"
        tests = package / "Tests/IlliquidNativePlaybackTests"
        sources.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(output / variant / SOURCE.name, sources / SOURCE.name)
        for name in TESTS:
            shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / name, tests / name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleTimestampRegressions", targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
        for configuration in ("debug", "release"):
            print(f"Testing {variant} ({configuration})", flush=True)
            test_command = [swift, "test", "--package-path", str(package),
                            "--cache-path", str(output / "swiftpm-cache"),
                            "--config-path", str(output / "swiftpm-config"),
                            "--security-path", str(output / "swiftpm-security"),
                            "--disable-sandbox", "--jobs", "2", "-c", configuration,
                            "--disable-xctest", "--enable-swift-testing", "--no-parallel",
                            "-Xswiftc", "-warnings-as-errors"]
            if platform.system() == "Linux":
                test_command += ["--use-integrated-swift-driver"]
            env = dict(os.environ)
            env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
            env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
            completed = subprocess.run(test_command, cwd=ROOT, env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            log = output / f"tests-{variant}-{configuration}.log"
            log.write_text(json.dumps(test_command) + "\n" + completed.stdout)
            counts = re.findall(r"Test run with (\d+) tests?[^\n]*passed", completed.stdout)
            if completed.returncode or not counts or int(counts[-1]) == 0:
                raise RuntimeError(f"Tests did not pass with nonzero execution: {log}\n{completed.stdout[-4000:]}")
            records.append({"variant": variant, "configuration": configuration,
                            "passed_tests": int(counts[-1]), "log_sha256": sha(log.read_bytes()),
                            "source_sha256": sha((sources / SOURCE.name).read_bytes()),
                            "tests": {name: sha((tests / name).read_bytes()) for name in TESTS}})
            write_json(output / "tests.json", records)
    if len({record["passed_tests"] for record in records}) != 1:
        raise RuntimeError("Regression test execution counts differ between sources/configurations")


def verify_timestamps(output: Path) -> None:
    cases = generate_cases()
    identifiers = [item["id"] for item in cases]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("Duplicate timestamp case identifier")
    path = output / "timestamp-cases.json"
    write_json(path, cases)
    expected = None
    receipts = {}
    for variant in VARIANTS:
        raw = command([str(output / variant / "timestamp-parity"), str(path)],
                      output / f"timestamp-parity-{variant}.log", output)
        records = json.loads(raw)
        if [row["id"] for row in records] != identifiers:
            raise ValueError("Timestamp driver did not execute the complete ordered corpus")
        for row in records:
            if "output" in row:
                base64.b64decode(row["output"], validate=True)
            elif row.get("error") not in ("missingWebVTTSignature", "noValidCues.srt", "noValidCues.webVTT"):
                raise ValueError("Unknown timestamp error receipt")
        if expected is not None and records != expected:
            differing = [a["id"] for a, b in zip(expected, records) if a != b]
            raise ValueError(f"Timestamp output/error mismatch: {differing[:10]}")
        expected = records
        compressed = output / f"timestamp-parity-{variant}.json.gz"
        compressed.write_bytes(gzip.compress(raw.encode(), mtime=0))
        receipts[variant] = {"sha256": sha(compressed.read_bytes()), "cases": len(records)}
    write_json(output / "timestamp-verification.json", {
        "cases": len(cases), "golden_cases": sum("expected_error" in c or "expected_dialogue" in c for c in cases),
        "exact_utf8_and_errors_match": True, "corpus_sha256": sha(path.read_bytes()),
        "receipts": receipts,
    })
    print(f"PASS exact timestamp output/errors and golden expectations: {len(cases)} cases", flush=True)


def verify(binaries: dict[str, Path], output: Path) -> dict[str, dict]:
    records = {}
    for variant, binary in binaries.items():
        raw = command([str(binary), "verify"], output / f"verify-{variant}.log", output)
        (output / f"verification-{variant}.json.gz").write_bytes(gzip.compress(raw.encode(), mtime=0))
        decoded = json.loads(raw)
        records[variant] = {row["case"]: row for row in decoded}
        if len(records[variant]) != len(decoded):
            raise ValueError("Duplicate verification case")
    if records["baseline"].keys() != records["candidate"].keys():
        raise ValueError("Baseline and candidate case lists differ")
    checked = {}
    for name, baseline in records["baseline"].items():
        candidate = records["candidate"][name]
        # Decode explicitly: Swift String equality permits canonical equivalence.
        for key in ("input_base64", "output_base64"):
            left, right = baseline[key], candidate[key]
            if (None if left is None else base64.b64decode(left, validate=True)) != (
                    None if right is None else base64.b64decode(right, validate=True)):
                raise ValueError(f"UTF-8 byte mismatch for {name}: {key}")
        if baseline != candidate:
            raise ValueError(f"Verification metadata or exact error differs for {name}")
        row = {key: value for key, value in candidate.items() if not key.endswith("_base64")}
        row["input_sha256"] = sha(base64.b64decode(candidate["input_base64"]))
        row["output_sha256"] = None if candidate["output_base64"] is None else sha(
            base64.b64decode(candidate["output_base64"]))
        checked[name] = row
    write_json(output / "verification.json", checked)
    print(f"PASS exact UTF-8 output/error equality: {len(checked)} cases", flush=True)
    return checked


def validate_sample(row: dict, expected: dict, operations: int) -> None:
    for key in ("case", "format", "cues", "input_bytes", "input_fnv1a", "timed",
                "output_bytes", "output_fnv1a", "error"):
        if row[key] != expected[key]:
            raise ValueError(f"Invalid timing receipt for {expected['case']}: {key}")
    checksum = (operations * int(expected["token"]) + 131 * operations * (operations - 1) // 2) & MASK
    if row["operations"] != operations or int(row["checksum"]) != checksum:
        raise ValueError(f"Wrong operation count or checksum: {expected['case']}")
    if row["elapsed_ns"] <= 0 or row["cpu_ns"] <= 0:
        raise ValueError("Invalid duration")


def summarize(output: Path) -> list[dict]:
    config = json.loads((output / "benchmark.json").read_text())
    verified = json.loads((output / "verification.json").read_text())
    rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
    cases, rounds = config["cases"], config["rounds"]
    if len(rows) != len(cases) * rounds * 2:
        raise ValueError("Incomplete measurement cohort")
    expected_order = []
    for round_index in range(rounds):
        order = VARIANTS if round_index % 2 == 0 else VARIANTS[::-1]
        # Reverse case traversal as well; each case retains adjacent AB/BA pairs.
        traversal = cases if round_index % 2 == 0 else cases[::-1]
        expected_order.extend((round_index, name, variant, position)
                              for name in traversal for position, variant in enumerate(order))
    for index, (row, identity) in enumerate(zip(rows, expected_order)):
        if (row["round"], row["case"], row["variant"], row["pair_position"]) != identity or row["sequence"] != index:
            raise ValueError("Duplicate, missing, or incorrectly ordered measurement")
        validate_sample(row, verified[row["case"]], config["iterations"][row["case"]])
    summaries = []
    for name in cases:
        selected = [row for row in rows if row["case"] == name]
        summary = {"case": name, "cues": verified[name]["cues"], "input_bytes": verified[name]["input_bytes"],
                   "operations_per_sample": config["iterations"][name], "pairs": rounds}
        for metric in ("elapsed_ns", "cpu_ns"):
            values = {variant: [row[metric] / row["operations"] for row in selected if row["variant"] == variant]
                      for variant in VARIANTS}
            ratios = []
            for round_index in range(rounds):
                pair = {row["variant"]: row for row in selected if row["round"] == round_index}
                ratios.append(pair["candidate"][metric] / pair["baseline"][metric])
            summary[metric] = {
                variant: {"median_per_operation": statistics.median(samples),
                          "min_per_operation": min(samples), "max_per_operation": max(samples)}
                for variant, samples in values.items()
            }
            summary[metric].update({"paired_candidate_over_baseline": ratios,
                                   "median_paired_ratio": statistics.median(ratios),
                                   "median_paired_change_percent": (statistics.median(ratios) - 1) * 100})
        summaries.append(summary)
    write_json(output / "summary.json", summaries)
    write_json(output / "sample-quality.json", {
        "observations": len(rows), "none_discarded": True,
        "minimum_elapsed_ns": min(row["elapsed_ns"] for row in rows),
        "minimum_cpu_ns": min(row["cpu_ns"] for row in rows),
        "below_target_elapsed_samples": sum(row["elapsed_ns"] < config["target_ms"] * 1_000_000 for row in rows),
        "below_target_cpu_samples": sum(row["cpu_ns"] < config["target_ms"] * 1_000_000 for row in rows),
    })
    print(f"PASS complete ordered cohort: {len(rows)} observations, {len(cases)} cases, {rounds} pairs", flush=True)
    for row in summaries:
        print(f"{row['case']}: {row['elapsed_ns']['median_paired_change_percent']:+.1f}% wall time", flush=True)
    return summaries


def benchmark(args: argparse.Namespace, output: Path, binaries: dict[str, Path], verified: dict[str, dict]) -> None:
    cases = args.case or list(TIMED_CASES)
    if len(set(cases)) != len(cases) or any(name not in verified for name in cases):
        raise ValueError("--case entries must name unique existing cases")
    calibration = []
    iterations = {}
    logs = output / "processes"
    logs.mkdir()
    for name in cases:
        rates = []
        for variant in VARIANTS:
            count = 1
            while True:
                row = json.loads(command([str(binaries[variant]), "measure", name, str(count)],
                                         logs / f"calibrate-{name}-{variant}-{count}.log", output))
                validate_sample(row, verified[name], count)
                row["variant"] = variant
                calibration.append(row)
                duration = min(row["elapsed_ns"], row["cpu_ns"])
                if duration >= args.target_ms * 1_000_000 / 4 or count >= 1_000_000:
                    break
                count = min(1_000_000, max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / duration)))
            rates.append(duration / count)
        # Equal work for both variants; target the faster one with a margin.
        iterations[name] = max(1, min(1_000_000, math.ceil(args.target_ms * 1_000_000 * 1.25 / min(rates))))
    write_json(output / "calibration.json", calibration)
    write_json(output / "benchmark.json", {"cases": cases, "rounds": args.rounds, "target_ms": args.target_ms,
                                          "iterations": iterations,
                                          "protocol": "Fresh processes; adjacent AB/BA pairs; reverse case traversal each round; no samples removed."})
    with (output / "measurements.jsonl").open("w") as stream:
        sequence = 0
        for round_index in range(args.rounds):
            order = VARIANTS if round_index % 2 == 0 else VARIANTS[::-1]
            traversal = cases if round_index % 2 == 0 else cases[::-1]
            for name in traversal:
                for position, variant in enumerate(order):
                    count = iterations[name]
                    log = logs / f"{round_index:02d}-{name}-{variant}.log"
                    row = json.loads(command([str(binaries[variant]), "measure", name, str(count)], log, output))
                    validate_sample(row, verified[name], count)
                    row.update({"round": round_index, "pair_position": position, "variant": variant, "sequence": sequence})
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    sequence += 1
            print(f"Finished paired round {round_index + 1}/{args.rounds}", flush=True)
    summarize(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("verify", "benchmark", "summarize"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--case", action="append", help="Exact case name; repeat to select multiple cases")
    parser.add_argument("--run-tests", action="store_true", help="Execute identical debug/release suites against both sources")
    args = parser.parse_args()
    output = args.output.resolve()
    if args.mode == "summarize":
        summarize(output)
        return
    if args.rounds < 2 or args.rounds % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--rounds must be positive, even, and at least two; --target-ms must be finite and positive")
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    binaries, manifest = build(args, output)
    if args.run_tests:
        test_sources(args, output)
    verified = verify(binaries, output)
    verify_timestamps(output)
    if args.mode == "benchmark":
        benchmark(args, output, binaries, verified)
    for variant in VARIANTS:
        folder = output / variant
        extension = "dylib" if platform.system() == "Darwin" else "so"
        for name, key in ((SOURCE.name, "source_sha256"),
                          (f"libIlliquidNativePlayback.{extension}", "library_sha256"),
                          ("converter-benchmark", "binary_sha256"),
                          ("timestamp-parity", "timestamp_parity_sha256")):
            if sha((folder / name).read_bytes()) != manifest["variants"][variant][key]:
                raise ValueError(f"Measured input changed: {variant}/{name}")
    if sha(SOURCE.read_bytes()) != manifest["variants"]["candidate"]["source_sha256"]:
        raise ValueError("Working-tree candidate changed during qualification")
    write_json(output / "completion.json", {"mode": args.mode, "passed": True,
                                           "source_and_binary_hashes_unchanged": True,
                                           "completed_utc": datetime.now(timezone.utc).isoformat()})


if __name__ == "__main__":
    main()
