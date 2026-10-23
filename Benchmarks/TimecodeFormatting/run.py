#!/usr/bin/env python3
"""Compare the actual timeline timecode formatter on native macOS Foundation.

Steady-state timings include a UTF-8 checksum and autorelease-pool cleanup.
Static initialization is warmed before timing. Full verification traces remain
in the output; parity/summary/samples/source receipts form the compact evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
SOURCE = "Sources/IlliquidApp/UI/PlaybackControlBar.swift"
CASES = ["continuous_short", "long_movie", "scrubbing", "repeated_display"]


def sha(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def extract_formatter(source):
    match = re.search(r"(?m)^enum TimecodeFormatter \{", source)
    if match is None:
        raise ValueError("Expected the production TimecodeFormatter enum")
    begin = source.index("{", match.start())
    depth = 0
    for index in range(begin, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():index + 1] + "\n"
    raise ValueError("Unbalanced formatter; review extraction")


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swiftc = args.swiftc or shutil.which("swiftc") or "swiftc"
        self.commands = []
        self.executables = {}
        self.receipts = {}

    def write(self, name, value):
        (self.output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, command, log=None):
        start = time.monotonic()
        result = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True,
                                text=True, timeout=600)
        self.commands.append({"argv": [str(x) for x in command], "returncode": result.returncode,
                              "seconds": time.monotonic() - start,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)})
        if log:
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Failed command: {command}\n{result.stdout[-3000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def prepare(self):
        if platform.system() != "Darwin":
            raise RuntimeError("This benchmark requires native macOS Foundation; Linux is not substituted")
        self.write("environment.json", {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree_status": self.command(["git", "status", "--short"]),
            "sw_vers": self.command(["sw_vers"]).strip(), "platform": platform.platform(),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "hardware_model": self.command(["sysctl", "-n", "hw.model"]).strip(),
            "architecture": platform.machine(), "logical_cpus": os.cpu_count(),
            "swift": self.command([self.swiftc, "--version"]).strip(),
            "locale": self.command(["locale"]).strip(),
            "macos_sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.args).items()},
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
        })
        for variant in ("baseline", "candidate"):
            directory = self.output / variant
            directory.mkdir()
            raw = (self.command(["git", "show", f"{BASELINE}:{SOURCE}"])
                   if variant == "baseline" else (ROOT / SOURCE).read_text())
            extracted = extract_formatter(raw)
            (directory / "PlaybackControlBar.snapshot.swift").write_text(raw)
            staged = directory / "TimecodeFormatter.swift"
            staged.write_text("import Foundation\n\n" + extracted)
            harness = directory / "Harness.swift"
            shutil.copyfile(HERE / "Harness.swift", harness)
            self.receipts[variant] = {"source_path": SOURCE, "source_sha256": sha(raw),
                                      "extracted_sha256": sha(extracted), "binaries": {}}
            for configuration in ("debug", "release"):
                binary = directory / ("benchmark-" + configuration)
                flags = ["-Onone", "-g"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
                flags += ["-swift-version", "6", "-parse-as-library", "-target",
                          f"{platform.machine()}-apple-macos26.0", "-module-cache-path", self.output / "module-cache"]
                self.command([self.swiftc, *flags, staged, harness, "-o", binary],
                             log=directory / f"compile-{configuration}.log")
                self.executables[(variant, configuration)] = binary
                self.receipts[variant]["binaries"][configuration] = {"sha256": sha(binary.read_bytes()),
                                                                     "flags": [str(x) for x in flags]}
                print("Built", variant, configuration, flush=True)
        if self.receipts["baseline"]["extracted_sha256"] == self.receipts["candidate"]["extracted_sha256"]:
            raise RuntimeError("Formatter implementations are identical; no candidate change to measure")
        self.write("source-receipts.json", self.receipts)

    def invoke(self, variant, configuration, *arguments):
        return json.loads(self.command([self.executables[(variant, configuration)], *arguments]))

    def verify(self):
        reference = None
        comparisons = []
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                trace = self.invoke(variant, configuration, "verify")
                self.write(f"{variant}-{configuration}-trace.json", trace)
                if reference is not None and trace != reference:
                    raise RuntimeError(f"Complete output parity failed for {variant}/{configuration}")
                reference = trace
                comparisons.append({"variant": variant, "configuration": configuration,
                                    "golden_cases": trace["goldenCases"], "rows": len(trace["rows"]),
                                    "semantic_trace_sha256": sha(json.dumps(trace, sort_keys=True))})
        self.write("parity.json", {"equal": True, "comparisons": comparisons,
                                  "negative_zero_bits": 1 << 63, "negative_zero_output": "00:00",
                                  "positive_zero_output": "00:00", "invalid_output": "0:00"})
        print(f'Exact debug/release parity: {len(reference["rows"])} inputs; '
              f'{reference["goldenCases"]} independent golden cases per binary', flush=True)

    def measure(self):
        summaries, calibrations = [], []
        for workload in CASES:
            pilots = {variant: [self.invoke(variant, "release", "measure", workload, 100_000) for _ in range(2)]
                      for variant in ("baseline", "candidate")}
            fastest = min(row["elapsedNanoseconds"] / row["iterations"]
                          for values in pilots.values() for row in values)
            # Target even the faster variant, with a margin for pilot variance.
            requested = math.ceil(self.args.target_ms * 1_000_000 * 1.5 / fastest)
            iterations = min(100_000_000, max(100_000, math.ceil(requested / 4_096) * 4_096))
            calibrations.append({"workload": workload, "pilots": pilots, "iterations": iterations,
                                 "requested_iterations": requested, "cap_applied": requested > 100_000_000,
                                 "faster_variant_target_ms": self.args.target_ms, "margin": 1.5})
            self.write("calibration.json", calibrations)
            rows = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                samples = {}
                for position, variant in enumerate(order):
                    row = self.invoke(variant, "release", "measure", workload, iterations)
                    row.update(variant=variant, pair=pair, process_order=position, order=list(order))
                    samples[variant] = row
                    rows.append(row)
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                for field in ("checksum", "warmupChecksum", "last", "iterations"):
                    if samples["baseline"][field] != samples["candidate"][field]:
                        raise RuntimeError(f"Timed output mismatch in {workload}/{pair}: {field}")
            summary = {"workload": workload, "iterations": iterations, "pairs": self.args.pairs}
            for metric in ("elapsedNanoseconds", "cpuNanoseconds"):
                values = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                          for variant in ("baseline", "candidate")}
                medians = {variant: statistics.median(sample) for variant, sample in values.items()}
                paired = []
                for pair in range(self.args.pairs):
                    sample = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                    paired.append((sample["candidate"] / sample["baseline"] - 1) * 100)
                summary[metric] = {"median_ns_per_operation": medians,
                    "range_ns_per_operation": {key: [min(value), max(value)] for key, value in values.items()},
                    "change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                    "paired_change_percent": paired, "median_paired_change_percent": statistics.median(paired)}
            summary["observations_under_target"] = [
                {"variant": row["variant"], "pair": row["pair"], "ms": row["elapsedNanoseconds"] / 1_000_000}
                for row in rows if row["elapsedNanoseconds"] < self.args.target_ms * 1_000_000]
            summaries.append(summary)
            wall = summary["elapsedNanoseconds"]["median_ns_per_operation"]
            cpu = summary["cpuNanoseconds"]["median_ns_per_operation"]
            print(workload, f'wall {wall["baseline"]:.1f} -> {wall["candidate"]:.1f} ns/op '
                  f'({summary["elapsedNanoseconds"]["change_percent"]:+.2f}%); '
                  f'CPU {cpu["baseline"]:.1f} -> {cpu["candidate"]:.1f} ns/op '
                  f'({summary["cpuNanoseconds"]["change_percent"]:+.2f}%)', flush=True)
            self.write("summary.json", summaries)
        return {"observations": len(CASES) * self.args.pairs * 2,
                "minimum_duration_met": all(not group["observations_under_target"] for group in summaries)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even number of pairs >= 2 and a positive finite target-ms")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.verify()
        counts = {} if args.tests_only else runner.measure()
        runner.write("completion.json", {"complete": True, "tests_only": args.tests_only, **counts})
    finally:
        runner.write("commands.json", runner.commands)


if __name__ == "__main__":
    main()
