#!/usr/bin/env python3
"""Compare the actual native callback collection loop and bounded replacement."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MONITOR = "Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift"
POLICY = "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
BATCH = "Sources/IlliquidApp/UI/SourceFilesystemEventBatch.swift"
WORKLOADS = ["normal64", "normal512", "boundary4096", "overflow4097",
             "overflow100000", "overflow1000000", "sparse8192_4096",
             "sparse100000_1", "null100000"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Experiment:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.build = self.output / "build"
        self.build.mkdir()
        resolved = shutil.which(args.swiftc)
        if not resolved:
            raise ValueError(f"Swift compiler not found: {args.swiftc}")
        # Keep the swiftc driver name: resolving its symlink changes driver mode.
        self.swiftc = Path(resolved).absolute()
        self.clang = self.swiftc.with_name("clang")
        self.env = dict(os.environ)
        self.env.update(CLANG_MODULE_CACHE_PATH=str(self.build / "module-cache"),
                        SWIFT_MODULECACHE_PATH=str(self.build / "module-cache"))
        self.binaries: dict[tuple[str, str], Path] = {}

    def command(self, argv: list, log: str | None = None) -> str:
        argv = [str(arg) for arg in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=600)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "returncode": result.returncode,
                                    "elapsed_seconds": time.monotonic() - start,
                                    "stdout_sha256": digest(result.stdout.encode()),
                                    "stderr": result.stderr}) + "\n")
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n{result.stdout[-4000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def prepare(self) -> None:
        baseline = json.loads((HERE / "baseline/manifest.json").read_text())
        originals = {}
        for path, expected in baseline["files"].items():
            raw = (HERE / "baseline" / Path(path).name).read_bytes()
            if digest(raw) != expected["sha256"] or git_blob(raw) != expected["git_blob"]:
                raise ValueError(f"Frozen baseline identity mismatch: {path}")
            originals[path] = raw

        monitor = originals[MONITOR].decode()
        start = "        let pointers = paths.assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self)\n"
        end = "        if !events.isEmpty { receiver.receive(events) }\n"
        if monitor.count(start) != 1 or monitor.count(end) != 1:
            raise ValueError("Baseline callback extraction boundary changed")
        body = monitor.split(start, 1)[1].split(end, 1)[0]
        mapping = "Self.flags(from: flags[index])"
        if body.count(mapping) != 1:
            raise ValueError("Baseline flag-mapping boundary changed")
        # The old collection statements remain verbatim apart from substituting
        # the native flag mapper with the same synchronous closure as candidate.
        adapter = ("import Foundation\n\nenum SourceFilesystemEventBatch {\n"
                   "    static func decode(paths: UnsafeBufferPointer<UnsafePointer<CChar>?>,\n"
                   "        flagsAt: (Int) -> SourceFilesystemEvent.Flags) -> [SourceFilesystemEvent] {\n"
                   "        let count = paths.count\n"
                   "        guard let pointers = paths.baseAddress else { return [] }\n"
                   + body.replace(mapping, "flagsAt(index)")
                   + "        return events\n    }\n}\n")
        support = ROOT / "Benchmarks/RuntimeLeaseHistory/CLeaseHeap"
        include = self.build / "include"
        include.mkdir()
        shutil.copyfile(support / "include/CLeaseHeap.h", include / "CLeaseHeap.h")
        (include / "module.modulemap").write_text('module CLeaseHeap { header "CLeaseHeap.h" export * }\n')
        heap = self.build / "heap.o"
        self.command([self.clang, "-O2", "-I", include, "-c", support / "heap.c", "-o", heap],
                     "build-heap.log")
        source_hashes = {}
        binary_hashes = {}
        for variant in ("baseline", "candidate"):
            folder = self.build / variant
            folder.mkdir()
            policy = originals[POLICY] if variant == "baseline" else (ROOT / POLICY).read_bytes()
            decoder = adapter.encode() if variant == "baseline" else (ROOT / BATCH).read_bytes()
            (folder / "Policy.swift").write_bytes(policy)
            (folder / "Batch.swift").write_bytes(decoder)
            source_hashes[variant] = {"policy_sha256": digest(policy), "batch_sha256": digest(decoder)}
            for configuration in ("debug", "release"):
                binary = folder / configuration
                flags = ["-Onone"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
                if platform.system() == "Darwin":
                    flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
                self.command([self.swiftc, *flags, "-swift-version", "6", "-warnings-as-errors",
                              "-parse-as-library", "-I", include, folder / "Policy.swift",
                              folder / "Batch.swift", HERE / "Harness.swift", heap, "-o", binary],
                             f"build-{variant}-{configuration}.log")
                self.binaries[variant, configuration] = binary
                binary_hashes[f"{variant}-{configuration}"] = digest(binary.read_bytes())
                print(f"Built {variant} {configuration}", flush=True)
        self.manifest = {
            "baseline": baseline,
            "checkout_head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_uses_worktree_source": True,
            "production_sha256": {path: digest((ROOT / path).read_bytes()) for path in (MONITOR, POLICY, BATCH)},
            "compiled_sources": source_hashes,
            "baseline_adapter": adapter,
            "harness_sha256": {name: digest((HERE / name).read_bytes()) for name in ("Harness.swift", "run.py")},
            "allocator_support_sha256": {name: digest((support / name).read_bytes())
                                         for name in ("heap.c", "include/CLeaseHeap.h")},
            "binary_sha256": binary_hashes,
        }
        save(self.output / "manifest.json", self.manifest)
        cpu = "unknown"
        if Path("/proc/cpuinfo").exists():
            cpu = next((line.partition(":")[2].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                        if line.startswith("model name")), cpu)
        save(self.output / "environment.json", {
            "started_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
            "machine": platform.machine(), "cpu": cpu, "compiler": self.command([self.swiftc, "--version"]).strip(),
            "swiftc": str(self.swiftc), "pairs": self.args.pairs, "target_ms": self.args.target_ms,
            "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
            "build_flags": "Swift 6, warnings-as-errors; -Onone and -O -whole-module-optimization",
            "scope": "C-string callback materialization; no live FSEvents, queued MainActor tasks, rescans, playback, RSS or physical footprint",
        })

    def verify(self) -> None:
        receipts = {}
        for configuration in ("debug", "release"):
            variants = {variant: json.loads(self.command([self.binaries[variant, configuration], "verify"]))
                        for variant in ("baseline", "candidate")}
            trace = json.dumps(variants, sort_keys=True).encode()
            (self.output / f"verification-{configuration}.json.gz").write_bytes(gzip.compress(trace, mtime=0))
            old = variants["baseline"]["cases"]
            new = variants["candidate"]["cases"]
            if len(old) != len(new) or not old:
                raise ValueError("Verification case inventory mismatch")
            overflow = 0
            for before, after in zip(old, new):
                keys = ("name", "raw_count", "valid_count", "buffered_events", "plan")
                if any(before[key] != after[key] for key in keys):
                    raise ValueError(f"Buffered event or planner mismatch: {before['name']}")
                if before["valid_count"] <= 4096:
                    if before["decoded_events"] != after["decoded_events"]:
                        raise ValueError(f"Detailed callback mismatch: {before['name']}")
                    if after["flags_reads"] != before["valid_count"]:
                        raise ValueError(f"Skipped/null flag semantics changed: {before['name']}")
                else:
                    overflow += 1
                    if after["decoded_count"] != 1 or after["flags_reads"] != 0:
                        raise ValueError(f"Overflow was not preflighted: {before['name']}")
                if after["decoded_count"] > 4096:
                    raise ValueError("Callback storage bound exceeded")
            if not overflow:
                raise ValueError("No overflow cases were tested")
            receipts[configuration] = {"cases": len(old), "overflow_cases": overflow,
                                       "exact_buffered_events_and_plans": True,
                                       "exact_within_budget_callbacks": True,
                                       "overflow_flag_reads": 0, "trace_sha256": digest(trace)}
        save(self.output / "verification.json", receipts)
        print("Debug and optimized differential verification passed", flush=True)

    def measure(self) -> None:
        iterations = {}
        calibrations = []
        for workload in WORKLOADS:
            for variant in ("baseline", "candidate"):
                count = 1
                for _ in range(6):
                    row = json.loads(self.command([self.binaries[variant, "release"], "measure", workload, count]))
                    calibrations.append({"variant": variant, **row})
                    elapsed = row["elapsed_ns"]
                    if elapsed >= self.args.target_ms * 1_000_000 * 0.7 or count >= 200000:
                        break
                    count = min(200000, max(count + 1, int(count * self.args.target_ms * 1_000_000 / max(1, elapsed))))
                iterations[variant, workload] = count
        save(self.output / "calibration.json", calibrations)
        observations = []
        for pair in range(self.args.pairs):
            for workload in WORKLOADS:
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for variant in order:
                    row = json.loads(self.command([self.binaries[variant, "release"], "measure", workload,
                                                   iterations[variant, workload]]))
                    row.update(variant=variant, pair=pair, order="AB" if pair % 2 == 0 else "BA")
                    if row["iterations"] <= 0 or row["elapsed_ns"] <= 0:
                        raise ValueError("Invalid timing sample")
                    row["ns_per_callback"] = row["elapsed_ns"] / row["iterations"]
                    observations.append(row)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Measured pair {pair + 1}/{self.args.pairs}", flush=True)
        summary = {}
        for workload in WORKLOADS:
            rows = {variant: [r for r in observations if r["variant"] == variant and r["workload"] == workload]
                    for variant in ("baseline", "candidate")}
            paired = [100 * (new["ns_per_callback"] / old["ns_per_callback"] - 1)
                      for old, new in zip(rows["baseline"], rows["candidate"])]
            summary[workload] = {
                **{variant: {key: statistics.median(r[key] for r in values)
                             for key in ("ns_per_callback", "returned_events", "callback_path_bytes",
                                         "live_allocator_delta_bytes", "flags_reads")}
                   for variant, values in rows.items()},
                "paired_time_change_percent": {"median": statistics.median(paired),
                                               "minimum": min(paired), "maximum": max(paired)},
            }
        save(self.output / "summary.json", summary)

    def finish(self) -> None:
        for path, expected in self.manifest["production_sha256"].items():
            if digest((ROOT / path).read_bytes()) != expected:
                raise ValueError(f"Production source changed during measurement: {path}")
        for path, expected in self.manifest["harness_sha256"].items():
            if digest((HERE / path).read_bytes()) != expected:
                raise ValueError(f"Harness changed during measurement: {path}")
        save(self.output / "completion.json", {"complete": True, "source_identity_rechecked": True})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=60)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not 1 <= args.target_ms <= 1000:
        parser.error("Use an even number of pairs >= 2 and target-ms between 1 and 1000")
    experiment = Experiment(args)
    experiment.prepare()
    experiment.verify()
    experiment.measure()
    experiment.finish()
    print(f"Completed: {experiment.output}")


if __name__ == "__main__":
    main()
