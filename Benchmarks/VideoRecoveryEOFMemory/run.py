#!/usr/bin/env python3
"""Measure real compressed-packet backing lifetimes at MediaSession's EOF boundary."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SESSION = "Sources/IlliquidNativePlayback/Media/MediaSession.swift"
SUPPORT = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/IlliquidNativePlayback/Playback/PlaybackGeneration.swift",
    "Sources/IlliquidNativePlayback/Runtime/VideoFrameCapacityGate.swift",
]
NATIVE_TEST = "Tests/IlliquidNativePlaybackTests/VideoRecoveryEOFLifetimeTests.swift"
SCENARIOS = ["empty", "small", "budget", "repeated-eof", "failed-drain",
             "cancelled-drain", "stale-eof", "held-owner", "new-generation"]
BOUNDARIES = [
    ("    private func decodeVideoPacket(\n", "    private func reportVideoDecodeFailure("),
    ("    private func takePendingVideoRecoveryReplay()", "    private func videoDecodeLoop()"),
    ("    private func videoDecodeLoop()", "    private func audioDecodeLoop()"),
]
EQUAL_FIELDS = ["output", "endOfStreamGenerations", "stalePackets", "reportedFailures",
                "replayCount", "decoderFlushes", "independentOwnersSurvived", "allAllocationsFreedAtCleanup"]
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def extract(source):
    methods = []
    for start, end in BOUNDARIES:
        if source.count(start) != 1 or source.count(end) != 1:
            raise RuntimeError("Review changed production extraction boundaries")
        a, b = source.index(start), source.index(end)
        if a >= b:
            raise RuntimeError("Production extraction boundaries are out of order")
        methods.append(source[a:b].rstrip() + "\n")
    return methods


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.receipt = {
            "schema": 1, "baseline": BASE, "complete": False,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "machine": platform.machine(),
            "pairs": args.pairs, "scenarios": SCENARIOS,
            "source_hashes": {}, "staged_hashes": {}, "binary_hashes": {},
            "extractions": {}, "comparisons": [], "negative_controls": [],
            "environment": {key: os.environ.get(key) for key in (
                "DEVELOPER_DIR", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR",
                "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")},
            "scope": "Exact session methods with controlled decoder/queues and real FFmpeg packet ownership. "
                     "Separate native tests validate actual decoded pixel safety. No whole-player RSS or timing claim.",
            "metric": "Live backing AVBufferRef.size bytes including FFmpeg input padding, excluding packet/ref "
                      "metadata and allocator overhead. Counter transfers the sole original reference, retaining no observer.",
        }
        self.environment = os.environ.copy()
        self.environment["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(self.output / "module-cache")
        if not KYOTO.is_file():
            print("Kyoto is unavailable on this host; builds run directly and serially in isolated directories.", flush=True)

    def checkpoint(self):
        save(self.output / "manifest.json", self.receipt)
        save(self.output / "commands.json", self.commands)

    def command(self, args, name, *, check=True, build=False):
        args = list(map(str, args))
        if build and KYOTO.is_file():
            cli = ["python3", str(KYOTO)]
            submitted = self.command([*cli, "submit", "--", *args], name + "-submit")
            job = str(json.loads(submitted.stdout)["id"])
            self.command([*cli, "show", job], name + "-show")
            waited = self.command([*cli, "wait", job], name + "-wait", check=False)
            logs = self.command([*cli, "logs", job], name + "-logs")
            if waited.returncode:
                raise RuntimeError(f"Kyoto build {job} failed; retained show/wait/logs receipts")
            return logs
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=self.environment,
                                capture_output=True, text=True, timeout=1800)
        path = self.output / "logs" / f"{len(self.commands):04d}-{name}.log"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(result.stdout + result.stderr)
        self.commands.append({"argv": args, "returncode": result.returncode,
                              "seconds": time.monotonic() - started,
                              "log": str(path.relative_to(self.output)),
                              "stdout_sha256": sha(result.stdout.encode()),
                              "stderr_sha256": sha(result.stderr.encode())})
        self.checkpoint()
        if check and result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n{result.stdout[-2000:]}\n{result.stderr[-6000:]}")
        return result

    def stage(self, relative, data):
        data = data.encode() if isinstance(data, str) else data
        path = self.output / "sources" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.receipt["staged_hashes"][str(path.relative_to(self.output))] = sha(data)
        return path

    def prepare(self):
        self.receipt["head"] = self.command(["git", "rev-parse", "HEAD"], "head").stdout.strip()
        self.receipt["working_tree"] = self.command(["git", "status", "--short"], "status").stdout
        self.swiftc = self.command(["xcrun", "--find", "swiftc"], "swiftc").stdout.strip()
        self.receipt["compiler"] = self.command([self.swiftc, "--version"], "compiler-version").stdout.strip()
        self.receipt["host"] = self.command(["sw_vers"], "host").stdout.strip()
        self.receipt["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").stdout.strip()
        sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").stdout.strip()
        self.receipt["sdk"] = sdk
        self.receipt["sdk_version"] = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version").stdout.strip()
        packages = ["libavformat", "libavfilter", "libavcodec", "libavutil", "libswresample", "libswscale"]
        versions = self.command(["pkg-config", "--modversion", *packages], "ffmpeg-versions").stdout.splitlines()
        self.receipt["ffmpeg"] = dict(zip(packages, versions))
        expected = dict(zip(packages, ["62.12.102", "11.14.102", "62.28.102", "60.26.102", "6.3.102", "9.5.102"]))
        if self.receipt["ffmpeg"] != expected:
            raise RuntimeError("This experiment requires the repository's pinned FFmpeg 8.1.2 SDK")
        cflags = shlex.split(self.command(["pkg-config", "--cflags", *packages], "cflags").stdout)
        libs = shlex.split(self.command(["pkg-config", "--libs", *packages], "libs").stdout)
        self.flags = ["-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                      "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0",
                      "-I", str(self.output / "sources/CFFmpeg"),
                      "-I", str(self.output / "sources/CREcoveryEOFProbe"),
                      "-module-cache-path", str(self.output / "module-cache")]
        for flag in cflags:
            self.flags += ["-Xcc", flag]
        for flag in libs:
            self.flags += ["-Xlinker", flag]
        # Retain full source bytes, not just extracted fragments or their hashes.
        shared = []
        for relative in [*SUPPORT, "Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h",
                         SESSION, NATIVE_TEST, "Tests/IlliquidNativePlaybackTests/VideoScratchFrameLifetimeTests.swift",
                         "Tests/IlliquidNativePlaybackTests/PacketOwnershipTests.swift",
                         "Benchmarks/VideoRecoveryEOFMemory/Probe.h",
                         "Benchmarks/VideoRecoveryEOFMemory/Harness.swift.in",
                         "Benchmarks/VideoRecoveryEOFMemory/run.py",
                         ".github/workflows/video-recovery-eof-memory.yml"]:
            data = (ROOT / relative).read_bytes()
            self.receipt["source_hashes"][relative] = sha(data)
            self.stage("originals/" + relative, data)
            if relative in SUPPORT:
                shared.append(self.stage("shared/" + Path(relative).name, data))
        for relative in ["module.modulemap", "include/ffmpeg_shim.h"]:
            self.stage("CFFmpeg/" + relative, (ROOT / "Sources/CFFmpeg" / relative).read_bytes())
        self.stage("CREcoveryEOFProbe/Probe.h", (HERE / "Probe.h").read_bytes())
        self.stage("CREcoveryEOFProbe/module.modulemap",
                   'module CREcoveryEOFProbe {\n header "Probe.h"\n export *\n}\n')
        template = (HERE / "Harness.swift.in").read_text()
        marker = "    // __PRODUCTION_METHODS__"
        if template.count(marker) != 1:
            raise RuntimeError("Harness injection marker changed")
        baseline = self.command(["git", "show", f"{BASE}:{SESSION}"], "baseline-source").stdout
        self.stage("baseline/MediaSession.swift", baseline)
        self.receipt["baseline_source_sha256"] = sha(baseline.encode())
        self.sources = {}
        for variant, source in [("baseline", baseline), ("candidate", (ROOT / SESSION).read_text())]:
            methods = extract(source)
            self.receipt["extractions"][variant] = [
                {"start": bounds[0], "end": bounds[1], "sha256": sha(method.encode())}
                for bounds, method in zip(BOUNDARIES, methods)]
            harness = self.stage(f"{variant}/Harness.swift", template.replace(marker, "\n".join(methods)))
            self.sources[variant] = [*shared, harness]
        self.checkpoint()

    def build(self):
        directory = self.output / "binaries"
        directory.mkdir()
        self.binaries = {}
        for configuration, flag in [("debug", "-Onone"), ("release", "-O")]:
            for variant in ("baseline", "candidate"):
                binary = directory / f"{configuration}-{variant}"
                defines = ["-D", "BASELINE"] if variant == "baseline" else []
                self.command([self.swiftc, flag, *self.flags, *defines, *self.sources[variant], "-o", binary],
                             f"build-{configuration}-{variant}", build=True)
                self.binaries[configuration, variant] = binary
                self.receipt["binary_hashes"][str(binary.relative_to(self.output))] = sha(binary.read_bytes())
        self.checkpoint()

    def validate(self, row, variant, scenario):
        if row["implementation"] != variant or row["scenario"] != scenario or row["ffmpegVersion"] != "8.1.2":
            raise RuntimeError("Report identity or FFmpeg version changed")
        observations = row["observations"]
        before = observations["before-run"]
        count = 0 if scenario == "empty" else (512 if scenario == "budget" else 4)
        if before["liveAllocations"] != count or before["totalAllocations"] != count:
            raise RuntimeError("Fixture did not own the expected number of native allocations")
        if not row["allAllocationsFreedAtCleanup"] or not row["independentOwnersSurvived"]:
            raise RuntimeError("Native lifetime or surviving-owner invariant failed")
        # Establish that the candidate has not moved cleanup before drain returns.
        if scenario not in ("failed-drain", "cancelled-drain"):
            inside = observations["drain-before-return-1"]
            if inside["liveBytes"] != before["liveBytes"] or inside["liveAllocations"] != count:
                raise RuntimeError("Recovery ownership disappeared before the drain returned")
        at_eof = observations["eos-enqueue-1"]
        if variant == "candidate" and scenario != "held-owner":
            if at_eof["liveBytes"] != 0 or at_eof["liveAllocations"] != 0:
                raise RuntimeError("Candidate retained recovery packet storage at EOF")
        if variant == "baseline":
            if at_eof["liveBytes"] != before["liveBytes"] or at_eof["liveAllocations"] != count:
                raise RuntimeError("Baseline did not reproduce EOF retention")

    def run(self):
        self.prepare()
        self.build()
        observations = []
        canonical_outputs = {}
        for configuration in ("debug", "release"):
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for scenario in SCENARIOS:
                    rows = {}
                    for variant in order:
                        label = f"{configuration}-{scenario}-{pair}-{variant}"
                        result = self.command([self.binaries[configuration, variant], scenario], label)
                        row = json.loads(result.stdout)
                        self.validate(row, variant, scenario)
                        rows[variant] = row
                        save(self.output / "metrics" / f"{label}.json", row)
                        observations.append({
                            "configuration": configuration, "pair": pair, "scenario": scenario,
                            "variant": variant, "observations": row["observations"],
                            "output_count": len(row["output"]),
                            "output_sha256": sha(json.dumps(row["output"], sort_keys=True).encode()),
                            "report_sha256": sha((self.output / "metrics" / f"{label}.json").read_bytes()),
                        })
                    for field in EQUAL_FIELDS:
                        if rows["baseline"].get(field) != rows["candidate"].get(field):
                            raise RuntimeError(f"Observable behavior changed: {configuration}/{scenario}/{field}")
                    behavior = {field: rows["candidate"].get(field) for field in EQUAL_FIELDS}
                    if scenario in canonical_outputs and canonical_outputs[scenario] != behavior:
                        raise RuntimeError(f"Behavior changed across builds/processes: {scenario}")
                    canonical_outputs[scenario] = behavior
                    self.receipt["comparisons"].append({
                        "configuration": configuration, "pair": pair, "scenario": scenario,
                        "complete_output_equal": True, "output_count": len(rows["candidate"]["output"]),
                    })
            # Both binaries must have built and run normally before negative controls.
            negative = self.command([self.binaries[configuration, "baseline"], "small", "--require-eof-release"],
                                    f"negative-{configuration}", check=False)
            if negative.returncode != 73 or "EOF_RELEASE_REGRESSION" not in negative.stderr:
                raise RuntimeError("Baseline negative control did not fail for the expected lifetime regression")
            self.command([self.binaries[configuration, "candidate"], "small", "--require-eof-release"],
                         f"positive-{configuration}")
            self.receipt["negative_controls"].append({
                "configuration": configuration, "baseline_exit": 73, "marker": "EOF_RELEASE_REGRESSION",
                "candidate_passed": True,
            })
        for relative, expected in self.receipt["source_hashes"].items():
            if sha((ROOT / relative).read_bytes()) != expected:
                raise RuntimeError(f"Source changed during qualification: {relative}")
        for relative, expected in self.receipt["binary_hashes"].items():
            if sha((self.output / relative).read_bytes()) != expected:
                raise RuntimeError(f"Binary changed during qualification: {relative}")
        save(self.output / "observations.json", observations)
        (self.output / "complete-outputs.json").write_text(json.dumps(canonical_outputs, sort_keys=True) + "\n")
        summary = []
        for configuration in ("debug", "release"):
            for scenario in SCENARIOS:
                selected = [row for row in observations if row["configuration"] == configuration
                            and row["scenario"] == scenario]
                by_variant = {variant: [row for row in selected if row["variant"] == variant]
                              for variant in ("baseline", "candidate")}
                if any(len(rows) != self.args.pairs for rows in by_variant.values()):
                    raise RuntimeError("Missing paired observation")
                entry = {"configuration": configuration, "scenario": scenario, "pairs": self.args.pairs}
                for variant, rows in by_variant.items():
                    first = rows[0]["observations"]["eos-enqueue-1"]
                    if any(row["observations"]["eos-enqueue-1"] != first for row in rows):
                        raise RuntimeError("Final-release counters were not reproducible across fresh processes")
                    entry[variant] = first
                    entry["output_count"] = rows[0]["output_count"]
                summary.append(entry)
        save(self.output / "summary.json", {
            "passed": True, "configurations": ["debug", "release"],
            "scenario_count": len(SCENARIOS), "pairs": self.args.pairs,
            "complete_output_comparisons": len(self.receipt["comparisons"]),
            "negative_controls": self.receipt["negative_controls"], "results": summary,
        })
        self.receipt["complete"] = True
        self.receipt["finished_utc"] = datetime.now(timezone.utc).isoformat()
        self.checkpoint()
        print(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=2)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This native ownership experiment requires macOS and the pinned FFmpeg SDK")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two")
    study = Study(args)
    try:
        study.run()
    except Exception as error:
        study.receipt["error"] = str(error)
        study.checkpoint()
        raise


if __name__ == "__main__":
    main()
