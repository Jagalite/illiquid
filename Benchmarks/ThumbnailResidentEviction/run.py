#!/usr/bin/env python3
"""Compare actual native thumbnail-cache sources on macOS; no decoder or disk I/O in timings."""

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
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CACHE = "Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift"
BASE_BLOB = "66b8127d5c1ea269860b2c1b63e3dcede4262807"
VARIANTS = ("baseline", "candidate")
CORE = [
    "Sources/IlliquidCore/Player/ThumbnailPolicy.swift",
    "Sources/IlliquidCore/Utilities/NonDecodePerformance.swift",
    "Sources/IlliquidCore/Player/MediaTrack.swift",
    "Sources/IlliquidCore/Persistence/MediaPlaybackSettings.swift",
    "Sources/IlliquidCore/Persistence/MediaContentVersion.swift",
]
NATIVE = [
    CACHE,
    "Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift",
    "Sources/IlliquidNativePlayback/Media/NativeFileContentVersion.swift",
    "Sources/IlliquidNativePlayback/Media/ThumbnailBlockingReader.swift",
    "Sources/IlliquidNativePlayback/Media/ThumbnailPromotionMailbox.swift",
    "Sources/IlliquidNativePlayback/Media/ThumbnailDiskEvictionHeap.swift",
]
TESTS = [
    "Tests/IlliquidNativePlaybackTests/ThumbnailResidentEvictionTests.swift",
    "Tests/IlliquidNativePlaybackTests/ThumbnailImageLifetimeTests.swift",
]
COMMANDS = []


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(args: list[str], out: Path) -> str:
    logs = out / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / f"{len(COMMANDS):04d}.log"
    environment = dict(os.environ)
    for key, name in (
        ("CLANG_MODULE_CACHE_PATH", "clang"),
        ("SWIFTPM_MODULECACHE_OVERRIDE", "swift"),
        ("XDG_CACHE_HOME", "xdg"),
        ("TMPDIR", "tmp"),
    ):
        directory = out / "cache" / name
        directory.mkdir(parents=True, exist_ok=True)
        environment[key] = str(directory)
    result = subprocess.run(args, cwd=ROOT, env=environment, text=True, capture_output=True)
    log.write_text(result.stdout + result.stderr)
    COMMANDS.append({
        "arguments": args, "returncode": result.returncode,
        "log": str(log.relative_to(out)), "log_sha256": sha(log.read_bytes()),
    })
    write_json(out / "commands.json", COMMANDS)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout[-4000:]}\n{result.stderr[-6000:]}")
    return result.stdout


def snapshot_inputs(out: Path) -> dict:
    baseline = run(["git", "show", f"{BASE}:{CACHE}"], out).encode()
    blob = hashlib.sha1(f"blob {len(baseline)}\0".encode() + baseline).hexdigest()
    if blob != BASE_BLOB:
        raise RuntimeError("Baseline cache does not match its pinned Git blob")
    hashes = {}
    for variant in VARIANTS:
        for relative in CORE + NATIVE:
            data = baseline if variant == "baseline" and relative == CACHE else (ROOT / relative).read_bytes()
            destination = out / "inputs" / variant / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            hashes[str(destination.relative_to(out))] = sha(data)
    for relative in TESTS + [
        "Benchmarks/ThumbnailResidentEviction/Harness.swift",
        "Benchmarks/ThumbnailResidentEviction/run.py",
    ]:
        destination = out / "inputs" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((ROOT / relative).read_bytes())
        hashes[str(destination.relative_to(out))] = sha(destination.read_bytes())
    return hashes


def test(variant: str, configuration: str, swift: str, out: Path) -> None:
    package = out / "tests" / variant
    for name, sources in (("IlliquidCore", CORE), ("IlliquidNativePlayback", NATIVE)):
        destination = package / "Sources" / name
        destination.mkdir(parents=True, exist_ok=True)
        for relative in sources:
            shutil.copyfile(out / "inputs" / variant / relative, destination / Path(relative).name)
    destination = package / "Tests/IlliquidNativePlaybackTests"
    destination.mkdir(parents=True, exist_ok=True)
    for relative in TESTS:
        shutil.copyfile(out / "inputs" / relative, destination / Path(relative).name)
    (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ThumbnailResidentEvictionQualification", platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidCore", "IlliquidNativePlayback"])
    ])
""")
    run([
        swift, "test", "--package-path", str(package), "--configuration", configuration,
        "--scratch-path", str(package / "build"), "--jobs", "2", "--no-parallel",
        "--cache-path", str(out / "cache/packages"), "--config-path", str(out / "cache/config"),
        "--security-path", str(out / "cache/security"),
    ], out)
    print(f"PASS {variant} {configuration} component regression tests", flush=True)


def build(variant: str, swiftc: str, sdk: str, out: Path) -> Path:
    destination = out / "build" / variant
    destination.mkdir(parents=True, exist_ok=True)
    flags = [
        "-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
        "-module-cache-path", str(out / "cache/modules"),
        "-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk,
    ]
    links = ["-I", str(destination), "-L", str(destination),
             "-Xlinker", "-rpath", "-Xlinker", str(destination)]
    for module, sources in (("IlliquidCore", CORE), ("IlliquidNativePlayback", NATIVE)):
        run([
            swiftc, *flags, "-enable-testing", "-emit-library", "-emit-module",
            "-module-name", module, "-emit-module-path", str(destination / f"{module}.swiftmodule"),
            "-o", str(destination / f"lib{module}.dylib"), *links,
            *(["-lIlliquidCore"] if module == "IlliquidNativePlayback" else []),
            *[str(out / "inputs" / variant / path) for path in sources],
        ], out)
    binary = destination / "resident-eviction"
    run([
        swiftc, *flags, "-parse-as-library", *links, "-lIlliquidCore", "-lIlliquidNativePlayback",
        str(out / "inputs/Benchmarks/ThumbnailResidentEviction/Harness.swift"), "-o", str(binary),
    ], out)
    write_json(destination / "hashes.json", {
        path.name: sha(path.read_bytes())
        for path in destination.iterdir() if path.is_file()
    })
    return binary


def compare_pair(pair: list[dict]) -> None:
    if len(pair) != 2 or {row["variant"] for row in pair} != set(VARIANTS):
        raise RuntimeError("Missing or duplicate paired observation")
    for key in ("workload", "iterations", "operations", "warmupIterations", "checksum", "finalState"):
        if pair[0][key] != pair[1][key]:
            raise RuntimeError(f"Paired output differs for {key}: {pair[0]['workload']}")


def summarize(rows: list[dict]) -> list[dict]:
    summaries = []
    for workload in dict.fromkeys(row["workload"] for row in rows):
        selected = [row for row in rows if row["workload"] == workload]
        ratios = []
        for pair_index in sorted({row["pair"] for row in selected}):
            pair = [row for row in selected if row["pair"] == pair_index]
            compare_pair(pair)
            by_variant = {row["variant"]: row for row in pair}
            ratios.append(by_variant["candidate"]["elapsedNS"] / by_variant["baseline"]["elapsedNS"])
        medians = {
            variant: statistics.median(row["elapsedNS"] / row["operations"]
                                       for row in selected if row["variant"] == variant)
            for variant in VARIANTS
        }
        rng = random.Random(20261028)
        bootstrap = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(5000))
        summaries.append({
            "workload": workload, "pairs": len(ratios),
            "baseline_ns_per_operation": medians["baseline"],
            "candidate_ns_per_operation": medians["candidate"],
            "median_change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
            "paired_ratio_median": statistics.median(ratios),
            "paired_ratio_bootstrap_95_interval": [bootstrap[124], bootstrap[4874]],
            "paired_ratios": ratios,
        })
    return summaries


def benchmark(args, binaries: dict[str, Path], out: Path) -> tuple[list, list, dict]:
    verification = {}
    workload_lists = {}
    for variant, binary in binaries.items():
        raw = run([str(binary), "verify"], out)
        verification[variant] = json.loads(raw)
        (out / f"verification-{variant}.json").write_text(raw)
        workload_lists[variant] = json.loads(run([str(binary), "list"], out))["workloads"]
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Full survivor/byte-count differential traces differ")
    if workload_lists["baseline"] != workload_lists["candidate"]:
        raise RuntimeError("Workload lists differ")
    verify_receipt = {
        "passed": True, "snapshots": verification["candidate"]["snapshots"],
        "traces": len(verification["candidate"]["traces"]),
        "canonical_sha256": sha(json.dumps(verification["candidate"], sort_keys=True).encode()),
    }
    write_json(out / "verification.json", verify_receipt)
    print(f"PASS exact differential: {verify_receipt['snapshots']} survivor snapshots", flush=True)
    workloads = workload_lists["candidate"]

    def measure(variant, workload, iterations):
        row = json.loads(run([str(binaries[variant]), "measure", workload, str(iterations)], out))
        if row["iterations"] != iterations or row["operations"] != iterations or row["elapsedNS"] <= 0:
            raise RuntimeError(f"Invalid timing receipt: {row}")
        row["variant"] = variant
        row["command_index"] = len(COMMANDS) - 1
        return row

    counts, calibration = {}, []
    for index, workload in enumerate(workloads):
        count = 8 if workload.startswith("shrink") else 128
        # Repeated budget-shrink fixtures involve 96 untimed actor insertions per
        # timed configure. Use a shorter aggregate interval for that one workload.
        target_ns = (min(args.target_ms, 20.0) if workload.startswith("shrink") else args.target_ms) * 1_000_000
        for attempt in range(8):
            order = VARIANTS if (index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
            pair = [measure(variant, workload, count) for variant in order]
            compare_pair(pair)
            for row in pair:
                row.update({"attempt": attempt, "order": list(order)})
                calibration.append(row)
            write_json(out / "calibration.json", calibration)
            fastest = min(row["elapsedNS"] for row in pair)
            if fastest >= target_ns:
                break
            count = max(count + 1, math.ceil(count * target_ns / fastest * 1.1))
        else:
            raise RuntimeError(f"Calibration failed for {workload}")
        counts[workload] = count
    write_json(out / "iterations.json", counts)

    observations = []
    for pair_index in range(args.pairs):
        for index, workload in enumerate(workloads):
            order = VARIANTS if (pair_index + index) % 2 == 0 else tuple(reversed(VARIANTS))
            pair = [measure(variant, workload, counts[workload]) for variant in order]
            compare_pair(pair)
            for row in pair:
                row.update({"pair": pair_index, "order": list(order)})
                observations.append(row)
            write_json(out / "observations.json", observations)
        print(f"Completed paired round {pair_index + 1}/{args.pairs}", flush=True)
    summary = summarize(observations)
    write_json(out / "summary.json", summary)
    for row in summary:
        print(f"{row['workload']}: {row['baseline_ns_per_operation'] / 1000:.3f} -> "
              f"{row['candidate_ns_per_operation'] / 1000:.3f} us/op "
              f"({row['median_change_percent']:+.1f}%), paired ratio "
              f"{row['paired_ratio_median']:.3f}", flush=True)
    return observations, summary, verify_receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=150.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This benchmark uses actual CoreGraphics/CryptoKit/ImageIO implementations and requires macOS")
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even --pairs >= 2 and positive finite --target-ms")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Choose a fresh output directory to preserve previous receipts")
    out.mkdir(parents=True, exist_ok=True)
    if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists():
        print("Kyoto is unavailable on this host; compiling serially in isolated output directories.", flush=True)

    hashes = snapshot_inputs(out)
    swiftc = run(["xcrun", "--find", "swiftc"], out).strip()
    swift = str(Path(swiftc).with_name("swift"))
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], out).strip()
    manifest = {
        "recorded_utc": datetime.now(timezone.utc).isoformat(),
        "commit": run(["git", "rev-parse", "HEAD"], out).strip(),
        "baseline_commit": BASE, "baseline_cache_git_blob": BASE_BLOB,
        "platform": platform.platform(), "machine": platform.machine(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"], out).strip(),
        "python": sys.version, "swiftc": swiftc,
        "swift_version": run([swiftc, "--version"], out).strip(),
        "sdk_version": run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], out).strip(),
        "input_sha256": hashes, "pairs": args.pairs, "target_ms": args.target_ms,
        "swift_deterministic_hashing": os.environ.get("SWIFT_DETERMINISTIC_HASHING"),
        "scope": "Native cache component maintenance; image creation, key creation, initial fill and disk I/O excluded. No playback/UI qualification.",
        "method": "Actual full source files, identical current shared dependencies, pinned baseline cache; separately compiled optimized modules; balanced serial fresh-process AB/BA pairs.",
    }
    write_json(out / "manifest.json", manifest)
    for variant in VARIANTS:
        for configuration in ("debug", "release"):
            test(variant, configuration, swift, out)
    binaries = {variant: build(variant, swiftc, sdk, out) for variant in VARIANTS}
    observations, summary, verification = benchmark(args, binaries, out)
    completion = {
        "component_tests": ["baseline-debug", "baseline-release", "candidate-debug", "candidate-release"],
        "verification": verification, "measurement_pairs": args.pairs, "workloads": len(summary),
        "passed": True,
    }
    write_json(out / "completion.json", completion)
    # A compact, exact receipt survives artifact expiry and can be retrieved
    # through the GitHub connector without downloading binaries or caches.
    evidence = {
        "manifest": manifest, "completion": completion, "summary": summary,
        "observations": observations, "calibration": json.loads((out / "calibration.json").read_text()),
        "commands": COMMANDS,
        "binary_hashes": {variant: json.loads((out / "build" / variant / "hashes.json").read_text())
                          for variant in VARIANTS},
    }
    write_json(out / "evidence.json", evidence)
    print("EVIDENCE_JSON_BEGIN", flush=True)
    print(json.dumps(evidence, sort_keys=True), flush=True)
    print("EVIDENCE_JSON_END", flush=True)


if __name__ == "__main__":
    main()
