#!/usr/bin/env python3
"""Compare exact production audio metadata preparation with real FFmpeg frames.

This runner needs Swift and the pinned FFmpeg headers/libavutil. It does not
download dependencies, substitute FFmpeg behavior, or compile Apple frameworks.
The full native decoder graph is qualified separately by the workflow.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import textwrap
import time

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "a2de305c8dbcaa81aac1477df7c9a0017c14eae3"
DECODER = "Sources/IlliquidNativePlayback/Media/AudioDecoder.swift"
HELPER = "Sources/IlliquidNativePlayback/Media/AudioSourceFormat.swift"
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
STREAM = "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift"
ERROR = "Sources/IlliquidNativePlayback/Media/FFmpegError.swift"
CASES = ["stable_mono", "stable_stereo", "stable_5_1", "stable_7_1", "stable_unspecified",
         "stable_custom", "stable_ambisonic", "rate_changes", "sample_format_changes",
         "output_changes", "same_count_layout_changes", "native_changes_every_frame",
         "custom_changes_every_frame"]
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library"]


def sha(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1:
        raise ValueError(f"Expected one extraction start: {start!r}")
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]


def c_function(source: str, name: str) -> str:
    match = re.search(r"(?m)^static inline [^\n]*\b" + re.escape(name) + r"\(", source)
    if match is None:
        raise ValueError(f"Missing C function {name}")
    end = source.index("\n}", match.start()) + 2
    result = source[match.start():end]
    if result.count("{") != result.count("}"):
        raise ValueError(f"Review changed shim extraction {name}")
    return result + "\n"


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.env = os.environ.copy()
        self.swiftc = os.path.abspath(args.swiftc or shutil.which("swiftc") or "swiftc")
        self.prefix = args.ffmpeg_prefix.resolve()
        self.module = self.output / "CFFmpeg"
        self.module.mkdir()
        self.common_flags = [*FLAGS, "-I", str(self.module), "-Xcc", "-I" + str(self.prefix / "include"),
                             "-L", str(self.prefix / "lib"), "-lavutil", "-Xlinker", "-rpath",
                             "-Xlinker", str(self.prefix / "lib"), "-module-cache-path", str(self.output / "module-cache")]
        if platform.system() == "Linux":
            self.common_flags += ["-lm", "-lpthread", "-ldl"]
        self.receipt = {"started_utc": datetime.now(timezone.utc).isoformat(),
                        "baseline_revision": args.baseline, "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
                        "platform": platform.platform(), "machine": platform.machine(),
                        "processor": platform.processor(), "flags": self.common_flags,
                        "compiler": self.command([self.swiftc, "--version"]).strip(),
                        "files": {}, "binaries": {}}

    def command(self, command, *, log=None):
        start = time.monotonic()
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.commands.append({"argv": [str(x) for x in command], "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - start,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)})
        if log:
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stdout[-4000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def source(self, variant, path):
        value = ((ROOT / path).read_text() if variant == "candidate" else
                 self.command(["git", "show", f"{self.args.baseline}:{path}"]))
        self.receipt["files"][f"{variant}:{path}"] = sha(value)
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)
        return value

    def prepare(self):
        shim = self.source("candidate", SHIM)
        old_shim = self.source("baseline", SHIM)
        names = ["illiquid_audio_frame_sample_rate", "illiquid_audio_frame_channel_count",
                 "illiquid_audio_frame_channel_layout_name", "illiquid_audio_frame_sample_count",
                 "illiquid_frame_sample_format", "illiquid_averror_exit", "illiquid_averror_invaliddata",
                 "illiquid_averror_eagain"]
        functions = [c_function(shim, name) for name in names]
        if functions != [c_function(old_shim, name) for name in names]:
            raise ValueError("Shared metadata shims differ; do not compare different FFmpeg wrappers")
        header = "#include <libavutil/avutil.h>\n#include <libavutil/frame.h>\n#include <libavutil/channel_layout.h>\n#include <libavutil/samplefmt.h>\n#include <libavutil/error.h>\n#include <string.h>\n#include <stdio.h>\n\n" + "\n".join(functions)
        # Fixture-only helper. Production behavior comes from the verbatim
        # shim functions above and the linked, real libavutil implementation.
        header += """
static inline int benchmark_custom_layout(AVFrame *frame, const char *name) {
    av_channel_layout_uninit(&frame->ch_layout);
    int result = av_channel_layout_custom_init(&frame->ch_layout, 2);
    if (result < 0) return result;
    frame->ch_layout.u.map[0].id = AV_CHAN_FRONT_LEFT;
    frame->ch_layout.u.map[1].id = AV_CHAN_FRONT_RIGHT;
    snprintf(frame->ch_layout.u.map[0].name, sizeof(frame->ch_layout.u.map[0].name), "%s-L", name);
    snprintf(frame->ch_layout.u.map[1].name, sizeof(frame->ch_layout.u.map[1].name), "%s-R", name);
    return 0;
}
"""
        (self.module / "metadata_shim.h").write_text(header)
        (self.module / "module.modulemap").write_text('module CFFmpeg [system] {\n  header "metadata_shim.h"\n  export *\n}\n')
        stream = self.source("candidate", STREAM)
        old_stream = self.source("baseline", STREAM)
        string_function = extract(stream, "func stringFromCStringBuffer(", "\nenum NativeStreamKind")
        if string_function != extract(old_stream, "func stringFromCStringBuffer(", "\nenum NativeStreamKind"):
            raise ValueError("String conversion differs between revisions")
        error = self.source("candidate", ERROR)
        if error != self.source("baseline", ERROR):
            raise ValueError("Shared FFmpegError differs between revisions")
        harness = (Path(__file__).parent / "Harness.swift").read_text()
        (self.output / "Harness.swift").write_text(harness)
        self.receipt["harness_sha256"] = sha(harness)
        self.receipt["runner_sha256"] = sha(Path(__file__).read_bytes())
        (self.output / "runner.snapshot.py").write_bytes(Path(__file__).read_bytes())
        self.receipt["extracted_c_sha256"] = sha(header)
        for variant in ("baseline", "candidate"):
            directory = self.output / variant
            directory.mkdir()
            raw = self.source(variant, DECODER)
            block = extract(raw, "        let sourceRate = illiquid_audio_frame_sample_rate(frame)",
                            "        if sourceFormatSignature != signature {")
            capacity = "        let outputChannels = outputCapacity.outputChannels(forSourceChannels: Int(sourceChannels))\n"
            if block.count(capacity) != 1:
                raise ValueError("Output capacity boundary changed; review extraction")
            block = textwrap.dedent(block.replace(capacity, ""))
            signature_type = "String" if variant == "baseline" else "AudioSourceFormat"
            cache = "" if variant == "baseline" else "private var channelLayoutNameCache = AudioChannelLayoutNameCache()"
            tracker = f"""import CFFmpeg
import Foundation

struct MetadataResult: Codable, Equatable {{
    let sampleRate: Int32
    let channelCount: Int32
    let channelLayout: String
    let sampleFormat: Int64
    let outputChannelCount: Int
    let changed: Bool
    let revision: UInt64
}}

struct MetadataTracker {{
    private var sourceFormatSignature: {signature_type}?
    {cache}
    private var revision: UInt64 = 0

    @inline(never)
    mutating func prepare(_ frame: UnsafeMutablePointer<AVFrame>, outputChannels: Int) throws -> MetadataResult {{
{textwrap.indent(block, '        ')}
        let changed = sourceFormatSignature != signature
        if changed {{
            sourceFormatSignature = signature
            revision += 1
        }}
        return MetadataResult(sampleRate: sourceRate, channelCount: sourceChannels,
                              channelLayout: sourceChannelLayout, sampleFormat: Int64(sampleFormat.rawValue),
                              outputChannelCount: outputChannels, changed: changed, revision: revision)
    }}
}}

{string_function}
"""
            sources = [directory / "Tracker.swift", directory / "FFmpegError.swift", self.output / "Harness.swift"]
            sources[0].write_text(tracker)
            sources[1].write_text(error)
            if variant == "candidate":
                helper = self.source(variant, HELPER)
                (directory / "AudioSourceFormat.swift").write_text(helper)
                sources.append(directory / "AudioSourceFormat.swift")
            self.receipt["files"][variant + ":extracted_block"] = sha(block)
            self.receipt["files"][variant + ":tracker"] = sha(tracker)
            binary = directory / "benchmark"
            print(f"Building {variant}", flush=True)
            self.command([self.swiftc, *self.common_flags, *sources, "-o", binary], log=directory / "compile.log")
            self.receipt["binaries"][variant] = {"path": str(binary), "sha256": sha(binary.read_bytes())}
        libs = list((self.prefix / "lib").glob("libavutil.*"))
        self.receipt["libavutil_files"] = {str(p): sha(p.read_bytes()) for p in libs if p.is_file() and not p.is_symlink()}
        write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant, *args):
        return json.loads(self.command([self.output / variant / "benchmark", *args]))

    def verify(self):
        traces = {}
        for variant in ("baseline", "candidate"):
            trace = self.invoke(variant, "verify")
            write_json(self.output / f"{variant}-trace.json", trace)
            traces[variant] = trace
        if traces["baseline"] != traces["candidate"]:
            raise ValueError("Metadata/revision traces differ; inspect saved traces")
        count = sum(len(v) for v in traces["candidate"]["workloads"].values()) + len(traces["candidate"]["mutatedFrame"])
        write_json(self.output / "parity.json", {"equal": True, "compared_frames": count,
                   "ffmpeg_version": traces["candidate"]["ffmpegVersion"],
                   "libavutil_version": traces["candidate"]["libavutilVersion"]})
        print(f"Exact metadata/revision parity: {count} frames", flush=True)

    def measure(self):
        observations = []
        summaries = []
        calibrations = []
        for case in self.args.cases:
            # Both members still run exactly the same number of preparations.
            # The cached candidate can be hundreds of times faster: calibrating
            # only the old path would leave its observations below one ms.
            # Two longer candidate pilots, their faster rate, and a 2x margin
            # reduce that risk. Actual durations are independently reported.
            pilots = {"baseline": [], "candidate": []}
            per_frame = {}
            for variant, pilot_iterations in (("baseline", 10_000), ("candidate", 100_000)):
                for _ in range(2):
                    pilots[variant].append(self.invoke(variant, "measure", case, str(pilot_iterations)))
                per_frame[variant] = min(p["elapsedNanoseconds"] / pilot_iterations for p in pilots[variant])
            requested = max(
                10_000,
                int(self.args.target_ms * 1_000_000 / max(1e-9, per_frame["baseline"])) + 1,
                *(int(2 * self.args.minimum_variant_ms * 1_000_000 / max(1e-9, value)) + 1
                  for value in per_frame.values()),
            )
            iterations = min(5_000_000, requested)
            calibrations.append({"workload": case, "pilots": pilots,
                                 "fastest_pilot_ns_per_frame": per_frame,
                                 "baseline_target_ms": self.args.target_ms,
                                 "minimum_variant_ms": self.args.minimum_variant_ms,
                                 "minimum_duration_margin": 2,
                                 "requested_iterations": requested, "iterations": iterations,
                                 "iteration_cap_applied": iterations != requested})
            write_json(self.output / "calibration.json", calibrations)
            pairs = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                values = {}
                for variant in order:
                    record = self.invoke(variant, "measure", case, str(iterations))
                    record.update({"variant": variant, "pair": pair, "order": list(order)})
                    values[variant] = record
                    observations.append(record)
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                for field in ("checksum", "last", "iterations"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise ValueError(f"Timed output mismatch in {case}/{pair}: {field}")
                pairs.append(values)
            old = [p["baseline"]["elapsedNanoseconds"] / iterations for p in pairs]
            new = [p["candidate"]["elapsedNanoseconds"] / iterations for p in pairs]
            ratio = statistics.median(new) / statistics.median(old)
            minimum_observed = {variant: min(p[variant]["elapsedNanoseconds"] / 1_000_000 for p in pairs)
                                for variant in ("baseline", "candidate")}
            under_minimum = [{"pair": p[variant]["pair"], "variant": variant,
                              "elapsed_ms": p[variant]["elapsedNanoseconds"] / 1_000_000}
                             for p in pairs for variant in ("baseline", "candidate")
                             if p[variant]["elapsedNanoseconds"] < self.args.minimum_variant_ms * 1_000_000]
            summary = {"workload": case, "iterations": iterations, "pairs": self.args.pairs,
                       "baseline_ns_per_frame": statistics.median(old), "candidate_ns_per_frame": statistics.median(new),
                       "change_percent": (ratio - 1) * 100,
                       "baseline_range_ns": [min(old), max(old)], "candidate_range_ns": [min(new), max(new)],
                       "minimum_observed_ms": minimum_observed,
                       "minimum_variant_ms": self.args.minimum_variant_ms,
                       "observations_under_minimum": under_minimum,
                       "paired_ratios": [p["candidate"]["elapsedNanoseconds"] / p["baseline"]["elapsedNanoseconds"] for p in pairs]}
            summaries.append(summary)
            print(f"{case}: {summary['baseline_ns_per_frame']:.1f} -> {summary['candidate_ns_per_frame']:.1f} ns/frame ({summary['change_percent']:+.1f}%)", flush=True)
            if under_minimum:
                print(f"  WARNING: {len(under_minimum)} observations below {self.args.minimum_variant_ms:g} ms; inspect raw durations", flush=True)
        write_json(self.output / "summary.json", summaries)
        return {"minimum_observation_duration_met": all(not s["observations_under_minimum"] for s in summaries),
                "minimum_variant_ms": self.args.minimum_variant_ms,
                "observations_under_minimum": sum(len(s["observations_under_minimum"]) for s in summaries)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--minimum-variant-ms", type=float, default=5,
                        help="Minimum target for each variant, calibrated with a 2x margin; short observations are flagged")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("Use an even number of at least two AB/BA pairs")
    if args.target_ms <= 0:
        parser.error("--target-ms must be positive")
    if args.minimum_variant_ms <= 0:
        parser.error("--minimum-variant-ms must be positive")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        runner.verify()
        duration = {} if args.tests_only else runner.measure()
        write_json(runner.output / "completion.json", {"complete": True, "tests_only": args.tests_only, **duration})
    finally:
        if runner:
            write_json(runner.output / "commands.json", runner.commands)


if __name__ == "__main__":
    main()
