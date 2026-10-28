#!/usr/bin/env python3
"""Qualify video-format reuse with exact production blocks and native CoreMedia."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shlex
import shutil
import statistics
import subprocess
import sys
import time
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TESTS = ("VideoFormatDescriptionCacheTests",)
PRESENTATION = ROOT / "Sources/IlliquidNativePlayback/Presentation"
SIGNPOSTS = ROOT / "Sources/IlliquidNativePlayback/Diagnostics/NativePlaybackSignposts.swift"
VARIANTS = ("baseline", "candidate")
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6"]
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_blob_digest(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def production_adapter(baseline: str, candidate: str) -> str:
    """Extract only native creation blocks; do not substitute CoreMedia stubs."""
    start = baseline.index("        var formatDescription: CMVideoFormatDescription?")
    end = baseline.index("\n\n        var timing = CMSampleTimingInfo(", start)
    format_block = baseline[start:end]
    wrapped_start = candidate.index(
        "        let formatDescription = try formatDescriptionCache.formatDescription(for: frame.pixelBuffer) {\n"
    )
    wrapped_end = candidate.index("\n\n        var timing = CMSampleTimingInfo(", wrapped_start)
    wrapped = candidate[wrapped_start:wrapped_end]
    lines = wrapped.splitlines()
    if lines[-2:] != ["            return formatDescription", "        }"]:
        raise RuntimeError("unexpected candidate format-description wrapper")
    unwrapped = "\n".join(line[4:] for line in lines[1:-2])
    if unwrapped != format_block:
        raise RuntimeError("candidate changed the native creation block")
    reconstructed = candidate[:wrapped_start] + format_block + candidate[wrapped_end:]
    reconstructed = reconstructed.replace(
        "    private let formatDescriptionCache = VideoFormatDescriptionCache()\n", "", 1
    ).replace("        formatDescriptionCache.reset()\n", "", 1)
    if reconstructed != baseline:
        raise RuntimeError("presenter changed outside the reviewed cache integration")

    sample_start = baseline.index("        var timing = CMSampleTimingInfo(", end)
    sample_end = baseline.index("        frame.planarOwnershipToken?", sample_start)
    sample_block = baseline[sample_start:sample_end].rstrip()
    errors = baseline[baseline.index("struct PresentationError:"):].strip()
    native_format = textwrap.dedent(format_block).replace("frame.pixelBuffer", "buffer")
    native_sample = (textwrap.dedent(sample_block)
                     .replace("frame.pixelBuffer", "buffer")
                     .replace("frame.duration", "duration")
                     .replace("frame.presentationTime", "time"))
    return (
        "import CoreMedia\nimport CoreVideo\nimport Foundation\n\n"
        "// Native blocks below are extracted from the pinned production presenter.\n"
        "public final class FormatDescriptionBenchmark {\n"
        "#if CANDIDATE\n"
        "    private let cache = VideoFormatDescriptionCache()\n"
        "#endif\n"
        "    public init() {}\n\n"
        "    public func reset() {\n"
        "#if CANDIDATE\n"
        "        cache.reset()\n"
        "#endif\n"
        "    }\n\n"
        "    public func formatDescription(for buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {\n"
        "#if CANDIDATE\n"
        "        return try cache.formatDescription(for: buffer) { try makeFormat(for: buffer) }\n"
        "#else\n"
        "        return try makeFormat(for: buffer)\n"
        "#endif\n"
        "    }\n\n"
        "    private func makeFormat(for buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {\n"
        + textwrap.indent(native_format, "        ") + "\n"
        "        return formatDescription\n"
        "    }\n\n"
        "    public func sampleBuffer(for buffer: CVPixelBuffer, time: CMTime,\n"
        "                             duration: CMTime) throws -> CMSampleBuffer {\n"
        "        let formatDescription = try self.formatDescription(for: buffer)\n"
        + textwrap.indent(native_sample, "        ") + "\n"
        "        return sampleBuffer\n"
        "    }\n"
        "}\n\n" + errors + "\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("tests", "benchmark", "all"), default="all")
    parser.add_argument("--pairs", type=positive_int, default=10)
    parser.add_argument("--target-ms", type=positive_int, default=100)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pairs % 2:
        parser.error("--pairs must be even to balance variant execution order")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Refuse reuse so earlier evidence cannot be silently overwritten or mixed.
    if any(output.iterdir()):
        parser.error("--output must be an empty or new directory")
    logs = output / "logs"
    logs.mkdir()
    command_log = output / "commands.jsonl"
    raw = output / "observations.jsonl"
    state = {"status": "running", "mode": args.mode, "pairs": args.pairs,
             "target_ms": args.target_ms, "tests": [], "summaries": []}

    def save_state() -> None:
        (output / "summary.json").write_text(json.dumps(state, indent=2) + "\n")

    def append(path: Path, value: dict) -> None:
        with path.open("a") as handle:
            handle.write(json.dumps(value, separators=(",", ":")) + "\n")

    def run(command: list[str], name: str) -> str:
        started = time.time()
        append(command_log, {"event": "start", "name": name, "command": command,
                             "cwd": str(ROOT), "started_unix": started})
        log = logs / (name + ".log")
        print("COMMAND " + shlex.join(command), flush=True)
        with log.open("w") as handle:
            process = subprocess.run(command, cwd=ROOT, text=True, stdout=handle,
                                     stderr=subprocess.STDOUT, check=False)
        append(command_log, {"event": "finish", "name": name,
                             "exit_code": process.returncode,
                             "wall_seconds": time.time() - started})
        text = log.read_text()
        if process.returncode:
            print(text[-20000:], flush=True)
            raise RuntimeError(f"{name} failed with exit {process.returncode}; see {log}")
        return text

    save_state()
    try:
        manifest = json.loads((HERE / "baseline/manifest.json").read_text())
        if manifest["baseline_commit"] != BASELINE_COMMIT:
            raise RuntimeError("unexpected frozen baseline commit")
        pinned = HERE / "baseline/SampleBufferVideoPresenter.swift"
        if git_blob_digest(pinned) != manifest["presenter_git_blob"]:
            raise RuntimeError("frozen presenter differs from the pinned source")
        if git_blob_digest(SIGNPOSTS) != manifest["signposts_git_blob"]:
            raise RuntimeError("signpost source differs from the pinned source")
        baseline_available = subprocess.run(
            ["git", "cat-file", "-e", BASELINE_COMMIT + "^{commit}"],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode == 0
        if baseline_available:
            for path, expected in (
                (manifest["presenter_path"], manifest["presenter_git_blob"]),
                (manifest["signposts_path"], manifest["signposts_git_blob"]),
            ):
                observed = run(["git", "rev-parse", BASELINE_COMMIT + ":" + path],
                               "audit-baseline-" + Path(path).stem).strip()
                if observed != expected:
                    raise RuntimeError("manifest does not identify the pinned baseline tree")
        candidate_presenter = PRESENTATION / "SampleBufferVideoPresenter.swift"
        helper = PRESENTATION / "VideoFormatDescriptionCache.swift"
        adapter = production_adapter(pinned.read_text(), candidate_presenter.read_text())
        snapshots = output / "sources"
        support = snapshots / "qualification"
        support.mkdir(parents=True)
        receipts: dict[str, dict] = {}
        support_sources = [
            HERE / "Harness.swift", HERE / "run.py", HERE / "baseline/manifest.json",
            pinned, candidate_presenter, helper, SIGNPOSTS,
            ROOT / "Tests/IlliquidNativePlaybackTests/VideoFormatDescriptionCacheTests.swift",
        ]
        for source in support_sources:
            name = "baseline-presenter.swift" if source == pinned else source.name
            shutil.copyfile(source, support / name)
            receipts["qualification/" + name] = {"sha256": digest(source)}
        sources: dict[str, list[Path]] = {}
        for variant in VARIANTS:
            folder = snapshots / variant
            folder.mkdir()
            api = folder / "BenchmarkAPI.swift"
            api.write_text(adapter)
            signposts = folder / "NativePlaybackSignposts.swift"
            shutil.copyfile(SIGNPOSTS, signposts)
            sources[variant] = [api, signposts]
            if variant == "candidate":
                cached = folder / helper.name
                shutil.copyfile(helper, cached)
                sources[variant].append(cached)
            for source in sources[variant]:
                receipts[variant + "/" + source.name] = {"sha256": digest(source)}
        metadata = {
            "schema_version": 1, "baseline": manifest,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "candidate-commit").strip(),
            "candidate_status": run(["git", "status", "--short"], "candidate-status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run(["swiftc", "--version"], "swift-version").strip(),
            "compiler_flags": FLAGS, "cross_module_optimization": False,
            "production_module_linkage": "dynamic, separately compiled from driver",
            "source_sha256": receipts, "pairs": args.pairs, "target_ms": args.target_ms,
            "calibration": "All baseline calibration trials retained; one shared iteration count per workload.",
            "initial_calibration_iterations": 1,
            "sampling": "Fresh process per variant/pair; baseline-first and candidate-first pairs alternate.",
            "scope": "Native format/sample construction including result consumption; no decoding or rendering.",
            "baseline_tree_verified": baseline_available,
            "adapter": "Exact format/sample/error blocks extracted from pinned presenter; only cache wrapper differs.",
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
        }
        if sys.platform == "darwin":
            metadata["macos"] = run(["sw_vers"], "macos-version").strip()
            metadata["xcode"] = run(["xcodebuild", "-version"], "xcode-version").strip()
            metadata["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
        if metadata["candidate_status"]:
            raise RuntimeError("qualification requires a clean checkout and output outside the repository")

        if args.mode in ("tests", "all"):
            for variant in ("candidate",):
                for configuration in ("debug", "release"):
                    work = output / "build" / f"tests-{variant}-{configuration}"
                    src = work / "Sources/IlliquidNativePlayback"
                    tests = work / "Tests/IlliquidNativePlaybackTests"
                    src.mkdir(parents=True)
                    tests.mkdir(parents=True)
                    for source in sources[variant]:
                        shutil.copyfile(source, src / source.name)
                    for name in TESTS:
                        shutil.copyfile(support / (name + ".swift"), tests / (name + ".swift"))
                    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "VideoFormatQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback", swiftSettings: [.define("CANDIDATE")]),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
                    label = f"tests-{variant}-{configuration}"
                    result = run(["swift", "test", "--package-path", str(work),
                                  "--no-parallel", "-c", configuration], label)
                    state["tests"].append({"variant": variant, "configuration": configuration,
                                           "passed": True, "log": f"logs/{label}.log"})
                    print("TEST_PASS " + variant + " " + configuration, flush=True)
                    print("\n".join(result.splitlines()[-8:]), flush=True)
                    save_state()

        if args.mode in ("benchmark", "all"):
            executables = {}
            for variant in VARIANTS:
                work = output / "build" / variant
                work.mkdir(parents=True)
                extension = "dylib" if sys.platform == "darwin" else "so"
                variant_flags = ["-D", "CANDIDATE"] if variant == "candidate" else []
                run(["swiftc", *FLAGS, *variant_flags, "-emit-library", "-emit-module", "-module-name", "IlliquidFormatBenchmark",
                     "-emit-module-path", str(work / "IlliquidFormatBenchmark.swiftmodule"),
                     *(str(source) for source in sources[variant]),
                     "-o", str(work / f"libIlliquidFormatBenchmark.{extension}")], f"compile-{variant}-module")
                executable = work / "video-format-benchmark"
                run(["swiftc", *FLAGS, "-parse-as-library", "-I", str(work), "-L", str(work),
                     "-lIlliquidFormatBenchmark", "-Xlinker", "-rpath", "-Xlinker", str(work),
                     str(support / "Harness.swift"), "-o", str(executable)], f"compile-{variant}-driver")
                executables[variant] = executable
                metadata.setdefault("binary_sha256", {})[variant] = {
                    "library": digest(work / f"libIlliquidFormatBenchmark.{extension}"),
                    "driver": digest(executable),
                }
                (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
            workloads = json.loads(run([str(executables["baseline"]), "--list"], "list-workloads"))
            candidate_workloads = json.loads(run([str(executables["candidate"]), "--list"], "list-candidate-workloads"))
            if workloads != candidate_workloads:
                raise RuntimeError("baseline and candidate workload manifests differ")
            (output / "workloads.json").write_text(json.dumps(workloads, indent=2) + "\n")
            for workload in workloads:
                identifier = workload["id"]
                # Calibrate using baseline only; use the same count for both
                # variants and retain every calibration observation.
                iterations = 1
                for trial in range(8):
                    label = f"calibrate-{identifier}-{trial}"
                    row = json.loads(run([str(executables["baseline"]), identifier, str(iterations)], label))
                    row.update({"phase": "calibration", "variant": "baseline", "trial": trial})
                    append(raw, row)
                    elapsed = row["elapsedMilliseconds"]
                    if elapsed >= args.target_ms / 2 or iterations >= 10_000_000 or trial == 7:
                        break
                    iterations = min(10_000_000, max(iterations + 1,
                        math.ceil(iterations * args.target_ms / max(elapsed, 0.000001))))
                samples = {variant: [] for variant in VARIANTS}
                pair_ratios = []
                candidate_faster_pairs = 0
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    paired = {}
                    paired_receipts = {}
                    for position, variant in enumerate(order):
                        label = f"measure-{identifier}-{pair}-{variant}"
                        row = json.loads(run([str(executables[variant]), identifier, str(iterations)], label))
                        row.update({"phase": "measurement", "variant": variant,
                                    "pair": pair, "position_in_pair": position})
                        append(raw, row)
                        value = row["nanosecondsPerCall"]
                        samples[variant].append(value)
                        paired[variant] = value
                        paired_receipts[variant] = (row["expectedChecksumPerCall"], row["checksum"], row["iterations"])
                        if row["iterations"] != iterations or row["workload"] != workload:
                            raise RuntimeError(f"observation receipt mismatch: {identifier} {variant}")
                    if paired_receipts["baseline"] != paired_receipts["candidate"]:
                        raise RuntimeError(f"baseline/candidate result receipt mismatch: {identifier} pair {pair}")
                    pair_ratios.append(paired["candidate"] / paired["baseline"])
                    candidate_faster_pairs += paired["candidate"] < paired["baseline"]
                before = statistics.median(samples["baseline"])
                after = statistics.median(samples["candidate"])
                summary = {"workload": workload, "iterations": iterations, "pairs": args.pairs,
                           "baseline_median_ns": before, "candidate_median_ns": after,
                           "reduction_percent": 100 * (1 - after / before),
                           "median_paired_reduction_percent": 100 * (1 - statistics.median(pair_ratios)),
                           "candidate_faster_pairs": candidate_faster_pairs,
                           "baseline_median_process_ms": before * iterations / 1_000_000,
                           "candidate_median_process_ms": after * iterations / 1_000_000,
                           "baseline_median_ns_per_frame": before / workload["unitsPerCall"],
                           "candidate_median_ns_per_frame": after / workload["unitsPerCall"],
                           "baseline_min_ns": min(samples["baseline"]),
                           "baseline_max_ns": max(samples["baseline"]),
                           "candidate_min_ns": min(samples["candidate"]),
                           "candidate_max_ns": max(samples["candidate"])}
                state["summaries"].append(summary)
                print("BENCHMARK_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)
                save_state()
        state["status"] = "passed"
        save_state()
        print("QUALIFICATION_PASS " + json.dumps({"tests": len(state["tests"]),
              "workloads": len(state["summaries"]), "pairs": args.pairs}), flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        save_state()
        raise


if __name__ == "__main__":
    main()
