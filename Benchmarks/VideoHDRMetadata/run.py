#!/usr/bin/env python3
"""Compare production video HDR metadata preparation with real FFmpeg/CoreVideo.

The benchmark extracts the six production methods without rewriting their
bodies. Baseline and candidate use identical FFmpeg headers, libraries, fixtures,
and compiler flags. Exact output parity is required before any timed runs.
The full decoder/application graph is qualified separately by native tests.
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
import re
import shlex
import shutil
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
DECODER = "Sources/IlliquidNativePlayback/Media/VideoDecoder.swift"
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
MODULE_MAP = "Sources/CFFmpeg/module.modulemap"
METHODS = (
    "applyColorMetadata", "masteringDisplayPayload", "contentLightPayload",
    "colorPrimariesAttachment", "transferAttachment", "matrixAttachment",
)
CASES = (
    "sdr_bgra", "sdr_nv12", "hdr10_bgra", "hdr10_p010", "mastering_only",
    "light_only", "metadata_changes", "preexisting_attachments",
    "hdr10_p010_cleared", "sdr_nv12_cleared",
)
PACKAGES = ("libavformat", "libavfilter", "libavcodec", "libavutil", "libswresample", "libswscale")
FLAGS = ("-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library")


def sha(value: bytes | str) -> str:
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def extract_method(source: str, name: str) -> str:
    """Keep the production method text, removing only its private modifier.

    Methods in VideoDecoder use four-space class member indentation. Fail
    closed if that boundary or the unique declaration changes.
    """
    starts = list(re.finditer(r"(?m)^    private func " + re.escape(name) + r"\(", source))
    if len(starts) != 1:
        raise ValueError(f"Expected one private production method: {name}")
    start = starts[0].start()
    end = re.search(r"(?m)^    }\s*$", source[starts[0].end():])
    if end is None:
        raise ValueError(f"Missing method boundary: {name}")
    block = source[start:starts[0].end() + end.end()].rstrip() + "\n"
    if block.count("{") != block.count("}"):
        raise ValueError(f"Review changed production method extraction: {name}")
    return block.replace("    private func ", "    func ", 1)


def validate_call_topology(source: str, variant: str) -> dict[str, str]:
    """Reject production call-site drift that the small wrapper cannot model.

    The production method and each relevant call must be unique. Require the
    exact variables, argument order and unconditional method-body indentation;
    moving preparation into a branch or changing either consumer needs review.
    Returned snippets are saved and hashed with the extracted helper methods.
    """
    if variant not in ("baseline", "candidate"):
        raise ValueError(f"Unknown topology variant: {variant}")
    # extract_method checks declaration uniqueness and the class-member closing
    # boundary. Restore its sole modifier removal for the call-site snapshot.
    frame = extract_method(source, "makeFrame").replace(
        "    func makeFrame(", "    private func makeFrame(", 1
    )
    for name in ("masteringDisplayPayload", "contentLightPayload", "applyColorMetadata", "NativeDecodedVideoFrame"):
        if len(re.findall(r"\b" + re.escape(name) + r"\s*\(", frame)) != 1:
            raise ValueError(f"Review {variant} makeFrame: expected one {name} call")

    def unique(pattern: str, label: str):
        matches = list(re.finditer(pattern, frame, re.MULTILINE))
        if len(matches) != 1:
            raise ValueError(f"Review {variant} makeFrame {label}: expected exact call-site variables and arguments")
        return matches[0]

    mastering = unique(
        r"^        let masteringMetadata = masteringDisplayPayload\(frame\)[ \t]*$",
        "mastering extraction",
    )
    light = unique(
        r"^        let contentLightMetadata = contentLightPayload\(frame\)[ \t]*$",
        "content-light extraction",
    )
    arguments = r"frame:\s*frame,\s*pixelBuffer:\s*pixelBuffer"
    if variant == "candidate":
        arguments += r",\s*masteringMetadata:\s*masteringMetadata,\s*contentLightMetadata:\s*contentLightMetadata"
    apply = unique(
        r"^        applyColorMetadata\(\s*" + arguments + r"\s*\)[ \t]*$",
        "color attachment call",
    )
    construction_start = unique(
        r"^        var decodedFrame = NativeDecodedVideoFrame\([ \t]*$",
        "decoded-frame construction",
    )
    construction_end = re.search(r"(?m)^        \)[ \t]*$", frame[construction_start.end():])
    if construction_end is None:
        raise ValueError(f"Review {variant} makeFrame: missing decoded-frame constructor boundary")
    construction = frame[construction_start.start():construction_start.end() + construction_end.end()]
    for label, value in (("pixelBuffer", "pixelBuffer"),
                         ("masteringDisplayMetadata", "masteringMetadata"),
                         ("contentLightMetadata", "contentLightMetadata")):
        if len(re.findall(r"\b" + label + r"\s*:", construction)) != 1 or not re.search(
            r"(?m)^            " + label + r": " + value + r",[ \t]*$", construction
        ):
            raise ValueError(f"Review {variant} makeFrame: decoded frame must consume {label}: {value}")

    if frame[mastering.end():light.start()].strip():
        raise ValueError(f"Review {variant} makeFrame: payload extraction statements must be adjacent")
    if variant == "baseline":
        valid_order = apply.end() < mastering.start() < light.start() < construction_start.start()
    else:
        valid_order = mastering.start() < light.start() < apply.start() < construction_start.start()
        if frame[light.end():apply.start()].strip():
            raise ValueError("Review candidate makeFrame: attachment call must immediately consume the extracted payloads")
    if not valid_order:
        raise ValueError(f"Review {variant} makeFrame: HDR preparation order no longer matches the benchmark wrapper")
    return {"makeFrame": frame, "masteringExtraction": mastering.group(),
            "contentLightExtraction": light.group(), "applyColorMetadataCall": apply.group(),
            "decodedFrameConstruction": construction}


def processor(methods: dict[str, str], variant: str) -> str:
    if variant == "baseline":
        body = """        applyColorMetadata(frame: frame, pixelBuffer: pixelBuffer)
        return (masteringDisplayPayload(frame), contentLightPayload(frame))"""
    else:
        body = """        let masteringMetadata = masteringDisplayPayload(frame)
        let contentLightMetadata = contentLightPayload(frame)
        applyColorMetadata(
            frame: frame,
            pixelBuffer: pixelBuffer,
            masteringMetadata: masteringMetadata,
            contentLightMetadata: contentLightMetadata
        )
        return (masteringMetadata, contentLightMetadata)"""
    return """import CFFmpeg
import CoreVideo
import Foundation

struct MetadataProcessor {
    @inline(never)
    func metadata(
        frame: UnsafeMutablePointer<AVFrame>,
        pixelBuffer: CVPixelBuffer
    ) -> (masteringMetadata: Data?, contentLightMetadata: Data?) {
""" + body + "\n    }\n\n" + "\n".join(methods.values()) + "}\n"


def linker_flags(tokens: list[str]) -> list[str]:
    """Forward pkg-config linker arguments without shell interpretation."""
    result = []
    for token in tokens:
        if token.startswith("-Wl,"):
            for part in token[4:].split(","):
                result.extend(("-Xlinker", part))
        else:
            result.extend(("-Xlinker", token))
    return result


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.env = os.environ.copy()
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": args.baseline,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "processor": platform.processor(), "files": {}, "binaries": {},
            "scope": "Color attachments and both returned HDR payloads for an existing AVFrame/CVPixelBuffer. The *_cleared controls also time clearing all attachments before preparation; other cases use a warm 32-buffer ring. Excludes decode, pixel conversion, allocation of the frame/pixel buffer, geometry attachments and presentation.",
        }

    def command(self, argv, *, log: Path | None = None):
        argv = [str(item) for item in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.commands.append({
            "argv": argv, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - start,
            "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
        })
        write_json(self.output / "commands.json", self.commands)
        if log is not None:
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n{result.stdout[-4000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def source(self, variant: str, path: str) -> str:
        value = ((ROOT / path).read_text() if variant == "candidate" else
                 self.command(["git", "show", f"{self.args.baseline}:{path}"]))
        self.receipt["files"][f"{variant}:{path}"] = sha(value)
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)
        return value

    def prepare(self):
        module = self.output / "CFFmpeg"
        for path, destination in ((SHIM, module / "include/ffmpeg_shim.h"),
                                  (MODULE_MAP, module / "module.modulemap")):
            candidate = self.source("candidate", path)
            if candidate != self.source("baseline", path):
                raise ValueError(f"Shared FFmpeg import changed between revisions: {path}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(candidate)
        harness = (HERE / "Harness.swift").read_bytes()
        (self.output / "Harness.swift").write_bytes(harness)
        self.receipt["harness_sha256"] = sha(harness)
        runner_source = Path(__file__).read_bytes()
        (self.output / "runner.snapshot.py").write_bytes(runner_source)
        self.receipt["runner_sha256"] = sha(runner_source)
        baseline_methods = None
        for variant in ("baseline", "candidate"):
            source = self.source(variant, DECODER)
            topology = validate_call_topology(source, variant)
            methods = {name: extract_method(source, name) for name in METHODS}
            if baseline_methods is None:
                baseline_methods = methods
            elif any(methods[name] != baseline_methods[name] for name in METHODS[1:]):
                raise ValueError("Payload serialization or color mapping changed; review benchmark scope")
            directory = self.output / variant
            directory.mkdir()
            (directory / "makeFrame.call-site.swift").write_text(topology["makeFrame"])
            self.receipt["call_site_topology_" + variant] = {
                "verified": True,
                "snippet_sha256": {name: sha(value) for name, value in topology.items()},
            }
            generated = processor(methods, variant)
            (directory / "MetadataProcessor.swift").write_text(generated)
            self.receipt["files"][variant + ":processor"] = sha(generated)
            self.receipt["extracted_methods_" + variant] = {name: sha(value) for name, value in methods.items()}
        diff = self.command(["git", "diff", "--no-ext-diff", "--", DECODER])
        (self.output / "candidate-working-tree.patch").write_text(diff)
        self.receipt["candidate_working_tree_patch_sha256"] = sha(diff)
        write_json(self.output / "build-receipt.json", self.receipt)

    def build(self):
        if platform.system() != "Darwin":
            raise RuntimeError("Native measurements require macOS/CoreVideo; --prepare-only can inspect extraction on other hosts")
        compiler = shutil.which(self.args.swiftc or "swiftc") or self.args.swiftc
        if not compiler:
            raise RuntimeError("swiftc not found; pass --swiftc")
        # Keep the swiftc basename: toolchain installations may use a symlink
        # to swift-driver, whose mode depends on the invoked executable name.
        compiler = os.path.abspath(compiler)
        cflags = shlex.split(self.command([self.args.pkg_config, "--cflags", *PACKAGES]))
        libs = shlex.split(self.command([self.args.pkg_config, "--libs", *PACKAGES]))
        flags = [*FLAGS, "-I", str(self.output / "CFFmpeg"),
                 "-module-cache-path", str(self.output / "module-cache")]
        for token in cflags:
            flags.extend(("-Xcc", token))
        flags.extend(linker_flags(libs))
        for framework in ("CoreVideo", "CoreMedia", "VideoToolbox", "Foundation"):
            flags.extend(("-framework", framework))
        # Make dylib resolution independent of the invoking shell's DYLD paths.
        library_directories = sorted(set(self.command([self.args.pkg_config, "--variable=libdir", package]).strip()
                                         for package in PACKAGES))
        for directory in library_directories:
            if directory:
                flags.extend(("-Xlinker", "-rpath", "-Xlinker", directory))
        self.receipt.update({
            "compiler": self.command([compiler, "--version"]).strip(),
            "sdk_version": self.command(["xcrun", "--show-sdk-version"]).strip(),
            "macos": self.command(["sw_vers"]).strip(), "flags": flags,
            "pkg_config_cflags": cflags, "pkg_config_libs": libs,
            "package_versions": {package: self.command([self.args.pkg_config, "--modversion", package]).strip()
                                 for package in PACKAGES},
        })
        libavutil_directory = self.command([self.args.pkg_config, "--variable=libdir", "libavutil"]).strip()
        self.receipt["libavutil_files"] = {
            str(path): sha(path.read_bytes())
            for path in Path(libavutil_directory).glob("libavutil*.dylib")
            if path.is_file() and not path.is_symlink()
        }
        write_json(self.output / "build-receipt.json", self.receipt)
        for variant in ("baseline", "candidate"):
            directory = self.output / variant
            binary = directory / "benchmark"
            print(f"Building {variant}", flush=True)
            self.command([compiler, *flags, directory / "MetadataProcessor.swift",
                          self.output / "Harness.swift", "-o", binary], log=directory / "compile.log")
            self.receipt["binaries"][variant] = {"path": str(binary), "sha256": sha(binary.read_bytes())}
            write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant: str, *args):
        return json.loads(self.command([self.output / variant / "benchmark", *args]))

    def verify(self):
        traces = {}
        for variant in ("baseline", "candidate"):
            traces[variant] = self.invoke(variant, "--verify")
            write_json(self.output / f"{variant}-trace.json", traces[variant])
        equal = traces["baseline"] == traces["candidate"]
        parity = {
            "equal": equal, "comparison": "Complete decoded JSON traces",
            "trace_sha256": {variant: sha(json.dumps(trace, sort_keys=True))
                             for variant, trace in traces.items()},
        }
        if all(isinstance(trace, list) for trace in traces.values()):
            parity["trace_count"] = len(traces["candidate"])
        write_json(self.output / "parity.json", parity)
        if not equal:
            raise ValueError("HDR payload/attachment traces differ; inspect saved traces. Timing was not run.")
        print("Exact HDR payload/attachment trace parity passed", flush=True)

    def measurement(self, variant: str, case: str, iterations: int):
        record = self.invoke(variant, "--case", case, "--iterations", iterations)
        if record.get("case") != case or record.get("iterations") != iterations:
            raise ValueError(f"Harness request/response mismatch: {record}")
        for field in ("wall_ns", "cpu_ns"):
            value = record.get(field)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"Invalid {field} in harness measurement: {record}")
        if "checksum" not in record:
            raise ValueError("Harness measurement must consume output and report checksum")
        return record

    def measure(self):
        summaries = []
        calibrations = []
        for case in self.args.cases:
            pilots = {variant: [self.measurement(variant, case, 5_000) for _ in range(2)]
                      for variant in ("baseline", "candidate")}
            for records in zip(pilots["baseline"], pilots["candidate"]):
                if records[0]["checksum"] != records[1]["checksum"]:
                    raise ValueError(f"Pilot output mismatch: {case}")
            fastest = min(record["wall_ns"] / record["iterations"]
                          for records in pilots.values() for record in records)
            requested = max(5_000, math.ceil(self.args.target_ms * 1_000_000 / fastest))
            iterations = min(10_000_000, requested)
            calibrations.append({"case": case, "pilots": pilots,
                                 "target_variant_ms": self.args.target_ms,
                                 "requested_iterations": requested, "iterations": iterations,
                                 "iteration_cap_applied": requested != iterations})
            write_json(self.output / "calibration.json", calibrations)
            pairs = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                values = {}
                for variant in order:
                    record = self.measurement(variant, case, iterations)
                    record.update({"variant": variant, "pair": pair, "order": list(order)})
                    values[variant] = record
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True, allow_nan=False) + "\n")
                if values["baseline"]["checksum"] != values["candidate"]["checksum"]:
                    raise ValueError(f"Timed output mismatch: {case}, pair {pair}")
                pairs.append(values)
            summary = {"case": case, "iterations": iterations, "pairs": self.args.pairs,
                       "paired_measurements": pairs}
            for metric in ("wall_ns", "cpu_ns"):
                old = [pair["baseline"][metric] / iterations for pair in pairs]
                new = [pair["candidate"][metric] / iterations for pair in pairs]
                ratios = [pair["candidate"][metric] / pair["baseline"][metric] for pair in pairs]
                ratio = statistics.median(new) / statistics.median(old)
                summary[metric] = {
                    "baseline_median_per_frame": statistics.median(old),
                    "candidate_median_per_frame": statistics.median(new),
                    "median_ratio": ratio, "change_percent": (ratio - 1) * 100,
                    "median_paired_ratio": statistics.median(ratios), "paired_ratios": ratios,
                    "candidate_wins": sum(value < 1 for value in ratios),
                    "baseline_range_per_frame": [min(old), max(old)],
                    "candidate_range_per_frame": [min(new), max(new)],
                }
            summary["minimum_wall_ms"] = {
                variant: min(pair[variant]["wall_ns"] for pair in pairs) / 1_000_000
                for variant in ("baseline", "candidate")
            }
            summaries.append(summary)
            write_json(self.output / "summary.json", summaries)
            wall = summary["wall_ns"]
            print(f"{case}: {wall['baseline_median_per_frame']:.1f} -> "
                  f"{wall['candidate_median_per_frame']:.1f} ns/frame "
                  f"({wall['change_percent']:+.1f}%; {wall['candidate_wins']}/{self.args.pairs} paired wins)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swiftc")
    parser.add_argument("--pkg-config", default="pkg-config")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-only", action="store_true",
                      help="Save exact extracted sources and receipts without Swift/macOS dependencies")
    mode.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two for balanced AB/BA ordering")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    if len(set(args.cases)) != len(args.cases):
        parser.error("--cases must not contain duplicates")
    runner = Runner(args)
    try:
        runner.prepare()
        if not args.prepare_only:
            runner.build()
            runner.verify()
            if not args.verify_only:
                runner.measure()
        write_json(runner.output / "completion.json", {
            "complete": True, "prepared": True, "compiled": not args.prepare_only,
            "verified": not args.prepare_only,
            "measured": not (args.prepare_only or args.verify_only),
            "performance_acceptance_gate": "None; inspect paired results before deciding whether to keep the change",
        })
    except Exception as error:
        write_json(runner.output / "completion.json", {"complete": False, "error": str(error)})
        raise
    finally:
        write_json(runner.output / "commands.json", runner.commands)


if __name__ == "__main__":
    main()
