#!/usr/bin/env python3
"""Measure complete synchronous source-presence invalidation against a pinned baseline."""
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
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCANNER = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
CORE = ["MediaFileSupport.swift", "NormalizedFileURL.swift", "SourcePreparationExecutor.swift"]
APP = ["UI/SourceMediaPresenceRecomputation.swift", "App/SourceRootPruning.swift"]
TESTS = ["SourceMediaPresenceReuseTests.swift", "SourceMediaPresenceRecomputationTests.swift",
         "SourceMediaPresenceInvalidationTests.swift"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def declaration(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"Declaration boundary changed: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise RuntimeError(f"Unclosed declaration: {marker}")


class Experiment:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.build = self.output / "build"
        (self.output / "logs").mkdir()
        self.env = os.environ.copy()
        self.env.update(SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb", NO_COLOR="1")
        for key in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.env[key] = str(self.build / "module-cache")
        self.swift = shutil.which(args.swift)
        if not self.swift:
            raise RuntimeError(f"Swift executable not found: {args.swift}")
        self.command_count = 0
        self.executables = {}
        self.manifest = {}
        self.source_snapshots = {}

    def command(self, argv: list, label: str, timeout: int = 600) -> str:
        args = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        self.command_count += 1
        prefix = f"{self.command_count:04d}-{label}"
        stdout = self.output / "logs" / (prefix + ".stdout.log")
        stderr = self.output / "logs" / (prefix + ".stderr.log")
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        append(self.output / "commands.jsonl", {
            "argv": args, "exitCode": result.returncode,
            "elapsedSeconds": time.monotonic() - started,
            "stdout": str(stdout.relative_to(self.output)), "stdoutSHA256": digest(stdout.read_bytes()),
            "stderr": str(stderr.relative_to(self.output)), "stderrSHA256": digest(stderr.read_bytes()),
        })
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{result.stdout[-5000:]}\n{result.stderr[-5000:]}")
        return result.stdout

    def swift_command(self, variant: str, operation: str, configuration: str) -> list:
        command = [self.swift, operation, "--package-path", self.build / variant,
                   "-c", configuration, "--jobs", "2", "--cache-path", self.build / "cache",
                   "--config-path", self.build / "config", "--security-path", self.build / "security",
                   "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-enable-testing"]
        if operation == "test":
            command.append("--no-parallel")
        # The external driver reads process statistics unavailable in some
        # container sandboxes. Use SwiftPM's bundled driver in that environment.
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def stage(self) -> None:
        pinned = json.loads((HERE / "baseline/manifest.json").read_text())
        baseline = (HERE / "baseline/SourceMediaPresenceScanner.swift").read_bytes()
        if digest(baseline) != pinned["sha256"]:
            raise RuntimeError("Frozen scanner does not match baseline manifest")
        sources = {"baseline": baseline, "candidate": (ROOT / SCANNER).read_bytes()}
        for path, expected in pinned["sharedSources"].items():
            if digest((ROOT / path).read_bytes()) != expected:
                raise RuntimeError(f"Shared source changed; requalify baseline isolation: {path}")
        self.manifest = {
            "baseline": pinned, "head": self.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "startedUTC": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "swift": self.command([self.swift, "--version"], "swift-version").strip(),
            "gitStatus": self.command(["git", "status", "--short"], "git-status"),
            "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(self.args).items()},
            "environment": {key: self.env.get(key) for key in ["SWIFT_DETERMINISTIC_HASHING", "DEVELOPER_DIR", "LD_LIBRARY_PATH"]},
            "runnerSHA256": digest(Path(__file__).read_bytes()), "sources": {}, "executables": {},
            "scope": "Complete synchronous invalidate; fixture restoration, state receipts and queued asynchronous traversal are outside timing.",
            "instrumentation": "Two monotonic wall and two process CPU clock readings per event sequence; no overhead subtraction.",
        }
        if platform.system() == "Darwin":
            self.manifest["macOS"] = self.command(["sw_vers"], "macos").strip()
            self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        else:
            self.manifest["cpu"] = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                                          if line.startswith("model name")), "unknown")
        for variant, scanner in sources.items():
            package = self.build / variant
            receipts = {}
            self.source_snapshots[variant] = {}

            def put(relative: str, content: bytes, origin: str, transformation: str = "none") -> None:
                target = package / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
                receipts[relative] = {"origin": origin, "sha256": digest(content), "transformation": transformation}
                self.source_snapshots[variant][relative] = content.decode()

            support = (HERE / "Support.swift").read_bytes()
            put("Sources/IlliquidApp/SourceMediaPresenceScanner.swift", scanner + b"\n" + support, SCANNER,
                "Complete production source unchanged, followed by test-only same-file setup/state access extension")
            receipts["originalScanner"] = {"sha256": digest(scanner)}
            receipts["appendedSupport"] = {"sha256": digest(support)}
            for name in CORE:
                path = "Sources/IlliquidCore/Utilities/" + name
                put("Sources/IlliquidCore/" + name, (ROOT / path).read_bytes(), path)
            for name in APP:
                path = "Sources/IlliquidApp/" + name
                put("Sources/IlliquidApp/" + Path(name).name, (ROOT / path).read_bytes(), path)
            identity_path = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
            identity = "import Foundation\nimport IlliquidCore\n\n" + declaration((ROOT / identity_path).read_text(), "enum SourceTreeIdentity {") + "\n"
            if digest(identity.encode()) != pinned["identitySHA256"]:
                raise RuntimeError("Shared SourceTreeIdentity declaration changed")
            put("Sources/IlliquidApp/SourceTreeIdentity.swift", identity.encode(), identity_path,
                "Exact SourceTreeIdentity declaration with imports")
            put("Sources/PresenceInvalidationBenchmark/Harness.swift", (HERE / "Harness.swift").read_bytes(),
                "Benchmarks/SourcePresenceInvalidation/Harness.swift")
            for name in TESTS:
                path = "Tests/IlliquidAppTests/" + name
                put("Tests/IlliquidAppTests/" + name, (ROOT / path).read_bytes(), path)
            manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SourcePresenceInvalidation", platforms: [.macOS("26.0")],
    products: [.executable(name: "PresenceInvalidationBenchmark", targets: ["PresenceInvalidationBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .executableTarget(name: "PresenceInvalidationBenchmark", dependencies: ["IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
    ], swiftLanguageModes: [.v6])
'''
            put("Package.swift", manifest.encode(), "Generated isolated component package")
            self.manifest["sources"][variant] = receipts
        self.source_snapshots["runner.py"] = Path(__file__).read_text()
        packed = gzip.compress(json.dumps(self.source_snapshots, sort_keys=True).encode(), mtime=0)
        (self.output / "compiled-sources.json.gz").write_bytes(packed)
        self.manifest["sourceSnapshotsSHA256"] = digest(packed)
        save(self.output / "manifest.json", self.manifest)

    def build_and_verify(self) -> dict:
        validation = {}
        reference = {}
        cases = None
        for variant in ("baseline", "candidate"):
            for configuration in ("debug", "release"):
                label = f"{variant}-{configuration}"
                if self.args.skip_tests:
                    self.command(self.swift_command(variant, "build", configuration), label + "-build")
                    test_count = 0
                else:
                    test_output = self.command(self.swift_command(variant, "test", configuration), label + "-tests")
                    counts = re.findall(r"Test run with (\d+) tests?\b", test_output)
                    test_count = int(counts[-1]) if counts else 0
                    if test_count == 0:
                        raise RuntimeError(f"No completed Swift Testing tests: {label}")
                folder = self.command(self.swift_command(variant, "build", configuration) + ["--show-bin-path"], label + "-bin").strip()
                executable = Path(folder) / "PresenceInvalidationBenchmark"
                self.executables[(variant, configuration)] = executable
                self.manifest["executables"][label] = digest(executable.read_bytes())
                catalog = json.loads(self.command([executable, "--mode", "cases"], label + "-cases"))
                if cases is not None and cases != catalog:
                    raise RuntimeError("Fixture catalogs differ between builds")
                cases = catalog
                traces = {}
                for ownership in cases["ownerships"]:
                    for case in cases["verificationCases"]:
                        raw = self.command([executable, "--mode", "verify", "--case", case, "--seed", "41",
                                            "--ownership", ownership], label + "-verify")
                        trace = json.loads(raw)
                        key = ownership + "/" + case
                        if key not in reference:
                            reference[key] = trace
                        elif trace != reference[key]:
                            save(self.output / f"mismatch-{label}-{case}-{ownership}.json", trace)
                            raise RuntimeError(f"Complete state trace mismatch: {label} / {key}")
                        traces[key] = digest(raw.encode())
                validation[label] = {"exactStateParity": True, "testsPassed": not self.args.skip_tests,
                                     "completedTests": test_count, "traces": traces}
                print(f"{label}: complete state parity and {'tests' if not self.args.skip_tests else 'build'} passed", flush=True)
        packed = json.dumps(reference, sort_keys=True, separators=(",", ":")).encode()
        (self.output / "state-traces.json.gz").write_bytes(gzip.compress(packed, mtime=0))
        save(self.output / "validation.json", validation)
        save(self.output / "cases.json", cases)
        save(self.output / "manifest.json", self.manifest)
        return cases

    def sample(self, variant: str, case: str, ownership: str, iterations: int, seed: int) -> dict:
        executable = self.executables[(variant, "release")]
        row = json.loads(self.command([executable, "--mode", "time", "--case", case,
                                      "--iterations", iterations, "--seed", seed,
                                      "--warmup", 2, "--ownership", ownership], "timing", timeout=300))
        if (row["case"], row["iterations"], row["seed"], row["ownership"]) != (case, iterations, seed, ownership):
            raise RuntimeError("Timing receipt does not match requested workload")
        if row["wallNanoseconds"] <= 0 or row["cpuNanoseconds"] <= 0 or row["operations"] <= 0:
            raise RuntimeError("Invalid timing receipt")
        return row

    def measure(self, catalog: dict) -> None:
        cases = self.args.cases.split(",") if self.args.cases else catalog["timingCases"]
        if len(set(cases)) != len(cases) or not set(cases).issubset(catalog["timingCases"]):
            raise RuntimeError("Select unique known timing cases")
        ownerships = self.args.ownerships.split(",")
        if len(set(ownerships)) != len(ownerships) or not set(ownerships).issubset(catalog["ownerships"]):
            raise RuntimeError("Select unique supported ownership cases")
        groups = [(case, owner) for case in cases for owner in ownerships]
        iteration_counts = {}
        calibration_decisions = {}
        for case, owner in groups:
            suggested = []
            input_entries = 0
            for variant in ("baseline", "candidate"):
                row = self.sample(variant, case, owner, 1, 41)
                append(self.output / "calibration.jsonl", {"variant": variant, **row})
                suggested.append(max(1, math.ceil(self.args.target_ms * 1e6 / min(row["wallNanoseconds"], row["cpuNanoseconds"]))))
                input_entries = max(input_entries, row["inputResults"], row["inputSummaries"])
            requested = max(suggested)
            # Rebuilding a large uniquely-owned fixture is deliberately outside
            # timing, but must not turn a microsecond candidate into hours of
            # setup. Bound that work explicitly and retain short-sample flags.
            entry_cap = max(1, self.args.maximum_restored_entries // max(1, input_entries))
            iteration_cap = min(self.args.maximum_iterations, entry_cap)
            iteration_counts[(case, owner)] = min(iteration_cap, requested)
            calibration_decisions[case + "/" + owner] = {"requestedIterations": requested,
                "selectedIterations": iteration_counts[(case, owner)],
                "iterationCap": iteration_cap, "inputEntries": input_entries,
                "maximumRestoredEntries": self.args.maximum_restored_entries,
                "capped": requested > iteration_cap}
        save(self.output / "calibration-decisions.json", calibration_decisions)
        records = []
        for pair in range(self.args.pairs):
            rotated = groups[pair % len(groups):] + groups[:pair % len(groups)]
            for case, owner in rotated:
                pair_rows = {}
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = self.sample(variant, case, owner, iteration_counts[(case, owner)], 41)
                    pair_rows[variant] = row
                    record = {"variant": variant, "pair": pair, "processOrder": position, **row}
                    records.append(record)
                    append(self.output / "measurements.jsonl", record)
                comparable = lambda row: {k: v for k, v in row.items() if k not in {"wallNanoseconds", "cpuNanoseconds"}}
                if comparable(pair_rows["baseline"]) != comparable(pair_rows["candidate"]):
                    raise RuntimeError(f"Timed state/output mismatch: {case} / {owner} / {pair}")
            print(f"Measured balanced round {pair + 1}/{self.args.pairs}", flush=True)
        persisted = [json.loads(line) for line in (self.output / "measurements.jsonl").read_text().splitlines()]
        if persisted != records or len(records) != len(groups) * self.args.pairs * 2:
            raise RuntimeError("Incomplete measurement cohort")
        summary = []
        for case, owner in groups:
            rows = [r for r in records if (r["case"], r["ownership"]) == (case, owner)]
            group = {"case": case, "ownership": owner, "iterations": iteration_counts[(case, owner)],
                     "operationsPerSample": rows[0]["operations"], "pairs": self.args.pairs}
            for variant in ("baseline", "candidate"):
                selected = [r for r in rows if r["variant"] == variant]
                group[variant] = {}
                for field in ("wallNanoseconds", "cpuNanoseconds"):
                    values = [r[field] / r["operations"] for r in selected]
                    group[variant][field + "PerOperation"] = {"median": statistics.median(values),
                                                              "minimum": min(values), "maximum": max(values)}
            for field in ("wallNanoseconds", "cpuNanoseconds"):
                ratios = []
                for pair in range(self.args.pairs):
                    values = {r["variant"]: r[field] for r in rows if r["pair"] == pair}
                    ratios.append(values["candidate"] / values["baseline"])
                group[field] = {"pairedRatios": ratios, "medianReductionPercent": 100 * (1 - statistics.median(ratios)),
                                "fasterPairs": sum(value < 1 for value in ratios),
                                "minimumSampleNanoseconds": min(r[field] for r in rows),
                                "samplesBelowTarget": sum(r[field] < self.args.target_ms * 1e6 for r in rows),
                                "samplesBelow50Milliseconds": sum(r[field] < 50_000_000 for r in rows)}
            summary.append(group)
            print(f"{case}/{owner}: wall {group['wallNanoseconds']['medianReductionPercent']:+.2f}% reduction, "
                  f"CPU {group['cpuNanoseconds']['medianReductionPercent']:+.2f}% reduction", flush=True)
        save(self.output / "summary.json", {"groups": summary, "observations": len(records)})
        for label, expected in self.manifest["executables"].items():
            variant, configuration = label.split("-", 1)
            if digest(self.executables[(variant, configuration)].read_bytes()) != expected:
                raise RuntimeError("Benchmark binary changed during measurements")
        save(self.output / "completion.json", {"complete": True, "observations": len(records),
                                                "pairs": self.args.pairs, "groups": len(groups),
                                                "testsSkipped": self.args.skip_tests,
                                                "allSamplesAtLeast50Milliseconds": all(
                                                    min(r["wallNanoseconds"], r["cpuNanoseconds"]) >= 50_000_000
                                                    for r in records)})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=os.environ.get("SWIFT", shutil.which("swift") or "swift"))
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--maximum-iterations", type=int, default=1000)
    parser.add_argument("--maximum-restored-entries", type=int, default=5_000_000,
                        help="Bound timed-iteration fixture restoration; short samples are reported")
    parser.add_argument("--cases", help="Comma-separated timing subset; complete verification still runs")
    parser.add_argument("--ownerships", default="unique,shared")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; full state parity still runs")
    args = parser.parse_args()
    if (args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms)
            or args.target_ms <= 0 or args.maximum_iterations < 1 or args.maximum_restored_entries < 1):
        parser.error("Use even pairs >= 2 and positive finite timing/iteration limits")
    print("Builds use isolated, serial package directories; submit this runner through Kyoto where available.", flush=True)
    experiment = Experiment(args)
    experiment.stage()
    catalog = experiment.build_and_verify()
    if not args.tests_only:
        experiment.measure(catalog)


if __name__ == "__main__":
    main()
