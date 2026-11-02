#!/usr/bin/env python3
"""Compare unchanged production subtitle matchers in fresh, paired processes.

Memory-only processes sample the allocator at every public cancellation poll.
Independent timing processes use a constant-false callback and no heap sampler.
All outputs are checked against the fixture oracle and each other.
"""
from __future__ import annotations

import argparse
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
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
SOURCES = {
    "Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift":
        "32baa1287ed03126aedee7c57fadd72aaf44fccc196b76e544de48fcb4e884a8",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift":
        "85680a02f22355e0c7514fe00c12ba253c88d26be3eb2b5ee1149b212e047a00",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift":
        "d167212f90dd5cd6d8e0e73c208d8e9b4648cc7f4dd21212d51c85a693a263e7",
}
SCENARIOS = ("broad", "dense", "exact", "unrelated", "empty")
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SubtitleCandidateStreamingQualification", platforms: [.macOS("26.0")],
    products: [.executable(name: "CandidateBenchmark", targets: ["CandidateBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "CHeapProbe", publicHeadersPath: "include"),
        .executableTarget(name: "CandidateBenchmark", dependencies: ["IlliquidCore", "CHeapProbe"]),
    ], swiftLanguageModes: [.v6]
)
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def distribution(values: list[float]) -> dict:
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("Use a new empty --output directory; existing evidence is never overwritten")
        self.env = dict(os.environ)
        self.env.update(SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb", NO_COLOR="1",
            CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
            SWIFT_MODULECACHE_PATH=str(self.output / "module-cache"))
        self.binaries = {}
        self.manifest = {
            "baseline_commit": BASELINE, "candidate_sources": "current worktree captured before compilation",
            "qualification": "current-support-regression" if args.regression_only else "historical",
            "performance_measured": False,
            "source_policy": "Pinned matcher; identical current support in both variants"
                if args.regression_only else "Pinned baseline; reject supporting-source drift",
            "platform": platform.platform(), "machine": platform.machine(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
            "environment": {"SWIFT_DETERMINISTIC_HASHING": "1"},
            "method": "Separate release IlliquidCore modules, unmodified production source; sequential balanced AB/BA pairs; fresh process per variant/case/mode/sample",
            "memory_boundary": "Input URLs held alive; tiny warmup; initial allocator reading; associate with sampling false cancellation callback; return reading with output held alive; exact verification afterward",
            "memory_limit": "Sampled live allocator high watermark is a lower bound on true peak; sampling occurs only at cancellation polls and after return, not every allocation",
            "timing_boundary": "Complete association, result-count consumption and result destruction; two warmup calls; false cancellation closure; no allocator sampling",
            "scope": "Component transient allocator growth and complete association timing; not process RSS or whole-player memory/latency",
            "sources": {}, "harness": {}, "binary_sha256": {},
        }
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.exists():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in cpuinfo.read_text().splitlines() if line.startswith("model name")), "unknown")

    def append(self, name: str, value: object) -> None:
        with (self.output / name).open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")

    def command(self, args: list, *, log: str | None = None, timeout: int = 600) -> bytes:
        command = [str(value) for value in args]
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, timeout=timeout)
        self.append("commands.jsonl", {
            "argv": command, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started,
            "stdout_sha256": sha(result.stdout), "stdout_bytes": len(result.stdout),
            "stderr_sha256": sha(result.stderr), "stderr_bytes": len(result.stderr),
        })
        if log:
            path = self.output / log
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n"
                               + (result.stdout + result.stderr).decode(errors="replace"))
        return result.stdout

    def save_manifest(self) -> None:
        save(self.output / "manifest.json", self.manifest)

    def prepare(self) -> None:
        self.manifest["toolchain"] = self.command([self.args.swift, "--version"]).decode().strip()
        self.manifest["checkout_head"] = self.command(["git", "rev-parse", "HEAD"]).decode().strip()
        self.manifest["working_tree"] = self.command(["git", "status", "--porcelain"]).decode().splitlines()
        if platform.system() == "Darwin":
            self.manifest["os_version"] = self.command(["sw_vers"]).decode().strip()
            self.manifest["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).decode().strip()
        harness = {
            "Harness.swift": (HERE / "Harness.swift").read_bytes(),
            "CHeapProbe/heap.c": (HERE / "CHeapProbe/heap.c").read_bytes(),
            "CHeapProbe/include/CHeapProbe.h": (HERE / "CHeapProbe/include/CHeapProbe.h").read_bytes(),
            "run.py": Path(__file__).read_bytes(),
        }
        for relative, data in harness.items():
            target = self.output / "sources/harness" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            self.manifest["harness"][relative] = {"sha256": sha(data), "bytes": len(data)}
        self.snapshot_sources(harness)

    def snapshot_sources(self, harness: dict[str, bytes]) -> None:
        baseline_sources = {}
        # Capture each current file once, then reuse its bytes for both variants.
        candidate_sources = {relative: (ROOT / relative).read_bytes() for relative in SOURCES}
        self.manifest["historical_sources"] = {}
        for relative, expected in SOURCES.items():
            baseline = (self.args.baseline_dir / Path(relative).name).read_bytes() if self.args.baseline_dir else \
                self.command(["git", "show", f"{BASELINE}:{relative}"])
            if sha(baseline) != expected:
                raise ValueError(f"Pinned baseline SHA-256 mismatch: {relative}")
            self.manifest["historical_sources"][relative] = {
                "sha256": sha(baseline), "revision": BASELINE,
                "origin": str(self.args.baseline_dir.resolve()) if self.args.baseline_dir else "git",
            }
            candidate = candidate_sources[relative]
            if Path(relative).name != "ExternalSubtitleMatcher.swift":
                if self.args.regression_only:
                    baseline = candidate
                elif candidate != baseline:
                    raise ValueError(f"A shared dependency changed: {relative}")
            baseline_sources[relative] = baseline
        matcher_path = next(path for path in SOURCES if path.endswith("ExternalSubtitleMatcher.swift"))
        if baseline_sources[matcher_path] == candidate_sources[matcher_path]:
            raise ValueError("Candidate matcher is unchanged; refuse a misleading comparison")
        for variant, source_files in (("baseline", baseline_sources), ("candidate", candidate_sources)):
            folder = self.output / "sources" / variant
            folder.mkdir(parents=True)
            package = self.output / "build" / variant
            core = package / "Sources/IlliquidCore"
            core.mkdir(parents=True)
            self.manifest["sources"][variant] = {}
            for relative, data in source_files.items():
                use_current = variant == "candidate" or (
                    self.args.regression_only and Path(relative).name != "ExternalSubtitleMatcher.swift")
                name = Path(relative).name
                (folder / name).write_bytes(data)
                (core / name).write_bytes(data)
                self.manifest["sources"][variant][relative] = {
                    "sha256": sha(data), "bytes": len(data), "transformation": "none",
                    "origin": "current-worktree" if use_current else "pinned-baseline",
                    "source_revision": self.manifest["checkout_head"] if use_current else BASELINE,
                    "snapshot": str((folder / name).relative_to(self.output)),
                    "differs_from_historical": sha(data) != SOURCES[relative],
                    "git_blob_sha1": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
                }
            (package / "Package.swift").write_text(PACKAGE)
            driver = package / "Sources/CandidateBenchmark/Harness.swift"
            driver.parent.mkdir(parents=True)
            driver.write_bytes(harness["Harness.swift"])
            for relative in ("heap.c", "include/CHeapProbe.h"):
                destination = package / "Sources/CHeapProbe" / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(harness["CHeapProbe/" + relative])
        self.manifest["package_sha256"] = sha(PACKAGE.encode())
        self.save_manifest()

    def build(self) -> None:
        for variant in ("baseline", "candidate"):
            print(f"Build unchanged {variant} source snapshot", flush=True)
            base = [self.args.swift, "build", "--package-path", self.output / "build" / variant,
                    "--configuration", "release", "--jobs", "2",
                    "--cache-path", self.output / "package-cache", "--config-path", self.output / "package-config",
                    "--security-path", self.output / "package-security",
                    "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-whole-module-optimization"]
            if platform.system() == "Linux":
                base.append("--use-integrated-swift-driver")
            self.command([*base, "--product", "CandidateBenchmark"], log=f"{variant}-build.log")
            path = Path(self.command([*base, "--show-bin-path"]).decode().strip()) / "CandidateBenchmark"
            self.binaries[variant] = path
            self.manifest["binary_sha256"][variant] = sha(path.read_bytes())
        self.save_manifest()

    def observe(self, variant: str, mode: str, scenario: str, count: int, iterations: int) -> dict:
        row = json.loads(self.command([self.binaries[variant], mode, scenario, count, iterations]))
        if row["mode"] != mode or row["scenario"] != scenario or row["receipt"]["mediaCount"] != count:
            raise ValueError("Observation did not match its requested workload")
        expected_subtitles = 0 if scenario == "empty" else (3 if scenario == "exact" else 1)
        expected_assigned = 3 if scenario == "exact" else 0
        if (row["iterations"] != iterations
                or row["receipt"]["inputSubtitleCount"] != expected_subtitles
                or row["receipt"]["assignedSubtitleCount"] != expected_assigned
                or row["heapMetric"] not in {"mallinfo2.uordblks + mallinfo2.hblkhd",
                                              "malloc_zone_statistics(NULL).size_in_use"}):
            raise ValueError("Observation has invalid workload or allocator metadata")
        if mode == "memory":
            before, maximum, after = row["heapBeforeBytes"], row["maximumSampledHeapBytes"], row["heapWithOutputBytes"]
            if (iterations != 1 or maximum < max(before, after)
                    or row["sampledPeakAllocatorGrowthBytes"] != maximum - before
                    or row["outputAllocatorGrowthBytes"] != after - before
                    or not 0 <= row["maximumSamplePoll"] <= row["cancellationPollCount"]
                    or row["cancellationPollCount"] < 1):
                raise ValueError("Inconsistent sampled memory observation")
        else:
            if (row["loopWallNanoseconds"] <= 0 or row["loopCPUNanoseconds"] <= 0
                    or row["consumedCount"] != iterations * (count + expected_assigned)):
                raise ValueError("Invalid timing clocks or result consumption")
        row["variant"] = variant
        return row

    @staticmethod
    def parity(baseline: dict, candidate: dict) -> None:
        if baseline["receipt"] != candidate["receipt"]:
            raise ValueError("Association receipt parity failed")
        if baseline["heapMetric"] != candidate["heapMetric"]:
            raise ValueError("Allocator metric changed between variants")
        if baseline["mode"] == "memory" and baseline["cancellationPollCount"] != candidate["cancellationPollCount"]:
            raise ValueError("Cancellation poll count changed")

    def verify(self) -> None:
        verification = []
        for count in self.args.sizes:
            for scenario in self.args.scenarios:
                snapshots = {}
                for variant in ("baseline", "candidate"):
                    raw = self.command([self.binaries[variant], "verify", scenario, count, 1])
                    value = json.loads(raw)
                    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
                    path = self.output / "verification" / f"{variant}-{scenario}-{count}.json.gz"
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(gzip.compress(canonical, compresslevel=9, mtime=0))
                    snapshots[variant] = canonical
                if snapshots["baseline"] != snapshots["candidate"]:
                    raise ValueError(f"Full association output mismatch: {count} / {scenario}")
                verification.append({"media_count": count, "scenario": scenario,
                                     "full_association_sha256": sha(snapshots["baseline"]),
                                     "uncompressed_bytes": len(snapshots["baseline"]),
                                     "status": "byte-identical canonical association records"})
        save(self.output / "verification.json", verification)
        print(f"Full association parity passed for {len(verification)} workloads", flush=True)

    def measure(self) -> None:
        if self.args.regression_only:
            raise ValueError("Regression-only snapshots cannot qualify historical performance")
        rows, calibration = [], []
        for count in self.args.sizes:
            for scenario in self.args.scenarios:
                if self.args.memory_only:
                    iterations = 1
                elif self.args.iterations is None:
                    pilots = {variant: self.observe(variant, "timing", scenario, count, 1)
                              for variant in ("baseline", "candidate")}
                    self.parity(pilots["baseline"], pilots["candidate"])
                    # Process CPU avoids treating host descheduling as useful
                    # benchmark work. Calibrate against the faster pilot so
                    # both variants target at least this much CPU work.
                    fastest = min(value["loopCPUNanoseconds"] for value in pilots.values())
                    iterations = max(1, min(100_000, math.ceil(self.args.target_ms * 1e6 / max(1, fastest))))
                    calibration.append({"media_count": count, "scenario": scenario,
                                        "iterations": iterations, "basis": "faster pilot process CPU",
                                        "observations": pilots})
                    save(self.output / "calibration.json", calibration)
                else:
                    iterations = self.args.iterations
                for mode in (("memory",) if self.args.memory_only else ("memory", "timing")):
                    for pair in range(self.args.pairs):
                        order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                        values = {}
                        for variant in order:
                            row = self.observe(variant, mode, scenario, count, iterations if mode == "timing" else 1)
                            row.update(pair=pair, order="AB" if pair % 2 == 0 else "BA")
                            values[variant] = row
                            rows.append(row)
                            self.append("observations.jsonl", row)
                        self.parity(values["baseline"], values["candidate"])
                print(f"Verified {count} media / {scenario} / {self.args.pairs} pairs per mode", flush=True)
        save(self.output / "summary.json", summarize(rows))
        self.manifest.update(observation_count=len(rows), all_parity_checks_passed=True,
                             performance_measured=True,
                             completed_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        self.save_manifest()


def summarize(rows: list[dict]) -> dict:
    cases = []
    for count, scenario in sorted({(row["receipt"]["mediaCount"], row["scenario"]) for row in rows}):
        selected = [row for row in rows if row["receipt"]["mediaCount"] == count and row["scenario"] == scenario]
        result = {"media_count": count, "scenario": scenario}
        for mode, key, label in (
            ("memory", "sampledPeakAllocatorGrowthBytes", "sampled_peak_allocator_growth_bytes"),
            ("memory", "outputAllocatorGrowthBytes", "output_allocator_growth_bytes"),
            ("timing", "loopWallNanoseconds", "wall_ns_per_association"),
            ("timing", "loopCPUNanoseconds", "cpu_ns_per_association"),
        ):
            observations = [row for row in selected if row["mode"] == mode]
            if not observations:
                continue
            result[label] = {variant: distribution([row[key] / row["iterations"] for row in observations
                                                    if row["variant"] == variant])
                             for variant in ("baseline", "candidate")}
            pairs = {index: {row["variant"]: row[key] / row["iterations"] for row in observations
                             if row["pair"] == index} for index in {row["pair"] for row in observations}}
            changes = [(pair["candidate"] / pair["baseline"] - 1) * 100
                       for pair in pairs.values() if pair["baseline"] > 0]
            result[label]["paired_percent_change"] = distribution(changes) if changes else None
        result["cancellation_poll_counts"] = {variant: sorted({row["cancellationPollCount"] for row in selected
            if row["variant"] == variant and row["mode"] == "memory"}) for variant in ("baseline", "candidate")}
        result["receipt"] = selected[0]["receipt"]
        cases.append(result)
    return {"observations": len(rows), "full_output_and_poll_parity_passed": True,
            "metric_warning": "Cancellation-poll sampled allocator high watermark is not every-allocation peak or RSS; memory instrumented runs are never used for timings",
            "cases": cases}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline-dir", type=Path, help="Retained baseline sources when pinned Git commit is unavailable; hashes must match")
    parser.add_argument("--regression-only", action="store_true",
        help="Verify full outputs with identical current supporting sources in both variants; no memory or timing measurement")
    parser.add_argument("--sizes", default="64,512,4096,32768")
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--iterations", type=int, help="Fixed equal iteration count instead of calibration")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--memory-only", action="store_true", help="Verify outputs and measure memory without calibration or timing processes")
    parser.add_argument("--cpu", type=int, help="Pin this process and children to one available Linux CPU")
    args = parser.parse_args()
    if args.regression_only and (args.prepare_only or args.memory_only):
        parser.error("--regression-only requires verification and prohibits measurement")
    args.sizes = [int(value) for value in args.sizes.split(",")]
    args.scenarios = args.scenarios.split(",")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive and even for balanced AB/BA ordering")
    if not args.sizes or any(value < 2 for value in args.sizes):
        parser.error("--sizes must contain integers of at least 2")
    if not args.scenarios or any(value not in SCENARIOS for value in args.scenarios):
        parser.error(f"--scenarios must be selected from {SCENARIOS}")
    if args.target_ms <= 0 or (args.iterations is not None and args.iterations < 1):
        parser.error("--target-ms and --iterations must be positive")
    if args.cpu is not None:
        if not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0):
            parser.error("Requested CPU affinity is unavailable")
        os.sched_setaffinity(0, {args.cpu})
    runner = Runner(args)
    try:
        runner.prepare()
        runner.build()
        if not args.prepare_only:
            runner.verify()
            if args.regression_only:
                save(runner.output / "summary.json", {
                    "status": "passed", "qualification": "current-support-regression",
                    "full_output_parity_passed": True, "performance_measured": False,
                    "workloads": len(args.sizes) * len(args.scenarios),
                    "scope": "Full fixture oracle and paired output parity; current-source unit tests run separately",
                })
            elif not args.verify_only:
                runner.measure()
        runner.manifest["status"] = "passed"
    except BaseException as error:
        runner.manifest.update(status="failed", error=str(error))
        raise
    finally:
        runner.save_manifest()
    print(f"Evidence: {runner.output}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Subtitle candidate qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
