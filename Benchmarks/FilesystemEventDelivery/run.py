#!/usr/bin/env python3
"""Measure real Task-to-MainActor filesystem delivery while its consumer is held.

Uses the production mailbox, event buffer, and planner without platform shims.
The comparator's per-callback Task is extracted from a frozen production source.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DELIVERY = "Sources/IlliquidApp/UI/SourceFilesystemEventDelivery.swift"
MONITOR = "Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift"
INVALIDATION = "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
HEAP = ROOT / "Benchmarks/RuntimeLeaseHistory/CLeaseHeap"
WORKLOADS = [
    ("ordinary64", 64, 128, "ordinary"),
    ("ordinary512", 512, 128, "ordinary"),
    ("boundary4096", 4096, 128, "ordinary"),
    ("overflow4097", 4097, 128, "ordinary"),
    ("sustained100000", 100000, 128, "ordinary"),
    ("sustained1000000", 1000000, 128, "ordinary"),
    ("oversized100000", 100000, 100000, "ordinary"),
    ("loss512", 512, 128, "loss"),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


class Experiment:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir()
        self.build = self.output / "build"
        self.build.mkdir()
        self.environment = os.environ.copy()
        self.swiftc = shutil.which(args.swiftc)
        if not self.swiftc:
            raise ValueError("Swift compiler unavailable; pass --swiftc or set PATH")
        self.clang = str(Path(self.swiftc).with_name("clang"))
        self.binaries = {}
        self.commands = []

    def run(self, command, log=None):
        command = [str(x) for x in command]
        started = time.monotonic()
        process = subprocess.run(command, cwd=ROOT, env=self.environment,
                                 capture_output=True, text=True, timeout=300)
        self.commands.append({"argv": command, "returncode": process.returncode,
                              "elapsed_seconds": time.monotonic() - started,
                              "stdout_sha256": sha(process.stdout.encode()),
                              "stderr": process.stderr})
        save(self.evidence / "commands.json", self.commands)
        if log:
            (self.evidence / log).write_text(process.stdout + process.stderr)
        if process.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{process.stdout[-4000:]}\n{process.stderr[-6000:]}")
        return process.stdout

    def prepare(self):
        baseline = (HERE / "baseline/SourceFilesystemMonitor.swift").read_bytes()
        pin = json.loads((HERE / "baseline/manifest.json").read_text())
        blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
        if sha(baseline) != pin["sha256"] or blob != pin["git_blob"]:
            raise RuntimeError("Frozen baseline source does not match its provenance")
        pattern = (r"        worker.start\(paths: paths, latency: latency\) \{ \[weak self\] events in\n"
                   r"(?P<task>            Task \{ @MainActor \[weak self\] in\n"
                   r"                guard let self, self.generation == revision else \{ return \}\n"
                   r"                self.handler\(events\)\n"
                   r"            \})\n        \}")
        matches = list(re.finditer(pattern, baseline.decode()))
        if len(matches) != 1:
            raise RuntimeError("Expected exactly one original per-callback delivery Task")
        task = matches[0].group("task")
        adapter = """import Foundation
// Scheduling body extracted verbatim from the pinned production monitor.
// A single active watch revision is sufficient for the held-consumer experiment.
final class MeasuredDelivery: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable ([SourceFilesystemEvent]) -> Void
    private let handler: Handler
    private var generation: UInt64 = 0
    init(handler: @escaping Handler) { self.handler = handler }
    func send(_ events: [SourceFilesystemEvent]) {
        let revision: UInt64 = 0
""" + task + """
    }
    @MainActor func close() { generation &+= 1 }
}
"""
        (self.build / "BaselineDelivery.swift").write_text(adapter)
        (self.build / "CandidateDelivery.swift").write_text(
            "typealias MeasuredDelivery = SourceFilesystemEventDelivery\n")
        support = self.build / "heap"
        shutil.copytree(HEAP, support)
        (support / "include/module.modulemap").write_text(
            'module CLeaseHeap { header "CLeaseHeap.h" export * }\n')
        self.run([self.clang, "-O2", "-I", support / "include", "-c", support / "heap.c",
                  "-o", support / "heap.o"], "build-heap.log")
        self.manifest = {
            "baseline": pin,
            "baseline_task": task,
            "baseline_adapter_sha256": sha(adapter.encode()),
            "source_sha256": {path: sha((ROOT / path).read_bytes()) for path in
                              (DELIVERY, MONITOR, INVALIDATION)},
            "harness_sha256": {name: sha((HERE / name).read_bytes()) for name in ("Harness.swift", "run.py")},
            "allocator_support_sha256": {str(path.relative_to(HEAP)): sha(path.read_bytes())
                                         for path in sorted(HEAP.rglob("*")) if path.is_file()},
            "checkout_head": self.run(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_uses_worktree_source": True,
            "compiler": self.run([self.swiftc, "--version"]).strip(),
            "platform": platform.platform(),
            "architecture": platform.machine(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "pairs": self.args.pairs,
            "scope": "Live allocator bytes for actual pending MainActor delivery tasks and event payloads. "
                     "Excludes native FSEvents callback arrays, the sidebar debounce buffer, full app, and RSS. "
                     "Stress inputs are synthetic, not observed event rates.",
            "binaries": {},
        }
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                binary = self.build / f"{variant}-{configuration}"
                sources = [ROOT / INVALIDATION]
                flags = ["-Onone"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
                if variant == "candidate":
                    sources += [ROOT / DELIVERY, self.build / "CandidateDelivery.swift"]
                    flags += ["-D", "CANDIDATE_DELIVERY"]
                else:
                    sources.append(self.build / "BaselineDelivery.swift")
                if platform.system() == "Darwin":
                    flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
                self.run([self.swiftc, *flags, "-swift-version", "6", "-warnings-as-errors",
                          "-parse-as-library", "-module-cache-path", self.build / "module-cache",
                          "-I", support / "include", *sources, HERE / "Harness.swift",
                          support / "heap.o", "-o", binary], f"build-{variant}-{configuration}.log")
                self.binaries[variant, configuration] = binary
                self.manifest["binaries"][f"{variant}-{configuration}"] = sha(binary.read_bytes())
                print(f"Built {variant}/{configuration}", flush=True)
        save(self.evidence / "manifest.json", self.manifest)

    def invoke(self, variant, configuration, mode, count, batch, kind):
        return json.loads(self.run([self.binaries[variant, configuration], mode, count, batch, kind]))

    def verify(self):
        receipts = []
        for configuration in ("debug", "release"):
            for count, batch in ((1, 128), (63, 7), (129, 128), (4096, 128)):
                rows = [self.invoke(variant, configuration, "verify", count, batch, "ordinary")
                        for variant in ("baseline", "candidate")]
                for key in ("events", "directories_to_reload", "trees_to_invalidate", "roots_to_rescan"):
                    if rows[0][key] != rows[1][key]:
                        raise RuntimeError(f"Exact ordinary delivery parity failed: {configuration}, {count}, {key}")
                receipts.append({"configuration": configuration, "input_events": count,
                                 "batch_size": batch, "exact_event_and_plan_parity": True,
                                 "events_sha256": sha(json.dumps(rows[0]["events"], sort_keys=True).encode())})
            rows = [self.invoke(variant, configuration, "verify", 257, 31, "loss")
                    for variant in ("baseline", "candidate")]
            if rows[0]["roots_to_rescan"] != rows[1]["roots_to_rescan"]:
                raise RuntimeError("Explicit event loss changed all-root recovery")
            for count in (4097, 10000):
                row = self.invoke("candidate", configuration, "verify", count, 128, "ordinary")
                if row["delivered_events"] != 1 or len(row["roots_to_rescan"]) != 2:
                    raise RuntimeError("Overflow did not recover all roots")
        save(self.evidence / "verification.json", {
            "ordinary_parity": receipts, "explicit_loss_configurations": ["debug", "release"],
            "overflow_configurations": ["debug", "release"], "overflow_inputs": [4097, 10000],
        })
        print("Exact ordinary delivery parity and conservative overflow recovery passed", flush=True)

    def measure(self):
        observations = []
        summary = []
        for name, count, batch, kind in WORKLOADS:
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for variant in order:
                    row = self.invoke(variant, "release", "measure", count, batch, kind)
                    row.update(workload=name, pair=pair, variant=variant)
                    observations.append(row)
                    save(self.evidence / "observations.json", observations)
            medians = {variant: statistics.median(row["allocator_delta_bytes"] for row in observations
                        if row["workload"] == name and row["variant"] == variant)
                       for variant in ("baseline", "candidate")}
            def representative(variant):
                rows = [row for row in observations if row["workload"] == name and row["variant"] == variant]
                fields = ("delivered_batches", "delivered_events", "delivered_path_utf8_bytes")
                if any(any(row[key] != rows[0][key] for key in fields) for row in rows):
                    raise RuntimeError("Deterministic retention counts changed between observations")
                return {key: rows[0][key] for key in fields}
            summary.append({"workload": name, "input_events": count, "batch_size": batch,
                            "median_allocator_delta_bytes": medians,
                            "median_reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"])
                                if medians["baseline"] > 0 else None,
                            "baseline": representative("baseline"), "candidate": representative("candidate")})
            save(self.evidence / "summary.json", summary)
            print(f"{name}: allocator delta baseline={medians['baseline']:.0f}, candidate={medians['candidate']:.0f} bytes", flush=True)
    def measure_close(self):
        rows = []
        for pair in range(self.args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for variant in order:
                row = self.invoke(variant, "release", "measure-close", 4096, 128, "ordinary")
                row.update(variant=variant, pair=pair)
                rows.append(row)
        save(self.evidence / "close-observations.json", rows)
        save(self.evidence / "close-summary.json", {
            variant: {key: statistics.median(row[key] for row in rows if row["variant"] == variant)
                      for key in ("pending_delta_bytes", "closed_delta_bytes", "bytes_released_by_close")}
            for variant in ("baseline", "candidate")
        })
        print("Measured immediate close while delivery tasks remain queued", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--pairs", type=int, default=4)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive and even, at least 2, for balanced AB/BA order")
    experiment = Experiment(args)
    experiment.prepare()
    experiment.verify()
    experiment.measure()
    experiment.measure_close()
    save(experiment.evidence / "completion.json", {
        "status": "passed", "fresh_process_memory_observations": (len(WORKLOADS) + 1) * args.pairs * 2,
        "pairs_per_workload": args.pairs, "delivery_workloads": len(WORKLOADS), "close_workloads": 1,
    })


if __name__ == "__main__":
    main()
