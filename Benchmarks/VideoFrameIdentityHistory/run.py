#!/usr/bin/env python3
"""Compare bounded video frame-identity histories on native macOS."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import shutil
import statistics
import subprocess
import sys
import textwrap
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "Sources/IlliquidNativePlayback/Presentation/VideoFrameIdentityHistory.swift"
PRESENTER = ROOT / "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
TEST = ROOT / "Tests/IlliquidNativePlaybackTests/VideoFrameIdentityHistoryTests.swift"
CASES = ["steady-append", "append-lookup", "cold-fill", "flush-refill",
         "lookup-newest", "lookup-middle", "lookup-oldest", "lookup-missing",
         "lookup-surface-reuse", "adjacent-forward", "adjacent-backward"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def append(path: Path, data: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(data, sort_keys=True) + "\n")


def command(args: list, output: Path, *, log: str | None = None) -> str:
    args = [str(value) for value in args]
    start = time.time()
    completed = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    append(output / "commands.jsonl", {"command": args, "returncode": completed.returncode,
                                      "elapsed_seconds": time.time() - start})
    if log:
        (output / log).write_text(completed.stdout)
    if completed.returncode:
        (output / "failure.txt").write_text(completed.stdout)
        raise RuntimeError(f"Command failed ({completed.returncode}): {args}\n{completed.stdout}")
    return completed.stdout


def between(source: str, start: str, end: str) -> str:
    if source.count(start) != 1:
        raise RuntimeError(f"Baseline extraction anchor changed: {start!r}")
    remainder = source.split(start, 1)[1]
    if end not in remainder:
        raise RuntimeError(f"Baseline extraction end changed: {end!r}")
    return remainder.split(end, 1)[0]


def adapted_baseline() -> str:
    source = (HERE / "baseline/SampleBufferVideoPresenter.swift").read_text()
    declaration = "    struct FrameIdentity: Sendable {" + between(
        source, "    struct FrameIdentity: Sendable {", "\n    private let identityLock")
    adjacent = between(source,
        "    func adjacentTime(to frame: FrameIdentity, direction: Int) -> Double? {\n        identityLock.withLock {\n",
        "\n        }\n    }\n\n    func identity(")
    lookup = between(source, "        return identityLock.withLock {\n",
                     "\n        }\n    }\n\n    let displayLayer")
    enqueue = between(source,
        "        identityLock.withLock {\n            if frameIdentities.count == 128",
        "\n        }\n        withNativeVideoSignpost(\"VideoRendererEnqueue\")")
    enqueue = "            if frameIdentities.count == 128" + enqueue
    clear = between(source, "identityLock.withLock { frameIdentities.removeAll(",
                    ") }\n        renderer.flush")
    return (
        "import Foundation\n\nstruct VideoFrameIdentityHistory: Sendable {\n" + declaration +
        "\n    private var frameIdentities: [FrameIdentity] = []\n\n"
        "    func adjacentTime(to frame: FrameIdentity, direction: Int) -> Double? {\n" +
        textwrap.indent(textwrap.dedent(adjacent), "        ") + "\n    }\n\n"
        "    func identity(surfaceID: UInt32?, bufferID: UInt) -> FrameIdentity? {\n"
        "        let surface = surfaceID\n" +
        textwrap.indent("return " + textwrap.dedent(lookup), "        ") + "\n    }\n\n"
        "    mutating func append(_ identity: FrameIdentity) {\n" +
        textwrap.indent(textwrap.dedent(enqueue), "        ") + "\n    }\n\n"
        "    mutating func removeAll() {\n"
        "        frameIdentities.removeAll(" + clear + ")\n    }\n}\n"
    )


def stage(variant: str, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    path = destination / "VideoFrameIdentityHistory.swift"
    path.write_text(adapted_baseline() if variant == "baseline" else SOURCE.read_text())
    return path


def tests(variant: str, work: Path, output: Path) -> None:
    package = work / f"tests-{variant}"
    stage(variant, package / "Sources/IlliquidNativePlayback")
    target = package / "Tests/IlliquidNativePlaybackTests"
    target.mkdir(parents=True)
    shutil.copyfile(TEST, target / TEST.name)
    (package / "Package.swift").write_text(
        '// swift-tools-version: 6.1\nimport PackageDescription\n'
        'let package = Package(name: "VideoFrameIdentityHistory", platforms: [.macOS("26.0")], targets: ['
        '.target(name: "IlliquidNativePlayback"),'
        '.testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])])\n')
    for configuration in ("debug", "release"):
        command(["swift", "test", "--package-path", package, "--jobs", "2", "--no-parallel",
                 "-c", configuration, "-Xswiftc", "-warnings-as-errors"], output,
                log=f"{variant}-{configuration}-tests.txt")
        print(f"{variant} {configuration} tests passed", flush=True)


def build(variant: str, work: Path, output: Path) -> Path:
    directory = work / variant
    source = stage(variant, directory / "sources")
    library = directory / "libIlliquidNativePlayback.dylib"
    flags = ["-swift-version", "6", "-O", "-warnings-as-errors"]
    command(["swiftc", *flags, "-whole-module-optimization", "-enable-testing",
             "-emit-library", "-emit-module", "-module-name", "IlliquidNativePlayback",
             "-emit-module-path", directory / "IlliquidNativePlayback.swiftmodule",
             source, "-o", library], output, log=f"{variant}-library-build.txt")
    binary = directory / "benchmark"
    command(["swiftc", *flags, "-parse-as-library", "-I", directory, "-L", directory,
             "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", directory,
             HERE / "Driver.swift", "-o", binary], output, log=f"{variant}-driver-build.txt")
    return binary


def measure(binary: Path, case: str, iterations: int, seed: int, output: Path) -> dict:
    row = json.loads(command([binary, case, iterations, seed], output))
    if row["case"] != case or row["iterations"] != iterations or row["seed"] != seed:
        raise RuntimeError("Benchmark invocation/receipt mismatch")
    if row["elapsed_ns"] <= 0 or row["operations_per_iteration"] != 1:
        raise RuntimeError("Invalid timing or work-unit count")
    receipt = row.pop("receipt")
    encoded = json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()
    row["receipt_sha256"] = digest(encoded)
    receipts = output / "receipts"
    receipts.mkdir(exist_ok=True)
    save(receipts / f"{binary.parent.name}-{case}-{seed}-{iterations}.json", receipt)
    return row


def summarize(rows: list[dict]) -> dict:
    result = {}
    for case in dict.fromkeys(row["case"] for row in rows):
        subset = [row for row in rows if row["case"] == case]
        result[case] = {}
        for metric, field in (("wall", "elapsed_ns"), ("cpu", "cpu_ns")):
            values = {variant: [r[field] / r["iterations"] for r in subset if r["variant"] == variant]
                      for variant in ("baseline", "candidate")}
            medians = {v: statistics.median(samples) for v, samples in values.items()}
            reductions = []
            for pair in sorted({r["pair"] for r in subset}):
                paired = {r["variant"]: r for r in subset if r["pair"] == pair}
                for key in ("checksum", "warmup_checksum", "receipt_sha256", "iterations", "seed"):
                    if paired["baseline"][key] != paired["candidate"][key]:
                        raise RuntimeError(f"Pair mismatch: {case}, pair {pair}, {key}")
                reductions.append(100 * (1 - paired["candidate"][field] / paired["baseline"][field]))
            result[case][metric] = {
                **{v: {"median_ns": medians[v], "min_ns": min(values[v]), "max_ns": max(values[v])}
                   for v in values},
                "median_reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                "paired_reduction_percent": {"median": statistics.median(reductions), "min": min(reductions),
                    "max": max(reductions), "candidate_faster_pairs": sum(v > 0 for v in reductions),
                    "pairs": len(reductions)},
            }
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--max-sample-ms", type=float, default=2000)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    cases = args.cases.split(",")
    if sys.platform != "darwin":
        parser.error("Use native macOS with Swift 6.1+")
    if (args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or
            args.max_sample_ms < args.target_ms or len(cases) != len(set(cases)) or
            any(case not in CASES for case in cases)):
        parser.error("Use an even pair count, valid unique cases and positive timing bounds")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Use a new empty output directory")
    work = output / "build"
    work.mkdir()
    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    frozen = HERE / "baseline/SampleBufferVideoPresenter.swift"
    if digest(frozen.read_bytes()) != baseline["sha256"]:
        raise RuntimeError("Frozen baseline hash mismatch")
    adapted = adapted_baseline()
    (output / "adapted-baseline.swift.txt").write_text(adapted)
    manifest = {
        "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift": command(["swiftc", "--version"], output).strip(),
        "macos": command(["sw_vers"], output).strip(),
        "hardware": command(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip(),
        "sdk": command(["xcrun", "--show-sdk-version"], output).strip(),
        "git_head": command(["git", "-C", ROOT, "rev-parse", "HEAD"], output).strip(),
        "git_status": command(["git", "-C", ROOT, "status", "--porcelain"], output).strip(),
        "arguments": {**vars(args), "output": str(output)}, "baseline": baseline,
        "sha256": {"baseline_adapter": digest(adapted.encode()), "candidate_helper": digest(SOURCE.read_bytes()),
                   "candidate_presenter": digest(PRESENTER.read_bytes()), "tests": digest(TEST.read_bytes()),
                   "driver": digest((HERE / "Driver.swift").read_bytes()), "runner": digest(Path(__file__).read_bytes())},
        "method": "Separate optimized module and identical driver; balanced fresh-process AB/BA pairs; "
                  "same iterations/seed; warmup and complete reference receipts outside timing; no discarded samples.",
        "scope": "History component CPU/wall time, excluding NSLock, native pixel-buffer identity extraction, "
                 "sample construction, rendering, decoder throughput, whole-player CPU and energy.",
    }
    save(output / "manifest.json", manifest)
    try:
        if args.tests_only:
            for variant in ("baseline", "candidate"):
                tests(variant, work, output)
            save(output / "tests.json", {f"{v}_{c}": "passed" for v in ("baseline", "candidate")
                                        for c in ("debug", "release")})
            return
        binaries = {variant: build(variant, work, output) for variant in ("baseline", "candidate")}
        manifest["binary_sha256"] = {
            variant: {p.name: digest(p.read_bytes()) for p in binary.parent.iterdir()
                      if p.is_file() and (p.name == "benchmark" or p.suffix == ".dylib")}
            for variant, binary in binaries.items()}
        save(output / "manifest.json", manifest)
        rows = []
        for case in cases:
            costs = {}
            for variant, binary in binaries.items():
                first = measure(binary, case, 1, 1000, output)
                count = max(1, min(100000, math.ceil(20_000_000 / first["elapsed_ns"])))
                probe = measure(binary, case, count, 1000, output)
                costs[variant] = probe["elapsed_ns"] / count
                append(output / "calibration.jsonl", {"variant": variant, "stage": "single", **first})
                append(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **probe})
            iterations = max(1, min(math.ceil(1.5 * args.target_ms * 1e6 / min(costs.values())),
                                    math.floor(args.max_sample_ms * 1e6 / max(costs.values()))))
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = measure(binaries[variant], case, iterations, 2000 + pair, output)
                    if row["cpu_ns"] <= 0:
                        raise RuntimeError("Nonpositive final CPU timing")
                    row.update(variant=variant, pair=pair, position=position)
                    rows.append(row)
                    append(output / "measurements.jsonl", row)
                summarize(rows[-2:])
            summary = summarize(rows)
            save(output / "summary.json", summary)
            print(case, json.dumps(summary[case], sort_keys=True), flush=True)
        save(output / "verification.json", {
            "all_pairs_equal": True, "records": len(rows), "cases": len(cases), "pairs_per_case": args.pairs,
            "minimum_wall_sample_ms": min(row["elapsed_ns"] for row in rows) / 1e6,
            "samples_below_target": sum(row["elapsed_ns"] < args.target_ms * 1e6 for row in rows)})
    except Exception as error:
        save(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
