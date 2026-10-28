#!/usr/bin/env python3
"""Measure native packet final-release ownership, not RSS or playback speed.

The baseline component EOF operation is deliberately a no-op, matching the
existing buffer lifetime. The candidate calls finish(generation:). Complete
MediaSession drain/EOF execution is qualified separately by native tests.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/CFFmpeg/include/ffmpeg_shim.h",
    "Sources/CFFmpeg/module.modulemap",
]
INSERTION = """    /// Releases replay ownership after this generation's session drain succeeds.
    /// A stale completion must not discard a newer generation's recovery GOP.
    func finish(generation expectedGeneration: Int) {
        lock.withLock {
            guard generation == expectedGeneration else { return }
            resetLocked(generation: expectedGeneration)
        }
    }

"""
CASES = ["empty", "gop", "byte_bound", "packet_bound", "held_clone",
         "stale_generation", "reset_control"]
PACKAGES = ["libavformat", "libavfilter", "libavcodec", "libavutil",
            "libswresample", "libswscale"]
EXPECTED_VERSIONS = ["62.12.102", "11.14.102", "62.28.102", "60.26.102",
                     "6.3.102", "9.5.102"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        (self.output / "logs").mkdir()
        (self.output / "binaries").mkdir()
        self.commands = []
        self.manifest = {
            "baseline_revision": BASELINE, "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "machine": platform.machine(),
            "python_version": platform.python_version(), "pairs": args.pairs,
            "developer_dir": os.environ.get("DEVELOPER_DIR"), "sources": {}, "binaries": {},
        }
        self.summary = {
            "status": "running", "scope": "native compressed-packet lifetime component",
            "baseline_EOF_is_no_op": True, "configurations": ["debug", "release"],
            "pairs": args.pairs, "cases": CASES, "comparisons": [],
            "limitations": [
                "Payload/AVBuffer extents exclude headers, probe overhead, allocator metadata and RSS.",
                "The final callback moves the sole original AVBufferRef; no observer reference is added.",
                "Synthetic compressed bytes exercise ownership, not decoding or live playback.",
                "This study does not execute MediaSession drain; native integration tests do that separately.",
                "No runtime-performance improvement is claimed; command wall times are provenance only.",
            ],
        }

    def persist(self):
        save(self.output / "manifest.json", self.manifest)
        save(self.output / "commands.json", self.commands)
        save(self.output / "summary.json", self.summary)

    def run(self, args, name):
        argv = [str(value) for value in args]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = self.output / "logs" / f"{len(self.commands):04d}-{name}.log"
        log.write_bytes(result.stdout)
        self.commands.append({
            "argv": argv, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started,
            "log": str(log.relative_to(self.output)), "log_sha256": sha(result.stdout),
        })
        self.persist()
        if result.returncode:
            raise RuntimeError(f"{name} exited {result.returncode}:\n"
                               + result.stdout.decode(errors="replace")[-8000:])
        return result.stdout

    def stage(self, relative, data):
        path = self.output / "sources" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.manifest["sources"][str(path.relative_to(self.output))] = sha(data)
        return path

    def execute(self):
        if platform.system() != "Darwin":
            raise RuntimeError("This study requires the actual macOS native SDK")
        self.manifest["head"] = self.run(["git", "rev-parse", "HEAD"], "head").decode().strip()
        self.manifest["worktree_status"] = self.run(["git", "status", "--short"], "status").decode()
        self.manifest["swift_version"] = self.run(["xcrun", "swiftc", "--version"], "swift-version").decode().strip()
        sdk = self.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").decode().strip()
        versions = self.run(["pkg-config", "--modversion", *PACKAGES], "native-versions").decode().splitlines()
        if versions != EXPECTED_VERSIONS:
            raise RuntimeError("Pinned FFmpeg 8.1.2 native SDK is required")
        self.manifest["native_versions"] = dict(zip(PACKAGES, versions))
        cflags = shlex.split(self.run(["pkg-config", "--cflags", *PACKAGES], "native-cflags").decode())
        links = shlex.split(self.run(["pkg-config", "--libs", *PACKAGES], "native-links").decode())
        self.manifest["native_cflags"] = cflags
        self.manifest["native_links"] = links
        staged = {"baseline": [], "candidate": []}
        for path in SOURCES:
            original = self.run(["git", "show", f"{BASELINE}:{path}"], "baseline-source")
            candidate = (ROOT / path).read_bytes()
            if path == SOURCES[0]:
                if candidate.count(INSERTION.encode()) != 1:
                    raise RuntimeError("Review changed finish method before requalifying")
                if candidate.replace(INSERTION.encode(), b"", 1) != original:
                    raise RuntimeError("FFmpegPacket has changes outside the qualified finish insertion")
            elif candidate != original:
                raise RuntimeError(f"Unrelated compiled dependency changed: {path}")
            for variant, data in [("baseline", original), ("candidate", candidate)]:
                destination = self.stage(variant + "/" + path, data)
                if path.endswith(".swift"):
                    staged[variant].append(destination)
        for name in ["Driver.swift", "measure.py", "CLifetimeProbe/LifetimeProbe.h",
                     "CLifetimeProbe/LifetimeProbe.c", "CLifetimeProbe/module.modulemap"]:
            self.stage("harness/" + name, (HERE / name).read_bytes())
        harness = self.output / "sources/harness"
        probe = self.output / "binaries/LifetimeProbe.o"
        target = f"{platform.machine()}-apple-macosx26.0"
        self.run(["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                  "-target", target, "-isysroot", sdk, *cflags,
                  "-c", harness / "CLifetimeProbe/LifetimeProbe.c", "-o", probe], "build-probe")
        self.manifest["binaries"]["LifetimeProbe.o"] = sha(probe.read_bytes())
        binaries = {}
        for configuration, optimize in [("debug", "-Onone"), ("release", "-O")]:
            for variant in ["baseline", "candidate"]:
                flags = [optimize, "-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                         "-target", target, "-sdk", sdk,
                         "-module-cache-path", self.output / ("module-cache-" + variant),
                         "-I", self.output / "sources" / variant / "Sources/CFFmpeg",
                         "-I", harness / "CLifetimeProbe"]
                if variant == "candidate":
                    flags += ["-D", "CANDIDATE"]
                for flag in cflags:
                    flags += ["-Xcc", flag]
                for flag in links:
                    flags += ["-Xlinker", flag]
                    if flag.startswith("-L"):
                        flags += ["-Xlinker", "-rpath", "-Xlinker", flag[2:]]
                binary = self.output / "binaries" / f"{configuration}-{variant}"
                self.run(["xcrun", "swiftc", *flags, *staged[variant],
                          harness / "Driver.swift", probe, "-o", binary], "build-" + binary.name)
                self.manifest["binaries"][binary.name] = sha(binary.read_bytes())
                binaries[configuration, variant] = binary
        canonical = {}
        raw = self.output / "observations.jsonl"
        for configuration in ["debug", "release"]:
            for case in CASES:
                pair_results = {}
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    for variant in order:
                        value = json.loads(self.run([binaries[configuration, variant], case],
                                                  f"{configuration}-{case}-{pair}-{variant}"))
                        if value["passed"] is not True or value["variant"] != variant or value["workload"] != case:
                            raise RuntimeError("Driver identity/validation mismatch")
                        key = (variant, case)
                        if key in canonical and value != canonical[key]:
                            raise RuntimeError("Ownership evidence changed across processes/configurations")
                        canonical[key] = value
                        pair_results[variant] = value
                        with raw.open("a") as stream:
                            stream.write(json.dumps(dict(value, configuration=configuration, pair=pair),
                                                    sort_keys=True) + "\n")
                    for field in ["input_fingerprint", "loaded", "packet_count", "packet_size",
                                  "held_clone_checksum", "after_final_release"]:
                        if pair_results["baseline"][field] != pair_results["candidate"][field]:
                            raise RuntimeError(f"Baseline/candidate input or cleanup parity failed: {field}")
                left, right = pair_results["baseline"], pair_results["candidate"]
                self.summary["comparisons"].append({
                    "configuration": configuration, "workload": case, "pairs": self.args.pairs,
                    "packet_count": left["packet_count"], "packet_size": left["packet_size"],
                    "baseline_after_operation": left["after_operation"],
                    "candidate_after_operation": right["after_operation"],
                    "released_payload_bytes": left["after_operation"]["live_payload_bytes"]
                                              - right["after_operation"]["live_payload_bytes"],
                    "input_and_final_cleanup_parity": True,
                })
                self.persist()
        self.summary["status"] = "passed"
        self.persist()
        print(json.dumps(self.summary, indent=2, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=2)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer of at least 2")
    study = Study(args)
    try:
        study.execute()
    except BaseException as error:
        study.summary.update(status="failed", error=str(error))
        study.persist()
        raise


if __name__ == "__main__":
    main()
