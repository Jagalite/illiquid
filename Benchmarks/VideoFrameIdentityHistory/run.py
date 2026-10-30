#!/usr/bin/env python3
"""Paired scalar frame-history measurements; does not build or time the player."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PRESENTER = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
HELPER = "Sources/IlliquidNativePlayback/Presentation/VideoFrameIdentityHistory.swift"
OPERATIONS = ["append", "append-lookup", "lookup-newest", "lookup-oldest", "lookup-miss",
              "adjacent-forward", "adjacent-backward", "flush-0", "flush-1", "flush-64", "flush-128", "flush-256"]


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path, value):
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


class Run:
    def __init__(self, output):
        self.output, self.number = output, 0
        (output / "logs").mkdir()

    def command(self, args, label):
        self.number += 1
        log = self.output / "logs" / f"{self.number:04d}-{label}.log"
        started = time.monotonic()
        env = os.environ.copy()
        env.pop("LD_PRELOAD", None)
        result = subprocess.run([str(a) for a in args], cwd=ROOT, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_bytes(result.stdout)
        append(self.output / "commands.jsonl", dict(args=[str(a) for a in args], cwd=str(ROOT),
               returncode=result.returncode, elapsed_seconds=time.monotonic() - started,
               log=str(log.relative_to(self.output))))
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): see {log}")
        return result.stdout.decode().strip()


def stage(run, manifest):
    directory = run.output / "sources"
    directory.mkdir()
    tracked = {}
    original = subprocess.check_output(["git", "show", f"{BASELINE}:{PRESENTER}"], cwd=ROOT)
    (directory / "OriginalPresenter.swift").write_bytes(original)
    baseline = (HERE / "Baseline.swift").read_text()
    # Verify the frozen baseline's operation statements against the pinned
    # presenter, ignoring indentation only. Renderer creation and extraction of
    # IOSurface/buffer IDs are deliberately outside this scalar experiment.
    def compact(value):
        return " ".join(value.split())
    blocks = [
        "if frameIdentities.count == 128 { frameIdentities.removeFirst() } frameIdentities.append(identity)",
        "frameIdentities.last { if let surface { return $0.surfaceID == surface } return $0.bufferID == bufferID }",
        "let times = frameIdentities.lazy.filter { $0.generation == frame.generation }.map(\\.time) "
        "return direction > 0 ? times.filter { $0 > frame.time + 0.000001 }.min() "
        ": times.filter { $0 < frame.time - 0.000001 }.max()",
        "frameIdentities.removeAll(keepingCapacity: true)",
    ]
    for block in blocks:
        if compact(block) not in compact(original.decode()) or compact(block) not in compact(baseline):
            raise RuntimeError("Frozen baseline no longer matches original operation statements")
    manifest["baseline_presenter"] = dict(commit=BASELINE, path=PRESENTER, sha256=sha(original))
    manifest["sources"] = {}
    for path in [ROOT / HELPER, HERE / "Baseline.swift", HERE / "Bridge.swift", HERE / "Driver.swift", HERE / "run.py"]:
        raw = path.read_bytes()
        snapshot = directory / path.name
        snapshot.write_bytes(raw)
        tracked[path] = tracked[snapshot] = sha(raw)
        manifest["sources"][str(path.relative_to(ROOT))] = sha(raw)
    tracked[directory / "OriginalPresenter.swift"] = sha(original)
    return tracked


def build(run, manifest, swiftc):
    native = sys.platform == "darwin"
    sdk_flags = []
    if native:
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")
        sdk_flags = ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
    binaries, products = {}, {}
    for variant in ("baseline", "candidate"):
        folder = run.output / "build" / variant
        folder.mkdir(parents=True)
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
                 "-module-cache-path", folder / "module-cache", *sdk_flags]
        source = run.output / "sources" / ("Baseline.swift" if variant == "baseline" else "VideoFrameIdentityHistory.swift")
        library = folder / ("libFrameHistoryBenchmark.dylib" if native else "libFrameHistoryBenchmark.so")
        run.command([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "FrameHistoryBenchmark",
                     "-emit-module-path", folder / "FrameHistoryBenchmark.swiftmodule",
                     source, run.output / "sources/Bridge.swift", "-o", library], f"build-{variant}-module")
        binary = folder / "driver"
        define = ["-D", "CANDIDATE"] if variant == "candidate" else []
        run.command([swiftc, *flags, *define, "-parse-as-library", "-I", folder, "-L", folder,
                     "-lFrameHistoryBenchmark", "-Xlinker", "-rpath", "-Xlinker", folder,
                     run.output / "sources/Driver.swift", "-o", binary], f"build-{variant}-driver")
        binaries[variant] = binary
        for path in [library, binary]:
            products[path] = sha(path.read_bytes())
    manifest["products"] = {str(p.relative_to(run.output)): digest for p, digest in products.items()}
    return binaries, products


def measure(run, binaries, args, summary):
    operations = ["append", "append-lookup", "lookup-oldest", "adjacent-forward", "flush-256"] if args.quick else OPERATIONS
    cases = [dict(id=f"{lock}/{operation}", operation=operation, lock_mode=lock,
                  initial_count=384, initial_rotation=0)
             for lock in ["unlocked", "locked"] for operation in operations]
    # Read-only queries keep a fixed layout throughout their interval. Include
    # a nonzero rotation rather than qualifying only the contiguous-array path.
    wrapped_queries = (["lookup-oldest", "adjacent-forward"] if args.quick else
                       ["lookup-newest", "lookup-oldest", "lookup-miss", "adjacent-forward", "adjacent-backward"])
    cases += [dict(id=f"{lock}/{operation}/rotation-17", operation=operation, lock_mode=lock,
                   initial_count=401, initial_rotation=17)
              for lock in ["unlocked", "locked"] for operation in wrapped_queries]
    save(run.output / "workloads.json", cases)
    references = {}
    observations = 0

    def sample(variant, case, iterations, label):
        row = json.loads(run.command([binaries[variant], case["operation"], case["lock_mode"],
                                      iterations, case["initial_count"]], label))
        for key, value in dict(variant=variant, operation=case["operation"], lock_mode=case["lock_mode"],
                              iterations=iterations, initial_count=case["initial_count"],
                              initial_rotation=case["initial_rotation"], oracle_passed=True).items():
            if row.get(key) != value:
                raise RuntimeError(f"Invalid observation {key}: {row}")
        signature = tuple(row[key] for key in ("state_fingerprint", "state_count", "checksum", "identity_stride"))
        key = (case["id"], iterations)
        if key in references and references[key] != signature:
            raise RuntimeError(f"Baseline/candidate state parity failed: {case['id']}")
        references[key] = signature
        row["workload"] = case["id"]
        return row

    for case in cases:
        iterations = 1_024
        for _ in range(5):
            row = sample("baseline", case, iterations, "calibration")
            append(run.output / "calibration.jsonl", row)
            if row["wall_ns"] >= args.target_ms * 500_000 or iterations >= 20_000_000:
                break
            iterations = min(20_000_000, max(iterations + 1,
                math.ceil(iterations * args.target_ms * 1_000_000 / max(1, row["wall_ns"]))))
        rows = []
        for pair in range(args.pairs):
            variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for position, variant in enumerate(variants):
                row = sample(variant, case, iterations, "measurement")
                row.update(pair=pair, order_position=position)
                append(run.output / "observations.jsonl", row)
                rows.append(row)
                observations += 1
        result = dict(case, iterations=iterations, pairs=args.pairs, identity_stride=rows[0]["identity_stride"])
        for metric in ["wall_ns", "cpu_ns"]:
            result[metric] = {}
            for variant in ["baseline", "candidate"]:
                values = [r[metric] / iterations for r in rows if r["variant"] == variant]
                result[metric][variant] = dict(median=statistics.median(values), min=min(values), max=max(values), values=values)
            pairs = []
            for pair in range(args.pairs):
                a, b = [next(r[metric] for r in rows if r["pair"] == pair and r["variant"] == v)
                        for v in ["baseline", "candidate"]]
                pairs.append(100 * (1 - b / a))
            result[metric]["paired_reduction_percent"] = dict(median=statistics.median(pairs), min=min(pairs), max=max(pairs), values=pairs)
        result["minimum_measured_wall_ms"] = min(r["wall_ns"] for r in rows) / 1_000_000
        summary["workloads"].append(result)
        save(run.output / "summary.json", summary)
        print(json.dumps(result, sort_keys=True), flush=True)
    return observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=60)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target duration")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be new or empty")
    run = Run(output)
    manifest = dict(baseline=BASELINE, platform=platform.platform(), architecture=platform.machine(),
                    cpu_count=os.cpu_count(), python_version=platform.python_version(),
                    timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    arguments=vars(args) | {"output": str(output)},
                    boundary="scalar history plus optional uncontended NSLock and shared opaque call boundary",
                    exclusions="renderer, decoding, pixel buffers, contention, heap/RSS and full-player performance")
    summary = dict(status="running", baseline=BASELINE, workloads=[])
    try:
        swiftc = shutil.which("swiftc")
        if not swiftc:
            raise RuntimeError("swiftc must be on PATH")
        manifest["swift_version"] = run.command([swiftc, "--version"], "swift-version")
        manifest["candidate_head"] = run.command(["git", "rev-parse", "HEAD"], "head")
        manifest["worktree_status"] = run.command(["git", "status", "--short"], "status")
        tracked = stage(run, manifest)
        save(output / "manifest.json", manifest)
        binaries, products = build(run, manifest, swiftc)
        save(output / "manifest.json", manifest)
        observation_count = measure(run, binaries, args, summary)
        for path, expected in (tracked | products).items():
            if sha(path.read_bytes()) != expected:
                raise RuntimeError(f"Measured source or binary changed during run: {path}")
        summary["status"] = "passed"
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)
    save(output / "completion.json", dict(finished=True, source_binary_identity_passed=True,
         workload_count=len(summary["workloads"]), observation_count=observation_count,
         all_oracles_passed=True, pairs=args.pairs))


if __name__ == "__main__":
    main()
