#!/usr/bin/env python3
"""Measure live memory of complete production auxiliary demuxers and input executors.

Requires macOS, Swift 6.1+, and an installed FFmpeg prefix. No dependencies or
fixtures are downloaded. Every observation is a new process; no samples
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
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
FONT = "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift"
INPUT = "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"
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
APIS = ("direct", "executor")
SCENARIOS = ("primary", "auxiliary", "primary-two-auxiliary")


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
        required = {"none", "fonts-2mib", "fonts-16mib", "fonts-64mib", "mixed-6mib"}
        if names != required:
            raise ValueError(f"Expected the complete five-case fixture set; got {sorted(names)}")
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
        for path in set(FULL_SOURCES + C_SOURCES) - {DEMUXER, INPUT}:
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
        heap = self.output / "CAuxiliaryFontHeap"
        shutil.copytree(HERE / "CAuxiliaryFontHeap", heap)
        self.record["allocator_helper_sources"] = {
            str(p.relative_to(heap)): file_sha(p) for p in sorted(heap.iterdir()) if p.is_file()}
        clang = self.command(["xcrun", "--find", "clang"]).strip()
        self.record["clang_version"] = self.command([clang, "--version"]).strip()
        self.record["clang_sha256"] = file_sha(Path(clang))
        heap_object = self.output / "heap.o"
        self.command([clang, "-O2", "-Wall", "-Wextra", "-Werror", "-isysroot", self.sdk,
                      "-c", heap / "heap.c", "-o", heap_object], log="heap-build.log")
        self.record["allocator_helper_object_sha256"] = file_sha(heap_object)
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-sdk", self.sdk,
                 "-I", str(module), "-I", str(heap), "-Xcc", "-I" + str(self.prefix / "include"),
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
                          *(["-D", "AUXILIARY_FONT_CANDIDATE"] if variant == "candidate" else []),
                          self.output / "Harness.swift", heap_object, "-o", executable], log=f"{variant}-driver-build.log")
            self.exes[variant] = executable
            self.record["binaries"][variant] = {"library_sha256": file_sha(library), "executable_sha256": file_sha(executable),
                "library_linkage": self.command(["otool", "-L", library]),
                "executable_linkage": self.command(["otool", "-L", executable])}
        write_json(self.output / "manifest.json", self.record)


    def sample(self, variant, case, api, scenario, pair, order_index):
        raw = self.command([self.exes[variant], case["path"], api, scenario,
                            case["accepted_payload_bytes"]], timeout=180)
        value = json.loads(raw)
        if value["api"] != api or value["scenario"] != scenario:
            raise ValueError("Harness argument receipt mismatch")
        expected_roles = {"primary": [False], "auxiliary": [True],
                          "primary-two-auxiliary": [False, True, True]}[scenario]
        if value["reader_count"] != len(expected_roles) or len(value["readers"]) != len(expected_roles):
            raise ValueError("Reader count mismatch")
        expected_payload = case["accepted_payload_bytes"] * sum(
            variant == "baseline" or not auxiliary for auxiliary in expected_roles)
        if value["retained_font_payload_bytes"] != expected_payload:
            raise ValueError("Retained owning font payload mismatch")
        for field in ("setup_wall_seconds", "setup_cpu_seconds"):
            if not isinstance(value[field], (int, float)) or not math.isfinite(value[field]) or value[field] < 0:
                raise ValueError(f"Invalid {field}")
        if value["setup_wall_seconds"] <= 0:
            raise ValueError("Nonpositive setup time")
        for field in ("allocator_before_bytes", "allocator_retained_bytes", "allocator_after_release_bytes",
                      "process_peak_rss_before_bytes", "process_peak_rss_after_open_bytes"):
            if not isinstance(value[field], int) or value[field] < 0:
                raise ValueError(f"Invalid {field}")
        if value["retained_allocator_delta_bytes"] != value["allocator_retained_bytes"] - value["allocator_before_bytes"]:
            raise ValueError("Invalid retained delta")
        if value["after_release_allocator_delta_bytes"] != value["allocator_after_release_bytes"] - value["allocator_before_bytes"]:
            raise ValueError("Invalid release delta")
        for auxiliary, receipt in zip(expected_roles, value["readers"]):
            if receipt["auxiliary"] != auxiliary or not receipt["owned_lifetime_verified"] or not receipt["observed_eof_twice"]:
                raise ValueError("Missing reader verification")
            expected_attachments = [] if variant == "candidate" and auxiliary else case["accepted_attachments"]
            if receipt["info"]["attachments"] != expected_attachments:
                raise ValueError(f"Font bytes/metadata disagree with independent fixture manifest: {case['name']} {variant}")
            normalized = {key: receipt[key] for key in ("codec_private", "initial_packets", "sought_packets")}
            normalized["info"] = {key: val for key, val in receipt["info"].items() if key != "attachments"}
            normalized["ffmpeg_versions"] = {key: value[key] for key in (
                "ffmpeg_version", "avformat_version", "avcodec_version", "avutil_version")}
            reference = self.parity.setdefault(case["name"], normalized)
            if reference != normalized:
                raise ValueError(f"Metadata/native codec-private/read/seek output differs: {case['name']} {variant} {api} {scenario}")
        value.update(variant=variant, case=case["name"], pair=pair, order_index=order_index)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
        return value

    def measure(self):
        for case in self.fixtures:
            for api in APIS:
                for scenario in SCENARIOS:
                    for pair in range(self.args.pairs):
                        order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                        for order_index, variant in enumerate(order):
                            self.measurements.append(self.sample(variant, case, api, scenario, pair, order_index))
                    print(json.dumps({"progress": "completed", "case": case["name"], "api": api,
                                      "scenario": scenario, "pairs": self.args.pairs}), flush=True)
        expected = len(self.fixtures) * len(APIS) * len(SCENARIOS) * self.args.pairs * 2
        if len(self.measurements) != expected:
            raise ValueError("Incomplete measurement matrix")
        write_json(self.output / "parity.json", self.parity)
        results = []
        fields = ("retained_allocator_delta_bytes", "retained_font_payload_bytes",
                  "after_release_allocator_delta_bytes", "setup_wall_seconds", "setup_cpu_seconds",
                  "process_peak_rss_after_open_bytes")
        for case in self.fixtures:
            for api in APIS:
                for scenario in SCENARIOS:
                    rows = [r for r in self.measurements if r["case"] == case["name"]
                            and r["api"] == api and r["scenario"] == scenario]
                    result = {"case": case["name"], "api": api, "scenario": scenario,
                              "pairs": self.args.pairs, "metrics": {}}
                    for field in fields:
                        by_variant = {v: [next(r[field] for r in rows if r["variant"] == v and r["pair"] == pair)
                                          for pair in range(self.args.pairs)] for v in VARIANTS}
                        a, b = by_variant["baseline"], by_variant["candidate"]
                        result["metrics"][field] = {
                            "baseline_median": statistics.median(a), "candidate_median": statistics.median(b),
                            "baseline_range": [min(a), max(a)], "candidate_range": [min(b), max(b)],
                            "paired_change_median": statistics.median(y - x for x, y in zip(a, b)),
                            "paired_change_percent_median": statistics.median((y - x) / x * 100 for x, y in zip(a, b)) if all(x > 0 for x in a) else None,
                            "candidate_lower_pairs": sum(y < x for x, y in zip(a, b)),
                        }
                    results.append(result)
        return {
            "status": "complete", "observations": expected, "pairs": self.args.pairs,
            "cases": len(self.fixtures), "apis": list(APIS), "scenarios": list(SCENARIOS),
            "parity": "All stored/derived media metadata except intentional auxiliary attachment omission, native codec-private bytes, and every initial/seek packet agree across variants, APIs, roles and pairs; primary attachment hashes match fixture manifests and survive input destruction.",
            "memory_metric": "Additional live allocator-accounted bytes after complete reader construction and autorelease drainage, relative to a baseline after opening and closing the same fixture once; includes native FFmpeg and Swift/runtime allocations, excludes allocations not represented by malloc zones. Not RSS or exact object sizes.",
            "payload_metric": "Sum of byte counts in owning Swift FontAttachment Data values held by all measured readers; not backing-capacity or process memory.",
            "peak_rss_metric": "Whole-process high-water bytes sampled after setup; includes the identical primary-reader warm-up. It is not an incremental or isolated setup peak.",
            "timing_metric": "One complete setup observation, including autorelease drainage; uncalibrated and potentially noisy. No throughput or whole-player speedup claim.",
            "results": results,
        }

    def verify_inputs(self):
        for key, receipt in self.sources.items():
            variant, path = key.split(":", 1)
            if variant == "candidate" and sha((ROOT / path).read_text()) != receipt["sha256"]:
                raise ValueError(f"Production source changed during benchmark: {path}")
        if file_sha(HERE / "Harness.swift") != self.record["harness_sha256"] or file_sha(Path(__file__)) != self.record["runner_sha256"]:
            raise ValueError("Harness or runner changed during benchmark")
        for path, expected in self.record["allocator_helper_sources"].items():
            if file_sha(HERE / "CAuxiliaryFontHeap" / path) != expected:
                raise ValueError("Allocator helper changed during benchmark")
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
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This benchmark requires native macOS frameworks and FFmpeg")
    if args.pairs <= 0 or args.pairs % 2:
        parser.error("Use a positive even pair count for balanced AB/BA order")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        summary = runner.measure()
        runner.verify_inputs()
        runner.record["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.record)
        write_json(runner.output / "summary.json", summary)
        print("AUXILIARY_FONT_ATTACHMENTS_SUMMARY " + json.dumps(summary, sort_keys=True, allow_nan=False), flush=True)
    except Exception as error:
        if runner is not None:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "record"):
                write_json(runner.output / "manifest.json", runner.record)
        raise


if __name__ == "__main__":
    main()
