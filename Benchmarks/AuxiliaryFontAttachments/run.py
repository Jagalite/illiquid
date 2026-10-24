#!/usr/bin/env python3
"""Measure live auxiliary-input font storage with actual native executors.

Each observation is a fresh process holding one primary input and 0/1/2
auxiliary inputs. No source behavior is reconstructed in a stand-in model.
Requires Apple Silicon macOS, Swift and the repository's pinned FFmpeg SDK.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
EXECUTOR = "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"
FULL_SOURCES = [
    DEMUXER, EXECUTOR,
    "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
]
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
BITMAP = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
C_SOURCES = ["Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
CALL_SITES = [
    "Sources/IlliquidNativePlayback/Media/MediaSession.swift",
    "Sources/IlliquidNativePlayback/Media/NativeFrameStepReader.swift",
    "Sources/IlliquidNativePlayback/Media/NativeThumbnailMetadataReader.swift",
    "Sources/IlliquidNativePlayback/Media/NativeTimelineThumbnailGenerator.swift",
    "Sources/IlliquidNativePlayback/Subtitles/PreparedExternalSubtitle.swift",
]
LIBRARIES = ["avformat", "avfilter", "avcodec", "avutil", "swresample", "swscale"]
VARIANTS = ("baseline", "candidate")
COUNTS = (0, 1, 2)
CASES = {"none", "fonts-128kib", "fonts-2mib", "fonts-16mib", "fonts-64mib", "mixed"}


def sha(value: bytes | str) -> str:
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("Source extraction markers changed")
    begin, finish = source.index(start), source.index(end)
    result = source[begin:finish]
    if begin >= finish or result.count("{") != result.count("}"):
        raise ValueError("Unbalanced extracted declarations")
    return result


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands, self.rows = [], []
        self.sources, self.exes, self.parity = {}, {}, {}
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        self.swiftc = Path(self.command(["xcrun", "--find", "swiftc"]).strip())
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        self.record = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "compiler_sha256": file_sha(self.swiftc),
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "host": self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"]),
            "protocol": {"pairs": args.pairs, "auxiliary_counts": COUNTS,
                         "fresh_process_per_observation": True,
                         "order": "alternating AB/BA", "warmup_opens": 0},
            "sources": self.sources, "compiled_sources": {}, "binaries": {},
            "native_libraries": {},
            "runner_sha256": file_sha(Path(__file__)),
            "harness_sha256": file_sha(HERE / "Harness.swift"),
            "generator_sha256": file_sha(HERE / "generate-fixtures.py"),
        }
        for name in ("run.py", "Harness.swift", "generate-fixtures.py"):
            shutil.copyfile(HERE / name, self.output / name)
        directory = args.fixtures.resolve(strict=True)
        self.fixtures = json.loads((directory / "manifest.json").read_text())
        if {case["name"] for case in self.fixtures} != CASES or len(self.fixtures) != len(CASES):
            raise ValueError("Require complete six-case fixture matrix")
        for case in self.fixtures:
            path = (directory / case["filename"]).resolve(strict=True)
            if not path.is_relative_to(directory) or file_sha(path) != case["sha256"]:
                raise ValueError("Fixture path or content hash mismatch")
            if path.stat().st_size != case["size_bytes"]:
                raise ValueError("Fixture size mismatch")
            case["path"] = str(path)
        write_json(self.output / "fixtures.json", self.fixtures)

    def command(self, argv, *, log=None, timeout=600):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - started,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)})
        write_json(self.output / "commands.json", self.commands)
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-2000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def source(self, variant, path):
        value = ((ROOT / path).read_text() if variant == "candidate" else
                 self.command(["git", "show", f"{BASELINE}:{path}"]))
        self.sources[f"{variant}:{path}"] = {"sha256": sha(value), "bytes": len(value.encode())}
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)
        return value

    def prepare(self):
        originals = {variant: {path: self.source(variant, path)
                               for path in FULL_SOURCES + [PRESENTATION, BITMAP] + C_SOURCES + CALL_SITES}
                     for variant in VARIANTS}
        for path in set(FULL_SOURCES + C_SOURCES) - {DEMUXER, EXECUTOR}:
            if originals["baseline"][path] != originals["candidate"][path]:
                raise ValueError(f"Unrelated component dependency changed: {path}")
        helpers = {}
        for variant in VARIANTS:
            error = extract(originals[variant][PRESENTATION], "struct PresentationError:", "\nfunc checkOSStatus(")
            packet = extract(originals[variant][BITMAP], "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
            helpers[variant] = "import Foundation\n\n" + error + "\n" + packet
        if helpers["baseline"] != helpers["candidate"]:
            raise ValueError("Shared extracted declarations changed")
        module = self.output / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for path in C_SOURCES:
            (module / Path(path).relative_to("Sources/CFFmpeg")).write_text(originals["candidate"][path])
        headers = {}
        for name in LIBRARIES:
            directory = self.prefix / "include" / f"lib{name}"
            for path in sorted(directory.rglob("*.h")):
                headers[str(path.relative_to(self.prefix / "include"))] = file_sha(path)
            library = (self.prefix / "lib" / f"lib{name}.dylib").resolve(strict=True)
            self.record["native_libraries"][name] = {"path": str(library), "sha256": file_sha(library)}
        write_json(self.output / "ffmpeg-headers.json", headers)
        self.record["ffmpeg_headers_manifest_sha256"] = file_sha(self.output / "ffmpeg-headers.json")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-sdk", self.sdk, "-I", str(module), "-Xcc", "-I" + str(self.prefix / "include"),
                 "-L", str(self.prefix / "lib"), "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib"),
                 "-module-cache-path", str(self.output / "module-cache"),
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.record["compiler_flags"] = flags
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            inputs = []
            for path in FULL_SOURCES:
                target = directory / Path(path).name
                target.write_text(originals[variant][path])
                inputs.append(target)
            target = directory / "ExtractedDeclarations.swift"
            target.write_text(helpers[variant])
            inputs.append(target)
            self.record["compiled_sources"][variant] = {
                str(path.relative_to(self.output)): file_sha(path) for path in inputs}
            library = directory / "libAuxiliaryFontInputs.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AuxiliaryFontInputs", "-emit-module-path", directory / "AuxiliaryFontInputs.swiftmodule",
                          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryFontInputs.dylib",
                          *inputs, "-o", library], log=f"{variant}-library-build.log")
            executable = directory / "auxiliary-font-benchmark"
            define = ["-D", "AUXILIARY_FONT_OMISSION"] if variant == "candidate" else []
            self.command([self.swiftc, *flags, *define, "-I", directory, "-L", directory, "-lAuxiliaryFontInputs",
                          "-Xlinker", "-rpath", "-Xlinker", directory,
                          self.output / "Harness.swift", "-o", executable], log=f"{variant}-driver-build.log")
            self.exes[variant] = executable
            self.record["binaries"][variant] = {"library_sha256": file_sha(library),
                "executable_sha256": file_sha(executable),
                "library_linkage": self.command(["otool", "-L", library]),
                "executable_linkage": self.command(["otool", "-L", executable])}
        write_json(self.output / "manifest.json", self.record)

    def sample(self, variant, case, count, pair, order_index):
        value = json.loads(self.command([self.exes[variant], case["path"], count]))
        if value["auxiliary_count"] != count or value["mode"] != "executor-group":
            raise ValueError("Harness command receipt mismatch")
        for key in ("open_wall_seconds", "open_cpu_seconds"):
            if not math.isfinite(value[key]) or value[key] <= 0:
                raise ValueError(f"Invalid {key}")
        for phase in ("before", "after"):
            for key in ("resident_bytes", "physical_footprint_bytes", "peak_rss_bytes"):
                if not isinstance(value[phase][key], int) or value[phase][key] <= 0:
                    raise ValueError(f"Invalid {phase} memory reading: {key}")
        font_bytes = case["accepted_payload_bytes"]
        expected_aux = 0 if variant == "candidate" else count * font_bytes
        if (value["primary_attachment_bytes"] != font_bytes
                or value["auxiliary_attachment_bytes"] != expected_aux
                or value["total_swift_attachment_bytes"] != font_bytes + expected_aux):
            raise ValueError("Live Swift font payload count disagrees with fixture/policy")
        metadata, playback = value.pop("metadata"), value.pop("playback_receipts")
        if len(metadata) != count + 1 or len(playback) != count + 1:
            raise ValueError("Incomplete input-group output receipts")
        primary = {"metadata": metadata[0], "playback": playback[0]}
        canonical_primary = self.parity.setdefault(case["name"], primary)
        if primary != canonical_primary:
            raise ValueError("Default primary output changed between variants/processes")
        for index, (info, packets) in enumerate(zip(metadata, playback)):
            expected = dict(canonical_primary["metadata"])
            if variant == "candidate" and index > 0:
                expected["attachments"] = []
            if info != expected or packets != canonical_primary["playback"]:
                raise ValueError(f"Auxiliary metadata/packet/seek/codec parity failure: {case['name']}/{index}")
        value["primary_receipt_sha256"] = sha(canonical(primary))
        value["group_receipt_sha256"] = sha(canonical({"metadata": metadata, "playback_receipts": playback}))
        value.update(variant=variant, case=case["name"], pair=pair, order_index=order_index)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(canonical(value) + "\n")
        self.rows.append(value)
        write_json(self.output / "parity.json", self.parity)

    def measure(self):
        for case in self.fixtures:
            for count in COUNTS:
                for pair in range(self.args.pairs):
                    order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                    for order_index, variant in enumerate(order):
                        self.sample(variant, case, count, pair, order_index)
                print(f"Completed {case['name']} / {count} auxiliary / {self.args.pairs} pairs", flush=True)
        return summarize(self.rows, self.fixtures, self.args.pairs)

    def verify_inputs(self):
        for key, receipt in self.sources.items():
            variant, path = key.split(":", 1)
            if variant == "candidate" and sha((ROOT / path).read_text()) != receipt["sha256"]:
                raise ValueError(f"Production source changed during measurement: {path}")
        for name, key in (("Harness.swift", "harness_sha256"), ("run.py", "runner_sha256"),
                          ("generate-fixtures.py", "generator_sha256")):
            if file_sha(HERE / name) != self.record[key]:
                raise ValueError("Measurement source changed during run")
        for case in self.fixtures:
            if file_sha(Path(case["path"])) != case["sha256"]:
                raise ValueError("Fixture changed during run")


def summarize(rows, fixtures, pairs):
    metrics = ["total_swift_attachment_bytes", "open_wall_seconds", "open_cpu_seconds",
               "after.resident_bytes", "after.physical_footprint_bytes", "after.peak_rss_bytes",
               "delta.resident_bytes", "delta.physical_footprint_bytes"]
    def value(row, metric):
        if metric.startswith("delta."):
            key = metric.split(".")[1]
            return row["after"][key] - row["before"][key]
        if "." in metric:
            phase, key = metric.split(".")
            return row[phase][key]
        return row[metric]
    results = []
    for case in fixtures:
        for count in COUNTS:
            selected = [r for r in rows if r["case"] == case["name"] and r["auxiliary_count"] == count]
            if len(selected) != pairs * 2:
                raise ValueError("Incomplete/duplicate measurement group")
            result = {"case": case["name"], "auxiliary_count": count, "pairs": pairs,
                      "accepted_payload_bytes": case["accepted_payload_bytes"]}
            for metric in metrics:
                changes, differences = [], []
                for pair in range(pairs):
                    observations = [r for r in selected if r["pair"] == pair]
                    by_variant = {r["variant"]: r for r in observations}
                    if len(observations) != 2 or set(by_variant) != set(VARIANTS):
                        raise ValueError("Incomplete/duplicate measurement pair")
                    order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                    if any(by_variant[v]["order_index"] != index for index, v in enumerate(order)):
                        raise ValueError("Observation order does not match protocol")
                    baseline, candidate = (value(by_variant[v], metric) for v in VARIANTS)
                    differences.append(candidate - baseline)
                    if baseline > 0:
                        changes.append(100 * (candidate / baseline - 1))
                result[metric] = {
                    v + "_median": statistics.median(value(r, metric) for r in selected if r["variant"] == v)
                    for v in VARIANTS}
                result[metric].update(
                    paired_differences=differences,
                    paired_median_difference=statistics.median(differences),
                    paired_percent_changes=changes,
                    paired_median_percent_change=statistics.median(changes) if changes else None,
                    candidate_lower_pairs=sum(x < 0 for x in differences))
            results.append(result)
    expected = len(fixtures) * len(COUNTS) * pairs * 2
    if len(rows) != expected:
        raise ValueError("Unexpected observations outside complete matrix")
    return {"status": "complete", "observations": expected, "results": results,
            "memory_scope": "live executor group before payload hashes/packet parity; whole process memory",
            "timing_scope": "one group open per fresh process; short samples are exploratory",
            "parity": "every non-font metadata field, primary font bytes, codec-private/parameter receipts, all packets and seek outputs"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    args = parser.parse_args()
    if platform.system() != "Darwin" or args.pairs < 2 or args.pairs % 2:
        parser.error("Native macOS and a positive even number of pairs >=2 are required")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        summary = runner.measure()
        runner.verify_inputs()
        runner.record["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.record)
        write_json(runner.output / "summary.json", summary)
        print("AUXILIARY_FONT_SUMMARY " + canonical(summary), flush=True)
    except Exception as error:
        if runner is not None:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "record"):
                write_json(runner.output / "manifest.json", runner.record)
        raise


if __name__ == "__main__":
    main()
