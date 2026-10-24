#!/usr/bin/env python3
"""Measure real VideoDecoder scratch ownership with the native application graph.

Run on macOS after installing the repository's pinned native SDK and Metal tools.
No checkout files are edited. Two temporary packages share identical current
support sources and strict tests; their VideoDecoder implementations differ only
in the placement of av_frame_unref. The baseline is checked byte for byte against
the pinned historical source. Default qualification is release; debug is optional.
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
import shutil
import subprocess
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
DECODER = "Sources/IlliquidNativePlayback/Media/VideoDecoder.swift"
REGRESSIONS = "Tests/IlliquidNativePlaybackTests/VideoDecoderFrameLifetimeTests.swift"
PROBE_DESTINATION = "Tests/IlliquidNativePlaybackTests/VideoDecoderFrameLifetimeProbeTests.swift"
CLEANUP = b"""            // Release scratch output on early cancellation or delivery failure,
            // before a following continuation check can leave the loop. Emitted
            // frames and deinterlacing history own their pixels independently.
            defer { av_frame_unref(frame) }
"""
OLD_CLEANUP = b"            av_frame_unref(frame)\n"
VARIANTS = ("baseline", "candidate")
SIZES = ((64, 48), (1920, 1080), (3840, 2160))
CASES = (
    "normal", "cancelled_before_decode", "cancelled_after_emit",
    "throwing_frame_consumer", "refused_output_reservation",
    "throwing_timestamp_consumer", "normal_timestamp",
)
AFFECTED_CASES = frozenset((
    "cancelled_after_emit", "throwing_frame_consumer",
    "refused_output_reservation", "throwing_timestamp_consumer",
))
STAGES = (
    "after_packet_release", "after_idle", "after_flush",
    "after_recovery", "after_decoder_destruction",
)
TIMESTAMP_FIXTURES = (
    "timestamp-cfr-bframes.mkv", "timestamp-vfr.mkv", "timestamp-nonzero.mkv",
    "timestamp-single.mp4", "timestamp-tff.mpg", "timestamp-bff.mpg",
    "timestamp-tff.mkv", "timestamp-bff.mkv",
)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def source_pair() -> tuple[bytes, bytes]:
    candidate = (ROOT / DECODER).read_bytes()
    if candidate.count(CLEANUP) != 1:
        raise ValueError("The exact candidate cleanup block changed; review the benchmark boundary")
    baseline = candidate.replace(CLEANUP, OLD_CLEANUP, 1)
    pinned = git("show", f"{BASELINE}:{DECODER}")
    if baseline != pinned:
        raise ValueError("Reconstructed baseline differs from the pinned complete production decoder")
    if baseline == candidate:
        raise ValueError("The compared production implementations are identical")
    return baseline, candidate


class Study:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory; previous evidence is never overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.baseline, self.candidate = source_pair()
        self.env = os.environ.copy()
        self.env.update(
            CLANG_MODULE_CACHE_PATH=str(self.output / "cache/modules"),
            SWIFT_MODULECACHE_PATH=str(self.output / "cache/modules"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "cache/modules"),
            TERM="dumb", NO_COLOR="1",
        )
        self.commands: list[dict] = []
        self.manifest = {
            "schema_version": 1,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_checkout_revision": git("rev-parse", "HEAD").decode().strip(),
            "candidate_worktree_status": git("status", "--porcelain=v1").decode(),
            "configuration": args.configuration,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "source_comparison": {
                "focal_source": DECODER,
                "baseline_sha256": sha(self.baseline),
                "candidate_sha256": sha(self.candidate),
                "baseline_is_exact_pinned_source": True,
                "shared_current_support": True,
                "only_transformation": "Replace one loop-top av_frame_unref with loop-scope defer",
                "old_cleanup": OLD_CLEANUP.decode(),
                "new_cleanup": CLEANUP.decode(),
            },
            "measurement": {
                "metric": "Bytes of one live av_malloc allocation tracked by its AVBuffer free callback",
                "includes": "Rawvideo BGRA input payload plus AV_INPUT_BUFFER_PADDING_SIZE",
                "excludes": ["CVPixelBuffer output", "codec-private allocation totals", "allocator overhead",
                             "process RSS", "hardware decoder surfaces", "whole-player footprint"],
                "packet_released_before_sampling": True,
                "decoder_and_emitted_frames_alive_at_first_sample": True,
                "sampling_precedes_pixel_extraction_hashing_and_json": True,
                "idle_milliseconds_without_decoding": 25,
                "fixtures": "In-process real rawvideo BGRA AVPacket buffers; no fake decoder",
                "timing_claim": "No decoding throughput or latency claim is made",
            },
            "sizes": list(SIZES), "cases": list(CASES),
            "driver_hashes": {name: file_sha(HERE / name) for name in ("run.py", "ProbeTests.swift")},
            "staged_sources": {}, "test_runs": [], "complete": False,
        }

    def checkpoint(self) -> None:
        save(self.output / "manifest.json", self.manifest)
        save(self.output / "commands.json", self.commands)

    def command(self, arguments: list, name: str, *, env: dict | None = None,
                timeout: int = 1800) -> str:
        arguments = [str(value) for value in arguments]
        log = self.output / "logs" / (name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        with log.open("wb") as stream:
            result = subprocess.run(arguments, cwd=ROOT, env=env or self.env,
                                    stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        data = log.read_bytes()
        self.commands.append({
            "argv": arguments, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started,
            "log": str(log.relative_to(self.output)), "log_sha256": sha(data),
        })
        self.checkpoint()
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n" + data.decode(errors="replace")[-12000:])
        return data.decode()

    def prepare(self) -> None:
        self.manifest["swift_version"] = self.command([self.args.swift, "--version"], "swift-version").strip()
        self.manifest["macos"] = self.command(["sw_vers"], "macos").strip()
        self.manifest["hardware"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "hardware").strip()
        self.manifest["sdk_version"] = self.command(
            ["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version").strip()
        self.manifest["native_sdk_manifest_sha256"] = file_sha(ROOT / "BuildInputs/native-sdk.json")
        self.manifest["dependency_source_manifest_sha256"] = file_sha(ROOT / "DependencySources/source-manifest.json")
        self.manifest["native_temporal_integration"] = False
        fixture_directory = self.env.get("ILLIQUID_FRAME_STEP_FIXTURE_DIR")
        if fixture_directory:
            fixtures = Path(fixture_directory).resolve(strict=True)
            manifest_path = fixtures / "fixture-manifest.json"
            fixture_manifest = json.loads(manifest_path.read_text())
            records = {record["filename"]: record for record in fixture_manifest["fixtures"]}
            if set(records) != set(TIMESTAMP_FIXTURES):
                raise ValueError("Native temporal integration requires the complete generated corpus")
            for name, record in records.items():
                if file_sha(fixtures / name) != record["sha256"]:
                    raise ValueError(f"Native temporal fixture hash changed: {name}")
            native = Path(self.env.get("ILLIQUID_NATIVE_FIXTURE_DIR", "")).resolve(strict=True)
            for field in ("tff", "bff"):
                if file_sha(native / f"interlaced-{field}.mpg") != records[f"timestamp-{field}.mpg"]["sha256"]:
                    raise ValueError(f"Missing or different interlaced native alias: {field}")
            save(self.output / "fixture-manifest.json", fixture_manifest)
            self.manifest["native_temporal_integration"] = True
            self.manifest["integration_fixture_manifest_sha256"] = file_sha(manifest_path)
            self.manifest["integration_fixture_sha256"] = {
                name: record["sha256"] for name, record in records.items()
            }

        # SwiftPM only needs these tracked inputs. Do not copy historical
        # benchmark evidence, dependency archives, an existing .build or .git.
        paths = {
            value.decode() for value in git("ls-files", "-z", "--", "Sources", "Tests", "Validation",
                                          "Package.swift", "Package.resolved").split(b"\0") if value
        }
        paths.add(REGRESSIONS)  # Also permit a reviewed, not-yet-committed local test.
        if not {DECODER, "Package.swift", "Package.resolved", REGRESSIONS} <= paths:
            raise ValueError("Required native package input is missing")
        source_hashes = {}
        for relative in sorted(paths):
            source = ROOT / relative
            if not source.is_file():
                raise ValueError(f"Missing tracked package input: {relative}")
            source_hashes[relative] = file_sha(source)
        self.manifest["shared_source_sha256"] = {
            path: digest for path, digest in source_hashes.items() if path != DECODER
        }

        for variant, decoder in (("baseline", self.baseline), ("candidate", self.candidate)):
            package = self.output / "packages" / variant
            records = {}
            for relative in sorted(paths):
                source, destination = ROOT / relative, package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                if relative == DECODER:
                    # Never rewrite a hard link: focal implementations are
                    # independently written and the root checkout is untouched.
                    destination.write_bytes(decoder)
                elif relative in {"Package.swift", "Package.resolved"}:
                    # SwiftPM may rewrite package bookkeeping. Give it private
                    # copies even though resolved versions are forced below.
                    shutil.copy2(source, destination)
                else:
                    try:
                        os.link(source, destination)
                    except OSError:
                        shutil.copy2(source, destination)
                records[relative] = file_sha(destination)
            destination = package / PROBE_DESTINATION
            destination.write_bytes((HERE / "ProbeTests.swift").read_bytes())
            records[PROBE_DESTINATION] = file_sha(destination)
            self.manifest["staged_sources"][variant] = records
            retained = self.output / "sources" / variant / "VideoDecoder.swift"
            retained.parent.mkdir(parents=True, exist_ok=True)
            retained.write_bytes(decoder)

        for path in set(paths) - {DECODER}:
            if self.manifest["staged_sources"]["baseline"][path] != self.manifest["staged_sources"]["candidate"][path]:
                raise ValueError(f"Unequal shared production/test support: {path}")
        shared = self.output / "sources/shared"
        shared.mkdir(parents=True)
        (shared / "VideoDecoderFrameLifetimeTests.swift").write_bytes((ROOT / REGRESSIONS).read_bytes())
        for name in ("run.py", "ProbeTests.swift"):
            (self.output / "sources" / name).write_bytes((HERE / name).read_bytes())
        self.checkpoint()

    def run(self, variant: str) -> None:
        print(f"Build and qualify actual native {self.args.configuration}/{variant}", flush=True)
        package = self.output / "packages" / variant
        receipts = self.output / "receipts" / variant
        receipts.mkdir(parents=True)
        environment = self.env.copy()
        environment["ILLIQUID_VIDEO_FRAME_LIFETIME_EVIDENCE_DIR"] = str(receipts)
        selected = "VideoDecoderFrameLifetimeProbeTests"
        required_suites = ["Video decoder frame lifetime measurements"]
        if variant == "candidate":
            selected += "|VideoDecoderFrameLifetimeTests"
            required_suites.append("Video decoder scratch-frame lifetime")
            if self.manifest["native_temporal_integration"]:
                selected += "|VideoTimestampDiscoveryTests|VideoDeinterlacerTests"
                required_suites += ["Timestamp discovery without presentation buffers", "Decoder-owned BWDIF deinterlacing"]
        command = [
            self.args.swift, "test", "--package-path", package,
            "--scratch-path", self.output / "build" / variant,
            "--cache-path", self.output / "cache/packages",
            "--config-path", self.output / "cache/config",
            "--security-path", self.output / "cache/security",
            "--force-resolved-versions", "--configuration", self.args.configuration,
            "--jobs", self.args.jobs, "--no-parallel", "--filter", selected,
        ]
        text = self.command(command, variant + "-native-tests", env=environment)
        counts = re.findall(r"Test run with (\d+) tests?", text)
        # Swift Testing counts @Test declarations here, not parameter values.
        # Require the entire selected suite set, not merely a nonempty run.
        expected_tests = 1 if variant == "baseline" else (
            19 if self.manifest["native_temporal_integration"] else 5
        )
        if not counts or int(counts[-1]) != expected_tests:
            raise ValueError(f"Expected {expected_tests} completed test declarations for {variant}, got {counts}")
        if "skipped" in text.lower():
            raise ValueError(f"The selected measurement/lifetime tests must not be skipped: {variant}")
        for suite in required_suites:
            if not re.search(r'Suite "' + re.escape(suite) + r'" passed\b', text):
                raise ValueError(f"Required suite did not report completion: {variant}/{suite}")
        self.manifest["test_runs"].append({
            "variant": variant, "configuration": self.args.configuration,
            "filter": selected, "reported_tests": int(counts[-1]), "passed": True,
            "completed_required_suites": required_suites,
            "receipt_directory": str(receipts.relative_to(self.output)),
        })
        executables = []
        for bundle in (self.output / "build" / variant).rglob("*.xctest"):
            directory = bundle / "Contents/MacOS"
            if directory.is_dir():
                executables += [path for path in directory.iterdir() if path.is_file()]
        if len(executables) != 1:
            raise ValueError(f"Expected one native test executable, found {len(executables)} for {variant}")
        self.manifest.setdefault("test_binary_sha256", {})[variant] = file_sha(executables[0])
        # Receipt every input and confirm the build did not alter any shared
        # hard-linked file. No subsequent source mutation is part of this study.
        for relative, expected in self.manifest["staged_sources"][variant].items():
            if file_sha(package / relative) != expected:
                raise ValueError(f"A staged source changed during qualification: {variant}/{relative}")
        self.checkpoint()

    def summarize(self) -> None:
        expected_names = {
            f"{case}-{width}x{height}.json" for case in CASES for width, height in SIZES
        }
        for variant in VARIANTS:
            actual = {path.name for path in (self.output / "receipts" / variant).glob("*.json")}
            if actual != expected_names:
                raise ValueError(f"Incomplete or extra {variant} receipts: missing={expected_names - actual}, extra={actual - expected_names}")
        summary = []
        for case in CASES:
            for width, height in SIZES:
                name = f"{case}-{width}x{height}.json"
                values = {variant: json.loads((self.output / "receipts" / variant / name).read_text())
                          for variant in VARIANTS}
                baseline, candidate = values["baseline"], values["candidate"]
                for variant, value in values.items():
                    if (value["schema"], value["scenario"], value["width"], value["height"]) != (1, case, width, height):
                        raise ValueError(f"Receipt identity mismatch: {variant}/{name}")
                    if set(value["snapshots"]) != set(STAGES):
                        raise ValueError(f"Lifecycle stages missing: {variant}/{name}")
                    if value["inputPayloadBytes"] != width * height * 4 or value["trackedAllocationBytes"] != value["inputPayloadBytes"] + value["packetPaddingBytes"]:
                        raise ValueError(f"Fixture byte accounting mismatch: {variant}/{name}")
                    if not value["pixelsEqualExpectedAfterRecoveryAndDestruction"]:
                        raise ValueError(f"Caller-owned output changed: {variant}/{name}")
                    for stage in STAGES:
                        snapshot = value["snapshots"][stage]
                        expect_retained = variant == "baseline" and case in AFFECTED_CASES and stage in STAGES[:3]
                        expected = {"trackedLiveAllocationBytes": value["trackedAllocationBytes"] if expect_retained else 0,
                                    "trackedBufferFreeCallbacks": 0 if expect_retained else 1}
                        if snapshot != expected:
                            raise ValueError(f"Unexpected native lifetime: {variant}/{name}/{stage}: {snapshot}; expected {expected}")
                    if value["recoveryAllocation"] != {"trackedLiveAllocationBytes": 0, "trackedBufferFreeCallbacks": 1}:
                        raise ValueError(f"Recovery packet retained input: {variant}/{name}")
                for field in ("inputPayloadBytes", "trackedAllocationBytes", "packetPaddingBytes", "idleMilliseconds",
                              "ffmpegVersion", "output", "recovery", "pixelsEqualExpectedAfterRecoveryAndDestruction"):
                    if baseline[field] != candidate[field]:
                        raise ValueError(f"Complete semantic output mismatch: {name}/{field}")
                summary.append({
                    "case": case, "width": width, "height": height,
                    "configuration": self.args.configuration,
                    "baseline_retained_bytes": baseline["snapshots"]["after_packet_release"]["trackedLiveAllocationBytes"],
                    "candidate_retained_bytes": candidate["snapshots"]["after_packet_release"]["trackedLiveAllocationBytes"],
                    "baseline_retained_through_idle_and_flush": case in AFFECTED_CASES,
                    "candidate_freed_before_reuse_or_flush": True,
                    "recovery_and_destruction_free_input": True,
                    "pixel_bytes_and_all_frame_metadata_match": True,
                    "errors_and_timestamp_output_match": True,
                    "pixels_equal_fixture_after_decoder_destruction": True,
                    "baseline_receipt_sha256": file_sha(self.output / "receipts/baseline" / name),
                    "candidate_receipt_sha256": file_sha(self.output / "receipts/candidate" / name),
                })
        save(self.output / "summary.json", summary)
        if (ROOT / DECODER).read_bytes() != self.candidate:
            raise ValueError("Root decoder source changed during qualification")
        self.manifest["complete"] = True
        self.manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
        self.manifest["comparison_count"] = len(summary)
        self.manifest["summary_sha256"] = file_sha(self.output / "summary.json")
        self.checkpoint()
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Actual CoreVideo/VideoToolbox qualification requires macOS; no substitute platform types are used")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    study = Study(args)
    study.prepare()
    for variant in VARIANTS:
        study.run(variant)
    study.summarize()


if __name__ == "__main__":
    main()
