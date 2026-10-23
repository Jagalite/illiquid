#!/usr/bin/env python3
"""Measure idle ownership using the full native compositor, baseline and candidate."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
COMPOSITOR = Path("Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift")
CACHE = Path("Sources/IlliquidNativePlayback/Presentation/PiPSubtitleUploadCache.swift")
PROBE_TEST = Path("Tests/IlliquidNativePlaybackTests/PiPIdleResourcesMemoryProbeTests.swift")
NORMAL_TEST = Path("Tests/IlliquidNativePlaybackTests/PiPIdleResourceRetirementTests.swift")
WORKLOADS = ("sdr-1080p", "hdr-pq-4k")
BYTE_FIELDS = ("hdrTextureAllocatedBytes", "subtitleTextureAllocatedBytes",
               "subtitleVertexAllocatedBytes", "stagingBytes", "preparedPixelBytes")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, anchor: str) -> str:
    """Copy one known observation declaration verbatim, with exact-anchor checks."""
    if source.count(anchor) != 1:
        raise ValueError(f"Expected exactly one observation anchor: {anchor}")
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(f"Unclosed observation declaration: {anchor}")


def instrument_baseline(baseline: str, candidate: str) -> tuple[str, dict]:
    probes = {
        "snapshot": declaration(candidate, "struct PiPSubtitleResourceSnapshot:"),
        "method": declaration(candidate, "    func resourceSnapshotForTesting()"),
    }
    anchors = {"snapshot": "struct PiPSubtitleCompositionMetrics:",
               "method": "    func composedPixelBufferForTesting("}
    result = baseline
    for name, probe in probes.items():
        anchor = anchors[name]
        if result.count(anchor) != 1 or probe in result:
            raise ValueError(f"Baseline insertion boundary changed: {name}")
        result = result.replace(anchor, probe + "\n\n" + anchor, 1)
    return result, {name: sha(probe.encode()) for name, probe in probes.items()}


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.ordinal = 0

    def command(self, args: list[str | Path], *, environment: dict | None = None,
                timeout: int = 1200) -> str:
        argv = [str(arg) for arg in args]
        log = self.output / f"command-{self.ordinal:02d}.log"
        started = time.monotonic()
        print(f"[{self.ordinal}] {' '.join(argv)}", flush=True)
        with log.open("w") as stream:
            result = subprocess.run(argv, cwd=ROOT, env=environment,
                                    stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        receipt = {"command": argv, "returncode": result.returncode,
                   "elapsed_seconds": time.monotonic() - started, "log": log.name}
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(receipt, sort_keys=True) + "\n")
        self.ordinal += 1
        contents = log.read_text()
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{contents[-16000:]}")
        return contents


def summarize(rows: list[dict]) -> list[dict]:
    result = []
    for workload in WORKLOADS:
        selected = [row for row in rows if row["workload"] == workload]
        outputs = [row["firstOutput"] for row in selected]
        if not outputs or any(output != outputs[0] for output in outputs):
            raise ValueError(f"Baseline/candidate output mismatch: {workload}")
        variants = {}
        for variant in dict.fromkeys(row["variant"] for row in selected):
            measured = [row for row in selected if row["variant"] == variant]
            stages = {}
            for phase in ("composed", "stopped", "reentered", "stoppedAgain",
                          "stoppedAgainAfterSettling", "finalIdleAfterFiveSeconds"):
                values = {key: statistics.median(row[phase]["resources"][key] for row in measured)
                          for key in BYTE_FIELDS}
                values["budgetStagingBytes"] = statistics.median(row[phase]["budgetStagingBytes"]
                                                                 for row in measured)
                values["allHaveOutputPool"] = all(row[phase]["resources"]["hasOutputPool"]
                                                  for row in measured)
                stages[phase] = values
            cycles = []
            for index in range(8):
                observed = [row["productionCycles"][index] for row in measured]
                cycles.append({
                    "cycle": index + 1,
                    "firstSampleMilliseconds": [cycle["firstSampleNanoseconds"] / 1e6
                                                for cycle in observed],
                    "diagnosticDeviceAllocatedBytes": {
                        phase: [cycle[phase]["resources"]["deviceAllocatedBytes"] for cycle in observed]
                        for phase in ("active", "stopped", "stoppedAfter150Milliseconds",
                                      "stoppedAfterOneSecond")
                    },
                    "medianStoppedOwnedResourceBytes": {
                        key: statistics.median(cycle["stoppedAfterOneSecond"]["resources"][key]
                                               for cycle in observed) for key in BYTE_FIELDS
                    },
                    "medianStoppedBudgetStagingBytes": statistics.median(
                        cycle["stoppedAfterOneSecond"]["budgetStagingBytes"] for cycle in observed),
                })
            variants[variant] = {
                "processes": len(measured), "medianStages": stages,
                "reentryFirstSampleMilliseconds": [row["reentryFirstSampleNanoseconds"] / 1e6
                                                    for row in measured],
                "medianReentryFirstSampleMilliseconds": statistics.median(
                    row["reentryFirstSampleNanoseconds"] / 1e6 for row in measured),
                "diagnosticDeviceAllocatedBytesAfterStop": [
                    row["stoppedAfterSettling"]["resources"]["deviceAllocatedBytes"]
                    for row in measured],
                "diagnosticDeviceAllocatedBytesAfterSecondStop": [
                    row["stoppedAgainAfterSettling"]["resources"]["deviceAllocatedBytes"]
                    for row in measured],
                "productionOnlyCycles": cycles,
                "diagnosticDeviceAllocatedBytesAfterFinalFiveSecondIdle": [
                    row["finalIdleAfterFiveSeconds"]["resources"]["deviceAllocatedBytes"]
                    for row in measured],
            }
        result.append({"workload": workload, "outputParity": True,
                       "output": outputs[0], "variants": variants})
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--retirement-only-control", help="Optional historical compositor commit with matching observation declarations")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build/pip-idle-resources")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This benchmark requires macOS 26, Metal, and the pinned native SDK")
    if args.repetitions < 1:
        raise SystemExit("repetitions must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit("Use a new empty output directory")
    runner = Runner(output)
    compositor = ROOT / COMPOSITOR
    probe_path = ROOT / PROBE_TEST
    normal_path = ROOT / NORMAL_TEST
    if probe_path.exists():
        raise SystemExit(f"Refusing to overwrite existing probe: {probe_path}")
    original = compositor.read_bytes()
    candidate = original.decode()
    normal_tests = normal_path.read_bytes() if normal_path.exists() else None
    baseline_sha = runner.command(["git", "rev-parse", f"{args.baseline}^{{commit}}"] ).strip()
    baseline = runner.command(["git", "show", f"{baseline_sha}:{COMPOSITOR}"])
    baseline_cache = runner.command(["git", "show", f"{baseline_sha}:{CACHE}"])
    candidate_cache = (ROOT / CACHE).read_text()
    cache_probe = declaration(candidate_cache, "    var retainedResourceBytesForTesting:")
    if candidate_cache.replace(cache_probe + "\n\n", "", 1) != baseline_cache:
        raise ValueError("Upload cache differs beyond the common read-only observation property")
    instrumented, probes = instrument_baseline(baseline, candidate)
    variants = [("baseline", instrumented.encode())]
    control_receipt = None
    if args.retirement_only_control:
        control_sha = runner.command(["git", "rev-parse", f"{args.retirement_only_control}^{{commit}}"] ).strip()
        control = runner.command(["git", "show", f"{control_sha}:{COMPOSITOR}"])
        for anchor in ("struct PiPSubtitleResourceSnapshot:", "    func resourceSnapshotForTesting()"):
            if declaration(control, anchor) != declaration(candidate, anchor):
                raise ValueError(f"Historical control observation differs: {anchor}")
        control_cache = runner.command(["git", "show", f"{control_sha}:{CACHE}"])
        if control_cache != candidate_cache:
            raise ValueError("Historical control upload cache differs from the common candidate cache")
        (output / "retirement-only-compositor.swift").write_text(control)
        control_receipt = {"commit": control_sha, "compositor_sha256": sha(control.encode()),
                           "common_observation_sha256": probes,
                           "common_upload_cache_sha256": sha(control_cache.encode())}
        variants.append(("retirement-only", control.encode()))
    variants.append(("candidate", original))
    (output / "baseline-compositor.swift").write_text(baseline)
    (output / "baseline-observed-compositor.swift").write_text(instrumented)
    (output / "candidate-compositor.swift").write_bytes(original)
    receipt = {
        "baseline_commit": baseline_sha,
        "candidate_commit": runner.command(["git", "rev-parse", "HEAD"]).strip(),
        "baseline_compositor_sha256": sha(baseline.encode()),
        "baseline_observed_compositor_sha256": sha(instrumented.encode()),
        "retirement_only_control": control_receipt,
        "candidate_compositor_sha256": sha(original),
        "common_observation_sha256": probes,
        "common_upload_cache_sha256": sha(candidate_cache.encode()),
        "upload_cache_probe_sha256": sha(cache_probe.encode()),
        "harness_sha256": sha((HERE / "MemoryProbeTests.swift").read_bytes()),
        "runner_sha256": sha(Path(__file__).read_bytes()),
        "package_resolved_sha256": sha((ROOT / "Package.resolved").read_bytes()),
        "native_sdk_manifest_sha256": sha((ROOT / "BuildInputs/native-sdk.json").read_bytes()),
        "method": "Full native SwiftPM test graph; common candidate dependencies; only compositor behavior differs. Baseline receives the identical read-only snapshot struct/method. Upload cache differs from pinned baseline only by its common read-only observation property.",
        "order": "Baseline, optional historical retirement-only control, then candidate; each in fresh test processes. Timing is a secondary reentry-cost observation, not a throughput or speedup gate.",
        "lifecycle": "Two initial sessions with companion readbacks, then eight production-only start/stop cycles. Each additional stop is sampled after drainage, 150 ms, and one second; final idle sample follows four further seconds. Owners remain alive throughout. Device allocation has no arbitrary pass threshold.",
        "resource_fields_are_not_additive": True,
    }
    save(output / "source-receipt.json", receipt)
    save(output / "environment.json", {
        "platform": platform.platform(), "machine": platform.machine(),
        "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "swift": runner.command(["swift", "--version"]).strip(),
        "macos": runner.command(["sw_vers"]).strip(),
        "hardware": runner.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
    })
    rows = []
    # `swift build --build-tests` does not enable @testable imports in release.
    # Apply the same testing visibility to both measured variants and test runs.
    swift_options = ["--force-resolved-versions", "--configuration", "release",
                     "-Xswiftc", "-enable-testing",
                     "--jobs", str(args.jobs), "--scratch-path", str(args.scratch_path.resolve())]
    try:
        probe_path.write_bytes((HERE / "MemoryProbeTests.swift").read_bytes())
        # Candidate-only retirement assertions intentionally fail on baseline.
        # Restore this exact file before the normal native regression suite.
        if normal_tests is not None:
            normal_path.unlink()
        for variant, source in variants:
            compositor.write_bytes(source)
            runner.command(["swift", "build", *swift_options, "--build-tests"])
            for repetition in range(args.repetitions):
                for workload in WORKLOADS:
                    report = output / f"{variant}-{workload}-{repetition}.json"
                    environment = os.environ.copy()
                    environment.update(ILLIQUID_PIP_IDLE_VARIANT=variant,
                                       ILLIQUID_PIP_IDLE_WORKLOAD=workload,
                                       ILLIQUID_PIP_IDLE_REPORT=str(report))
                    runner.command(["swift", "test", *swift_options, "--skip-build", "--no-parallel",
                                    "--filter", "PiPIdleResourcesMemoryProbeTests"],
                                   environment=environment, timeout=120)
                    row = json.loads(report.read_text())
                    if row["variant"] != variant or row["workload"] != workload:
                        raise ValueError("Measurement identity mismatch")
                    if row["firstOutput"] != row["reenteredOutput"]:
                        raise ValueError("Restart output mismatch")
                    if [cycle["cycle"] for cycle in row["productionCycles"]] != list(range(1, 9)):
                        raise ValueError("Production-only cycle measurements are incomplete")
                    row["repetition"] = repetition
                    rows.append(row)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
        summary = summarize(rows)
        save(output / "summary.json", summary)
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
    finally:
        compositor.write_bytes(original)
        if probe_path.exists():
            probe_path.unlink()
        if normal_tests is not None:
            normal_path.write_bytes(normal_tests)
        save(output / "restoration.json", {
            "candidate_compositor_restored": compositor.read_bytes() == original,
            "normal_tests_restored": normal_tests is None or normal_path.read_bytes() == normal_tests,
            "temporary_probe_removed": not probe_path.exists(),
        })
    save(output / "completion.json", {"measurements": len(rows), "outputParity": True,
                                      "variants": [variant for variant, _ in variants],
                                      "candidateRetirementAssertionsPassed": True,
                                      "productionOnlyCycles": sum(len(row["productionCycles"]) for row in rows),
                                      "finalFiveSecondIdleSamples": len(rows),
                                      "deviceAllocationThresholdApplied": False})


if __name__ == "__main__":
    main()
