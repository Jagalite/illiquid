#!/usr/bin/env python3
"""Compare the production thumbnail-memory eviction paths in isolated processes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = "Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift"
BASELINE_REVISION = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "66b8127d5c1ea269860b2c1b63e3dcede4262807"
CASES = (
    "count-foreground", "count-background", "count-mixed", "byte-budget",
    "bulk-insert", "bulk-configure", "no-victim", "resident-hit",
)
INPUTS = (
    "Benchmarks/ThumbnailMemoryEviction/Support.swift",
    "Benchmarks/ThumbnailMemoryEviction/Harness.swift",
    "Benchmarks/ThumbnailMemoryEviction/Probe.swift",
    "Sources/IlliquidCore/Player/ThumbnailPolicy.swift",
    "Sources/IlliquidCore/Utilities/NonDecodePerformance.swift",
)
FLAGS = ["-parse-as-library", "-swift-version", "6", "-warnings-as-errors"]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def pair_count(value: str) -> int:
    parsed = positive_int(value)
    if parsed % 2:
        raise argparse.ArgumentTypeError("must be even to balance AB/BA order")
    return parsed


class Experiment:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and (not self.output.is_dir() or any(self.output.iterdir())):
            raise ValueError("--output must be a new or empty directory")
        compiler = shutil.which(args.swiftc)
        if compiler is None:
            raise ValueError(f"Swift compiler not found: {args.swiftc}")
        self.swiftc = compiler
        self.output.mkdir(parents=True, exist_ok=True)
        self.sources = self.output / "sources"
        self.sources.mkdir()
        self.manifest = {
            "schema_version": 1,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "status": "running",
            "platform": platform.platform(),
            "architecture": platform.machine(),
            "compiler_path": self.swiftc,
            "baseline_revision": BASELINE_REVISION,
            "baseline_blob": BASELINE_BLOB,
            "source_sha256": {},
            "binary_sha256": {},
            "common_flags": FLAGS,
            "configuration_flags": {"debug": ["-Onone"], "release": ["-O"]},
            "test_environment": {"SWIFT_DETERMINISTIC_HASHING": "1"},
            "pairs": args.pairs,
            "cases": args.cases,
            "iterations": args.iterations,
            "bulk_iterations": args.bulk_iterations,
            "tests_only": args.tests_only,
            "skip_debug": args.skip_debug,
        }
        self.executables: dict[tuple[str, str], Path] = {}
        self.verification: list[dict] = []
        self.summaries: list[dict] = []
        self.save()

    def command(self, argv: list[str], *, env: dict[str, str] | None = None) -> bytes:
        started = time.monotonic()
        process = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True)
        receipt = {
            "argv": argv,
            "elapsed_seconds": time.monotonic() - started,
            "returncode": process.returncode,
            "stdout_sha256": sha256(process.stdout),
            "stderr_sha256": sha256(process.stderr),
        }
        if process.stderr:
            receipt["stderr"] = process.stderr.decode(errors="replace")
        if process.returncode:
            receipt["stdout"] = process.stdout.decode(errors="replace")
        append_json(self.output / "commands.jsonl", receipt)
        if process.returncode:
            raise RuntimeError(
                f"Command failed ({process.returncode}): {argv!r}\n"
                + process.stderr.decode(errors="replace")[-8000:]
            )
        return process.stdout

    def prepare(self) -> None:
        self.manifest["compiler"] = self.command([self.swiftc, "--version"]).decode().strip()
        self.manifest["checkout_revision"] = self.command(["git", "rev-parse", "HEAD"]).decode().strip()
        baseline = self.command(["git", "show", f"{BASELINE_REVISION}:{SOURCE}"])
        if git_blob(baseline) != BASELINE_BLOB:
            raise ValueError("Baseline cache does not match the pinned Git blob")
        candidate = (ROOT / SOURCE).read_bytes()
        self.manifest["candidate_blob"] = git_blob(candidate)
        snapshots = {path: (ROOT / path).read_bytes() for path in INPUTS}
        snapshots["Benchmarks/ThumbnailMemoryEviction/run.py"] = Path(__file__).read_bytes()
        snapshots[SOURCE] = candidate
        self.manifest["source_sha256"] = {name: sha256(data) for name, data in snapshots.items()}
        self.manifest["baseline_source_sha256"] = sha256(baseline)
        for path in INPUTS:
            (self.sources / Path(path).name).write_bytes(snapshots[path])
        (self.sources / "run.snapshot.py").write_bytes(Path(__file__).read_bytes())
        self.manifest["generated_source_sha256"] = {}
        for variant, original in (("baseline", baseline), ("candidate", candidate)):
            (self.sources / f"{variant}.original.swift").write_bytes(original)
            omitted = {"import IlliquidCore"}
            if platform.system() != "Darwin":
                omitted.update(("import CoreGraphics", "import CryptoKit"))
            lines = original.decode().splitlines(keepends=True)
            for line in omitted:
                if sum(item.rstrip("\r\n") == line for item in lines) != 1:
                    raise ValueError(f"Expected exactly one {line!r} in {variant}")
            adapted = "".join(line for line in lines if line.rstrip("\r\n") not in omitted)
            generated = adapted.encode() + b"\n" + snapshots["Benchmarks/ThumbnailMemoryEviction/Probe.swift"]
            path = self.sources / f"{variant}.Cache.swift"
            path.write_bytes(generated)
            self.manifest["generated_source_sha256"][variant] = sha256(generated)
        self.save()

    def build(self, configuration: str, variant: str) -> Path:
        directory = self.output / "build" / configuration / variant
        directory.mkdir(parents=True)
        executable = directory / "eviction-benchmark"
        sources = [self.sources / f"{variant}.Cache.swift"] + [
            self.sources / name for name in (
                "Support.swift", "Harness.swift", "ThumbnailPolicy.swift", "NonDecodePerformance.swift"
            )
        ]
        self.command([
            self.swiftc, *FLAGS, *self.manifest["configuration_flags"][configuration],
            *(str(path) for path in sources), "-o", str(executable),
        ])
        self.manifest["binary_sha256"][f"{configuration}/{variant}"] = sha256(executable.read_bytes())
        self.executables[configuration, variant] = executable
        self.save()
        return executable

    def verify(self, configuration: str) -> None:
        traces = {}
        env = os.environ.copy()
        env["SWIFT_DETERMINISTIC_HASHING"] = "1"
        for variant in ("baseline", "candidate"):
            executable = self.executables[configuration, variant]
            trace = self.command([str(executable), "verify"], env=env)
            lines = trace.splitlines()
            if not lines:
                raise ValueError(f"Empty verification trace: {configuration}/{variant}")
            for line in lines:
                json.loads(line)
            (self.output / f"verify-{configuration}-{variant}.jsonl").write_bytes(trace)
            traces[variant] = trace
        if traces["baseline"] != traces["candidate"]:
            raise ValueError(f"Baseline/candidate verification trace mismatch: {configuration}")
        self.verification.append({
            "configuration": configuration, "status": "passed",
            "trace_lines": len(traces["baseline"].splitlines()),
            "trace_sha256": sha256(traces["baseline"]),
        })
        self.save()
        print(f"{configuration}: identical baseline/candidate verification traces", flush=True)

    def measure(self, variant: str, case: str, iterations: int) -> dict:
        executable = self.executables["release", variant]
        row = json.loads(self.command([str(executable), "benchmark", case, str(iterations)]))
        if row.get("case") != case or row.get("iterations") != iterations:
            raise ValueError(f"Measurement identity mismatch: {row}")
        for field in ("elapsed_ns", "cpu_ns"):
            if not isinstance(row.get(field), (int, float)) or not math.isfinite(row[field]) or row[field] <= 0:
                raise ValueError(f"Invalid measurement {field}: {row.get(field)}")
        if not isinstance(row.get("receipt"), list) or not all(isinstance(item, str) for item in row["receipt"]):
            raise ValueError("Expected a receipt containing a list of strings")
        row["receipt_sha256"] = sha256(json.dumps(row["receipt"], separators=(",", ":")).encode())
        row["variant"] = variant
        return row

    def benchmark(self, case: str) -> None:
        iterations = self.args.bulk_iterations if case.startswith("bulk-") else self.args.iterations
        paired = []
        for pair in range(self.args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            observations = {}
            for position, variant in enumerate(order):
                row = self.measure(variant, case, iterations)
                row.update(pair=pair, process_position=position)
                append_json(self.output / "measurements.jsonl", row)
                observations[variant] = row
            if observations["baseline"]["receipt"] != observations["candidate"]["receipt"]:
                raise ValueError(f"Timed output mismatch: {case}, pair {pair}")
            paired.append(observations)
        summary = {"case": case, "iterations": iterations, "pairs": self.args.pairs}
        for clock, field in (("wall", "elapsed_ns"), ("cpu", "cpu_ns")):
            for variant in ("baseline", "candidate"):
                values = [pair[variant][field] / iterations for pair in paired]
                summary[f"{variant}_{clock}_ns_per_operation_median"] = statistics.median(values)
                summary[f"{variant}_{clock}_ns_per_operation_range"] = [min(values), max(values)]
            changes = [100 * (pair["candidate"][field] / pair["baseline"][field] - 1) for pair in paired]
            summary[f"{clock}_paired_change_percent_median"] = statistics.median(changes)
        self.summaries.append(summary)
        self.save()
        print(json.dumps(summary, sort_keys=True), flush=True)

    def save(self) -> None:
        write_json(self.output / "manifest.json", self.manifest)
        write_json(self.output / "verification.json", self.verification)
        write_json(self.output / "summary.json", self.summaries)

    def run(self) -> None:
        self.prepare()
        configurations = ["release"] if self.args.skip_debug else ["debug", "release"]
        for configuration in configurations:
            for variant in ("baseline", "candidate"):
                self.build(configuration, variant)
            self.verify(configuration)
        if not self.args.tests_only:
            for case in self.args.cases:
                self.benchmark(case)
        self.manifest["status"] = "passed"
        self.manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
        self.save()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=pair_count, default=8)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-debug", action="store_true")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--iterations", type=positive_int, default=10_000)
    parser.add_argument("--bulk-iterations", type=positive_int, default=100)
    args = parser.parse_args()
    if len(args.cases) != len(set(args.cases)):
        parser.error("--cases must not contain duplicates")
    experiment = Experiment(args)
    try:
        experiment.run()
    except BaseException as error:
        experiment.manifest["status"] = "failed"
        experiment.manifest["error"] = f"{type(error).__name__}: {error}"
        experiment.save()
        raise


if __name__ == "__main__":
    main()
