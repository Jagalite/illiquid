#!/usr/bin/env python3
"""Compare bitmap subtitle acquisition classifiers using exact Swift source slices.

Requires macOS and the repository's pinned FFmpeg SDK. Does not install tools,
rewrite parser statements, or replace production dependencies with stubs.
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
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PARSER = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
SHARED = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/CFFmpeg/module.modulemap",
    "Sources/CFFmpeg/include/ffmpeg_shim.h",
]
CASES = ["pgs_tiny", "dvb_tiny", "pgs_mixed_4k", "dvb_mixed_4k",
         "pgs_mixed_64k", "dvb_mixed_64k", "pgs_mixed_256k", "dvb_mixed_256k"]
VARIANTS = ("baseline", "candidate")
BOUNDARIES = {
    PARSER: (b"\nstruct NativeBitmapSubtitleRegion:", "BitmapSubtitleClassifiers.swift"),
    DEMUXER: (b"\nfinal class FFmpegDemuxer {", "NativePacketClassifiers.swift"),
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def prefix(source: bytes, path: str) -> bytes:
    boundary, _ = BOUNDARIES[path]
    if source.count(boundary) != 1:
        raise ValueError(f"Extraction boundary changed in {path}; review the harness")
    result = source[:source.index(boundary)]
    expected = ([b"enum PGSSubtitlePacket {", b"enum DVBSubtitlePacket {"]
                if path == PARSER else [b"import CFFmpeg", b"struct FFmpegDemuxReadRetryPolicy {"])
    if any(result.count(marker) != 1 for marker in expected):
        raise ValueError(f"Expected production declarations changed in {path}")
    return result


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
        self.sdk = args.ffmpeg_prefix.resolve()
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree_status": self.command(["git", "status", "--porcelain"]),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "hardware": self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "mode": "native-exact-production-classifier-prefixes",
            "sources": {}, "extractions": {}, "binaries": {},
        }

    def command(self, argv, *, log: Path | None = None) -> str:
        argv = [str(value) for value in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.commands.append({
            "argv": argv, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - start,
            "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
        })
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-4000:].decode(errors='replace')}\n"
                               f"{result.stderr[-8000:].decode(errors='replace')}")
        return result.stdout.decode()

    def source(self, path: str, variant: str) -> bytes:
        data = ((ROOT / path).read_bytes() if variant == "candidate"
                else self.command(["git", "show", f"{BASELINE}:{path}"]).encode())
        self.receipt["sources"][f"{variant}:{path}"] = sha(data)
        return data

    def prepare(self):
        manifest_path = HERE / "baseline/manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if manifest["revision"] != BASELINE:
            raise ValueError("Frozen baseline revision changed; review the comparison")
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        files = {v: {} for v in VARIANTS}
        for path in [PARSER, DEMUXER, *SHARED]:
            old, new = self.source(path, "baseline"), self.source(path, "candidate")
            if sha(old) != manifest["sha256"][path]:
                raise ValueError(f"Baseline source does not match its manifest: {path}")
            if path in SHARED and old != new:
                raise ValueError(f"Shared dependency changed: {path}; requalify the experiment")
            files["baseline"][path], files["candidate"][path] = old, new
        old_call = b"let acquisition = needsAcquisition && packet.data.map"
        if old_call not in files["baseline"][DEMUXER]:
            raise ValueError("Baseline call site no longer matches the copying adapter")
        new_call = files["candidate"][DEMUXER]
        if (old_call in new_call or b"PGSSubtitlePacket.isAcquisition(packet)" not in new_call
                or b"DVBSubtitlePacket.isAcquisition(packet, compositionPageID:" not in new_call):
            raise ValueError("Candidate demuxer is not using the packet overloads")

        source_root = self.output / "sources"
        module = source_root / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for path in SHARED:
            if path.startswith("Sources/CFFmpeg/"):
                destination = source_root / path.removeprefix("Sources/")
                destination.write_bytes(files["candidate"][path])
        shared_paths = []
        for path in SHARED:
            if path.endswith(".swift"):
                destination = source_root / "shared" / Path(path).name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(files["candidate"][path])
                shared_paths.append(destination)
        driver = source_root / "Driver.swift"
        driver.write_bytes((HERE / "Driver.swift").read_bytes())
        self.receipt["driver_sha256"] = sha(driver.read_bytes())
        self.receipt["runner_sha256"] = sha(Path(__file__).read_bytes())
        self.receipt["frozen_manifest_sha256"] = sha(manifest_path.read_bytes())
        self.receipt["sdk_manifest_sha256"] = sha((ROOT / "BuildInputs/native-sdk.json").read_bytes())
        shutil.copyfile(__file__, self.output / "runner.snapshot.py")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-I", str(module), "-Xcc", "-I" + str(self.sdk / "include"),
                 "-L", str(self.sdk / "lib"), "-Xlinker", "-rpath", "-Xlinker", str(self.sdk / "lib"),
                 "-module-cache-path", str(self.output / "module-cache")]
        self.receipt["flags"] = flags
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            extracted_paths = []
            for path in BOUNDARIES:
                data = prefix(files[variant][path], path)
                boundary, name = BOUNDARIES[path]
                if variant == "baseline":
                    if (data != (HERE / "baseline" / name).read_bytes()
                            or sha(data) != manifest["prefix_sha256"][path]):
                        raise ValueError(f"Frozen baseline prefix changed: {path}")
                elif path == DEMUXER:
                    for marker in [b"extension PGSSubtitlePacket {", b"extension DVBSubtitlePacket {"]:
                        if data.count(marker) != 1:
                            raise ValueError("Candidate packet overload extraction is incomplete")
                self.receipt["extractions"][f"{variant}:{path}"] = {
                    "start_byte": 0, "end_byte_exclusive": len(data),
                    "next_declaration": boundary.decode().strip(), "sha256": sha(data),
                }
                destination = directory / name
                destination.write_bytes(data)
                extracted_paths.append(destination)
            binary = directory / "benchmark"
            conditional = ["-D", "BASELINE"] if variant == "baseline" else []
            print(f"Building {variant} exact classifier prefixes against native FFmpeg", flush=True)
            self.command([self.swiftc, *flags, *conditional, *shared_paths, *extracted_paths, driver,
                          "-o", binary], log=directory / "compile.log")
            self.receipt["binaries"][variant] = sha(binary.read_bytes())
        self.receipt["linked_dependencies"] = self.command(["otool", "-L", self.output / "candidate/benchmark"])
        self.receipt["ffmpeg_libraries"] = {
            path.name: sha(path.read_bytes())
            for path in sorted((self.sdk / "lib").glob("*.dylib")) if not path.is_symlink()
        }
        write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant, *args):
        return json.loads(self.command([self.output / variant / "benchmark", *args]))

    def verify(self):
        traces = {}
        for variant in VARIANTS:
            traces[variant] = self.invoke(variant, "verify")
            write_json(self.output / f"{variant}-trace.json", traces[variant])
        if traces["baseline"] != traces["candidate"]:
            raise ValueError("Frozen-baseline classifier parity failed; inspect saved traces")
        rows = traces["candidate"]["rows"]
        summary = {
            "equal": True, "compared_cases": len(rows),
            "authored_expectations": sum(row["authoredExpectation"] for row in rows),
            "acquisition_true": sum(row["result"] for row in rows),
            "acquisition_false": sum(not row["result"] for row in rows),
            "ffmpeg_version": traces["candidate"]["ffmpegVersion"],
        }
        write_json(self.output / "parity.json", summary)
        print(f"Frozen-baseline Boolean parity: {len(rows)} cases", flush=True)

    def calibrate(self, variant, case):
        iterations, pilots = 4_096, []
        for _ in range(6):
            result = self.invoke(variant, "measure", case, str(iterations))
            pilots.append(result)
            measured = min(result["elapsedNanoseconds"], result["cpuNanoseconds"])
            if measured >= self.args.target_ms * 1_000_000:
                return {"iterations": iterations, "pilots": pilots}
            requested = math.ceil(iterations * self.args.target_ms * 1_000_000 * 1.25 / max(1, measured))
            iterations = max(iterations + 16, math.ceil(requested / 16) * 16)
            if iterations > 100_000_000:
                raise ValueError("Calibration exceeds 100 million calls; inspect timer/optimizer")
        raise ValueError(f"Could not calibrate {variant}/{case}")

    def measure(self):
        summaries, calibration = [], {}
        minimum = self.args.minimum_ms * 1_000_000
        duration_failures = False
        for case in self.args.cases:
            calibration[case] = {v: self.calibrate(v, case) for v in VARIANTS}
            write_json(self.output / "calibration.json", calibration)
            pairs = []
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                values = {}
                for variant in order:
                    iterations = calibration[case][variant]["iterations"]
                    record = self.invoke(variant, "measure", case, str(iterations))
                    if record["iterations"] != iterations or record["workload"] != case:
                        raise ValueError("Timed process returned different workload/iterations")
                    record.update({"variant": variant, "pair": pair, "order": list(order)})
                    values[variant] = record
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                for field in ("cycleChecksum", "warmupChecksum", "warmupIterations", "first", "last", "payloadBytes"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise ValueError(f"Timed output mismatch in {case}/{pair}: {field}")
                pairs.append(values)
            summary = {
                "workload": case, "pairs": self.args.pairs,
                "iterations": {v: calibration[case][v]["iterations"] for v in VARIANTS},
                "payload_bytes": pairs[0]["baseline"]["payloadBytes"],
                "minimum_required_ms": self.args.minimum_ms,
            }
            too_short = []
            for metric, field in (("wall", "elapsedNanoseconds"), ("cpu", "cpuNanoseconds")):
                normalized = {v: [p[v][field] / p[v]["iterations"] for p in pairs] for v in VARIANTS}
                old, new = (statistics.median(normalized[v]) for v in VARIANTS)
                ratios = [p["candidate"][field] / p["candidate"]["iterations"]
                          / (p["baseline"][field] / p["baseline"]["iterations"]) for p in pairs]
                summary[metric] = {
                    "baseline_ns_per_packet": old, "candidate_ns_per_packet": new,
                    "change_percent": (new / old - 1) * 100,
                    "paired_ratios": ratios, "median_paired_ratio": statistics.median(ratios),
                    "ranges_ns_per_packet": {v: [min(normalized[v]), max(normalized[v])] for v in VARIANTS},
                    "minimum_observed_ms": {v: min(p[v][field] for p in pairs) / 1_000_000 for v in VARIANTS},
                }
                too_short.extend({"variant": v, "pair": p[v]["pair"], "metric": metric,
                                  "observed_ms": p[v][field] / 1_000_000}
                                 for p in pairs for v in VARIANTS if p[v][field] < minimum)
            summary["observations_under_minimum"] = too_short
            duration_failures |= bool(too_short)
            summaries.append(summary)
            write_json(self.output / "summary.json", summaries)
            wall = summary["wall"]
            print(f"{case}: {wall['baseline_ns_per_packet']:.1f} -> {wall['candidate_ns_per_packet']:.1f} ns/packet"
                  f" ({wall['change_percent']:+.1f}% wall; {summary['cpu']['change_percent']:+.1f}% CPU)", flush=True)
        if duration_failures:
            raise ValueError("At least one observation was too short; retain the cohort and raise --target-ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=240)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2:
        parser.error("Use an even number of at least six balanced process pairs")
    if args.minimum_ms < 60 or args.target_ms < args.minimum_ms:
        parser.error("Target must be at least the minimum, and minimum must be at least 60 ms")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        runner.verify()
        if not args.tests_only:
            runner.measure()
        write_json(runner.output / "completion.json", {
            "complete": True, "tests_only": args.tests_only,
            "minimum_observation_duration_met": not args.tests_only,
            "minimum_ms": args.minimum_ms, "pairs": args.pairs,
        })
    finally:
        if runner:
            write_json(runner.output / "commands.json", runner.commands)
            write_json(runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()

