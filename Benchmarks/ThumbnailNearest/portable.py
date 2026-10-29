#!/usr/bin/env python3
"""Supplementary thumbnail planning probe, not native cache qualification.

Extract the exact nearest-candidate planning statements and original Key fields.
The adapter uses Dictionary<Key, UInt8> membership and returns the planned keys.
It excludes actor scheduling, CGImage ownership, image attempts, LRU and disk.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
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
SOURCE = "Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift"
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "66b8127d5c1ea269860b2c1b63e3dcede4262807"
HEADER = "    func nearest(to key: Key, maximumDistance: Double, fallbackTimes: [Double] = []) async -> (CGImage, Double)? {\n"
NEXT = "    func admitsBackground(size: CGSize) -> Bool {"
CANCEL = "            guard !Task.isCancelled else { return nil }\n"
KEY = "    struct Key: Hashable, Encodable, Sendable {\n"
DIGEST = "        var digest: String {"
FLAGS = ["-swift-version", "6", "-O", "-whole-module-optimization", "-disable-cmo",
         "-parse-as-library", "-warnings-as-errors"]
SCOPE = ("Planning-only source projection using Dictionary<Key, UInt8>; excludes native "
         "actor scheduling, CGImage ownership, image attempts, LRU, disk and playback.")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def emit(kind, value):
    print("NEAREST_PORTABLE_" + kind + " " + json.dumps(
        value, sort_keys=True, allow_nan=False), flush=True)


def split_source(source):
    for marker in (HEADER, NEXT, KEY, DIGEST):
        if source.count(marker) != 1:
            raise ValueError(f"Extraction boundary changed: {marker!r}")
    start, end = source.index(HEADER), source.index(NEXT)
    if start >= end:
        raise ValueError("Invalid nearest source order")
    body = source[start + len(HEADER):end]
    if body.count(CANCEL) != 1:
        raise ValueError("Nearest cancellation boundary changed")
    cancel = body.index(CANCEL)
    key_start, key_end = source.index(KEY), source.index(DIGEST)
    if key_start >= key_end or key_end >= start:
        raise ValueError("Invalid Key field source order")
    return {"before": source[:start], "after": source[end:],
            "key": source[key_start:key_end],
            "planning_prefix": body[:cancel], "async_tail": body[cancel:]}


def projections(baseline, candidate):
    parts = {"baseline": split_source(baseline), "candidate": split_source(candidate)}
    for field in ("before", "after", "key", "async_tail"):
        if parts["baseline"][field] != parts["candidate"][field]:
            raise ValueError(f"Unexpected change outside planning: {field}")
    projected = {}
    for variant, part in parts.items():
        plan = part["planning_prefix"]
        if variant == "baseline":
            opening = "        for match in candidates.sorted(by: {\n"
            ending = "        }) {\n"
            if plan.count(opening) != 1 or not plan.endswith(ending):
                raise ValueError("Baseline sorted-attempt boundary changed")
            plan = plan.replace(opening, "        return candidates.sorted(by: {\n", 1)
            plan = plan[:-len(ending)] + "        })\n"
        else:
            ending = "        for match in candidates {\n"
            if plan.count(ending) != 1 or not plan.endswith(ending):
                raise ValueError("Candidate sorted-attempt boundary changed")
            plan = plan[:-len(ending)] + "        return candidates\n"
        key = part["key"].replace("    struct Key:", "    public struct Key:", 1)
        projected[variant] = (
            "import Foundation\n\npublic struct NativeThumbnailPlanner {\n"
            + key + "    }\n\n"
            + "    private let images: [Key: UInt8]\n"
            + "    public init(keys: [Key]) {\n"
            + "        var images: [Key: UInt8] = [:]\n"
            + "        for key in keys { images[key] = 0 }\n"
            + "        self.images = images\n"
            + "    }\n\n"
            + "    public func nearest(to key: Key, maximumDistance: Double, fallbackTimes: [Double] = []) -> [Key]? {\n"
            + plan + "    }\n}\n")
    return projected, parts


class Probe:
    def __init__(self, args):
        self.args, self.out = args, args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Use an empty output directory; preserve previous attempts")
        for name in ("inputs", "receipts", "logs", "build"):
            (self.out / name).mkdir(parents=True)
        self.env = os.environ.copy()
        self.build_env = {}
        for variable, suffix in (("CLANG_MODULE_CACHE_PATH", "clang"),
                                 ("SWIFT_MODULECACHE_PATH", "swift"), ("TMPDIR", "tmp")):
            path = self.out / "build" / suffix
            path.mkdir()
            self.env[variable] = self.build_env[variable] = str(path)
        self.commands = []
        self.manifest = {"scope": SCOPE, "baseline": BASELINE,
                         "started_utc": datetime.now(timezone.utc).isoformat(),
                         "platform": platform.platform(), "machine": platform.machine(),
                         "cpu_count": os.cpu_count(), "libc": platform.libc_ver(),
                         "container_image": os.environ.get("PROBE_CONTAINER_IMAGE"),
                         "native_qualification": False, "case_order": "fixed driver verification order",
                         "calibration": "Both variants reach target duration before final equal-work pairs",
                         "build_environment": self.build_env, "flags": FLAGS,
                         "pairs": args.pairs, "target_ms": args.target_ms,
                         "method": "Fresh-process equal-work pairs; alternating AB/BA; "
                                   "all observations retained; calibration excluded."}

    def run(self, argv):
        started = time.monotonic()
        result = subprocess.run([str(x) for x in argv], cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=300)
        log = self.out / "logs" / f"{len(self.commands):03d}.txt"
        log.write_text(result.stdout + result.stderr)
        record = {"argv": [str(x) for x in argv], "cwd": str(ROOT),
                  "returncode": result.returncode, "elapsed_seconds": time.monotonic() - started,
                  "log": str(log.relative_to(self.out))}
        self.commands.append(record)
        with (self.out / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n" + (result.stdout + result.stderr)[-8000:])
        return result.stdout

    def prepare(self):
        self.manifest.update(
            swift_version=self.run(["swift", "--version"]).strip(),
            swiftc_version=self.run(["swiftc", "--version"]).strip(),
            swift_path=shutil.which("swift"), swiftc_path=shutil.which("swiftc"),
            git_head=self.run(["git", "rev-parse", "HEAD"]).strip(),
            git_status=self.run(["git", "status", "--porcelain"]).strip())
        cpu = Path("/proc/cpuinfo")
        if cpu.exists():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in cpu.read_text().splitlines() if line.startswith("model name")), None)
        limit = Path("/sys/fs/cgroup/cpu.max")
        if limit.exists():
            self.manifest["cgroup_cpu_max"] = limit.read_text().strip()
        baseline = self.run(["git", "show", f"{BASELINE}:{SOURCE}"]).encode()
        actual_blob = hashlib.sha1(f"blob {len(baseline)}\0".encode() + baseline).hexdigest()
        if actual_blob != BASELINE_BLOB:
            raise ValueError("Frozen baseline blob differs")
        candidate = (ROOT / SOURCE).read_bytes()
        generated, parts = projections(baseline.decode(), candidate.decode())
        driver_path = str((HERE / "Portable.swift").relative_to(ROOT))
        runner_path = str(Path(__file__).resolve().relative_to(ROOT))
        workflow_path = ".github/workflows/thumbnail-nearest-portable.yml"
        current = {SOURCE: candidate, driver_path: (ROOT / driver_path).read_bytes(),
                   runner_path: (ROOT / runner_path).read_bytes(),
                   workflow_path: (ROOT / workflow_path).read_bytes()}
        self.input_hashes = {path: digest(data) for path, data in current.items()}
        self.manifest.update(
            baseline_blob=actual_blob,
            source_sha256={"baseline": digest(baseline), "candidate": digest(candidate)},
            input_sha256=self.input_hashes,
            identical_outside_nearest=True, identical_original_key_fields=True,
            identical_async_tail=True,
            extraction_sha256={
                variant: {field: digest(text.encode()) for field, text in values.items()}
                for variant, values in parts.items()},
            generated_sha256={variant: digest(text.encode()) for variant, text in generated.items()})
        (self.out / "inputs/baseline-cache.swift").write_bytes(baseline)
        (self.out / "inputs/candidate-cache.swift").write_bytes(candidate)
        (self.out / "inputs/Portable.swift").write_bytes(current[driver_path])
        (self.out / "inputs/portable.py").write_bytes(current[runner_path])
        (self.out / "inputs/workflow.yml").write_bytes(current[workflow_path])
        self.binaries = {}
        flags = [*FLAGS, "-module-cache-path", str(self.out / "build/modules")]
        suffix = ".dylib" if platform.system() == "Darwin" else ".so"
        for variant, text in generated.items():
            projected = self.out / "inputs" / f"{variant}-plan.swift"
            projected.write_text(text)
            directory = self.out / "build" / variant
            directory.mkdir()
            library = directory / ("libThumbnailNearestPlan" + suffix)
            self.run(["swiftc", *flags, "-enable-testing", "-emit-library", "-emit-module",
                      "-module-name", "ThumbnailNearestPlan", "-emit-module-path",
                      directory / "ThumbnailNearestPlan.swiftmodule", projected, "-o", library])
            binary = directory / "portable-probe"
            self.run(["swiftc", *flags, "-I", directory, "-L", directory,
                      "-lThumbnailNearestPlan", "-Xlinker", "-rpath", "-Xlinker", directory,
                      self.out / "inputs/Portable.swift", "-o", binary])
            self.binaries[variant] = binary
            self.manifest.setdefault("binary_sha256", {})[variant] = {
                "module": digest(library.read_bytes()), "driver": digest(binary.read_bytes())}

    def measure(self, variant, case, iterations):
        row = json.loads(self.run([self.binaries[variant], "--mode", "measure",
                                  "--case", case, "--iterations", str(iterations)]))
        if (row["case"] != case or row["iterations"] != iterations
                or row["operations"] != iterations or row["elapsed_ns"] <= 0
                or row["candidate_count"] < 0 or "checksum" not in row):
            raise ValueError("Invalid measurement receipt")
        row["ns_per_operation"] = row["elapsed_ns"] / iterations
        return row

    def benchmark(self):
        receipts = {}
        for variant, binary in self.binaries.items():
            receipts[variant] = json.loads(self.run([binary, "--mode", "verify"]))
            write_json(self.out / "receipts" / f"{variant}.json", receipts[variant])
        if receipts["baseline"] != receipts["candidate"]:
            raise ValueError("Complete ordered-key verification receipts differ")
        receipt = receipts["candidate"]
        cases = receipt["cases"]
        if not cases or len(cases) != len(set(cases)):
            raise ValueError("Empty or duplicate case cohort")
        canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"),
                                             allow_nan=False).encode()
        verification = {"all_ordered_key_receipts_equal": True, "scope": SCOPE,
                        "fixtures": len(receipt["fixtures"]), "cases": cases,
                        "full_receipt_sha256": digest(canonical(receipt)),
                        "fixture_sha256": [
                            {"name": item["name"], "sha256": digest(canonical(item))}
                            for item in receipt["fixtures"]]}
        write_json(self.out / "verification.json", verification)
        emit("VERIFICATION", verification)
        observations, calibration, summary = [], [], {}
        for case in cases:
            initial = {variant: self.measure(variant, case, 1000) for variant in self.binaries}
            calibration += [{"variant": variant, "stage": "initial", **row}
                            for variant, row in initial.items()]
            fastest = min(row["elapsed_ns"] / 1000 for row in initial.values())
            target = self.args.target_ms * 1_000_000
            count = max(1000, math.ceil(1.05 * target / fastest))
            for attempt in range(5):
                pilot = {variant: self.measure(variant, case, count) for variant in self.binaries}
                calibration += [{"variant": variant, "stage": f"target-{attempt}", **row}
                                for variant, row in pilot.items()]
                write_json(self.out / "calibration.json", calibration)
                fastest_elapsed = min(row["elapsed_ns"] for row in pilot.values())
                if fastest_elapsed >= target:
                    break
                count = max(count + 1, math.ceil(1.05 * count * target / fastest_elapsed))
            else:
                raise ValueError(f"Calibration did not reach target duration: {case}")
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                matched = {}
                for position, variant in enumerate(order):
                    row = self.measure(variant, case, count)
                    row.update(variant=variant, pair=pair, position=position)
                    matched[variant] = row
                    observations.append(row)
                    with (self.out / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
                    emit("MEASUREMENT", row)
                for field in ("iterations", "operations", "checksum", "candidate_count"):
                    if matched["baseline"][field] != matched["candidate"][field]:
                        raise ValueError(f"Paired receipt mismatch: {case}/{pair}/{field}")
            rows = [row for row in observations if row["case"] == case]
            result = {}
            for variant in self.binaries:
                values = [row["ns_per_operation"] for row in rows if row["variant"] == variant]
                result[variant] = {"median_ns": statistics.median(values),
                                   "min_ns": min(values), "max_ns": max(values)}
            changes = []
            for pair in range(self.args.pairs):
                values = {row["variant"]: row["ns_per_operation"] for row in rows if row["pair"] == pair}
                changes.append(100 * (1 - values["candidate"] / values["baseline"]))
            result["paired_reduction_percent"] = {
                "median": statistics.median(changes), "min": min(changes), "max": max(changes),
                "values": changes, "candidate_faster_pairs": sum(value > 0 for value in changes),
                "pairs": len(changes)}
            result["minimum_sample_ms"] = min(row["elapsed_ns"] for row in rows) / 1_000_000
            summary[case] = result
            write_json(self.out / "summary.json", summary)
            emit("SUMMARY", {case: result})

    def execute(self):
        try:
            self.prepare()
            self.benchmark()
            for path, expected in self.input_hashes.items():
                if digest((ROOT / path).read_bytes()) != expected:
                    raise ValueError(f"Input changed during probe: {path}")
            self.manifest.update(status="passed", inputs_unchanged=True)
        except Exception as error:
            self.manifest["status"] = "failed"
            write_json(self.out / "failure.json", {"type": type(error).__name__, "message": str(error)})
            raise
        finally:
            self.manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
            write_json(self.out / "manifest.json", self.manifest)
            emit("MANIFEST", self.manifest)
            for record in self.commands:
                emit("COMMAND", record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms < 50:
        parser.error("Use an even pair count >= 2 and target >= 50 ms")
    Probe(args).execute()


if __name__ == "__main__":
    main()
