#!/usr/bin/env python3
"""Compare complete production source-presence scans on shared real fixtures.

Use Swift 6.1+ and Python 3.10+. Submit this runner through Kyoto when that
queue is available. Each variant has an isolated SwiftPM build directory; all
compilation and test execution is serial. Native macOS evidence is required for
macOS performance claims. The fixture trees are deliberately warmed, so timings
do not establish cold-storage, whole-player, or SwiftUI performance.
"""
from __future__ import annotations

import argparse
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
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PIN = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCANNER = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
IDENTITY_SOURCE = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
CORE = ["MediaFileSupport.swift", "NormalizedFileURL.swift", "SourcePreparationExecutor.swift"]
APP = ["UI/SourceMediaPresenceRecomputation.swift", "App/SourceRootPruning.swift"]
TESTS = ["SourceMediaPresenceReuseTests.swift", "SourceMediaPresenceRecomputationTests.swift",
         "SourceMediaPresenceTraversalTests.swift"]
VARIANTS = ("baseline", "candidate")
CONFIGURATIONS = ("debug", "release")
TIMINGS = ("elapsed_ns", "cpu_ns")
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True, ensure_ascii=False) + "\n")


def declaration(source: str, marker: str) -> str:
    """Extract the same exact, brace-literal-free identity declaration as prior research."""
    if source.count(marker) != 1:
        raise RuntimeError(f"Expected exactly one declaration: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise RuntimeError(f"Unclosed declaration: {marker}")


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output
        self.build = self.output / "build"
        self.fixtures = self.output / "fixtures"
        self.inputs: dict[Path, str] = {}
        self.staged: dict[str, dict] = {}
        self.binaries: dict[tuple[str, str], Path] = {}
        self.env = os.environ.copy()
        self.env.update(CLANG_MODULE_CACHE_PATH=str(self.build / "module-cache"),
                        SWIFT_MODULECACHE_PATH=str(self.build / "module-cache"),
                        SWIFTPM_MODULECACHE_OVERRIDE=str(self.build / "module-cache"),
                        SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb", NO_COLOR="1")
        self.manifest: dict = {}

    def run(self, arguments: list, *, name: str | None = None, timeout: int = 900) -> str:
        argv = [str(value) for value in arguments]
        started = time.time()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        append(self.output / "commands.jsonl", {
            "argv": argv, "started_unix": started, "seconds": time.time() - started,
            "returncode": result.returncode, "stdout_sha256": digest(result.stdout.encode()),
            "stderr_sha256": digest(result.stderr.encode()), "stderr": result.stderr,
        })
        if name:
            (self.output / name).write_text(result.stdout + result.stderr)
        if result.returncode:
            (self.output / "failure.log").write_text(result.stdout + result.stderr)
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-3000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def read(self, path: Path) -> bytes:
        data = path.read_bytes()
        checksum = digest(data)
        if path in self.inputs and self.inputs[path] != checksum:
            raise RuntimeError(f"Input changed during staging: {path}")
        self.inputs[path] = checksum
        return data

    def stage(self, variant: str) -> dict:
        package = self.build / variant
        receipts: dict = {}

        def put(relative: str, data: bytes, origin: str, transformation: str = "none") -> None:
            path = package / relative
            snapshot = self.output / "sources" / variant / relative
            for destination in (path, snapshot):
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            receipts[relative] = {"origin": origin, "sha256": digest(data),
                                  "bytes": len(data), "transformation": transformation,
                                  "snapshot": str(snapshot.relative_to(self.output))}

        scanner = HERE / "baseline/SourceMediaPresenceScanner.swift" if variant == "baseline" else ROOT / SCANNER
        put("Sources/IlliquidApp/SourceMediaPresenceScanner.swift", self.read(scanner),
            str(scanner.relative_to(ROOT)))
        for name in CORE:
            path = ROOT / "Sources/IlliquidCore/Utilities" / name
            put("Sources/IlliquidCore/" + name, self.read(path), str(path.relative_to(ROOT)))
        for name in APP:
            path = ROOT / "Sources/IlliquidApp" / name
            put("Sources/IlliquidApp/" + Path(name).name, self.read(path), str(path.relative_to(ROOT)))
        identity = "import Foundation\nimport IlliquidCore\n\n" + declaration(
            self.read(ROOT / IDENTITY_SOURCE).decode(), "enum SourceTreeIdentity {") + "\n"
        put("Sources/IlliquidApp/SourceTreeIdentity.swift", identity.encode(), IDENTITY_SOURCE,
            "exact SourceTreeIdentity declaration; Foundation/IlliquidCore imports added")
        put("Sources/PresenceTraversalBenchmark/Harness.swift", self.read(HERE / "Harness.swift"),
            "Benchmarks/SourcePresenceTraversal/Harness.swift")
        for name in TESTS:
            path = ROOT / "Tests/IlliquidAppTests" / name
            put("Tests/IlliquidAppTests/" + name, self.read(path), str(path.relative_to(ROOT)))
        manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourcePresenceTraversal", platforms: [.macOS("26.0")],
    products: [.executable(name: "PresenceTraversalBenchmark", targets: ["PresenceTraversalBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .executableTarget(name: "PresenceTraversalBenchmark", dependencies: ["IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"]),
    ], swiftLanguageModes: [.v6]
)
'''
        put("Package.swift", manifest.encode(), "generated isolated component package")
        self.staged[variant] = receipts
        return receipts

    def prepare(self) -> None:
        if KYOTO.is_file():
            print("Kyoto is available; the caller must submit this runner through its default queue.", flush=True)
        else:
            print("Kyoto is unavailable on this host; compiling serially in isolated component packages.", flush=True)
        baseline = json.loads(self.read(HERE / "baseline/manifest.json"))
        data = self.read(HERE / "baseline/SourceMediaPresenceScanner.swift")
        if baseline["commit"] != PIN or baseline["source"] != SCANNER or digest(data) != baseline["sha256"]:
            raise RuntimeError("Pinned full-source baseline manifest/hash mismatch")
        for path, checksum in baseline["shared_sources_sha256"].items():
            if digest(self.read(ROOT / path)) != checksum:
                raise RuntimeError(f"Shared dependency changed since the baseline pin; review attribution: {path}")
        if data == self.read(ROOT / SCANNER):
            raise RuntimeError("Baseline and candidate scanner are identical; no optimization to measure")
        save(self.output / "baseline-pin.json", baseline)
        self.manifest = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(), "logical_cpus": os.cpu_count(),
            "compiler": self.run([self.args.swift, "--version"]).strip(),
            "git_head": self.run(["git", "rev-parse", "HEAD"]).strip(),
            "git_status": self.run(["git", "status", "--short"]),
            "baseline": baseline,
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
            "runner_sha256": digest(self.read(Path(__file__))),
            "harness_sha256": digest(self.read(HERE / "Harness.swift")),
            "kyoto_available": KYOTO.is_file(),
            "environment_overrides": {key: self.env[key] for key in (
                "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE",
                "SWIFT_DETERMINISTIC_HASHING", "TERM", "NO_COLOR")},
            "method": "Exact full scanner and shared dependencies; real filesystem enumeration; separate modules; "
                      "serial debug/release tests; canonical complete-output parity; common iteration count; "
                      "balanced fresh-process AB/BA release pairs; workload order rotates between pairs.",
            "scope": "Complete SourceMediaPresenceCursor traversal including batch construction/destruction and "
                     "a small per-batch checksum; excludes fixture construction, complete-output verification, "
                     "the async scanner publication loop, UI rendering, and media playback.",
            "cache_scope": "Same generated fixture trees for all runs, with one warmup scan in each process. "
                           "No cache flushing: these are warm-filesystem component timings, not cold-storage latency.",
            "calibration_policy": "A common iteration count targets the slower pilot at target-ms; "
                                  "all measured samples are retained, including faster or below-target samples.",
            "predeclared_acceptance": {
                "primary_cases": ["flat-media-4096", "flat-nonmedia-4096"],
                "minimum_median_paired_cpu_reduction_percent": 5,
                "minimum_cpu_improved_pairs_of_10": 8,
                "controls": ["directory-heavy-2048", "cached-directories-64"],
                "control_review": "No consistent CPU regression above 5%; report all controls and review "
                                  "paired consistency. This is a research decision, not a noisy CI timing gate.",
            },
        }
        if platform.system() == "Darwin":
            self.manifest.update(
                hardware=self.run(["sysctl", "hw.model", "machdep.cpu.brand_string"]).strip(),
                sw_vers=self.run(["sw_vers"]).strip(),
                sdk_version=self.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
                developer_dir=os.environ.get("DEVELOPER_DIR"),
            )
        elif Path("/proc/cpuinfo").exists():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), "unknown")
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        self.manifest["source_receipts"] = {variant: self.stage(variant) for variant in VARIANTS}
        save(self.output / "manifest.json", self.manifest)

    def swift(self, variant: str, operation: str, configuration: str) -> list:
        command = [self.args.swift, operation, "--package-path", self.build / variant,
                   "--configuration", configuration, "--jobs", "2",
                   "--cache-path", self.build / "cache", "--config-path", self.build / "config",
                   "--security-path", self.build / "security", "-Xswiftc", "-warnings-as-errors",
                   "-Xswiftc", "-enable-testing"]
        if operation == "test":
            # All staged suites use Swift Testing. Selecting it explicitly also
            # prevents SwiftPM from suffixing its XML path with -swift-testing
            # to distinguish it from an empty XCTest receipt.
            command += ["--no-parallel", "--disable-xctest", "--enable-swift-testing",
                        "--xunit-output", self.output / f"{variant}-{configuration}-tests.xml"]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def build_and_test(self) -> None:
        tests = []
        for variant in VARIANTS:
            for configuration in CONFIGURATIONS:
                prefix = f"{variant}-{configuration}"
                self.run(self.swift(variant, "build", configuration) + ["--product", "PresenceTraversalBenchmark"],
                         name=f"{prefix}-build.log")
                self.run(self.swift(variant, "test", configuration), name=f"{prefix}-tests.log")
                report = ET.parse(self.output / f"{prefix}-tests.xml").getroot()
                cases = report.findall(".//testcase")
                executed = [case for case in cases if case.find("skipped") is None and "time" in case.attrib]
                failures = report.findall(".//failure") + report.findall(".//error")
                if not executed or failures:
                    raise RuntimeError(f"Invalid test receipt for {prefix}: require nonzero completed tests and no failures")
                tests.append({"variant": variant, "configuration": configuration, "passed": True,
                              "matched": len(cases), "executed": len(executed), "failures": len(failures),
                              "test_names": [case.attrib for case in executed],
                              "receipt_sha256": digest((self.output / f"{prefix}-tests.xml").read_bytes())})
                save(self.output / "tests.json", tests)
                directory = self.run(self.swift(variant, "build", configuration) + ["--show-bin-path"]).strip()
                self.binaries[(variant, configuration)] = Path(directory) / "PresenceTraversalBenchmark"
                print(f"{prefix}: {len(executed)} tests executed, zero failures", flush=True)
        self.manifest["binary_sha256"] = {
            f"{variant}-{configuration}": digest(binary.read_bytes())
            for (variant, configuration), binary in self.binaries.items()}
        save(self.output / "manifest.json", self.manifest)

    def invoke(self, variant: str, configuration: str, *arguments: object) -> object:
        return json.loads(self.run([self.binaries[variant, configuration], "--fixtures", self.fixtures, *arguments]))

    def verify(self) -> list[dict]:
        preparation = self.run([self.binaries["candidate", "release"], "--fixtures", self.fixtures,
                                "--prepare"], name="fixture-preparation.log")
        save(self.output / "preparation.json", {"fixtures": str(self.fixtures), "prepared_by": "candidate-release",
                                                "stdout_sha256": digest(preparation.encode())})
        reference = None
        catalog = None
        parity = []
        for variant in VARIANTS:
            for configuration in CONFIGURATIONS:
                cases = self.invoke(variant, configuration, "--list")
                if not isinstance(cases, list) or not cases or any(not isinstance(case.get("case"), str) for case in cases):
                    raise RuntimeError("Harness must return a nonempty case catalog with case names")
                names = [case["case"] for case in cases]
                if len(set(names)) != len(names):
                    raise RuntimeError("Duplicate benchmark case name")
                if catalog is not None and cases != catalog:
                    raise RuntimeError(f"Workload catalog differs for {variant}-{configuration}")
                catalog = cases
                trace = self.invoke(variant, configuration, "--differential")
                save(self.output / f"{variant}-{configuration}-outputs.json", trace)
                if reference is not None and trace != reference:
                    raise RuntimeError(f"Complete output parity failed: {variant}-{configuration}")
                reference = trace
                parity.append({"variant": variant, "configuration": configuration, "equal": True,
                               "canonical_output_sha256": digest(canonical(trace)),
                               "trace_cases": len(trace) if isinstance(trace, list) else None})
        save(self.output / "cases.json", catalog)
        save(self.output / "parity.json", {"equal": True, "comparisons": parity})
        print("Complete canonical output parity passed for both variants in debug and release", flush=True)
        if self.args.cases:
            selected = self.args.cases.split(",")
            if len(set(selected)) != len(selected) or set(selected) - {case["case"] for case in catalog}:
                raise RuntimeError(f"Invalid/duplicate case selection: {selected}")
            return [case for case in catalog if case["case"] in selected]
        return catalog

    def sample(self, variant: str, case: str, iterations: int) -> dict:
        row = self.invoke(variant, "release", "--case", case, "--iterations", iterations)
        if (row["case"], row["iterations"], row["operations"]) != (case, iterations, iterations):
            raise RuntimeError(f"Sample does not match requested scans: {row}")
        for field in TIMINGS:
            if not isinstance(row[field], (int, float)) or not math.isfinite(row[field]) or row[field] <= 0:
                raise RuntimeError(f"Invalid sample {field}: {row}")
        if row.get("warmup_iterations") != 1:
            raise RuntimeError(f"Expected exactly one untimed warmup scan: {row}")
        for field in ("visited_entries", "checksum", "warmup_checksum"):
            if field not in row:
                raise RuntimeError(f"Missing correctness receipt {field}: {row}")
        return row

    @staticmethod
    def require_pair_parity(samples: dict[str, dict]) -> None:
        values = [{key: value for key, value in samples[variant].items() if key not in TIMINGS}
                  for variant in VARIANTS]
        if values[0] != values[1]:
            raise RuntimeError(f"Timed scan checksum/count mismatch: {values}")

    def measure(self, cases: list[dict]) -> None:
        rows: list[dict] = []
        summaries = []
        iteration_counts = {}
        target = self.args.target_ms * 1_000_000
        for case in cases:
            name = case["case"]
            pilots = {variant: [] for variant in VARIANTS}
            for attempt in range(2):
                order = VARIANTS if attempt % 2 == 0 else tuple(reversed(VARIANTS))
                samples = {variant: self.sample(variant, name, 1) for variant in order}
                self.require_pair_parity(samples)
                for variant in order:
                    pilots[variant].append(samples[variant]["elapsed_ns"])
                    append(self.output / "calibration.jsonl", dict(samples[variant], variant=variant,
                                                                   attempt=attempt, order=list(order)))
            slower = max(statistics.median(samples) for samples in pilots.values())
            requested = math.ceil(target / slower)
            iterations = max(1, min(100_000, requested))
            iteration_counts[name] = iterations
            append(self.output / "calibration.jsonl", {"case": name, "decision": "common_iteration_count",
                "iterations": iterations, "requested_iterations": requested, "cap_applied": requested > 100_000,
                "slower_pilot_ns_per_scan": slower, "target_ms": self.args.target_ms})

        # Keep each baseline/candidate pair adjacent, while rotating workload
        # order to spread longer-term host drift across all cases. Variant order
        # uses the original case index so every case has exactly balanced AB/BA.
        original_indices = {case["case"]: index for index, case in enumerate(cases)}
        schedule = []
        for pair in range(self.args.pairs):
            offset = pair % len(cases)
            for position, case in enumerate(cases[offset:] + cases[:offset]):
                name = case["case"]
                order = VARIANTS if (pair + original_indices[name]) % 2 == 0 else tuple(reversed(VARIANTS))
                schedule.append({"pair": pair, "workload_position": position, "case": name,
                                 "iterations": iteration_counts[name], "order": list(order)})
        save(self.output / "schedule.json", schedule)
        for scheduled in schedule:
            name = scheduled["case"]
            iterations = scheduled["iterations"]
            order = scheduled["order"]
            samples = {}
            for position, variant in enumerate(order):
                raw = self.sample(variant, name, iterations)
                samples[variant] = raw
                row = dict(raw, variant=variant, pair=scheduled["pair"], order=order,
                           workload_position=scheduled["workload_position"], process_position=position)
                rows.append(row)
                append(self.output / "measurements.jsonl", row)
            self.require_pair_parity(samples)
            print(f'Completed pair {scheduled["pair"] + 1}/{self.args.pairs}: {name}', flush=True)

        for case in cases:
            name = case["case"]
            iterations = iteration_counts[name]
            current = [row for row in rows if row["case"] == name]
            summary = {**case, "pairs": self.args.pairs, "iterations": iterations, "metrics": {}}
            for metric in TIMINGS:
                values = {variant: [row[metric] / row["operations"] for row in current if row["variant"] == variant]
                          for variant in VARIANTS}
                medians = {variant: statistics.median(values[variant]) for variant in VARIANTS}
                reductions = [100 * (1 - values["candidate"][pair] / values["baseline"][pair])
                              for pair in range(self.args.pairs)]
                summary["metrics"][metric] = {
                    "median_ns_per_scan": medians,
                    "range_ns_per_scan": {variant: [min(values[variant]), max(values[variant])] for variant in VARIANTS},
                    "ratio_of_medians_reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                    "paired_reduction_percent": reductions,
                    "median_paired_reduction_percent": statistics.median(reductions),
                    "improved_pairs": sum(value > 0 for value in reductions),
                }
            summary["below_target_samples"] = [{"variant": row["variant"], "pair": row["pair"],
                "elapsed_ms": row["elapsed_ns"] / 1_000_000} for row in current if row["elapsed_ns"] < target]
            summaries.append(summary)
            wall = summary["metrics"]["elapsed_ns"]
            cpu = summary["metrics"]["cpu_ns"]
            print(f'{name}: wall {wall["median_ns_per_scan"]["baseline"] / 1e6:.3f} -> '
                  f'{wall["median_ns_per_scan"]["candidate"] / 1e6:.3f} ms/scan; '
                  f'paired wall reduction {wall["median_paired_reduction_percent"]:.2f}%; '
                  f'paired CPU reduction {cpu["median_paired_reduction_percent"]:.2f}%', flush=True)
        save(self.output / "summary.json", {"units": "nanoseconds per complete scan", "cases": summaries,
                                              "observation_count": len(rows), "omitted_observations": 0})

    def verify_sources(self) -> None:
        inputs = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in self.inputs}
        changed = [str(path) for path, expected in self.inputs.items() if digest(path.read_bytes()) != expected]
        staged = {}
        for variant, receipts in self.staged.items():
            staged[variant] = {}
            for relative, receipt in receipts.items():
                actual = digest((self.build / variant / relative).read_bytes())
                snapshot = digest((self.output / receipt["snapshot"]).read_bytes())
                staged[variant][relative] = actual
                if actual != receipt["sha256"] or snapshot != receipt["sha256"]:
                    changed.append(f"{variant}/{relative}")
        save(self.output / "source-verification.json", {
            "unchanged": not changed, "changed": changed, "input_sha256": inputs, "staged_sha256_after_run": staged})
        if changed:
            raise RuntimeError(f"Benchmark inputs or staged sources changed during execution: {changed}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=350)
    parser.add_argument("--cases", help="Optional comma-separated subset; correctness still checks the full catalog")
    parser.add_argument("--correctness-only", "--tests-only", action="store_true", dest="correctness_only")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target-ms")
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use a new/empty output directory to preserve prior attempts")
    args.output.mkdir(parents=True, exist_ok=True)
    runner = Runner(args)
    try:
        runner.prepare()
        runner.build_and_test()
        cases = runner.verify()
        if not args.correctness_only:
            runner.measure(cases)
        runner.verify_sources()
        save(args.output / "completion.json", {"status": "passed", "correctness_only": args.correctness_only,
            "cases": [case["case"] for case in cases], "sources_unchanged": True,
            "observations": 0 if args.correctness_only else len(cases) * args.pairs * 2,
            "performance_threshold_evaluated": False})
    except Exception as error:
        save(args.output / "completion.json", {"status": "failed", "error": str(error)})
        raise


if __name__ == "__main__":
    main()
