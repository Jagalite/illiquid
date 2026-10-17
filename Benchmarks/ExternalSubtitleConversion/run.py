#!/usr/bin/env python3
"""Exact-source, dependency-free subtitle conversion A/B and differential runner."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PRODUCTION = "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library"]
SOURCE_LIFETIME = "Fresh String decoded from preloaded Data before each conversion; decoding excluded; code/runtime warmed"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def summarize(output: Path) -> dict:
    rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
    source_lifetimes = {row.get("source_lifetime", "Preloaded String reused across warmups and timed conversions (legacy cohort)") for row in rows}
    if len(source_lifetimes) != 1:
        raise ValueError("Timing rows mix different source lifetimes")
    grouped: dict[str, dict[int, dict]] = {}
    for row in rows:
        grouped.setdefault(row["workload"], {}).setdefault(row["sample"], {})[row["variant"]] = row
    result = {}
    for name, samples in sorted(grouped.items()):
        ratios, baseline, candidate = [], [], []
        orders = {"baseline,candidate": 0, "candidate,baseline": 0}
        for index, pair in sorted(samples.items()):
            if set(pair) != {"baseline", "candidate"}:
                raise ValueError(f"Incomplete pair: {name}, sample {index}")
            left, right = pair["baseline"], pair["candidate"]
            for key in ["iterations", "warmups", "input_bytes", "output_bytes", "output_fnv1a64", "format", "fixture_sha256"]:
                if left[key] != right[key]:
                    raise ValueError(f"Pair mismatch for {name}: {key}")
            baseline.append(left["ns_per_conversion"])
            candidate.append(right["ns_per_conversion"])
            ratios.append(right["ns_per_conversion"] / left["ns_per_conversion"])
            orders[",".join(left["pair_order"])] += 1
        ratio = statistics.median(ratios)
        result[name] = {
            "paired_samples": len(ratios), "pair_orders": orders,
            "baseline_median_ms": statistics.median(baseline) / 1e6,
            "candidate_median_ms": statistics.median(candidate) / 1e6,
            "baseline_range_ms": [min(baseline) / 1e6, max(baseline) / 1e6],
            "candidate_range_ms": [min(candidate) / 1e6, max(candidate) / 1e6],
            "median_paired_candidate_over_baseline": ratio,
            "median_paired_speedup": statistics.median([1 / value for value in ratios]),
            "median_paired_reduction_percent": 100 * (1 - ratio),
            "paired_ratios": ratios,
        }
    summary = {
        "scope": "Full in-memory SRT/WebVTT conversion elapsed latency; not player startup, rendering, footprint or energy",
        "source_lifetime": next(iter(source_lifetimes)),
        "unit_of_replication": "Fresh process per variant/workload/sample; repeated conversions averaged within each process",
        "workloads": result,
    }
    write_json(output / "summary.json", summary)
    return summary


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.absolute()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use an empty output directory to avoid mixing evidence")
        self.output.mkdir(parents=True, exist_ok=True)
        compiler = shutil.which(args.swiftc)
        if compiler is None:
            raise ValueError(f"Compiler not found: {args.swiftc}")
        # Do not resolve the swiftc -> swift-driver symlink: argv[0] selects mode.
        self.swiftc = os.path.abspath(compiler)
        self.env = os.environ.copy()
        self.env["SWIFT_MODULECACHE_PATH"] = str(self.output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        self.command_index = 0
        self.manifest = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "uname": dict(platform.uname()._asdict()),
            "python": platform.python_version(), "logical_cpu_count": os.cpu_count(),
            "swiftc": self.swiftc, "swift_version": self.command([self.swiftc, "--version"], "compiler-version").strip(),
            "compiler_flags": FLAGS, "cross_module_optimization": False,
            "source_lifetime": SOURCE_LIFETIME,
            "settings": {"samples": args.samples, "iterations": args.iterations, "warmups": args.warmups,
                         "random_cases": args.random_cases, "seed": str(args.seed)},
            "source_snapshots": {}, "binaries": {},
        }
        self.manifest["run_context"] = {
            key: os.environ[key] for key in ["GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "RUNNER_ARCH", "RUNNER_OS"]
            if key in os.environ
        }
        if platform.system() == "Darwin":
            for key, command in [("cpu_model", ["sysctl", "-n", "machdep.cpu.brand_string"]),
                                 ("macos_version", ["sw_vers"])]:
                try:
                    self.manifest[key] = self.command(command, key).strip()
                except (RuntimeError, FileNotFoundError):
                    self.manifest[key] = "unavailable"
        try:
            self.manifest["checkout_head"] = self.command(["git", "rev-parse", "HEAD"], "git-head").strip()
        except RuntimeError:
            self.manifest["checkout_head"] = None
        for name in ["run.py", "Fixtures.swift", "Harness.swift", "Differential.swift", "baseline-manifest.json"]:
            data = (HERE / name).read_bytes()
            (self.output / name).write_bytes(data)
            self.manifest["source_snapshots"][name] = {"sha256": sha(data), "bytes": len(data)}
        self.save_manifest()

    def save_manifest(self):
        write_json(self.output / "manifest.json", self.manifest)

    def command(self, argv: list[str], label: str) -> str:
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        logs = self.output / "logs"
        logs.mkdir(exist_ok=True)
        stem = f"{self.command_index:04d}-{label}"
        self.command_index += 1
        (logs / f"{stem}.stdout").write_text(result.stdout)
        (logs / f"{stem}.stderr").write_text(result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "cwd": str(ROOT), "returncode": result.returncode,
                                     "process_elapsed_seconds": time.monotonic() - started,
                                     "stdout": f"logs/{stem}.stdout", "stderr": f"logs/{stem}.stderr"}) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {logs / (stem + '.stderr')}\n{result.stderr[-6000:]}")
        return result.stdout

    def build(self):
        frozen = json.loads((HERE / "baseline-manifest.json").read_text())
        baseline = (HERE / frozen["snapshot"]).read_bytes()
        if sha(baseline) != frozen["sha256"] or len(baseline) != frozen["bytes"]:
            raise ValueError("Frozen baseline does not match its source manifest")
        candidate_path = self.args.candidate_source.absolute()
        candidate = candidate_path.read_bytes()
        self.manifest["baseline"] = frozen
        self.manifest["candidate_original_path"] = str(candidate_path)
        self.executables = {}
        extension = ".dylib" if platform.system() == "Darwin" else ".so"
        for variant, content in [("baseline", baseline), ("candidate", candidate)]:
            directory = self.output / variant
            directory.mkdir()
            source = directory / "ExternalTextSubtitleConverter.swift"
            source.write_bytes(content)
            self.manifest["source_snapshots"][str(source.relative_to(self.output))] = {
                "sha256": sha(content), "bytes": len(content), "transformations": [],
            }
            library = directory / ("libConverterModule" + extension)
            self.command([self.swiftc, *FLAGS, "-enable-testing", "-emit-library", "-emit-module",
                          "-module-name", "ConverterModule", "-emit-module-path", str(directory / "ConverterModule.swiftmodule"),
                          str(source), "-o", str(library)], f"{variant}-module-build")
            executable = directory / "convert-benchmark"
            self.command([self.swiftc, *FLAGS, "-I", str(directory), "-L", str(directory), "-lConverterModule",
                          str(self.output / "Fixtures.swift"), str(self.output / "Harness.swift"),
                          "-Xlinker", "-rpath", "-Xlinker", str(directory), "-o", str(executable)],
                         f"{variant}-driver-build")
            self.executables[variant] = executable
            for binary in [library, executable]:
                self.manifest["binaries"][str(binary.relative_to(self.output))] = {"sha256": sha(binary.read_bytes())}
        original = b"enum ExternalTextSubtitleConverter {"
        renamed = b"enum BaselineExternalTextSubtitleConverter {"
        if baseline.count(original) != 1:
            raise ValueError("Baseline enum declaration changed; review the differential rename")
        differential_baseline = baseline.replace(original, renamed, 1)
        renamed_path = self.output / "BaselineRenamed.swift"
        renamed_path.write_bytes(differential_baseline)
        self.manifest["source_snapshots"][renamed_path.name] = {
            "sha256": sha(differential_baseline), "bytes": len(differential_baseline),
            "transformations": [{"kind": "single exact declaration rename", "from": original.decode(), "to": renamed.decode()}],
            "unmodified_baseline_sha256": sha(baseline),
        }
        self.differential = self.output / "differential"
        self.command([self.swiftc, *FLAGS, str(renamed_path),
                      str(self.output / "candidate" / "ExternalTextSubtitleConverter.swift"),
                      str(self.output / "Fixtures.swift"), str(self.output / "Differential.swift"),
                      "-o", str(self.differential)], "differential-build")
        self.manifest["binaries"]["differential"] = {"sha256": sha(self.differential.read_bytes())}
        self.save_manifest()

    def verify(self):
        receipt = json.loads(self.command([str(self.differential), str(self.args.seed), str(self.args.random_cases)], "differential"))
        if receipt.get("status") != "passed":
            raise ValueError("Differential verification did not pass")
        write_json(self.output / "verification.json", receipt)
        print(json.dumps({"verification": receipt}), flush=True)

    def benchmark(self):
        fixtures_dir = self.output / "fixtures"
        receipt = json.loads(self.command([str(self.executables["baseline"]), "generate", str(fixtures_dir), str(self.args.seed)], "generate-fixtures"))
        fixtures = receipt["fixtures"]
        for fixture in fixtures:
            data = (fixtures_dir / fixture["path"]).read_bytes()
            fixture["sha256"] = sha(data)
            if len(data) != fixture["input_bytes"]:
                raise ValueError("Fixture byte receipt mismatch")
        write_json(self.output / "fixtures.json", receipt)
        if self.args.workloads:
            wanted = set(self.args.workloads)
            if wanted - {fixture["name"] for fixture in fixtures}:
                raise ValueError(f"Unknown workloads: {wanted}")
            fixtures = [fixture for fixture in fixtures if fixture["name"] in wanted]
        with (self.output / "measurements.jsonl").open("w") as stream:
            for sample in range(self.args.samples):
                for workload_index, fixture in enumerate(fixtures):
                    order = ["baseline", "candidate"] if (sample + workload_index) % 2 == 0 else ["candidate", "baseline"]
                    iterations = self.args.iterations * (25 if fixture["name"].startswith("tiny_") else 1)
                    pair = {}
                    for position, variant in enumerate(order):
                        result = json.loads(self.command([
                            str(self.executables[variant]), "measure", str(fixtures_dir / fixture["path"]),
                            fixture["format"], str(iterations), str(self.args.warmups),
                        ], f"sample-{sample}-{fixture['name']}-{variant}"))
                        result.update({"sample": sample, "workload": fixture["name"], "variant": variant,
                                       "pair_order": order, "position_in_pair": position,
                                       "fixture_sha256": fixture["sha256"]})
                        pair[variant] = result
                        stream.write(json.dumps(result, sort_keys=True) + "\n")
                        stream.flush()
                    for key in ["iterations", "input_bytes", "output_bytes", "output_fnv1a64", "format"]:
                        if pair["baseline"][key] != pair["candidate"][key]:
                            raise ValueError(f"Timed-pair parity failed: {fixture['name']}, {key}")
                print(f"Completed paired sample {sample + 1}/{self.args.samples}", flush=True)
        summary = summarize(self.output)
        self.manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
        self.save_manifest()
        print(json.dumps(summary, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "verify", "benchmark", "summarize"])
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--candidate-source", type=Path, default=ROOT / PRODUCTION)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--samples", type=int, default=6, help="Even count of fresh-process pairs (default: 6)")
    parser.add_argument("--iterations", type=int, default=3, help="Conversions per process; tiny inputs multiply by 25")
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--random-cases", type=int, default=2_000)
    parser.add_argument("--seed", type=int, default=20261017)
    parser.add_argument("--workloads", nargs="+")
    args = parser.parse_args()
    if args.output is None:
        if args.action == "summarize": parser.error("summarize requires --output")
        args.output = Path(tempfile.mkdtemp(prefix="illiquid-subtitle-conversion-"))
    if args.samples < 2 or args.samples % 2:
        parser.error("--samples must be positive and even (at least 2) for balanced AB/BA pairs")
    if args.iterations < 1 or args.warmups < 0 or args.random_cases < 0 or not 0 <= args.seed <= 2**64 - 1:
        parser.error("Invalid iteration, warmup, random-case or UInt64 seed value")
    if args.action == "summarize":
        print(json.dumps(summarize(args.output), indent=2))
        return
    print(f"Evidence: {args.output.absolute()}", flush=True)
    runner = Runner(args)
    runner.build()
    if args.action in {"verify", "benchmark"}: runner.verify()
    if args.action == "benchmark": runner.benchmark()


if __name__ == "__main__":
    main()
