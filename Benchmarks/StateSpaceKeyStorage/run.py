#!/usr/bin/env python3
"""Measure exact production search modules in paired, fresh optimized processes."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
EXPLORER = "Sources/IlliquidPlaybackStateSpace/PlaybackStateSpaceExplorer.swift"
MODELS = [
    ("seek", "ready-playing"), ("eof-drain", "playing-av"),
    ("recovery", "playing-hardware"), ("track-subtitles", "automatic"),
    ("stop-shutdown", "playing"), ("preroll-buffering", "opening-av"),
]


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def command(arguments: list, output: Path, *, name: str | None = None,
            timeout: int = 1800) -> str:
    arguments = [str(argument) for argument in arguments]
    environment = os.environ.copy()
    environment.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
                       SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
                       TERM="dumb", NO_COLOR="1")
    # Keep native randomized hashing enabled. Semantic comparison decodes Set
    # and Dictionary values rather than relying on their serialization order.
    environment.pop("SWIFT_DETERMINISTIC_HASHING", None)
    started = time.time()
    result = subprocess.run(arguments, capture_output=True, env=environment, timeout=timeout)
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": arguments, "started_unix": started,
                                 "seconds": time.time() - started, "returncode": result.returncode,
                                 "stdout": stdout, "stderr": stderr}) + "\n")
    if name:
        (output / name).write_text(stdout + stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments}\n{stdout}\n{stderr}")
    return stdout


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / "packages" / variant
    receipts = {}
    paths = ["Sources/IlliquidCore/Player/MediaTrack.swift"]
    for folder in ("Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace"):
        listed = (git("ls-tree", "-r", "--name-only", baseline, "--", folder).decode().splitlines()
                  if variant == "baseline" else
                  [str(path.relative_to(ROOT)) for path in sorted((ROOT / folder).rglob("*.swift"))])
        paths.extend(path for path in listed if path.endswith(".swift"))
    for relative in paths:
        data = (git("show", f"{baseline}:{relative}") if variant == "baseline"
                else (ROOT / relative).read_bytes())
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[relative] = {"sha256": sha256(data), "transformation": "none"}
    for source, destination in [
        (HERE / "Harness.swift", package / "Sources/SearchBenchmark/Harness.swift"),
        (HERE / "CSearchMemory/memory.c", package / "Sources/CSearchMemory/memory.c"),
        (HERE / "CSearchMemory/include/CSearchMemory.h", package / "Sources/CSearchMemory/include/CSearchMemory.h"),
    ]:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "StateSpaceKeyStorage", platforms: [.macOS("26.0")],
  products: [.executable(name: "SearchBenchmark", targets: ["SearchBenchmark"])],
  targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
    .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
    .target(name: "CSearchMemory", publicHeadersPath: "include"),
    .executableTarget(name: "SearchBenchmark", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace", "CSearchMemory"]),
  ], swiftLanguageModes: [.v6])
'''
    (package / "Package.swift").write_text(manifest)
    return receipts


def metrics(row: dict) -> dict:
    before = row["beforeSearch"]
    after = row["afterSearchWithResultAlive"]
    sampled = [before] + [progress["memory"] for progress in row["progress"]]
    return {
        "progress_peak_live_allocator_delta_bytes": max(value["liveAllocatorBytes"] for value in sampled) - before["liveAllocatorBytes"],
        "progress_peak_current_rss_bytes": max(value["currentRSSBytes"] for value in sampled),
        "progress_peak_physical_footprint_bytes": max(value["physicalFootprintBytes"] for value in sampled),
        "whole_search_peak_rss_bytes": after["peakRSSBytes"],
        "result_live_allocator_delta_bytes": after["liveAllocatorBytes"] - before["liveAllocatorBytes"],
        "search_wall_nanoseconds": row["searchWallNanoseconds"],
        "search_cpu_nanoseconds": row["searchCPUNanoseconds"],
    }


def run_pair(args: argparse.Namespace, binaries: dict, cohort: dict, pair: int,
             order: list[str], *, preserve: bool) -> dict:
    stem = f'{cohort["name"]}-pair-{pair}'
    rows = {}
    prefixes = {}
    for variant in order:
        prefix = args.output / "transient-receipts" / f"{stem}-{variant}"
        prefixes[variant] = prefix
        row = json.loads(command([
            binaries[variant], cohort["model"], cohort["seed"], cohort["cap"],
            cohort["depth"], prefix, cohort["oracle"],
        ], args.output))
        required = ["liveAllocatorBytes", "currentRSSBytes", "peakRSSBytes"]
        if platform.system() == "Darwin":
            required.append("physicalFootprintBytes")
        for sample in [row["beforeSearch"], row["afterSearchWithResultAlive"]] + [value["memory"] for value in row["progress"]]:
            if any(sample[metric] <= 0 for metric in required):
                raise AssertionError(f"Unavailable memory sampler in {stem}/{variant}: {sample}")
        if row["searchWallNanoseconds"] <= 0 or row["searchCPUNanoseconds"] <= 0:
            raise AssertionError(f"Unavailable clock sampler in {stem}/{variant}")
        row.update(variant=variant, cohort=cohort["name"], pair=pair, order=order)
        row["metrics"] = metrics(row)
        rows[variant] = row
        with (args.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(row) + "\n")
    if rows["baseline"]["summary"] != rows["candidate"]["summary"]:
        raise AssertionError(f"Search summary drift: {stem}")
    if cohort["oracle"] == "production" and any(row["failureCount"] for row in rows.values()):
        raise AssertionError(f"Unexpected production invariant failure: {stem}")
    if cohort["performance"] and rows["baseline"]["summary"]["stateCount"] != cohort["cap"]:
        raise AssertionError(f"Performance cohort did not reach its requested state count: {stem}")
    comparison = json.loads(command([
        binaries["candidate"], "--compare", prefixes["baseline"], prefixes["candidate"],
    ], args.output))
    receipts = {}
    for variant, prefix in prefixes.items():
        receipts[variant] = {}
        for suffix in (".result.json", ".nodes.jsonl"):
            path = Path(str(prefix) + suffix)
            receipts[variant][suffix] = {"sha256": file_hash(path), "bytes": path.stat().st_size}
            if preserve:
                destination = args.output / "control-receipts" / (path.name + ".gz")
                destination.parent.mkdir(parents=True, exist_ok=True)
                with path.open("rb") as source, gzip.open(destination, "wb") as sink:
                    shutil.copyfileobj(source, sink)
            path.unlink()
    result = {"cohort": cohort, "pair": pair, "order": order, "comparison": comparison,
              "summary": rows["baseline"]["summary"], "raw_receipts": receipts,
              "baseline_metrics": rows["baseline"]["metrics"],
              "candidate_metrics": rows["candidate"]["metrics"]}
    with (args.output / "comparisons.jsonl").open("a") as stream:
        stream.write(json.dumps(result) + "\n")
    print(f'{stem}: exact parity ({comparison["comparedNodes"]} nodes), '
          f'wall baseline/candidate {rows["baseline"]["searchWallNanoseconds"]/1e9:.3f}/'
          f'{rows["candidate"]["searchWallNanoseconds"]/1e9:.3f}s', flush=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--caps", default="1000,10000,50000")
    parser.add_argument("--skip-controls", action="store_true", help="Exploratory prototype only")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    caps = [int(value) for value in args.caps.split(",")]
    if args.pairs < 1 or not caps or any(cap < 1 for cap in caps) or len(set(caps)) != len(caps):
        raise ValueError("pairs and unique caps must be positive")
    baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
    manifest = {
        "baseline_commit": baseline, "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "candidate_sources": "current worktree", "platform": platform.platform(), "machine": platform.machine(),
        "compiler": command([args.swift, "--version"], args.output).strip(),
        "pairs": args.pairs, "caps": caps, "controls_skipped": args.skip_controls,
        "scope": "Exact bounded playback state-space developer tool; not video playback or full app memory.",
        "method": "Fresh optimized processes, alternating AB/BA, full typed semantic comparison after timed search.",
        "source_hashes": {}, "harness_hashes": {
            str(path.relative_to(HERE)): file_hash(path) for path in sorted(HERE.rglob("*"))
            if path.is_file() and path.suffix in {".swift", ".c", ".h", ".py"}},
        "metric_notes": {
            "live_allocator": "Darwin malloc_zone_statistics(NULL) all zones; Linux mallinfo2 prototype only.",
            "progress": "Completed BFS-layer callbacks only; maximum is a lower bound and excludes a capped partial layer and digest.",
            "whole_search_peak_rss": "getrusage process high-water mark sampled immediately after run, before JSON; includes startup, final digest, teardown.",
            "after_search": "Result remains alive; local visited/key storage has been released. Not evidence of in-search savings.",
            "timing": "Search including sampler callbacks and final digest; excludes all receipt encoding/comparison/replay.",
            "physical_footprint": "TASK_VM_INFO.phys_footprint on Darwin; zero/unavailable on Linux.",
            "payload_sharing": "The eliminated array duplicates inline key values/capacity; nested String/Array buffers already shared via copy-on-write.",
        },
    }
    binaries = {}
    for variant in ("baseline", "candidate"):
        print(f"Stage and build {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
        save(args.output / "manifest.json", manifest)
        build = [args.swift, "build", "--package-path", args.output / "packages" / variant,
                 "--configuration", "release", "--jobs", "2",
                 "--cache-path", args.output / "cache", "--config-path", args.output / "config",
                 "--security-path", args.output / "security", "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux":
            build.append("--use-integrated-swift-driver")
        command([*build, "--product", "SearchBenchmark"], args.output, name=f"{variant}-build.log")
        binaries[variant] = Path(command([*build, "--show-bin-path"], args.output).strip()) / "SearchBenchmark"
    hashes = manifest["source_hashes"]
    changed = {path for path in set(hashes["baseline"]) | set(hashes["candidate"])
               if hashes["baseline"].get(path) != hashes["candidate"].get(path)}
    if changed != {EXPLORER}:
        raise AssertionError(f"Unexpected production changes: {sorted(changed)}")
    manifest["changed_production_paths"] = sorted(changed)
    manifest["binary_hashes"] = {variant: file_hash(binary) for variant, binary in binaries.items()}
    save(args.output / "manifest.json", manifest)
    (args.output / "transient-receipts").mkdir()
    comparisons = []
    if not args.skip_controls:
        controls = [{"name": f"control-{model}", "model": model, "seed": seed,
                     "cap": 10_000, "depth": 2, "oracle": "production", "performance": False}
                    for model, seed in MODELS]
        controls += [
            {"name": "seed-only", "model": "seek", "seed": "ready-playing", "cap": 1,
             "depth": 0, "oracle": "production", "performance": False},
            {"name": "failure-replay", "model": "seek", "seed": "ready-playing", "cap": 10_000,
             "depth": 2, "oracle": "stop", "performance": False},
        ]
        for index, cohort in enumerate(controls):
            comparisons.append(run_pair(args, binaries, cohort, 0,
                ["baseline", "candidate"] if index % 2 == 0 else ["candidate", "baseline"], preserve=True))
    for cohort_index, cap in enumerate(caps):
        cohort = {"name": f"seek-cap-{cap}", "model": "seek", "seed": "ready-playing",
                  "cap": cap, "depth": 12, "oracle": "production", "performance": True}
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if (pair + cohort_index) % 2 == 0 else ["candidate", "baseline"]
            comparisons.append(run_pair(args, binaries, cohort, pair, order, preserve=False))
    aggregates = []
    for cap in caps:
        rows = [row for row in comparisons if row["cohort"]["name"] == f"seek-cap-{cap}"]
        aggregate = {"cohort": rows[0]["cohort"], "pairs": len(rows), "summary": rows[0]["summary"], "metrics": {}}
        for metric in rows[0]["baseline_metrics"]:
            first = [row["baseline_metrics"][metric] for row in rows]
            second = [row["candidate_metrics"][metric] for row in rows]
            aggregate["metrics"][metric] = {
                "baseline_median": statistics.median(first), "candidate_median": statistics.median(second),
                "paired_savings_median": statistics.median(a - b for a, b in zip(first, second)),
                "paired_savings_min": min(a - b for a, b in zip(first, second)),
                "paired_savings_max": max(a - b for a, b in zip(first, second)),
            }
        aggregates.append(aggregate)
    # Guard the exact staged code and its worktree origin after all measurements.
    for variant, files in hashes.items():
        for relative, receipt in files.items():
            if file_hash(args.output / "packages" / variant / relative) != receipt["sha256"]:
                raise AssertionError(f"Staged source changed during benchmark: {variant}/{relative}")
            if variant == "candidate" and file_hash(ROOT / relative) != receipt["sha256"]:
                raise AssertionError(f"Candidate source changed during benchmark: {relative}")
    for relative, digest in manifest["harness_hashes"].items():
        if file_hash(HERE / relative) != digest:
            raise AssertionError(f"Harness changed during benchmark: {relative}")
    summary = {"scope": manifest["scope"], "metric_notes": manifest["metric_notes"],
               "exact_comparisons_passed": len(comparisons),
               "full_nodes_compared": sum(row["comparison"]["comparedNodes"] for row in comparisons),
               "source_integrity_verified": True, "aggregates": aggregates}
    save(args.output / "summary.json", summary)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
