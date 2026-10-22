#!/usr/bin/env python3
"""Compare the actual filesystem event planner with a pinned Git baseline."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
SOURCE = "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
TESTS = [
    "SourceFilesystemMonitorTests.swift",
    "SourceFilesystemEventLossTests.swift",
    "SourceFilesystemRootRegressionTests.swift",
    "SourceFilesystemPlanningTests.swift",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Experiment:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.out = args.output.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.evidence = self.out / "evidence"
        self.evidence.mkdir()
        self.env = dict(os.environ)
        for key in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.env[key] = str(self.out / "module-cache")
        fixtures = self.out / "fixtures"
        self.env["ILLIQUID_FILESYSTEM_BENCHMARK_FIXTURES"] = str(fixtures)
        for index in range(256):
            for folder, extension in (("files", "mkv"), ("metadata", "nfo")):
                path = fixtures / folder / f"Group{index % 16}" / f"Episode{index}.{extension}"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture\n")
            (fixtures / "directories" / f"Season{index}").mkdir(parents=True)
        for name in (".plexmatch", "Series.nfo"):
            (fixtures / "directories" / name).mkdir()
        compiler = shutil.which(args.swiftc)
        if compiler is None:
            raise ValueError(f"Swift compiler not found: {args.swiftc}")
        self.swiftc = compiler
        self.swift = str(Path(compiler).with_name("swift"))
        self.executables: dict[tuple[str, str], Path] = {}
        self.sources: dict[str, bytes] = {}

    def command(self, argv: list, *, log: str | None = None, timeout: int = 600) -> str:
        command = [str(value) for value in argv]
        process = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True,
                                 text=True, timeout=timeout)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": command, "returncode": process.returncode,
                                     "stdout_sha256": digest(process.stdout.encode()),
                                     "stderr": process.stderr}) + "\n")
        if log:
            (self.evidence / log).write_text(process.stdout + process.stderr)
        if process.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{process.stdout[-6000:]}\n{process.stderr[-6000:]}")
        return process.stdout

    def build(self) -> None:
        self.sources = {
            "baseline": self.command(["git", "show", f"{self.args.baseline}:{SOURCE}"]).encode(),
            "candidate": (ROOT / SOURCE).read_bytes(),
        }
        manifest = {
            "baseline": self.args.baseline,
            "candidate_head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "source_path": SOURCE,
            "source_sha256": {key: digest(value) for key, value in self.sources.items()},
            "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "tests_sha256": {name: digest((ROOT / "Tests/IlliquidAppTests" / name).read_bytes())
                             for name in TESTS},
            "executables_sha256": {},
        }
        environment = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "git_status": self.command(["git", "status", "--short"]),
            "fixture_root": str(self.out / "fixtures"),
            "fixture_note": "256 existing media-named files, 256 existing NFO-named files, and 256 existing directories; setup excluded from timing",
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
        }
        if platform.system() == "Darwin":
            environment["macos"] = self.command(["sw_vers"]).strip()
            environment["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        else:
            cpuinfo = Path("/proc/cpuinfo").read_text()
            environment["cpu"] = next((line.partition(":")[2].strip() for line in cpuinfo.splitlines()
                                       if line.startswith("model name")), "unknown")
        write_json(self.evidence / "environment.json", environment)
        for variant, source in self.sources.items():
            folder = self.out / variant
            folder.mkdir()
            production = folder / Path(SOURCE).name
            production.write_bytes(source)
            for configuration in ("debug", "release"):
                flags = ["-O", "-whole-module-optimization"] if configuration == "release" else ["-Onone", "-g"]
                if platform.system() == "Darwin":
                    flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
                executable = folder / f"planner-{configuration}"
                self.command([self.swiftc, "-swift-version", "6", "-warnings-as-errors",
                              "-parse-as-library", *flags, production, HERE / "Harness.swift",
                              "-o", executable])
                self.executables[(variant, configuration)] = executable
                manifest["executables_sha256"][f"{variant}-{configuration}"] = digest(executable.read_bytes())
                print(f"Built {variant} {configuration}", flush=True)
        write_json(self.evidence / "manifest.json", manifest)

    def validate(self) -> None:
        validation = {}
        reference = None
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                raw = self.command([self.executables[(variant, configuration)], "verify"])
                trace = json.loads(raw)
                if reference is None:
                    reference = trace
                    (self.evidence / "baseline-trace.json.gz").write_bytes(
                        gzip.compress(raw.encode(), mtime=0))
                elif trace != reference:
                    write_json(self.evidence / f"mismatch-{variant}-{configuration}.json", trace)
                    raise RuntimeError(f"Exact plan trace mismatch: {variant} {configuration}")
                validation[f"{variant}-{configuration}"] = {
                    "exact_plan_parity": True, "trace_sha256": digest(raw.encode()),
                    "plan_count": sum(len(trace[key]) for key in
                                      ("single_event_matrix", "mixed_batches", "workloads")),
                }
        # Compile the unchanged production file and repository tests in a small
        # package; neither the planner nor the test assertions are rewritten.
        for variant, source in self.sources.items():
            package = self.out / variant / "tests"
            sources = package / "Sources/IlliquidApp"
            tests = package / "Tests/IlliquidAppTests"
            sources.mkdir(parents=True)
            tests.mkdir(parents=True)
            (sources / Path(SOURCE).name).write_bytes(source)
            for name in TESTS:
                shutil.copyfile(ROOT / "Tests/IlliquidAppTests" / name, tests / name)
            (package / "Package.swift").write_text(
                '// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "FilesystemPlanningQualification", '
                'platforms: [.macOS("26.0")], targets: [\n'
                '    .target(name: "IlliquidApp"),\n'
                '    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])\n])\n')
            for configuration in ("debug", "release"):
                log = f"{variant}-{configuration}-tests.log"
                self.command([self.swift, "test", "--package-path", package,
                              "--cache-path", self.out / "package-cache",
                              "--config-path", self.out / "package-config",
                              "--security-path", self.out / "package-security",
                              "--jobs", "2", "--no-parallel", "-c", configuration,
                              "-Xswiftc", "-warnings-as-errors"], log=log)
                validation[f"{variant}-{configuration}"]["tests_passed"] = True
                print(f"Passed {variant} {configuration} tests and exact plan parity", flush=True)
        write_json(self.evidence / "validation.json", validation)

    def bench(self, variant: str, case: str, iterations: int) -> dict:
        row = json.loads(self.command([self.executables[(variant, "release")], "bench", case, iterations]))
        if row["iterations"] != iterations or row["case"] != case:
            raise RuntimeError("Harness returned an unexpected workload")
        if row["elapsed_ns"] <= 0 or row["cpu_ns"] <= 0:
            raise RuntimeError("Invalid timing receipt")
        return row

    def measure(self) -> None:
        cases = json.loads(self.command([self.executables[("baseline", "release")], "cases"]))
        if cases != json.loads(self.command([self.executables[("candidate", "release")], "cases"])):
            raise RuntimeError("Baseline and candidate workload lists differ")
        if self.args.cases:
            wanted = set(self.args.cases.split(","))
            if not wanted.issubset(cases):
                raise ValueError(f"Unknown cases: {sorted(wanted.difference(cases))}")
            cases = [case for case in cases if case in wanted]
        summary = []
        observations = 0
        for case in cases:
            calibration = []
            suggested = []
            for variant in ("baseline", "candidate"):
                iterations = 1
                while True:
                    row = self.bench(variant, case, iterations)
                    calibration.append({"variant": variant, **row})
                    if row["elapsed_ns"] >= 10_000_000 or iterations == 1_000_000:
                        break
                    iterations = min(1_000_000, max(iterations + 1,
                                     math.ceil(iterations * 15_000_000 / row["elapsed_ns"])))
                suggested.append(min(1_000_000, max(1, math.ceil(
                    iterations * self.args.target_ms * 1_000_000 / row["elapsed_ns"]))))
            with (self.evidence / "calibration.jsonl").open("a") as stream:
                for row in calibration:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            iterations = max(suggested)
            rows = []
            expected = None
            ratios = []
            cpu_ratios = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                pair_rows = {}
                for process_order, variant in enumerate(order):
                    row = self.bench(variant, case, iterations)
                    result = {key: row[key] for key in ("final_plan", "checksum", "event_count", "root_count")}
                    if expected is not None and result != expected:
                        raise RuntimeError(f"Benchmark output mismatch for {case}")
                    expected = result
                    row.update(variant=variant, pair=pair, process_order=process_order)
                    rows.append(row)
                    pair_rows[variant] = row
                    with (self.evidence / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                    observations += 1
                ratios.append(pair_rows["candidate"]["elapsed_ns"] / pair_rows["baseline"]["elapsed_ns"])
                cpu_ratios.append(pair_rows["candidate"]["cpu_ns"] / pair_rows["baseline"]["cpu_ns"])
            stats = {}
            for variant in ("baseline", "candidate"):
                values = [row["elapsed_ns"] / iterations for row in rows if row["variant"] == variant]
                cpus = [row["cpu_ns"] / iterations for row in rows if row["variant"] == variant]
                stats[variant] = {"median_ns": statistics.median(values), "min_ns": min(values),
                                  "max_ns": max(values), "median_cpu_ns": statistics.median(cpus)}
            change = (statistics.median(ratios) - 1) * 100
            summary.append({"case": case, "iterations": iterations, "pairs": self.args.pairs,
                            "event_count": expected["event_count"], "root_count": expected["root_count"],
                            "paired_change_percent": change, "pair_ratios": ratios,
                            "paired_cpu_change_percent": (statistics.median(cpu_ratios) - 1) * 100,
                            "pairs_faster": sum(ratio < 1 for ratio in ratios), **stats})
            print(f"{case}: {stats['baseline']['median_ns'] / 1e6:.4f} -> "
                  f"{stats['candidate']['median_ns'] / 1e6:.4f} ms/plan; "
                  f"paired {change:+.1f}%; faster {sum(ratio < 1 for ratio in ratios)}/{self.args.pairs}",
                  flush=True)
            write_json(self.evidence / "summary.json", {"observations": observations, "groups": summary})
        assert observations == len(cases) * self.args.pairs * 2
        write_json(self.evidence / "completion.json", {"complete": True, "observations": observations,
                                                       "cases": len(cases), "pairs": self.args.pairs})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--cases", help="Optional comma-separated workload subset")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("Use an even pair count of at least two for balanced AB/BA order")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be positive and finite")
    experiment = Experiment(args)
    experiment.build()
    experiment.validate()
    if not args.tests_only:
        experiment.measure()


if __name__ == "__main__":
    main()
