#!/usr/bin/env python3
"""Measure scan-local sidecar cache retention using exact production readers."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
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
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
READER = "MediaSidecarReader.swift"
SOURCE_DIR = Path("Sources/IlliquidCore/MediaLibrary")
SOURCES = ["MediaNameRecognition.swift", "MediaMetadataHints.swift",
           "NFOMetadataHints.swift", "PlexMatchHints.swift", READER]
TESTS = ["MediaSidecarTests.swift", "MediaSidecarPathPlanTests.swift",
         "MediaSidecarNegativeCacheTests.swift", "NFOMetadataFieldSelectionTests.swift",
         "NFOEpisodeScopeRegressionTests.swift", "PlexMatchHintsRegressionTests.swift",
         "PlexMatchReaderRegressionTests.swift"]
HEAP = ROOT / "Benchmarks/RuntimeLeaseHistory/CLeaseHeap"
PRIOR_DRIVER = ROOT / "Benchmarks/SidecarPathPlan/Harness.swift"
MANIFEST = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SidecarNegativeCacheQualification", platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
              .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n")


class Experiment:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.out = args.output.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.evidence = self.out / "evidence"
        self.evidence.mkdir()
        self.build = self.out / "build"
        self.build.mkdir()
        self.env = dict(os.environ)
        for name in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.env[name] = str(self.build / "module-cache")
        swift = shutil.which(args.swift)
        if not swift:
            raise ValueError(f"Swift executable not found: {args.swift}")
        self.swift = swift
        self.swiftc = str(Path(swift).with_name("swiftc"))
        self.clang = str(Path(swift).with_name("clang"))
        self.binaries: dict[str, Path] = {}
        self.parity_binaries: dict[str, Path] = {}
        self.expected: dict[str, dict] = {}

    def command(self, arguments: list, log: str | None = None, timeout: int = 900) -> str:
        argv = [str(value) for value in arguments]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "returncode": result.returncode,
                "elapsed_seconds": time.monotonic() - started, "log": log,
                "stdout_sha256": digest(result.stdout.encode()),
                "stderr_sha256": digest(result.stderr.encode())}) + "\n")
        if log:
            (self.evidence / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n{result.stdout[-8000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def stage(self) -> None:
        baseline = self.command(["git", "rev-parse", f"{self.args.baseline}^{{commit}}"]).strip()
        current = {name: (ROOT / SOURCE_DIR / name).read_bytes() for name in SOURCES}
        old_reader = self.command(["git", "show", f"{baseline}:{SOURCE_DIR / READER}"]).encode()
        if old_reader == current[READER]:
            raise ValueError("Baseline and candidate reader are identical")
        tests = {name: (ROOT / "Tests/IlliquidCoreTests" / name).read_bytes() for name in TESTS}
        harness = (HERE / "Harness.swift").read_bytes()
        parity_harness = PRIOR_DRIVER.read_bytes()
        source_evidence = self.evidence / "sources"
        source_evidence.mkdir()
        for name, raw in {**current, **tests, "Harness.swift": harness,
                          "PriorParityHarness.swift": parity_harness, "run.py": (HERE / "run.py").read_bytes()}.items():
            (source_evidence / name).write_bytes(raw)
        (source_evidence / ("baseline-" + READER)).write_bytes(old_reader)
        support = self.build / "support"
        shutil.copytree(HEAP, support)
        (support / "include/module.modulemap").write_text('module CLeaseHeap { header "CLeaseHeap.h" export * }\n')
        shutil.copyfile(HEAP / "heap.c", source_evidence / "heap.c")
        shutil.copyfile(HEAP / "include/CLeaseHeap.h", source_evidence / "CLeaseHeap.h")
        self.command([self.clang, "-O2", "-I", support / "include", "-c", support / "heap.c",
                      "-o", support / "heap.o"], "build-heap.log")
        manifests = {}
        for variant in ("baseline", "candidate"):
            package = self.build / variant
            production = package / "Sources/IlliquidCore"
            test_dir = package / "Tests/IlliquidCoreTests"
            production.mkdir(parents=True)
            test_dir.mkdir(parents=True)
            (package / "Package.swift").write_text(MANIFEST)
            manifest = {"production": {}, "tests": {}, "manifest_sha256": digest(MANIFEST.encode())}
            for name, shared in current.items():
                original = old_reader if variant == "baseline" and name == READER else shared
                compiled = original
                adaptation = None
                if platform.system() == "Linux":
                    if name == READER:
                        if original.count(b"import Darwin\n") != 1:
                            raise ValueError("Reader POSIX import changed; review Linux adaptation")
                        compiled = original.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        adaptation = "Darwin import -> Glibc"
                    elif name == "NFOMetadataHints.swift":
                        if original.count(b"import Foundation\n") != 1:
                            raise ValueError("Parser Foundation import changed; review Linux adaptation")
                        compiled = original.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        adaptation = "Add FoundationXML import"
                (production / name).write_bytes(compiled)
                manifest["production"][name] = {"original_sha256": digest(original),
                    "compiled_sha256": digest(compiled), "adaptation": adaptation}
            for name, raw in tests.items():
                (test_dir / name).write_bytes(raw)
                manifest["tests"][name] = digest(raw)
            driver = package / "Harness.swift"
            driver.write_bytes(harness)
            parity_driver = package / "PriorParityHarness.swift"
            parity_driver.write_bytes(parity_harness)
            flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library"]
            if platform.system() == "Darwin":
                flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
            binary = package / "sidecar-negative-cache"
            self.command([self.swiftc, *flags, "-I", support / "include",
                          *[production / name for name in SOURCES], driver,
                          support / "heap.o", "-o", binary], f"build-{variant}.log")
            parity_binary = package / "sidecar-parity"
            self.command([self.swiftc, *flags, *[production / name for name in SOURCES],
                          parity_driver, "-o", parity_binary], f"build-{variant}-parity.log")
            manifest["binary_sha256"] = digest(binary.read_bytes())
            manifest["parity_binary_sha256"] = digest(parity_binary.read_bytes())
            manifests[variant] = manifest
            self.binaries[variant] = binary
            self.parity_binaries[variant] = parity_binary
            print(f"Built {variant}", flush=True)
        changed = [name for name in SOURCES
                   if manifests["baseline"]["production"][name] != manifests["candidate"]["production"][name]]
        if changed != [READER]:
            raise ValueError(f"Source isolation failed: {changed}")
        save(self.evidence / "manifest.json", {
            "baseline_commit": baseline,
            "candidate_head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_uses_worktree_source": True,
            "only_changed_production_file": str(SOURCE_DIR / READER),
            "variants": manifests,
            "source_evidence_sha256": {p.name: digest(p.read_bytes()) for p in sorted(source_evidence.iterdir())},
            "allocator_support_provenance": str(HEAP.relative_to(ROOT)),
        })
        environment = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "compiler": self.command([self.swiftc, "--version"]).strip(),
            "flags": flags, "pairs": self.args.pairs, "selected_cases": self.args.cases,
            "tests_requested": not self.args.skip_tests,
            "git_status": self.command(["git", "status", "--short"]),
        }
        if platform.system() == "Darwin":
            environment["os"] = self.command(["sw_vers"]).strip()
            environment["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        save(self.evidence / "environment.json", environment)

    def tests(self) -> None:
        results = {}
        for variant in self.binaries:
            for configuration in ("debug", "release"):
                log = f"{variant}-{configuration}-tests.log"
                self.command([self.swift, "test", "--package-path", self.build / variant,
                              "--configuration", configuration, "--jobs", self.args.jobs,
                              "--no-parallel", "-Xswiftc", "-warnings-as-errors"], log)
                text = (self.evidence / log).read_text()
                counts = re.findall(r"Test run with ([1-9][0-9]*) tests? .* passed", text)
                if not counts:
                    raise ValueError(f"Missing nonempty successful test summary: {log}")
                results[f"{variant}-{configuration}"] = int(counts[-1])
                print(f"{variant} {configuration}: {counts[-1]} tests passed", flush=True)
        save(self.evidence / "tests.json", results)

    def verify(self) -> None:
        self.fixtures = self.build / "fixtures"
        if self.fixtures.exists():
            raise ValueError("Fixture destination must be fresh")
        cases = json.loads(self.command([self.binaries["baseline"], "prepare", self.fixtures], "fixtures.log"))
        candidate_cases = json.loads(self.command([self.binaries["candidate"], "list"]))
        if cases != candidate_cases:
            raise ValueError("Different scenario catalogues")
        selected = set(self.args.cases.split(",")) if self.args.cases else {case["name"] for case in cases}
        if selected - {case["name"] for case in cases}:
            raise ValueError("Unknown scenario selection")
        self.cases = [case for case in cases if case["name"] in selected]
        receipts = []
        for case in self.cases:
            name = case["name"]
            reports = {variant: json.loads(self.command([binary, "verify", self.fixtures, name]))
                       for variant, binary in self.binaries.items()}
            if reports["baseline"] != reports["candidate"]:
                raise ValueError(f"Complete output/filesRead mismatch for {name}")
            report = reports["baseline"]
            expected_reads = {"mixed": case["count"] // 16 + 2,
                              "positive": case["count"] + 2,
                              "malformed": case["count"]}.get(case["style"], 0)
            expected_kind = "extra" if case["style"] == "extras" else "episode"
            if (report["firstReceipt"]["filesRead"] != expected_reads
                or report["secondReceipt"]["filesRead"] != expected_reads
                or len(report["first"]) != case["count"]
                or any(output["kind"] != expected_kind for output in report["first"])):
                raise ValueError(f"Fixture did not exercise intended paths: {name}")
            self.expected[name] = report["firstReceipt"]
            raw = canonical(report)
            (self.evidence / f"parity-{name}.json.gz").write_bytes(gzip.compress(raw, mtime=0))
            receipts.append({"name": name, "outputs_per_pass": len(report["first"]),
                "passes": 2, "canonical_output_sha256": digest(raw), "receipt": self.expected[name]})
            print(f"Verified {name}: {len(report['first']) * 2} complete outputs", flush=True)
        # Reuse all prior path/precedence/Unicode/depth fixtures as an additional
        # oracle. This driver is identical in both variants and is not timed.
        parity_root = self.build / "prior-fixtures"
        self.command([self.parity_binaries["baseline"], "prepare", parity_root])
        old_reports = [json.loads(self.command([binary, "verify", parity_root]))
                       for binary in self.parity_binaries.values()]
        if old_reports[0] != old_reports[1]:
            raise ValueError("Prior path-plan/precedence fixture outputs differ")
        raw = canonical(old_reports[0])
        (self.evidence / "parity-existing-scenarios.json.gz").write_bytes(gzip.compress(raw, mtime=0))
        save(self.evidence / "verification.json", {
            "exact_complete_output_and_files_read_parity": True,
            "memory_scenarios": receipts,
            "existing_scenarios": len(old_reports[0]),
            "existing_complete_outputs": sum(len(row["outputs"]) for row in old_reports[0]),
            "existing_canonical_output_sha256": digest(raw),
            "all_output_fields": ["kind", "title", "year", "season", "episode", "lastEpisode", "airDate",
                "episodeTitle", "edition", "catalogIDs", "variant", "metadataSources", "seriesTitle", "displayName", "section"],
        })

    def measure(self) -> None:
        rows = []
        for case in self.cases:
            name = case["name"]
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for position, variant in enumerate(order):
                    row = json.loads(self.command([self.binaries[variant], "measure", self.fixtures, name]))
                    if (row["scenario"] != name or row["count"] != case["count"]
                        or row["allocatorMetric"] == "unsupported"
                        or any(row[field] <= 0 for field in ("firstWallNS", "firstCPUNS", "secondWallNS", "secondCPUNS"))
                        or row["firstReceipt"] != self.expected[name]
                        or row["secondReceipt"] != self.expected[name]):
                        raise ValueError(f"Unexpected measurement/output receipt for {name}/{variant}")
                    row.update(variant=variant, pair=pair, process_order=position, pair_order=order)
                    rows.append(row)
                    with (self.evidence / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Measured {name}: {self.args.pairs} alternating AB/BA pairs", flush=True)
        results = {}
        fields = ["retainedDeltaBytes", "cachedDeltaBytes", "releasedDeltaBytes",
                  "firstWallNS", "firstCPUNS", "secondWallNS", "secondCPUNS"]
        for case in self.cases:
            name = case["name"]
            cohort = [row for row in rows if row["scenario"] == name]
            result = {"count": case["count"], "style": case["style"], "pairs": self.args.pairs}
            for variant in self.binaries:
                selected = [row for row in cohort if row["variant"] == variant]
                result[variant] = {field: {"median": statistics.median(row[field] for row in selected),
                    "min": min(row[field] for row in selected), "max": max(row[field] for row in selected)}
                    for field in fields}
            result["paired"] = {}
            for field in fields:
                changes = []
                differences = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[field] for row in cohort if row["pair"] == pair}
                    differences.append(values["candidate"] - values["baseline"])
                    if values["baseline"] > 0:
                        changes.append((values["candidate"] / values["baseline"] - 1) * 100)
                result["paired"][field] = {"candidate_minus_baseline": differences,
                    "median_difference": statistics.median(differences), "change_percent": changes,
                    "median_change_percent": statistics.median(changes) if changes else None,
                    "lower_pairs": sum(x < 0 for x in differences)}
            results[name] = result
        save(self.evidence / "summary.json", {
            "metric": rows[0]["allocatorMetric"], "observations": len(rows),
            "method": "Fresh processes, balanced alternating AB/BA order. Inputs prebuilt; small reader warms runtime. Live allocator samples after autorelease pools drain, before reader release and after release. Two scans per reader: filling and cached.",
            "scope": "Additional live allocator-accounted bytes while one scan-local reader is alive. Excludes input URL arrays and output retention. Not process RSS, peak footprint, whole-player RAM, or a leak claim.",
            "timing_scope": "One complete scan including actual sidecar probes/parsing, recognize calls, small result consumer and autorelease drain; excludes fixture/input preparation, full-output verification and JSON. Warm filesystem caches; short controls can be noisy.",
            "workloads": results,
        })


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--cases", help="Comma-separated cases for a separately labelled exploratory run")
    parser.add_argument("--tests-only", action="store_true", help="Run correctness/parity without allocator/timing observations")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; record that regression suites were not run")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive and even (at least 2) for balanced AB/BA order")
    if args.tests_only and args.skip_tests:
        parser.error("--tests-only and --skip-tests conflict")
    study = Experiment(args)
    study.stage()
    if not args.skip_tests:
        study.tests()
    else:
        save(study.evidence / "tests.json", {"status": "skipped for exploration"})
    study.verify()
    if not args.tests_only:
        study.measure()
    save(study.evidence / "completion.json", {
        "completed_utc": datetime.now(timezone.utc).isoformat(),
        "tests_run": not args.skip_tests, "measurements_run": not args.tests_only,
        "selected_cases": args.cases, "pairs": args.pairs,
        "evidence_sha256": {str(path.relative_to(study.evidence)): digest(path.read_bytes())
            for path in sorted(study.evidence.rglob("*")) if path.is_file()},
    })
    print(f"Completed: {study.evidence}", flush=True)


if __name__ == "__main__":
    main()
