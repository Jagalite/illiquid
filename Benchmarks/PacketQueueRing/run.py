#!/usr/bin/env python3
"""Measure exact bounded queues against a pinned ring-buffer baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RING = Path("Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift")
QUEUE = Path("Sources/IlliquidNativePlayback/Playback/PacketQueue.swift")
TESTS = (
    Path("Tests/IlliquidNativePlaybackTests/FixedRingBufferTests.swift"),
    Path("Tests/IlliquidNativePlaybackTests/PacketQueueWakeupTests.swift"),
)
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "f381657f22d07f49941b05afbd0c2549a2d98b1e"
VARIANTS = ("baseline", "candidate")
WORKLOADS = (
    "queue-value-half", "queue-value-full",
    "queue-reference-half", "queue-reference-full",
    "queue-mixed", "queue-try",
    "ring", "ring-mixed", "queue-count-control",
)
CAPACITIES = (12, 48, 64, 96, 192)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args: list[str], log: Path) -> str:
    log.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(args, text=True, capture_output=True)
    log.write_text(json.dumps(args) + "\n\n" + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{result.stderr[-6000:]}")
    return result.stdout


def snapshot(out: Path) -> dict:
    baseline = (HERE / "baseline/FixedRingBuffer.swift").read_bytes()
    blob = hashlib.sha1(f"blob {len(baseline)}\0".encode() + baseline).hexdigest()
    if blob != BASELINE_BLOB:
        raise RuntimeError("Pinned baseline ring changed")
    inputs = {
        "baseline/FixedRingBuffer.swift": baseline,
        "candidate/FixedRingBuffer.swift": (ROOT / RING).read_bytes(),
        "PacketQueue.swift": (ROOT / QUEUE).read_bytes(),
        "Harness.swift": (HERE / "Harness.swift").read_bytes(),
        "run.py": Path(__file__).read_bytes(),
    }
    for path in TESTS:
        inputs[path.name] = (ROOT / path).read_bytes()
    hashes = {}
    for name, data in inputs.items():
        dest = out / "inputs" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        hashes[name] = digest(data)
    return hashes


def toolchain(out: Path) -> dict:
    native = sys.platform == "darwin"
    swiftc = os.environ.get("SWIFTC")
    if native and not swiftc:
        swiftc = command(["xcrun", "--find", "swiftc"], out / "compiler-path.log").strip()
    swiftc = swiftc or shutil.which("swiftc")
    if not swiftc:
        raise RuntimeError("swiftc is required")
    swift = os.environ.get("SWIFT") or str(Path(swiftc).parent / "swift")
    info = {
        "swiftc": swiftc, "swift": swift,
        "version": command([swiftc, "--version"], out / "compiler-version.log").strip(),
        "compiler_sha256": digest(Path(swiftc).resolve().read_bytes()),
    }
    if native:
        info["sdk"] = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], out / "sdk.log").strip()
        info["sdk_version"] = command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], out / "sdk-version.log").strip()
    return info


def run_tests(out: Path, compiler: dict) -> None:
    for variant in VARIANTS:
        package = out / "tests" / variant
        sources = package / "Sources/IlliquidNativePlayback"
        tests = package / "Tests/IlliquidNativePlaybackTests"
        sources.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(out / "inputs" / variant / "FixedRingBuffer.swift", sources / "FixedRingBuffer.swift")
        shutil.copyfile(out / "inputs/PacketQueue.swift", sources / "PacketQueue.swift")
        for source in TESTS:
            shutil.copyfile(out / "inputs" / source.name, tests / source.name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PacketQueueRingQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])
])
''')
        for configuration in ("debug", "release"):
            args = [compiler["swift"], "test", "--package-path", str(package),
                    "--configuration", configuration, "--jobs", "2",
                    "--scratch-path", str(package / "build"),
                    "-Xswiftc", "-warnings-as-errors"]
            log = out / f"tests-{variant}-{configuration}.log"
            command(args, log)
            print(f"PASS {variant} {configuration} ring and existing queue regression tests", flush=True)


def build(out: Path, compiler: dict) -> dict[str, Path]:
    binaries = {}
    for variant in VARIANTS:
        folder = out / "build" / variant
        folder.mkdir(parents=True)
        binary = folder / "queue-ring"
        flags = ["-swift-version", "6", "-O", "-whole-module-optimization",
                 "-warnings-as-errors", "-parse-as-library",
                 "-module-cache-path", str(out / "module-cache")]
        if sys.platform == "darwin":
            flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", compiler["sdk"]]
        args = [compiler["swiftc"], *flags, str(out / "inputs" / variant / "FixedRingBuffer.swift"),
                str(out / "inputs/PacketQueue.swift"), str(out / "inputs/Harness.swift"),
                "-o", str(binary)]
        command(args, folder / "build.log")
        save(folder / "manifest.json", {"command": args, "binary_sha256": digest(binary.read_bytes())})
        binaries[variant] = binary
    return binaries


def compare_pair(pair: list[dict]) -> None:
    if len(pair) != 2 or {x["variant"] for x in pair} != set(VARIANTS):
        raise RuntimeError("Invalid pair")
    for key in ("workload", "capacity", "iterations", "warmupIterations"):
        if pair[0][key] != pair[1][key]:
            raise RuntimeError(f"Different {key} in paired receipts")
    for part in ("warmup", "measurement"):
        for key in ("fingerprint", "remainingFingerprint", "remainingCount"):
            if pair[0][part][key] != pair[1][part][key]:
                raise RuntimeError(f"Different {part}.{key} in paired receipts")


def interval(ratios: list[float]) -> list[float]:
    # Descriptive paired bootstrap; raw pairs are retained for independent review.
    rng = random.Random(870_411)
    draws = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(2_000))
    return [draws[49], draws[1949]]


def summarize(rows: list[dict]) -> list[dict]:
    summaries = []
    for workload in WORKLOADS:
        for capacity in CAPACITIES:
            selected = [r for r in rows if r["workload"] == workload and r["capacity"] == capacity]
            if not selected:
                continue
            item = {"workload": workload, "capacity": capacity, "iterations": selected[0]["iterations"],
                    "unit": "ns per pop/enqueue cycle" if workload != "queue-count-control" else "ns per count read"}
            for label, field in (("wall", "wallNanoseconds"), ("cpu", "cpuNanoseconds")):
                ratios = []
                for index in sorted({r["pair"] for r in selected}):
                    pair = [r for r in selected if r["pair"] == index]
                    compare_pair(pair)
                    matched = {r["variant"]: r for r in pair}
                    ratios.append(matched["candidate"]["measurement"][field] /
                                  matched["baseline"]["measurement"][field])
                item[label] = {
                    variant: statistics.median(r["measurement"][field] / r["iterations"]
                                               for r in selected if r["variant"] == variant)
                    for variant in VARIANTS
                }
                item[label].update({
                    "paired_ratio_median": statistics.median(ratios),
                    "paired_ratio_95pct_bootstrap": interval(ratios),
                    "paired_ratios": ratios,
                    "change_percent": (statistics.median(ratios) - 1) * 100,
                })
            summaries.append(item)
    return summaries


def benchmark(out: Path, args: argparse.Namespace, compiler: dict) -> None:
    binaries = build(out, compiler)
    cases = [(w, c) for w in WORKLOADS for c in CAPACITIES]

    def measure(variant: str, workload: str, capacity: int, iterations: int, label: str) -> dict:
        argv = [str(binaries[variant]), workload, str(capacity), str(iterations)]
        log = out / "processes" / f"{label}-{workload}-{capacity}-{variant}.log"
        row = json.loads(command(argv, log))
        if (row["workload"], row["capacity"], row["iterations"]) != (workload, capacity, iterations):
            raise RuntimeError("Benchmark returned wrong fixture")
        if min(row["measurement"]["wallNanoseconds"], row["measurement"]["cpuNanoseconds"]) <= 0:
            raise RuntimeError("Benchmark returned non-positive duration")
        row.update({"variant": variant, "command": argv, "process_log_sha256": digest(log.read_bytes())})
        return row

    counts = {}
    calibrations = []
    for case_index, (workload, capacity) in enumerate(cases):
        count = 50_000
        for attempt in range(6):
            order = VARIANTS if (case_index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
            pair = [measure(v, workload, capacity, count, f"calibration-{attempt}") for v in order]
            compare_pair(pair)
            for position, row in enumerate(pair):
                row.update({"attempt": attempt, "order": list(order), "position": position})
            calibrations.extend(pair)
            fastest = min(r["measurement"]["wallNanoseconds"] for r in pair)
            if fastest >= args.target_ms * 1_000_000:
                break
            count = max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / fastest * 1.1))
        else:
            raise RuntimeError(f"Calibration failed: {workload}/{capacity}")
        counts[(workload, capacity)] = count
    save(out / "calibration.json", calibrations)
    rows = []
    with (out / "measurements.jsonl").open("w") as stream:
        for pair_index in range(args.pairs):
            # Rotate case order to distribute gradual host drift across capacities.
            shift = pair_index % len(cases)
            ordered_cases = cases[shift:] + cases[:shift]
            for workload, capacity in ordered_cases:
                case_index = cases.index((workload, capacity))
                order = VARIANTS if (pair_index + case_index) % 2 == 0 else tuple(reversed(VARIANTS))
                pair = []
                for position, variant in enumerate(order):
                    row = measure(variant, workload, capacity, counts[(workload, capacity)],
                                  f"pair-{pair_index:02d}")
                    row.update({"pair": pair_index, "order": list(order), "position": position,
                                "sequence": len(rows)})
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    rows.append(row)
                    pair.append(row)
                compare_pair(pair)
            print(f"Completed paired round {pair_index + 1}/{args.pairs}", flush=True)
    save(out / "summary.json", summarize(rows))
    print("RING_SUMMARY_JSON " + json.dumps(summarize(rows), sort_keys=True), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even --pairs >= 2 and finite positive --target-ms")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Use a fresh output directory")
    out.mkdir(parents=True, exist_ok=True)
    hashes = snapshot(out)
    compiler = toolchain(out)
    manifest = {
        "baseline_commit": BASELINE_COMMIT, "baseline_ring_blob": BASELINE_BLOB,
        "candidate_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "recorded_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "cpu_count": os.cpu_count(), "python": sys.version, "compiler": compiler,
        "source_sha256": hashes, "pairs": args.pairs, "target_ms": args.target_ms,
        "method": "Exact queue sources; identical -O whole-module builds; runtime capacities; serial fresh-process balanced AB/BA; setup, warmup and teardown outside timing.",
    }
    save(out / "manifest.json", manifest)
    run_tests(out, compiler)
    if not args.tests_only:
        benchmark(out, args, compiler)
    save(out / "completion.json", {"tests_passed": True, "benchmark_completed": not args.tests_only})
    print("RING_MANIFEST_JSON " + json.dumps(manifest, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
