#!/usr/bin/env python3
"""Qualify PGS packet borrowing with complete production sources and real FFmpeg.

Run on macOS after installing the repository's pinned native SDK. No dependency
download, platform stub or source rewrite is performed by this runner.
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
PARSER = "Sources/IlliquidNativePlayback/Subtitles/PGSSubtitlePresentation.swift"
DECODER = "Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift"
SHARED = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/CFFmpeg/module.modulemap",
    "Sources/CFFmpeg/include/ffmpeg_shim.h",
]
CASES = ["tiny_end", "composition_one", "composition_two_cropped", "object_4k",
         "object_64k", "composition_object_64k", "multisegment_256k",
         "composition_multisegment_256k"]
VARIANTS = ("baseline", "candidate")
REGRESSION_TARGET = "c1ef6aff6060ad35decbc6dce0c224164be941a2"
CURRENT_SUPPORT = "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


class Runner:
    def __init__(self, args):
        if platform.system() != "Darwin":
            raise ValueError("Native macOS is required; no portable substitutes are used")
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
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "hardware": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "sources": {}, "binaries": {}, "mode": "native-exact-production-sources",
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
        return value

    def prepare(self):
        self.receipt["mode"] = ("current-support-regression-no-timing"
            if self.args.current_support_regression else "native-exact-production-sources")
        if self.args.current_support_regression:
            self.receipt["target_oracle_revision"] = REGRESSION_TARGET
            for path in (PARSER, DECODER):
                pinned = subprocess.check_output(["git", "show", f"{REGRESSION_TARGET}:{path}"], cwd=ROOT)
                if (ROOT / path).read_bytes() != pinned:
                    raise ValueError(f"Pinned regression target changed: {path}")
        manifest = json.loads((HERE / "baseline/manifest.json").read_text())
        if manifest["revision"] != BASELINE:
            raise ValueError("Frozen baseline revision changed; review the experiment")
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        frozen = (HERE / "baseline/PGSSubtitlePresentation.swift").read_bytes()
        baseline = self.source(PARSER, "baseline")
        if baseline != frozen or sha(baseline) != manifest["sha256"][PARSER]:
            raise ValueError("Frozen parser does not match the pinned baseline")
        candidate = self.source(PARSER, "candidate")
        if b"static func update(in packet: FFmpegPacket)" not in candidate:
            raise ValueError("Candidate packet overload is missing")
        old_call = self.source(DECODER, "baseline")
        new_call = self.source(DECODER, "candidate")
        if b"let data = packet.data" not in old_call or b"PGSSubtitlePresentation.update(in: data)" not in old_call:
            raise ValueError("Baseline decoder call site differs from the benchmark adapter")
        if b"PGSSubtitlePresentation.update(in: packet)" not in new_call:
            raise ValueError("Candidate decoder is not using the packet overload")
        files = {}
        for path in SHARED:
            old, new = self.source(path, "baseline"), self.source(path, "candidate")
            if self.args.current_support_regression and path == CURRENT_SUPPORT:
                if sha(old) != manifest["sha256"][path]:
                    raise ValueError("Frozen packet support does not match its manifest")
                self.receipt["support_override"] = {
                    "path": path, "historical_sha256": sha(old), "both_arms_sha256": sha(new)}
                files[path] = new
                continue
            if old != new or sha(old) != manifest["sha256"][path]:
                raise ValueError(f"Shared dependency changed: {path}; review/requalify this comparison")
            files[path] = new
        module = self.output / "sources/CFFmpeg"
        (module / "include").mkdir(parents=True)
        (module / "module.modulemap").write_bytes(files["Sources/CFFmpeg/module.modulemap"])
        (module / "include/ffmpeg_shim.h").write_bytes(files["Sources/CFFmpeg/include/ffmpeg_shim.h"])
        shared_paths = []
        for path, value in files.items():
            if not path.endswith(".swift"):
                continue
            destination = self.output / "sources/shared" / Path(path).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(value)
            shared_paths.append(destination)
        driver = self.output / "sources/Driver.swift"
        driver.write_bytes((HERE / "Driver.swift").read_bytes())
        self.receipt["driver_sha256"] = sha(driver.read_bytes())
        self.receipt["runner_sha256"] = sha(Path(__file__).read_bytes())
        self.receipt["frozen_manifest_sha256"] = sha((HERE / "baseline/manifest.json").read_bytes())
        self.receipt["sdk_manifest_sha256"] = sha((ROOT / "BuildInputs/native-sdk.json").read_bytes())
        shutil.copyfile(__file__, self.output / "runner.snapshot.py")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-I", str(module), "-Xcc", "-I" + str(self.prefix / "include"),
                 "-L", str(self.prefix / "lib"), "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib"),
                 "-module-cache-path", str(self.output / "module-cache")]
        self.receipt["flags"] = flags
        for variant, parser in (("baseline", baseline), ("candidate", candidate)):
            directory = self.output / variant
            directory.mkdir()
            parser_path = directory / "PGSSubtitlePresentation.swift"
            parser_path.write_bytes(parser)
            binary = directory / "benchmark"
            conditional = ["-D", "BASELINE"] if variant == "baseline" else []
            print(f"Building {variant} against native FFmpeg", flush=True)
            self.command([self.swiftc, *flags, *conditional, *shared_paths, parser_path, driver,
                          "-o", binary], log=directory / "compile.log")
            self.receipt["binaries"][variant] = sha(binary.read_bytes())
        self.receipt["linked_dependencies"] = self.command(["otool", "-L", self.output / "candidate/benchmark"])
        self.receipt["ffmpeg_libraries"] = {
            p.name: sha(p.read_bytes()) for p in sorted((self.prefix / "lib").glob("*.dylib"))
            if not p.is_symlink()
        }
        write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant, *args):
        return json.loads(self.command([self.output / variant / "benchmark", *args]))

    def verify(self):
        traces = {}
        for variant in VARIANTS:
            trace = self.invoke(variant, "verify")
            write_json(self.output / f"{variant}-trace.json", trace)
            traces[variant] = trace
        if traces["baseline"] != traces["candidate"]:
            raise ValueError("Complete object/crop/error parity failed; inspect the saved traces")
        rows = traces["candidate"]["rows"]
        summary = {"equal": True, "compared_cases": len(rows),
                   "authored_expectations": sum(row["authoredExpectation"] for row in rows),
                   "statuses": {status: sum(row["result"]["status"] == status for row in rows)
                                for status in ("composition", "none", "error")},
                   "ffmpeg_version": traces["candidate"]["ffmpegVersion"]}
        write_json(self.output / "parity.json", summary)
        print(f"Complete output and error parity: {len(rows)} cases", flush=True)

    def calibrate(self, variant, case):
        # Every process runs complete cycles of exactly the same 16 packets.
        # Iteration counts can differ across variants to avoid multi-second slow
        # samples when the borrowed no-composition path is hundreds of times faster.
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
                for field in ("cycleChecksum", "warmupChecksum", "first", "last", "payloadBytes"):
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
    parser.add_argument("--current-support-regression", action="store_true",
                        help="Pinned-target regression with identical current packet support; no timing qualification")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=240)
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
        if not args.tests_only and not args.current_support_regression:
            runner.measure()
        write_json(runner.output / "completion.json", {"complete": True, "tests_only": args.tests_only,
                   "comparison_mode": runner.receipt["mode"],
                   "minimum_observation_duration_met": not args.tests_only and not args.current_support_regression,
                   "minimum_ms": args.minimum_ms, "pairs": args.pairs})
    finally:
        if runner:
            write_json(runner.output / "commands.json", runner.commands)
            write_json(runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()
