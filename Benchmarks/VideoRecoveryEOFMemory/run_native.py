#!/usr/bin/env python3
"""Qualify recovery-buffer EOF lifetime against actual native session workers.

Run only in an isolated checkout. All Swift builds are serialized and temporary
source probes are restored even if a build, test, or parity gate fails.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import time

from measure import BASELINE, INSERTION

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PACKET = "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift"
SESSION = "Sources/IlliquidNativePlayback/Media/MediaSession.swift"
UNIT = "Tests/IlliquidNativePlaybackTests/VideoRecoveryPacketLifetimeTests.swift"
INTEGRATION = "Tests/IlliquidNativePlaybackTests/VideoRecoveryEOFIntegrationTests.swift"
EOF_INSERTION = """                        // Thrown drain errors still need the GOP for decoder recovery.
                        // Only release the completed generation's compressed replay.
                        if isRunning && generation.accepts(active) {
                            videoRecoveryPackets.finish(generation: active)
                        }
"""
RECOVERY_TESTS = [
    "videoRecoveryPacketBufferReplaysFromAKeyframeOnce",
    "recreatesSoftwareDecoderAfterHardwarePathFailure",
    "recreatesSoftwareDecoderFromBufferedGOPWithoutSeeking",
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Qualification:
    def __init__(self, output):
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        (self.output / "logs").mkdir()
        (self.output / "fixtures").mkdir()
        self.commands = []
        self.summary = {
            "status": "running", "baseline_revision": BASELINE,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "machine": platform.machine(),
            "qualification": "Native component and actual prepared session; no live presentation/UI qualification.",
            "sources": {}, "tests": {},
        }

    def persist(self):
        save(self.output / "commands.json", self.commands)
        save(self.output / "summary.json", self.summary)

    def run(self, args, name, env=None):
        argv = [str(arg) for arg in args]
        print("$ " + shlex.join(argv), flush=True)
        log = self.output / "logs" / f"{len(self.commands):03d}-{name}.log"
        start = time.monotonic()
        with log.open("wb") as stream:
            process = subprocess.run(argv, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
        data = log.read_bytes()
        self.commands.append({
            "argv": argv, "returncode": process.returncode,
            "elapsed_seconds": time.monotonic() - start,
            "log": str(log.relative_to(self.output)), "log_sha256": sha(data),
        })
        self.persist()
        if process.returncode:
            print(data.decode(errors="replace")[-16000:], flush=True)
            raise RuntimeError(f"{name} failed with status {process.returncode}; see {log}")
        return data

    def snapshot(self, relative, data):
        destination = self.output / "sources" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        self.summary["sources"][relative] = sha(data)

    def run_tests(self, name, pattern, env, minimum_count):
        output = self.run([
            "swift", "test", "--scratch-path", self.output / "build",
            "--force-resolved-versions", "-c", "release", "--jobs", "2",
            "--no-parallel", "--filter", pattern,
        ], name, env).decode(errors="replace")
        counts = re.findall(r"Test run with (\d+) tests? .*passed", output)
        if not counts or int(counts[-1]) < minimum_count:
            raise RuntimeError(f"{name}: missing successful Swift Testing receipt or too few tests")
        self.summary["tests"][name] = {"passed": int(counts[-1]), "configuration": "release"}
        print(output[-4500:], flush=True)
        self.persist()

    def execute(self):
        if platform.system() != "Darwin":
            raise RuntimeError("Actual macOS frameworks and pinned native SDK are required")
        if Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists():
            raise RuntimeError("Kyoto is available; submit this qualification through its shared queue")
        print("Kyoto is unavailable here; compiling serially in an isolated checkout.", flush=True)
        self.summary["head"] = self.run(["git", "rev-parse", "HEAD"], "head").decode().strip()
        self.summary["swift_version"] = self.run(["swift", "--version"], "swift-version").decode().strip()
        self.run(["git", "diff", "--exit-code", "--", "Sources", "Tests", "Package.swift", "Package.resolved"],
                 "clean-sources")
        changed = set(self.run([
            "git", "diff", "--name-only", BASELINE, "--", "Sources", "Package.swift", "Package.resolved",
        ], "changed-production").decode().splitlines())
        if changed != {PACKET, SESSION}:
            raise RuntimeError(f"Review unexpected production differences before requalifying: {changed}")
        originals = {path: (ROOT / path).read_bytes() for path in (PACKET, SESSION, UNIT)}
        if (ROOT / INTEGRATION).exists():
            raise RuntimeError("Refusing to replace an existing integration test")
        baseline = {}
        for path, insertion in [(PACKET, INSERTION), (SESSION, EOF_INSERTION)]:
            baseline[path] = self.run(["git", "show", f"{BASELINE}:{path}"], "baseline-source")
            if originals[path].count(insertion.encode()) != 1:
                raise RuntimeError(f"Qualified insertion changed: {path}")
            if originals[path].replace(insertion.encode(), b"", 1) != baseline[path]:
                raise RuntimeError(f"Unexpected edits in {path}")
            self.snapshot("baseline/" + path, baseline[path])
            self.snapshot("candidate/" + path, originals[path])
        self.snapshot("candidate/" + UNIT, originals[UNIT])
        for name in ("run_native.py", "PacketProbe.swift", "SessionProbe.swift",
                     "VideoRecoveryEOFIntegrationTests.swift"):
            self.snapshot("harness/" + name, (HERE / name).read_bytes())

        fixtures = self.output / "fixtures"
        small = fixtures / "eof-recovery-h264.mp4"
        recovery = fixtures / "h264-aac.mp4"
        self.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=25",
            "-frames:v", "4", "-an", "-c:v", "libx264", "-preset", "medium",
            "-pix_fmt", "yuv420p", "-g", "48", "-bf", "2",
            "-x264-params", "keyint=48:min-keyint=48:scenecut=0:b-adapt=0",
            "-threads", "2", small,
        ], "generate-eof-fixture")
        self.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "3", "-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p",
            "-g", "48", "-bf", "2", "-x264-params", "keyint=48:min-keyint=48:scenecut=0",
            "-threads", "2", "-c:a", "aac", "-b:a", "96k", recovery,
        ], "generate-recovery-fixture")
        for fixture in (small, recovery):
            self.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-xerror",
                      "-i", fixture, "-f", "null", "-"], "validate-" + fixture.stem)
        # The reviewed SDK supplies ffmpeg, not ffprobe. Check delayed output
        # with the same pinned decoder CLI that produced/validated the fixture.
        showinfo = self.run([
            "ffmpeg", "-hide_banner", "-nostdin", "-v", "info", "-i", small,
            "-map", "0:v:0", "-vf", "showinfo", "-an", "-f", "null", "-",
        ], "inspect-eof-frames").decode(errors="replace")
        frames = re.findall(r"\bn:\s*(\d+).*?\btype:([IPB?])\b", showinfo)
        if [int(index) for index, _ in frames] != [0, 1, 2, 3]:
            raise RuntimeError("EOF fixture must decode exactly four frames")
        if not any(kind == "B" for _, kind in frames):
            raise RuntimeError("EOF fixture must exercise delayed B-frame output")
        save(fixtures / "eof-recovery-h264.json", {
            "decoder": "pinned ffmpeg with showinfo", "frame_indices_and_types": frames,
            "four_frames": True, "contains_b_frames": True,
        })
        self.summary["fixtures"] = {p.name: sha(p.read_bytes()) for p in (small, recovery)}

        environment = dict(os.environ)
        environment["ILLIQUID_NATIVE_FIXTURE_DIR"] = str(fixtures)
        environment["ILLIQUID_PACKET_OWNERSHIP_FIXTURE"] = str(recovery)
        pattern = "|".join(["VideoRecoveryPacketLifetimeTests", "PacketOwnershipTests"] + RECOVERY_TESTS)
        # Compile and execute the ordinary production graph before adding probes.
        self.run_tests("candidate-uninstrumented", pattern, environment, 16)

        receipts = {}
        try:
            (ROOT / INTEGRATION).write_bytes((HERE / "VideoRecoveryEOFIntegrationTests.swift").read_bytes())
            for variant in ("baseline", "candidate"):
                selected = baseline if variant == "baseline" else originals
                for path, probe in [(PACKET, "PacketProbe.swift"), (SESSION, "SessionProbe.swift")]:
                    data = selected[path] + (HERE / probe).read_bytes()
                    (ROOT / path).write_bytes(data)
                    self.snapshot(variant + "-instrumented/" + path, data)
                if variant == "baseline":
                    (ROOT / UNIT).unlink()
                else:
                    (ROOT / UNIT).write_bytes(originals[UNIT])
                receipt_path = self.output / (variant + "-session.json")
                env = dict(environment)
                env.update(
                    ILLIQUID_RECOVERY_EOF_FIXTURE=str(small),
                    ILLIQUID_RECOVERY_EOF_EXPECT_RELEASED="1" if variant == "candidate" else "0",
                    ILLIQUID_RECOVERY_EOF_OUTPUT=str(receipt_path),
                )
                self.run_tests(variant + "-session", "VideoRecoveryEOFIntegrationTests", env, 1)
                receipt = json.loads(receipt_path.read_text())
                if receipt["completed"] is not True or receipt["shutdownCompleted"] is not True:
                    raise RuntimeError("Incomplete native session receipt")
                if receipt["expectedReleased"] != (variant == "candidate"):
                    raise RuntimeError("Wrong variant in native session receipt")
                receipts[variant] = receipt
        finally:
            for path, data in originals.items():
                (ROOT / path).write_bytes(data)
            (ROOT / INTEGRATION).unlink(missing_ok=True)
            self.summary["sources_restored"] = all(
                (ROOT / path).read_bytes() == data for path, data in originals.items()
            ) and not (ROOT / INTEGRATION).exists()
            self.persist()
        self.run(["git", "diff", "--exit-code", "--", "Sources", "Tests"], "restored-sources")
        if not self.summary["sources_restored"]:
            raise RuntimeError("Temporary native source probes were not restored")
        left, right = receipts["baseline"], receipts["candidate"]
        for field in ("fixtureSHA256", "expectedFrameCount", "heldFrameAfterSeek", "heldFrameAfterShutdown"):
            if left[field] != right[field]:
                raise RuntimeError("Native output parity failed: " + field)
        comparisons = {}
        for phase in ("first", "afterSeek"):
            a, b = left[phase], right[phase]
            for field in ("generation", "queuedItemCount", "frames", "endOfStreamGenerations"):
                if a[field] != b[field]:
                    raise RuntimeError("Native output parity failed: " + phase + "." + field)
            comparisons[phase] = {
                "baseline_retained": a["recoveryBeforeQueueConsumption"],
                "candidate_retained": b["recoveryBeforeQueueConsumption"],
                "complete_active_pixel_hashes_and_metadata_match": True,
                "frames": [frame["output"] for frame in b["frames"]],
            }
        self.summary.update(status="passed", comparisons=comparisons,
                            held_frame_survived_seek_and_shutdown=True,
                            complete_native_output_parity=True)
        self.persist()
        print(json.dumps(self.summary, indent=2, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    study = Qualification(args.output)
    try:
        study.execute()
    except BaseException as error:
        study.summary.update(status="failed", error=str(error))
        study.persist()
        raise


if __name__ == "__main__":
    main()
