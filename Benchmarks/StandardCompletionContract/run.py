#!/usr/bin/env python3
"""Measure exact production completion-contract sources in fresh AB/BA processes."""
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
TARGET = "Sources/IlliquidPlaybackCore/EventsAndEffects.swift"
SCENARIOS = ["defaultEffects", "customEffects", "pendingCheckpoints", "checkpointChurn"]
VARIANTS = ["baseline", "candidate"]
METRICS = ["retainedAllocatorDeltaBytes", "allocationRequests", "requestedBytes", "meteredWallNanoseconds"]
HARNESS_FILES = ["run.py", "Harness.swift", "CCompletionHeap/heap.c", "CCompletionHeap/include/CCompletionHeap.h"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def command(args: list, output: Path, *, log: str | None = None, timeout: int = 900) -> str:
    args = [str(arg) for arg in args]
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"), TERM="dumb", NO_COLOR="1")
    started = time.time()
    result = subprocess.run(args, capture_output=True, env=env, timeout=timeout)
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": args, "returncode": result.returncode,
            "started_unix": started, "seconds": time.time() - started,
            "stdout": stdout, "stderr": stderr}) + "\n")
    if log:
        (output / log).write_text(stdout + stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{stdout}\n{stderr}")
    return stdout


def swift(args: argparse.Namespace, variant: str, operation: str, configuration: str) -> list:
    result = [args.swift, operation, "--package-path", args.output / variant,
        "--configuration", configuration, "--jobs", "2", "--cache-path", args.output / "cache",
        "--config-path", args.output / "config", "--security-path", args.output / "security",
        "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        # Tests have a separate build root so they cannot replace measured modules.
        result += ["--scratch-path", args.output / variant / ".build/tests", "--no-parallel"]
    if platform.system() == "Linux":
        result += ["--use-integrated-swift-driver", "-Xlinker", "--export-dynamic"]
    return result


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / variant
    receipts = {}

    def copy(relative: str, *, destination: str | None = None, baseline_source: bool = False) -> None:
        data = (git("show", f"{baseline}:{relative}") if baseline_source and variant == "baseline"
                else (ROOT / relative).read_bytes())
        target = package / (destination or relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[relative] = {"sha256": sha(data), "destination": str(target.relative_to(package)),
            "source": baseline if baseline_source and variant == "baseline" else "current worktree",
            "transformation": "none"}

    copy("Sources/IlliquidCore/Player/MediaTrack.swift", baseline_source=True)
    for folder in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace"]:
        old = sorted(git("ls-tree", "-r", "--name-only", baseline, "--", folder).decode().splitlines())
        current = sorted(str(p.relative_to(ROOT)) for p in (ROOT / folder).rglob("*.swift"))
        if [p for p in old if p.endswith(".swift")] != current:
            raise ValueError(f"Production file inventory differs: {folder}")
        for relative in current:
            copy(relative, baseline_source=True)
    # Current tests, including the new regression cases, are identical in both arms.
    for folder in ["Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            copy(str(path.relative_to(ROOT)))
    copy("Benchmarks/StandardCompletionContract/Harness.swift",
         destination="Sources/CompletionContractBenchmark/Harness.swift")
    for relative in ["heap.c", "include/CCompletionHeap.h"]:
        copy("Benchmarks/StandardCompletionContract/CCompletionHeap/" + relative,
             destination="Sources/CCompletionHeap/" + relative)
    targets = [
        '.target(name: "IlliquidCore")',
        '.target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"])',
        '.target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"])',
        '.target(name: "CCompletionHeap", publicHeadersPath: "include")',
        '.executableTarget(name: "CompletionContractBenchmark", dependencies: ["IlliquidPlaybackCore", "CCompletionHeap"])',
        '.testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"])',
        '.testTarget(name: "IlliquidPlaybackStateSpaceTests", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"])',
    ]
    manifest = ('// swift-tools-version: 6.1\nimport PackageDescription\n'
        'let package = Package(name: "StandardCompletionContract", platforms: [.macOS("26.0")],\n'
        'products: [.executable(name: "CompletionContractBenchmark", targets: ["CompletionContractBenchmark"])],\n'
        'targets: [\n' + ',\n'.join(targets) + '\n], swiftLanguageModes: [.v6])\n')
    (package / "Package.swift").write_text(manifest)
    receipts["<generated Package.swift>"] = {"sha256": sha(manifest.encode()), "destination": "Package.swift",
        "source": "run.py", "transformation": "generated isolated package"}
    return receipts


def check_observation(row: dict, scenario: str, count: int, semantic: bytes) -> None:
    if row["schema"] != 1 or row["scenario"] != scenario or row["count"] != count:
        raise ValueError("Measurement scenario/count/schema mismatch")
    if row["semanticBytes"] != len(semantic):
        raise ValueError("Semantic byte length mismatch")
    if row["retainedAllocatorDeltaBytes"] != row["allocatorAfterWorkBytes"] - row["allocatorBeforeWorkBytes"]:
        raise ValueError("Allocator delta mismatch")
    receipt = json.loads(semantic)
    if receipt["scenario"] != scenario or receipt["count"] != count or receipt["work"] != row["work"]:
        raise ValueError("Measured work differs from complete semantic replay")
    if receipt["work"]["issued"] != count or len(receipt["effects"]) != count:
        raise ValueError("Incomplete effect workload")
    if not receipt["effectRoundTripEqual"] or not receipt["stateRoundTripEqual"] or receipt["replaySteps"] != 0:
        raise ValueError("Round-trip or replay-disabled verification failed")
    pending = count if scenario == "pendingCheckpoints" else 0
    if receipt["pendingEffects"] != pending or receipt["outstandingEffects"] != pending:
        raise ValueError("Unexpected pending/outstanding effect population")
    if receipt["work"]["completed"] != (count if scenario == "checkpointChurn" else 0):
        raise ValueError("Unexpected completion count")
    for key in ["allocationRequests", "requestedBytes"]:
        if row["allocationMeterAvailable"] != (key in row):
            raise ValueError("Allocation counter availability mismatch")


def summarize(rows: list[dict], counts: list[int], pairs: int) -> list:
    summary = []
    for scenario in SCENARIOS:
        for count in counts:
            cell = [r for r in rows if r["scenario"] == scenario and r["count"] == count]
            expected = {(v, p) for v in VARIANTS for p in range(pairs)}
            if len(cell) != len(expected) or {(r["variant"], r["pair"]) for r in cell} != expected:
                raise ValueError("Incomplete or duplicated balanced pairs")
            metrics = {}
            for metric in METRICS:
                if any(metric not in r for r in cell):
                    continue  # Darwin intentionally has no Linux request counter.
                data = {v: [next(r[metric] for r in cell if r["variant"] == v and r["pair"] == p)
                            for p in range(pairs)] for v in VARIANTS}
                medians = {v: statistics.median(data[v]) for v in VARIANTS}
                savings = [a - b for a, b in zip(data["baseline"], data["candidate"])]
                metrics[metric] = {"baseline_median": medians["baseline"], "candidate_median": medians["candidate"],
                    "baseline_range": [min(data["baseline"]), max(data["baseline"])],
                    "candidate_range": [min(data["candidate"]), max(data["candidate"])],
                    "paired_saving_median": statistics.median(savings),
                    "paired_saving_range": [min(savings), max(savings)]}
            summary.append({"scenario": scenario, "count": count, "pairs": pairs, "metrics": metrics})
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--counts", default="1,128,4096")
    parser.add_argument("--run-tests", action="store_true")
    args = parser.parse_args()
    counts = [int(n) for n in args.counts.split(",")]
    if args.pairs < 2 or args.pairs % 2 or len(set(counts)) != len(counts) or any(n < 1 or n > 8192 for n in counts):
        parser.error("Use an even positive pair count and distinct counts in 1...8192")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("Use a new, empty output directory")
    baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
    manifest = {"schema": 1, "baseline_commit": baseline,
        "candidate_head": git("rev-parse", "HEAD").decode().strip(), "candidate_sources": "current worktree",
        "candidate_status": git("status", "--porcelain=v1").decode().splitlines(),
        "compiler": command([args.swift, "--version"], args.output).strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "method": "exact production sources; balanced AB/BA; fresh processes; release Swift 6",
        "scope": "incremental live allocator bytes after warm-up and Linux successful malloc/calloc/realloc requests",
        "limitations": ["One shared Set persists after first use outside the measured window.",
            "No cold-start, whole-process, RSS, replay-storage or uninstrumented timing claim.",
            "Explicit caller-owned custom contracts remain freshly allocated.",
            "Darwin records allocator live bytes; request counters are Linux/glibc-only."],
        "pairs": args.pairs, "counts": counts, "scenarios": SCENARIOS, "run_tests": args.run_tests,
        "source_hashes": {}, "harness_hashes": {p: sha((HERE / p).read_bytes()) for p in HARNESS_FILES}}
    binaries = {}
    for variant in VARIANTS:
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
    first, second = (manifest["source_hashes"][v] for v in VARIANTS)
    differences = [p for p in first if first[p]["sha256"] != second[p]["sha256"]]
    if differences != [TARGET]:
        raise ValueError(f"The only changed compiled source must be {TARGET}; found {differences}")
    save(args.output / "manifest.json", manifest)
    for variant in VARIANTS:
        print(f"Build {variant} release", flush=True)
        command([*swift(args, variant, "build", "release"), "--product", "CompletionContractBenchmark"],
                args.output, log=f"{variant}-build.log")
        directory = command([*swift(args, variant, "build", "release"), "--show-bin-path"], args.output).strip()
        binaries[variant] = Path(directory) / "CompletionContractBenchmark"
    manifest["binary_hashes"] = {v: sha(p.read_bytes()) for v, p in binaries.items()}
    save(args.output / "manifest.json", manifest)
    rows, references = [], {}
    (args.output / "semantics").mkdir()
    for scenario in SCENARIOS:
        for count in counts:
            print(f"Measure {scenario}: {count} effects, {args.pairs} AB/BA pairs", flush=True)
            reference = None
            relative = f"semantics/{scenario}-{count}.json.gz"
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else list(reversed(VARIANTS))
                for variant in order:
                    temporary = args.output / "semantic-current.json"
                    row = json.loads(command([binaries[variant], scenario, count, temporary], args.output))
                    semantic = temporary.read_bytes()
                    temporary.unlink()
                    check_observation(row, scenario, count, semantic)
                    if reference is None:
                        reference = semantic
                        compressed = gzip.compress(semantic, compresslevel=9, mtime=0)
                        (args.output / relative).write_bytes(compressed)
                        references[relative] = {"sha256": sha(semantic), "bytes": len(semantic),
                            "gzip_sha256": sha(compressed), "gzip_bytes": len(compressed)}
                    elif semantic != reference:
                        raise ValueError(f"Complete canonical output/state differs: {scenario} {count} pair {pair} {variant}")
                    row.update(variant=variant, pair=pair, pairOrder=order,
                               semanticSHA256=sha(semantic), semanticReference=relative)
                    rows.append(row)
                    save(args.output / "observations.json", rows)
    save(args.output / "summary.json", summarize(rows, counts, args.pairs))
    verification = {"canonical_output_and_state_equal": True, "observations": len(rows),
                    "semantic_references": references, "tests": []}
    save(args.output / "verification.json", verification)
    print("All complete canonical effect/state bytes match across every fresh process", flush=True)
    if args.run_tests:
        for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
            print(f"Test {variant} {configuration}: full core and state-space suites", flush=True)
            log = f"{variant}-{configuration}-tests.log"
            command(swift(args, variant, "test", configuration), args.output, log=log)
            verification["tests"].append({"variant": variant, "configuration": configuration,
                                          "log": log, "sha256": sha((args.output / log).read_bytes()), "passed": True})
            save(args.output / "verification.json", verification)
    for variant in VARIANTS:
        for relative, receipt in manifest["source_hashes"][variant].items():
            if sha((args.output / variant / receipt["destination"]).read_bytes()) != receipt["sha256"]:
                raise ValueError(f"Staged source changed during run: {variant} {relative}")
            if receipt["source"] == "current worktree" and sha((ROOT / relative).read_bytes()) != receipt["sha256"]:
                raise ValueError(f"Measured worktree source changed during run: {relative}")
    for relative, digest in manifest["harness_hashes"].items():
        if sha((HERE / relative).read_bytes()) != digest:
            raise ValueError(f"Harness changed during run: {relative}")
    if any(sha(p.read_bytes()) != manifest["binary_hashes"][v] for v, p in binaries.items()):
        raise ValueError("Measured binary changed during run")
    verification["sources_and_binaries_unchanged"] = True
    verification["complete"] = True
    save(args.output / "verification.json", verification)
    print(f"Complete evidence: {args.output}", flush=True)


if __name__ == "__main__":
    main()
