#!/usr/bin/env python3
"""Compare native attachment admission using complete production demuxers.

Requires macOS, Swift 6.1+, and an installed FFmpeg prefix. No dependencies or
fixtures are downloaded. Every timed observation is a new process; no samples
are removed. The output directory retains source, commands, receipts, and data.
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
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
FONT = "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift"
FULL_SOURCES = [
    DEMUXER, FONT,
    "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
]
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
BITMAP = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
C_SOURCES = ["Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
LIBRARIES = ["avformat", "avfilter", "avcodec", "avutil", "swresample", "swscale"]
VARIANTS = ("baseline", "candidate")
MODES = ("projection", "setup")


def sha(value: bytes | str) -> str:
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Extraction markers changed: {start!r} / {end!r}")
    begin, finish = source.index(start), source.index(end)
    if begin >= finish:
        raise ValueError("Extraction markers are out of order")
    result = source[begin:finish]
    if result.count("{") != result.count("}"):
        raise ValueError("Extracted declarations have unbalanced braces")
    return result


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.sources = {}
        self.parity = {}
        self.calibrations = []
        self.measurements = []
        self.exes = {}
        self.env = os.environ.copy()
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        # Keep the swiftc executable name: resolving its swift-driver symlink
        # changes argv[0], which the Swift driver uses to select compiler mode.
        compiler = args.swiftc or self.command(["xcrun", "--find", "swiftc"]).strip()
        self.swiftc = Path(compiler).absolute()
        if not self.swiftc.is_file():
            raise ValueError(f"Missing Swift compiler: {self.swiftc}")
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        if not Path(self.sdk).is_dir():
            raise ValueError(f"Missing macOS SDK: {self.sdk}")
        self.fixtures = self.load_fixtures(args.fixtures.resolve(strict=True))
        self.record = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "compiler_path": str(self.swiftc), "compiler_sha256": file_sha(self.swiftc),
            "sdk_path": self.sdk,
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "ffmpeg_prefix": str(self.prefix),
            "protocol": vars(args) | {"baseline": BASELINE},
            "sources": self.sources, "binaries": {}, "native_libraries": {},
            "runner_sha256": file_sha(Path(__file__)),
            "harness_sha256": file_sha(HERE / "Harness.swift"),
        }
        self.record["protocol"] = {k: str(v) if isinstance(v, Path) else v
                                   for k, v in self.record["protocol"].items()}
        self.record["system"] = self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"])
        (self.output / "runner.snapshot.py").write_bytes(Path(__file__).read_bytes())
        (self.output / "Harness.swift").write_bytes((HERE / "Harness.swift").read_bytes())

    def command(self, argv, *, log: str | None = None, timeout: int = 600) -> str:
        argv = [str(x) for x in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - started,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)})
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        write_json(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-3000:]}\n{result.stderr[-10000:]}")
        return result.stdout

    def load_fixtures(self, directory: Path):
        manifest = directory / "manifest.json"
        data = json.loads(manifest.read_text())
        if not isinstance(data, list) or not data:
            raise ValueError("Fixture manifest must be a nonempty array")
        names = set()
        for case in data:
            if case["name"] in names:
                raise ValueError("Duplicate fixture name")
            names.add(case["name"])
            path = (directory / case["filename"]).resolve(strict=True)
            if not path.is_relative_to(directory) or not path.is_file():
                raise ValueError("Fixture must be a file inside its manifest directory")
            for key in ("rejected_payload_bytes", "accepted_payload_bytes"):
                if not isinstance(case[key], int) or case[key] < 0:
                    raise ValueError(f"Invalid fixture {key}")
            digest = file_sha(path)
            if "sha256" in case and case["sha256"] != digest:
                raise ValueError(f"Fixture content hash mismatch: {case['name']}")
            if "size_bytes" in case and case["size_bytes"] != path.stat().st_size:
                raise ValueError(f"Fixture size mismatch: {case['name']}")
            case.update(path=str(path), sha256=digest, size_bytes=path.stat().st_size)
        required = {"none", "fonts-2mib", "unsupported-1mib", "unsupported-16mib",
                    "unsupported-64mib", "mixed-16mib", "cover-png"}
        if names != required:
            raise ValueError(f"Expected the complete seven-case fixture set; got {sorted(names)}")
        write_json(self.output / "fixtures.json", data)
        shutil.copyfile(manifest, self.output / "fixture-manifest.snapshot.json")
        return data

    def source(self, variant: str, path: str) -> str:
        text = ((ROOT / path).read_text() if variant == "candidate" else
                self.command(["git", "show", f"{BASELINE}:{path}"]))
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)
        self.sources[f"{variant}:{path}"] = {"sha256": sha(text), "bytes": len(text.encode())}
        return text

    def prepare(self):
        original = {variant: {path: self.source(variant, path)
                              for path in FULL_SOURCES + [PRESENTATION, BITMAP] + C_SOURCES}
                    for variant in VARIANTS}
        for path in set(FULL_SOURCES + C_SOURCES) - {DEMUXER, FONT}:
            if original["baseline"][path] != original["candidate"][path]:
                raise ValueError(f"Unrelated production dependency changed: {path}")
        error = {v: extract(original[v][PRESENTATION], "struct PresentationError:", "\nfunc checkOSStatus(")
                 for v in VARIANTS}
        packets = {v: extract(original[v][BITMAP], "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
                   for v in VARIANTS}
        if error["baseline"] != error["candidate"] or packets["baseline"] != packets["candidate"]:
            raise ValueError("Shared extracted error/packet declarations differ")
        module = self.output / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for path in C_SOURCES:
            (module / Path(path).relative_to("Sources/CFFmpeg")).write_text(original["candidate"][path])

        header_manifest = {}
        for directory in LIBRARIES:
            include = self.prefix / "include" / f"lib{directory}"
            if not include.is_dir():
                raise ValueError(f"Missing FFmpeg headers: {include}")
            for path in sorted(include.rglob("*.h")):
                header_manifest[str(path.relative_to(self.prefix / "include"))] = file_sha(path)
            library = self.prefix / "lib" / f"lib{directory}.dylib"
            resolved = library.resolve(strict=True)
            self.record["native_libraries"][directory] = {"path": str(resolved), "sha256": file_sha(resolved)}
        write_json(self.output / "ffmpeg-headers.json", header_manifest)
        self.record["ffmpeg_headers_manifest_sha256"] = file_sha(self.output / "ffmpeg-headers.json")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-sdk", self.sdk,
                 "-I", str(module), "-Xcc", "-I" + str(self.prefix / "include"),
                 "-L", str(self.prefix / "lib"), "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib"),
                 "-module-cache-path", str(self.output / "module-cache"),
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.record["compiler_flags"] = flags
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            inputs = []
            for path in FULL_SOURCES:
                source = original[variant][path]
                if path == DEMUXER:
                    marker = "    private static func makeMediaInfo("
                    replacement = "    static func makeMediaInfo("
                    if source.count(marker) != 1:
                        raise ValueError("Production projection access marker changed")
                    source = source.replace(marker, replacement, 1)
                    if source.replace(replacement, marker, 1) != original[variant][path]:
                        raise ValueError("Unexpected demuxer transformation")
                target = directory / Path(path).name
                target.write_text(source)
                inputs.append(target)
            helpers = directory / "ExtractedDeclarations.swift"
            helpers.write_text("import Foundation\n\n" + error[variant] + "\n" + packets[variant])
            inputs.append(helpers)
            self.record.setdefault("compiled_sources", {})[variant] = {
                str(p.relative_to(self.output)): file_sha(p) for p in inputs}
            library = directory / "libAttachmentProjection.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AttachmentProjection", "-emit-module-path", directory / "AttachmentProjection.swiftmodule",
                          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAttachmentProjection.dylib",
                          *inputs, "-o", library], log=f"{variant}-library-build.log")
            executable = directory / "attachment-benchmark"
            self.command([self.swiftc, *flags, "-I", directory, "-L", directory, "-lAttachmentProjection",
                          "-Xlinker", "-rpath", "-Xlinker", directory,
                          self.output / "Harness.swift", "-o", executable], log=f"{variant}-driver-build.log")
            self.exes[variant] = executable
            self.record["binaries"][variant] = {"library_sha256": file_sha(library), "executable_sha256": file_sha(executable),
                "library_linkage": self.command(["otool", "-L", library]),
                "executable_linkage": self.command(["otool", "-L", executable])}
        write_json(self.output / "manifest.json", self.record)

    def sample(self, variant: str, case, mode: str, iterations: int, stage: str, **metadata):
        raw = self.command([self.exes[variant], case["path"], mode, iterations,
                            case["accepted_payload_bytes"], case["rejected_payload_bytes"]])
        value = json.loads(raw)
        if value["mode"] != mode or value["iterations"] != iterations:
            raise ValueError("Harness command receipt mismatch")
        for key in ("wall_seconds", "cpu_seconds"):
            if not isinstance(value[key], (int, float)) or not math.isfinite(value[key]) or value[key] < 0:
                raise ValueError(f"Invalid {key}")
        if value["wall_seconds"] <= 0:
            raise ValueError("Nonpositive wall duration")
        for key in ("accepted_payload_bytes", "rejected_payload_bytes"):
            if value[key] != case[key]:
                raise ValueError("Harness inventory disagrees with fixture manifest")
        receipt = {key: value[key] for key in (
            "snapshot", "input_attachments", "accepted_payload_bytes", "rejected_payload_bytes",
            "accepted_attachment_count", "checksum_per_iteration", "ffmpeg_version", "avformat_version", "avcodec_version", "avutil_version")}
        previous = self.parity.setdefault(case["name"], receipt)
        if receipt != previous:
            raise ValueError(f"Full production output differs: {case['name']} {mode} {variant}")
        if int(value["checksum"]) != (int(value["checksum_per_iteration"]) * iterations) % (1 << 64):
            raise ValueError("Consumed output checksum mismatch")
        if case["name"] == "cover-png":
            if value["accepted_attachment_count"] != 0 or not any(
                    s["kind"] == "video" and s["codec_name"] == "png" and s["disposition"] & 0x400
                    for s in value["snapshot"]["streams"]):
                raise ValueError("Cover control must retain an attached PNG video stream and no font payloads")
        if case["name"] == "none" and value["input_attachments"]:
            raise ValueError("No-attachment control unexpectedly contains an attachment")
        if case["name"] in ("fonts-2mib", "mixed-16mib") and value["accepted_attachment_count"] == 0:
            raise ValueError("Font/mixed control did not retain a supported font")
        value.update(variant=variant, case=case["name"], stage=stage, **metadata)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
        return value

    def calibrate(self, case, mode):
        count = 1
        trials = []
        for attempt in range(5):
            pair = [self.sample(v, case, mode, count, "calibration", attempt=attempt) for v in VARIANTS]
            trials.extend(pair)
            fastest = min(x["wall_seconds"] for x in pair)
            slowest = max(x["wall_seconds"] for x in pair)
            target = math.ceil(count * self.args.target_ms / 1000 / max(fastest, 1e-9))
            cap = max(1, math.floor(count * self.args.max_sample_ms / 1000 / max(slowest, 1e-9)))
            selected = max(1, min(target, cap, self.args.max_iterations))
            if fastest >= self.args.target_ms / 1000 or selected <= count or attempt == 4:
                break
            count = selected
        record = {"case": case["name"], "mode": mode, "iterations": count,
                  "target_ms": self.args.target_ms, "max_sample_ms": self.args.max_sample_ms,
                  "last_wall_ms": {x["variant"]: 1000 * x["wall_seconds"] for x in pair},
                  "target_reached": fastest >= self.args.target_ms / 1000,
                  "trials": len(trials)}
        self.calibrations.append(record)
        write_json(self.output / "calibration.json", self.calibrations)
        return count

    def measure(self):
        for case_index, case in enumerate(self.fixtures):
            for mode in MODES:
                iterations = self.calibrate(case, mode)
                for pair in range(self.args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    for order_index, variant in enumerate(order):
                        self.measurements.append(self.sample(variant, case, mode, iterations, "measurement",
                                                             pair=pair, order_index=order_index))
                print(json.dumps({"progress": "completed", "case": case["name"], "mode": mode,
                                  "pairs": self.args.pairs}), flush=True)
        expected = len(self.fixtures) * len(MODES) * self.args.pairs * 2
        if len(self.measurements) != expected:
            raise ValueError("Incomplete measurement matrix")
        write_json(self.output / "parity.json", self.parity)
        summaries = []
        for case in self.fixtures:
            for mode in MODES:
                rows = [r for r in self.measurements if r["case"] == case["name"] and r["mode"] == mode]
                result = {"case": case["name"], "mode": mode, "pairs": self.args.pairs,
                          "accepted_payload_bytes": case["accepted_payload_bytes"],
                          "rejected_payload_bytes": case["rejected_payload_bytes"],
                          "sample_wall_seconds": {
                              variant: {"minimum": min(r["wall_seconds"] for r in rows if r["variant"] == variant),
                                        "maximum": max(r["wall_seconds"] for r in rows if r["variant"] == variant),
                                        "observations_below_5ms": sum(r["wall_seconds"] < 0.005 for r in rows if r["variant"] == variant)}
                              for variant in VARIANTS}}
                for metric in ("wall_seconds", "cpu_seconds", "process_max_rss_bytes"):
                    paired = []
                    for pair in range(self.args.pairs):
                        values = {r["variant"]: r[metric] for r in rows if r["pair"] == pair}
                        if set(values) != set(VARIANTS):
                            raise ValueError("Missing or duplicate pair observation")
                        baseline, candidate = values["baseline"], values["candidate"]
                        paired.append(100 * (candidate / baseline - 1) if baseline > 0 else None)
                    result[metric] = {
                        "baseline_median": statistics.median(r[metric] / (r["iterations"] if metric.endswith("seconds") else 1)
                                                             for r in rows if r["variant"] == "baseline"),
                        "candidate_median": statistics.median(r[metric] / (r["iterations"] if metric.endswith("seconds") else 1)
                                                              for r in rows if r["variant"] == "candidate"),
                        "paired_percent_changes": paired,
                        "paired_median_percent_change": statistics.median(x for x in paired if x is not None)
                            if any(x is not None for x in paired) else None,
                        "candidate_lower_pairs": sum(x is not None and x < 0 for x in paired),
                    }
                summaries.append(result)
        return {"status": "complete", "timed_observations": expected, "cases": len(self.fixtures),
                "modes": list(MODES), "pairs": self.args.pairs,
                "parity": "exact across both variants, both modes, all calibration and measured observations",
                "timing_unit": "seconds per operation", "rss_unit": "process-lifetime peak bytes; not incremental allocation",
                "results": summaries}

    def verify_inputs(self):
        for key, receipt in self.sources.items():
            variant, path = key.split(":", 1)
            if variant == "candidate" and sha((ROOT / path).read_text()) != receipt["sha256"]:
                raise ValueError(f"Production source changed during benchmark: {path}")
        if file_sha(HERE / "Harness.swift") != self.record["harness_sha256"] or file_sha(Path(__file__)) != self.record["runner_sha256"]:
            raise ValueError("Harness or runner changed during benchmark")
        for case in self.fixtures:
            if file_sha(Path(case["path"])) != case["sha256"]:
                raise ValueError(f"Fixture changed during benchmark: {case['name']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=10)
    parser.add_argument("--max-sample-ms", type=float, default=5000)
    parser.add_argument("--max-iterations", type=int, default=100000)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This benchmark requires native macOS frameworks and FFmpeg")
    if args.pairs <= 0 or args.pairs % 2 or args.target_ms < 5 or args.max_sample_ms < args.target_ms or args.max_iterations < 1:
        parser.error("Use positive even pairs, target >= 5 ms, max-sample >= target, and positive iterations")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        summary = runner.measure()
        runner.verify_inputs()
        runner.record["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.record)
        write_json(runner.output / "summary.json", summary)
        print("ATTACHMENT_ADMISSION_SUMMARY " + json.dumps(summary, sort_keys=True, allow_nan=False), flush=True)
    except Exception as error:
        if runner is not None:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "record"):
                write_json(runner.output / "manifest.json", runner.record)
        raise


if __name__ == "__main__":
    main()
