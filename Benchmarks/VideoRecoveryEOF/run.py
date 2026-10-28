#!/usr/bin/env python3
"""Measure final-GOP ownership with actual FFmpegPacket and native AVBuffers.

Requires Swift 6, Python 3, pkg-config, and libavcodec/libavutil development
libraries. Linux can use the distribution's FFmpeg; native qualification uses
the project's selected macOS SDK. No packet, buffer, or allocation API is mocked.
This is a retained-requested-storage study, not an RSS or latency benchmark.
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
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
MEDIA = "Sources/IlliquidNativePlayback/Media/"
PATHS = {"packet": MEDIA + "FFmpegPacket.swift", "error": MEDIA + "FFmpegError.swift",
         "time": MEDIA + "MediaTime.swift", "session": MEDIA + "MediaSession.swift",
         "queue": "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
         "shim": "Sources/CFFmpeg/include/ffmpeg_shim.h"}
HELPERS = ["illiquid_averror_eagain", "illiquid_averror_nomem",
           "illiquid_averror_invaliddata", "illiquid_averror_exit",
           "illiquid_packet_is_corrupt", "illiquid_packet_is_keyframe", "illiquid_nopts_value"]
PACKAGES = ["libavcodec", "libavutil"]
CONFIGURATIONS = {"debug": "-Onone", "release": "-O"}
GOPS = {"empty": 0, "single_64k": 1, "gop_120": 120, "limit_512": 512, "replaced_gop": 5}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, marker: str) -> str:
    """Extract one unchanged, brace-balanced declaration; fail on ambiguity."""
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


def eof_action(session: str, variant: str) -> tuple[str, str]:
    """Expose only the production post-drain action, with its exact provenance.

    The driver supplies a successful-drain boundary; it does not decode video.
    The separate native MediaSession test verifies the real decoder/EOF wiring.
    """
    loop = declaration(session, "private func videoDecodeLoop()")
    start = loop.index("case let .endOfStream(active):")
    end = loop.index("case let .flush(active):", start)
    case = loop[start:end]
    if case.count("try videoDecoder.drain(") != 1:
        raise ValueError("Cannot identify the video EOF drain")
    marker = "self.recordVideoDecodeDiagnostics(videoDecoder)\n"
    if case.count(marker) != 1:
        raise ValueError("Cannot identify the end of the drain emitter")
    tail = case[case.index(marker) + len(marker):]
    closing, tail = tail.split("\n", 1)
    if closing.strip() != "}":
        raise ValueError("Drain emitter boundary changed")
    boundary = "                        _ = videoFrames.push(.endOfStream(generation: active))"
    if tail.count(boundary) != 1:
        raise ValueError("Cannot identify the video EOF publication boundary")
    action = tail[:tail.index(boundary)]
    statements = [line.strip() for line in action.splitlines()
                  if line.strip() and not line.lstrip().startswith("//")]
    expected = [] if variant == "baseline" else [
        "videoRecoveryPackets.releaseAfterDrain(generation: active)"]
    if statements != expected:
        raise ValueError(f"Unexpected {variant} EOF action: {statements}")
    return action, case


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def validate(report: dict, variant: str) -> None:
    cases = {case["name"]: case for case in report["cases"]}
    require(set(cases) == set(GOPS) | {"external_clone", "stale_generation", "pre_eof_recovery"},
            "Case coverage changed")
    padding = report["inputPaddingBytes"]
    require(padding > 0, "FFmpeg padding must be positive")
    for case in cases.values():
        for phase, value in case["snapshots"].items():
            prefix = f"{variant}/{case['name']}/{phase}"
            require(value["invalidReleaseCounts"] == 0, prefix + ": allocation freed multiple times")
            require(value["allocatedBuffers"] == value["releasedBuffers"] + value["liveBuffers"],
                    prefix + ": allocation accounting")
            require(value["liveRequestedStorageBytes"] == value["livePayloadBytes"] + padding * value["liveBuffers"],
                    prefix + ": storage accounting")

    def live(case, phase, count, payload, owners=None):
        value = cases[case]["snapshots"][phase]
        require((value["liveBuffers"], value["livePayloadBytes"], value["livePacketWrappers"])
                == (count, payload, count if owners is None else owners),
                f"Unexpected ownership: {variant}/{case}/{phase}: {value}")

    for name, count in GOPS.items():
        live(name, "recorded", count, count * 65_536)
        allocated = count + (3 if name == "replaced_gop" else 0)
        require(cases[name]["snapshots"]["recorded"]["allocatedBuffers"] == allocated,
                f"Unexpected allocation count: {name}")
        retained = count if variant == "baseline" else 0
        live(name, "afterEOF", retained, retained * 65_536)
        live(name, "afterRepeatedEOF", retained, retained * 65_536)
        live(name, "afterReset", 0, 0)
    live("external_clone", "recorded", 1, 65_536)
    retained = 1 if variant == "baseline" else 0
    live("external_clone", "afterEOF", 1, 65_536, owners=retained)
    live("external_clone", "afterCloneRelease", retained, retained * 65_536)
    live("external_clone", "afterReset", 0, 0)
    clone = cases["external_clone"]
    require(clone["cloneChecksumBeforeEOF"] == clone["cloneChecksumAfterEOF"],
            "Independently owned clone changed at EOF")
    for name, count, size, generation in [("stale_generation", 4, 65_536, 8),
                                           ("pre_eof_recovery", 8, 4_096, 7)]:
        for phase in cases[name]["snapshots"]:
            released = phase == "afterReplayRelease"
            live(name, phase, 0 if released else count, 0 if released else count * size)
        replay = cases[name]["replay"]
        require(len(replay) == count, f"Replay count changed: {name}")
        for index, packet in enumerate(replay):
            require((packet["pts"], packet["dts"], packet["duration"], packet["generation"],
                     packet["bytes"], packet["keyframe"])
                    == (index * 40, index * 40, 40, generation, size, index == 0),
                    f"Replay properties changed: {name}/{index}")


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.environment = os.environ.copy()
        self.swiftc = args.swiftc or shutil.which("swiftc") or "swiftc"
        self.commands = []
        self.receipt = {
            "schemaVersion": 1, "startedUTC": datetime.now(timezone.utc).isoformat(),
            "baselineRevision": BASELINE, "complete": False,
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(), "pairs": args.pairs,
            "scope": "Live requested AVBuffer payload plus padding; excludes allocator overhead, packet headers, side data, RSS, decoder/render pools, and total player memory.",
            "adaptation": "Compile whole production FFmpegPacket/FFmpegError; extract unchanged portable support and C helpers. Expose the exact post-drain/pre-EOF action from MediaSession. The driver models successful drain, not decoding.",
            "environment": {key: self.environment.get(key) for key in (
                "DEVELOPER_DIR", "PKG_CONFIG_PATH", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH",
                "ImageOS", "ImageVersion")},
            "sourceHashes": {}, "stagedHashes": {}, "binaryHashes": {}, "observations": [],
            "harnessHashes": {name: sha((HERE / name).read_bytes()) for name in ("Driver.swift", "run.py")},
        }

    def persist(self):
        save(self.output / "receipt.json", self.receipt)
        save(self.output / "commands.json", self.commands)

    def command(self, argv, name):
        argv = list(map(str, argv))
        result = subprocess.run(argv, cwd=ROOT, env=self.environment,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        log = self.output / "logs" / (name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_bytes(result.stdout)
        self.commands.append({"argv": argv, "cwd": str(ROOT), "returncode": result.returncode,
                              "log": str(log.relative_to(self.output)), "logSHA256": sha(result.stdout)})
        self.persist()
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n"
                               + result.stdout.decode(errors="replace")[-8_000:])
        return result.stdout

    def stage(self, name, content):
        data = content.encode() if isinstance(content, str) else content
        path = self.output / "sources" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.receipt["stagedHashes"][str(path.relative_to(self.output))] = sha(data)
        return path

    def sources(self, variant):
        source = {}
        for name, path in PATHS.items():
            data = (self.command(["git", "show", f"{BASELINE}:{path}"], f"source-{variant}-{name}")
                    if variant == "baseline" else (ROOT / path).read_bytes())
            source[name] = data.decode()
            self.receipt["sourceHashes"][f"{variant}/{path}"] = sha(data)
        compiled = [self.stage(f"{variant}/{name}.swift", source[name]) for name in ("packet", "error")]
        support = "import Foundation\nimport CFFmpeg\n" + declaration(source["time"], "struct FFmpegRational:")
        support += "enum MediaTime {\n" + declaration(source["time"], "static func seconds(") + "}\n"
        support += declaration(source["queue"], "struct BoundedQueueCost:")
        compiled.append(self.stage(f"{variant}/Support.swift", support))
        helpers = "#include <errno.h>\n#include <libavcodec/avcodec.h>\n#include <libavutil/avutil.h>\n#include <libavutil/buffer.h>\n#include <libavutil/error.h>\n#include <libavutil/mem.h>\n"
        for name in HELPERS:
            match = re.search(r"(?m)^static inline [^\n]*\b" + re.escape(name) + r"\(", source["shim"])
            if match is None:
                raise ValueError(f"Missing C helper: {name}")
            helpers += declaration(source["shim"], match.group())
        self.stage(f"{variant}/CFFmpeg/shim.h", helpers)
        self.stage(f"{variant}/CFFmpeg/module.modulemap", 'module CFFmpeg [system] {\n header "shim.h"\n export *\n}\n')
        action, original_case = eof_action(source["session"], variant)
        self.stage(f"{variant}/EOFCase.swift.txt", original_case)
        self.stage(f"{variant}/EOFAction.swift.txt", action)
        wrapper = "@inline(never)\nfunc completeSuccessfulDrain(_ videoRecoveryPackets: VideoRecoveryPacketBuffer, active: Int) {\n" + action + "}\n"
        compiled.append(self.stage(f"{variant}/EOFAction.swift", wrapper))
        return compiled

    def run(self):
        require(platform.system() in ("Linux", "Darwin"), "Only Linux and macOS are supported")
        self.receipt["candidateRevision"] = self.command(["git", "rev-parse", "HEAD"], "candidate-revision").decode().strip()
        self.receipt["candidateWorktreeStatus"] = self.command(["git", "status", "--porcelain"], "candidate-status").decode()
        self.receipt["compiler"] = self.command([self.swiftc, "--version"], "swift-version").decode().strip()
        versions = self.command(["pkg-config", "--modversion", *PACKAGES], "sdk-versions").decode().splitlines()
        self.receipt["sdkVersions"] = dict(zip(PACKAGES, versions))
        cflags = shlex.split(self.command(["pkg-config", "--cflags", *PACKAGES], "sdk-cflags").decode())
        links = shlex.split(self.command(["pkg-config", "--libs", *PACKAGES], "sdk-links").decode())
        library_files = {}
        for package in PACKAGES:
            folder = Path(self.command(["pkg-config", "--variable=libdir", package], "sdk-libdir-" + package).decode().strip())
            for path in sorted(folder.glob(package + ".*")):
                if path.is_file():
                    library_files[str(path.resolve())] = sha(path.read_bytes())
        self.receipt["sdkLibraryInventorySHA256"] = library_files
        driver = self.stage("Driver.swift", (HERE / "Driver.swift").read_bytes())
        sources = {variant: self.sources(variant) for variant in ("baseline", "candidate")}
        for relative in ("Support.swift", "CFFmpeg/shim.h"):
            require((self.output / "sources/baseline" / relative).read_bytes()
                    == (self.output / "sources/candidate" / relative).read_bytes(),
                    f"Shared support changed: {relative}")
        binaries = {}
        for configuration, flag in CONFIGURATIONS.items():
            for variant in ("baseline", "candidate"):
                binary = self.output / "bin" / f"{variant}-{configuration}"
                binary.parent.mkdir(parents=True, exist_ok=True)
                command = [self.swiftc, "-swift-version", "6", "-parse-as-library", "-warnings-as-errors", flag,
                           "-module-cache-path", self.output / "module-cache", "-I", self.output / "sources" / variant / "CFFmpeg"]
                command += [arg for value in cflags for arg in ("-Xcc", value)]
                command += [*sources[variant], driver]
                command += [arg for value in links for arg in ("-Xlinker", value)]
                command += ["-o", binary]
                self.command(command, "build-" + binary.name)
                self.receipt["binaryHashes"][binary.name] = sha(binary.read_bytes())
                self.command(["ldd" if platform.system() == "Linux" else "otool", *([] if platform.system() == "Linux" else ["-L"]), binary], "linked-" + binary.name)
                binaries[configuration, variant] = binary
        canonical = {}
        for configuration in CONFIGURATIONS:
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate", "candidate", "baseline")
                if pair % 2:
                    order = ("candidate", "baseline", "baseline", "candidate")
                for position, variant in enumerate(order):
                    label = f"{configuration}-{pair}-{position}-{variant}"
                    report = json.loads(self.command([binaries[configuration, variant]], "run-" + label))
                    validate(report, variant)
                    for package, field in [("libavcodec", "avcodecVersion"), ("libavutil", "avutilVersion")]:
                        number = report[field]
                        runtime = ".".join(str((number >> shift) & 255) for shift in (16, 8, 0))
                        require(runtime == self.receipt["sdkVersions"][package], f"SDK/runtime mismatch: {package}")
                    if variant in canonical:
                        require(report == canonical[variant], f"Nondeterministic ownership across fresh processes/configurations: {label}")
                    canonical[variant] = report
                    path = self.output / "observations" / (label + ".json")
                    save(path, report)
                    self.receipt["observations"].append({"configuration": configuration, "pair": pair,
                        "position": position, "variant": variant, "path": str(path.relative_to(self.output)),
                        "sha256": sha(path.read_bytes())})
                    self.persist()
        left = {c["name"]: c for c in canonical["baseline"]["cases"]}
        right = {c["name"]: c for c in canonical["candidate"]["cases"]}
        for name in ("stale_generation", "pre_eof_recovery"):
            require(left[name] == right[name], f"Existing recovery behavior differs: {name}")
        for name in GOPS:
            for phase in ("recorded", "afterReset"):
                require(left[name]["snapshots"][phase] == right[name]["snapshots"][phase],
                        f"Ownership control differs: {name}/{phase}")
        summary = [{"case": name, "baselineAfterEOF": left[name]["snapshots"]["afterEOF"],
                    "candidateAfterEOF": right[name]["snapshots"]["afterEOF"]} for name in GOPS]
        save(self.output / "summary.json", summary)
        self.receipt["summary"] = summary
        self.receipt["complete"] = True
        self.receipt["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        self.persist()
        print(json.dumps({"complete": True, "observations": len(self.receipt["observations"]),
                          "receipt": str(self.output / "receipt.json")}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=2, help="Fresh-process ABBA/BAAB cohorts per configuration")
    parser.add_argument("--swiftc", help="Swift 6 compiler path (default: PATH)")
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    study = Study(args)
    try:
        study.run()
    finally:
        study.persist()


if __name__ == "__main__":
    main()
