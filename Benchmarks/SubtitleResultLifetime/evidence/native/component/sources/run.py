#!/usr/bin/env python3
"""Compare exact-source SubtitleDecoder output ownership on native macOS.

This is a retained-allocation experiment, not an RSS or decoding-speed benchmark.
Only --output is required after the repository's native SDK is installed.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
DECODER = "Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift"
FULL_SUPPORT = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift",
    "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift",
    "Sources/IlliquidNativePlayback/Subtitles/PGSSubtitlePresentation.swift",
    "Sources/CFFmpeg/module.modulemap",
    "Sources/CFFmpeg/include/ffmpeg_shim.h",
]
# Each extracted support declaration remains byte-for-byte production code.
# No fake platform types, replacement decoders, or edited production methods.
EXTRACTED_SUPPORT = [
    ("Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift", None, "struct FFmpegMediaInfo:"),
    ("Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift",
     "final class OwnedCodecParameters:", "/// Sole owner of AVFormatContext"),
    ("Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift",
     "struct PresentationError:", "func checkOSStatus("),
    ("Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift",
     "struct ASSRenderedRegion:", "struct ASSRenderResult:"),
]
CASES = ["text", "pgs_tiny", "pgs_1080p", "pgs_large_cropped", "pgs_display_rejected",
         "pgs_budget_rejected", "pgs_malformed", "dvb_tiny"]
TARGET_CASES = set(CASES) - {"pgs_malformed"}
VARIANTS = ("baseline", "candidate")
CONFIGURATIONS = {"debug": "-Onone", "release": "-O"}
SNAPSHOT_FIELDS = ("hasOutput", "rectangleCount", "indexedPayloadBytes", "textPayloadBytes",
                   "liveMallocBytes", "liveAllocations")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def source_inputs() -> tuple[dict[str, bytes], dict]:
    manifest = json.loads((HERE / "baseline/manifest.json").read_text())
    if manifest["revision"] != BASELINE:
        raise ValueError("Frozen baseline revision changed")
    frozen = (HERE / "baseline/SubtitleDecoder.swift").read_bytes()
    if sha(frozen) != manifest["source_sha256"][DECODER]:
        raise ValueError("Frozen complete decoder does not match its recorded hash")
    inputs = {}
    for path in FULL_SUPPORT + [item[0] for item in EXTRACTED_SUPPORT]:
        data = (ROOT / path).read_bytes()
        if sha(data) != manifest["source_sha256"][path]:
            raise ValueError(f"Shared source changed: {path}; explicitly review and requalify")
        inputs[path] = data
    inputs["baseline/SubtitleDecoder.swift"] = frozen
    inputs["candidate/SubtitleDecoder.swift"] = (ROOT / DECODER).read_bytes()
    for name in ("Driver.swift", "ProbeExtension.swift", "LifetimeProbe.h", "run.py", "baseline/manifest.json"):
        inputs["harness/" + name] = (HERE / name).read_bytes()
    return inputs, manifest


class Study:
    def __init__(self, args, inputs, frozen):
        self.args, self.inputs, self.frozen = args, inputs, frozen
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.receipt = {
            "schema_version": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE, "platform": platform.platform(),
            "machine": platform.machine(), "mode": "exact-source-live-transient-output-allocations",
            "source_hashes": {path: sha(data) for path, data in inputs.items()},
            "extractions": [], "binaries": {}, "observations": [], "complete": False,
            "measurement_boundary": {
                "included": "live malloc block sizes reachable from the original AVSubtitle output",
                "excluded": ["persistent result header", "codec-private caches", "Swift event Data",
                             "process RSS", "allocator free-page retention", "whole-player footprint"],
                "idle_ms": 50, "no_packet_during_idle": True,
                "malloc_size_only_for_live_base_pointers": True,
            },
        }

    def command(self, argv, name):
        argv = [str(value) for value in argv]
        begin = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        path = self.output / "logs" / (name + ".log")
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(result.stdout + result.stderr)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - begin,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
                              "log": str(path.relative_to(self.output)), "log_sha256": sha(path.read_bytes())})
        self.save()
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n"
                               + (result.stdout + result.stderr).decode(errors="replace")[-8000:])
        return result.stdout

    def save(self):
        write_json(self.output / "receipt.json", self.receipt)
        write_json(self.output / "commands.json", self.commands)

    def stage(self, name, data):
        path = self.output / "sources" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def prepare(self):
        self.receipt["candidate_revision"] = self.command(["git", "rev-parse", "HEAD"], "head").decode().strip()
        self.receipt["worktree_status"] = self.command(["git", "status", "--porcelain"], "status").decode()
        historical = self.command(["git", "show", f"{BASELINE}:{DECODER}"], "baseline-source")
        if historical != self.inputs["baseline/SubtitleDecoder.swift"]:
            raise ValueError("Frozen baseline does not match the pinned Git commit")
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestry")
        self.receipt["compiler"] = self.command([self.args.swiftc, "--version"], "swift-version").decode().strip()
        self.receipt["macos"] = self.command(["sw_vers"], "macos-version").decode().strip()
        self.receipt["hardware"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "hardware").decode().strip()
        sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").decode().strip()
        prefix = self.args.ffmpeg_prefix.resolve()
        module = self.output / "sources/CFFmpeg"
        sources = []
        for path in FULL_SUPPORT:
            if path.startswith("Sources/CFFmpeg/"):
                self.stage(path.removeprefix("Sources/"), self.inputs[path])
            else:
                sources.append(self.stage("shared/" + Path(path).name, self.inputs[path]))
        parts = [b"import CFFmpeg\nimport CoreGraphics\nimport Foundation\n"]
        for path, begin, end in EXTRACTED_SUPPORT:
            text = self.inputs[path].decode()
            if (begin and text.count(begin) != 1) or text.count(end) != 1:
                raise ValueError(f"Declaration boundary changed: {path}")
            first = text.index(begin) if begin else 0
            selected = text[first:text.index(end)].encode()
            parts.append(selected)
            self.receipt["extractions"].append({"path": path, "begin": begin, "end": end,
                                                "extracted_sha256": sha(selected)})
        sources.append(self.stage("shared/SupportDeclarations.swift", b"\n".join(parts)))
        probe = self.output / "sources/LifetimeProbe"
        self.stage("LifetimeProbe/LifetimeProbe.h", self.inputs["harness/LifetimeProbe.h"])
        self.stage("LifetimeProbe/module.modulemap", b'module LifetimeProbe { header "LifetimeProbe.h" export * }\n')
        driver = self.stage("Driver.swift", self.inputs["harness/Driver.swift"])
        for name in ("run.py", "ProbeExtension.swift", "baseline/manifest.json"):
            self.stage(name, self.inputs["harness/" + name])
        flags = ["-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                 "-target", platform.machine() + "-apple-macosx26.0", "-sdk", sdk,
                 "-I", str(module), "-I", str(probe),
                 "-Xcc", "-I" + str(module / "include"),
                 "-Xcc", "-I" + str(prefix / "include"), "-L", str(prefix / "lib"),
                 "-Xlinker", "-rpath", "-Xlinker", str(prefix / "lib"),
                 "-module-cache-path", str(self.output / "module-cache")]
        self.receipt["common_flags"] = flags
        self.receipt["sdk_manifest_sha256"] = sha((ROOT / "BuildInputs/native-sdk.json").read_bytes())
        self.executables = {}
        for configuration, optimization in CONFIGURATIONS.items():
            for variant in VARIANTS:
                original = self.inputs[f"{variant}/SubtitleDecoder.swift"]
                self.stage(variant + "/SubtitleDecoder.original.swift", original)
                observed = self.stage(variant + "/SubtitleDecoder.swift",
                    original + b"\n" + self.inputs["harness/ProbeExtension.swift"])
                binary = self.output / "build" / configuration / variant
                binary.parent.mkdir(parents=True, exist_ok=True)
                print(f"Compile {configuration}/{variant}", flush=True)
                self.command([self.args.swiftc, optimization, *flags, *sources, observed, driver, "-o", binary],
                             configuration + "-" + variant + "-compile")
                key = configuration + "/" + variant
                self.executables[key] = binary
                self.receipt["binaries"][key] = sha(binary.read_bytes())
        self.receipt["linked_dependencies"] = self.command(
            ["otool", "-L", self.executables["release/candidate"]], "dependencies").decode()
        self.receipt["ffmpeg_libraries"] = {
            path.name: sha(path.read_bytes()) for path in sorted((prefix / "lib").glob("*.dylib"))
            if not path.is_symlink()
        }
        self.save()

    def observe(self):
        summary = []
        baseline_failures = []
        for configuration in CONFIGURATIONS:
            for case_index, case in enumerate(CASES):
                values, output_paths = {}, {}
                order = VARIANTS if case_index % 2 == 0 else VARIANTS[::-1]
                for variant in order:
                    name = configuration + "-" + case + "-" + variant
                    output = self.output / "outputs" / (name + ".bin")
                    output.parent.mkdir(exist_ok=True)
                    raw = self.command([self.executables[configuration + "/" + variant], case, output], name)
                    value = json.loads(raw)
                    value.update(configuration=configuration, variant=variant, process_order=list(order))
                    write_json(self.output / "observations" / (name + ".json"), value)
                    self.receipt["observations"].append(name)
                    values[variant], output_paths[variant] = value, output
                baseline, candidate = values["baseline"], values["candidate"]
                for field in ("workload", "ffmpegVersion", "packetSHA256", "packetBytes", "idleMilliseconds", "semantic"):
                    if baseline[field] != candidate[field]:
                        raise ValueError(f"Output/fixture mismatch: {configuration}/{case}/{field}")
                before, after = (output_paths[v].read_bytes() for v in VARIANTS)
                if before != after:
                    raise ValueError(f"Complete event byte mismatch: {configuration}/{case}")
                for variant, data in (("baseline", before), ("candidate", after)):
                    path = output_paths[variant]
                    path.with_suffix(".bin.gz").write_bytes(gzip.compress(data, compresslevel=9, mtime=0))
                    path.unlink()
                for stage, snapshot in candidate["snapshots"].items():
                    if any(snapshot[field] for field in SNAPSHOT_FIELDS):
                        raise ValueError(f"Candidate retains transient output: {configuration}/{case}/{stage}")
                for stage in ("initial", "after_flush", "final"):
                    if any(baseline["snapshots"][stage][field] for field in SNAPSHOT_FIELDS):
                        raise ValueError(f"Baseline control retains output: {configuration}/{case}/{stage}")
                for stage in baseline["snapshots"]:
                    if baseline["snapshots"][stage]["eventBudgetBytes"] != candidate["snapshots"][stage]["eventBudgetBytes"]:
                        raise ValueError(f"Application event budget mismatch: {configuration}/{case}/{stage}")
                first = baseline["snapshots"]["after_return"]
                if case in TARGET_CASES:
                    if not first["hasOutput"] or first["liveMallocBytes"] <= 0 or first["liveAllocations"] <= 0:
                        raise ValueError(f"Baseline does not reproduce retained-output defect: {configuration}/{case}")
                    if baseline["snapshots"]["after_idle"] != first:
                        raise ValueError("Baseline idle observation changed")
                    baseline_failures.append({"configuration": configuration, "workload": case,
                        "assertion": "liveMallocBytes == 0 after decode return", "actual": first["liveMallocBytes"],
                        "expected_failure_observed": True})
                elif any(first[field] for field in SNAPSHOT_FIELDS):
                    raise ValueError("Malformed-before-decode control unexpectedly retained output")
                summary.append({"configuration": configuration, "workload": case,
                    "baseline_after_return": first, "candidate_after_return": candidate["snapshots"]["after_return"],
                    "complete_output_bytes": len(before), "complete_output_sha256": sha(before),
                    "exact_output_match": True, "all_candidate_stages_empty": True,
                    "initial_flush_and_final_controls_empty": True})
                write_json(self.output / "summary.json", summary)
                write_json(self.output / "baseline-regression-demonstration.json", baseline_failures)
                self.save()
                print(f"{configuration}/{case}: {first['liveMallocBytes']} -> 0 live result-owned malloc bytes; exact events match", flush=True)
        for key, binary in self.executables.items():
            if sha(binary.read_bytes()) != self.receipt["binaries"][key]:
                raise ValueError("Measured binary changed: " + key)
        current, _ = source_inputs()
        if current != self.inputs:
            raise ValueError("Source or harness changed during the study")
        self.receipt["complete"] = True
        self.receipt["completed_utc"] = datetime.now(timezone.utc).isoformat()
        self.save()
        write_json(self.output / "completion.json", {"complete": True, "configurations": list(CONFIGURATIONS),
            "workloads_per_configuration": len(CASES), "process_observations": len(summary) * 2,
            "exact_output_comparisons": len(summary), "baseline_lifetime_assertion_failures": len(baseline_failures),
            "all_candidate_stages_empty": True, "source_and_binary_hashes_unchanged": True,
            "retained_transient_output_only": True, "timings_or_RSS_measured": False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--validate-inputs", action="store_true", help="Verify frozen/shared source hashes without compiling")
    args = parser.parse_args()
    inputs, frozen = source_inputs()
    if args.validate_inputs:
        print(json.dumps({"valid": True, "baseline_revision": BASELINE, "inputs": len(inputs)}, sort_keys=True))
        return
    if args.output is None:
        parser.error("--output is required for native measurement")
    if platform.system() != "Darwin":
        parser.error("Requires native macOS, real CoreMedia and the pinned FFmpeg SDK")
    study = Study(args, inputs, frozen)
    try:
        study.prepare()
        study.observe()
    finally:
        study.save()


if __name__ == "__main__":
    main()
