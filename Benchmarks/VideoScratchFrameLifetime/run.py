#!/usr/bin/env python3
"""Compare actual old/new native VideoDecoder scratch-frame ownership on macOS.

The tracked allocation is the synthetic source AVBuffer supplied to the real
decoder receive path. It is not process RSS, codec-private storage, a renderer
measurement, or a whole-player memory estimate. Every timed observation is a
fresh test process; baseline and candidate alternate within each paired round.
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
import shutil
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
DECODER = Path("Sources/IlliquidNativePlayback/Media/VideoDecoder.swift")
HARNESS_FILES = [
    Path("Tests/IlliquidNativePlaybackTests/VideoScratchFrameLifetimeTests.swift"),
    Path("Tests/IlliquidNativePlaybackTests/VideoScratchFrameLifetimeMeasurements.swift"),
]
TIMESTAMP_TESTS = Path("Tests/IlliquidNativePlaybackTests/VideoTimestampDiscoveryTests.swift")
RECEIPT_FILES = [
    DECODER,
    Path("Sources/CFFmpeg/include/ffmpeg_shim.h"),
    Path("Package.swift"),
    Path("Package.resolved"),
    Path("BuildInputs/native-sdk.json"),
    Path("DependencySources/source-manifest.json"),
]
VARIANTS = ("baseline", "candidate")
MARKER = "VIDEO_SCRATCH_MEASUREMENT "


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def workloads() -> list[dict]:
    cases = []
    for mode in ("frame-throw", "frame-cancel", "reservation-denied", "timestamp-throw"):
        for label, width, height in (("small", 64, 48), ("1080p", 1920, 1080), ("4k", 3840, 2160)):
            cases.append(dict(name=f"{mode}-{label}", width=width, height=height,
                              mode=mode, iterations=1))
    for label, width, height in (("small", 64, 48), ("1080p", 1920, 1080)):
        cases.append(dict(name=f"normal-control-{label}", width=width, height=height,
                          mode="normal", iterations=100))
    return cases


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.commands: list[dict] = []

    def run(self, argv: list, *, env: dict | None = None, timeout: int = 300,
            label: str = "command") -> str:
        command = [str(item) for item in argv]
        started = time.monotonic()
        log = f"{len(self.commands):03}-{label}.log"
        timed_out = False
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=timeout, check=False)
            raw, code = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            raw = error.stdout or ""
            if isinstance(raw, bytes):
                raw = raw.decode(errors="replace")
            raw += f"\nCommand exceeded its {timeout}-second timeout.\n"
            code, timed_out = None, True
        except OSError as error:
            raw, code = str(error) + "\n", None
        (self.output / log).write_text(raw)
        self.commands.append(dict(argv=command, exit=code, log=log,
                                  seconds=time.monotonic() - started,
                                  timeout_seconds=timeout, timed_out=timed_out))
        save(self.output / "commands.json", self.commands)
        if code != 0:
            raise RuntimeError(f"Command failed; full log: {self.output / log}\n"
                               f"{command}\n{raw[-18000:]}")
        return raw


def validate_record(row: dict, case: dict, variant: str) -> None:
    # Identity checks prevent a disabled/misconfigured Swift test from producing
    # a plausible record for a different workload.
    if row.get("scenario") != case["name"]:
        raise RuntimeError(f"Measurement did not execute requested scenario: {case} / {row}")
    for key in ("mode", "width", "height", "iterations"):
        if row.get(key) != case[key]:
            raise RuntimeError(f"Measurement did not execute requested {key}: {case} / {row}")
    for key, value in row.items():
        if isinstance(value, float) and not math.isfinite(value):
            raise RuntimeError(f"Nonfinite measurement {key}: {row}")
    for key in ("payload_bytes", "storage_bytes"):
        if type(row.get(key)) is not int or row[key] <= 0:
            raise RuntimeError(f"Missing/invalid tracked allocation size: {key} / {row}")
    if row["storage_bytes"] < row["payload_bytes"]:
        raise RuntimeError(f"Tracked storage is smaller than the source pixel payload: {row}")
    for key in ("wall_ns_per_decode", "cpu_ns_per_decode"):
        if type(row.get(key)) not in (int, float) or row[key] < 0 or not math.isfinite(row[key]):
            raise RuntimeError(f"Missing/invalid decode timing: {key} / {row}")

    retains_source = variant == "baseline" and case["mode"] != "normal"
    expected_references = 2 if retains_source else 1
    expected_releases = 0 if retains_source else 1
    expectations = {
        "packet_refcounts_after_decode": [expected_references] * case["iterations"],
        "source_release_counts_after_packet_release": [expected_releases] * case["iterations"],
        "retained_payload_bytes_after_packet_release": row["payload_bytes"] if retains_source else 0,
        "retained_storage_bytes_after_packet_release": row["storage_bytes"] if retains_source else 0,
        # These scalar fields describe the LAST probe. Each iteration has its
        # own callback tracker, including in the 100-decode normal controls.
        "source_release_count_after_flush": expected_releases,
        "source_release_count_after_decoder_destroy": 1,
        "output_count": 0 if case["mode"] == "reservation-denied" else case["iterations"],
    }
    for key, expected in expectations.items():
        if row.get(key) != expected:
            raise RuntimeError(f"Unexpected {variant} ownership/output result for {key}: "
                               f"expected {expected!r}, received {row.get(key)!r}; {row}")
    if row.get("all_sources_released_exactly_once") is not True:
        raise RuntimeError(f"A tracked source leaked or was destroyed more than once: {row}")
    expected_timestamp_sum = case["iterations"] * (case["iterations"] - 1) * 0.02
    if type(row.get("timestamp_sum")) not in (int, float) or not math.isclose(
            row["timestamp_sum"], expected_timestamp_sum, rel_tol=1e-10, abs_tol=1e-10):
        raise RuntimeError(f"Unexpected delivered timestamp sum: {row}")
    emits_pixels = case["mode"] not in ("reservation-denied", "timestamp-throw")
    hashes = [row.get(key) for key in ("output_sha256_before_flush", "output_sha256_after_flush",
                                     "output_sha256_after_decoder_destroy")]
    if emits_pixels:
        if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes):
            raise RuntimeError(f"Expected checksums of all held output pixels: {row}")
        if len(set(hashes)) != 1 or not isinstance(row.get("output_metadata"), dict):
            raise RuntimeError(f"Held output changed across decoder cleanup or metadata is absent: {row}")
    elif hashes != [None, None, None] or row.get("output_metadata") is not None:
        raise RuntimeError(f"Timestamp/rejected-reservation case unexpectedly emitted pixel output: {row}")


def validate_pair(before: dict, after: dict) -> None:
    for key in ("scenario", "width", "height", "mode", "iterations", "payload_bytes", "storage_bytes",
                "output_count", "timestamp_sum", "output_metadata", "output_sha256_before_flush",
                "output_sha256_after_flush", "output_sha256_after_decoder_destroy"):
        if before[key] != after[key]:
            raise RuntimeError(f"Baseline/candidate output mismatch in {before['scenario']}: {key}\n"
                               f"baseline={before[key]!r}\ncandidate={after[key]!r}")


def numeric_summary(rows: list[dict], cases: list[dict], pairs: int) -> list[dict]:
    summary = []
    for case in cases:
        observations = {variant: [row for row in rows
                        if row["scenario"] == case["name"] and row["variant"] == variant]
                        for variant in VARIANTS}
        if any(len(value) != pairs for value in observations.values()):
            raise RuntimeError(f"Incomplete paired observations for {case['name']}")
        metrics = ("retained_payload_bytes_after_packet_release", "retained_storage_bytes_after_packet_release",
                   "wall_ns_per_decode", "cpu_ns_per_decode")
        record = dict(workload=case, pairs=pairs, metrics={},
                      payload_bytes=observations["baseline"][0]["payload_bytes"],
                      storage_bytes=observations["baseline"][0]["storage_bytes"])
        for metric in metrics:
            values = {variant: [row[metric] for row in observations[variant]]
                      for variant in VARIANTS}
            statistics_by_variant = {
                variant: dict(median=statistics.median(value), min=min(value), max=max(value))
                for variant, value in values.items()
            }
            # A zero baseline is meaningful for exact lifetime counters; do not
            # manufacture a percentage for it.
            reductions = [(1 - after / before) * 100
                          for before, after in zip(values["baseline"], values["candidate"])
                          if before != 0]
            statistics_by_variant["paired_reduction_percent_median"] = (
                statistics.median(reductions) if len(reductions) == pairs else None)
            record["metrics"][metric] = statistics_by_variant
        summary.append(record)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="New evidence/build directory; existing evidence is never overwritten")
    parser.add_argument("--fixtures", type=Path, required=True,
                        help="Output of Benchmarks/FrameStepTimestamps/generate-fixtures.py")
    parser.add_argument("--pairs", type=int, default=4)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("The real CoreMedia/CoreVideo decoder and native tests require macOS.")
    if not 2 <= args.pairs <= 12:
        parser.error("--pairs must be between 2 and 12.")
    if args.output.exists():
        parser.error("--output must be a new directory.")
    fixtures = args.fixtures.resolve()
    manifest_path = fixtures / "fixture-manifest.json"
    if not manifest_path.is_file():
        parser.error("Generate the required timestamp fixture manifest before running this benchmark.")
    output = args.output.resolve()
    output.mkdir(parents=True)
    shutil.copy2(Path(__file__).resolve(), output / "runner.py")
    runner = Runner(output)
    completion = dict(succeeded=False, baseline_commit=BASELINE)
    save(output / "completion.json", completion)
    try:
        baseline = runner.run(["git", "rev-parse", f"{BASELINE}^{{commit}}"],
                              timeout=30, label="baseline-commit").strip()
        if baseline != BASELINE:
            raise RuntimeError("Pinned baseline did not resolve to the expected commit.")
        environment = {
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_commit": baseline,
            "candidate_commit": runner.run(["git", "rev-parse", "HEAD"],
                                             timeout=30, label="candidate-commit").strip(),
            "candidate_worktree_status": runner.run(["git", "status", "--short", "--untracked-files=no"],
                                                      timeout=30, label="worktree-status").strip(),
            "runner_sha256": digest(Path(__file__).resolve()),
            "swift": runner.run(["swift", "--version"], timeout=30, label="swift-version").strip(),
            "xcode": runner.run(["xcodebuild", "-version"], timeout=30, label="xcode-version").strip(),
            "macos": runner.run(["sw_vers"], timeout=30, label="macos-version").strip(),
            "sdk": runner.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                               timeout=30, label="sdk-version").strip(),
            "hardware": runner.run(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"],
                                    timeout=30, label="hardware").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "pairs": args.pairs, "build": "SwiftPM release, production package, two jobs, serial tests",
            "method": "alternating AB/BA pairs of fresh measurement processes; one separate warm-up decoder "
                      "per process, measured decoder initially cold; build probes excluded",
            "scope": "tracked source AVBuffer payload and destructor callbacks in actual VideoDecoder paths; "
                     "not process RSS, codec-private allocations, renderer memory, or whole-player RAM",
        }
        save(output / "environment.json", environment)

        manifest = json.loads(manifest_path.read_text())
        if manifest.get("schemaVersion") != 1 or not manifest.get("fixtures"):
            raise RuntimeError("Required timestamp fixture manifest is empty or unsupported.")
        fixture_receipts = []
        for fixture in manifest["fixtures"]:
            path = fixtures / fixture["filename"]
            if not path.is_file() or digest(path) != fixture["sha256"]:
                raise RuntimeError(f"Required fixture is absent or has changed: {path}")
            fixture_receipts.append(dict(file=path.name, sha256=digest(path), bytes=path.stat().st_size))
        save(output / "fixtures.json", dict(manifest_sha256=digest(manifest_path), files=fixture_receipts))
        shutil.copy2(manifest_path, output / "fixture-manifest.json")

        cases = workloads()
        save(output / "workloads.json", cases)
        baseline_tree = output / "baseline-tree"
        runner.run(["git", "worktree", "add", "--detach", baseline_tree, baseline],
                   timeout=180, label="baseline-worktree")
        for path in HARNESS_FILES:
            shutil.copy2(ROOT / path, baseline_tree / path)
        roots = {"baseline": baseline_tree, "candidate": ROOT}

        receipts = {}
        for variant, root in roots.items():
            receipt = {str(path): digest(root / path)
                       for path in [*RECEIPT_FILES, *HARNESS_FILES, TIMESTAMP_TESTS]}
            production = {str(path.relative_to(root)): digest(path)
                          for path in sorted((root / "Sources").rglob("*")) if path.is_file()}
            receipts[variant] = dict(files=receipt, production=production)
            for relative in [*RECEIPT_FILES, *HARNESS_FILES, TIMESTAMP_TESTS]:
                destination = output / "sources" / variant / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(root / relative, destination)
        differences = sorted(path for path in set(receipts["baseline"]["production"])
                             | set(receipts["candidate"]["production"])
                             if receipts["baseline"]["production"].get(path)
                             != receipts["candidate"]["production"].get(path))
        save(output / "sources.json", dict(variants=receipts, production_differences=differences))
        if differences != [str(DECODER)]:
            raise RuntimeError(f"Comparison must isolate VideoDecoder.swift; observed differences: {differences}")
        for path in [*HARNESS_FILES, *RECEIPT_FILES[1:]]:
            if receipts["baseline"]["files"][str(path)] != receipts["candidate"]["files"][str(path)]:
                raise RuntimeError(f"Paired comparison input differs: {path}")

        base_environment = os.environ.copy()
        base_environment.update(ILLIQUID_VIDEO_SCRATCH_MEASURE="1",
                                ILLIQUID_FRAME_STEP_FIXTURE_DIR=str(fixtures),
                                ILLIQUID_FRAME_STEP_REQUIRE_FIXTURES="1", TERM="dumb", NO_COLOR="1")

        def swift_command(variant: str, suite: str, *, skip_build: bool = True) -> list:
            command = ["swift", "test", "--package-path", roots[variant],
                       "--scratch-path", output / f"{variant}-build",
                       "--force-resolved-versions", "-c", "release", "--jobs", "2",
                       "--no-parallel", "--filter", suite]
            if skip_build:
                command.append("--skip-build")
            return command

        def measure(variant: str, case: dict, *, build: bool = False) -> dict:
            env = base_environment.copy()
            env["ILLIQUID_VIDEO_SCRATCH_WORKLOAD"] = json.dumps(case, sort_keys=True)
            raw = runner.run(swift_command(variant, "VideoScratchFrameLifetimeMeasurements", skip_build=not build),
                             env=env, timeout=2400 if build else 300,
                             label=f"{variant}-{'build' if build else case['name']}")
            matches = re.findall(r"^" + re.escape(MARKER) + r"(\{.*\})$", raw, re.MULTILINE)
            if len(matches) != 1:
                raise RuntimeError("Expected exactly one VIDEO_SCRATCH_MEASUREMENT record; inspect test discovery.")
            row = json.loads(matches[0])
            validate_record(row, case, variant)
            return row

        binaries = {}
        for variant in VARIANTS:
            print(f"Building actual {variant} application/test graph", flush=True)
            probe = measure(variant, cases[0], build=True)
            save(output / f"{variant}-build-probe.json", probe)
            bin_path = Path(runner.run(
                ["swift", "build", "--package-path", roots[variant],
                 "--scratch-path", output / f"{variant}-build", "-c", "release", "--show-bin-path"],
                timeout=60, label=f"{variant}-bin-path").strip())
            executables = [path for bundle in bin_path.glob("*.xctest")
                           for path in (bundle / "Contents" / "MacOS").glob("*") if path.is_file()]
            if not executables:
                raise RuntimeError(f"Cannot locate the native test executable in {bin_path}")
            binaries[variant] = [{"path": str(path), "sha256": digest(path), "bytes": path.stat().st_size}
                                 for path in sorted(executables)]
            save(output / "binaries.json", binaries)

        regression_results = []
        for suite in ("VideoScratchFrameLifetimeTests", "VideoTimestampDiscoveryTests"):
            print(f"Qualifying candidate {suite}", flush=True)
            env = base_environment.copy()
            env["ILLIQUID_VIDEO_SCRATCH_MEASURE"] = "0"
            env.pop("ILLIQUID_VIDEO_SCRATCH_WORKLOAD", None)
            raw = runner.run(swift_command("candidate", suite), env=env, timeout=600,
                             label=f"candidate-{suite}")
            counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", raw)
            if len(counts) != 1 or int(counts[0]) == 0:
                raise RuntimeError(f"Expected a successful, nonempty native regression suite: {suite}")
            regression_results.append(dict(suite=suite, passed_tests=int(counts[0]),
                                           log=runner.commands[-1]["log"]))
            save(output / "regressions.json", regression_results)

        observations = []
        for case in cases:
            print(f"Measuring {case['name']} ({args.pairs} alternating pairs)", flush=True)
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                pair_rows = {}
                for variant in order:
                    row = measure(variant, case)
                    row.update(variant=variant, pair=pair, ordinal=len(observations),
                               log=runner.commands[-1]["log"])
                    observations.append(row)
                    pair_rows[variant] = row
                    with (output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
                validate_pair(pair_rows["baseline"], pair_rows["candidate"])

        summary = numeric_summary(observations, cases, args.pairs)
        save(output / "summary.json", summary)
        for variant in VARIANTS:
            for binary in binaries[variant]:
                if digest(Path(binary["path"])) != binary["sha256"]:
                    raise RuntimeError(f"{variant} test executable changed after build.")
            for path, expected in receipts[variant]["files"].items():
                if digest(roots[variant] / path) != expected:
                    raise RuntimeError(f"{variant} input changed during measurement: {path}")
        completion.update(succeeded=True, candidate_commit=environment["candidate_commit"],
                          observations=len(observations), expected_observations=len(cases) * args.pairs * 2,
                          workloads=len(cases), pairs=args.pairs, regressions=regression_results,
                          alternating_order=True, source_and_binary_hashes_unchanged=True,
                          native_fixture_checksums_verified=True,
                          paired_output_comparisons=len(cases) * args.pairs,
                          pixel_and_timestamp_outputs_equal=True,
                          expected_ownership_and_destructor_counts_verified=True)
        save(output / "completion.json", completion)
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
    except BaseException as error:
        completion.update(error=f"{type(error).__name__}: {error}")
        save(output / "completion.json", completion)
        raise


if __name__ == "__main__":
    main()
