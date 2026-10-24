#!/usr/bin/env python3
"""Measure exact production auxiliary-input font ownership on native macOS."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
EXECUTOR = "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"
FULL_SOURCES = [DEMUXER, EXECUTOR,
    "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift"]
EXTRACTIONS = [
    ("Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift",
     "struct PresentationError:", "\nfunc checkOSStatus("),
    ("Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift",
     "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")]
C_SOURCES = ["Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
VARIANTS = ("baseline", "candidate")
SCENARIOS = {"primary": [True], "auxiliary": [False],
             "primary-plus-one": [True, False], "primary-plus-two": [True, False, False]}
CASES = {"none", "real-font", "synthetic-1mib", "synthetic-16mib", "synthetic-32mib"}
METRICS = ["owned_swift_font_payload_bytes", "retained_allocator_delta_bytes",
           "released_allocator_delta_bytes", "open_wall_nanoseconds", "open_cpu_nanoseconds"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def source_inputs() -> dict:
    result = {}
    for variant in VARIANTS:
        result[variant] = {}
        for path in FULL_SOURCES + C_SOURCES + [item[0] for item in EXTRACTIONS]:
            result[variant][path] = (subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                                     if variant == "baseline" else (ROOT / path).read_bytes())
    for path in result["baseline"]:
        if path not in {DEMUXER, EXECUTOR} and result["baseline"][path] != result["candidate"][path]:
            raise ValueError(f"Shared dependency changed; review and requalify: {path}")
    for path, begin, end in EXTRACTIONS:
        text = result["baseline"][path].decode()
        if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) >= text.index(end):
            raise ValueError(f"Support declaration boundaries changed: {path}")
    return result


class Study:
    def __init__(self, args, inputs):
        self.args, self.inputs = args, inputs
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands, self.rows, self.semantic = [], [], {}
        self.receipt = {
            "schema_version": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE, "platform": platform.platform(), "machine": platform.machine(),
            "source_hashes": {variant: {path: sha(data) for path, data in files.items()}
                              for variant, files in inputs.items()},
            "harness_hashes": {p.name: sha(p.read_bytes()) for p in sorted(HERE.iterdir())
                               if p.is_file() and p.suffix in {".py", ".swift", ".h"}},
            "pairs": args.pairs, "scenarios": SCENARIOS, "complete": False,
            "measurement": {
                "metric": "malloc_zone_statistics(NULL).size_in_use",
                "scope": "live allocator delta for all open input executors, demuxers and owned media info",
                "not_measured": ["whole-player RSS", "frame rate", "libass font parsing/cache memory"],
                "warmup": "three input executors on the no-font A/V/subtitle fixture",
                "open_completion": "synchronize the actual executor serial queue after its open semaphore",
                "semantic_checks": "separate inputs opened after measured inputs are destroyed",
                "native_extradata": "still owned by each AVFormatContext; inventory is diagnostic, not a saving",
                "order": "fresh processes, alternating baseline/candidate AB/BA, no removed samples"},
            "compiled_sources": {}, "binaries": {}, "extractions": []}
        manifest = args.fixtures.resolve() / "manifest.json"
        self.cases = json.loads(manifest.read_text())
        if {c["name"] for c in self.cases} != CASES or len(self.cases) != len(CASES):
            raise ValueError("Expected exactly the five declared fixtures")
        for case in self.cases:
            path = manifest.parent / case["filename"]
            if (not path.resolve().is_relative_to(manifest.parent)
                    or path.stat().st_size != case["size_bytes"]
                    or sha(path.read_bytes()) != case["sha256"]):
                raise ValueError(f"Fixture hash/path mismatch: {case['name']}")
            if sum(a["bytes"] for a in case["attachments"]) != case["font_payload_bytes"]:
                raise ValueError("Fixture font-byte inventory mismatch")
            case["path"] = str(path)
        self.warmup = next(c["path"] for c in self.cases if c["name"] == "none")
        save(self.output / "fixtures.json", self.cases)
        shutil.copyfile(manifest, self.output / "fixture-manifest.json")
        shutil.copyfile(manifest.parent / "commands.json", self.output / "fixture-commands.json")
        self.executables = {}
        save(self.output / "manifest.json", self.receipt)

    def command(self, argv, name, *, timeout=600):
        argv = [str(value) for value in argv]
        begin = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=timeout)
        log = self.output / "logs" / (name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_bytes(result.stdout + result.stderr)
        self.commands.append({"argv": argv, "returncode": result.returncode,
                              "seconds": time.monotonic() - begin,
                              "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
                              "log": str(log.relative_to(self.output)), "log_sha256": sha(log.read_bytes())})
        save(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n"
                               + (result.stdout + result.stderr).decode(errors="replace")[-10000:])
        return result.stdout

    def stage(self, name, data):
        path = self.output / "sources" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def prepare(self):
        self.receipt["candidate_revision"] = self.command(["git", "rev-parse", "HEAD"], "revision").decode().strip()
        self.receipt["candidate_worktree_status"] = self.command(["git", "status", "--porcelain"], "status").decode()
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "ancestry")
        compiler = self.args.swiftc or self.command(["xcrun", "--find", "swiftc"], "compiler").decode().strip()
        self.receipt["compiler"] = self.command([compiler, "--version"], "compiler-version").decode()
        self.receipt["macos"] = self.command(["sw_vers"], "macos").decode()
        self.receipt["hardware"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "hardware").decode()
        sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").decode().strip()
        prefix = self.args.ffmpeg_prefix.resolve(strict=True)
        module = self.output / "sources/CFFmpeg"
        for path in C_SOURCES:
            self.stage(path.removeprefix("Sources/"), self.inputs["candidate"][path])
        probe = self.output / "sources/HeapProbe"
        self.stage("HeapProbe/HeapProbe.h", (HERE / "HeapProbe.h").read_bytes())
        self.stage("HeapProbe/module.modulemap", b'module HeapProbe { header "HeapProbe.h" export * }\n')
        driver = self.stage("Harness.swift", (HERE / "Harness.swift").read_bytes())
        for name in ("run.py", "generate-fixtures.py", "DemuxerProbe.swift", "ExecutorProbe.swift"):
            self.stage(name, (HERE / name).read_bytes())
        flags = ["-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                 "-target", platform.machine() + "-apple-macosx26.0", "-sdk", sdk,
                 "-I", module, "-I", probe, "-Xcc", "-I" + str(prefix / "include"),
                 "-L", prefix / "lib", "-Xlinker", "-rpath", "-Xlinker", prefix / "lib",
                 "-module-cache-path", self.output / "module-cache",
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.receipt["flags"] = list(map(str, flags))
        self.receipt["native_sdk_manifest_sha256"] = sha((ROOT / "BuildInputs/native-sdk.json").read_bytes())
        self.receipt["ffmpeg_libraries"] = {p.name: sha(p.read_bytes())
            for p in sorted((prefix / "lib").glob("*.dylib")) if not p.is_symlink()}
        save(self.output / "manifest.json", self.receipt)
        for variant in VARIANTS:
            sources = []
            for path in FULL_SOURCES:
                data = self.inputs[variant][path]
                self.stage(f"{variant}/original/{Path(path).name}", data)
                probe_name = {DEMUXER: "DemuxerProbe.swift", EXECUTOR: "ExecutorProbe.swift"}.get(path)
                if probe_name:
                    data += b"\n" + (HERE / probe_name).read_bytes()
                source = self.stage(f"{variant}/compiled/{Path(path).name}", data)
                sources.append(source)
                self.receipt["compiled_sources"][str(source.relative_to(self.output))] = {
                    "sha256": sha(data), "production_file": path,
                    "transformation": "append read-only " + probe_name if probe_name else "none"}
            declarations = [b"import Foundation\n"]
            for path, begin, end in EXTRACTIONS:
                text = self.inputs[variant][path].decode()
                data = text[text.index(begin):text.index(end)].encode()
                declarations.append(data)
                self.receipt["extractions"].append({"variant": variant, "path": path,
                    "begin": begin, "end": end, "sha256": sha(data)})
            sources.append(self.stage(f"{variant}/compiled/SupportDeclarations.swift", b"\n".join(declarations)))
            save(self.output / "manifest.json", self.receipt)
            for configuration, optimization in (("debug", ["-Onone"]), ("release", ["-O", "-whole-module-optimization"])):
                build = self.output / "build" / configuration / variant
                build.mkdir(parents=True)
                library = build / "libAuxiliaryFontInputs.dylib"
                print(f"Build {configuration}/{variant}", flush=True)
                self.command([compiler, *optimization, *flags, "-emit-library", "-emit-module", "-enable-testing",
                              "-module-name", "AuxiliaryFontInputs", "-emit-module-path", build / "AuxiliaryFontInputs.swiftmodule",
                              "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryFontInputs.dylib",
                              *sources, "-o", library], f"{configuration}-{variant}-library")
                binary = build / "font-payload-benchmark"
                defines = ["-D", "CANDIDATE"] if variant == "candidate" else []
                self.command([compiler, *optimization, *flags, *defines,
                              "-I", build, "-L", build, "-lAuxiliaryFontInputs",
                              "-Xlinker", "-rpath", "-Xlinker", build, driver, "-o", binary],
                             f"{configuration}-{variant}-driver")
                self.executables[(configuration, variant)] = binary
                self.receipt["binaries"][configuration + "/" + variant] = {
                    "executable_sha256": sha(binary.read_bytes()), "library_sha256": sha(library.read_bytes()),
                    "linked_libraries": self.command(["otool", "-L", library], f"{configuration}-{variant}-linkage").decode()}
                save(self.output / "manifest.json", self.receipt)
        save(self.output / "manifest.json", self.receipt)

    def sample(self, configuration, variant, case, scenario, pair, order):
        name = f"{configuration}-{case['name']}-{scenario}-{pair}-{variant}"
        value = json.loads(self.command([self.executables[(configuration, variant)], case["path"], self.warmup,
                                        scenario, case["font_payload_bytes"]], name))
        roles = SCENARIOS[scenario]
        expected_copies = sum(roles) if variant == "candidate" else len(roles)
        if (value["owned_swift_font_payload_bytes"] != case["font_payload_bytes"] * expected_copies
                or value["owned_swift_font_count"] != len(case["attachments"]) * expected_copies
                or value["input_count"] != len(roles) or value["primary_count"] != sum(roles)):
            raise ValueError("Owned payload contract mismatch")
        verification = value.pop("verification")
        if (not verification["projection_survives_input_close"] or not verification["input_destruction_verified"]
                or len(verification["media_info"]) != len(roles)
                or len(verification["inputs"]) != len(roles)):
            raise ValueError("Incomplete lifetime/semantic verification")
        all_native_bytes = 0
        semantic_info = []
        for role, media, native in zip(roles, verification["media_info"], verification["inputs"], strict=True):
            expected_fonts = ([a | {"supported_font": True} for a in case["attachments"]]
                              if variant == "baseline" or role else [])
            if media["attachments"] != expected_fonts:
                raise ValueError("Font bytes, names, order or admission changed")
            semantic_info.append({key: item for key, item in media.items() if key != "attachments"})
            indices = {s["index"] for s in media["streams"] if s["kind"] == "attachment"}
            fonts = [s for s in native["native_streams"] if s["index"] in indices]
            inventory = [{"filename": f["filename"], "mime_type": f["mime_type"],
                          "bytes": f["extradata_bytes"], "sha256": f["extradata_sha256"]} for f in fonts]
            if inventory != case["attachments"]:
                raise ValueError("Native font extradata changed or disappeared")
            all_native_bytes += sum(f["extradata_bytes"] for f in fonts)
            if native["open_was_main_thread"]:
                raise ValueError("Executor opened on the main thread")
            if not {"video", "audio", "subtitle"} <= {s["kind"] for s in media["streams"]}:
                raise ValueError("Fixture must include actual video, audio and subtitle streams")
        normalized = {"media_info": semantic_info, "inputs": verification["inputs"],
                      "input_destruction_verified": True, "projection_survives_input_close": True}
        key = (case["name"], scenario)
        digest = sha(canonical(normalized))
        previous = self.semantic.setdefault(key, digest)
        if digest != previous:
            raise ValueError(f"Metadata, native extradata, codec parameters or packets changed: {key}")
        verification_name = f"{configuration}-{case['name']}-{scenario}-{variant}.json"
        destination = self.output / "verification" / verification_name
        if destination.exists() and json.loads(destination.read_text()) != verification:
            raise ValueError("Verification changed between repeated observations")
        save(destination, verification)
        value.update(configuration=configuration, variant=variant, case=case["name"], pair=pair,
                     process_order=order, semantic_sha256=digest,
                     verification_file=str(destination.relative_to(self.output)),
                     native_font_extradata_bytes=all_native_bytes)
        if all_native_bytes != case["font_payload_bytes"] * len(roles):
            raise ValueError("Native font-byte accounting mismatch")
        self.rows.append(value)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
        return value

    def run(self):
        for case in self.cases:
            for scenario in SCENARIOS:
                print(f"Verify debug {case['name']}/{scenario}", flush=True)
                for variant in VARIANTS:
                    self.sample("debug", variant, case, scenario, 0, list(VARIANTS))
                for pair in range(self.args.pairs):
                    order = list(VARIANTS if pair % 2 == 0 else VARIANTS[::-1])
                    for variant in order:
                        self.sample("release", variant, case, scenario, pair, order)
                print(f"Measured {case['name']}/{scenario}: {self.args.pairs} pairs", flush=True)
        summaries = []
        for case in self.cases:
            for scenario in SCENARIOS:
                rows = [r for r in self.rows if r["configuration"] == "release"
                        and r["case"] == case["name"] and r["scenario"] == scenario]
                metrics = {}
                for metric in METRICS:
                    samples = {v: [r[metric] for r in rows if r["variant"] == v] for v in VARIANTS}
                    before, after = (statistics.median(samples[v]) for v in VARIANTS)
                    metrics[metric] = {"baseline_median": before, "candidate_median": after,
                        "difference": after - before, "change_percent": (after / before - 1) * 100 if before else None,
                        "baseline_range": [min(samples["baseline"]), max(samples["baseline"])],
                        "candidate_range": [min(samples["candidate"]), max(samples["candidate"])]}
                summaries.append({"case": case["name"], "scenario": scenario,
                    "font_payload_bytes_per_input": case["font_payload_bytes"], "pairs": self.args.pairs,
                    "native_font_extradata_bytes_each_variant": case["font_payload_bytes"] * len(SCENARIOS[scenario]),
                    "metrics": metrics})
        expected = len(CASES) * len(SCENARIOS) * (2 + 2 * self.args.pairs)
        if len(self.rows) != expected:
            raise ValueError("Incomplete observation matrix")
        self.receipt.update(complete=True, observation_count=len(self.rows),
                            debug_observations=len(CASES) * len(SCENARIOS) * 2,
                            release_observations=len(CASES) * len(SCENARIOS) * 2 * self.args.pairs)
        save(self.output / "manifest.json", self.receipt)
        save(self.output / "summary.json", summaries)
        save(self.output / "parity.json", {"complete": True, "matched_scenarios": len(self.semantic),
              "semantic_sha256": {case + "/" + scenario: digest for (case, scenario), digest in self.semantic.items()}})
        print(json.dumps(summaries, indent=2), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/Cellar/ffmpeg/8.1.2-illiquid1"))
    parser.add_argument("--validate-inputs", action="store_true")
    args = parser.parse_args()
    inputs = source_inputs()
    if args.validate_inputs:
        print(json.dumps({"baseline": BASELINE, "source_inputs_valid": True,
                          "full_production_files": len(FULL_SOURCES), "support_declarations": len(EXTRACTIONS)}))
        return
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Native measurement requires Apple Silicon macOS and the pinned SDK")
    if not args.fixtures or not args.output or args.pairs < 2 or args.pairs % 2:
        parser.error("--fixtures, --output and an even number of at least two pairs are required")
    study = Study(args, inputs)
    study.prepare()
    study.run()


if __name__ == "__main__":
    main()
