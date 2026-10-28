#!/usr/bin/env python3
"""Measure real FFmpeg bitmap-subtitle acquisition on macOS."""
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
DEMUX = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
TIMELINE = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
BASELINE_BLOBS = {
    DEMUX: "5bd9337262dcdc2a583f1631bb1223c58ebcd2dc",
    TIMELINE: "cd3482a721c63fc9742195f91ce67ae37a0301b7",
}
SHARED = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/CFFmpeg/module.modulemap",
    "Sources/CFFmpeg/include/ffmpeg_shim.h",
]
SHAPES = [
    "tiny_end", "small_acquisition", "small_ordinary", "object_4k", "object_64k",
    "first_64k", "last_64k", "object_256k", "first_256k", "last_256k", "mixed_64k",
]
CASES = [f"{codec}_{shape}" for codec in ("pgs", "dvb") for shape in SHAPES]
VARIANTS = ("baseline", "candidate")
HELPER_MARKER = "// MARK: - Bitmap subtitle acquisition\n"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


class Runner:
    def __init__(self, args):
        if platform.system() != "Darwin":
            raise ValueError("Requires macOS and real FFmpeg; no substitute packet types are used")
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.swiftc = args.swiftc or shutil.which("swiftc") or "swiftc"
        self.prefix = args.ffmpeg_prefix.resolve()
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "hardware": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "sources": {}, "binaries": {},
            "mode": "native-ffmpeg-separate-production-module",
        }

    def command(self, argv, *, log: Path | None = None) -> str:
        argv = [str(item) for item in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - start,
                              "stdout_sha256": sha(result.stdout.encode()),
                              "stderr_sha256": sha(result.stderr.encode())})
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-4000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def source(self, path: str, variant: str) -> bytes:
        value = ((ROOT / path).read_bytes() if variant == "candidate" else
                 self.command(["git", "show", f"{BASELINE}:{path}"]).encode())
        self.receipt["sources"][f"{variant}:{path}"] = sha(value)
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(value)
        return value

    def prepare(self):
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        for path, blob in BASELINE_BLOBS.items():
            if self.command(["git", "rev-parse", f"{BASELINE}:{path}"]).strip() != blob:
                raise ValueError(f"Baseline Git blob mismatch: {path}")
        old_demux = self.source(DEMUX, "baseline").decode()
        new_demux = self.source(DEMUX, "candidate").decode()
        old_timeline = self.source(TIMELINE, "baseline")
        if self.source(TIMELINE, "candidate") != old_timeline:
            raise ValueError("Shared acquisition parsers changed; review/requalify this comparison")
        timeline = old_timeline.decode()
        start = timeline.index("enum PGSSubtitlePacket {")
        end = timeline.index("struct NativeBitmapSubtitleRegion: Sendable {")
        # Both complete, unchanged declarations; unrelated geometry is excluded.
        parsers = "import Foundation\n\n" + timeline[start:end]
        source_dir = self.output / "sources" / "compiled"
        source_dir.mkdir(parents=True)
        parser_path = source_dir / "BitmapSubtitleAcquisition.swift"
        parser_path.write_text(parsers)
        self.receipt["sources"]["extracted_complete_parsers"] = sha(parsers.encode())

        marker = "let acquisition = needsAcquisition && "
        if old_demux.count(marker) != 1:
            raise ValueError("Baseline acquisition call site is ambiguous")
        old_expression = old_demux.split(marker, 1)[1].split("if acquisition {", 1)[0].strip()
        if not old_expression.startswith("packet.data.map { data in") or not old_expression.endswith("} == true"):
            raise ValueError("Baseline is not the reviewed Data-copy call site")
        baseline_adapter = (
            "import CFFmpeg\nimport Foundation\n\nextension FFmpegPacket {\n"
            "    func isSubtitleAcquisition(isPGS: Bool, compositionPageID: UInt16?) -> Bool {\n"
            "        let packet = self\n        return " + old_expression + "\n    }\n}\n"
        )
        if new_demux.count(HELPER_MARKER) != 1:
            raise ValueError("Candidate helper marker is missing or ambiguous")
        candidate_adapter = "import CFFmpeg\nimport Foundation\n\n" + new_demux.split(HELPER_MARKER, 1)[1]
        if "extension FFmpegPacket {" not in candidate_adapter or "withExtendedLifetime(self)" not in candidate_adapter:
            raise ValueError("Candidate packet helper changed; review extraction")
        if "let acquisition = needsAcquisition && packet.isSubtitleAcquisition(" not in new_demux:
            raise ValueError("Production demuxer is not using the measured helper")

        files = {}
        for path in SHARED:
            old, new = self.source(path, "baseline"), self.source(path, "candidate")
            if old != new:
                raise ValueError(f"Shared dependency changed: {path}; review/requalify")
            files[path] = new
        module = source_dir / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        (module / "module.modulemap").write_bytes(files["Sources/CFFmpeg/module.modulemap"])
        (module / "include/ffmpeg_shim.h").write_bytes(files["Sources/CFFmpeg/include/ffmpeg_shim.h"])
        shared_paths = [parser_path]
        for path, value in files.items():
            if path.endswith(".swift"):
                destination = source_dir / Path(path).name
                destination.write_bytes(value)
                shared_paths.append(destination)
        driver = source_dir / "Driver.swift"
        driver.write_bytes((HERE / "Driver.swift").read_bytes())
        self.receipt["driver_sha256"] = sha(driver.read_bytes())
        self.receipt["runner_sha256"] = sha(Path(__file__).read_bytes())
        self.receipt["sdk_manifest_sha256"] = sha((ROOT / "BuildInputs/native-sdk.json").read_bytes())
        shutil.copyfile(__file__, self.output / "runner.snapshot.py")
        common = [
            "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
            "-I", str(module), "-Xcc", "-I" + str(self.prefix / "include"),
            "-L", str(self.prefix / "lib"), "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib"),
            "-module-cache-path", str(self.output / "module-cache"),
        ]
        self.receipt["flags"] = common
        for configuration in ("debug", "release"):
            optimization = ["-Onone", "-g"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
            for variant, adapter in (("baseline", baseline_adapter), ("candidate", candidate_adapter)):
                directory = self.output / "build" / configuration / variant
                directory.mkdir(parents=True)
                adapter_path = source_dir / f"{variant}-PacketAcquisition.swift"
                adapter_path.write_text(adapter)
                self.receipt["sources"][f"{variant}:compiled_adapter"] = sha(adapter.encode())
                library = directory / "libAcquisitionComponent.dylib"
                binary = directory / "benchmark"
                print(f"Building {configuration}/{variant} with real FFmpeg", flush=True)
                self.command([
                    self.swiftc, *common, *optimization, "-enable-testing",
                    "-emit-library", "-emit-module", "-module-name", "AcquisitionComponent",
                    "-emit-module-path", directory / "AcquisitionComponent.swiftmodule",
                    *shared_paths, adapter_path, "-o", library,
                ], log=self.output / "logs" / f"{configuration}-{variant}-module.log")
                self.command([
                    self.swiftc, *common, *optimization, "-I", directory, "-L", directory,
                    "-lAcquisitionComponent", "-Xlinker", "-rpath", "-Xlinker", directory,
                    driver, "-o", binary,
                ], log=self.output / "logs" / f"{configuration}-{variant}-driver.log")
                self.receipt["binaries"][f"{configuration}/{variant}"] = {
                    "module_sha256": sha(library.read_bytes()), "driver_sha256": sha(binary.read_bytes())
                }
        self.receipt["linked_dependencies"] = self.command([
            "otool", "-L", self.output / "build/release/candidate/libAcquisitionComponent.dylib"
        ])
        self.receipt["ffmpeg_libraries"] = {
            p.name: sha(p.read_bytes()) for p in sorted((self.prefix / "lib").glob("*.dylib"))
            if not p.is_symlink()
        }
        write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant, *args, configuration="release"):
        return json.loads(self.command([self.output / "build" / configuration / variant / "benchmark", *args]))

    def verify(self):
        reference = None
        summaries = []
        for configuration in ("debug", "release"):
            for variant in VARIANTS:
                trace = self.invoke(variant, "verify", configuration=configuration)
                write_json(self.output / f"{configuration}-{variant}-trace.json", trace)
                if reference is None:
                    reference = trace
                elif trace != reference:
                    raise ValueError(f"Complete acquisition decision parity failed: {configuration}/{variant}")
                summaries.append({"configuration": configuration, "variant": variant, "cases": len(trace["rows"])})
        rows = reference["rows"]
        summary = {
            "equal": True, "compared_cases": len(rows),
            "authored_expectations": sum(row["authoredExpectation"] for row in rows),
            "accepted": sum(row["result"] for row in rows),
            "configurations": summaries, "ffmpeg_version": reference["ffmpegVersion"],
        }
        write_json(self.output / "parity.json", summary)
        print(f"Debug/release decision parity: {len(rows)} cases per variant", flush=True)

    def calibrate(self, variant, case):
        # Every process runs complete cycles of exactly the same 16 packets.
        # Iteration counts can differ across variants to avoid multi-second slow
        # samples when copying large payloads is much slower than viewing their headers.
        iterations = 4_096
        pilots = []
        for _ in range(6):
            result = self.invoke(variant, "measure", case, str(iterations))
            pilots.append(result)
            measured = min(result["elapsedNanoseconds"], result["cpuNanoseconds"])
            if measured >= self.args.target_ms * 1_000_000:
                break
            requested = math.ceil(iterations * self.args.target_ms * 1_000_000 * 1.25 / max(1, measured))
            iterations = max(iterations + 16, math.ceil(requested / 16) * 16)
            if iterations > 100_000_000:
                raise ValueError("Calibration exceeds 100 million calls; inspect timer/optimizer")
        else:
            raise ValueError(f"Could not calibrate {variant}/{case}")
        return {"iterations": iterations, "pilots": pilots}

    def measure(self):
        summaries, calibration = [], {}
        minimum = self.args.minimum_ms * 1_000_000
        all_durations_met = True
        for case in self.args.cases:
            calibration[case] = {variant: self.calibrate(variant, case) for variant in VARIANTS}
            write_json(self.output / "calibration.json", calibration)
            pairs = []
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                values = {}
                for variant in order:
                    count = calibration[case][variant]["iterations"]
                    record = self.invoke(variant, "measure", case, str(count))
                    record.update({"variant": variant, "pair": pair, "order": list(order)})
                    values[variant] = record
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                for field in ("cycleChecksum", "warmupChecksum", "decisions", "payloadBytes"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise ValueError(f"Timed output mismatch in {case}/{pair}: {field}")
                pairs.append(values)
            summary = {"workload": case, "pairs": self.args.pairs,
                       "iterations": {v: calibration[case][v]["iterations"] for v in VARIANTS},
                       "payload_bytes": pairs[0]["baseline"]["payloadBytes"],
                       "minimum_required_ms": self.args.minimum_ms}
            under_minimum = []
            for metric, field in (("wall", "elapsedNanoseconds"), ("cpu", "cpuNanoseconds")):
                normalized = {v: [p[v][field] / p[v]["iterations"] for p in pairs] for v in VARIANTS}
                old, new = (statistics.median(normalized[v]) for v in VARIANTS)
                summary[metric] = {"baseline_ns_per_packet": old, "candidate_ns_per_packet": new,
                                   "change_percent": (new / old - 1) * 100,
                                   "paired_ratios": [p["candidate"][field] / p["candidate"]["iterations"]
                                                     / (p["baseline"][field] / p["baseline"]["iterations"])
                                                     for p in pairs],
                                   "minimum_observed_ms": {v: min(p[v][field] for p in pairs) / 1_000_000
                                                           for v in VARIANTS},
                                   "ranges_ns_per_packet": {v: [min(normalized[v]), max(normalized[v])]
                                                            for v in VARIANTS}}
                under_minimum.extend({"variant": v, "pair": p[v]["pair"], "metric": metric,
                                      "observed_ms": p[v][field] / 1_000_000}
                                     for p in pairs for v in VARIANTS if p[v][field] < minimum)
            summary["observations_under_minimum"] = under_minimum
            all_durations_met = all_durations_met and not under_minimum
            summaries.append(summary)
            write_json(self.output / "summary.json", summaries)
            wall = summary["wall"]
            print(f"{case}: {wall['baseline_ns_per_packet']:.1f} -> {wall['candidate_ns_per_packet']:.1f} ns/packet "
                  f"({wall['change_percent']:+.1f}% wall; {summary['cpu']['change_percent']:+.1f}% CPU)", flush=True)
        if not all_durations_met:
            raise ValueError("At least one measurement was under the required duration; increase --target-ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=180)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2:
        parser.error("Use an even number of at least six alternating process pairs")
    if args.minimum_ms < 60 or args.target_ms < args.minimum_ms:
        parser.error("Target must be at least the minimum, and minimum must be at least 60 ms")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        runner.verify()
        if not args.tests_only:
            runner.measure()
        write_json(runner.output / "completion.json", {"complete": True, "tests_only": args.tests_only,
                   "minimum_observation_duration_met": not args.tests_only,
                   "minimum_ms": args.minimum_ms, "pairs": args.pairs})
    finally:
        if runner:
            write_json(runner.output / "commands.json", runner.commands)
            write_json(runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()
