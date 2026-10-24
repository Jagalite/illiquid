#!/usr/bin/env python3
"""Measure retained memory of exact native baseline/candidate input groups."""
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
SPEC = importlib.util.spec_from_file_location("attachment_build", HERE.parent / "AttachmentAdmission/run.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)
VARIANTS = ("baseline", "candidate")
SCENARIOS = [("executor", 0), ("executor", 1), ("executor", 2), ("direct", 1)]
CHANGED = {BUILD.DEMUXER, BUILD.FONT,
           "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"}


def sha(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def sources():
    paths = BUILD.FULL_SOURCES + [BUILD.PRESENTATION, BUILD.BITMAP] + BUILD.C_SOURCES
    result = {variant: {} for variant in VARIANTS}
    for path in paths:
        result["baseline"][path] = subprocess.check_output(
            ["git", "show", f"{BASELINE}:{path}"], cwd=ROOT, text=True)
        result["candidate"][path] = (ROOT / path).read_text()
        if path not in CHANGED and result["baseline"][path] != result["candidate"][path]:
            raise ValueError(f"Unrelated component dependency changed: {path}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--validate-inputs", action="store_true")
    args = parser.parse_args()
    original = sources()
    if args.validate_inputs:
        print(json.dumps({"baseline": BASELINE, "sources": len(original["baseline"]),
                          "candidate_changes": sorted(CHANGED)}))
        return
    if platform.system() != "Darwin":
        parser.error("Native memory measurement requires macOS")
    if args.output is None or args.fixtures is None or args.pairs < 2 or args.pairs % 2:
        parser.error("Supply --output, --fixtures and an even --pairs >= 2")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    prefix = args.ffmpeg_prefix.resolve(strict=True)
    fixtures = args.fixtures.resolve(strict=True)
    cases = json.loads((fixtures / "manifest.json").read_text())
    if len(cases) != 5 or {x["name"] for x in cases} != {"none", "real-font", "font-2mib", "font-16mib", "fonts-64mib"}:
        raise ValueError("Incomplete or unexpected fixture matrix")
    for case in cases:
        path = (fixtures / case["filename"]).resolve(strict=True)
        if not path.is_relative_to(fixtures) or sha(path.read_bytes()) != case["sha256"]:
            raise ValueError("Fixture path/hash mismatch")
        if type(case["font_bytes"]) is not int or not 0 <= case["font_bytes"] <= 64 * 1024 * 1024:
            raise ValueError("Fixture exceeds font-byte limit")
        if type(case["font_count"]) is not int or not 0 <= case["font_count"] <= 64:
            raise ValueError("Invalid fixture font count")
    write_json(output / "fixtures.json", cases)
    commands = []

    def command(argv, log=None):
        argv = list(map(str, argv))
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=600)
        commands.append({"argv": argv, "returncode": result.returncode,
                         "elapsed_seconds": time.monotonic() - started,
                         "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)})
        write_json(output / "commands.json", commands)
        if log:
            (output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"{argv}\n{result.stdout[-4000:]}\n{result.stderr[-10000:]}")
        return result.stdout

    compiler = command(["xcrun", "--find", "swiftc"]).strip()
    sdk = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    manifest = {"baseline": BASELINE,
                "candidate_revision": command(["git", "rev-parse", "HEAD"]).strip(),
                "worktree": command(["git", "status", "--porcelain=v1"]),
                "compiler": command([compiler, "--version"]),
                "compiler_sha256": BUILD.file_sha(Path(compiler)),
                "host": command(["sw_vers"]), "machine": platform.machine(),
                "sdk": sdk, "sdk_version": command(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
                "pairs": args.pairs, "sources": {}, "compiled_sources": {}, "binaries": {},
                "native_libraries": {}, "driver_files": {},
                "allocator_metric": "malloc_zone_statistics(NULL).size_in_use",
                "resident_metric": "task_info(MACH_TASK_BASIC_INFO).resident_size"}
    for name in ["run.py", "Harness.swift", "Heap.c", "Heap.h", "module.modulemap", "generate-fixtures.py"]:
        data = (HERE / name).read_bytes()
        (output / name).write_bytes(data)
        manifest["driver_files"][name] = sha(data)
    manifest["shared_build_helper_sha256"] = BUILD.file_sha(HERE.parent / "AttachmentAdmission/run.py")
    (output / "shared-build-helper.py").write_bytes((HERE.parent / "AttachmentAdmission/run.py").read_bytes())
    cmodule = output / "CFFmpeg"
    (cmodule / "include").mkdir(parents=True)
    for path in BUILD.C_SOURCES:
        (cmodule / Path(path).relative_to("Sources/CFFmpeg")).write_text(original["candidate"][path])
    headers = {}
    for library in BUILD.LIBRARIES:
        directory = prefix / "include" / f"lib{library}"
        if not directory.is_dir():
            raise ValueError(f"Missing FFmpeg headers: {directory}")
        for header in sorted(directory.rglob("*.h")):
            headers[str(header.relative_to(prefix / "include"))] = BUILD.file_sha(header)
        dylib = (prefix / "lib" / f"lib{library}.dylib").resolve(strict=True)
        manifest["native_libraries"][library] = {"path": str(dylib), "sha256": BUILD.file_sha(dylib)}
    write_json(output / "headers.json", headers)
    manifest["headers_manifest_sha256"] = BUILD.file_sha(output / "headers.json")
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
             "-sdk", sdk, "-I", cmodule, "-Xcc", "-I" + str(prefix / "include"),
             "-L", prefix / "lib", "-Xlinker", "-rpath", "-Xlinker", prefix / "lib",
             "-module-cache-path", output / "module-cache",
             "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox"]
    manifest["flags"] = list(map(str, flags))
    prepared_inputs = {}
    for variant in VARIANTS:
        directory = output / variant
        directory.mkdir()
        manifest["sources"][variant] = {}
        inputs = []
        for path, value in original[variant].items():
            destination = output / "sources" / variant / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(value)
            manifest["sources"][variant][path] = sha(value)
            if path in BUILD.FULL_SOURCES:
                # Complete production files, with no source rewriting.
                inputs.append(destination)
        error = BUILD.extract(original[variant][BUILD.PRESENTATION],
                              "struct PresentationError:", "\nfunc checkOSStatus(")
        packets = BUILD.extract(original[variant][BUILD.BITMAP],
                                "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
        helper = directory / "ExtractedDeclarations.swift"
        helper.write_text("import Foundation\n\n" + error + "\n" + packets)
        inputs.append(helper)
        manifest["compiled_sources"][variant] = {str(p.relative_to(output)): BUILD.file_sha(p) for p in inputs}
        prepared_inputs[variant] = inputs
    # Preserve both source snapshots and their provenance even if compilation fails.
    write_json(output / "manifest.json", manifest)
    command(["xcrun", "clang", "-O2", "-isysroot", sdk, "-c", output / "Heap.c",
             "-o", output / "Heap.o"], "heap-build.log")
    executables = {}
    for variant in VARIANTS:
        directory = output / variant
        inputs = prepared_inputs[variant]
        library = directory / "libAuxiliaryInput.dylib"
        command([compiler, *flags, "-emit-library", "-emit-module", "-enable-testing",
                 "-module-name", "AuxiliaryInput", "-emit-module-path", directory / "AuxiliaryInput.swiftmodule",
                 "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAuxiliaryInput.dylib",
                 *inputs, "-o", library], f"{variant}-library.log")
        executable = directory / "auxiliary-memory"
        condition = ["-D", "CANDIDATE"] if variant == "candidate" else []
        command([compiler, *flags, *condition, "-I", output, "-I", directory, "-L", directory,
                 "-lAuxiliaryInput", "-Xlinker", "-rpath", "-Xlinker", directory,
                 output / "Harness.swift", output / "Heap.o", "-o", executable], f"{variant}-driver.log")
        manifest["binaries"][variant] = {"library_sha256": BUILD.file_sha(library),
                                         "executable_sha256": BUILD.file_sha(executable)}
        executables[variant] = executable
    write_json(output / "manifest.json", manifest)
    observations = []
    summaries = []
    for case in cases:
        for mode, count in SCENARIOS:
            cohort = []
            reference = None
            for pair in range(args.pairs):
                ordering = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                for order, variant in enumerate(ordering):
                    raw = command([executables[variant], fixtures / case["filename"], mode, count,
                                   fixtures / "none.mkv", case["font_bytes"]])
                    sample = json.loads(raw)
                    if sample["mode"] != mode or sample["auxiliary_count"] != count:
                        raise ValueError("Harness scenario receipt mismatch")
                    for metric in ["heap_before_bytes", "heap_retained_bytes", "heap_delta_bytes",
                                   "resident_before_bytes", "resident_retained_bytes", "resident_delta_bytes",
                                   "peak_rss_bytes", "primary_font_bytes", "auxiliary_font_bytes"]:
                        if type(sample[metric]) is not int:
                            raise ValueError(f"Noninteger byte metric: {metric}")
                        if metric in ["heap_before_bytes", "heap_retained_bytes", "resident_before_bytes",
                                      "resident_retained_bytes", "peak_rss_bytes"] and sample[metric] <= 0:
                            raise ValueError(f"Failed native memory probe: {metric}")
                    for metric in ["open_wall_seconds", "open_cpu_seconds"]:
                        value = sample[metric]
                        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                            raise ValueError(f"Invalid timing metric: {metric}")
                    for metric_prefix in ["heap", "resident"]:
                        if sample[f"{metric_prefix}_delta_bytes"] != sample[f"{metric_prefix}_retained_bytes"] - sample[f"{metric_prefix}_before_bytes"]:
                            raise ValueError(f"Incorrect memory delta: {metric_prefix}")
                    snapshots = sample.pop("inputs")
                    if len(snapshots) != count + 1 or sample["primary_font_bytes"] != case["font_bytes"]:
                        raise ValueError("Input or primary font count mismatch")
                    if len(snapshots[0]["attachments"]) != case["font_count"]:
                        raise ValueError("Primary font inventory mismatch")
                    expected_aux = count * case["font_bytes"] if variant == "baseline" else 0
                    if sample["auxiliary_font_bytes"] != expected_aux:
                        raise ValueError("Unexpected auxiliary font payload")
                    normalized = copy.deepcopy(snapshots)
                    for index, info in enumerate(normalized):
                        if not info["packets"] or not info["seek_packets"]:
                            raise ValueError("Empty packet parity fixture")
                        if index:
                            if variant == "baseline" and info["attachments"] != normalized[0]["attachments"]:
                                raise ValueError("Baseline auxiliary font mismatch")
                            if variant == "candidate" and info["attachments"]:
                                raise ValueError("Candidate retained auxiliary font metadata")
                            info["attachments"] = []
                    if reference is None:
                        reference = normalized
                    if normalized != reference:
                        raise ValueError("Complete metadata, codec-private or packet output differs")
                    output_path = output / "outputs" / f"{case['name']}-{mode}-{count}-{variant}.json"
                    if not output_path.exists():
                        write_json(output_path, snapshots)
                    elif json.loads(output_path.read_text()) != snapshots:
                        raise ValueError("Same-variant output changed between repetitions")
                    sample.update(case=case["name"], variant=variant, pair=pair, order=order,
                                  output_sha256=sha(json.dumps(snapshots, sort_keys=True)))
                    observations.append(sample)
                    cohort.append(sample)
                    with (output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(sample, sort_keys=True, allow_nan=False) + "\n")
            summary = {"case": case["name"], "mode": mode, "auxiliary_count": count,
                       "font_bytes_per_input": case["font_bytes"], "pairs": args.pairs,
                       "saved_auxiliary_payload_bytes": count * case["font_bytes"]}
            for metric in ["heap_delta_bytes", "resident_delta_bytes", "peak_rss_bytes",
                           "open_wall_seconds", "open_cpu_seconds"]:
                a = [next(x[metric] for x in cohort if x["variant"] == "baseline" and x["pair"] == p)
                     for p in range(args.pairs)]
                b = [next(x[metric] for x in cohort if x["variant"] == "candidate" and x["pair"] == p)
                     for p in range(args.pairs)]
                summary[metric] = {"baseline_median": statistics.median(a),
                                   "candidate_median": statistics.median(b),
                                   "median_paired_saving": statistics.median([x-y for x,y in zip(a,b)]),
                                   "baseline_range": [min(a), max(a)], "candidate_range": [min(b), max(b)],
                                   "favorable_pairs": sum(y < x for x,y in zip(a,b))}
            summaries.append(summary)
            write_json(output / "summary.json", summaries)
            print(json.dumps({k: summary[k] for k in ["case", "mode", "auxiliary_count", "heap_delta_bytes"]}), flush=True)
    if len(observations) != len(cases) * len(SCENARIOS) * args.pairs * 2:
        raise ValueError("Incomplete measurement matrix")
    for path, value in original["candidate"].items():
        if BUILD.file_sha(ROOT / path) != sha(value):
            raise ValueError(f"Production source changed during measurement: {path}")
    for name, digest in manifest["driver_files"].items():
        if BUILD.file_sha(HERE / name) != digest:
            raise ValueError(f"Benchmark driver changed during measurement: {name}")
    if BUILD.file_sha(HERE.parent / "AttachmentAdmission/run.py") != manifest["shared_build_helper_sha256"]:
        raise ValueError("Shared build helper changed during measurement")
    for case in cases:
        if BUILD.file_sha(fixtures / case["filename"]) != case["sha256"]:
            raise ValueError(f"Fixture changed during measurement: {case['name']}")
    write_json(output / "completion.json", {"observations": len(observations),
                                           "pairs": len(observations)//2, "all_outputs_match": True})


if __name__ == "__main__":
    main()
