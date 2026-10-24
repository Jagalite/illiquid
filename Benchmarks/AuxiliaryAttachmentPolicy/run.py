#!/usr/bin/env python3
"""Measure live native readers using exact baseline/candidate Swift sources on macOS.

Each observation runs in a fresh process. Both variants retain a primary input;
only the candidate's auxiliary inputs omit unused Swift font payload copies.
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
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
EXECUTOR = "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"
SOURCES = [
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
LIBRARIES = ["avformat", "avfilter", "avcodec", "avutil", "swresample", "swscale"]
METRICS = ["allocator_open_delta_bytes", "allocator_release_delta_bytes",
           "process_max_rss_while_open_bytes", "opening_wall_seconds", "opening_cpu_seconds"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Extraction markers changed: {start!r} / {end!r}")
    result = source[source.index(start):source.index(end)]
    if result.count("{") != result.count("}"):
        raise ValueError("Unbalanced extracted declarations")
    return result


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        self.env = os.environ.copy()
        self.env.update(CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
                        SWIFT_MODULECACHE_PATH=str(self.output / "module-cache"))
        self.baseline = self.command(["git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}"]).strip()
        compiler = args.swiftc or self.command(["xcrun", "--find", "swiftc"]).strip()
        self.swiftc = Path(compiler).absolute()  # Preserve the swiftc argv[0] symlink.
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        self.record = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": self.baseline,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "compiler_sha256": sha(self.swiftc.read_bytes()),
            "sdk_path": self.sdk,
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "hardware": self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"]),
            "protocol": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
            "sources": {}, "compiled_sources": {}, "binaries": {},
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
            "generator_sha256": sha((HERE / "generate-fixtures.py").read_bytes()),
        }
        for name in ["run.py", "Harness.swift", "generate-fixtures.py"]:
            shutil.copyfile(HERE / name, self.output / ("snapshot-" + name))
        self.fixtures = json.loads((args.fixtures / "manifest.json").read_text())
        expected_names = {"none", "fonts-128kib", "fonts-2mib", "fonts-16mib", "fonts-64mib", "mixed"}
        if {case["name"] for case in self.fixtures} != expected_names or len(self.fixtures) != len(expected_names):
            raise ValueError("The complete controlled six-case fixture set is required")
        for case in self.fixtures:
            path = (args.fixtures / case["filename"]).resolve(strict=True)
            if not path.is_relative_to(args.fixtures.resolve()) or sha(path.read_bytes()) != case["sha256"]:
                raise ValueError("Invalid fixture path or digest")
            if not 0 <= case["accepted_payload_bytes"] <= 64 * 1024 * 1024:
                raise ValueError("Fixture exceeds the existing font budget")
        save(self.output / "fixtures.json", self.fixtures)
        self.exes = {}
        self.observations = []
        self.receipts = {}

    def command(self, argv, *, log=None, timeout=600):
        argv = [str(x) for x in argv]
        started = time.time()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True, timeout=timeout)
        stdout, stderr = result.stdout.decode(), result.stderr.decode()
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "started_unix": started,
                                     "seconds": time.time() - started, "returncode": result.returncode,
                                     "stdout_sha256": sha(result.stdout), "stderr": stderr}) + "\n")
        if log:
            (self.output / log).write_text(stdout + stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n{stdout[-4000:]}\n{stderr[-10000:]}")
        return stdout

    def build(self):
        originals = {}
        for variant in ["baseline", "candidate"]:
            originals[variant] = {}
            for relative in SOURCES + C_SOURCES + [PRESENTATION, BITMAP]:
                data = ((ROOT / relative).read_bytes() if variant == "candidate" else
                        self.command(["git", "show", f"{self.baseline}:{relative}"]).encode())
                target = self.output / "sources" / variant / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                originals[variant][relative] = data.decode()
                self.record["sources"][f"{variant}:{relative}"] = {"sha256": sha(data), "bytes": len(data)}
        for relative in set(SOURCES + C_SOURCES) - {DEMUXER, EXECUTOR}:
            if originals["baseline"][relative] != originals["candidate"][relative]:
                raise ValueError(f"Unrelated shared dependency changed: {relative}")

        module = self.output / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for relative in C_SOURCES:
            (module / Path(relative).relative_to("Sources/CFFmpeg")).write_text(originals["candidate"][relative])
        libraries = {}
        headers = {}
        for name in LIBRARIES:
            library = (self.prefix / "lib" / f"lib{name}.dylib").resolve(strict=True)
            libraries[name] = {"path": str(library), "sha256": sha(library.read_bytes())}
            include = self.prefix / "include" / f"lib{name}"
            if not include.is_dir():
                raise ValueError(f"Missing native headers: {include}")
            for path in sorted(include.rglob("*.h")):
                headers[str(path.relative_to(self.prefix / "include"))] = sha(path.read_bytes())
        save(self.output / "ffmpeg-headers.json", headers)
        self.record["native_libraries"] = libraries
        self.record["native_headers_manifest_sha256"] = sha((self.output / "ffmpeg-headers.json").read_bytes())
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
                 "-parse-as-library", "-sdk", self.sdk, "-I", module,
                 "-Xcc", "-I" + str(self.prefix / "include"), "-L", self.prefix / "lib",
                 "-Xlinker", "-rpath", "-Xlinker", self.prefix / "lib",
                 "-module-cache-path", self.output / "module-cache",
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.record["compiler_flags"] = list(map(str, flags))
        helpers = {}
        for variant in ["baseline", "candidate"]:
            original = originals[variant]
            helpers[variant] = "import Foundation\n\n" + extract(
                original[PRESENTATION], "struct PresentationError:", "\nfunc checkOSStatus("
            ) + "\n" + extract(original[BITMAP], "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
        if helpers["baseline"] != helpers["candidate"]:
            raise ValueError("Shared extracted declarations differ")
        for variant in ["baseline", "candidate"]:
            directory = self.output / variant
            directory.mkdir()
            inputs = []
            for relative in SOURCES:
                target = directory / Path(relative).name
                target.write_text(originals[variant][relative])
                inputs.append(target)
            helper = directory / "ExtractedDeclarations.swift"
            helper.write_text(helpers[variant])
            inputs.append(helper)
            self.record["compiled_sources"][variant] = {str(p.relative_to(self.output)): sha(p.read_bytes()) for p in inputs}
            library = directory / "libAttachmentProjection.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AttachmentProjection", "-emit-module-path",
                          directory / "AttachmentProjection.swiftmodule", "-Xlinker", "-install_name",
                          "-Xlinker", "@rpath/libAttachmentProjection.dylib", *inputs, "-o", library],
                         log=f"{variant}-library-build.log")
            executable = directory / "auxiliary-attachments"
            mode = ["-D", "OMIT_AUXILIARY_ATTACHMENTS"] if variant == "candidate" else []
            self.command([self.swiftc, *flags, *mode, "-I", directory, "-L", directory, "-lAttachmentProjection",
                          "-Xlinker", "-rpath", "-Xlinker", directory,
                          HERE / "Harness.swift", "-o", executable], log=f"{variant}-driver-build.log")
            self.exes[variant] = executable
            self.record["binaries"][variant] = {"library_sha256": sha(library.read_bytes()),
                "executable_sha256": sha(executable.read_bytes()),
                "linkage": self.command(["otool", "-L", executable])}
        save(self.output / "manifest.json", self.record)

    def measure(self):
        for case_index, case in enumerate(self.fixtures):
            for reader in ["demuxer", "executor"]:
                for auxiliaries in [0, 1, 2]:
                    key = f"{case['name']}/{reader}/{auxiliaries}"
                    for pair in range(self.args.pairs):
                        order = ["baseline", "candidate"] if (pair + case_index) % 2 == 0 else ["candidate", "baseline"]
                        for position, variant in enumerate(order):
                            raw = self.command([self.exes[variant], self.args.fixtures / case["filename"], reader,
                                                auxiliaries, case["accepted_payload_bytes"]], timeout=120)
                            value = json.loads(raw)
                            if (value["variant"] != variant or value["reader"] != reader
                                    or value["auxiliary_count"] != auxiliaries
                                    or value["expected_font_bytes"] != case["accepted_payload_bytes"]):
                                raise ValueError("Harness command receipt differs")
                            expected_aux = auxiliaries * case["accepted_payload_bytes"] if variant == "baseline" else 0
                            if (value["primary_retained_payload_bytes"] != case["accepted_payload_bytes"]
                                    or value["auxiliary_retained_payload_bytes"] != expected_aux
                                    or value["total_retained_payload_bytes"] != expected_aux + case["accepted_payload_bytes"]):
                                raise ValueError("Retained payload ownership does not match policy")
                            for metric in METRICS:
                                if not isinstance(value[metric], (int, float)) or not math.isfinite(value[metric]):
                                    raise ValueError(f"Invalid measurement: {metric}")
                                if metric in {"opening_wall_seconds", "opening_cpu_seconds", "process_max_rss_while_open_bytes"} and value[metric] < 0:
                                    raise ValueError(f"Negative measurement: {metric}")
                            validation = value.pop("validation")
                            if key in self.receipts and self.receipts[key] != validation:
                                raise ValueError(f"Metadata, codec or packet parity differs: {key} {variant}")
                            self.receipts[key] = validation
                            value.update(case=case["name"], pair=pair, order=order, position=position,
                                         validation_sha256=sha(json.dumps(validation, sort_keys=True).encode()))
                            self.observations.append(value)
                            with (self.output / "observations.jsonl").open("a") as stream:
                                stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
                        save(self.output / "parity.json", self.receipts)
                    print(json.dumps({"completed": key, "pairs": self.args.pairs}), flush=True)
        self.summarize()

    def summarize(self):
        groups = []
        for case in self.fixtures:
            for reader in ["demuxer", "executor"]:
                for auxiliaries in [0, 1, 2]:
                    rows = [r for r in self.observations if r["case"] == case["name"]
                            and r["reader"] == reader and r["auxiliary_count"] == auxiliaries]
                    if len(rows) != self.args.pairs * 2:
                        raise ValueError("Incomplete measurement group")
                    before = sorted([r for r in rows if r["variant"] == "baseline"], key=lambda r: r["pair"])
                    after = sorted([r for r in rows if r["variant"] == "candidate"], key=lambda r: r["pair"])
                    group = {"case": case["name"], "reader": reader, "auxiliary_count": auxiliaries,
                             "pairs": self.args.pairs, "payload_bytes_saved": case["accepted_payload_bytes"] * auxiliaries}
                    for metric in METRICS:
                        changes = [a[metric] - b[metric] for a, b in zip(before, after)]
                        group[metric] = {"baseline_median": statistics.median(r[metric] for r in before),
                                         "candidate_median": statistics.median(r[metric] for r in after),
                                         "paired_savings_median": statistics.median(changes),
                                         "paired_savings_min": min(changes), "paired_savings_max": max(changes)}
                    groups.append(group)
        save(self.output / "summary.json", {"pairs": self.args.pairs, "observations": len(self.observations),
             "groups": groups, "notes": [
                 "Live allocator bytes are measured while all native inputs remain open; FFmpeg-owned extradata remains allocated.",
                 "Peak RSS includes runtime/input loading and is a process high-water mark, not the player's physical footprint.",
                 "Synthetic font-labeled payloads exercise copying and retention; a separate native test uses a real font.",
                 "Hashing, metadata serialization and packet validation run only after the measured reader cohort releases.",
                 "All observations are retained. Pair order alternates AB/BA; no timing thresholds or sample exclusions."]})
        save(self.output / "completion.json", {"status": "complete", "observations": len(self.observations),
             "parity_groups": len(self.receipts), "finished_utc": datetime.now(timezone.utc).isoformat()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--swiftc")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=6)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This benchmark requires macOS and the native FFmpeg SDK")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("Use a positive even pair count (at least two)")
    args.fixtures = args.fixtures.resolve(strict=True)
    runner = Runner(args)
    try:
        runner.build()
        runner.measure()
    except Exception as error:
        save(runner.output / "failure.json", {"error": str(error), "observations": len(runner.observations)})
        raise


if __name__ == "__main__":
    main()
