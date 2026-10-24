#!/usr/bin/env python3
"""Compare retained native-input memory with exact baseline/candidate sources.

Native execution requires macOS and the repository's installed FFmpeg SDK.
--validate-inputs checks source provenance on any platform without compiling.
No dependencies or fixtures are downloaded; no production source is rewritten.
"""
from __future__ import annotations

import argparse
import ast
from datetime import datetime, timezone
import hashlib
import json
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
SOURCE_PATHS = FULL_SOURCES + [PRESENTATION, BITMAP] + C_SOURCES
LIBRARIES = ["avformat", "avfilter", "avcodec", "avutil", "swresample", "swscale"]
VARIANTS = ("baseline", "candidate")
CASE_NAMES = {"none", "font-128kib", "font-2mib", "fonts-16mib", "unsupported-8mib", "mixed"}
PROFILES = [("auxiliary", owner, count) for owner in ("demuxer", "executor") for count in (1, 3)] + [
    ("primary", owner, 1) for owner in ("demuxer", "executor")]


def sha(value: bytes | str) -> str:
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def file_sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Extraction markers changed: {start!r} / {end!r}")
    begin, finish = source.index(start), source.index(end)
    result = source[begin:finish]
    if begin >= finish or result.count("{") != result.count("}"):
        raise ValueError("Invalid declaration extraction")
    return result


def source_inputs():
    receipt = json.loads((HERE / "baseline.json").read_text())
    if receipt["commit"] != BASELINE or set(receipt["sources"]) != set(SOURCE_PATHS):
        raise ValueError("Baseline receipt does not describe the fixed source set")
    baseline = {path: subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                for path in SOURCE_PATHS}
    candidate = {path: (ROOT / path).read_bytes() for path in SOURCE_PATHS}
    for path, content in baseline.items():
        if sha(content) != receipt["sources"][path]:
            raise ValueError(f"Pinned baseline source hash mismatch: {path}")
        if path not in (DEMUXER, EXECUTOR) and candidate[path] != content:
            raise ValueError(f"Unrelated benchmark dependency changed: {path}")
    original = {"baseline": baseline, "candidate": candidate}
    helpers = {}
    for variant in VARIANTS:
        error = extract(original[variant][PRESENTATION].decode(),
                        "struct PresentationError:", "\nfunc checkOSStatus(")
        packets = extract(original[variant][BITMAP].decode(),
                          "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
        helpers[variant] = ("import Foundation\n\n" + error + "\n" + packets).encode()
    if helpers["baseline"] != helpers["candidate"]:
        raise ValueError("Extracted production support declarations differ")
    for name in ("run.py", "generate-fixtures.py"):
        ast.parse((HERE / name).read_text(), filename=name)
    for name in ("Harness.swift", "CMemoryProbe/module.modulemap", "CMemoryProbe/memory.h"):
        if not (HERE / name).is_file():
            raise ValueError(f"Missing harness input: {name}")
    return original, helpers


def check_observation(value, case, variant, owner, role, count, canonical):
    expected_fonts = variant == "baseline" or role == "primary"
    for key, expected in {"schema": 1, "owner": owner, "role": role, "input_count": count,
                          "include_font_attachments": expected_fonts, "verified_inputs": count,
                          "allocator_metric": "malloc_zone_statistics(NULL).size_in_use"}.items():
        if value[key] != expected:
            raise ValueError(f"Observation command/metric mismatch: {key}")
    for key in ("allocator_before_bytes", "allocator_retained_bytes"):
        if type(value[key]) is not int or value[key] < 0:
            raise ValueError(f"Invalid allocator sample: {key}")
    if value["allocator_retained_delta_bytes"] != value["allocator_retained_bytes"] - value["allocator_before_bytes"]:
        raise ValueError("Allocator delta was not computed from recorded samples")
    attachments = [item for item in case["attachments"] if item["supported_font"]] if expected_fonts else []
    if value["retained_font_payload_bytes"] != sum(item["bytes"] for item in attachments) * count:
        raise ValueError("Retained font payload count disagrees with fixture manifest")
    if value["retained_font_attachment_count"] != len(attachments) * count:
        raise ValueError("Retained attachment count disagrees with fixture manifest")
    observed = value["input_receipt"]
    if observed["metadata"]["attachments"] != attachments:
        raise ValueError("Font metadata or complete payload hashes differ from generated bytes")
    streams = observed["metadata"]["streams"]
    if not {"video", "audio", "subtitle"}.issubset({item["kind"] for item in streams}):
        raise ValueError("Fixture lost a required media stream")
    if len(observed["metadata"]["chapters"]) != 2:
        raise ValueError("Fixture lost chapter metadata")
    native_attachments = [item for item in streams if item["kind"] == "attachment"]
    if len(native_attachments) != len(case["attachments"]):
        raise ValueError("Native attachment stream inventory changed")
    codec_data = {item["stream_index"]: item["payload"] for item in observed["codec_private_data"]}
    for stream, entry in zip(native_attachments, case["attachments"], strict=True):
        if codec_data[stream["index"]] != {key: entry[key] for key in ("bytes", "sha256")}:
            raise ValueError("Opt-out changed native attachment codec-private data")
    for field in ("initial_packets", "packets_after_seek"):
        if not observed[field] or len(observed[field]) >= 1_000:
            raise ValueError("Invalid packet-sequence receipt")
        packet_indices = {item["stream_index"] for item in observed[field]}
        required = {item["index"] for item in streams if item["kind"] in ("video", "audio", "subtitle")}
        if not required.issubset(packet_indices):
            raise ValueError("Packet sequence did not exercise every media stream")
    # Remove only the intentionally omitted Swift font array. Full stream and
    # chapter metadata, codec-private payloads, and both packet sequences match.
    common = dict(observed)
    common["metadata"] = dict(observed["metadata"], attachments=[])
    common["native_versions"] = {key: value[key] for key in (
        "ffmpeg_version", "avformat_version", "avcodec_version", "avutil_version")}
    previous = canonical.setdefault(case["name"], common)
    if common != previous:
        raise ValueError(f"Production output parity failed: {case['name']} {owner} {role}")


def summarize(observations, fixtures, pairs):
    expected = len(fixtures) * len(PROFILES) * pairs * 2
    if len(observations) != expected:
        raise ValueError(f"Incomplete cohort: {len(observations)} observations, expected {expected}")
    results = []
    for case in fixtures:
        for role, owner, count in PROFILES:
            rows = [row for row in observations if (row["case"], row["role"], row["owner"], row["input_count"])
                    == (case["name"], role, owner, count)]
            differences, percentages = [], []
            for pair in range(pairs):
                selected = [row for row in rows if row["pair"] == pair]
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                if len(selected) != 2 or [row["variant"] for row in selected] != list(order) \
                        or [row["order_index"] for row in selected] != [0, 1]:
                    raise ValueError("Missing, duplicate, or unbalanced pair")
                by_variant = {row["variant"]: row for row in selected}
                baseline = by_variant["baseline"]["allocator_retained_delta_bytes"]
                candidate = by_variant["candidate"]["allocator_retained_delta_bytes"]
                differences.append(baseline - candidate)
                percentages.append(100 * (1 - candidate / baseline) if baseline > 0 else None)
            result = {"case": case["name"], "role": role, "owner": owner, "input_count": count,
                      "pairs": pairs, "font_payload_bytes_per_input": case["font_payload_bytes"],
                      "allocator_paired_bytes_saved": differences,
                      "allocator_median_paired_bytes_saved": statistics.median(differences),
                      "allocator_paired_percent_reductions": percentages,
                      "allocator_median_paired_percent_reduction": statistics.median(
                          value for value in percentages if value is not None)
                          if all(value is not None for value in percentages) else None,
                      "candidate_lower_pairs": sum(value > 0 for value in differences)}
            for variant in VARIANTS:
                values = [row["allocator_retained_delta_bytes"] for row in rows if row["variant"] == variant]
                result[variant] = {"allocator_retained_delta_median_bytes": statistics.median(values),
                                   "allocator_retained_delta_min_bytes": min(values),
                                   "allocator_retained_delta_max_bytes": max(values),
                                   "font_payload_bytes": next(row["retained_font_payload_bytes"]
                                                              for row in rows if row["variant"] == variant)}
            results.append(result)
    return {"status": "complete", "observations": expected, "pairs": pairs, "cases": len(fixtures),
            "profiles": len(PROFILES), "allocator_metric": "malloc_zone_statistics(NULL).size_in_use",
            "scope": "retained native-input allocator delta after opening; not RSS, peak, or whole-player memory",
            "parity": "all metadata, codec-private data hashes, and full initial/seek packet receipts agree; default fonts match manifest",
            "results": results}


class Runner:
    def __init__(self, args, original, helpers):
        self.args, self.original, self.helpers = args, original, helpers
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty result directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands, self.observations, self.canonical, self.executables = [], [], {}, {}
        self.env = os.environ.copy()
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        compiler = args.swiftc or self.command(["xcrun", "--find", "swiftc"]).strip()
        # Preserve the swiftc symlink's argv[0], which selects compiler mode.
        self.swiftc = Path(compiler).absolute()
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        self.record = {
            "started_utc": datetime.now(timezone.utc).isoformat(), "baseline_commit": BASELINE,
            "candidate_commit": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "compiler_path": str(self.swiftc), "compiler_sha256": file_sha(self.swiftc),
            "sdk_path": self.sdk,
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "system": self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"]),
            "ffmpeg_prefix": str(self.prefix), "pairs": args.pairs,
            "profiles": PROFILES, "sources": {}, "binaries": {}, "native_libraries": {},
            "harness_inputs": {},
        }
        for name in ("run.py", "generate-fixtures.py", "baseline.json", "Harness.swift",
                     "CMemoryProbe/module.modulemap", "CMemoryProbe/memory.h"):
            target = self.output / "harness" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(HERE / name, target)
            self.record["harness_inputs"][name] = file_sha(target)
        self.fixtures = self.load_fixtures(args.fixtures.resolve(strict=True))

    def command(self, argv, *, log=None, timeout=300):
        argv = [str(item) for item in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - started,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)})
        write_json(self.output / "commands.json", self.commands)
        if log:
            (self.output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-2000:]}\n{result.stderr[-10000:]}")
        return result.stdout

    def load_fixtures(self, directory):
        cases = json.loads((directory / "manifest.json").read_text())
        if len(cases) != len(CASE_NAMES) or {case["name"] for case in cases} != CASE_NAMES:
            raise ValueError("The complete six-case fixture set is required")
        for case in cases:
            path = (directory / case["filename"]).resolve(strict=True)
            if not path.is_relative_to(directory) or not path.is_file():
                raise ValueError("Fixture path escapes its directory")
            if path.stat().st_size != case["size_bytes"] or file_sha(path) != case["sha256"]:
                raise ValueError("Fixture size/hash differs from generation receipt")
            case["path"] = str(path)
            for supported, key in ((True, "font_payload_bytes"), (False, "unsupported_payload_bytes")):
                if case[key] != sum(item["bytes"] for item in case["attachments"] if item["supported_font"] == supported):
                    raise ValueError("Fixture payload inventory sum mismatch")
        write_json(self.output / "fixtures.json", cases)
        shutil.copyfile(directory / "fixture-commands.json", self.output / "fixture-commands.json")
        return cases

    def prepare(self):
        for variant in VARIANTS:
            for path, content in self.original[variant].items():
                target = self.output / "sources" / variant / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
                self.record["sources"][f"{variant}:{path}"] = sha(content)
        module = self.output / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for path in C_SOURCES:
            (module / Path(path).relative_to("Sources/CFFmpeg")).write_bytes(self.original["candidate"][path])
        headers = {}
        for library in LIBRARIES:
            include = self.prefix / "include" / f"lib{library}"
            if not include.is_dir():
                raise ValueError(f"Missing FFmpeg headers: {include}")
            for path in sorted(include.rglob("*.h")):
                headers[str(path.relative_to(self.prefix / "include"))] = file_sha(path)
            native = (self.prefix / "lib" / f"lib{library}.dylib").resolve(strict=True)
            self.record["native_libraries"][library] = {"path": str(native), "sha256": file_sha(native)}
        write_json(self.output / "ffmpeg-headers.json", headers)
        self.record["ffmpeg_headers_manifest_sha256"] = file_sha(self.output / "ffmpeg-headers.json")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-sdk", self.sdk, "-I", module, "-Xcc", "-I" + str(self.prefix / "include"),
                 "-L", self.prefix / "lib", "-Xlinker", "-rpath", "-Xlinker", self.prefix / "lib",
                 "-module-cache-path", self.output / "module-cache",
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.record["compiler_flags"] = list(map(str, flags))
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            inputs = [self.output / "sources" / variant / path for path in FULL_SOURCES]
            helpers = directory / "ExtractedDeclarations.swift"
            helpers.write_bytes(self.helpers[variant])
            inputs.append(helpers)
            self.record.setdefault("compiled_sources", {})[variant] = {
                str(path.relative_to(self.output)): file_sha(path) for path in inputs}
            library = directory / "libAuxiliaryFontInput.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AuxiliaryFontInput", "-emit-module-path", directory / "AuxiliaryFontInput.swiftmodule",
                          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryFontInput.dylib",
                          *inputs, "-o", library], log=f"{variant}-library-build.log")
            executable = directory / "auxiliary-font-memory"
            defines = ["-D", "AUXILIARY_FONT_CANDIDATE"] if variant == "candidate" else []
            self.command([self.swiftc, *flags, *defines, "-I", self.output / "harness/CMemoryProbe",
                          "-I", directory, "-L", directory, "-lAuxiliaryFontInput",
                          "-Xlinker", "-rpath", "-Xlinker", directory,
                          self.output / "harness/Harness.swift", "-o", executable],
                         log=f"{variant}-driver-build.log")
            self.executables[variant] = executable
            self.record["binaries"][variant] = {
                "library_sha256": file_sha(library), "executable_sha256": file_sha(executable),
                "library_linkage": self.command(["otool", "-L", library]),
                "executable_linkage": self.command(["otool", "-L", executable])}
        write_json(self.output / "manifest.json", self.record)

    def measure(self):
        warm = next(case["path"] for case in self.fixtures if case["name"] == "none")
        for case in self.fixtures:
            for role, owner, count in PROFILES:
                for pair in range(self.args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    for order_index, variant in enumerate(order):
                        value = json.loads(self.command([self.executables[variant], case["path"], owner, count, role, warm]))
                        check_observation(value, case, variant, owner, role, count, self.canonical)
                        value.update(case=case["name"], variant=variant, pair=pair, order_index=order_index)
                        self.observations.append(value)
                        with (self.output / "observations.jsonl").open("a") as stream:
                            stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
                print(json.dumps({"case": case["name"], "role": role, "owner": owner,
                                  "inputs": count, "pairs_complete": self.args.pairs}), flush=True)
        write_json(self.output / "parity.json", self.canonical)
        return summarize(self.observations, self.fixtures, self.args.pairs)

    def verify_inputs(self):
        for path in SOURCE_PATHS:
            if (ROOT / path).read_bytes() != self.original["candidate"][path]:
                raise ValueError(f"Source changed during measurement: {path}")
        for name, expected in self.record["harness_inputs"].items():
            if file_sha(HERE / name) != expected:
                raise ValueError(f"Harness input changed during measurement: {name}")
        for case in self.fixtures:
            if file_sha(Path(case["path"])) != case["sha256"]:
                raise ValueError(f"Fixture changed during measurement: {case['name']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-inputs", action="store_true")
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=4)
    args = parser.parse_args()
    original, helpers = source_inputs()
    if args.validate_inputs:
        print(json.dumps({"status": "validated", "baseline_commit": BASELINE,
                          "complete_production_sources_per_variant": len(FULL_SOURCES),
                          "source_snapshots_checked": len(SOURCE_PATHS) * 2,
                          "extracted_support_sha256": sha(helpers["baseline"])}, sort_keys=True))
        return
    if platform.system() != "Darwin":
        parser.error("Native execution requires macOS; use --validate-inputs for portable source checks")
    if args.fixtures is None or args.output is None or args.pairs <= 0 or args.pairs % 2:
        parser.error("Supply --fixtures, --output, and a positive even --pairs count")
    runner = None
    try:
        runner = Runner(args, original, helpers)
        runner.prepare()
        summary = runner.measure()
        runner.verify_inputs()
        runner.record["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.record)
        write_json(runner.output / "summary.json", summary)
        print("AUXILIARY_FONT_MEMORY_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    except Exception as error:
        if runner is not None:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "record"):
                write_json(runner.output / "manifest.json", runner.record)
        raise


if __name__ == "__main__":
    main()
