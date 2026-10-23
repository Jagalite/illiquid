#!/usr/bin/env python3
"""Measure actual native PCM sample-buffer creation and retained allocator bytes.

Requires macOS, CoreMedia, and Swift. It stages complete production declarations
without rewriting the sample construction, frame data type, or error handling.
Native decoder/renderer integration is qualified separately by the app tests.
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
BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
PRESENTER = "Sources/IlliquidNativePlayback/Presentation/SampleBufferAudioPresenter.swift"
FRAME = "Sources/IlliquidNativePlayback/Media/AudioDecoder.swift"
ERROR = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
HELPER = "Sources/IlliquidNativePlayback/Presentation/AudioPCMBlockBuffer.swift"
VARIANTS = ("baseline", "candidate")
CASES = [f"c{channels}-s{samples}" for channels in (1, 2, 6, 8)
         for samples in (1, 128, 1024, 8192)] + [
             f"c{channels}-s{samples}-{storage}" for channels in (1, 2, 6, 8)
             for samples in (1024, 8192) for storage in ("resampler-spare", "trimmed")
         ] + ["c2-s1024-huge-parent"]


def sha(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1:
        raise ValueError(f"Expected one extraction start {start!r}")
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        self.commands = []
        self.env = os.environ.copy()
        self.swiftc = os.path.abspath(args.swiftc or shutil.which("swiftc") or "swiftc")
        self.clang = self.command(["xcrun", "--find", "clang"]).strip()
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        self.target = f"{platform.machine()}-apple-macosx26.0"
        self.manifest = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "worktree_status": self.command(["git", "status", "--porcelain"]).splitlines(),
            "platform": platform.platform(), "machine": platform.machine(),
            "host": self.command(["sw_vers"]),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "compiler_sha256": sha(Path(self.swiftc).read_bytes()),
            "clang": self.command([self.clang, "--version"]).strip(),
            "sdk": self.sdk, "target": self.target,
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "sources": {}, "compiled_inputs": {}, "binaries": {},
            "protocol": {
                "pairs": args.pairs, "target_ms": args.target_ms,
                "retained_frames": args.retained_frames,
                "warmup_calls": 512, "case_names": args.case or CASES,
                "timing": "full production makeSampleBuffer; sample released each iteration",
                "memory": "Darwin malloc_zone_statistics(NULL).size_in_use",
                "primary_endpoint": "live allocator bytes during source/sample overlap AND samples-only retention",
                "secondary_endpoints": "samples-only and final-release allocator bytes; construction CPU/wall",
                "acceptance": [
                    "All exact-output checks and authored byte/lifetime/validation assertions pass in debug and release.",
                    "All >=4096-byte cases show a repeatable overlap-allocator reduction with source-address sharing.",
                    "Any samples-only retained-byte regression must be reported and reviewed before a memory-success claim.",
                    "Resampler-spare, trimmed, and huge-parent controls may retain source allocation slack; overlap alone is insufficient.",
                    "No unreleased payload remains after both source and sample arrays are dropped.",
                    "Report small-buffer overhead and any consistent CPU or wall regression >=5%.",
                    "No whole-player, RSS, or GPU-memory claim follows from this component result.",
                ],
            },
        }
        (self.output / "runner.snapshot.py").write_bytes(Path(__file__).read_bytes())

    def command(self, argv, *, name=None, timeout=300):
        argv = [str(value) for value in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        index = len(self.commands)
        stem = name or f"command-{index:04d}"
        stdout = self.output / "logs" / f"{stem}.stdout.log"
        stderr = self.output / "logs" / f"{stem}.stderr.log"
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        self.commands.append({"argv": argv, "exit_code": result.returncode,
                              "elapsed_seconds": time.monotonic() - start,
                              "stdout": str(stdout.relative_to(self.output)),
                              "stderr": str(stderr.relative_to(self.output)),
                              "stdout_sha256": sha(result.stdout),
                              "stderr_sha256": sha(result.stderr)})
        write_json(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n{result.stdout[-3000:]}\n{result.stderr[-7000:]}")
        return result.stdout

    def source(self, variant, path):
        raw = ((ROOT / path).read_text() if variant == "candidate" else
               self.command(["git", "show", f"{BASELINE}:{path}"]))
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(raw)
        self.manifest["sources"][f"{variant}:{path}"] = {
            "sha256": sha(raw), "bytes": len(raw.encode()),
            "git_blob_sha1": sha1_git_blob(raw.encode()),
        }
        return raw

    def stage(self):
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        common = self.output / "compiled" / "common"
        common.mkdir(parents=True)
        (common / "Driver.swift").write_bytes((HERE / "Driver.swift").read_bytes())
        probe = common / "CAudioPCMProbe"
        shutil.copytree(HERE / "CAudioPCMProbe", probe)
        (probe / "module.modulemap").write_text(
            'module CAudioPCMProbe {\n  header "include/CAudioPCMProbe.h"\n  export *\n}\n')
        self.command([self.clang, "-O2", "-target", self.target, "-isysroot", self.sdk,
                      "-I", probe / "include", "-c", probe / "probe.c", "-o", probe / "probe.o"],
                     name="build-heap-probe")
        shared = {}
        for variant in VARIANTS:
            presenter = self.source(variant, PRESENTER)
            frame = self.source(variant, FRAME)
            errors = self.source(variant, ERROR)
            method = extract(presenter, "    static func makeSampleBuffer(", "\n    func flush()")
            frame_type = extract(frame, "struct NativeDecodedAudioFrame: Sendable {", "\nextension NativeDecodedAudioFrame")
            error_types = errors[errors.index("struct PresentationError: LocalizedError {"):]
            if error_types.count("func checkOSStatus(") != 1:
                raise ValueError("Presentation error helper boundary changed")
            shared[variant] = (frame_type, error_types)
            compiled = self.output / "compiled" / variant
            compiled.mkdir()
            (compiled / "Presenter.swift").write_text(
                "import AudioToolbox\nimport CoreMedia\nimport Foundation\n\n"
                "enum SampleBufferAudioPresenter {\n" + method + "\n}\n")
            (compiled / "Frame.swift").write_text("import CoreMedia\nimport Foundation\n\n" + frame_type)
            (compiled / "Errors.swift").write_text("import AudioToolbox\nimport Foundation\n\n" + error_types)
            if variant == "candidate":
                (compiled / "AudioPCMBlockBuffer.swift").write_text(self.source(variant, HELPER))
            self.manifest["compiled_inputs"][variant] = {
                p.name: sha(p.read_bytes()) for p in sorted(compiled.glob("*.swift"))}
        if shared["baseline"] != shared["candidate"]:
            raise ValueError("Frame data type or error helpers differ; this experiment requires unchanged dependencies")
        self.manifest["compiled_inputs"]["common"] = {
            str(p.relative_to(common)): sha(p.read_bytes()) for p in sorted(common.rglob("*")) if p.is_file()}
        write_json(self.output / "manifest.json", self.manifest)

    def build(self):
        common = self.output / "compiled" / "common"
        probe = common / "CAudioPCMProbe"
        for variant in VARIANTS:
            for configuration, optimize in (("debug", "-Onone"), ("release", "-O")):
                executable = self.output / f"{variant}-{configuration}"
                flags = ["-swift-version", "6", optimize, "-parse-as-library", "-target", self.target,
                         "-sdk", self.sdk, "-module-cache-path", str(self.output / "module-cache"),
                         "-I", str(probe)]
                if configuration == "release":
                    flags.append("-whole-module-optimization")
                inputs = [*sorted((self.output / "compiled" / variant).glob("*.swift")),
                          common / "Driver.swift", probe / "probe.o"]
                self.command([self.swiftc, *flags, *inputs, "-o", executable],
                             name=f"build-{variant}-{configuration}", timeout=300)
                self.manifest["binaries"][f"{variant}-{configuration}"] = {
                    "sha256": sha(executable.read_bytes()), "flags": flags}
        write_json(self.output / "manifest.json", self.manifest)

    def verify(self):
        outputs = {}
        for variant in VARIANTS:
            for configuration in ("debug", "release"):
                key = f"{variant}-{configuration}"
                outputs[key] = json.loads(self.command([self.output / key, "verify"], name=f"verify-{key}"))
                write_json(self.output / f"verification-{key}.json", outputs[key])
        reference = outputs["baseline-release"]
        if any(output != reference for output in outputs.values()):
            raise ValueError("Complete verification receipts differ")
        result = {"exact_output_parity": True,
                  "configurations": list(outputs),
                  "authored_cases_per_configuration": reference["authored_cases"],
                  "pcm_cases": len(reference["outputs"]), "rejected_cases": len(reference["errors"]),
                  "canonical_sha256": sha(json.dumps(reference, sort_keys=True))}
        write_json(self.output / "parity.json", result)
        print(json.dumps(result, sort_keys=True), flush=True)

    def observe(self, variant, case, iterations, tag):
        row = json.loads(self.command([self.output / f"{variant}-release", "observe", case,
                                       str(iterations), str(self.args.retained_frames)], name=tag, timeout=180))
        if row["case"] != case or row["iterations"] != iterations:
            raise ValueError("Observation identity differs")
        if row["memory"]["retained_frames"] != self.args.retained_frames:
            raise ValueError("Memory fixture count differs")
        return row

    def measure(self):
        rows = []
        pilots = []
        for case in self.args.case or CASES:
            calibration = {}
            for variant in VARIANTS:
                row = self.observe(variant, case, 2048, f"pilot-{case}-{variant}")
                pilots.append({"variant": variant, **row})
                calibration[variant] = max(row["wall_ns"], row["cpu_ns"]) / row["iterations"]
            # Equal work per pair. Calibrate to the faster implementation so
            # both variants receive meaningful intervals, capped explicitly.
            per_call = min(calibration.values())
            iterations = min(1_000_000, max(2048, math.ceil(self.args.target_ms * 1e6 / per_call)))
            iterations = ((iterations + 15) // 16) * 16
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                pair_rows = []
                for position, variant in enumerate(order):
                    row = self.observe(variant, case, iterations, f"measure-{case}-{pair:02d}-{variant}")
                    row.update({"variant": variant, "pair": pair, "position": position})
                    rows.append(row)
                    pair_rows.append(row)
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                if pair_rows[0]["checksum"] != pair_rows[1]["checksum"]:
                    raise ValueError("Paired timed checksums differ")
            print(f"Measured {case}: {self.args.pairs} pairs x {iterations} calls", flush=True)
        write_json(self.output / "calibration.json", pilots)
        summary = {}
        for case in self.args.case or CASES:
            group = [r for r in rows if r["case"] == case]
            paired = [{variant: next(r for r in group if r["pair"] == pair and r["variant"] == variant)
                       for variant in VARIANTS} for pair in range(self.args.pairs)]
            result = {"pairs": self.args.pairs, "variants": {}, "paired": {}}
            for variant in VARIANTS:
                values = [r for r in group if r["variant"] == variant]
                result["variants"][variant] = {
                    "wall_ns_per_call": describe([r["wall_ns"] / r["iterations"] for r in values]),
                    "cpu_ns_per_call": describe([r["cpu_ns"] / r["iterations"] for r in values]),
                    "overlap_increment_bytes": describe([r["memory"]["overlap_increment_bytes"] for r in values]),
                    "source_increment_bytes": describe([r["memory"]["source_increment_bytes"] for r in values]),
                    "samples_only_increment_bytes": describe([r["memory"]["samples_only_increment_bytes"] for r in values]),
                    "released_increment_bytes": describe([r["memory"]["released_increment_bytes"] for r in values]),
                    "samples_sharing_source_address": describe([r["memory"]["samples_sharing_source_address"] for r in values]),
                    "minimum_wall_ms": min(r["wall_ns"] for r in values) / 1e6,
                    "minimum_cpu_ms": min(r["cpu_ns"] for r in values) / 1e6,
                    "payload_bytes_per_frame": values[0]["memory"]["payload_bytes_per_frame"],
                    "retained_frames": self.args.retained_frames,
                }
            for metric in ("wall_ns", "cpu_ns"):
                ratios = [100 * (p["candidate"][metric] / p["baseline"][metric] - 1) for p in paired]
                result["paired"][metric + "_percent_change"] = describe(ratios)
                result["paired"][metric + "_candidate_wins"] = sum(value < 0 for value in ratios)
            savings = [p["baseline"]["memory"]["overlap_increment_bytes"]
                       - p["candidate"]["memory"]["overlap_increment_bytes"] for p in paired]
            result["paired"]["overlap_bytes_saved"] = describe(savings)
            result["paired"]["overlap_candidate_wins"] = sum(value > 0 for value in savings)
            sample_savings = [p["baseline"]["memory"]["samples_only_increment_bytes"]
                             - p["candidate"]["memory"]["samples_only_increment_bytes"] for p in paired]
            result["paired"]["samples_only_bytes_saved"] = describe(sample_savings)
            result["paired"]["samples_only_candidate_wins"] = sum(value > 0 for value in sample_savings)
            summary[case] = result
        write_json(self.output / "summary.json", summary)
        print(json.dumps(summary, sort_keys=True, indent=2), flush=True)


def sha1_git_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def describe(values):
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=200)
    parser.add_argument("--retained-frames", type=int, default=32)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This benchmark requires native macOS CoreMedia")
    if args.pairs < 2 or args.target_ms <= 0 or args.retained_frames < 1:
        parser.error("pairs >= 2, target-ms > 0, and retained-frames >= 1 are required")
    runner = Runner(args)
    runner.stage()
    runner.build()
    runner.verify()
    if not args.tests_only:
        runner.measure()
    runner.manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
    runner.manifest["completed"] = True
    write_json(runner.output / "manifest.json", runner.manifest)
    write_json(runner.output / "completion.json", {"tests_passed": True,
               "measurements_completed": not args.tests_only, "candidate_revision": runner.manifest["candidate_revision"]})


if __name__ == "__main__":
    main()
