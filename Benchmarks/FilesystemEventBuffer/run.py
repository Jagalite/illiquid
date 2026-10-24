#!/usr/bin/env python3
"""Measure retained allocator bytes for the original array and production buffer."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
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
BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
SOURCE = "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
SIDEBAR = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
HEAP = ROOT / "Benchmarks/RuntimeLeaseHistory/CLeaseHeap"
WORKLOADS = [
    ("normal64", 64, "ordinary"),
    ("normal512", 512, "ordinary"),
    ("boundary4096", 4096, "ordinary"),
    ("overflow4097", 4097, "ordinary"),
    ("sustained100000", 100000, "ordinary"),
    ("sustained1000000", 1000000, "ordinary"),
    ("loss512", 512, "loss"),
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Experiment:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir()
        self.env = dict(os.environ)
        for name in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH"):
            self.env[name] = str(self.output / "module-cache")
        swift = shutil.which(args.swift)
        if not swift:
            raise ValueError(f"Swift executable not found: {args.swift}")
        self.swiftc = str(Path(swift).with_name("swiftc"))
        self.clang = str(Path(swift).with_name("clang"))
        self.binaries: dict[str, Path] = {}

    def command(self, arguments: list, log: str | None = None) -> str:
        argv = [str(value) for value in arguments]
        started = time.monotonic()
        process = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                 text=True, timeout=600)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "returncode": process.returncode,
                "seconds": time.monotonic() - started,
                "stdout_sha256": digest(process.stdout.encode()),
                "stderr": process.stderr}) + "\n")
        if log:
            (self.evidence / log).write_text(process.stdout + process.stderr)
        if process.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n{process.stdout[-6000:]}\n{process.stderr[-6000:]}")
        return process.stdout

    def build(self) -> None:
        baseline = self.command(["git", "rev-parse", f"{self.args.baseline}^{{commit}}"]).strip()
        old_sidebar = self.command(["git", "show", f"{baseline}:{SIDEBAR}"])
        patterns = {
            "declaration": r"(?m)^    @State (private var pendingFilesystemEvents: \[SourceFilesystemEvent\] = \[\])$",
            "append": r"(?m)^        (pendingFilesystemEvents\.append\(contentsOf: events\))$",
            "drain": r"(?m)^            (let events = pendingFilesystemEvents\n            pendingFilesystemEvents\.removeAll\(\))$",
        }
        fragments = {}
        for name, pattern in patterns.items():
            matches = re.findall(pattern, old_sidebar)
            if len(matches) != 1:
                raise ValueError(f"Baseline sidebar {name} changed; refusing an invented comparator")
            fragments[name] = matches[0]
        baseline_adapter = (
            "// Original accumulator statements extracted from the pinned SourcesSidebar.swift.\n"
            "struct MeasuredBuffer {\n    " + fragments["declaration"] + "\n"
            "    var count: Int { pendingFilesystemEvents.count }\n"
            "    mutating func append(contentsOf events: [SourceFilesystemEvent]) {\n        "
            + fragments["append"] + "\n    }\n"
            "    mutating func take() -> [SourceFilesystemEvent] {\n        "
            + fragments["drain"].replace("\n            ", "\n        ")
            + "\n        return events\n    }\n"
            "    mutating func removeAll() { pendingFilesystemEvents.removeAll() }\n}\n"
        )
        sources = {
            "baseline": self.command(["git", "show", f"{baseline}:{SOURCE}"]).encode(),
            "candidate": (ROOT / SOURCE).read_bytes(),
        }
        source_dir = self.evidence / "sources"
        source_dir.mkdir()
        (source_dir / "baseline-SourcesSidebar.swift").write_text(old_sidebar)
        shutil.copyfile(ROOT / SIDEBAR, source_dir / "candidate-SourcesSidebar.swift")
        shutil.copyfile(HERE / "Harness.swift", source_dir / "Harness.swift")
        shutil.copyfile(HERE / "run.py", source_dir / "run.py")
        support = self.output / "support"
        shutil.copytree(HEAP, support)
        (support / "include/module.modulemap").write_text(
            'module CLeaseHeap { header "CLeaseHeap.h" export * }\n')
        self.command([self.clang, "-O2", "-I", support / "include", "-c", support / "heap.c",
                      "-o", support / "heap.o"], "build-heap.log")
        shutil.copyfile(HEAP / "heap.c", source_dir / "heap.c")
        shutil.copyfile(HEAP / "include/CLeaseHeap.h", source_dir / "CLeaseHeap.h")
        manifest = {
            "baseline_commit": baseline,
            "candidate_head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_uses_worktree_source": True,
            "production_path": SOURCE,
            "production_sha256": {name: digest(raw) for name, raw in sources.items()},
            "baseline_sidebar_sha256": digest(old_sidebar.encode()),
            "candidate_sidebar_sha256": digest((ROOT / SIDEBAR).read_bytes()),
            "baseline_extracted_statements": fragments,
            "allocator_support_provenance": str(HEAP.relative_to(ROOT)),
            "executables_sha256": {},
        }
        for variant, raw in sources.items():
            folder = self.output / variant
            folder.mkdir()
            production = folder / "SourceFilesystemInvalidation.swift"
            production.write_bytes(raw)
            adapter = folder / "MeasuredBuffer.swift"
            adapter.write_text(baseline_adapter if variant == "baseline"
                               else "typealias MeasuredBuffer = SourceFilesystemEventBuffer\n")
            shutil.copyfile(production, source_dir / f"{variant}-SourceFilesystemInvalidation.swift")
            shutil.copyfile(adapter, source_dir / f"{variant}-MeasuredBuffer.swift")
            binary = folder / "FilesystemEventBuffer"
            flags = ["-D", "CANDIDATE_BUFFER"] if variant == "candidate" else []
            if platform.system() == "Darwin":
                flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
            self.command([self.swiftc, "-O", "-swift-version", "6", "-warnings-as-errors",
                "-parse-as-library", *flags, "-I", support / "include", production,
                adapter, HERE / "Harness.swift", support / "heap.o", "-o", binary],
                f"build-{variant}.log")
            self.binaries[variant] = binary
            manifest["executables_sha256"][variant] = digest(binary.read_bytes())
            print(f"Built {variant}", flush=True)
        manifest["evidence_sources_sha256"] = {
            p.name: digest(p.read_bytes()) for p in sorted(source_dir.iterdir())}
        save(self.evidence / "manifest.json", manifest)
        environment = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "swiftc": self.swiftc, "compiler": self.command([self.swiftc, "--version"]).strip(),
            "optimization": "-O", "pairs": self.args.pairs, "batch_size": 128,
            "path_utf8_length_range": [96, 160],
            "git_status": self.command(["git", "status", "--short"]),
            "scope": "Retained allocator-accounted bytes for a sidebar debounce accumulator; excludes FSEvents delivery, MainActor tasks, rendering, process RSS, and whole-player memory.",
        }
        if platform.system() == "Darwin":
            environment["os"] = self.command(["sw_vers"]).strip()
            environment["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        elif Path("/proc/cpuinfo").exists():
            environment["cpu"] = next((line.partition(":")[2].strip()
                for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), "unknown")
        save(self.evidence / "environment.json", environment)

    def verify(self) -> None:
        receipts = {variant: json.loads(self.command([binary, "verify"]))
                    for variant, binary in self.binaries.items()}
        for key in ("parity", "lossPlans"):
            if receipts["baseline"][key] != receipts["candidate"][key]:
                raise ValueError(f"Baseline/candidate exact {key} mismatch")
        if receipts["candidate"]["recoveryChecks"] != 3:
            raise ValueError("Candidate did not run overflow, drain, and reset checks")
        trace = json.dumps(receipts["baseline"], sort_keys=True).encode()
        (self.evidence / "parity-trace.json.gz").write_bytes(gzip.compress(trace, mtime=0))
        save(self.evidence / "verification.json", {
            "exact_below_capacity_event_and_plan_parity": True,
            "below_capacity_cases": len(receipts["baseline"]["parity"]),
            "compared_events": sum(row["count"] for row in receipts["baseline"]["parity"]),
            "loss_plan_parity_cases": len(receipts["baseline"]["lossPlans"]),
            "overflow_drain_and_reset_cases": receipts["candidate"]["recoveryChecks"],
            "trace_sha256": digest(trace),
        })
        print("Exact event/plan parity and bounded overflow recovery passed", flush=True)

    def measure(self) -> None:
        rows = []
        for name, count, mode in WORKLOADS:
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for variant in order:
                    row = json.loads(self.command([self.binaries[variant], "measure", count, 128, mode]))
                    if row["inputEvents"] != count or row["batchSize"] != 128 or row["allocatorMetric"] == "unsupported":
                        raise ValueError("Unexpected measurement receipt")
                    row.update(workload=name, pair=pair, variant=variant, pair_order=order)
                    rows.append(row)
                    with (self.evidence / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Measured {name}: {self.args.pairs} balanced pairs", flush=True)
        results = {}
        for name, count, mode in WORKLOADS:
            case = [row for row in rows if row["workload"] == name]
            entry = {"input_events": count, "loss_marker": mode == "loss", "pairs": self.args.pairs}
            for variant in ("baseline", "candidate"):
                selected = [row for row in case if row["variant"] == variant]
                entry[variant] = {key: statistics.median(row[key] for row in selected) for key in (
                    "allocatorRetainedDeltaBytes", "retainedEvents", "retainedPathUTF8Bytes",
                    "peakBufferedEventsAfterAppend", "elapsedNanoseconds")}
            paired = [(next(row for row in case if row["pair"] == pair and row["variant"] == "baseline"),
                       next(row for row in case if row["pair"] == pair and row["variant"] == "candidate"))
                      for pair in range(self.args.pairs)]
            entry["median_paired_allocator_reduction_bytes"] = statistics.median(
                old["allocatorRetainedDeltaBytes"] - new["allocatorRetainedDeltaBytes"] for old, new in paired)
            entry["median_paired_allocator_reduction_percent"] = statistics.median(
                100 * (old["allocatorRetainedDeltaBytes"] - new["allocatorRetainedDeltaBytes"])
                / old["allocatorRetainedDeltaBytes"] for old, new in paired)
            results[name] = entry
        save(self.evidence / "summary.json", {
            "metric": rows[0]["allocatorMetric"],
            "method": "Fresh sequential processes, alternating AB/BA pairs, input batches destroyed before allocator sample, result summarization after sample.",
            "allocator_note": "Allocator-accounted bytes include allocator overhead/caches; these are not RSS, physical footprint, or peak process memory measurements.",
            "peak_count_note": "Peak buffer event count sampled after each append; transient callback arrays are excluded.",
            "workloads": results,
        })


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", default=4, type=int)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be a positive even number of at least 2 for balanced AB/BA order")
    experiment = Experiment(args)
    experiment.build()
    experiment.verify()
    experiment.measure()
    print(f"Evidence: {experiment.evidence}")


if __name__ == "__main__":
    main()
