#!/usr/bin/env python3
"""Measure redundant Swift attachment copies in native auxiliary input topologies.

Requires macOS, Swift 6.1+, and a local FFmpeg prefix. Each observation opens
one primary reader plus the selected auxiliary readers in a fresh process.
There is no timing calibration or performance threshold. All samples, paired
differences, source snapshots, hashes, and command receipts are retained.
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
EXECUTOR = "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"
FULL_SOURCES = [
    DEMUXER, EXECUTOR,
    "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
]
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
BITMAP = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
C_SOURCES = ["Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
# These source snapshots make the real opt-out decisions reviewable. They are
# not compiled into this component harness, which opens equivalent reader counts
# without running a MediaSession, rendering thumbnails, or starting a UI.
CALLSITE_SOURCES = [
    "Sources/IlliquidNativePlayback/Media/MediaSession.swift",
    "Sources/IlliquidNativePlayback/Media/NativeFrameStepReader.swift",
    "Sources/IlliquidNativePlayback/Media/NativeThumbnailMetadataReader.swift",
    "Sources/IlliquidNativePlayback/Media/NativeTimelineThumbnailGenerator.swift",
    "Sources/IlliquidNativePlayback/Subtitles/PreparedExternalSubtitle.swift",
]
SUPPORT = ["Harness.swift", "Heap.c", "CAuxiliaryHeap/Heap.h", "CAuxiliaryHeap/module.modulemap"]
LIBRARIES = ["avformat", "avfilter", "avcodec", "avutil", "swresample", "swscale"]
VARIANTS = ("baseline", "candidate")
SCENARIOS = (
    ("primary-only", 0, 0),
    ("subtitle", 1, 0),
    ("subtitle+audio-delay", 2, 0),
    ("primary+thumbnail-reader", 0, 1),
)
BYTE_METRICS = (
    "primary_font_bytes", "auxiliary_font_bytes",
    "heap_before_bytes", "heap_retained_bytes", "heap_delta_bytes",
    "resident_before_bytes", "resident_retained_bytes", "resident_delta_bytes",
)
METRICS = BYTE_METRICS + ("wall_seconds", "cpu_seconds")


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Extraction markers changed: {start!r} / {end!r}")
    begin, finish = source.index(start), source.index(end)
    if begin >= finish:
        raise ValueError("Extraction markers are out of order")
    result = source[begin:finish]
    if result.count("{") != result.count("}"):
        raise ValueError("Extracted declarations have unbalanced braces")
    return result


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        self.env = os.environ.copy()
        self.commands = []
        self.sources = {}
        self.parity = {}
        self.measurements = []
        self.exes = {}
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        # Preserve argv[0] as swiftc; resolving the swift-driver symlink changes
        # how the Swift driver interprets its arguments.
        compiler = args.swiftc or self.command(["xcrun", "--find", "swiftc"]).strip()
        self.swiftc = Path(compiler).absolute()
        if not self.swiftc.is_file():
            raise ValueError(f"Missing Swift compiler: {self.swiftc}")
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        if not Path(self.sdk).is_dir():
            raise ValueError(f"Missing macOS SDK: {self.sdk}")
        self.fixtures = self.load_fixtures(args.fixtures.resolve(strict=True))
        self.record = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "compiler_path": str(self.swiftc), "compiler_sha256": file_sha(self.swiftc),
            "sdk_path": self.sdk,
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
            "ffmpeg_prefix": str(self.prefix),
            "protocol": {key: str(value) if isinstance(value, Path) else value
                         for key, value in vars(args).items()},
            "scenarios": [{"name": name, "aux_executor_count": executors, "aux_direct_count": direct}
                          for name, executors, direct in SCENARIOS],
            "sources": self.sources, "binaries": {}, "native_libraries": {},
            "runner_sha256": file_sha(Path(__file__)),
            "support_sha256": {path: file_sha(HERE / path) for path in SUPPORT},
        }
        self.record["system"] = self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"])
        (self.output / "runner.snapshot.py").write_bytes(Path(__file__).read_bytes())
        for path in SUPPORT:
            destination = self.output / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(HERE / path, destination)
        write_json(self.output / "manifest.json", self.record)

    def command(self, argv, *, timeout: int = 600) -> str:
        argv = [str(value) for value in argv]
        index = len(self.commands)
        prefix = f"logs/{index:04d}"
        started = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                    timeout=timeout)
            stdout, stderr = result.stdout, result.stderr
            returncode = result.returncode
            failure = None
        except subprocess.TimeoutExpired as error:
            stdout, stderr = error.stdout or b"", error.stderr or b""
            returncode = None
            failure = f"Command timed out after {timeout} seconds"
        (self.output / f"{prefix}.stdout.log").write_bytes(stdout)
        (self.output / f"{prefix}.stderr.log").write_bytes(stderr)
        record = {"argv": argv, "returncode": returncode,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout_sha256": sha(stdout), "stderr_sha256": sha(stderr),
                  "stdout_log": f"{prefix}.stdout.log", "stderr_log": f"{prefix}.stderr.log"}
        if failure:
            record["error"] = failure
        self.commands.append(record)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True, allow_nan=False) + "\n")
        if returncode != 0:
            raise RuntimeError(f"{failure or f'Command failed ({returncode})'}: {argv}\n"
                               f"{stdout[-3000:].decode(errors='replace')}\n"
                               f"{stderr[-10000:].decode(errors='replace')}")
        return stdout.decode("utf-8")

    def load_fixtures(self, directory: Path) -> list[dict]:
        manifest = directory / "manifest.json"
        data = json.loads(manifest.read_text())
        if not isinstance(data, list) or not data:
            raise ValueError("Fixture manifest must be a nonempty array")
        names = set()
        for case in data:
            if case["name"] in names:
                raise ValueError("Duplicate fixture name")
            names.add(case["name"])
            path = (directory / case["filename"]).resolve(strict=True)
            if not path.is_relative_to(directory) or not path.is_file():
                raise ValueError("Fixture must be a file inside its manifest directory")
            for key in ("font_payload_bytes", "font_payload_count"):
                if type(case[key]) is not int or case[key] < 0:
                    raise ValueError(f"Invalid fixture {key}")
            if file_sha(path) != case["sha256"] or path.stat().st_size != case["size_bytes"]:
                raise ValueError(f"Fixture content/size mismatch: {case['name']}")
            attachments = case["attachments"]
            if not isinstance(attachments, list):
                raise ValueError("Fixture attachments must be an array")
            accepted = [entry for entry in attachments if entry["supported_font"]]
            if len(accepted) != case["font_payload_count"] or sum(entry["size_bytes"] for entry in accepted) != case["font_payload_bytes"]:
                raise ValueError("Fixture font inventory disagrees with totals")
            if len(accepted) > 64 or case["font_payload_bytes"] > 64 * 1024 * 1024 or any(entry["size_bytes"] > 16 * 1024 * 1024 for entry in accepted):
                raise ValueError("Benchmark fixtures must stay inside existing font limits")
            for entry in attachments:
                payload = (directory / entry["payload_path"]).resolve(strict=True)
                if not payload.is_relative_to(directory) or not payload.is_file():
                    raise ValueError("Attachment payload must be inside the fixture directory")
                if file_sha(payload) != entry["sha256"] or payload.stat().st_size != entry["size_bytes"]:
                    raise ValueError("Attachment payload hash/size mismatch")
            case["path"] = str(path)
        if names != {"none", "real-font", "fonts-8mib", "fonts-32mib"}:
            raise ValueError(f"Expected the complete four-fixture set; got {sorted(names)}")
        expected = {"none": (0, 0), "fonts-8mib": (8 * 1024 * 1024, 1),
                    "fonts-32mib": (32 * 1024 * 1024, 4)}
        for case in data:
            if case["name"] in expected and (case["font_payload_bytes"], case["font_payload_count"]) != expected[case["name"]]:
                raise ValueError(f"Incorrect controlled payload inventory: {case['name']}")
            if case["name"] == "real-font":
                if case["font_payload_count"] != 1 or case["font_payload_bytes"] <= 0:
                    raise ValueError("Real-font control must contain one nonempty font")
                if case["attachments"][0]["sha256"] != file_sha(ROOT / "TestFixtures/Fonts/NotoSans-Regular.ttf"):
                    raise ValueError("Real-font control must use the bundled Noto Sans bytes")
        write_json(self.output / "fixtures.json", data)
        shutil.copyfile(manifest, self.output / "fixture-manifest.snapshot.json")
        for name in ("generation.json", "fixture-commands.jsonl", "integration-manifest.json"):
            if (directory / name).is_file():
                shutil.copyfile(directory / name, self.output / name)
        return data

    def source(self, variant: str, path: str) -> str:
        raw = ((ROOT / path).read_bytes() if variant == "candidate" else
               self.command(["git", "show", f"{BASELINE}:{path}"]).encode("utf-8"))
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        self.sources[f"{variant}:{path}"] = {"sha256": sha(raw), "bytes": len(raw)}
        return raw.decode("utf-8")

    def prepare(self) -> None:
        paths = FULL_SOURCES + [PRESENTATION, BITMAP] + C_SOURCES + CALLSITE_SOURCES
        original = {variant: {path: self.source(variant, path) for path in paths}
                    for variant in VARIANTS}
        self.record["integration_callsites_not_compiled"] = {
            "description": "Production call sites retained for review; these files are not compiled into the component harness",
            "sources": {variant: {path: self.sources[f"{variant}:{path}"]
                                  for path in CALLSITE_SOURCES} for variant in VARIANTS},
        }
        for path in set(FULL_SOURCES + C_SOURCES) - {DEMUXER, EXECUTOR}:
            if original["baseline"][path] != original["candidate"][path]:
                raise ValueError(f"Unrelated compiled production dependency changed: {path}")
        errors = {variant: extract(original[variant][PRESENTATION],
                                  "struct PresentationError:", "\nfunc checkOSStatus(")
                  for variant in VARIANTS}
        packets = {variant: extract(original[variant][BITMAP],
                                   "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
                   for variant in VARIANTS}
        if errors["baseline"] != errors["candidate"] or packets["baseline"] != packets["candidate"]:
            raise ValueError("Shared extracted error/packet declarations differ")

        module = self.output / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for path in C_SOURCES:
            target = module / Path(path).relative_to("Sources/CFFmpeg")
            target.write_bytes((self.output / "sources/candidate" / path).read_bytes())

        headers = {}
        for library in LIBRARIES:
            include = self.prefix / "include" / f"lib{library}"
            if not include.is_dir():
                raise ValueError(f"Missing FFmpeg headers: {include}")
            for path in sorted(include.rglob("*.h")):
                headers[str(path.relative_to(self.prefix / "include"))] = file_sha(path)
            resolved = (self.prefix / "lib" / f"lib{library}.dylib").resolve(strict=True)
            self.record["native_libraries"][library] = {"path": str(resolved), "sha256": file_sha(resolved)}
        write_json(self.output / "ffmpeg-headers.json", headers)
        self.record["ffmpeg_headers_manifest_sha256"] = file_sha(self.output / "ffmpeg-headers.json")

        heap = self.output / "Heap.o"
        self.command(["xcrun", "--sdk", "macosx", "clang", "-O2", "-isysroot", self.sdk,
                      "-c", self.output / "Heap.c", "-o", heap])
        self.record["heap_object_sha256"] = file_sha(heap)
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-sdk", self.sdk, "-I", str(module),
                 "-Xcc", "-I" + str(self.prefix / "include"),
                 "-L", str(self.prefix / "lib"), "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib"),
                 "-module-cache-path", str(self.output / "module-cache"),
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.record["compiler_flags"] = flags
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            inputs = []
            for path in FULL_SOURCES:
                target = directory / Path(path).name
                # Compile the complete, byte-identical production source. The
                # harness uses module APIs through @testable import; no private
                # access levels or production algorithms are rewritten.
                target.write_bytes((self.output / "sources" / variant / path).read_bytes())
                if file_sha(target) != self.sources[f"{variant}:{path}"]["sha256"]:
                    raise ValueError(f"Compiled source differs from snapshot: {path}")
                inputs.append(target)
            helpers = directory / "ExtractedDeclarations.swift"
            helpers.write_text("import Foundation\n\n" + errors[variant] + "\n" + packets[variant])
            inputs.append(helpers)
            self.record.setdefault("compiled_sources", {})[variant] = {
                str(path.relative_to(self.output)): file_sha(path) for path in inputs}
            library = directory / "libAuxiliaryAttachmentProjection.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AuxiliaryAttachmentProjection",
                          "-emit-module-path", directory / "AuxiliaryAttachmentProjection.swiftmodule",
                          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryAttachmentProjection.dylib",
                          *inputs, "-o", library])
            executable = directory / "auxiliary-attachment-benchmark"
            define = ["-D", "CANDIDATE"] if variant == "candidate" else []
            self.command([self.swiftc, *flags, *define,
                          "-I", self.output / "CAuxiliaryHeap", "-I", directory, "-L", directory,
                          "-lAuxiliaryAttachmentProjection", "-Xlinker", "-rpath", "-Xlinker", directory,
                          self.output / "Harness.swift", heap, "-o", executable])
            self.exes[variant] = executable
            self.record["binaries"][variant] = {
                "library_sha256": file_sha(library), "executable_sha256": file_sha(executable),
                "library_linkage": self.command(["otool", "-L", library]),
                "executable_linkage": self.command(["otool", "-L", executable]),
            }
        write_json(self.output / "manifest.json", self.record)

    def sample(self, variant: str, case: dict, scenario: tuple,
               pair: int, order_index: int) -> dict:
        name, executors, direct = scenario
        raw = self.command([self.exes[variant], case["path"], executors, direct,
                            case["font_payload_bytes"]])
        value = json.loads(raw)
        for key in BYTE_METRICS:
            if type(value.get(key)) is not int:
                raise ValueError(f"Invalid integer {key}")
            if not key.endswith("delta_bytes") and value[key] < 0:
                raise ValueError(f"Negative absolute byte measurement: {key}")
        for key in ("wall_seconds", "cpu_seconds"):
            if type(value.get(key)) not in (int, float) or not math.isfinite(value[key]) or value[key] < 0:
                raise ValueError(f"Invalid {key}")
        if value["wall_seconds"] <= 0:
            raise ValueError("Nonpositive wall duration")
        for metric in ("heap", "resident"):
            if value[f"{metric}_retained_bytes"] - value[f"{metric}_before_bytes"] != value[f"{metric}_delta_bytes"]:
                raise ValueError(f"Inconsistent {metric} delta")
        if value["resident_before_bytes"] == 0 or value["resident_retained_bytes"] == 0:
            raise ValueError("Resident-memory sampling failed")
        font_bytes = case["font_payload_bytes"]
        if value["primary_font_bytes"] != font_bytes:
            raise ValueError("Primary default reader did not preserve all font bytes")
        expected_aux = font_bytes * (executors + direct) if variant == "baseline" else 0
        if value["auxiliary_font_bytes"] != expected_aux:
            raise ValueError(f"Auxiliary owned-byte invariant failed: {case['name']} {name} {variant}")
        receipt = value.get("receipt")
        if not isinstance(receipt, dict) or not receipt:
            raise ValueError("Missing semantic receipt")
        if len(receipt.get("auxiliary_metadata", [])) != executors + direct or len(receipt.get("auxiliary_reads", [])) != executors + direct:
            raise ValueError("Harness opened the wrong auxiliary reader topology")
        expected_attachments = [
            {"filename": entry["filename"], "mime_type": entry["mime_type"],
             "bytes": entry["size_bytes"], "sha256": entry["sha256"], "supported_font": True}
            for entry in case["attachments"] if entry["supported_font"]
        ]
        if receipt.get("primary", {}).get("attachments") != expected_attachments:
            raise ValueError("Primary attachment hashes/metadata disagree with fixture manifest")
        key = f"{case['name']}/{name}"
        previous = self.parity.setdefault(key, receipt)
        if receipt != previous:
            raise ValueError(f"Semantic metadata/packet parity failed: {key} {variant}")
        value.update(variant=variant, case=case["name"], scenario=name,
                     aux_executor_count=executors, aux_direct_count=direct,
                     pair=pair, order_index=order_index)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
        return value

    def measure(self) -> dict:
        for case in self.fixtures:
            for scenario in SCENARIOS:
                for pair in range(self.args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    for order_index, variant in enumerate(order):
                        self.measurements.append(self.sample(variant, case, scenario, pair, order_index))
                print(json.dumps({"progress": "completed", "case": case["name"],
                                  "scenario": scenario[0], "pairs": self.args.pairs}), flush=True)
        expected = len(self.fixtures) * len(SCENARIOS) * self.args.pairs * 2
        if len(self.measurements) != expected:
            raise ValueError("Incomplete measurement matrix")
        write_json(self.output / "parity.json", self.parity)
        results = []
        for case in self.fixtures:
            for name, executors, direct in SCENARIOS:
                rows = [row for row in self.measurements
                        if row["case"] == case["name"] and row["scenario"] == name]
                result = {"case": case["name"], "scenario": name, "pairs": self.args.pairs,
                          "font_payload_bytes": case["font_payload_bytes"],
                          "aux_executor_count": executors, "aux_direct_count": direct}
                for metric in METRICS:
                    differences, percentages = [], []
                    for pair in range(self.args.pairs):
                        observations = [row for row in rows if row["pair"] == pair]
                        if len(observations) != 2 or {row["variant"] for row in observations} != set(VARIANTS):
                            raise ValueError("Missing or duplicate pair observation")
                        values = {row["variant"]: row[metric] for row in observations}
                        baseline, candidate = values["baseline"], values["candidate"]
                        differences.append(candidate - baseline)
                        percentages.append(100 * (candidate / baseline - 1) if baseline > 0 else None)
                    valid_percentages = [value for value in percentages if value is not None]
                    result[metric] = {
                        "baseline_median": statistics.median(row[metric] for row in rows if row["variant"] == "baseline"),
                        "candidate_median": statistics.median(row[metric] for row in rows if row["variant"] == "candidate"),
                        "paired_differences": differences,
                        "paired_median_difference": statistics.median(differences),
                        "paired_percent_changes": percentages,
                        "paired_median_percent_change": statistics.median(valid_percentages) if valid_percentages else None,
                        "candidate_lower_pairs": sum(value < 0 for value in differences),
                    }
                results.append(result)
        return {
            "status": "complete", "observations": expected, "fixtures": len(self.fixtures),
            "scenarios": [scenario[0] for scenario in SCENARIOS], "pairs": self.args.pairs,
            "parity": "exact semantic receipts across both variants and every pair",
            "difference_sign": "candidate minus baseline; negative means lower",
            "timing_unit": "seconds for one retained reader topology; no calibration",
            "heap_unit": "malloc-zone bytes in use while all readers are alive",
            "resident_unit": "current process resident bytes while readers are alive; not a process-lifetime peak",
            "owned_bytes_unit": "sum of Swift FontAttachment.data byte counts",
            "performance_threshold": None, "outliers_removed": 0,
            "results": results,
        }

    def verify_inputs(self) -> None:
        for key, receipt in self.sources.items():
            variant, path = key.split(":", 1)
            if variant == "candidate" and file_sha(ROOT / path) != receipt["sha256"]:
                raise ValueError(f"Production source changed during benchmark: {path}")
        if file_sha(Path(__file__)) != self.record["runner_sha256"]:
            raise ValueError("Runner changed during benchmark")
        for path, digest in self.record["support_sha256"].items():
            if file_sha(HERE / path) != digest:
                raise ValueError(f"Benchmark support changed during benchmark: {path}")
        for case in self.fixtures:
            if file_sha(Path(case["path"])) != case["sha256"]:
                raise ValueError(f"Fixture changed during benchmark: {case['name']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=8)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This benchmark requires native macOS frameworks and FFmpeg")
    if args.pairs <= 0 or args.pairs % 2:
        parser.error("Use a positive even number of pairs for balanced AB/BA order")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        summary = runner.measure()
        runner.verify_inputs()
        runner.record["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.record)
        write_json(runner.output / "summary.json", summary)
        write_json(runner.output / "completion.json", {
            "status": "complete", "observations": len(runner.measurements),
            "summary_sha256": file_sha(runner.output / "summary.json"),
            "observations_sha256": file_sha(runner.output / "observations.jsonl"),
        })
        print("AUXILIARY_ATTACHMENTS_SUMMARY " + json.dumps(summary, sort_keys=True, allow_nan=False), flush=True)
    except Exception as error:
        if runner is not None:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "record"):
                write_json(runner.output / "manifest.json", runner.record)
        raise


if __name__ == "__main__":
    main()
