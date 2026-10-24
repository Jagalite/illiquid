#!/usr/bin/env python3
"""Qualify exact native auxiliary inputs and measure their live font-copy cost.

macOS only. No packages, native libraries, or fixtures are downloaded. The old
AttachmentAdmission study remains frozen; only its source inventory and guarded
declaration-extraction helpers are shared here.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
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
VARIANTS = ("baseline", "candidate")
WORKLOADS = [("auxiliary", count) for count in (1, 2, 3)] + [("default", 1)]
HELPER = ROOT / "Benchmarks/AttachmentAdmission/run.py"
FOCAL = {"Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift",
         "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def helper():
    spec = importlib.util.spec_from_file_location("attachment_admission_sources", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory; retained evidence is never overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.commands, self.observations, self.parity = [], [], []
        self.sources, self.binaries = {}, {}
        self.prefix = args.ffmpeg_prefix.resolve(strict=True)
        compiler = args.swiftc or self.command(["xcrun", "--find", "swiftc"], "find-swiftc").strip()
        self.swiftc = Path(compiler).absolute()  # Preserve the swiftc driver basename.
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "find-sdk").strip()
        self.fixtures = self.load_fixtures(args.fixtures.resolve(strict=True))
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(), "baseline_revision": BASELINE,
            "candidate_worktree_head": self.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "candidate_worktree_status": self.command(["git", "status", "--porcelain=v1"], "status"),
            "candidate_revision_note": "Source hashes identify exact working-tree bytes. A clean checkout matches HEAD; otherwise HEAD identifies the checkout ancestor.",
            "platform": platform.platform(), "machine": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"], "compiler-version").strip(),
            "compiler_path": str(self.swiftc), "compiler_sha256": file_sha(self.swiftc),
            "sdk_path": self.sdk,
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version").strip(),
            "system": self.command(["system_profiler", "SPHardwareDataType", "SPSoftwareDataType"], "system"),
            "protocol": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
            "workloads": WORKLOADS, "allowed_production_differences": sorted(FOCAL),
            "source_transformations": "None. Complete sources plus unchanged guarded error/PGS declarations.",
            "sources": self.sources, "binaries": self.binaries, "native_libraries": {},
            "drivers": {},
        }
        for path in [Path(__file__), HERE / "Harness.swift", HERE / "MemoryProbe.h",
                     HERE / "generate-fixtures.py", HELPER]:
            name = "admission-source-helper.py" if path == HELPER else path.name
            shutil.copyfile(path, self.output / name)
            self.receipt["drivers"][str(path.relative_to(ROOT))] = file_sha(path)

    def command(self, argv, label, timeout=600):
        argv = [str(value) for value in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=timeout)
        directory = self.output / "logs"
        directory.mkdir(exist_ok=True)
        stdout, stderr = directory / (label + ".stdout"), directory / (label + ".stderr")
        stdout.write_text(result.stdout); stderr.write_text(result.stderr)
        record = {"label": label, "argv": argv, "returncode": result.returncode,
                  "seconds": time.monotonic() - start,
                  "stdout": str(stdout.relative_to(self.output)), "stderr": str(stderr.relative_to(self.output)),
                  "stdout_sha256": file_sha(stdout), "stderr_sha256": file_sha(stderr)}
        self.commands.append(record)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{result.stdout[-2000:]}\n{result.stderr[-10000:]}")
        return result.stdout

    def load_fixtures(self, directory):
        path = directory / "manifest.json"
        fixtures = json.loads(path.read_text())
        expected_sizes = {"none": 0, "fonts-2mib": 2 << 20,
                          "fonts-16mib": 16 << 20, "fonts-64mib": 64 << 20}
        if len(fixtures) != 4 or {item["name"] for item in fixtures} != set(expected_sizes):
            raise ValueError("Expected all four controlled font workloads")
        for item in fixtures:
            file = (directory / item["filename"]).resolve(strict=True)
            if not file.is_relative_to(directory) or not file.is_file():
                raise ValueError("Fixture must be a file within its manifest directory")
            if file_sha(file) != item["sha256"] or file.stat().st_size != item["size_bytes"]:
                raise ValueError(f"Fixture hash/size differs: {item['name']}")
            attachments = item["attachments"]
            if (item["accepted_payload_bytes"] != expected_sizes[item["name"]]
                    or sum(font["bytes"] for font in attachments) != item["accepted_payload_bytes"]
                    or any(font["bytes"] > 16 << 20 for font in attachments)
                    or len(attachments) > 64):
                raise ValueError("Font fixture violates its byte inventory or production limits")
            item["path"] = str(file)
        shutil.copyfile(path, self.output / "fixture-manifest.snapshot.json")
        write_json(self.output / "fixtures.json", fixtures)
        return fixtures

    def prepare(self):
        original = {}
        shared = helper()
        paths = shared.FULL_SOURCES + [shared.PRESENTATION, shared.BITMAP] + shared.C_SOURCES
        for variant in VARIANTS:
            original[variant] = {}
            for path in paths:
                raw = (ROOT / path).read_bytes() if variant == "candidate" else subprocess.check_output(
                    ["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
                original[variant][path] = raw.decode()
                target = self.output / "sources" / variant / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
                self.sources[f"{variant}:{path}"] = {"sha256": sha(raw), "bytes": len(raw),
                    "origin": "working-tree" if variant == "candidate" else "pinned-baseline"}
        for path in set(shared.FULL_SOURCES + shared.C_SOURCES) - FOCAL:
            if original["baseline"][path] != original["candidate"][path]:
                raise ValueError(f"Unrelated production dependency changed: {path}")
        extracted = {}
        for variant in VARIANTS:
            extracted[variant] = "import Foundation\n\n" + shared.extract(
                original[variant][shared.PRESENTATION], "struct PresentationError:", "\nfunc checkOSStatus(")
            extracted[variant] += "\n" + shared.extract(
                original[variant][shared.BITMAP], "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
        if extracted["baseline"] != extracted["candidate"]:
            raise ValueError("Shared extracted error/packet declarations differ")
        module = self.output / "CFFmpeg"
        (module / "include").mkdir(parents=True)
        for path in shared.C_SOURCES:
            (module / Path(path).relative_to("Sources/CFFmpeg")).write_text(original["candidate"][path])
        probe = self.output / "CAuxiliaryMemory"
        probe.mkdir()
        shutil.copyfile(HERE / "MemoryProbe.h", probe / "MemoryProbe.h")
        (probe / "module.modulemap").write_text('module CAuxiliaryMemory [system] { header "MemoryProbe.h" export * }\n')
        headers = {}
        for name in shared.LIBRARIES:
            directory = self.prefix / "include" / ("lib" + name)
            if not directory.is_dir():
                raise ValueError(f"Missing FFmpeg headers: {directory}")
            for path in sorted(directory.rglob("*.h")):
                headers[str(path.relative_to(self.prefix / "include"))] = file_sha(path)
            library = (self.prefix / "lib" / f"lib{name}.dylib").resolve(strict=True)
            self.receipt["native_libraries"][name] = {"path": str(library), "sha256": file_sha(library)}
        write_json(self.output / "ffmpeg-headers.json", headers)
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-sdk", self.sdk, "-I", str(module), "-I", str(probe),
                 "-Xcc", "-I" + str(self.prefix / "include"), "-L", str(self.prefix / "lib"),
                 "-Xlinker", "-rpath", "-Xlinker", str(self.prefix / "lib"),
                 "-module-cache-path", str(self.output / "module-cache"),
                 "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
        self.receipt["compiler_flags"] = flags
        self.receipt["compiled_sources"] = {}
        self.executables = {}
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            inputs = []
            for path in shared.FULL_SOURCES:
                target = directory / Path(path).name
                target.write_text(original[variant][path])
                inputs.append(target)
            target = directory / "ExtractedDeclarations.swift"
            target.write_text(extracted[variant]); inputs.append(target)
            self.receipt["compiled_sources"][variant] = {
                str(path.relative_to(self.output)): file_sha(path) for path in inputs}
            library = directory / "libAuxiliaryInputs.dylib"
            self.command([self.swiftc, *flags, "-emit-library", "-emit-module", "-enable-testing",
                          "-module-name", "AuxiliaryInputs", "-emit-module-path", directory / "AuxiliaryInputs.swiftmodule",
                          "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryInputs.dylib",
                          *inputs, "-o", library], variant + "-library-build")
            executable = directory / "auxiliary-input-benchmark"
            define = ["-D", "CANDIDATE"] if variant == "candidate" else []
            self.command([self.swiftc, *flags, *define, "-I", directory, "-L", directory, "-lAuxiliaryInputs",
                          "-Xlinker", "-rpath", "-Xlinker", directory,
                          self.output / "Harness.swift", "-o", executable], variant + "-driver-build")
            self.executables[variant] = executable
            self.binaries[variant] = {"library": str(library.relative_to(self.output)),
                "executable": str(executable.relative_to(self.output)),
                "library_sha256": file_sha(library), "executable_sha256": file_sha(executable),
                "library_linkage": self.command(["otool", "-L", library], variant + "-library-linkage"),
                "executable_linkage": self.command(["otool", "-L", executable], variant + "-executable-linkage")}
        write_json(self.output / "manifest.json", self.receipt)

    def invoke(self, variant, case, mode, policy, count, iterations, label):
        raw = self.command([self.executables[variant], mode, case["path"], policy, count, iterations,
                            case["accepted_payload_bytes"]], label)
        result = json.loads(raw)
        for key, expected in [("mode", mode), ("policy", policy), ("inputs", count),
                              ("iterations", iterations), ("accepted_payload_bytes", case["accepted_payload_bytes"])]:
            if result[key] != expected:
                raise ValueError(f"Harness command identity mismatch: {key}")
        if result["loads_fonts"] != (variant == "baseline" or policy != "auxiliary"):
            raise ValueError("Harness selected the wrong font-loading policy")
        return result

    def verify(self):
        for case in self.fixtures:
            variants = {variant: self.invoke(variant, case, "verify", "default", 1, 1,
                        f"verify-{case['name']}-{variant}") for variant in VARIANTS}
            reference = None
            for variant, data in variants.items():
                for backend, policies in data["traces"].items():
                    if set(policies) != {"default", "explicit", "auxiliary"}:
                        raise ValueError("Missing constructor policy verification")
                    for policy, trace in policies.items():
                        expected_fonts = [] if variant == "candidate" and policy == "auxiliary" else case["attachments"]
                        if trace["metadata"]["attachments"] != expected_fonts:
                            raise ValueError(f"Exact font inventory differs: {case['name']}/{variant}/{backend}/{policy}")
                        normalized = copy.deepcopy(trace)
                        normalized["metadata"]["attachments"] = []
                        if reference is None:
                            reference = normalized
                        if normalized != reference:
                            raise ValueError(f"Metadata, codec, packet, or seek parity differs: {case['name']}/{variant}/{backend}/{policy}")
                if set(data["traces"]) != {"direct", "executor"}:
                    raise ValueError("Missing direct demuxer or serialized executor verification")
            metadata = reference["metadata"]
            if not {"video", "audio", "subtitle"} <= {stream["kind"] for stream in metadata["streams"]}:
                raise ValueError("Fixture must exercise all three playable stream kinds")
            if len(metadata["chapters"]) != 2:
                raise ValueError("Fixture must exercise chapter metadata")
            self.parity.append({"case": case["name"], "comparisons": 12,
                "complete_nonattachment_trace_sha256": sha(canonical(reference)),
                "font_payload_sha256_matches_manifest": True,
                "initial_packets": len(reference["initial_packets"]),
                "seek_packets": len(reference["seek_packets"]),
                "active_subtitle_packets": len(reference["active_subtitle_packets"]),
                "status": "equal apart from the expected empty auxiliary Swift font array"})
        write_json(self.output / "parity.json", self.parity)

    def sample(self, variant, case, mode, policy, count, iterations, stage, **identity):
        label = f"{stage}-{mode}-{case['name']}-{policy}-{count}-{identity.get('pair', 0)}-{variant}"
        value = self.invoke(variant, case, mode, policy, count, iterations, label)
        if mode == "memory":
            expected = count * case["accepted_payload_bytes"] if value["loads_fonts"] else 0
            if value["auxiliary_font_bytes"] != expected or value["main_font_bytes"] != case["accepted_payload_bytes"]:
                raise ValueError("Measured retained font inventory differs")
            for checkpoint in ("before_main", "after_main", "after_inputs", "after_input_release", "after_all_release"):
                if min(value[checkpoint][key] for key in ("allocator_bytes", "resident_bytes", "peak_resident_bytes")) <= 0:
                    raise ValueError("Invalid native memory sample")
        else:
            if any(not math.isfinite(value[key]) or value[key] <= 0 for key in ("wall_seconds", "cpu_seconds")):
                raise ValueError("Invalid timing sample")
            if int(value["checksum"]) != int(value["checksum_per_iteration"]) * iterations % (1 << 64):
                raise ValueError("Timed checksum mismatch")
        value.update(variant=variant, case=case["name"], stage=stage, **identity)
        self.observations.append(value)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True, allow_nan=False) + "\n")
        return value

    def measure(self):
        calibrations = []
        for mode in ("memory", "timing"):
            for case in self.fixtures:
                for policy, count in WORKLOADS:
                    iterations = 1
                    if mode == "timing":
                        trials = [self.sample(v, case, mode, policy, count, 1, "calibration") for v in VARIANTS]
                        fastest = min(row["wall_seconds"] for row in trials)
                        iterations = min(self.args.max_iterations, max(1, math.ceil(self.args.target_ms / 1000 / fastest)))
                        calibrations.append({"case": case["name"], "policy": policy, "inputs": count,
                                             "iterations": iterations, "target_ms": self.args.target_ms})
                        write_json(self.output / "calibration.json", calibrations)
                    for pair in range(self.args.pairs):
                        order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                        for order_index, variant in enumerate(order):
                            self.sample(variant, case, mode, policy, count, iterations, "measurement",
                                        pair=pair, order_index=order_index)
                    print(json.dumps({"completed": mode, "case": case["name"], "policy": policy,
                                      "inputs": count, "pairs": self.args.pairs}), flush=True)
        return self.summarize()

    def summarize(self):
        measurements = [row for row in self.observations if row["stage"] == "measurement"]
        expected = len(self.fixtures) * len(WORKLOADS) * 2 * self.args.pairs * 2
        if len(measurements) != expected:
            raise ValueError("Incomplete measurement cohort")
        results = []
        for case in self.fixtures:
            for policy, count in WORKLOADS:
                selected = [row for row in measurements if (row["case"], row["policy"], row["inputs"]) == (case["name"], policy, count)]
                result = {"case": case["name"], "policy": policy, "inputs": count,
                          "font_bytes_per_input": case["accepted_payload_bytes"], "metrics": {}}
                metrics = {
                    "retained_allocator_delta_bytes": ("memory", lambda row: row["retained_allocator_delta_bytes"]),
                    "live_allocator_bytes": ("memory", lambda row: row["after_inputs"]["allocator_bytes"]),
                    "live_resident_bytes": ("memory", lambda row: row["after_inputs"]["resident_bytes"]),
                    "process_peak_resident_bytes": ("memory", lambda row: row["after_inputs"]["peak_resident_bytes"]),
                    "released_allocator_delta_bytes": ("memory", lambda row: row["released_allocator_delta_bytes"]),
                    "open_close_wall_seconds_per_batch": ("timing", lambda row: row["wall_seconds"] / row["iterations"]),
                    "open_close_cpu_seconds_per_batch": ("timing", lambda row: row["cpu_seconds"] / row["iterations"]),
                }
                for name, (mode, value) in metrics.items():
                    rows = [row for row in selected if row["mode"] == mode]
                    variants = {variant: [value(row) for row in rows if row["variant"] == variant] for variant in VARIANTS}
                    savings, reductions = [], []
                    for pair in range(self.args.pairs):
                        members = [row for row in rows if row["pair"] == pair]
                        if len(members) != 2 or {row["variant"] for row in members} != set(VARIANTS):
                            raise ValueError("Missing or duplicate paired observation")
                        values = {row["variant"]: value(row) for row in members}
                        baseline, candidate = values["baseline"], values["candidate"]
                        savings.append(baseline - candidate)
                        reductions.append(100 * (baseline - candidate) / baseline if baseline > 0 else None)
                    result["metrics"][name] = {
                        **{variant: {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}
                           for variant, values in variants.items()},
                        "paired_savings": savings, "paired_reduction_percent": reductions,
                        "median_paired_savings": statistics.median(savings),
                        "median_paired_reduction_percent": statistics.median([x for x in reductions if x is not None])
                            if any(x is not None for x in reductions) else None,
                        "candidate_lower_pairs": sum(value > 0 for value in savings),
                    }
                results.append(result)
        return {"status": "complete", "pairs": self.args.pairs, "measurement_processes": expected,
                "ordering": "AB/BA balanced per case, policy, input count, and measurement type; all samples retained",
                "memory_boundary": "One default main input remains alive; add 1/2/3 auxiliary inputs, then release them. No tracing/hashing before checkpoints.",
                "timing_boundary": "Open and close one batch of serialized input executors with a main input held alive; one warmup batch excluded.",
                "results": results}

    def verify_inputs(self):
        for key, record in self.sources.items():
            variant, path = key.split(":", 1)
            if variant == "candidate" and file_sha(ROOT / path) != record["sha256"]:
                raise ValueError(f"Production input changed during measurement: {path}")
        for path, digest in self.receipt["drivers"].items():
            if file_sha(ROOT / path) != digest:
                raise ValueError(f"Benchmark input changed during measurement: {path}")
        for variant, record in self.binaries.items():
            for kind in ("library", "executable"):
                if file_sha(self.output / record[kind]) != record[kind + "_sha256"]:
                    raise ValueError(f"Compiled binary changed: {variant}/{kind}")
        for case in self.fixtures:
            if file_sha(Path(case["path"])) != case["sha256"]:
                raise ValueError("Fixture changed during measurement")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--max-iterations", type=int, default=1000)
    parser.add_argument("--mode", choices=("all", "verify", "build"), default="all")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This exact-source native study requires macOS and the pinned FFmpeg SDK")
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 5 or args.max_iterations < 1:
        parser.error("Use positive even pairs >= 2, target >= 5 ms, and positive max iterations")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        if args.mode != "build":
            runner.verify()
        if args.mode == "all":
            summary = runner.measure()
        else:
            summary = {"status": "complete", "mode": args.mode, "parity": runner.parity}
        runner.verify_inputs()
        runner.receipt["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(runner.output / "manifest.json", runner.receipt)
        write_json(runner.output / "summary.json", summary)
        print("AUXILIARY_FONT_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    except Exception as error:
        if runner is not None:
            write_json(runner.output / "failure.json", {"error": str(error)})
            if hasattr(runner, "receipt"):
                write_json(runner.output / "manifest.json", runner.receipt)
        raise


if __name__ == "__main__":
    main()
