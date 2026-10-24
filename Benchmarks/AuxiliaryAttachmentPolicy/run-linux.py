#!/usr/bin/env python3
"""Measure actual FFmpeg opens with extracted production attachment projection.

Linux component experiment only: this does not compile the macOS demuxer,
executor, decoders, subtitle renderer or player graph.
"""
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
STREAM = "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift"
TIME = "Sources/IlliquidNativePlayback/Media/MediaTime.swift"
FONT = "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift"
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
SOURCE_PATHS = [DEMUXER, STREAM, TIME, FONT, PRESENTATION, SHIM]
C_HELPERS = ["illiquid_nopts_value", "illiquid_chapter_count", "illiquid_chapter_at",
             "illiquid_metadata_value", "illiquid_codecpar_rotation_degrees",
             "illiquid_codecpar_display_matrix_is_mirrored", "illiquid_codecpar_field_order",
             "illiquid_codecpar_channel_layout_name"]
CASES = ["none", "fonts-128kib", "fonts-2mib", "fonts-16mib", "fonts-64mib", "mixed"]
METRICS = ["allocator_open_delta_bytes", "allocator_while_open_bytes",
           "allocator_release_delta_bytes", "process_max_rss_while_open_bytes",
           "opening_wall_seconds", "opening_cpu_seconds", "total_retained_payload_bytes"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise ValueError(f"Expected one declaration marker: {marker}")
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"Unbalanced declaration: {marker}")
    return source[start:end]


def projection_files(original: dict[str, bytes], candidate: bool) -> tuple[dict[str, bytes], list]:
    demuxer = original[DEMUXER].decode()
    marker = "    private static func makeMediaInfo("
    if demuxer.count(marker) != 1 or not demuxer.rstrip().endswith("}"):
        raise ValueError("Demuxer projection extraction boundary changed")
    # Preserve the complete production suffix: projection and its three helpers.
    suffix = demuxer[demuxer.index(marker):].rstrip()[:-1]
    for helper in ["bestPlayableSubtitleIndex", "bestStream", "metadataValue"]:
        if f"private static func {helper}(" not in suffix:
            raise ValueError(f"Missing original projection helper: {helper}")
    suffix = suffix.replace("private static func makeMediaInfo(", "static func makeMediaInfo(", 1)
    policy = declaration(demuxer, "enum FFmpegAttachmentPolicy:") + "\n" if candidate else ""
    if not candidate and "attachmentPolicy" in suffix:
        raise ValueError("Baseline already contains attachment policy; choose the pre-change commit")
    streams = original[STREAM].decode()
    if streams.count("import CoreGraphics\n") != 1:
        raise ValueError("CoreGraphics import adaptation boundary changed")
    time_source = original[TIME].decode()
    rational = declaration(time_source, "struct FFmpegRational:")
    seconds = declaration(time_source, "    static func seconds(")
    presentation = declaration(original[PRESENTATION].decode(), "struct PresentationError:")
    files = {
        "Projection.swift": ("import CFFmpeg\nimport Foundation\n" + policy
                             + "enum FFmpegProjection {\n" + suffix + "\n}\n").encode(),
        "FFmpegStreamInfo.swift": streams.replace("import CoreGraphics\n", "", 1).encode(),
        "MediaTime.swift": ("import CFFmpeg\nimport Foundation\n" + rational
                            + "\nenum MediaTime {\n" + seconds + "\n}\n").encode(),
        "FontAttachmentStore.swift": original[FONT],
        "PresentationError.swift": ("import Foundation\n" + presentation + "\n").encode(),
    }
    adaptations = [
        "Extract entire exact FFmpegDemuxer projection/helper suffix into FFmpegProjection enum; remove only makeMediaInfo private access",
        "Candidate includes exact FFmpegAttachmentPolicy declaration; baseline has no policy argument",
        "Remove CoreGraphics import; Linux Foundation supplies CGSize; retain all stream/info declarations",
        "Extract exact FFmpegRational and MediaTime.seconds, omitting unused CoreMedia/CMTime functions",
        "Compile complete FontAttachmentStore and exact PresentationError declaration",
    ]
    return files, adaptations


def shim_source(original: str) -> str:
    helpers = []
    for name in C_HELPERS:
        position = original.index(name + "(")
        start = original.rfind("static inline", 0, position)
        signature = original[start:position + len(name) + 1]
        helpers.append(declaration(original, signature))
    return """#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/display.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/sha.h>
#include <libavutil/mem.h>
#include <stdint.h>
#include <errno.h>
#include <math.h>
#include <malloc.h>
""" + "\n\n".join(helpers) + """

// Measurement-only helpers. These are not replacements for FFmpeg structures.
typedef struct {
    uint64_t arena_used_bytes;
    uint64_t mmap_bytes;
    uint64_t total_bytes;
} auxiliary_study_heap_statistics;
static inline auxiliary_study_heap_statistics auxiliary_study_heap(void) {
    struct mallinfo2 value = mallinfo2();
    auxiliary_study_heap_statistics result = {
        value.uordblks, value.hblkhd, value.uordblks + value.hblkhd
    };
    return result;
}
static inline int auxiliary_study_sha256(const uint8_t *data, size_t count, uint8_t *digest) {
    struct AVSHA *state = av_sha_alloc();
    if (!state) return -1;
    int result = av_sha_init(state, 256);
    if (result == 0) {
        if (count > 0) av_sha_update(state, data, count);
        av_sha_final(state, digest);
    }
    av_free(state);
    return result;
}
static inline int auxiliary_study_averror_eof(void) { return AVERROR_EOF; }
"""


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        args.baseline = subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}"],
            cwd=ROOT, text=True,
        ).strip()
        if len(args.baseline) != 40 or any(c not in "0123456789abcdef" for c in args.baseline):
            raise ValueError("Baseline did not resolve to one immutable commit SHA")
        self.prefix = args.ffmpeg_prefix.resolve()
        self.swift = args.swift or shutil.which("swiftc")
        if not self.swift:
            raise ValueError("Pass --swift /path/to/swiftc")
        if Path(self.swift).name == "swift":
            self.swift = str(Path(self.swift).with_name("swiftc"))
        self.env = os.environ.copy()
        self.env["LD_LIBRARY_PATH"] = str(self.prefix / "lib") + ":" + self.env.get("LD_LIBRARY_PATH", "")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.binaries = {}
        self.command_count = 0

    def run(self, argv, label, timeout=300):
        argv = list(map(str, argv))
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=timeout)
        directory = self.output / "logs"
        directory.mkdir(exist_ok=True)
        (directory / (label + ".stdout")).write_text(result.stdout)
        (directory / (label + ".stderr")).write_text(result.stderr)
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"argv": argv, "label": label, "returncode": result.returncode,
                                  "stdout_sha256": digest(result.stdout.encode()),
                                  "stderr_sha256": digest(result.stderr.encode())}, sort_keys=True) + "\n")
        self.command_count += 1
        if result.returncode:
            raise RuntimeError(f"{label} failed:\n" + (result.stdout + result.stderr)[-18000:])
        return result.stdout

    def prepare(self):
        if sys.platform != "linux":
            raise ValueError("This runner is Linux-only; use run.py for the native macOS experiment")
        originals = {
            "baseline": {path: subprocess.check_output(["git", "show", f"{self.args.baseline}:{path}"], cwd=ROOT)
                         for path in SOURCE_PATHS},
            "candidate": {path: (ROOT / path).read_bytes() for path in SOURCE_PATHS},
        }
        for path in SOURCE_PATHS:
            if path != DEMUXER and originals["baseline"][path] != originals["candidate"][path]:
                raise ValueError(f"Unrelated supporting production source changed: {path}")
        common = self.output / "CFFmpeg"
        common.mkdir()
        shim = shim_source(originals["candidate"][SHIM].decode()).encode()
        (common / "projection_shim.h").write_bytes(shim)
        (common / "module.modulemap").write_text('module CFFmpeg [system] { header "projection_shim.h" export * }\n')
        staged_hashes = {}
        for variant in ["baseline", "candidate"]:
            directory = self.output / variant
            directory.mkdir()
            staged, adaptations = projection_files(originals[variant], variant == "candidate")
            for path, contents in originals[variant].items():
                destination = directory / "original" / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(contents)
            for path, contents in staged.items():
                (directory / path).write_bytes(contents)
            receipt = {"variant": variant, "original": {p: digest(c) for p, c in originals[variant].items()},
                       "staged": {p: digest(c) for p, c in staged.items()}, "adaptations": adaptations}
            staged_hashes[variant] = receipt
            write_json(directory / "sources.json", receipt)
            flags = ["-O", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                     "-I", common, "-Xcc", "-I" + str(self.prefix / "include"),
                     "-L", self.prefix / "lib", "-lavformat", "-lavcodec", "-lavutil", "-lm",
                     "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib")]
            self.run([self.swift, *flags, "-emit-library", "-emit-module", "-enable-testing",
                      "-module-name", "AttachmentProjection", *[directory / p for p in staged],
                      "-emit-module-path", directory / "AttachmentProjection.swiftmodule",
                      "-o", directory / "libAttachmentProjection.so"], f"build-{variant}-projection")
            binary = directory / "harness"
            defines = ["-D", "OMIT_AUXILIARY_ATTACHMENTS"] if variant == "candidate" else []
            self.run([self.swift, *flags, *defines, "-I", directory, "-L", directory,
                      "-lAttachmentProjection", "-Xlinker", "-rpath", "-Xlinker", directory,
                      HERE / "HarnessLinux.swift", "-o", binary], f"build-{variant}-driver")
            self.binaries[variant] = binary
            staged_hashes[variant]["binary_sha256"] = digest(binary.read_bytes())
            staged_hashes[variant]["projection_library_sha256"] = digest((directory / "libAttachmentProjection.so").read_bytes())
            self.run(["ldd", binary], f"linked-libraries-{variant}")
        lib_hashes = {str(path.relative_to(self.prefix)): digest(path.read_bytes())
                      for path in sorted((self.prefix / "lib").glob("libav*.so.*")) if not path.is_symlink()}
        header_hashes = {str(path.relative_to(self.prefix)): digest(path.read_bytes())
                         for path in sorted((self.prefix / "include").rglob("*.h"))}
        self.manifest = {"scope": "actual FFmpeg open/probe plus exact extracted production media-info projection",
                         "excluded": "full macOS FFmpegDemuxer/FFmpegInputExecutor lifecycle, decoders, rendering, whole-player footprint",
                         "baseline": self.args.baseline,
                         "worktree_head": self.run(["git", "rev-parse", "HEAD"], "head").strip(),
                         "worktree_status": self.run(["git", "status", "--short"], "status"),
                         "platform": platform.platform(), "python": sys.version,
                         "swift": self.run([self.swift, "--version"], "swift-version").strip(),
                         "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                         "pairs": self.args.pairs, "auxiliary_counts": self.args.auxiliary_counts,
                         "cases": self.args.cases, "sources": staged_hashes,
                         "shim_sha256": digest(shim), "production_c_helpers": C_HELPERS,
                         "native_library_sha256": lib_hashes, "native_header_sha256": header_hashes,
                         "allocator_metric": "mallinfo2.uordblks + mallinfo2.hblkhd; live arena allocations plus malloc-owned mmap regions",
                         "rss_metric": "getrusage ru_maxrss converted from KiB to bytes before validation",
                         "comparison": "balanced AB/BA pairs; fresh subprocess per observation; no discarded observations"}
        for name in ["run-linux.py", "HarnessLinux.swift", "generate-fixtures.py"]:
            contents = (HERE / name).read_bytes()
            (self.output / name).write_bytes(contents)
            self.manifest.setdefault("driver_sha256", {})[name] = digest(contents)
        write_json(self.output / "manifest.json", self.manifest)

    def fixtures(self):
        if self.args.fixtures:
            directory = self.args.fixtures.resolve()
        else:
            directory = self.output / "fixtures"
            self.run([sys.executable, HERE / "generate-fixtures.py", "--output", directory,
                      "--ffmpeg", self.args.ffmpeg], "generate-fixtures")
        fixtures = json.loads((directory / "manifest.json").read_text())
        by_name = {item["name"]: item for item in fixtures}
        for name in self.args.cases:
            if name not in by_name:
                raise ValueError(f"Missing fixture: {name}")
            item = by_name[name]
            path = directory / item["filename"]
            if digest(path.read_bytes()) != item["sha256"]:
                raise ValueError(f"Fixture hash mismatch: {path}")
        write_json(self.output / "fixture-manifest.json", fixtures)
        return directory, by_name

    def benchmark(self):
        directory, fixtures = self.fixtures()
        observations = []
        pairs = []
        for case in self.args.cases:
            fixture = fixtures[case]
            for count in self.args.auxiliary_counts:
                oracle = None
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    cohort = {}
                    for position, variant in enumerate(order):
                        label = f"{case}-aux{count}-pair{pair}-{variant}"
                        value = json.loads(self.run([self.binaries[variant], directory / fixture["filename"], count,
                                                    fixture["accepted_payload_bytes"]], label))
                        if value["variant"] != variant or value["auxiliary_count"] != count:
                            raise ValueError("Driver identity mismatch")
                        expected_primary = fixture["accepted_payload_bytes"]
                        expected_auxiliary = 0 if variant == "candidate" else expected_primary * count
                        if (value["expected_font_bytes"] != expected_primary
                            or value["primary_retained_payload_bytes"] != expected_primary
                            or value["auxiliary_retained_payload_bytes"] != expected_auxiliary
                            or value["total_retained_payload_bytes"] != expected_primary + expected_auxiliary):
                            raise ValueError(f"Independent retained-byte invariant failed: {label}")
                        for metric in ["opening_wall_seconds", "opening_cpu_seconds"]:
                            if not math.isfinite(value[metric]) or value[metric] < 0:
                                raise ValueError(f"Invalid timing {metric}: {label}")
                        for metric in ["allocator_before_bytes", "allocator_while_open_bytes", "allocator_after_release_bytes",
                                       "process_max_rss_before_bytes", "process_max_rss_while_open_bytes",
                                       "process_max_rss_after_release_bytes"]:
                            if not isinstance(value[metric], int) or value[metric] < 0:
                                raise ValueError(f"Invalid memory measurement {metric}: {label}")
                        if value["allocator_open_delta_bytes"] != value["allocator_while_open_bytes"] - value["allocator_before_bytes"]:
                            raise ValueError(f"Allocator delta mismatch: {label}")
                        if value["allocator_release_delta_bytes"] != value["allocator_after_release_bytes"] - value["allocator_before_bytes"]:
                            raise ValueError(f"Allocator release delta mismatch: {label}")
                        validation = value.pop("validation")
                        if (validation["input_count"] != count + 1
                            or validation["auxiliary_policy_verified"] is not True
                            or validation["auxiliary_metadata_codec_packet_parity"] is not True):
                            raise ValueError(f"Incomplete parity validation: {label}")
                        if oracle is None:
                            oracle = validation
                            write_json(self.output / "validation" / f"{case}-aux{count}.json", oracle)
                        elif oracle != validation:
                            raise ValueError(f"Full validation differs: {label}")
                        expected_fonts = [{"filename": a["filename"], "mime_type": a["mime_type"],
                                           "bytes": a["size_bytes"], "sha256": a["sha256"], "supported_font": True}
                                          for a in fixture["attachments"] if a["supported_font"]]
                        if validation["primary_attachments"] != expected_fonts:
                            raise ValueError(f"Primary font bytes differ from generated payload: {label}")
                        value.update(case=case, pair=pair, order_position=position,
                                     validation_sha256=digest(json.dumps(validation, sort_keys=True).encode()))
                        observations.append(value)
                        cohort[variant] = value
                        with (self.output / "observations.jsonl").open("a") as output:
                            output.write(json.dumps(value, sort_keys=True) + "\n")
                    pairs.append({"case": case, "auxiliary_count": count, "pair": pair,
                                  "metrics": {metric: {"baseline": cohort["baseline"][metric],
                                                       "candidate": cohort["candidate"][metric],
                                                       "reduction": cohort["baseline"][metric] - cohort["candidate"][metric],
                                                       "reduction_percent": 100 * (cohort["baseline"][metric] - cohort["candidate"][metric]) / cohort["baseline"][metric]
                                                       if cohort["baseline"][metric] else None}
                                              for metric in METRICS}})
                print(f"Measured {case}, auxiliaries={count}: {self.args.pairs} pairs", flush=True)
        summary = []
        for case in self.args.cases:
            for count in self.args.auxiliary_counts:
                relevant = [row for row in pairs if row["case"] == case and row["auxiliary_count"] == count]
                metrics = {}
                for metric in METRICS:
                    values = [row["metrics"][metric] for row in relevant]
                    percents = [value["reduction_percent"] for value in values if value["reduction_percent"] is not None]
                    metrics[metric] = {"baseline_median": statistics.median(v["baseline"] for v in values),
                                       "candidate_median": statistics.median(v["candidate"] for v in values),
                                       "paired_reduction_median": statistics.median(v["reduction"] for v in values),
                                       "paired_reduction_percent_median": statistics.median(percents) if percents else None,
                                       "improved_pairs": sum(v["reduction"] > 0 for v in values),
                                       "worse_pairs": sum(v["reduction"] < 0 for v in values)}
                summary.append({"case": case, "auxiliary_count": count, "pairs": len(relevant), "metrics": metrics})
        write_json(self.output / "pairs.json", pairs)
        write_json(self.output / "summary.json", summary)
        write_json(self.output / "completion.json", {"observations": len(observations), "pairs": len(pairs),
                                                    "full_validation_groups": len(summary), "all_font_hashes_match": True,
                                                    "all_validation_equal": True, "commands": self.command_count})
        print(json.dumps({"output": str(self.output), "observations": len(observations), "pairs": len(pairs)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg-prefix", required=True, type=Path)
    parser.add_argument("--swift")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--auxiliary-counts", nargs="+", type=int, default=[0, 1, 2])
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("Use a positive even pair count for balanced AB/BA ordering")
    if any(count < 0 or count > 16 for count in args.auxiliary_counts):
        parser.error("Auxiliary counts must be between zero and sixteen")
    if len(set(args.cases)) != len(args.cases) or len(set(args.auxiliary_counts)) != len(args.auxiliary_counts):
        parser.error("Cases and auxiliary counts must be unique")
    runner = Runner(args)
    runner.prepare()
    runner.benchmark()


if __name__ == "__main__":
    main()
