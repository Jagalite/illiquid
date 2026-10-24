#!/usr/bin/env python3
"""Measure independent subtitle staging-slot storage using actual Swift sources."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
EXTRACTOR = ROOT / "Benchmarks/SubtitleStaging/run.py"
VARIANTS = ("baseline", "candidate")


def sha(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands, self.rows, self.parity = [], [], {}
        self.env = dict(os.environ)
        self.env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(self.output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.swift = Path(args.swift).absolute()
        self.swiftc = self.swift.with_name("swiftc")
        if not self.swift.is_file() or not self.swiftc.is_file():
            raise ValueError("swift and swiftc must exist in the selected toolchain directory")
        spec = importlib.util.spec_from_file_location("staging_extractor", EXTRACTOR)
        self.extractor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.extractor)
        self.manifest = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swift, "--version"]).strip(),
            "compiler_sha256": file_sha(self.swiftc),
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "driver_sha256": sha((HERE / "Main.swift").read_bytes()),
            "extractor_sha256": sha(EXTRACTOR.read_bytes()),
            "protocol": {"pairs": args.pairs, "fresh_process_per_observation": True,
                         "order": "alternating AB/BA by pair", "warmup_sequences": 0,
                         "held_count": args.held_count},
            "variants": {},
        }
        if platform.system() == "Darwin":
            self.manifest["host"] = self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"])
            self.manifest["sdk"] = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip()
        for name, path in (("Main.swift", HERE / "Main.swift"), ("run.py", Path(__file__)),
                           ("extractor.py", EXTRACTOR)):
            shutil.copyfile(path, self.output / name)
        self.binaries = {}

    def command(self, argv, log=None, timeout=600):
        argv = [str(v) for v in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        record = {"argv": argv, "returncode": result.returncode,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)}
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
            record["log"] = log
        self.commands.append(record)
        write_json(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-6000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def build(self):
        for variant in VARIANTS:
            directory = self.output / variant
            ref = BASELINE if variant == "baseline" else None
            receipt = self.extractor.extract(directory, ref)
            binary = directory / "subtitle-slot-capacity"
            inputs = [directory / name for name in sorted(receipt["generated_sha256"])]
            flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                     "-module-cache-path", str(self.output / "module-cache")]
            if platform.system() == "Darwin":
                flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
            command = [self.swiftc, *flags, *inputs, self.output / "Main.swift", "-o", binary]
            self.command(command, log=f"{variant}-build.log")
            receipt.update(binary_sha256=file_sha(binary), command=[str(v) for v in command])
            self.manifest["variants"][variant] = receipt
            self.binaries[variant] = binary
        write_json(self.output / "manifest.json", self.manifest)
        self.cases = json.loads(self.command([self.binaries["candidate"], "list"]))
        if not isinstance(self.cases, list) or len(self.cases) != 12 or len(set(self.cases)) != 12:
            raise ValueError("Expected twelve distinct workload names")
        if set(self.cases) != {f"{kind}-{pattern}" for kind in ("r8", "bitmap", "bgra")
                               for pattern in ("spike", "stable-small", "stable-large", "delayed-large")}:
            raise ValueError("Incomplete workload matrix")
        if json.loads(self.command([self.binaries["baseline"], "list"])) != self.cases:
            raise ValueError("Workload lists differ")
        self.manifest["cases"] = self.cases

    def verify(self):
        for case in self.cases:
            values = {}
            for variant in VARIANTS:
                value = json.loads(self.command([self.binaries[variant], "verify", case],
                                               log=f"verify-{case}-{variant}.log"))
                if (value["case"] != case or value["status"] != "passed"
                        or value["source_retirement_released_storage"] is not True):
                    raise ValueError("Verification case mismatch")
                values[variant] = value
            if values["baseline"]["parity"] != values["candidate"]["parity"]:
                raise ValueError(f"Active pixel/geometry/snapshot verification failed: {case}")
            self.parity[case] = values
        write_json(self.output / "verification.json", self.parity)

    def measure(self):
        for case in self.cases:
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                for order_index, variant in enumerate(order):
                    value = json.loads(self.command([self.binaries[variant], "measure", case, self.args.held_count]))
                    if value["case"] != case or value["mode"] != "measure":
                        raise ValueError("Measurement command receipt mismatch")
                    if (value["retained_snapshot_limit"] != self.args.held_count
                            or value["retained_snapshot_count"] != self.args.held_count):
                        raise ValueError("Snapshot retention does not match requested workload")
                    if not value["frames"]:
                        raise ValueError("Missing frame measurements")
                    verified = self.parity[case][variant]["parity"]
                    if (len(value["frames"]) != len(verified)
                            or value["final_active_fnv1a64"] != verified[-1]["active_fnv1a64"]
                            or value["final_zero_tail"] is not True
                            or value["checkpoint_before_output_hashing"] is not True):
                        raise ValueError("Measured output does not match independently verified output")
                    for frame, expected in zip(value["frames"], verified):
                        semantic = {key: item for key, item in frame.items() if key not in {
                            "clear_bytes", "selected_slot_bytes", "other_slot_bytes", "retained_bytes",
                            "budget_reserved_bytes", "elapsed_ns", "cpu_seconds", "minor_faults"}}
                        if semantic != {key: item for key, item in expected.items() if key != "active_fnv1a64"}:
                            raise ValueError("Measured frame geometry/metrics differ from verified output")
                        if frame["retained_bytes"] != frame["budget_reserved_bytes"]:
                            raise ValueError("Budget reservation does not match reusable slot lengths")
                        if frame["retained_bytes"] != frame["selected_slot_bytes"] + frame["other_slot_bytes"]:
                            raise ValueError("Per-slot lengths do not match actual packer total")
                        if not (0 < frame["active_bytes"] <= frame["selected_slot_bytes"]):
                            raise ValueError("Prepared storage cannot cover active texture")
                        if not math.isfinite(frame["cpu_seconds"]) or frame["cpu_seconds"] < 0 or frame["elapsed_ns"] <= 0:
                            raise ValueError("Invalid preparation timing")
                    for phase in ("memory_before", "memory"):
                        for key in ("resident_bytes", "peak_rss_bytes", "physical_footprint_bytes"):
                            measured = value[phase].get(key)
                            if measured is None and key == "physical_footprint_bytes" and platform.system() == "Linux":
                                continue
                            if not isinstance(measured, int) or measured <= 0:
                                raise ValueError(f"Invalid memory reading: {phase}.{key}")
                    value.update(variant=variant, pair=pair, order_index=order_index)
                    self.rows.append(value)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
            print(f"Completed {case}: {self.args.pairs} paired fresh processes", flush=True)
        return summarize(self.rows, self.cases, self.args.pairs, self.args.held_count)

    def verify_sources(self):
        for path, expected in self.manifest["variants"]["candidate"]["source_sha256"].items():
            if sha((ROOT / path).read_bytes()) != expected:
                raise ValueError(f"Production source changed during run: {path}")
        for path, key in ((Path(__file__), "runner_sha256"), (HERE / "Main.swift", "driver_sha256"),
                          (EXTRACTOR, "extractor_sha256")):
            if sha(path.read_bytes()) != self.manifest[key]:
                raise ValueError("Measurement source changed during run")


def summarize(rows, cases, pairs, held_count):
    results = []
    def metric(row, key):
        if key == "retained_bytes":
            return row["frames"][-1][key]
        if key == "group_elapsed_ns":
            return sum(frame["elapsed_ns"] for frame in row["frames"])
        if key == "group_cpu_seconds":
            return sum(frame["cpu_seconds"] for frame in row["frames"])
        if key.startswith("frame_"):
            return row["frames"][int(key.split("_")[1])]["elapsed_ns"]
        return row["memory"].get(key)
    for case in cases:
        selected = [r for r in rows if r["case"] == case]
        if len(selected) != 2 * pairs:
            raise ValueError("Incomplete or duplicate case observations")
        frame_count = len(selected[0]["frames"])
        if any(len(r["frames"]) != frame_count for r in selected):
            raise ValueError("Frame counts differ within workload")
        result = {"case": case, "pairs": pairs, "frame_count": frame_count}
        metrics = ["retained_bytes", "resident_bytes", "physical_footprint_bytes", "peak_rss_bytes",
                   "group_elapsed_ns", "group_cpu_seconds", *[f"frame_{i}_elapsed_ns" for i in range(frame_count)]]
        for key in metrics:
            if all(metric(r, key) is None for r in selected):
                result[key] = None
                continue
            if any(metric(r, key) is None for r in selected):
                raise ValueError("A memory metric is missing from only part of a cohort")
            differences, percentages = [], []
            for pair in range(pairs):
                observations = [r for r in selected if r["pair"] == pair]
                by_variant = {r["variant"]: r for r in observations}
                if len(observations) != 2 or set(by_variant) != set(VARIANTS):
                    raise ValueError("Incomplete or duplicate pair")
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                if any(by_variant[v]["order_index"] != index for index, v in enumerate(order)):
                    raise ValueError("Unbalanced run order")
                baseline, candidate = (metric(by_variant[v], key) for v in VARIANTS)
                differences.append(candidate - baseline)
                if baseline > 0:
                    percentages.append(100 * (candidate / baseline - 1))
            result[key] = {
                v + "_median": statistics.median(metric(r, key) for r in selected if r["variant"] == v)
                for v in VARIANTS}
            result[key].update(paired_differences=differences,
                               paired_median_difference=statistics.median(differences),
                               paired_percent_changes=percentages,
                               paired_median_percent_change=statistics.median(percentages) if percentages else None,
                               candidate_lower_pairs=sum(value < 0 for value in differences))
        results.append(result)
    if len(rows) != len(cases) * pairs * 2:
        raise ValueError("Unexpected observations outside case matrix")
    return {"status": "complete", "processes": len(rows), "held_count": held_count, "results": results,
            "memory_scope": "reusable slot Data lengths and whole harness process memory with requested frame snapshots alive",
            "timing_scope": "cold frame-preparation samples; small intervals are exploratory, not playback latency"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--held-count", type=int, choices=(1, 3), default=1)
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    if not args.swift or args.pairs < 2 or args.pairs % 2:
        parser.error("Select a Swift toolchain and a positive even number of pairs >=2")
    runner = None
    try:
        runner = Runner(args)
        runner.build()
        runner.verify()
        if not args.build_only:
            summary = runner.measure()
            runner.verify_sources()
            write_json(runner.output / "summary.json", summary)
        runner.manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.manifest)
    except Exception as error:
        if runner:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "manifest"):
                write_json(runner.output / "manifest.json", runner.manifest)
        raise


if __name__ == "__main__":
    main()
