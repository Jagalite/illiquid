#!/usr/bin/env python3
"""Exact-production playback reducer settlement study; no macOS/native SDK required."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
FOCAL = "Sources/IlliquidPlaybackCore/PlaybackCore.swift"
CORE_DEPENDENCY = "Sources/IlliquidCore/Player/MediaTrack.swift"
VARIANTS = ("baseline", "candidate")
TEST_FILTER = "EffectSettlementTests|CompletedEffectHistoryTests|StandardCompletionContractTests|PlaybackCoreTests"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        self.command_number = 0
        self.rows = []
        self.allocation_rows = []
        self.pilots = []
        self.binary = {}
        self.receipt = {
            "schema": 1, "baseline_commit": BASELINE,
            "candidate_head": git("rev-parse", "HEAD").decode().strip(),
            "candidate_sources": "current worktree",
            "platform": platform.platform(), "machine": platform.machine(),
            "libc": platform.libc_ver(),
            "pairs": args.pairs, "target_ms": args.target_ms,
            "minimum_sample_ms": args.minimum_ms,
            "tests_skipped": args.skip_tests, "tests_only": args.tests_only,
            "method": "fresh processes, alternating AB/BA pairs, optimized full production core",
            "measurement_boundary": {
                "included": "public PlaybackCore.update, result destruction, invariant checks, scalar checksum",
                "excluded": "fixture construction/destruction, full-state checks, canonicalization, serialization",
                "timing": "sum of disjoint batch windows; each core is updated once",
                "ownership": "independent dictionaries; separate snapshot cases retain a second state value",
                "allocations": "successful glibc malloc/calloc/realloc request counts and requested sizes; not peak/live/RSS",
                "scope": "seeded reducer component; not whole-player throughput, playback memory, or observed effect population",
            },
            "sources": {}, "harness_sources": {},
            "complete": False,
        }
        for path in sorted(HERE.rglob("*")):
            if path.is_file() and path.suffix in {".swift", ".py", ".c", ".h", ".md"} and "evidence" not in path.parts:
                self.receipt["harness_sources"][str(path.relative_to(ROOT))] = sha(path.read_bytes())
        self.persist()

    def persist(self):
        save(self.output / "manifest.json", self.receipt)

    def command(self, argv, *, label: str, extra_env: dict | None = None, timeout: int = 600) -> bytes:
        self.command_number += 1
        argv = [str(item) for item in argv]
        env = os.environ.copy()
        env.update(CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
                   SWIFT_MODULECACHE_PATH=str(self.output / "module-cache"),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                   TERM="dumb", NO_COLOR="1")
        if extra_env:
            env.update(extra_env)
        started = time.time()
        run = subprocess.run(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, timeout=timeout)
        log = self.output / "logs" / f"{self.command_number:04d}-{label}.log"
        log.write_bytes(run.stdout + run.stderr)
        record = {
            "argv": argv, "returncode": run.returncode, "started_unix": started,
            "elapsed_seconds": time.time() - started, "log": str(log.relative_to(self.output)),
            "stdout_sha256": sha(run.stdout), "stderr_sha256": sha(run.stderr),
            "extra_environment": extra_env or {},
        }
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if run.returncode:
            raise RuntimeError(f"{label} failed ({run.returncode}):\n"
                               + (run.stdout + run.stderr).decode(errors="replace")[-8000:])
        return run.stdout

    def stage(self, variant: str):
        package = self.output / variant
        paths = [CORE_DEPENDENCY]
        paths += git("ls-tree", "-r", "--name-only", BASELINE, "--",
                     "Sources/IlliquidPlaybackCore").decode().splitlines()
        current_paths = [str(path.relative_to(ROOT)) for path in
                         sorted((ROOT / "Sources/IlliquidPlaybackCore").rglob("*.swift"))]
        if sorted(path for path in paths if path.startswith("Sources/IlliquidPlaybackCore/")) != current_paths:
            raise ValueError("Production core file inventory changed; explicitly review the benchmark boundary")
        receipts = {}
        for relative in paths:
            if not relative.endswith(".swift"):
                continue
            data = git("show", f"{BASELINE}:{relative}") if variant == "baseline" else (ROOT / relative).read_bytes()
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            receipts[relative] = {"sha256": sha(data), "bytes": len(data), "transformation": "none"}

        # Current regression tests run against both versions, including the new
        # tests: neither variant receives weaker correctness expectations.
        tests = sorted((ROOT / "Tests/IlliquidPlaybackCoreTests").glob("*.swift"))
        if not any(path.name == "EffectSettlementTests.swift" for path in tests):
            raise ValueError("New settlement regression tests are missing")
        for path in tests:
            relative = str(path.relative_to(ROOT))
            data = path.read_bytes()
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            receipts[relative] = {"sha256": sha(data), "bytes": len(data), "transformation": "none; current tests"}

        harness = package / "Sources/EffectSettlementBenchmark/Harness.swift"
        harness.parent.mkdir(parents=True)
        shutil.copyfile(HERE / "Harness.swift", harness)
        shutil.copytree(HERE / "CEffectSettlementProbe", package / "Sources/CEffectSettlementProbe")
        manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "EffectSettlement",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "EffectSettlementBenchmark", targets: ["EffectSettlementBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .target(name: "CEffectSettlementProbe", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        .executableTarget(name: "EffectSettlementBenchmark",
                          dependencies: ["IlliquidPlaybackCore", "CEffectSettlementProbe"]),
        .testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"]),
    ],
    swiftLanguageModes: [.v6]
)
"""
        (package / "Package.swift").write_text(manifest)
        receipts["generated/Package.swift"] = {"sha256": sha(manifest.encode()), "bytes": len(manifest)}
        self.receipt["sources"][variant] = receipts
        self.persist()

    def swift(self, operation: str, variant: str, configuration: str) -> list:
        args = [self.args.swift, operation, "--package-path", self.output / variant,
                "--configuration", configuration, "--jobs", "2",
                "--cache-path", self.output / "cache", "--config-path", self.output / "config",
                "--security-path", self.output / "security", "-Xswiftc", "-warnings-as-errors"]
        if operation == "test":
            args += ["--no-parallel", "--filter", TEST_FILTER]
        if platform.system() == "Linux":
            args.append("--use-integrated-swift-driver")
        return args

    def prepare(self):
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], label="baseline-ancestry")
        self.receipt["swift_version"] = self.command([self.args.swift, "--version"], label="swift-version").decode().strip()
        self.receipt["worktree_status"] = self.command(["git", "status", "--porcelain"], label="worktree-status").decode()
        for variant in VARIANTS:
            print(f"Build exact production core: {variant}", flush=True)
            self.stage(variant)
        changes = {path for path, record in self.receipt["sources"]["baseline"].items()
                   if path.startswith("Sources/") and
                   record["sha256"] != self.receipt["sources"]["candidate"][path]["sha256"]}
        if changes != {FOCAL}:
            raise ValueError(f"Expected only the settlement source to differ; got {sorted(changes)}")
        for variant in VARIANTS:
            self.command([*self.swift("build", variant, "release"), "--product", "EffectSettlementBenchmark"],
                         label=f"{variant}-build")
            directory = self.command([*self.swift("build", variant, "release"), "--show-bin-path"],
                                     label=f"{variant}-bin-path").decode().strip()
            self.binary[variant] = Path(directory) / "EffectSettlementBenchmark"
        self.receipt["binary_sha256"] = {variant: sha(path.read_bytes()) for variant, path in self.binary.items()}
        self.persist()
        if not self.args.skip_tests:
            for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
                print(f"Regression tests: {variant} {configuration}", flush=True)
                self.command(self.swift("test", variant, configuration), label=f"{variant}-{configuration}-tests")
            self.receipt["regression_tests_passed"] = True
        else:
            self.receipt["regression_tests_passed"] = False
        traces = {}
        for variant in VARIANTS:
            raw = self.command([self.binary[variant], "--mode", "verify"], label=f"{variant}-full-state-parity")
            traces[variant] = json.loads(raw)
            (self.output / f"trace-{variant}.json").write_bytes(raw)
        if traces["baseline"] != traces["candidate"]:
            raise ValueError("Full state, UI snapshot, disposition, effects, or invariants differ")
        self.cases = json.loads(self.command([self.binary["candidate"], "--mode", "cases"], label="case-inventory"))
        if self.args.cases:
            requested = set(self.args.cases.split(","))
            self.cases = [item for item in self.cases if item["id"] in requested]
            if {item["id"] for item in self.cases} != requested:
                raise ValueError("Unknown requested case")
        parity = {"passed": True, "traces": len(traces["baseline"]),
                  "full_state_and_effects": True,
                  "normalization": "production canonical state plus omitted stored state fields; canonical effects",
                  "trace_sha256": {v: sha((self.output / f"trace-{v}.json").read_bytes()) for v in VARIANTS}}
        save(self.output / "parity.json", parity)
        self.receipt["parity"] = parity
        self.receipt["cases"] = self.cases
        self.persist()

    def observe(self, variant: str, case: dict, batches: int, *, allocation: bool = False) -> dict:
        mode = "allocations" if allocation else "timing"
        env = {"LD_PRELOAD": str(self.meter)} if allocation else None
        row = json.loads(self.command([self.binary[variant], "--mode", mode, "--case", case["id"],
                                       "--batches", str(batches)], label=f"{variant}-{mode}-{case['id']}",
                                      extra_env=env))
        row["variant"] = variant
        if allocation and row.get("allocationMeterSelfCheck") is not True:
            raise ValueError("Allocation instrumentation did not pass its positive self-check")
        if row["spec"] != case or row["batches"] != batches or row["operations"] < 1:
            raise ValueError("Unexpected observation workload")
        return row

    def calibrate(self, variant: str, case: dict) -> int:
        batches = 1
        for _ in range(8):
            row = self.observe(variant, case, batches)
            self.pilots.append(row)
            save(self.output / "calibrations.json", self.pilots)
            duration = min(row["wallNanoseconds"], row["cpuNanoseconds"])
            if duration >= self.args.target_ms * 1_000_000:
                return batches
            factor = min(100, max(2, math.ceil(self.args.target_ms * 1_000_000 / max(1, duration) * 1.25)))
            batches *= factor
            if batches > 1_000_000:
                break
        raise ValueError(f"Calibration failed: {variant} {case['id']}")

    def timing(self):
        for case in self.cases:
            print(f"Timing {case['id']}: {self.args.pairs} balanced pairs", flush=True)
            counts = {variant: self.calibrate(variant, case) for variant in VARIANTS}
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                paired = {}
                for variant in order:
                    row = self.observe(variant, case, counts[variant])
                    row.update(pair=pair, order=list(order))
                    paired[variant] = row
                    self.rows.append(row)
                    save(self.output / "observations.json", self.rows)
                if paired["baseline"]["checksumPerOperation"] != paired["candidate"]["checksumPerOperation"]:
                    raise ValueError("Timed scalar outputs differ")
        short = [i for i, row in enumerate(self.rows) if min(row["wallNanoseconds"], row["cpuNanoseconds"])
                 < self.args.minimum_ms * 1_000_000]
        self.receipt["short_sample_indices"] = short
        self.receipt["all_timing_samples_pass_duration_gate"] = not short
        self.persist()

    def allocations(self):
        supported = platform.system() == "Linux" and platform.libc_ver()[0] == "glibc"
        if not supported or self.args.skip_allocations:
            self.receipt["allocation_status"] = "skipped by request" if self.args.skip_allocations else "unsupported platform (timing only)"
            self.persist()
            return
        instrument = ROOT / "Benchmarks/NonDecodePerformance/allocmeter.c"
        meter_source = self.output / "allocmeter.c"
        shutil.copyfile(instrument, meter_source)
        self.meter = self.output / "libeffect-settlement-allocmeter.so"
        self.command([self.args.cc, "-shared", "-fPIC", "-O2", str(meter_source), "-o", self.meter],
                     label="allocation-meter-build")
        self.receipt["allocation_meter"] = {
            "source": str(instrument.relative_to(ROOT)), "source_sha256": sha(meter_source.read_bytes()),
            "binary_sha256": sha(self.meter.read_bytes()),
            "boundary": "successful malloc/calloc/realloc requests only; atomic counting perturbs timing",
            "separate_processes_from_timing": True,
        }
        for case in self.cases:
            print(f"Allocation traffic {case['id']}", flush=True)
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                paired = {}
                for variant in order:
                    row = self.observe(variant, case, 4, allocation=True)
                    row.update(pair=pair, order=list(order))
                    paired[variant] = row
                    self.allocation_rows.append(row)
                    save(self.output / "allocation-observations.json", self.allocation_rows)
                if paired["baseline"]["checksumPerOperation"] != paired["candidate"]["checksumPerOperation"]:
                    raise ValueError("Allocation scalar outputs differ")
        self.receipt["allocation_status"] = "measured"
        self.receipt["allocation_positive_self_check_passed"] = all(
            row["allocationMeterSelfCheck"] for row in self.allocation_rows)
        self.persist()

    def summarize(self):
        def metric(rows, case_id, name):
            values = {variant: [row[name] / row["operations"] for row in rows
                                if row["variant"] == variant and row["spec"]["id"] == case_id]
                      for variant in VARIANTS}
            if not all(values.values()):
                return None
            medians = {variant: statistics.median(numbers) for variant, numbers in values.items()}
            return {
                "baseline_median": medians["baseline"], "candidate_median": medians["candidate"],
                "change_percent": 100 * (medians["candidate"] / medians["baseline"] - 1) if medians["baseline"] else None,
                "baseline_range": [min(values["baseline"]), max(values["baseline"])],
                "candidate_range": [min(values["candidate"]), max(values["candidate"])],
                "paired_candidate_over_baseline": [b / a if a else None
                    for a, b in zip(values["baseline"], values["candidate"])],
            }
        result = []
        for case in self.cases:
            result.append({
                "case": case, "pairs": self.args.pairs,
                "wall_ns_per_event": metric(self.rows, case["id"], "wallNanoseconds"),
                "cpu_ns_per_event": metric(self.rows, case["id"], "cpuNanoseconds"),
                "allocation_requests_per_event": metric(self.allocation_rows, case["id"], "allocationRequests"),
                "requested_bytes_per_event": metric(self.allocation_rows, case["id"], "requestedBytes"),
            })
        save(self.output / "summary.json", result)
        self.receipt["summary_sha256"] = sha((self.output / "summary.json").read_bytes())
        self.receipt["complete"] = not bool(self.receipt.get("short_sample_indices"))
        self.persist()
        if self.receipt.get("short_sample_indices"):
            raise ValueError("Some final samples missed the duration gate; every sample is retained; rerun the entire cohort")
        print(json.dumps({"complete": True, "cases": len(result),
                          "parity": self.receipt["parity"]["passed"],
                          "allocation_status": self.receipt.get("allocation_status"),
                          "output": str(self.output)}, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--cc", default=shutil.which("cc") or "cc")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=240)
    parser.add_argument("--minimum-ms", type=float, default=100)
    parser.add_argument("--cases", help="Optional comma-separated exploratory case IDs; full inventory is default")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only")
    parser.add_argument("--skip-allocations", action="store_true", help="Exploration or unsupported instrumentation")
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.minimum_ms < 100 or args.target_ms < args.minimum_ms * 1.5:
        raise ValueError("Use an even pair count >=2 and target >=1.5x a minimum duration of at least 100ms")
    study = Study(args)
    study.prepare()
    if not args.tests_only:
        study.timing()
        study.allocations()
        study.summarize()
    else:
        study.receipt["complete"] = True
        study.persist()


if __name__ == "__main__":
    main()
