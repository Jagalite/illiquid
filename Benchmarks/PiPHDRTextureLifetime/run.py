#!/usr/bin/env python3
"""Measure native PiP HDR texture ownership using pinned old/new production code.

The same observation-only hooks and tests run in both variants. These receipts
describe Metal resource lifetime/allocatedSize, not process RSS or frame rate.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
COMPOSITOR = Path("Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift")
MARKER = "PIP_HDR_LIFETIME_MEASUREMENT "
VARIANTS = ("baseline", "candidate")
REGRESSIONS = (
    "PiPHDRTextureLifetimeTests|PiPSubtitlePipelineTests|PiPSubtitleUploadReuseTests|"
    "PiPVideoMappingTests|PiPSubtitleCompositionPolicyTests|MetalASSSubtitleCompositorTests"
)


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.commands = []

    def run(self, argv, *, env=None, timeout=300, label="command") -> str:
        command = list(map(str, argv))
        print(f"Running {label}", flush=True)
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False)
        log = f"{len(self.commands):03}-{label}.log"
        (self.output / log).write_text(result.stdout)
        self.commands.append(dict(argv=command, exit=result.returncode, log=log,
                                  seconds=time.monotonic() - started))
        save(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{result.stdout[-18000:]}")
        return result.stdout


def verify(row: dict, workload: dict, variant: str) -> None:
    for key, value in workload.items():
        if row.get("workload" if key == "name" else key) != value:
            raise RuntimeError(f"Wrong workload {key}: {row}")
    logical = workload["width"] * workload["height"] * 8
    allocated = row.get("allocatedTextureBytes")
    if type(allocated) is not int or allocated < logical:
        raise RuntimeError(f"Missing or undersized native allocation: {row}")
    expected_retained = allocated if variant == "baseline" else 0
    checks = dict(
        logicalTextureBytes=logical,
        activeResourceReused=True,
        retainedAllocatedBytesAfterStop=expected_retained,
        textureAliveAfterStop=(variant == "baseline"),
        compositorOwnsTextureAfterStop=(variant == "baseline"),
        reentryAllocatedTextureBytes=allocated,
        reentryImmediatelyDisplayedFrames=1,
        retainedAllocatedBytesAfterFinalStop=expected_retained,
    )
    for key, value in checks.items():
        if row.get(key) != value:
            raise RuntimeError(f"Unexpected {variant} {key}: expected {value}, got {row}")
    before = row.get("outputBeforeStop")
    if not isinstance(before, dict) or not re.fullmatch(r"[0-9a-f]{64}", before.get("sha256", "")):
        raise RuntimeError(f"Missing full visible-plane checksum: {row}")
    if not all(before.get(key) for key in ("transferFunction", "primaries", "matrix")):
        raise RuntimeError(f"Missing HDR color tags: {row}")
    if before != row.get("outputAfterStop") or before != row.get("outputAfterReentry"):
        raise RuntimeError(f"Output changed across stop or paused reentry: {row}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.pairs <= 10:
        parser.error("--pairs must be in 1...10")
    if platform.system() != "Darwin":
        raise RuntimeError("This experiment requires native macOS, Metal and the pinned SDK.")
    if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
        print("Kyoto is unavailable; builds run sequentially in isolated scratch directories.", flush=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    runner = Runner(output)
    manifest = json.loads((ROOT / "Benchmarks/PiPHDRTextureLifetime/instrumentation.json").read_text())
    baseline_commit = manifest["baseline_commit"]
    original = runner.run(["git", "show", f"{baseline_commit}:{COMPOSITOR}"],
                          label="pinned-baseline-source")
    baseline = original
    for edit in manifest["edits"]:
        if baseline.count(edit["old"]) != 1:
            raise RuntimeError("The pinned baseline no longer matches an observation-only hook anchor.")
        baseline = baseline.replace(edit["old"], edit["new"], 1)
    candidate = (ROOT / COMPOSITOR).read_text()
    # Establish that baseline instrumentation changes observation only. Retain
    # both diffs so reviewers can independently audit the comparison.
    (output / "baseline-instrumentation.diff").write_text("".join(difflib.unified_diff(
        original.splitlines(True), baseline.splitlines(True), "pinned-main", "instrumented-main")))
    (output / "retirement.diff").write_text("".join(difflib.unified_diff(
        baseline.splitlines(True), candidate.splitlines(True), "baseline", "candidate")))
    expected_candidate = baseline.replace(
        "            presenter.flush(removeDisplayedImage: true)\n            emitMetrics()\n",
        "            presenter.flush(removeDisplayedImage: true)\n"
        "            retireHDRTextureIfStoppedAndIdle()\n            emitMetrics()\n", 1)
    helper = (
        "    /// Work-queue confined. Keep the working texture until the last submitted\n"
        "    /// composition returns, and preserve reuse if PiP has already restarted.\n"
        "    private func retireHDRTextureIfStoppedAndIdle() {\n"
        "        guard stateLock.withLock({ !active && !workerActive }) else { return }\n"
        "        hdrLinearTexture = nil\n"
        "    }\n\n"
    )
    expected_candidate = expected_candidate.replace(
        "    private func consumePendingFrame() {\n", helper + "    private func consumePendingFrame() {\n", 1)
    expected_candidate = expected_candidate.replace(
        "        guard let work else { return }\n",
        "        guard let work else {\n            retireHDRTextureIfStoppedAndIdle()\n            return\n        }\n", 1)
    expected_candidate = expected_candidate.replace(
        "                workerActive = false\n            }\n        } catch {\n",
        "                workerActive = false\n            }\n"
        "            retireHDRTextureIfStoppedAndIdle()\n        } catch {\n", 1)
    if candidate != expected_candidate:
        raise RuntimeError("Comparison must isolate the three retirement sites and their helper.")

    head = runner.run(["git", "rev-parse", "HEAD"], label="candidate-head").strip()
    roots = {"candidate": ROOT, "baseline": output / "baseline-checkout"}
    runner.run(["git", "worktree", "add", "--detach", roots["baseline"], head], label="baseline-worktree")
    (roots["baseline"] / COMPOSITOR).write_text(baseline)
    sources = output / "sources"
    sources.mkdir()
    (sources / "baseline.swift").write_text(baseline)
    (sources / "candidate.swift").write_text(candidate)
    inputs = [COMPOSITOR, Path("Package.swift"), Path("Package.resolved"),
              Path("BuildInputs/native-sdk.json"),
              Path("Tests/IlliquidNativePlaybackTests/PiPHDRTextureLifetimeTests.swift"),
              Path("Tests/IlliquidNativePlaybackTests/PiPHDRTextureLifetimeMeasurements.swift")]
    save(output / "source-receipt.json", {
        "baseline_commit": baseline_commit, "candidate_commit": head,
        "pinned_source_sha256": digest(original.encode()),
        "variants": {variant: {str(path): digest((root / path).read_bytes()) for path in inputs}
                     for variant, root in roots.items()},
    })
    environment = dict(
        baseline_commit=baseline_commit, candidate_commit=head,
        platform=platform.platform(), machine=platform.machine(),
        swift=runner.run(["swift", "--version"], label="swift-version").strip(),
        xcode=runner.run(["xcodebuild", "-version"], label="xcode-version").strip(),
        hardware=runner.run(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"], label="hardware").strip(),
        scope="Native Metal texture ownership and allocatedSize; not process footprint or playback FPS",
        pairs=args.pairs,
    )
    save(output / "environment.json", environment)
    workloads = [
        dict(name="small-pq", width=64, height=32, transfer=16),
        dict(name="1080p-pq", width=1920, height=1080, transfer=16),
        dict(name="uhd-pq", width=3840, height=2160, transfer=16),
        dict(name="uhd-hlg", width=3840, height=2160, transfer=18),
    ]
    save(output / "workloads.json", workloads)

    def swift_command(variant, suite, build=False):
        command = ["swift", "test", "--package-path", roots[variant],
                   "--scratch-path", output / "build" / variant,
                   "--force-resolved-versions", "-c", "release", "--jobs", "2",
                   "--no-parallel", "--filter", suite]
        if not build:
            command.append("--skip-build")
        return command

    def measure(variant, workload, build=False):
        env = os.environ.copy()
        env["ILLIQUID_PIP_HDR_MEASURE"] = "1"
        env["ILLIQUID_PIP_HDR_WORKLOAD"] = json.dumps(workload)
        raw = runner.run(swift_command(variant, "PiPHDRTextureLifetimeMeasurements", build),
                         env=env, timeout=2400 if build else 180,
                         label=f"{variant}-{'build' if build else workload['name']}")
        matches = re.findall(r"^" + re.escape(MARKER) + r"(\{.*\})$", raw, re.MULTILINE)
        if len(matches) != 1:
            raise RuntimeError("Expected one native measurement record; check discovery and enablement.")
        row = json.loads(matches[0])
        verify(row, workload, variant)
        return row

    for variant in VARIANTS:
        save(output / f"{variant}-build-probe.json", measure(variant, workloads[0], build=True))
    raw = runner.run(swift_command("candidate", REGRESSIONS), timeout=600, label="native-regressions")
    counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", raw)
    if len(counts) != 1 or int(counts[0]) < 5:
        raise RuntimeError("Native regression selection did not execute a successful nonempty suite.")
    save(output / "regressions.json", dict(passed_tests=int(counts[0]), log=runner.commands[-1]["log"]))

    rows = []
    for workload in workloads:
        for pair in range(args.pairs):
            paired = {}
            for variant in VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS)):
                row = measure(variant, workload)
                row.update(variant=variant, pair=pair, log=runner.commands[-1]["log"])
                rows.append(row)
                paired[variant] = row
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            for key in ("allocatedTextureBytes", "logicalTextureBytes", "outputBeforeStop",
                        "outputAfterStop", "outputAfterReentry"):
                if paired["baseline"][key] != paired["candidate"][key]:
                    raise RuntimeError(f"Paired allocation/output mismatch: {workload['name']} {key}")
    summary = dict(succeeded=True, candidate_commit=head, baseline_commit=baseline_commit,
                   pairs=args.pairs, observations=len(rows), native_tests=int(counts[0]),
                   workloads=[dict(
                       name=case["name"], width=case["width"], height=case["height"], transfer=case["transfer"],
                       logical_bytes=case["width"] * case["height"] * 8,
                       allocated_bytes=next(row["allocatedTextureBytes"] for row in rows if row["workload"] == case["name"]),
                       baseline_retained_bytes=next(row["retainedAllocatedBytesAfterStop"] for row in rows
                                                    if row["workload"] == case["name"] and row["variant"] == "baseline"),
                       candidate_retained_bytes=0,
                   ) for case in workloads])
    save(output / "summary.json", summary)
    print("PIP_HDR_LIFETIME_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
