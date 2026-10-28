#!/usr/bin/env python3
"""Qualify the exact shuffled-checkpoint identity expression in separate Swift modules."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CORE = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/PlaylistMutationTests.swift",
    "Tests/IlliquidCoreTests/PlaylistOrderRestorationTests.swift",
    "Tests/IlliquidCoreTests/PlaylistRestoredIdentityTests.swift",
    "Tests/IlliquidCoreTests/NaturalFilenameOrderingTests.swift",
    "Tests/IlliquidCoreTests/FolderPlaylistTests.swift",
]
CASES = [
    (0, "unchanged"), (1, "unchanged"), (1, "no-base"),
    (16, "unchanged"), (16, "no-base"),
    (256, "unchanged"), (256, "edited"), (256, "duplicates"),
    (256, "no-base"), (256, "unicode"),
    (4096, "unchanged"), (4096, "edited"), (4096, "duplicates"),
    (4096, "no-base"), (4096, "unicode"), (4096, "duplicate-heavy"),
]
VARIANTS = ("baseline", "candidate")
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_hashes(data: bytes) -> dict:
    header = b"blob " + str(len(data)).encode() + b"\0"
    return {"sha256": sha256(data),
            "git_blob_sha1": hashlib.sha1(header + data).hexdigest()}


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def receipt(kind: str, value: object) -> None:
    print("CP_" + kind + " " + json.dumps(value, sort_keys=True, separators=(",", ":")),
          flush=True)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    rank = (len(ordered) - 1) * fraction
    low, high = math.floor(rank), math.ceil(rank)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def ratio_summary(ratios: list[float]) -> dict:
    rng = random.Random(20261028)
    bootstrap = [
        statistics.median(rng.choices(ratios, k=len(ratios)))
        for _ in range(5000)
    ]
    return {
        "median": statistics.median(ratios),
        "bootstrap_median_interval_95": [
            percentile(bootstrap, 0.025), percentile(bootstrap, 0.975),
        ],
        "minimum": min(ratios), "maximum": max(ratios),
    }


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("--output must be new or empty; retain earlier attempts")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env.update(
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
            CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
        )
        self.commands: list[dict] = []
        self.sources: dict = {}
        self.tests: list[dict] = []
        self.fixtures: list[dict] = []
        self.calibration: list[dict] = []
        self.observations: list[dict] = []
        self.summaries: list[dict] = []
        self.binaries: dict[str, Path] = {}

    def capture(self, argv: list, log: Path | None = None) -> bytes:
        argv = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(
            argv, cwd=ROOT, env=self.env, capture_output=True, timeout=1200
        )
        self.commands.append({
            "argv": argv, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started,
        })
        write_json(self.output / "commands.json", self.commands)
        if log is not None:
            log.write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(
                f"Command failed: {argv!r}\n"
                + (result.stdout[-8000:] + result.stderr[-12000:]).decode(
                    "utf-8", errors="replace")
            )
        return result.stdout

    def command(self, argv: list, log: Path | None = None) -> str:
        return self.capture(argv, log).decode("utf-8")

    def swift(self, action: str, variant: str, configuration: str) -> list:
        return [
            self.args.swift, action,
            "--package-path", self.output / variant,
            "--scratch-path", self.output / "build" / variant,
            "--cache-path", self.output / "swiftpm-cache",
            "--config-path", self.output / "swiftpm-config",
            "--security-path", self.output / "swiftpm-security",
            "--configuration", configuration, "--jobs", "2",
            "-Xswiftc", "-warnings-as-errors",
        ]

    def prepare(self) -> None:
        # A caller on the shared Mac must submit this entire command through
        # Kyoto. Hosted Actions runners have no shared Kyoto installation.
        print("Build coordination: use the shared Kyoto queue when available; "
              "this runner compiles its isolated packages serially.", flush=True)
        self.environment = {
            "baseline": self.args.baseline,
            "head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "status": self.command(["git", "status", "--short"]),
            "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "logical_cpus": os.cpu_count(), "python": sys.version,
            "swift": self.command([self.args.swift, "--version"]).strip(),
            "kyoto_available": KYOTO.is_file(),
            "arguments": {k: str(v) if isinstance(v, Path) else v
                          for k, v in vars(self.args).items()},
        }
        receipt("META", self.environment)
        write_json(self.output / "environment.json", self.environment)
        (self.output / "runner.snapshot.py").write_bytes(Path(__file__).read_bytes())
        harness = (HERE / "Harness.swift").read_bytes()
        tests = {path: (ROOT / path).read_bytes() for path in TESTS}
        for variant in VARIANTS:
            flags = '[.define("CHECKPOINT_BASELINE")]' if variant == "baseline" else "[]"
            package = f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "CheckpointIdentityQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(
            name: "CheckpointIdentityHarness", dependencies: ["IlliquidCore"],
            swiftSettings: {flags}
        ),
        .testTarget(
            name: "IlliquidCoreTests", dependencies: ["IlliquidCore"],
            swiftSettings: {flags}
        ),
    ]
)
'''
            sources = {
                path: ((ROOT / path).read_bytes() if variant == "candidate"
                       else self.capture(["git", "show", f"{self.args.baseline}:{path}"]))
                for path in CORE
            }
            staged = {
                "Package.swift": package.encode(),
                "Sources/CheckpointIdentityHarness/Harness.swift": harness,
                **{f"Sources/IlliquidCore/{Path(path).name}": data
                   for path, data in sources.items()},
                **tests,
            }
            caller_path = "Sources/IlliquidPlayer/Player/PlaybackController.swift"
            caller = ((ROOT / caller_path).read_bytes() if variant == "candidate"
                      else self.capture(["git", "show", f"{self.args.baseline}:{caller_path}"]))
            self.sources[variant] = {
                "repository_sources": {p: source_hashes(d) for p, d in sources.items()},
                "staged_sources": {p: source_hashes(d) for p, d in staged.items()},
                "caller": {"path": caller_path, **source_hashes(caller)},
            }
            for path, data in staged.items():
                destination = self.output / variant / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
        for path in CORE[:-1]:
            if (self.sources["baseline"]["repository_sources"][path]
                    != self.sources["candidate"]["repository_sources"][path]):
                raise AssertionError(f"Unintended dependency difference: {path}")
        receipt("SOURCES", self.sources)
        write_json(self.output / "source-receipt.json", self.sources)

    def build_and_test(self) -> None:
        for configuration in ("debug", "release"):
            for variant in VARIANTS:
                print(f"Testing {variant} ({configuration})", flush=True)
                log = self.output / f"tests-{variant}-{configuration}.log"
                self.command(
                    self.swift("test", variant, configuration) + ["--no-parallel"], log
                )
                text = log.read_text()
                for required in (
                    "allSmallQueuesAndSavedOrdersMatchIndependentIdentityLabels",
                    "canonicallyEqualSavedSpellingDoesNotReplaceCurrentIdentityBytes",
                ):
                    if required not in text:
                        raise AssertionError(f"Required test did not execute: {required}")
                result = {
                    "variant": variant, "configuration": configuration,
                    "exit_code": 0, "log_sha256": sha256(log.read_bytes()),
                    "summary": [line.strip() for line in text.splitlines()
                                if "Test run with " in line and " passed " in line],
                }
                if not result["summary"]:
                    raise AssertionError("Missing successful Swift Testing summary")
                self.tests.append(result)
                receipt("TEST", result)
                self.command(
                    self.swift("build", variant, configuration)
                    + ["--product", "CheckpointIdentityHarness"],
                    self.output / f"build-{variant}-{configuration}.log",
                )
                directory = Path(self.command(
                    self.swift("build", variant, configuration) + ["--show-bin-path"]
                ).strip())
                binary = directory / "CheckpointIdentityHarness"
                for size, workload in CASES:
                    raw = self.capture([binary, "verify", size, workload])
                    verified = json.loads(raw)
                    name = f"{size}-{workload}-{configuration}"
                    target = self.output / "verified-fixtures" / f"{name}-{variant}.json"
                    target.parent.mkdir(exist_ok=True)
                    target.write_bytes(raw)
                    if variant == "candidate":
                        reference = target.with_name(f"{name}-baseline.json").read_bytes()
                        if json.loads(reference) != verified:
                            raise AssertionError(f"Exact UTF-8 output mismatch: {name}")
                        check = {
                            "size": size, "workload": workload,
                            "configuration": configuration,
                            "input_count": verified["input_count"],
                            "unique_count": verified["unique_count"],
                            "saved_count": verified["saved_count"],
                            "full_checksum": verified["full_checksum"],
                            "fixture_sha256": sha256(raw), "exact_parity": True,
                        }
                        self.fixtures.append(check)
                        receipt("FIXTURE", check)
                if configuration == "release":
                    self.binaries[variant] = binary
        write_json(self.output / "test-receipts.json", self.tests)

    def sample(self, variant: str, size: int, workload: str, iterations: int,
               *, calibration: bool = False) -> dict:
        result = json.loads(self.capture(
            [self.binaries[variant], "bench", size, workload, iterations]
        ))
        if not (result["exact_output_verified"]
                and result["measured_checksum"] == result["expected_measured_checksum"]
                and result["iterations"] == iterations
                and result["cpu_ns"] >= 0 and result["wall_ns"] >= 0
                and (calibration or (result["cpu_ns"] > 0 and result["wall_ns"] > 0))):
            raise AssertionError(f"Invalid timing record: {result}")
        return result

    def calibrate(self, size: int, workload: str) -> int:
        per_iteration = []
        for variant in VARIANTS:
            iterations = 8
            while True:
                sample = self.sample(variant, size, workload, iterations, calibration=True)
                record = {"variant": variant, **sample}
                self.calibration.append(record)
                receipt("CALIBRATION", record)
                if sample["cpu_ns"] >= 5_000_000 or iterations == 2_000_000:
                    per_iteration.append(sample["cpu_ns"] / iterations)
                    break
                iterations = min(2_000_000, max(iterations + 1,
                    math.ceil(iterations * 5_000_000 / max(1, sample["cpu_ns"]))))
        slower_ns = max(per_iteration)
        if slower_ns <= 0:
            raise RuntimeError("Process CPU timer did not advance during calibration")
        return max(1, min(2_000_000, math.ceil(
            self.args.target_ms * 1_000_000 / slower_ns
        )))

    def measure(self) -> None:
        raw_path = self.output / "observations.jsonl"
        for size, workload in CASES:
            iterations = self.calibrate(size, workload)
            pairs = []
            for pair in range(self.args.pairs):
                order = list(VARIANTS if pair % 2 == 0 else reversed(VARIANTS))
                results = {}
                for variant in order:
                    result = self.sample(variant, size, workload, iterations)
                    results[variant] = result
                    record = {
                        "variant": variant, "pair": pair, "execution_order": order,
                        "cpu_ns_per_call": result["cpu_ns"] / iterations,
                        "wall_ns_per_call": result["wall_ns"] / iterations,
                        **result,
                    }
                    self.observations.append(record)
                    with raw_path.open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                    receipt("SAMPLE", record)
                for field in ("full_checksum", "measured_checksum", "input_count",
                              "unique_count", "saved_count"):
                    if results["baseline"][field] != results["candidate"][field]:
                        raise AssertionError(f"Paired {field} mismatch")
                pairs.append(results)
            summary = {
                "size": size, "workload": workload, "iterations": iterations,
                "pairs": self.args.pairs,
                "input_count": pairs[0]["baseline"]["input_count"],
                "unique_count": pairs[0]["baseline"]["unique_count"],
                "saved_count": pairs[0]["baseline"]["saved_count"],
            }
            for metric in ("cpu_ns", "wall_ns"):
                for variant in VARIANTS:
                    summary[f"{variant}_{metric}_median_per_call"] = statistics.median(
                        pair[variant][metric] / iterations for pair in pairs
                    )
                summary[f"{metric}_paired_ratio"] = ratio_summary([
                    pair["candidate"][metric] / pair["baseline"][metric]
                    for pair in pairs
                ])
            self.summaries.append(summary)
            receipt("SUMMARY", summary)
            write_json(self.output / "summary.json", self.summaries)

    def finish(self) -> None:
        for variant, sources in self.sources.items():
            for path, expected in sources["staged_sources"].items():
                actual = source_hashes((self.output / variant / path).read_bytes())
                if actual != expected:
                    raise AssertionError(f"Staged source changed: {variant}/{path}")
        completion = {
            "success": True,
            "observations": len(self.observations), "workloads": len(CASES),
            "tests": len(self.tests), "fixture_checks": len(self.fixtures),
            "binary_sha256": {v: sha256(p.read_bytes()) for v, p in self.binaries.items()},
            "runner_sha256": sha256(Path(__file__).read_bytes()),
            "harness_sha256": sha256((HERE / "Harness.swift").read_bytes()),
            "finished_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        results = {
            "environment": self.environment, "sources": self.sources,
            "test_receipts": self.tests, "fixture_checks": self.fixtures,
            "calibration": self.calibration, "observations": self.observations,
            "summaries": self.summaries, "completion": completion,
        }
        write_json(self.output / "results.json", results)
        receipt("COMPLETE", completion)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=150)
    args = parser.parse_args()
    if len(args.baseline) != 40 or any(c not in "0123456789abcdef" for c in args.baseline):
        parser.error("--baseline must be a full lowercase commit SHA")
    if args.pairs < 4 or args.pairs > 30 or args.pairs % 2:
        parser.error("--pairs must be an even integer in 4...30")
    if not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 1000:
        parser.error("--target-ms must be finite and in 10...1000")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.build_and_test()
        runner.measure()
        runner.finish()
    except Exception as error:
        write_json(runner.output / "failure.json", {
            "error": str(error), "type": type(error).__name__,
            "completed_observations": len(runner.observations),
        })
        raise


if __name__ == "__main__":
    main()
