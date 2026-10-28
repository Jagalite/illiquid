#!/usr/bin/env python3
"""Measure exact native PiP coordinate preparation; no media or player is opened."""
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
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
HELPER = "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift"
COMPOSITOR = "Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift"
TESTS = ("PiPVideoMappingTests.swift", "PiPTextureCoordinateCacheTests.swift")
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-enable-testing"]
MODULE = "IlliquidNativePlayback"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=int, default=120)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("The production CoreGraphics implementation requires macOS")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be even and in 2...20")
    if not 20 <= args.target_ms <= 500:
        parser.error("--target-ms must be in 20...500")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    (output / "logs").mkdir()
    evidence: dict[str, object] = {}
    ordinal = 0

    def save(name: str, value: object) -> None:
        evidence[name] = value
        (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def run(command: list[str | Path], name: str, timeout: int = 300) -> str:
        nonlocal ordinal
        argv = [str(value) for value in command]
        start = time.monotonic()
        process = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        log = output / "logs" / (name + ".log")
        log.write_text(process.stdout + process.stderr)
        with (output / "commands.jsonl").open("a") as handle:
            handle.write(json.dumps({
                "ordinal": ordinal, "command": argv, "log": str(log.relative_to(output)),
                "wall_seconds": time.monotonic() - start, "exit_code": process.returncode,
            }, sort_keys=True) + "\n")
        ordinal += 1
        if process.returncode:
            print((process.stdout + process.stderr)[-16000:], flush=True)
            raise RuntimeError(f"{name} exited {process.returncode}; see {log}")
        return process.stdout

    def measure(binary: Path, case: str, count: int, name: str) -> dict:
        row = json.loads(run([binary, case, str(count)], name))
        if row["case"] != case or row["iterations"] != count or row["calls_per_iteration"] != 1:
            raise ValueError("Measurement identity mismatch")
        for key in ("cpu_nanoseconds", "wall_nanoseconds"):
            if not isinstance(row[key], int) or row[key] <= 0:
                raise ValueError(f"Invalid timer result: {key}")
        return row

    def equal_receipts(pair: dict[str, dict]) -> None:
        for key in ("checksum", "warmup_checksum", "final_coordinates", "iterations", "case"):
            if pair["baseline"][key] != pair["candidate"][key]:
                raise ValueError(f"Baseline/candidate result differs: {key}")

    try:
        old = run(["git", "show", f"{BASELINE}:{HELPER}"], "baseline-source").encode()
        current = (ROOT / HELPER).read_bytes()
        anchor = b"    static func colorCoefficients"
        if old.count(anchor) != 1 or current.count(anchor) != 1:
            raise ValueError("Original helper boundary changed")
        if old[old.index(anchor):] != current[current.index(anchor):]:
            raise ValueError("The reference mapping or color math changed")
        receipts = {}
        sources = {}
        for variant, data in (("baseline", old), ("candidate", current)):
            directory = output / "sources" / variant
            directory.mkdir(parents=True)
            path = directory / "PiPVideoMapping.swift"
            path.write_bytes(data)
            sources[variant] = [path]
            receipts[f"{variant}/{HELPER}"] = digest(data)
            boundary = directory / "RequestBoundary.swift"
            shutil.copyfile(HERE / boundary.name, boundary)
            sources[variant].append(boundary)
            if variant == "baseline":
                adapter = directory / "BaselineAdapter.swift"
                shutil.copyfile(HERE / adapter.name, adapter)
                sources[variant].append(adapter)
                receipts["baseline/adapter"] = digest(adapter.read_bytes())
        qualification = output / "qualification"
        qualification.mkdir()
        for source in (
            HERE / "Driver.swift", HERE / "run.py", HERE / "BaselineAdapter.swift",
            HERE / "RequestBoundary.swift",
            *(ROOT / "Tests/IlliquidNativePlaybackTests" / name for name in TESTS),
        ):
            shutil.copyfile(source, qualification / source.name)
            receipts[str(source.relative_to(ROOT))] = digest(source.read_bytes())
        receipts[COMPOSITOR] = digest((ROOT / COMPOSITOR).read_bytes())
        manifest = {
            "baseline_commit": BASELINE,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "head").strip(),
            "working_tree_status": run(["git", "status", "--short"], "status").strip(),
            "source_sha256": receipts, "platform": platform.platform(),
            "architecture": platform.machine(),
            "swift": run(["xcrun", "swiftc", "--version"], "swift-version").strip(),
            "macos": run(["sw_vers"], "macos").strip(),
            "xcode": run(["xcodebuild", "-version"], "xcode").strip(),
            "hardware": run(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"], "hardware").strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "compiler_flags": FLAGS,
            "module": "Actual helper compiled separately as a dynamic library; no cross-module optimization",
            "baseline_adapter": "Semantic-test compatibility only; timed general requests call the original helper directly with BASELINE driver define; HDR uses positive 1920x1080 dimensions",
            "hdr_boundary": "Identical non-inlined support function in both modules; common call overhead is timed",
            "pairs": args.pairs, "target_ms": args.target_ms,
            "sampling": "Fresh process per variant and pair; AB/BA alternation with rotated workload order",
            "calibration": "Common iteration count per workload; calibrate both variants, retain all trials, target the faster variant",
            "timed_scope": "One coordinate request plus identical indexed-input/checksum loop overhead",
            "excluded_scope": "Fixture creation, verification, JSON, Metal encoding, GPU rendering, video decoding and live player UI",
        }
        save("manifest.json", manifest)

        tests = []
        for variant in VARIANTS:
            work = output / "build" / f"tests-{variant}"
            src = work / "Sources" / MODULE
            dst = work / "Tests" / "MappingTests"
            src.mkdir(parents=True)
            dst.mkdir(parents=True)
            for source in sources[variant]:
                shutil.copyfile(source, src / source.name)
            for name in TESTS:
                shutil.copyfile(qualification / name, dst / name)
            (work / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PiPTextureCoordinateQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "MappingTests", dependencies: ["IlliquidNativePlayback"]),
])
""")
            for configuration in ("debug", "release"):
                label = f"tests-{variant}-{configuration}"
                result = run([
                    "swift", "test", "--package-path", work, "--no-parallel", "-c", configuration
                ], label)
                tests.append({"variant": variant, "configuration": configuration, "passed": True,
                              "log": f"logs/{label}.log"})
                save("tests.json", tests)
                print("TEST_PASS " + variant + " " + configuration, flush=True)
                print("\n".join(result.splitlines()[-12:]), flush=True)

        binaries = {}
        for variant in VARIANTS:
            work = output / "build" / variant
            work.mkdir(parents=True)
            library = work / f"lib{MODULE}.dylib"
            run([
                "xcrun", "swiftc", *FLAGS, "-emit-library", "-emit-module",
                "-module-name", MODULE, "-emit-module-path", work / f"{MODULE}.swiftmodule",
                *sources[variant], "-o", library,
            ], f"compile-{variant}-module")
            binary = work / "benchmark"
            run([
                "xcrun", "swiftc", *FLAGS, *(["-D", "BASELINE"] if variant == "baseline" else []),
                "-parse-as-library", "-I", work, "-L", work,
                f"-l{MODULE}", "-Xlinker", "-rpath", "-Xlinker", work,
                qualification / "Driver.swift", "-o", binary,
            ], f"compile-{variant}-driver")
            binaries[variant] = binary
            manifest.setdefault("binary_sha256", {})[variant] = {
                "library": digest(library.read_bytes()), "driver": digest(binary.read_bytes()),
            }
        save("manifest.json", manifest)

        verification = {
            variant: json.loads(run([binary, "--verify"], f"verify-{variant}"))
            for variant, binary in binaries.items()
        }
        if verification["baseline"] != verification["candidate"]:
            raise ValueError("Complete coordinate bit receipts differ")
        save("verification.json", {
            "baseline_matches_candidate": True, "reference_math_unchanged": True,
            "receipt": verification["candidate"],
        })
        print("VERIFIED " + str(verification["candidate"]["requests"]) + " complete coordinate arrays", flush=True)

        if not args.verify_only:
            cases = json.loads(run([binaries["baseline"], "--list"], "cases"))["cases"]
            if json.loads(run([binaries["candidate"], "--list"], "candidate-cases"))["cases"] != cases:
                raise ValueError("Workload lists differ")
            counts = {}
            calibration = []
            for case in cases:
                count = 65_520
                for attempt in range(5):
                    pair = {}
                    for variant in VARIANTS:
                        row = measure(binaries[variant], case, count, f"calibrate-{case}-{attempt}-{variant}")
                        row.update(variant=variant, attempt=attempt)
                        calibration.append(row)
                        pair[variant] = row
                    equal_receipts(pair)
                    save("calibration.json", calibration)
                    elapsed = min(row["cpu_nanoseconds"] for row in pair.values()) / 1_000_000
                    if elapsed >= args.target_ms * 0.8 or count == 24_000_000:
                        break
                    requested = math.ceil(count * args.target_ms / max(elapsed, 0.000001))
                    count = min(24_000_000, max(count + 240, math.ceil(requested / 240) * 240))
                counts[case] = count
                print(f"CALIBRATED {case} {count}", flush=True)
            save("iteration-counts.json", counts)
            observations = []
            for pair_number in range(args.pairs):
                offset = pair_number % len(cases)
                for case in cases[offset:] + cases[:offset]:
                    order = VARIANTS if pair_number % 2 == 0 else tuple(reversed(VARIANTS))
                    pair = {}
                    for position, variant in enumerate(order):
                        row = measure(binaries[variant], case, counts[case],
                                      f"measure-{pair_number}-{case}-{variant}")
                        row.update(variant=variant, pair=pair_number, order=position)
                        observations.append(row)
                        pair[variant] = row
                    equal_receipts(pair)
                save("observations.json", observations)
                print(f"MEASURED pair {pair_number + 1}/{args.pairs}", flush=True)
            if len(observations) != len(cases) * args.pairs * 2:
                raise ValueError("Incomplete observation cohort")
            summaries = []
            for case in cases:
                rows = [row for row in observations if row["case"] == case]
                summary = {"case": case, "iterations": counts[case], "pairs": args.pairs}
                for timer in ("cpu", "wall"):
                    key = timer + "_ns_per_call"
                    samples = {variant: [row[key] for row in rows if row["variant"] == variant]
                               for variant in VARIANTS}
                    ratios = []
                    for pair_number in range(args.pairs):
                        pair = {row["variant"]: row[key] for row in rows if row["pair"] == pair_number}
                        ratios.append(pair["candidate"] / pair["baseline"])
                    before = statistics.median(samples["baseline"])
                    after = statistics.median(samples["candidate"])
                    summary[timer] = {
                        "baseline_median_ns": before, "candidate_median_ns": after,
                        "median_reduction_percent": 100 * (1 - after / before),
                        "paired_median_reduction_percent": 100 * (1 - statistics.median(ratios)),
                        "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
                        "paired_ratios": ratios,
                        "baseline_range_ns": [min(samples["baseline"]), max(samples["baseline"])],
                        "candidate_range_ns": [min(samples["candidate"]), max(samples["candidate"])],
                    }
                summaries.append(summary)
                print("PERF_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
            save("summary.json", summaries)

        # Seal the exact inputs after all tests and timings.
        if digest((ROOT / HELPER).read_bytes()) != receipts[f"candidate/{HELPER}"]:
            raise ValueError("Candidate helper changed during qualification")
        for path, expected in receipts.items():
            if path.startswith(("baseline/", "candidate/")):
                continue
            if digest((ROOT / path).read_bytes()) != expected:
                raise ValueError(f"Source changed during qualification: {path}")
        save("completion.json", {
            "passed": True, "test_runs": len(tests), "verify_only": args.verify_only,
            "coordinate_requests": verification["candidate"]["requests"],
            "measurements": len(evidence.get("observations.json", [])),
        })
    except BaseException as error:
        save("failure.json", {"error": f"{type(error).__name__}: {error}"})
        raise
    finally:
        # Plain JSON receipts let remote reviewers retain results without
        # decoding binary workflow artifacts. Logs and source snapshots are
        # also uploaded by CI.
        for name, value in evidence.items():
            print("EVIDENCE_JSON " + json.dumps({"file": name, "data": value},
                                              separators=(",", ":"), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
