#!/usr/bin/env python3
"""Measure live native input memory before/after omitting unused font copies.

Requires macOS and the repository's native FFmpeg SDK. Compiles complete,
unmodified production sources at the pinned baseline and the working tree.
Every observation is a new process, with balanced AB/BA ordering.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import platform
from pathlib import Path
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
NATIVE = "Sources/IlliquidNativePlayback/"
DEMUXER = NATIVE + "Media/FFmpegDemuxer.swift"
EXECUTOR = NATIVE + "Media/FFmpegInputExecutor.swift"
SOURCES = [DEMUXER, EXECUTOR, *[NATIVE + name for name in (
    "Subtitles/FontAttachmentStore.swift", "Media/FFmpegStreamInfo.swift",
    "Media/MediaTime.swift", "Media/FFmpegError.swift", "Media/FFmpegPacket.swift",
    "Playback/PacketQueue.swift", "Playback/FixedRingBuffer.swift",
)]]
PRESENTATION = NATIVE + "Presentation/SampleBufferVideoPresenter.swift"
BITMAP = NATIVE + "Subtitles/BitmapSubtitleTimeline.swift"
C_SOURCES = ["Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
CALLERS = [NATIVE + path for path in (
    "Media/MediaSession.swift", "Media/NativeTimelineThumbnailGenerator.swift",
    "Media/NativeThumbnailMetadataReader.swift", "Media/NativeFrameStepReader.swift",
    "Subtitles/PreparedExternalSubtitle.swift",
)]
LIBRARIES = ("avformat", "avfilter", "avcodec", "avutil", "swresample", "swscale")
VARIANTS = ("baseline", "candidate")
FIXTURES = ("none", "fonts-2mib", "fonts-16mib", "fonts-64mib", "unsupported-only", "mixed")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Extraction boundary changed: {start} / {end}")
    begin, finish = source.index(start), source.index(end)
    if begin >= finish:
        raise ValueError("Extraction boundaries are out of order")
    return source[begin:finish]


def scenarios() -> list[tuple[str, str, str]]:
    return (
        [(name, "direct", "auxiliary-only") for name in FIXTURES]
        + [(name, "executor", "primary-plus-one") for name in FIXTURES]
        + [(name, "executor", "primary-plus-two") for name in FIXTURES[:4]]
        + [(name, "direct", "primary-only") for name in FIXTURES[:3]]
    )


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.sources = {}
        self.exes = {}
        self.rows = []
        self.parity = {}
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        self.swiftc = Path(args.swiftc or self.command(["xcrun", "--find", "swiftc"]).strip()).absolute()
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        self.fixtures = self.load_fixtures(args.fixtures.resolve(strict=True))
        self.manifest = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_commit": BASELINE,
            "candidate_commit": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_status": self.command(["git", "status", "--porcelain"]),
            "platform": platform.platform(),
            "host": self.command(["sw_vers"]),
            "hardware": self.command(["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"]),
            "compiler": self.command([self.swiftc, "--version"]),
            "compiler_sha256": file_digest(self.swiftc),
            "sdk": self.sdk,
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "pairs": args.pairs,
            "scenarios": scenarios(),
            "sources": self.sources,
            "runner_sha256": file_digest(Path(__file__)),
            "harness_sha256": file_digest(HERE / "Harness.swift"),
            "generator_sha256": file_digest(HERE / "generate-fixtures.py"),
        }
        for name in ("run.py", "Harness.swift", "generate-fixtures.py"):
            shutil.copyfile(HERE / name, self.output / name)

    def command(self, command, *, log=None, timeout=300) -> str:
        argv = list(map(str, command))
        result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "stdout_sha256": digest(result.stdout.encode()),
                              "stderr_sha256": digest(result.stderr.encode())})
        write_json(self.output / "commands.json", self.commands)
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-4000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def load_fixtures(self, directory):
        manifest = json.loads((directory / "manifest.json").read_text())
        by_name = {case["name"]: case for case in manifest}
        if len(by_name) != len(manifest) or set(by_name) != set(FIXTURES):
            raise ValueError("Expected the complete six-case fixture set without duplicates")
        for case in manifest:
            path = (directory / case["filename"]).resolve(strict=True)
            if not path.is_relative_to(directory) or not path.is_file():
                raise ValueError("Fixture path escapes its directory")
            if file_digest(path) != case["sha256"] or path.stat().st_size != case["size_bytes"]:
                raise ValueError("Fixture content differs from generator manifest")
            for key in ("accepted_payload_bytes", "font_count"):
                if not isinstance(case[key], int) or case[key] < 0:
                    raise ValueError(f"Invalid fixture field {key}")
            case["path"] = str(path)
        write_json(self.output / "fixtures.json", manifest)
        return by_name

    def source(self, variant, path):
        data = ((ROOT / path).read_bytes() if variant == "candidate" else
                self.command(["git", "show", f"{BASELINE}:{path}"]).encode())
        target = self.output / "sources" / variant / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.sources[f"{variant}:{path}"] = digest(data)
        return data.decode()

    def prepare(self):
        originals = {variant: {path: self.source(variant, path)
                               for path in SOURCES + C_SOURCES + [PRESENTATION, BITMAP]}
                     for variant in VARIANTS}
        for path in set(SOURCES + C_SOURCES) - {DEMUXER, EXECUTOR}:
            if originals["baseline"][path] != originals["candidate"][path]:
                raise ValueError(f"Unrelated compiled dependency changed: {path}")
        for path in CALLERS:
            self.source("candidate", path)
        module = self.output / "CFFmpeg"
        for path in C_SOURCES:
            target = module / Path(path).relative_to("Sources/CFFmpeg")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(originals["candidate"][path])
        headers = {}
        libraries = {}
        for library in LIBRARIES:
            for path in sorted((self.prefix / "include" / f"lib{library}").rglob("*.h")):
                headers[str(path.relative_to(self.prefix / "include"))] = file_digest(path)
            binary = (self.prefix / "lib" / f"lib{library}.dylib").resolve(strict=True)
            libraries[library] = {"path": str(binary), "sha256": file_digest(binary)}
        if not headers:
            raise ValueError("No FFmpeg headers found")
        write_json(self.output / "ffmpeg-headers.json", headers)
        self.manifest["ffmpeg_libraries"] = libraries
        self.manifest["ffmpeg_headers_sha256"] = file_digest(self.output / "ffmpeg-headers.json")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-warnings-as-errors", "-sdk", self.sdk,
                 "-I", module, "-Xcc", "-I" + str(self.prefix / "include"),
                 "-L", self.prefix / "lib", "-Xlinker", "-rpath", "-Xlinker", self.prefix / "lib",
                 "-module-cache-path", self.output / "module-cache",
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.manifest["compiler_flags"] = list(map(str, flags))
        self.manifest["binaries"] = {}
        self.manifest["extracted_declarations"] = {}
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            inputs = []
            for path in SOURCES:
                target = directory / Path(path).name
                target.write_text(originals[variant][path])
                inputs.append(target)
            support = "import Foundation\n\n" + extract(originals[variant][PRESENTATION],
                "struct PresentationError:", "\nfunc checkOSStatus(") + "\n" + extract(
                originals[variant][BITMAP], "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
            helpers = directory / "ExtractedDeclarations.swift"
            helpers.write_text(support)
            inputs.append(helpers)
            self.manifest["extracted_declarations"][variant] = digest(support.encode())
            library = directory / "libAuxiliaryAttachmentInputs.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AuxiliaryAttachmentInputs", "-emit-module-path",
                          directory / "AuxiliaryAttachmentInputs.swiftmodule",
                          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryAttachmentInputs.dylib",
                          *inputs, "-o", library], log=f"{variant}-library-build.log")
            executable = directory / "auxiliary-attachments"
            condition = ["-D", "BASELINE"] if variant == "baseline" else []
            self.command([self.swiftc, *flags, *condition, "-I", directory, "-L", directory,
                          "-lAuxiliaryAttachmentInputs", "-Xlinker", "-rpath", "-Xlinker", directory,
                          self.output / "Harness.swift", "-o", executable], log=f"{variant}-driver-build.log")
            self.exes[variant] = executable
            self.manifest["binaries"][variant] = {"library_sha256": file_digest(library),
                "executable_sha256": file_digest(executable),
                "library_linkage": self.command(["otool", "-L", library])}
        if len(set(self.manifest["extracted_declarations"].values())) != 1:
            raise ValueError("Extracted shared declaration bodies changed")
        write_json(self.output / "manifest.json", self.manifest)

    def measure(self):
        for pair in range(self.args.pairs):
            order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
            cases = scenarios() if pair % 2 == 0 else scenarios()[::-1]
            for name, backend, layout in cases:
                case = self.fixtures[name]
                for position, variant in enumerate(order):
                    row = json.loads(self.command([self.exes[variant], case["path"], backend, layout,
                                                   case["accepted_payload_bytes"]]))
                    if row["variant"] != variant:
                        raise ValueError("Driver reported the wrong compiled variant")
                    row.update(case=name, pair=pair, variant=variant, pair_position=position,
                               sequence=len(self.rows))
                    self.validate(row, case, backend, layout)
                    self.rows.append(row)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
                print(f"pair {pair + 1}/{self.args.pairs}: {name} {backend} {layout}", flush=True)
        return summarize(self.rows, self.args.pairs)

    def validate(self, row, case, backend, layout):
        # The driver enforces the exact copied-byte inventory and serializes
        # metadata/packet receipts after the retained-memory sample.
        if row["backend"] != backend or row["layout"] != layout:
            raise ValueError("Driver receipt does not match invocation")
        expected_count = {"primary-only": 1, "auxiliary-only": 1,
                          "primary-plus-one": 2, "primary-plus-two": 3}[layout]
        if len(row["readers"]) != expected_count or row["reader_count"] != expected_count:
            raise ValueError("Wrong number of retained readers")
        if row["expected_font_bytes"] != case["accepted_payload_bytes"] or not row["readers_released"]:
            raise ValueError("Wrong fixture inventory or surviving input owner")
        for index, reader in enumerate(row["readers"]):
            keeps_fonts = row["variant"] == "baseline" or (layout != "auxiliary-only" and index == 0)
            expected_bytes = case["accepted_payload_bytes"] if keeps_fonts else 0
            if reader["copied_font_bytes"] != expected_bytes:
                raise ValueError("Unexpected retained font byte count")
            expected_fonts = case["font_count"] if keeps_fonts else 0
            if len(reader["attachments"]) != expected_fonts:
                raise ValueError("Unexpected retained font count")
            common = {key: reader[key] for key in ("metadata", "packet_trace", "codec_private")}
            key = case["name"]
            if self.parity.setdefault(key, common) != common:
                raise ValueError(f"Metadata, codec configuration or packet output changed: {key}")
            if keeps_fonts:
                key += ":fonts"
                if self.parity.setdefault(key, reader["attachments"]) != reader["attachments"]:
                    raise ValueError("Default font ownership/content changed")
        for phase in ("before", "retained", "after_release"):
            if set(row["memory"][phase]) != {"resident_bytes", "phys_footprint_bytes", "heap_in_use_bytes", "max_rss_bytes"}:
                raise ValueError("Missing or unexpected native memory metric")
            for value in row["memory"][phase].values():
                if not isinstance(value, int) or value < 0:
                    raise ValueError("Invalid native memory measurement")
        for key in ("open_wall_seconds", "open_cpu_seconds"):
            if not math.isfinite(row[key]) or row[key] < 0:
                raise ValueError("Invalid open time")

    def verify_inputs(self):
        for key, expected in self.sources.items():
            variant, path = key.split(":", 1)
            if variant == "candidate" and file_digest(ROOT / path) != expected:
                raise ValueError(f"Source changed during measurement: {path}")
        for name, key in (("run.py", "runner_sha256"), ("Harness.swift", "harness_sha256"),
                          ("generate-fixtures.py", "generator_sha256")):
            if file_digest(HERE / name) != self.manifest[key]:
                raise ValueError(f"Benchmark input changed: {name}")
        for case in self.fixtures.values():
            if file_digest(Path(case["path"])) != case["sha256"]:
                raise ValueError("Fixture changed during measurement")


def summarize(rows, pairs):
    expected = []
    for pair in range(pairs):
        order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
        cases = scenarios() if pair % 2 == 0 else scenarios()[::-1]
        expected.extend((pair, *case, variant, position) for case in cases
                        for position, variant in enumerate(order))
    actual = [(r["pair"], r["case"], r["backend"], r["layout"], r["variant"], r["pair_position"])
              for r in rows]
    if actual != expected or [r["sequence"] for r in rows] != list(range(len(rows))):
        raise ValueError("Incomplete, duplicated or incorrectly ordered measurement cohort")
    output = []
    for name, backend, layout in scenarios():
        selected = [r for r in rows if (r["case"], r["backend"], r["layout"]) == (name, backend, layout)]
        metrics = {
            **{key: lambda r, key=key: r["memory"]["retained"][key]
               for key in ("resident_bytes", "phys_footprint_bytes", "heap_in_use_bytes")},
            "copied_font_bytes": lambda r: sum(x["copied_font_bytes"] for x in r["readers"]),
            "open_wall_seconds": lambda r: r["open_wall_seconds"],
            "open_cpu_seconds": lambda r: r["open_cpu_seconds"],
        }
        summary = {"case": name, "backend": backend, "layout": layout, "pairs": pairs}
        for key, get in metrics.items():
            values = {v: [get(r) for r in selected if r["variant"] == v] for v in VARIANTS}
            differences = []
            percents = []
            for pair in range(pairs):
                members = {r["variant"]: get(r) for r in selected if r["pair"] == pair}
                differences.append(members["baseline"] - members["candidate"])
                if members["baseline"] > 0:
                    percents.append(100 * (1 - members["candidate"] / members["baseline"]))
            summary[key] = {v: {"median": statistics.median(samples), "min": min(samples), "max": max(samples)}
                            for v, samples in values.items()}
            summary[key].update(median_paired_reduction=statistics.median(differences),
                                min_paired_reduction=min(differences), max_paired_reduction=max(differences),
                                median_paired_reduction_percent=statistics.median(percents) if percents else None)
        output.append(summary)
    return {"observations": len(rows), "scenarios": output}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=6)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Requires native macOS frameworks; do not substitute Linux measurements")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("Use an even number of pairs from 2 through 20")
    runner = Runner(args)
    try:
        runner.prepare()
        summary = runner.measure()
        runner.verify_inputs()
        runner.manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.manifest)
        write_json(runner.output / "parity.json", runner.parity)
        write_json(runner.output / "summary.json", summary)
        print("AUXILIARY_FONT_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    except Exception as error:
        write_json(runner.output / "failure.json", {"error": str(error)})
        raise


if __name__ == "__main__":
    main()
