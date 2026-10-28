#!/usr/bin/env python3
"""Execute real native PiP ownership regressions and paired restart measurements."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
FOCAL = "Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift"
BASELINE_BLOB = "6ec0cd6317cbecbe40d92ed894fec86a4134438c"
REGRESSION = "Tests/IlliquidNativePlaybackTests/PiPIdleResourceLifetimeTests.swift"
STAGED_HARNESS = "Tests/IlliquidNativePlaybackTests/PiPIdleResourceResearchTests.swift"
EXISTING = ("PiPSubtitlePipelineTests|PiPSubtitleUploadReuseTests|"
            "PiPSubtitleCompositionPolicyTests|PiPVideoMappingTests|"
            "NativePictureInPictureTransitionTests")
NEGATIVE = "PiPIdleResourceLifetimeTests/stopRetiresIdleResourcesWithoutInvalidatingCaptionUploads"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("Baseline instrumentation boundary changed: " + repr(old))
    return source.replace(old, new, 1)


def instrument_baseline(baseline, candidate):
    start = "    struct OutputResourceSnapshot: Sendable {"
    end = "    func composedPixelBufferForTesting("
    if candidate.count(start) != 1 or candidate.count(end) != 1:
        raise ValueError("Candidate diagnostics boundaries changed")
    block = candidate[candidate.index(start):candidate.index(end)]
    instrumented = replace_once(baseline, end, block + end)
    # The nil-by-default GPU test hook is inert in every benchmark execution.
    # Regression compilation requires its initializer argument on both variants.
    substitutions = INERT_HOOK_SUBSTITUTIONS
    for old, new in substitutions:
        instrumented = replace_once(instrumented, old, new)
    recovered = instrumented
    for old, new in reversed(substitutions):
        recovered = replace_once(recovered, new, old)
    recovered = replace_once(recovered, block, "")
    if recovered != baseline:
        raise ValueError("Baseline production code changed beyond inert diagnostics")
    return instrumented, {
        "description": "queue-synchronized observations and nil-by-default GPU test hook only",
        "diagnostics_sha256": sha(block.encode()),
        "recovered_baseline_sha256": sha(recovered.encode()),
    }


# Filled from the production patch's exact inert test-hook insertion sites.
INERT_HOOK_SUBSTITUTIONS = [
    ('''    private let stateLock = NSLock()

    private var active = false''',
     '''    private let stateLock = NSLock()
    private let beforeGPUCommitForTesting: (@Sendable (any MTLCommandBuffer) -> Void)?

    private var active = false'''),
    ('''        subtitles: SubtitlePipeline? = nil,
        memoryBudget: SubtitleMemoryBudget? = nil
    ) throws {''',
     '''        subtitles: SubtitlePipeline? = nil,
        memoryBudget: SubtitleMemoryBudget? = nil,
        beforeGPUCommitForTesting: (@Sendable (any MTLCommandBuffer) -> Void)? = nil
    ) throws {'''),
    ('''        self.commandQueue = commandQueue
        textureCache = cache''',
     '''        self.commandQueue = commandQueue
        self.beforeGPUCommitForTesting = beforeGPUCommitForTesting
        textureCache = cache'''),
    ('''        commandBuffer.commit()
    }

    private func encodeSubtitles(''',
     '''        beforeGPUCommitForTesting?(commandBuffer)
        commandBuffer.commit()
    }

    private func encodeSubtitles('''),
]


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.packages = {}
        self.manifest = {
            "baseline_commit": BASELINE, "platform": platform.platform(),
            "machine": platform.machine(), "pairs": args.pairs,
            "iterations_per_process": args.iterations,
            "production_cycles_per_case": 8,
            "production_cycle_settle_requested_ns": 150_000_000,
            "production_final_settle_requested_ns": 1_000_000_000,
            "production_extended_settle_requested_ns": 5_000_000_000,
            "production_extended_settle_pair": 0,
            "scope": "native output-resource ownership; component resource recreation latency through direct GPU-completed composition",
            "latency_excludes": [
                "normal production worker scheduling", "presenter enqueue", "AVKit UI",
                "shader initialization", "source setup", "output hashing",
            ],
            "limitations": [
                "No process RSS, energy, physical display, or visible PiP startup measurement.",
                "Metal device.currentAllocatedSize is a process/device allocation counter, not resident memory; raw repeated-cycle growth has no numeric pass threshold.",
                "Production-cycle probes run before direct-composition readbacks and retain no output-buffer probes.",
                "Weak output-buffer payloads exclude allocation overhead; they are observed live wrappers, not a total-player-memory estimate.",
                "Metal allocatedSize is the actual owned HDR working-texture allocation; pool capacity is not inferred from configured limits.",
            ],
        }

    def command(self, argv, label, *, cwd=ROOT, environment=None, allowed=(0,), timeout=1200):
        started = time.monotonic()
        result = subprocess.run([str(x) for x in argv], cwd=cwd, env=environment,
                                capture_output=True, timeout=timeout)
        log = result.stdout + result.stderr
        (self.output / (label + ".log")).write_bytes(log)
        self.commands.append({
            "label": label, "argv": [str(x) for x in argv],
            "cwd": str(cwd), "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started, "log_sha256": sha(log),
        })
        save(self.output / "commands.json", self.commands)
        if result.returncode not in allowed:
            raise RuntimeError(label + " failed:\n" + log.decode(errors="replace")[-18000:])
        return result.stdout.decode(), log.decode(errors="replace"), result.returncode

    def prepare(self):
        if platform.system() != "Darwin":
            raise ValueError("This experiment requires native macOS/CoreVideo/Metal")
        if Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists():
            raise ValueError("Kyoto is available; submit this experiment through its shared queue")
        print("Kyoto is unavailable on this ephemeral runner; building serially in isolated worktrees.", flush=True)
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head")[0].strip()
        self.manifest["swift"] = self.command(["swift", "--version"], "swift")[0].strip()
        self.manifest["xcode"] = self.command(["xcodebuild", "-version"], "xcode")[0].strip()
        self.manifest["host"] = self.command(["sw_vers"], "host")[0]
        self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu")[0].strip()
        changed = self.command(["git", "diff", "--name-only", BASELINE, "HEAD", "--", "Sources"], "source-diff")[0].splitlines()
        if set(changed) != {FOCAL}:
            raise ValueError("Requalify baseline methodology: unrelated production sources changed")
        original = self.command(["git", "show", BASELINE + ":" + FOCAL], "baseline-source")[0]
        blob = hashlib.sha1(b"blob " + str(len(original.encode())).encode() + b"\0" + original.encode()).hexdigest()
        if blob != BASELINE_BLOB:
            raise ValueError("Frozen baseline Git blob mismatch")
        candidate = (ROOT / FOCAL).read_text()
        baseline, instrumentation = instrument_baseline(original, candidate)
        self.manifest["instrumentation"] = instrumentation
        self.manifest["sources"] = {
            "baseline_original": sha(original.encode()),
            "baseline_instrumented": sha(baseline.encode()),
            "candidate": sha(candidate.encode()),
            "regression": sha((ROOT / REGRESSION).read_bytes()),
            "harness": sha((HERE / "Harness.swift").read_bytes()),
            "runner": sha(Path(__file__).read_bytes()),
            "package_resolved": sha((ROOT / "Package.resolved").read_bytes()),
            "native_sdk_manifest": sha((ROOT / "BuildInputs/native-sdk.json").read_bytes()),
        }
        (self.output / "worktrees").mkdir()
        for variant, ref, source in [
            ("baseline", BASELINE, baseline), ("candidate", self.manifest["head"], candidate),
        ]:
            package = self.output / "worktrees" / variant
            self.command(["git", "worktree", "add", "--detach", package, ref], "worktree-" + variant)
            (package / FOCAL).write_text(source)
            (package / REGRESSION).write_bytes((ROOT / REGRESSION).read_bytes())
            (package / STAGED_HARNESS).write_bytes((HERE / "Harness.swift").read_bytes())
            self.packages[variant] = package
        save(self.output / "manifest.json", self.manifest)

    def swift_args(self, variant, action):
        return ["swift", action, "--package-path", self.packages[variant],
                "--scratch-path", self.output / "build" / variant,
                "-c", "release", "--force-resolved-versions", "--jobs", "2"]

    def build(self):
        binaries = {}
        for variant in ["baseline", "candidate"]:
            print("Building full native test graph: " + variant, flush=True)
            command = self.swift_args(variant, "build") + ["--build-tests", "-Xswiftc", "-enable-testing"]
            self.command(command, "build-" + variant)
            directory = Path(self.command(
                self.swift_args(variant, "build") + ["--show-bin-path"], "bin-path-" + variant)[0].strip())
            binary = directory / "IlliquidPackageTests.xctest/Contents/MacOS/IlliquidPackageTests"
            if not binary.is_file():
                raise ValueError("Native test bundle is missing")
            binaries[variant] = {"path": str(binary), "sha256": sha(binary.read_bytes())}
        self.manifest["binaries"] = binaries
        save(self.output / "manifest.json", self.manifest)

    def test(self, variant, filter_text, label, *, negative=False, receipt=None, long_settle=False):
        environment = os.environ.copy()
        if receipt is not None:
            environment.update(ILLIQUID_PIP_IDLE_VARIANT=variant,
                               ILLIQUID_PIP_IDLE_RECEIPT=str(receipt),
                               ILLIQUID_PIP_IDLE_ITERATIONS=str(self.args.iterations),
                               ILLIQUID_PIP_IDLE_LONG_SETTLE="1" if long_settle else "0")
        command = self.swift_args(variant, "test") + [
            "--skip-build", "--disable-xctest", "--enable-swift-testing",
            "--no-parallel", "--filter", filter_text]
        _, log, status = self.command(command, label, cwd=self.packages[variant],
                                      environment=environment, allowed=(0, 1) if negative else (0,))
        outcome = "failed" if negative else "passed"
        completed = re.search(r"Test run with (\d+) tests?(?: in \d+ suites?)? " + outcome, log)
        if not completed or int(completed.group(1)) == 0:
            raise ValueError(label + " did not report completed Swift Testing execution")
        if negative and (status == 0 or "stopRetiresIdleResourcesWithoutInvalidatingCaptionUploads" not in log):
            raise ValueError("Baseline negative control did not fail the intended ownership regression")
        return {"variant": variant, "filter": filter_text, "completed_tests": int(completed.group(1)),
                "expected_failure": negative, "exit_status": status, "log": label + ".log"}

    def qualify(self):
        records = [
            self.test("baseline", EXISTING, "baseline-regressions"),
            self.test("baseline", NEGATIVE, "baseline-ownership-negative", negative=True),
            self.test("candidate", EXISTING + "|PiPIdleResourceLifetimeTests", "candidate-regressions"),
        ]
        save(self.output / "tests.json", records)

    def measure(self):
        observations = []
        for pair in range(self.args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for position, variant in enumerate(order):
                label = f"measure-{pair:02d}-{variant}"
                print(label, flush=True)
                receipt = self.output / (label + ".json")
                self.test(variant, "PiPIdleResourceResearchTests", label,
                          receipt=receipt, long_settle=(pair == 0))
                value = json.loads(receipt.read_text())
                if value["variant"] != variant or len(value["rows"]) != 8 or len(value["production_cycles"]) != 2:
                    raise ValueError("Incomplete research receipt")
                for row in value["production_cycles"]:
                    if len(row["cycles"]) != 8 or any(item["composed_frames"] != 1 for item in row["cycles"]):
                        raise ValueError("Production cycle did not complete eight real first-sample deliveries")
                    if (pair == 0) != ("extended_settled_device_bytes" in row):
                        raise ValueError("Extended settling schedule differs from the declared methodology")
                device = value["metal_device"]
                if not device.get("name") or not device.get("registry_id"):
                    raise ValueError("Measurement omitted the actual Metal device identity")
                if "metal_device" in self.manifest and self.manifest["metal_device"] != device:
                    raise ValueError("Metal device changed between measurement processes")
                self.manifest["metal_device"] = device
                save(self.output / "manifest.json", self.manifest)
                value.update(pair=pair, process_order=position)
                observations.append(value)
                save(self.output / "observations.json", observations)
        references = {}
        cases = []
        for name in [row["case"] for row in observations[0]["rows"]]:
            records = {}
            for observation in observations:
                row = next(item for item in observation["rows"] if item["case"] == name)
                if name in references and row["semantic"] != references[name]:
                    raise ValueError("Baseline/candidate complete pixel or color-tag mismatch: " + name)
                references[name] = row["semantic"]
                records[observation["pair"], observation["variant"]] = row
            before, after, changes = [], [], []
            for pair in range(self.args.pairs):
                b = statistics.median(records[pair, "baseline"]["restart_to_gpu_completion_ns"])
                c = statistics.median(records[pair, "candidate"]["restart_to_gpu_completion_ns"])
                before.append(b)
                after.append(c)
                changes.append(100 * (c / b - 1))
            cases.append({
                "case": name, "baseline_median_restart_ns": statistics.median(before),
                "candidate_median_restart_ns": statistics.median(after),
                "median_paired_restart_change_percent": statistics.median(changes),
                "paired_restart_change_range_percent": [min(changes), max(changes)],
                "baseline_ownership": records[0, "baseline"],
                "candidate_ownership": records[0, "candidate"],
            })
        save(self.output / "parity.json", {
            "cases": references, "complete_logical_pixels_and_color_tags_equal": True,
            "fresh_processes": len(observations)})
        production_cases = []
        for name in [row["case"] for row in observations[0]["production_cycles"]]:
            records = {}
            process_summaries = []
            for observation in observations:
                row = next(item for item in observation["production_cycles"] if item["case"] == name)
                cycles = row["cycles"]
                stopped = [item["post_settle_device_bytes"] for item in cycles]
                # First start is cold; summarize the seven true re-entries separately.
                restart_ns = statistics.median(item["start_to_first_sample_ns"] for item in cycles[1:])
                item = {
                    "variant": observation["variant"], "pair": observation["pair"],
                    "cold_start_to_first_sample_ns": cycles[0]["start_to_first_sample_ns"],
                    "median_reentry_to_first_sample_ns": restart_ns,
                    "stopped_cycle_1_device_bytes": stopped[0],
                    "stopped_cycle_8_device_bytes": stopped[-1],
                    "cycle_1_to_8_growth_bytes": stopped[-1] - stopped[0],
                    "successive_stopped_device_deltas_bytes": [b - a for a, b in zip(stopped, stopped[1:])],
                    "final_settled_device_bytes": row["final_settled_device_bytes"],
                    "final_delta_from_before_initial_compose_bytes":
                        row["final_settled_device_bytes"] - row["before_initial_compose_device_bytes"],
                }
                if "extended_settled_device_bytes" in row:
                    item["extended_settled_device_bytes"] = row["extended_settled_device_bytes"]
                process_summaries.append(item)
                records[observation["pair"], observation["variant"]] = item
            changes = [
                100 * (records[pair, "candidate"]["median_reentry_to_first_sample_ns"] /
                       records[pair, "baseline"]["median_reentry_to_first_sample_ns"] - 1)
                for pair in range(self.args.pairs)
            ]
            production_cases.append({
                "case": name,
                "median_paired_reentry_change_percent": statistics.median(changes),
                "paired_reentry_change_range_percent": [min(changes), max(changes)],
                "processes": process_summaries,
            })
        save(self.output / "summary.json", {
            "pairs": self.args.pairs, "iterations_per_process": self.args.iterations,
            "positive_restart_change_means_slower": True, "cases": cases,
            "production_cycle_cases": production_cases,
            "production_cycle_allocation_policy": "Observe raw device-counter growth; no numeric pass threshold."})
        self.manifest["complete"] = True
        save(self.output / "manifest.json", self.manifest)

    def emit(self):
        names = ["manifest.json", "commands.json", "tests.json", "parity.json", "summary.json",
                 "observations.json",
                 "baseline-regressions.log", "baseline-ownership-negative.log", "candidate-regressions.log"]
        names += [path.name for path in sorted(self.output.glob("measure-*.json"))]
        for name in names:
            path = self.output / name
            if path.is_file():
                print("PIP_IDLE_EVIDENCE_JSON " + json.dumps(
                    {"file": name, "sha256": sha(path.read_bytes()), "content": path.read_text()},
                    sort_keys=True, separators=(",", ":"), allow_nan=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=6)
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2 or args.iterations < 3:
        parser.error("Use at least six balanced pairs and three restart samples per process")
    study = Study(args)
    try:
        study.prepare()
        study.build()
        study.qualify()
        study.measure()
    finally:
        study.emit()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("PiP idle resource research failed: " + str(error), file=sys.stderr)
        sys.exit(1)
