#!/usr/bin/env python3
"""Measure production PGS/DVB acquisition scans with real owned FFmpeg packets.

macOS uses the complete native CFFmpeg module. Linux uses the pinned FFmpeg
archive built by DeinterlacerEOFMemory/build-linux-ffmpeg.sh, a header containing
unchanged used shim helpers, and unchanged non-CoreMedia timestamp declarations.
No packet, allocator, parser, or FFmpeg ownership operation is mocked.
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
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
NATIVE = "Sources/IlliquidNativePlayback/"
TIMELINE = NATIVE + "Subtitles/BitmapSubtitleTimeline.swift"
DEMUXER = NATIVE + "Media/FFmpegDemuxer.swift"
SHARED = [NATIVE + value for value in ["Media/FFmpegPacket.swift", "Media/FFmpegError.swift",
    "Media/MediaTime.swift", "Playback/PacketQueue.swift", "Playback/FixedRingBuffer.swift"]]
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
MODULE = "Sources/CFFmpeg/module.modulemap"
TEST = "Tests/IlliquidNativePlaybackTests/BitmapSubtitleAcquisitionBorrowTests.swift"
METER = "Benchmarks/SubtitleAcquisitionBorrow/allocmeter.c"
CASES = ["disabled", "pgs_empty", "pgs_tiny", "pgs_object_4k", "pgs_object_64k",
         "pgs_object_256k", "pgs_first_64k", "pgs_last_64k", "dvb_tiny",
         "dvb_object_4k", "dvb_object_64k", "dvb_object_256k", "dvb_first_64k", "dvb_last_64k"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise ValueError(f"Expected one declaration: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1] + "\n"
    raise ValueError(f"Unbalanced declaration: {marker}")


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new, empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.linux = platform.system() == "Linux"
        if not self.linux and platform.system() != "Darwin":
            raise ValueError("Only Linux/glibc and macOS are supported")
        self.swiftc = str(Path(args.swiftc).absolute()) if Path(args.swiftc).exists() else args.swiftc
        self.swift = str(Path(self.swiftc).with_name("swift"))
        self.sdk = args.ffmpeg_prefix.resolve()
        self.environment = os.environ.copy()
        self.environment.update({key: str(self.output / "module-cache") for key in
                                 ["SWIFT_MODULECACHE_PATH", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"]})
        self.environment["TMPDIR"] = str(self.output / "tmp")
        (self.output / "tmp").mkdir()
        self.commands = []
        self.sources = {}
        self.binaries = {}
        self.receipt = {"baseline_commit": BASELINE, "platform": platform.platform(),
                        "machine": platform.machine(), "started_utc": datetime.now(timezone.utc).isoformat(),
                        "source_hashes": {}, "staged_hashes": {}, "binary_hashes": {},
                        "pairs": args.pairs, "cases": args.cases, "target_ms": args.target_ms,
                        "linux_adaptation": "Real FFmpeg 8.1.2; used inline C shim helpers and non-CoreMedia timestamp declarations extracted unchanged" if self.linux else None,
                        "scope": "Acquisition checks only, excluding demux I/O, seek scheduling, decoding, renderer and player RSS",
                        "allocation_metric": "Successful intercepted malloc/calloc/realloc requested bytes and calls; excludes aligned/other APIs; separate instrumented processes using LD_PRELOAD on Linux/glibc and DYLD interposition on macOS; not live bytes or RSS",
                        "build_coordination": "Serial isolated builds; use Kyoto when available; no shared .build"}

    def command(self, argv, name, *, environment=None, timeout=600):
        argv = [str(value) for value in argv]
        env = self.environment.copy()
        env.update(environment or {})
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
        log = self.output / "logs" / f"{len(self.commands):04d}-{name}.log"
        log.parent.mkdir(exist_ok=True)
        log.write_text(result.stdout + result.stderr)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "seconds": time.monotonic() - start, "environment_add": environment or {},
                              "log": str(log.relative_to(self.output)), "sha256": digest(log.read_bytes())})
        save(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n{result.stdout[-3000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def stage(self, name, data):
        data = data.encode() if isinstance(data, str) else data
        path = self.output / "sources" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.receipt["staged_hashes"][str(path.relative_to(self.output))] = digest(data)
        return path

    def prepare(self):
        self.receipt["compiler"] = self.command([self.swiftc, "--version"], "compiler").strip()
        self.receipt["candidate_head"] = self.command(["git", "rev-parse", "HEAD"], "head").strip()
        self.command(["git", "cat-file", "-e", f"{BASELINE}^{{commit}}"], "baseline-available")
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestor")
        self.receipt["candidate_status"] = self.command(["git", "status", "--short"], "status")
        baseline = self.command(["git", "show", f"{BASELINE}:{TIMELINE}"], "baseline-timeline")
        old_demux = self.command(["git", "show", f"{BASELINE}:{DEMUXER}"], "baseline-demuxer")
        new_demux = (ROOT / DEMUXER).read_text()
        if "needsAcquisition && packet.data.map" not in old_demux:
            raise ValueError("Review changed baseline call site")
        if "needsAcquisition && Self.isSubtitleAcquisition(" not in new_demux:
            raise ValueError("Candidate demuxer does not use packet borrowing")
        self.stage("originals/baseline/BitmapSubtitleTimeline.swift", baseline)
        self.stage("originals/baseline/FFmpegDemuxer.swift", old_demux)
        self.stage("originals/candidate/FFmpegDemuxer.swift", new_demux)
        baseline_parser = "import Foundation\n\n" + declaration(baseline, "enum PGSSubtitlePacket {") + "\n" + declaration(baseline, "enum DVBSubtitlePacket {")
        if (ROOT / TIMELINE).read_text() != baseline:
            raise ValueError("Shared parsers changed; review the benchmark")
        helper = "import CFFmpeg\nimport Foundation\n\nenum FFmpegDemuxer {\n" + declaration(new_demux, "    static func isSubtitleAcquisition(") + "}\n"
        parsers = {"baseline": [self.stage("baseline/BitmapSubtitlePacket.swift", baseline_parser)],
                   "candidate": [self.stage("candidate/BitmapSubtitlePacket.swift", baseline_parser),
                                 self.stage("candidate/FFmpegDemuxer.swift", helper)]}
        shared = []
        inputs = {}
        for path in SHARED + [SHIM, MODULE]:
            data = (ROOT / path).read_bytes()
            original = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{BASELINE}:{path}"])
            if data != original:
                raise ValueError(f"Shared dependency changed: {path}; review the benchmark")
            inputs[path] = data
            self.receipt["source_hashes"][path] = digest(data)
            self.stage("originals/shared/" + path, data)
        for path in [DEMUXER, TIMELINE, TEST, METER]:
            self.receipt["source_hashes"][path] = digest((ROOT / path).read_bytes())
        for path in SHARED:
            if self.linux and path.endswith("MediaTime.swift"):
                text = inputs[path].decode()
                data = ("import CFFmpeg\nimport Foundation\n" + declaration(text, "struct FFmpegRational:")
                        + "\nenum MediaTime {\n" + declaration(text, "    static func seconds(") + "}\n")
            else:
                data = inputs[path]
            shared.append(self.stage("shared/" + Path(path).name, data))
        module = self.output / "sources/CFFmpeg"
        if self.linux:
            text = inputs[SHIM].decode()
            header = "#include <libavcodec/avcodec.h>\n#include <libavutil/avutil.h>\n#include <libavutil/error.h>\n"
            for name in ["illiquid_averror_eagain", "illiquid_averror_eof", "illiquid_averror_nomem",
                         "illiquid_averror_invaliddata", "illiquid_averror_exit", "illiquid_nopts_value",
                         "illiquid_packet_is_corrupt", "illiquid_packet_is_keyframe"]:
                match = re.search(r"(?m)^static inline [^\n]*\b" + name + r"\(", text)
                if match is None:
                    raise ValueError("Missing production helper " + name)
                header += declaration(text, text[match.start():text.index("(", match.start()) + 1])
            self.stage("CFFmpeg/include/ffmpeg_shim.h", header)
            self.stage("CFFmpeg/module.modulemap", 'module CFFmpeg [system] { header "include/ffmpeg_shim.h" link "avcodec" link "avutil" export * }\n')
            links = ["-lavcodec", "-lavutil", "-lm", "-lpthread", "-latomic", "-ldl"]
            for name in ["source-receipt.json", "build-receipt.json"]:
                self.receipt[name] = json.loads((self.sdk / name).read_text())
        else:
            self.stage("CFFmpeg/include/ffmpeg_shim.h", inputs[SHIM])
            self.stage("CFFmpeg/module.modulemap", inputs[MODULE])
            links = ["-lavformat", "-lavfilter", "-lavcodec", "-lavutil", "-lswresample", "-lswscale"]
        if not (self.sdk / "include/libavcodec/avcodec.h").is_file():
            raise ValueError("Missing real FFmpeg SDK: " + str(self.sdk))
        self.receipt["sdk_libraries"] = {str(p.relative_to(self.sdk)): digest(p.read_bytes())
            for pattern in (["libavcodec.a", "libavutil.a"] if self.linux else ["libavcodec*.dylib", "libavutil*.dylib"])
            for p in sorted((self.sdk / "lib").glob(pattern)) if not p.is_symlink()}
        self.flags = ["-swift-version", "6", "-warnings-as-errors", "-I", module,
                      "-Xcc", "-I" + str(self.sdk / "include"), "-L", self.sdk / "lib",
                      "-Xlinker", "-rpath", "-Xlinker", self.sdk / "lib", *links,
                      "-module-cache-path", self.output / "module-cache"]
        driver = self.stage("harness/Driver.swift", (HERE / "Driver.swift").read_bytes())
        self.stage("harness/run.py", Path(__file__).read_bytes())
        meter_source = self.stage("harness/allocmeter.c", (ROOT / METER).read_bytes())
        meter = self.output / ("libacquisition_allocmeter.so" if self.linux else "libacquisition_allocmeter.dylib")
        self.command(["cc", "-O2", "-shared" if self.linux else "-dynamiclib", "-fPIC", meter_source, "-o", meter], "build-allocation-meter")
        for variant in ["baseline", "candidate"]:
            self.sources[variant] = shared + parsers[variant]
            directory = self.output / "bin" / variant
            directory.mkdir(parents=True)
            self.binaries[variant] = {}
            for kind in ["plain", "allocations"]:
                executable = directory / kind
                flags = (["-D", "BASELINE"] if variant == "baseline" else [])
                if kind == "allocations":
                    flags += ["-D", "ALLOCATIONS", meter, "-Xlinker", "-rpath", "-Xlinker", self.output]
                self.command([self.swiftc, "-O", "-whole-module-optimization", "-parse-as-library",
                              *self.flags, *flags, *self.sources[variant], driver, "-o", executable],
                             f"build-{variant}-{kind}")
                self.binaries[variant][kind] = executable
                self.receipt["binary_hashes"][f"{variant}/{kind}"] = digest(executable.read_bytes())
        self.meter = meter
        save(self.output / "manifest.json", self.receipt)

    def tests(self):
        package = self.output / "tests"
        source = package / "Sources/IlliquidNativePlayback"
        test = package / "Tests/IlliquidNativePlaybackTests"
        source.mkdir(parents=True)
        test.mkdir(parents=True)
        for path in self.sources["candidate"]:
            shutil.copyfile(path, source / path.name)
        shutil.copytree(self.output / "sources/CFFmpeg", package / "Sources/CFFmpeg")
        shutil.copyfile(ROOT / TEST, test / Path(TEST).name)
        include = json.dumps("-I" + str(self.sdk / "include"))
        library = json.dumps("-L" + str(self.sdk / "lib"))
        extra_links = ', "-lm", "-lpthread", "-latomic", "-ldl"' if self.linux else ""
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleAcquisitionBorrow", platforms: [.macOS("26.0")], targets: [
    .systemLibrary(name: "CFFmpeg"),
    .target(name: "IlliquidNativePlayback", dependencies: ["CFFmpeg"],
        swiftSettings: [.unsafeFlags(["-Xcc", ''' + include + '''])],
        linkerSettings: [.unsafeFlags([''' + library + extra_links + '''])]),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback", "CFFmpeg"],
        swiftSettings: [.unsafeFlags(["-Xcc", ''' + include + '''])]),
], swiftLanguageModes: [.v6])
''')
        for configuration in ["debug", "release"]:
            self.command([self.swift, "test", "--package-path", package, "--jobs", "2", "--no-parallel",
                          "--cache-path", self.output / "swift-cache", "--config-path", self.output / "swift-config",
                          "--security-path", self.output / "swift-security", "-c", configuration,
                          "-Xswiftc", "-warnings-as-errors"], f"candidate-{configuration}-tests")
            print(f"Candidate {configuration} tests passed", flush=True)

    def observe(self, variant, case, iterations, mode="timing", label="sample"):
        kind = "allocations" if mode == "allocations" else "plain"
        env = {"LD_PRELOAD" if self.linux else "DYLD_INSERT_LIBRARIES": str(self.meter)} if kind == "allocations" else None
        row = json.loads(self.command([self.binaries[variant][kind], mode, case, iterations],
                                      f"{label}-{variant}-{case}", environment=env))
        if row["iterations"] != iterations or row["case"] != case:
            raise ValueError("Measurement receipt differs from request")
        row["variant"] = variant
        return row

    def run(self):
        self.prepare()
        self.tests()
        outcomes = {}
        for variant in ["baseline", "candidate"]:
            outcomes[variant] = json.loads(self.command([self.binaries[variant]["plain"], "verify"], f"verify-{variant}"))
        if outcomes["baseline"] != outcomes["candidate"]:
            save(self.output / "parity-failure.json", outcomes)
            raise ValueError("Baseline/candidate complete outcomes differ")
        save(self.output / "parity.json", {"equal": True, "fixture_count": len(outcomes["baseline"]["outcomes"]),
                                           "outcomes": outcomes["baseline"]["outcomes"]})
        if self.args.tests_only:
            save(self.output / "completion.json", {"tests": "passed", "parity": True, "timing": "not run"})
            return
        observations = []
        pilots = []
        summaries = {}
        for case in self.args.cases:
            iterations = {}
            for variant in ["baseline", "candidate"]:
                count = 4_096
                for attempt in range(6):
                    row = self.observe(variant, case, count, label="calibration")
                    pilots.append(row)
                    save(self.output / "calibration.json", pilots)
                    elapsed = min(row["wall_nanoseconds"], row["cpu_nanoseconds"])
                    if elapsed >= self.args.target_ms * 1_000_000:
                        break
                    count = min(100_000_000, math.ceil(count * self.args.target_ms * 1_000_000 / max(1, elapsed) * 1.15 / 16) * 16)
                else:
                    raise RuntimeError("Could not calibrate " + case)
                iterations[variant] = count
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for variant in order:
                    row = self.observe(variant, case, iterations[variant])
                    row["pair"] = pair
                    observations.append(row)
                    (self.output / "measurements.jsonl").write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in observations))
                    if min(row["wall_nanoseconds"], row["cpu_nanoseconds"]) < self.args.target_ms * 500_000:
                        raise RuntimeError("Timed sample too short; increase target-ms")
                pair_rows = observations[-2:]
                for key in ["packet_sizes", "expected_cycle", "cycle_checksum"]:
                    if pair_rows[0][key] != pair_rows[1][key]:
                        raise ValueError("Measured pair semantic mismatch: " + key)
                for variant in order:
                    row = self.observe(variant, case, 256, mode="allocations")
                    row["pair"] = pair
                    observations.append(row)
                    (self.output / "measurements.jsonl").write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in observations))
                    if variant == "baseline" and "object_64k" in case and row["allocation_requested_bytes"] < 65_535 * 256:
                        raise ValueError("Allocation interposer did not observe the baseline payload allocations")
                (self.output / "measurements.jsonl").write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in observations))
            values = [row for row in observations if row["case"] == case]
            summary = {}
            for metric in ["wall_nanoseconds", "cpu_nanoseconds", "allocation_requests", "allocation_requested_bytes"]:
                by_variant = {variant: [row[metric] / row["iterations"] for row in values
                                        if row["variant"] == variant and metric in row] for variant in ["baseline", "candidate"]}
                if not by_variant["baseline"]:
                    continue
                medians = {key: statistics.median(value) for key, value in by_variant.items()}
                summary[metric + "_per_packet"] = {**medians,
                    "baseline_range": [min(by_variant["baseline"]), max(by_variant["baseline"])],
                    "candidate_range": [min(by_variant["candidate"]), max(by_variant["candidate"])],
                    "reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]) if medians["baseline"] else None}
            summary["packet_sizes"] = values[0]["packet_sizes"]
            summaries[case] = summary
            save(self.output / "summary.json", summaries)
            save(self.output / "calibration.json", pilots)
            print(case + ": " + json.dumps(summary["wall_nanoseconds_per_packet"]), flush=True)
        save(self.output / "completion.json", {"tests": "passed debug and release", "parity": True,
            "timing": "passed", "pairs": self.args.pairs, "cases": len(self.args.cases),
            "observations": len(observations), "allocation_traffic": "measured"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=120)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    args.cases = args.cases.split(",")
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 60:
        parser.error("Use an even pair count >= 2 and target-ms >= 60")
    if any(case not in CASES for case in args.cases):
        parser.error("Unknown workload")
    Study(args).run()


if __name__ == "__main__":
    main()
