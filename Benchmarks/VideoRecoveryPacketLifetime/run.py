#!/usr/bin/env python3
"""Prove recovery-GOP payload lifetime with exact Swift owners and real FFmpeg.

This is an ownership experiment, not a decoder, player-RSS, or timing benchmark.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REVISION = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE = "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift"
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
SUPPORT = "Benchmarks/PlaybackPipeline/PacketProbeSupport.swift"
HELPERS = ("illiquid_averror_nomem", "illiquid_nopts_value",
           "illiquid_packet_is_corrupt", "illiquid_packet_is_keyframe")
CASES = {"4KiB-final-GOP": (4, 4_096), "1MiB-final-GOP": (16, 1_048_576),
         "32MiB-final-GOP": (512, 33_554_432)}
CONTROLS = {"decoder-error", "throwing-cancellation", "stale-generation-EOF",
            "seek-during-drain", "borrowed-native-packet", "fresh-GOP-after-seek"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def c_helper(text, name):
    pattern = r"(?m)^static inline [^\n]*\b" + re.escape(name) + r"\([^\n]*\) \{\n[^{}]*\n\}"
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        raise ValueError("Review changed C helper before staging: " + name)
    return matches[0] + "\n"


def validate(result, variant):
    if result["variant"] != variant or result["checks"] < 40:
        raise ValueError("Wrong or incomplete ownership probe")
    if {row["name"] for row in result["success"]} != set(CASES):
        raise ValueError("Missing success case")
    if {row["name"] for row in result["controls"]} != CONTROLS:
        raise ValueError("Missing lifetime control")
    if len(result["success"]) != len(CASES) or len(result["controls"]) != len(CONTROLS):
        raise ValueError("Duplicate observation")
    for row in result["success"]:
        count, payload = CASES[row["name"]]
        if row["packetCount"] != count or row["payloadBytes"] != payload:
            raise ValueError("Wrong fixture dimensions")
        if row["requestedStorageBytes"] <= payload:
            raise ValueError("Missing real FFmpeg input padding")
        expected = payload if variant == "baseline" else 0
        storage = row["requestedStorageBytes"] if variant == "baseline" else 0
        if (row["livePayloadBytesAfterDrain"] != expected
                or row["liveStorageBytesAfterDrain"] != storage
                or row["releaseCallbacksDuringDrain"] != 0
                or row["releaseCallbacksAfterReset"] != count
                or row["everyAllocationReleasedExactlyOnce"] is not True):
            raise ValueError("Unexpected native payload ownership: " + row["name"])
    if any(row["checks"] < 3 for row in result["controls"]):
        raise ValueError("Incomplete control")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg-prefix", required=True, type=Path,
                        help="Pinned SDK built by Benchmarks/DeinterlacerEOFMemory/build-linux-ffmpeg.sh")
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("This portable probe is qualified for Linux; run the native suite on macOS")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    swiftc = shutil.which(args.swiftc)
    if not swiftc:
        parser.error("Swift 6.1+ compiler unavailable; set PATH or --swiftc")
    sdk = args.ffmpeg_prefix.resolve()
    if not (sdk / "include/libavcodec/packet.h").is_file():
        parser.error("FFmpeg development headers missing; build the pinned SDK first")
    output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"
    sources = output / "sources"
    builds = output / "build"
    for directory in (logs, sources, builds):
        directory.mkdir()
    environment = os.environ.copy()
    environment["PKG_CONFIG_LIBDIR"] = str(sdk / "lib/pkgconfig")
    environment.pop("PKG_CONFIG_PATH", None)
    environment["SWIFT_MODULECACHE_PATH"] = str(builds / "module-cache")
    environment["CLANG_MODULE_CACHE_PATH"] = str(builds / "module-cache")
    commands = []
    manifest = {
        "schema_version": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "scope": "Synthetic drain boundary; exact production packet/recovery owner and real FFmpeg AVBuffer callbacks",
        "limitations": ["Does not execute MediaSession, decode video, or qualify macOS playback",
                        "Requested tracked native payload/storage bytes, not RSS or allocator overhead",
                        "Cancellation control throws CancellationError; silent early-return cancellation is not modeled"],
        "staged_sha256": {}, "binaries_sha256": {}, "complete": False,
    }

    def command(argv, name):
        argv = [str(value) for value in argv]
        process = subprocess.run(argv, cwd=ROOT, env=environment, capture_output=True, timeout=600)
        log = logs / (name + ".log")
        log.write_bytes(process.stdout + process.stderr)
        commands.append({"argv": argv, "returncode": process.returncode,
                         "log": str(log.relative_to(output)), "log_sha256": digest(log.read_bytes())})
        save(output / "commands.json", commands)
        if process.returncode:
            raise RuntimeError(f"{name} failed; see {log}\n" + log.read_text(errors="replace")[-8000:])
        return process.stdout.decode()

    def stage(relative, data):
        path = sources / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        manifest["staged_sha256"][str(path.relative_to(output))] = digest(data)
        return path

    try:
        pin = json.loads((HERE / "baseline/manifest.json").read_text())
        baseline = (HERE / "baseline/FFmpegPacket.swift").read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
        if (pin["revision"] != REVISION or pin["source"] != SOURCE
                or pin["git_blob"] != blob or pin["sha256"] != digest(baseline)):
            raise ValueError("Frozen baseline identity mismatch")
        candidate = (ROOT / SOURCE).read_bytes()
        method = b"func retireAfterSuccessfulDrain("
        if method in baseline or candidate.count(method) != 1:
            raise ValueError("Expected old and new EOF retirement boundaries are missing")
        manifest["baseline"] = pin
        manifest["compiler"] = command([swiftc, "--version"], "compiler").strip()
        manifest["checkout_head"] = command(["git", "rev-parse", "HEAD"], "git-head").strip()
        manifest["worktree_status"] = command(["git", "status", "--porcelain=v1"], "git-status")
        manifest["candidate_source_sha256"] = digest(candidate)
        manifest["harness_sha256"] = {
            name: digest((HERE / name).read_bytes()) for name in ("run.py", "Probe.swift", "baseline/manifest.json")
        }
        packages = ["libavcodec", "libavutil"]
        versions = command(["pkg-config", "--modversion", *packages], "sdk-versions").splitlines()
        if versions != ["62.28.102", "60.26.102"]:
            raise ValueError("Use the repository's pinned FFmpeg 8.1.2 SDK")
        ccflags = shlex.split(command(["pkg-config", "--cflags", *packages], "sdk-cflags"))
        ldflags = shlex.split(command(["pkg-config", "--static", "--libs", *packages], "sdk-libs"))
        manifest["sdk"] = {"prefix": str(sdk), "packages": dict(zip(packages, versions)),
                           "libraries_sha256": {name: digest((sdk / "lib" / name).read_bytes())
                                                for name in ("libavcodec.a", "libavutil.a")}}
        for name in ("source-receipt.json", "build-receipt.json"):
            if not (sdk / name).is_file():
                raise ValueError("Missing pinned SDK provenance: " + name)
            manifest["sdk"][name] = json.loads((sdk / name).read_text())

        header = """#include <libavcodec/avcodec.h>
#include <libavcodec/packet.h>
#include <libavutil/avutil.h>
#include <libavutil/buffer.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <errno.h>

static inline unsigned probe_avcodec_header_version(void) { return LIBAVCODEC_VERSION_INT; }
static inline unsigned probe_avutil_header_version(void) { return LIBAVUTIL_VERSION_INT; }
"""
        shim = (ROOT / SHIM).read_bytes()
        for name in HELPERS:
            header += "\n" + c_helper(shim.decode(), name)
        stage("CFFmpeg/packet_api.h", header.encode())
        stage("CFFmpeg/module.modulemap", b'module CFFmpeg [system] { header "packet_api.h" export * }\n')
        support = stage("shared/PacketProbeSupport.swift", (ROOT / SUPPORT).read_bytes())
        driver = stage("shared/Probe.swift", (HERE / "Probe.swift").read_bytes())
        stage("originals/ffmpeg_shim.h", shim)
        staged = {
            "baseline": stage("baseline/FFmpegPacket.swift", baseline),
            "candidate": stage("candidate/FFmpegPacket.swift", candidate),
        }
        save(output / "manifest.json", manifest)
        records = {}
        for configuration, optimization in (("debug", "-Onone"), ("release", "-O")):
            for variant in ("baseline", "candidate"):
                binary = builds / f"{variant}-{configuration}"
                argv = [swiftc, optimization, "-swift-version", "6", "-warnings-as-errors",
                        "-parse-as-library", "-module-cache-path", builds / "module-cache",
                        "-I", sources / "CFFmpeg"]
                if variant == "baseline":
                    argv += ["-D", "BASELINE"]
                for flag in ccflags:
                    argv += ["-Xcc", flag]
                argv += [support, staged[variant], driver]
                for flag in ldflags:
                    argv += ["-Xlinker", "-lpthread" if flag == "-pthread" else flag]
                argv += ["-o", binary]
                print(f"Build and run {variant} {configuration}", flush=True)
                command(argv, f"build-{variant}-{configuration}")
                manifest["binaries_sha256"][binary.name] = digest(binary.read_bytes())
                save(output / "manifest.json", manifest)
                result = json.loads(command([binary], f"run-{variant}-{configuration}"))
                validate(result, variant)
                records[variant, configuration] = result
                save(output / f"{variant}-{configuration}.json", result)

        for variant in ("baseline", "candidate"):
            if records[variant, "debug"] != records[variant, "release"]:
                raise ValueError("Debug/release ownership observations differ")
        before, after = records["baseline", "release"], records["candidate", "release"]
        if before["controls"] != after["controls"]:
            raise ValueError("Lifecycle control coverage differs")
        for name in ("ffmpegVersion", "avcodecVersion", "avutilVersion"):
            if before[name] != after[name]:
                raise ValueError("Native libraries differ between variants")
        if digest((ROOT / SOURCE).read_bytes()) != manifest["candidate_source_sha256"]:
            raise ValueError("Production source changed during validation")
        summary = {
            "status": "passed", "scope": manifest["scope"], "timing_claim": None,
            "configurations": ["debug", "release"], "controls": sorted(CONTROLS),
            "success_cases": [
                {"name": left["name"], "payload_bytes": left["payloadBytes"],
                 "baseline_live_payload_bytes_after_drain": left["livePayloadBytesAfterDrain"],
                 "candidate_live_payload_bytes_after_drain": right["livePayloadBytesAfterDrain"],
                 "baseline_live_storage_bytes_after_drain": left["liveStorageBytesAfterDrain"],
                 "candidate_live_storage_bytes_after_drain": right["liveStorageBytesAfterDrain"]}
                for left, right in zip(before["success"], after["success"])
            ],
            "all_tracked_allocations_released_exactly_once": True,
            "limitations": manifest["limitations"],
        }
        save(output / "summary.json", summary)
        manifest["complete"] = True
        print(json.dumps(summary, indent=2, sort_keys=True))
    finally:
        save(output / "manifest.json", manifest)


if __name__ == "__main__":
    main()
