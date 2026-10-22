#!/usr/bin/env python3
"""Native exact-setter qualification for presentation observation cadence admission."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "a2de305c8dbcaa81aac1477df7c9a0017c14eae3"
HELPER = "Sources/IlliquidNativePlayback/Production/PresentationObservationCadence.swift"
COORDINATOR = "Sources/IlliquidNativePlayback/Presentation/NativePresentationCoordinator.swift"
RUNTIME = "Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift"
TESTS = "Tests/IlliquidNativePlaybackTests/PresentationObservationCadenceTests.swift"
CASES = ("steady-4hz", "steady-24hz", "steady-30hz", "steady-60hz", "steady-120hz",
         "periodic-transitions", "alternating-control")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def region(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError("Production extraction boundaries changed; review the harness")
    first, last = source.index(start), source.index(end)
    if first >= last:
        raise RuntimeError("Production extraction order changed")
    return source[first:last]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=7)
    parser.add_argument("--requests", type=int, default=100_000)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Requires native macOS CoreMedia and Dispatch; no Linux adapters are used")
    if args.pairs < 2 or args.requests < 1:
        parser.error("--pairs must be at least 2 and --requests must be positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"

    def run(command: list[str | Path], log: Path | None = None, timeout: int = 600) -> str:
        command = [str(item) for item in command]
        start = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=environment, text=True,
                                capture_output=True, timeout=timeout)
        row = dict(command=command, returncode=result.returncode,
                   seconds=time.monotonic() - start,
                   stdout=result.stdout, stderr=result.stderr)
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        if log:
            log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    setter_start = "    func setPresentationTimeObservationInterval(_ interval: CMTime) {"
    setter_end = "    /// Media-time callbacks stop repeating while paused"
    current_coordinator = (ROOT / COORDINATOR).read_text()
    setter = region(current_coordinator, setter_start, setter_end)
    original_coordinator = run(["git", "show", f"{BASELINE}:{COORDINATOR}"])
    if setter != region(original_coordinator, setter_start, setter_end):
        raise RuntimeError("Coordinator setter changed since baseline; requalify the experiment")
    policy = region((ROOT / RUNTIME).read_text(), "enum NativeSubtitleRenderPolicy {",
                    "/// Periodic diagnostics deliberately expose enqueue horizons")
    original_runtime = run(["git", "show", f"{BASELINE}:{RUNTIME}"])
    if policy != region(original_runtime, "enum NativeSubtitleRenderPolicy {",
                        "/// Periodic diagnostics deliberately expose enqueue horizons"):
        raise RuntimeError("Cadence interval policy changed since baseline")
    inputs = {
        "PresentationObservationCadence.swift": (ROOT / HELPER).read_bytes(),
        "Benchmark.swift": (HERE / "Benchmark.swift").read_bytes(),
        "ProductionSetter.swift": ("import CoreMedia\n\nextension BenchmarkPresentationReceiver {\n"
                                   + setter + "}\n").encode(),
        "NativeSubtitleRenderPolicy.swift": ("import CoreMedia\n\n" + policy).encode(),
        "PresentationObservationCadenceTests.swift": (ROOT / TESTS).read_bytes(),
        "run.py": Path(__file__).read_bytes(),
    }
    staged = output / "sources"
    staged.mkdir()
    for name, data in inputs.items():
        (staged / name).write_bytes(data)
    compiler = run(["xcrun", "--find", "swiftc"]).strip()
    swift = run(["xcrun", "--find", "swift"]).strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
             "-sdk", sdk, "-target", f"{platform.machine()}-apple-macos26.0",
             "-module-cache-path", str(output / "module-cache")]
    host = dict(platform=platform.platform(), machine=platform.machine(),
                python=platform.python_version(), compiler=run([compiler, "--version"]),
                os_version=run(["sw_vers"]), xcode=run(["xcodebuild", "-version"]),
                hardware=run(["sysctl", "hw.model", "hw.ncpu", "machdep.cpu.brand_string"]),
                sdk=sdk, flags=flags, baseline_revision=BASELINE,
                candidate_revision=run(["git", "rev-parse", "HEAD"]).strip(),
                working_tree=run(["git", "status", "--porcelain"]),
                pairs=args.pairs, requests=args.requests,
                source_sha256={name: sha(data) for name, data in inputs.items()},
                production_source_sha256={path: sha((ROOT / path).read_bytes())
                                          for path in (HELPER, COORDINATOR, RUNTIME, TESTS)},
                exact_setter_sha256=sha(setter.encode()), exact_policy_sha256=sha(policy.encode()),
                scope="Cadence admission and uncontended synchronous queue entry; observer replacement is a recorder")
    save(output / "environment.json", host)

    if not args.skip_tests:
        package = output / "tests"
        source_dir = package / "Sources/IlliquidNativePlayback"
        test_dir = package / "Tests/IlliquidNativePlaybackTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        (source_dir / "PresentationObservationCadence.swift").write_bytes(inputs["PresentationObservationCadence.swift"])
        (test_dir / "PresentationObservationCadenceTests.swift").write_bytes(inputs["PresentationObservationCadenceTests.swift"])
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "PresentationObservationCadenceQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
''')
        for configuration in ("debug", "release"):
            print(f"Testing exact production gate: {configuration}", flush=True)
            run([swift, "test", "--package-path", package, "--jobs", "2", "--no-parallel",
                 "--configuration", configuration], output / f"tests-{configuration}.log")
    binaries = {}
    swift_sources = [staged / name for name in (
        "PresentationObservationCadence.swift", "NativeSubtitleRenderPolicy.swift",
        "ProductionSetter.swift", "Benchmark.swift")]
    for variant in ("baseline", "candidate"):
        binary = output / variant
        definition = ["-D", "CANDIDATE"] if variant == "candidate" else []
        run([compiler, *flags, *definition, *swift_sources, "-o", binary])
        binaries[variant] = binary
    binary_hashes = {name: sha(path.read_bytes()) for name, path in binaries.items()}
    save(output / "binary-sha256.json", binary_hashes)

    verification = {name: json.loads(run([binary, "verify"])) for name, binary in binaries.items()}
    save(output / "verification.json", verification)
    def behavior(records: list[dict]) -> list[dict]:
        return [{key: value for key, value in record.items() if key != "queue_sync_entries"}
                for record in records]
    if behavior(verification["baseline"]) != behavior(verification["candidate"]):
        raise RuntimeError("Effective interval histories differ between baseline and candidate")
    if len(verification["candidate"]) != len(CASES) + 2:
        raise RuntimeError("Incomplete verification cohort")
    for record in verification["candidate"]:
        if record["workload"].startswith("steady-") and record["queue_sync_entries"] != 1:
            raise RuntimeError("Stable cadence did not admit exactly the first request")
        if record["workload"].startswith("receiver-lifetime-") and record["effective_changes"] != 1:
            raise RuntimeError("New receiver did not receive its independent initial cadence")
    print("Verified exact effective-change traces, steady admission, and receiver ownership", flush=True)

    rows = []
    if not args.verify_only:
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            cases = CASES[pair % len(CASES):] + CASES[:pair % len(CASES)]
            for case in cases:
                paired = []
                for variant in order:
                    row = json.loads(run([binaries[variant], "measure", case, str(args.requests)]))
                    if row["workload"] != case or row["requests"] != args.requests or row["wall_ns"] <= 0:
                        raise RuntimeError("Invalid benchmark result")
                    row.update(pair=pair, variant=variant)
                    rows.append(row)
                    paired.append(row)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                if any(paired[0][key] != paired[1][key] for key in
                       ("effective_changes", "final_interval", "requests", "warmup_requests")):
                    raise RuntimeError(f"Timed receiver results differ: {case}")
            print(f"Finished pair {pair + 1}/{args.pairs}", flush=True)
        summary = []
        for case in CASES:
            subset = [r for r in rows if r["workload"] == case]
            before = [r["ns_per_request"] for r in subset if r["variant"] == "baseline"]
            after = [r["ns_per_request"] for r in subset if r["variant"] == "candidate"]
            base, candidate = statistics.median(before), statistics.median(after)
            row = dict(workload=case, baseline_median_ns=base, candidate_median_ns=candidate,
                       median_paired_savings_ns=statistics.median(a - b for a, b in zip(before, after)),
                       median_paired_reduction_percent=statistics.median(
                           100 * (1 - b / a) for a, b in zip(before, after)),
                       baseline_ns=before, candidate_ns=after,
                       queue_sync_entries={variant: sorted({r["queue_sync_entries"] for r in subset
                                                           if r["variant"] == variant})
                                           for variant in ("baseline", "candidate")})
            summary.append(row)
            print(f"{case}: {base:.1f} -> {candidate:.1f} ns/request; "
                  f"queue entries {row['queue_sync_entries']}", flush=True)
        save(output / "summary.json", summary)
    if any((staged / name).read_bytes() != data for name, data in inputs.items()):
        raise RuntimeError("Staged source changed during qualification")
    if any(sha(path.read_bytes()) != binary_hashes[name] for name, path in binaries.items()):
        raise RuntimeError("Executable changed during qualification")
    expected = 0 if args.verify_only else args.pairs * len(CASES) * 2
    if len(rows) != expected:
        raise RuntimeError("Incomplete measurement cohort")
    save(output / "completion.json", dict(verified=True, completed_measurements=len(rows),
         expected_measurements=expected, debug_release_tests=not args.skip_tests,
         staged_sources_unchanged=True, binaries_unchanged=True))


if __name__ == "__main__":
    main()
