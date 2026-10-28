#!/usr/bin/env python3
"""Compare real subtitle converters and retain platform-specific evidence."""
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
import sys
from pathlib import Path

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE = "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
CASES = ("srt-short", "vtt-short", "srt-crlf", "vtt-crlf",
         "srt-multiline", "srt-dense",
         "srt-long-line", "invalid-preamble")
TESTS = ("ExternalTextSubtitleConverterTests.swift",
         "ExternalSubtitleEscapingTests.swift", "SubtitleCueStreamingTests.swift")
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if platform.system() not in ("Darwin", "Linux"):
        parser.error("Requires macOS or Linux with Swift 6.1 or newer.")
    native = platform.system() == "Darwin"
    swiftc = ["xcrun", "swiftc"] if native else ["swiftc"]
    swift = ["xcrun", "swift"] if native else ["swift"]
    if args.pairs < 6 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be even and between 6 and 20")
    if not 100 <= args.target_ms <= 2000:
        parser.error("--target-ms must be between 100 and 2000")
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must be a new directory")
    output.mkdir(parents=True)
    root = Path(__file__).resolve().parents[2]
    receipts = []

    def save(name, value):
        (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def execute(label, command, cwd=None, timeout=600):
        command = [str(x) for x in command]
        process = subprocess.run(command, cwd=cwd or root, capture_output=True,
                                 text=True, timeout=timeout)
        log_name = f"{label}.log"
        (output / log_name).write_text(process.stdout + process.stderr)
        receipts.append({
            "label": label, "command": command, "cwd": str(cwd or root),
            "exit_code": process.returncode, "log": log_name,
            "stdout_sha256": digest(process.stdout.encode()),
            "stderr_sha256": digest(process.stderr.encode()),
        })
        save("commands.json", receipts)
        if process.returncode:
            raise RuntimeError(f"{label} failed ({process.returncode}); see {log_name}")
        return process.stdout

    def compile_command(label, command, cwd=None):
        # A single Kyoto job can own this whole serial workflow. Never enqueue
        # nested jobs or treat a queued submission as successful compilation.
        if KYOTO.is_file() and os.environ.get("ILLIQUID_CUE_STREAMING_QUEUED") != "1":
            raise RuntimeError(
                "Kyoto is available. Run: python3 "
                f"{KYOTO} submit -- env ILLIQUID_CUE_STREAMING_QUEUED=1 "
                f"python3 {Path(__file__).resolve()} --output NEW_PATH "
                f"--pairs {args.pairs} --target-ms {args.target_ms}"
            )
        return execute(label, command, cwd=cwd)

    try:
        if not KYOTO.is_file():
            print("Kyoto is unavailable on this hosted machine; compiling directly "
                  "in isolated temporary directories, with builds serialized.",
                  flush=True)
        execute("baseline-ancestor", ["git", "merge-base", "--is-ancestor",
                                     BASELINE, "HEAD"])
        baseline = execute("baseline-source", ["git", "show", f"{BASELINE}:{SOURCE}"])
        candidate = (root / SOURCE).read_text()
        driver = Path(__file__).with_name("Driver.swift").read_text()
        snapshots = output / "sources"
        snapshots.mkdir()
        for variant, source in (("baseline", baseline), ("candidate", candidate)):
            (snapshots / f"{variant}.swift").write_text(source)
        (snapshots / "Driver.swift").write_text(driver)
        shutil.copy2(__file__, snapshots / "run.py")
        provenance = {
            "baseline_commit": BASELINE,
            "candidate_commit": execute("head", ["git", "rev-parse", "HEAD"]).strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": execute("swift-version", [*swiftc, "--version"]).strip(),
            "xcode": execute("xcode-version", ["xcodebuild", "-version"]).strip() if native else None,
            "hardware": execute("hardware", ["sysctl", "hw.model", "hw.memsize", "hw.ncpu"] if native else ["lscpu"]).strip(),
            "source_path": SOURCE,
            "baseline_sha256": digest(baseline.encode()),
            "candidate_sha256": digest(candidate.encode()),
            "driver_sha256": digest(driver.encode()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "pairs": args.pairs, "target_ms": args.target_ms,
            "kyoto_available": KYOTO.is_file(),
            "scope": "Full text-to-ASS conversion; no file I/O, libass, playback, or UI timing.",
        }
        save("provenance.json", provenance)
        binaries = {}
        traces = {}
        for configuration, flags in (("debug", ["-Onone"]),
                                     ("release", ["-O", "-whole-module-optimization"])):
            for variant in ("baseline", "candidate"):
                label = f"{variant}-{configuration}"
                binary = output / label
                compile_command(f"build-{label}", [
                    *swiftc, "-swift-version", "6", "-parse-as-library",
                    *flags, snapshots / f"{variant}.swift",
                    snapshots / "Driver.swift", "-o", binary,
                ])
                binaries[(variant, configuration)] = binary
                traces[label] = json.loads(execute(f"verify-{label}", [binary, "verify"]))
                save(f"trace-{label}.json", traces[label])
        first_trace = traces["baseline-debug"]
        for label, trace in traces.items():
            if trace != first_trace:
                raise RuntimeError(f"Full output/error parity failed for {label}")
        save("parity.json", {
            "passed": True, "configurations": list(traces),
            "case_count": len(first_trace["cases"]),
            "comparison": "Exact JSON records of complete ASS output or typed error, not hashes alone.",
        })

        # Compile the real converter and focused native-package tests without
        # importing FFmpeg, a renderer, or the full application dependency graph.
        test_results = []
        package_manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SubtitleCueStreamingValidation",
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidNativePlayback"]),
    ]
)
"""
        for variant, source in (("baseline", baseline), ("candidate", candidate)):
            package = output / f"tests-{variant}"
            (package / "Sources/IlliquidNativePlayback").mkdir(parents=True)
            (package / "Tests/IlliquidNativePlaybackTests").mkdir(parents=True)
            (package / "Package.swift").write_text(package_manifest)
            (package / "Sources/IlliquidNativePlayback/ExternalTextSubtitleConverter.swift").write_text(source)
            for name in TESTS:
                source_test = root / "Tests/IlliquidNativePlaybackTests" / name
                shutil.copy2(source_test, package / "Tests/IlliquidNativePlaybackTests" / name)
            for configuration in ("debug", "release"):
                compile_command(f"tests-{variant}-{configuration}", [
                    *swift, "test", "--package-path", package,
                    "--configuration", configuration, "--jobs", "2", "--no-parallel",
                ])
                test_log = (output / f"tests-{variant}-{configuration}.log").read_text()
                counts_found = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", test_log)
                if not counts_found or int(counts_found[-1]) == 0:
                    raise RuntimeError("Swift Testing did not report executed regression tests")
                test_results.append({"variant": variant, "configuration": configuration,
                                     "passed": True, "test_count": int(counts_found[-1]),
                                     "files": list(TESTS)})
                save("tests.json", test_results)
        if args.tests_only:
            save("completion.json", {"passed": True, "tests_only": True})
            return

        def observe(variant, case, iterations, label):
            row = json.loads(execute(label, [
                binaries[(variant, "release")], "measure", case, str(iterations)
            ]))
            if row["iterations"] != iterations or row["case"] != case:
                raise RuntimeError("Measurement receipt does not match requested workload")
            if row["checksum"] != row["expected_checksum"]:
                raise RuntimeError("Timed output checksum differs")
            return row

        pilots = []
        counts = {}
        # Each variant gets its own iteration count, but identical fixture
        # distribution. Normalization is per complete conversion.
        for case in CASES:
            for variant in ("baseline", "candidate"):
                count = 1
                for attempt in range(8):
                    row = observe(variant, case, count,
                                  f"pilot-{case}-{variant}-{attempt}")
                    pilots.append({"variant": variant, **row})
                    save("calibration.json", pilots)
                    elapsed = min(row["wall_ns"], row["cpu_ns"])
                    if elapsed >= args.target_ms * 1_000_000:
                        break
                    count = min(1_000_000, max(count + 1,
                        math.ceil(count * args.target_ms * 1_000_000
                                  / max(elapsed, 1) * 1.15)))
                else:
                    raise RuntimeError(f"Could not calibrate {case} {variant}")
                counts[(case, variant)] = count

        rows = []
        memory_rows = []
        for case in CASES:
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                pair_rows = []
                for variant in order:
                    row = observe(variant, case, counts[(case, variant)],
                                  f"measure-{case}-{pair}-{variant}")
                    if min(row["wall_ns"], row["cpu_ns"]) < 60_000_000:
                        raise RuntimeError("Timed sample below 60 ms qualification floor")
                    row.update(variant=variant, pair=pair, ordinal=len(rows))
                    rows.append(row)
                    pair_rows.append(row)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                for key in ("input_bytes", "output_bytes", "fixture_count", "fixture_checksum", "cycle_checksum"):
                    if pair_rows[0][key] != pair_rows[1][key]:
                        raise RuntimeError(f"Baseline/candidate fixture mismatch: {key}")
        for case in ("srt-dense", "srt-long-line"):
            for pair in range(4):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for variant in order:
                    row = json.loads(execute(f"memory-{case}-{pair}-{variant}", [
                        binaries[(variant, "release")], "memory", case
                    ]))
                    reference = next(r for r in rows
                                     if r["case"] == case and r["variant"] == variant)
                    if row.get("mode") != "memory" or row.get("case") != case:
                        raise RuntimeError("Memory receipt has the wrong workload")
                    for key in ("fixture_count", "fixture_checksum", "input_bytes",
                                "output_bytes", "cycle_checksum"):
                        if row[key] != reference[key]:
                            raise RuntimeError(f"Memory fixture mismatch: {key}")
                    if not (row["checksum"] == row["expected_checksum"]
                            == row["cycle_checksum"]):
                        raise RuntimeError("Memory checksum differs")
                    if not (row["peak_rss_bytes"] >= row["peak_rss_before_conversion_bytes"]
                            >= row["peak_rss_before_fixture_bytes"]):
                        raise RuntimeError("Memory high-water marks are inconsistent")
                    if row["peak_rss_growth_bytes"] != (
                        row["peak_rss_bytes"] - row["peak_rss_before_conversion_bytes"]
                    ):
                        raise RuntimeError("Memory growth receipt differs")
                    row.update(variant=variant, pair=pair, ordinal=len(memory_rows))
                    memory_rows.append(row)
                    with (output / "memory.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")

        summary = []
        for case in CASES:
            item = {"case": case, "pairs": args.pairs}
            for variant in ("baseline", "candidate"):
                subset = [r for r in rows if r["case"] == case and r["variant"] == variant]
                entry = {}
                for metric in ("wall_ns", "cpu_ns"):
                    values = [r[metric] / r["iterations"] for r in subset]
                    entry[f"{metric}_per_conversion"] = {
                        "median": statistics.median(values), "min": min(values),
                        "max": max(values), "samples": values,
                    }
                entry.update(input_bytes=subset[0]["input_bytes"],
                             output_bytes=subset[0]["output_bytes"],
                             iterations=subset[0]["iterations"])
                item[variant] = entry
            for metric in ("wall_ns", "cpu_ns"):
                key = f"{metric}_per_conversion"
                item[f"{metric}_median_speedup"] = (
                    item["baseline"][key]["median"] / item["candidate"][key]["median"])
            mem = [r for r in memory_rows if r["case"] == case]
            if mem:
                item["process_peak_rss_bytes"] = {
                    variant: {
                        "median": statistics.median(r["peak_rss_bytes"] for r in mem
                                                    if r["variant"] == variant),
                        "samples": [r["peak_rss_bytes"] for r in mem
                                    if r["variant"] == variant],
                    } for variant in ("baseline", "candidate")
                }
            summary.append(item)
        save("summary.json", summary)
        save("completion.json", {
            "passed": True, "timing_rows": len(rows), "memory_rows": len(memory_rows),
            "binaries": {f"{v}-{c}": digest(path.read_bytes())
                         for (v, c), path in binaries.items()},
        })
        print(json.dumps({"parity_passed": True, "summary": summary}, indent=2), flush=True)
    except Exception as error:
        save("completion.json", {"passed": False, "error": str(error)})
        raise


if __name__ == "__main__":
    main()
