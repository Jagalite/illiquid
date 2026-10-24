#!/usr/bin/env python3
"""Reproduce audio-delay output parity and retained PCM payload ownership.

macOS uses real CoreMedia. Linux substitutes only the documented rational-time
shim and provides component evidence, never native-player memory or latency.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
TIMELINE = "Sources/IlliquidNativePlayback/Media/AudioDelayTimeline.swift"
DECODER = "Sources/IlliquidNativePlayback/Media/AudioDecoder.swift"
EXISTING_TESTS = "Tests/IlliquidNativePlaybackTests/AudioDelayTests.swift"
MEMORY_TESTS = "Tests/IlliquidNativePlaybackTests/AudioDelayMemoryTests.swift"
LIFETIME_TESTS = [
    "sourcePCMIsReleasedAfterEmittedFramesAreDiscarded",
    "fullyTrimmedSourcePCMIsReleased",
    "canceledSourceEmissionReleasesPCM",
    "canceledSilenceEmissionReleasesSourceAndPreservesAcceptedCursor",
    "emittedPCMRemainsAliveUntilConsumerReleasesIt",
]
BEHAVIOR_FILTER = ("AudioDelayTests|latestSourceMetadataDrivesTailSilence|"
                   "positivePaddingPreservesSilenceBoundaries|emptyTimelineEmitsOneSilentFallbackSample|"
                   "silenceFramesKeepValueSemanticsWhenCopiedAndTrimmed")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if path.suffix == ".gz":
        path.write_bytes(gzip.compress(data, mtime=0))
    else:
        path.write_bytes(data)


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def command(arguments: list, output: Path, log: str, *, expected_failure: bool = False) -> str:
    arguments = [str(argument) for argument in arguments]
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"), TERM="dumb", NO_COLOR="1")
    result = subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=600)
    combined = result.stdout + result.stderr
    if log.endswith(".gz"):
        (output / log).write_bytes(gzip.compress(combined.encode(), mtime=0))
    else:
        (output / log).write_text(combined)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": arguments, "returncode": result.returncode,
                                 "log": log, "expected_failure": expected_failure}) + "\n")
    if expected_failure:
        # A compiler error or missing tool is never accepted as proof of the
        # old ownership defect. Require all five chosen tests to report failure.
        failed = set(re.findall(r"Test ([A-Za-z0-9_]+)\([^\n]* failed after", combined))
        if result.returncode != 1 or failed != set(LIFETIME_TESTS):
            raise RuntimeError(f"Expected only the five baseline lifetime failures; got {failed}\n{combined}")
    elif result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments}\n{combined}")
    return result.stdout


def stage(output: Path, variant: str) -> dict:
    package = output / variant
    receipts = {}

    def source(path: str) -> bytes:
        data = git("show", f"{BASELINE}:{path}") if variant == "baseline" else (ROOT / path).read_bytes()
        receipts[path] = {"original_sha256": digest(data), "transformation": "none"}
        return data

    def write(path: str, data: bytes) -> None:
        target = package / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    timeline = source(TIMELINE)
    write("Sources/IlliquidNativePlayback/AudioDelayTimeline.swift", timeline)
    decoder = source(DECODER)
    begin = decoder.index(b"struct NativeDecodedAudioFrame: Sendable {")
    end = decoder.index(b"/// Maps decoded source timestamps", begin)
    frame = b"import CoreMedia\nimport Foundation\n\n" + decoder[begin:end]
    write("Sources/IlliquidNativePlayback/NativeDecodedAudioFrame.swift", frame)
    receipts[DECODER].update(transformation="Exact frame struct and trimming extension, with imports",
                             byte_start=begin, byte_end=end, extracted_sha256=digest(frame))
    for name in ["Harness.swift", "CoreMediaShim.swift"]:
        data = (HERE / name).read_bytes()
        target = ("Sources/CoreMedia/CoreMediaShim.swift" if name.startswith("CoreMedia")
                  else "Sources/AudioDelayMemory/Harness.swift")
        if name == "Harness.swift" or platform.system() == "Linux":
            write(target, data)
    memory_tests = (ROOT / MEMORY_TESTS).read_bytes()
    write("Tests/IlliquidNativePlaybackTests/AudioDelayMemoryTests.swift", memory_tests)
    existing = (ROOT / EXISTING_TESTS).read_bytes()
    # Keep the three exact existing component tests. Native session/runtime
    # integration remains in the full application's macOS test graph.
    cutoff = existing.index(b"    @Test @MainActor")
    portable = existing[:cutoff].replace(b"import IlliquidCore\n", b"").replace(b"import IlliquidPlayback\n", b"") + b"}\n"
    write("Tests/IlliquidNativePlaybackTests/AudioDelayTests.swift", portable)
    receipts[EXISTING_TESTS] = {"original_sha256": digest(existing), "extracted_sha256": digest(portable),
        "transformation": "Three existing component tests before first native @MainActor test; unused imports removed"}
    receipts[MEMORY_TESTS] = {"original_sha256": digest(memory_tests), "transformation": "none"}
    shim_target = '.target(name: "CoreMedia"),' if platform.system() == "Linux" else ""
    dependencies = '["CoreMedia"]' if platform.system() == "Linux" else '[]'
    manifest = f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AudioDelayMemory", platforms: [.macOS("26.0")],
    products: [.executable(name: "AudioDelayMemory", targets: ["AudioDelayMemory"])],
    targets: [
        {shim_target}
        .target(name: "IlliquidNativePlayback", dependencies: {dependencies},
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "AudioDelayMemory", dependencies: ["IlliquidNativePlayback"]),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])
    ], swiftLanguageModes: [.v6])
'''
    write("Package.swift", manifest.encode())
    return receipts


def swift_command(args: argparse.Namespace, variant: str, operation: str, configuration: str) -> list:
    result = [args.swift, operation, "--package-path", args.output / variant,
              "--configuration", configuration, "--jobs", "2",
              "--cache-path", args.output / "cache", "--config-path", args.output / "config",
              "--security-path", args.output / "security", "-Xswiftc", "-warnings-as-errors"]
    if platform.system() == "Linux":
        result.append("--use-integrated-swift-driver")
    return result


def compare(baseline: dict, candidate: dict) -> list:
    before = [item["semantic"] for item in baseline["scenarios"]]
    after = [item["semantic"] for item in candidate["scenarios"]]
    if before != after:
        raise ValueError("Complete output receipts differ")
    for variant, report in [("baseline", baseline), ("candidate", candidate)]:
        life = report["sourceLifetime"]
        expected = 0 if variant == "baseline" else 1
        if (not life["consumeSucceeded"] or life["releasesWhileTimelineIsAlive"] != expected
                or life["releasesAfterTimelineReset"] != 1):
            raise ValueError(f"Unexpected source PCM ownership receipt: {variant}: {life}")
    summaries = []
    for old, new in zip(baseline["scenarios"], candidate["scenarios"], strict=True):
        semantic = old["semantic"]
        name = semantic["scenario"]
        if name.startswith("padding_10s"):
            channels = 8 if name.endswith("8ch") else 2
            if (len(semantic["frames"]) != 469 or sum(f["sampleCount"] for f in semantic["frames"]) != 480_000
                    or not all(f["allZero"] for f in semantic["frames"])):
                raise ValueError("Incorrect ten-second padding output")
            for report, expected in [(old, 48 * 1_024 * channels * 4), (new, 1_024 * channels * 4)]:
                full = [batch for batch in report["batches"] if batch["frames"] == 48]
                if len(full) != 9 or any(b["uniqueBorrowedPCMBytes"] != expected for b in full):
                    raise ValueError(f"Unexpected full-batch backing storage: {name}: {full}")
        summaries.append({"scenario": name, "emitted_frames": len(semantic["frames"]),
            "emitted_samples": sum(f["sampleCount"] for f in semantic["frames"]),
            "output_parity": True,
            "baseline_batches": old["batches"], "candidate_batches": new["batches"]})
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; final evidence must include tests")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    manifest = {"baseline_commit": BASELINE, "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "candidate_source": "current worktree", "platform": platform.platform(), "machine": platform.machine(),
        "compiler": command([args.swift, "--version"], args.output, "compiler.log").strip(),
        "coremedia": "Linux rational-time shim" if platform.system() == "Linux" else "Apple CoreMedia",
        "method": "Exact production timeline and frame/trimming declarations; debug/release fresh processes",
        "metric": "Union of simultaneously borrowed PCM payload byte ranges in batches of up to 48 frames",
        "exclusions": "Not malloc block sizes, cumulative allocation counts, renderer memory, process RSS, or timing",
        "small_controls": "Inline/small Data cases are output-size controls; borrowed ranges are not allocator observations",
        "tests_skipped": args.skip_tests,
        "harness_sha256": {name: digest((HERE / name).read_bytes()) for name in ["run.py", "Harness.swift", "CoreMediaShim.swift"]},
        "source_receipts": {}, "binary_sha256": {}}
    reports = {}
    for variant in ["baseline", "candidate"]:
        manifest["source_receipts"][variant] = stage(args.output, variant)
        save(args.output / "manifest.json", manifest)
        for configuration in ["debug", "release"]:
            label = f"{variant}-{configuration}"
            print(f"Build {label}", flush=True)
            command([*swift_command(args, variant, "build", configuration), "--product", "AudioDelayMemory"],
                    args.output, f"{label}-build.log")
            bin_path = command([*swift_command(args, variant, "build", configuration), "--show-bin-path"],
                               args.output, f"{label}-bin-path.log").strip()
            binary = Path(bin_path) / "AudioDelayMemory"
            manifest["binary_sha256"][label] = digest(binary.read_bytes())
            stdout = command([binary], args.output, f"{label}-receipt.json.gz")
            reports[label] = json.loads(stdout)
            if not args.skip_tests:
                print(f"Test {label}", flush=True)
                arguments = swift_command(args, variant, "test", configuration)
                if variant == "baseline":
                    command([*arguments, "--filter", BEHAVIOR_FILTER], args.output, f"{label}-behavior-tests.log")
                    command([*arguments, "--skip-build", "--filter", "|".join(LIFETIME_TESTS)],
                            args.output, f"{label}-expected-lifetime-failures.log", expected_failure=True)
                else:
                    command(arguments, args.output, f"{label}-tests.log")
            save(args.output / "manifest.json", manifest)
    summaries = {configuration: compare(reports[f"baseline-{configuration}"], reports[f"candidate-{configuration}"])
                 for configuration in ["debug", "release"]}
    # Keep the complete per-frame receipts compact, including both build modes.
    save(args.output / "observations.json.gz", reports)
    save(args.output / "summary.json", summaries)
    print("PASS: 12 scenarios match in debug/release; bounded payload sharing and source release verified", flush=True)


if __name__ == "__main__":
    main()
