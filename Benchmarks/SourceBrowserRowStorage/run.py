#!/usr/bin/env python3
"""Compare real source-browser row storage with exact shared production inputs.

Memory is allocator-accounted live bytes, not player RSS. Timings cover awaited
projection calls after fixture setup. Full output equality is checked separately
for every supported scenario; measured processes emit complete-output checksums.
"""
from __future__ import annotations

import argparse
import difflib
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
FOCAL = "Sources/IlliquidApp/UI/SourceBrowserFilter.swift"
STAGED_FOCAL = "Sources/IlliquidApp/SourceBrowserFilter.swift"
SUPPORT_RUNNER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
TESTS = [
    "SourceBrowserFilterTests.swift", "SourceBrowserSearchTests.swift",
    "SourceTreeVisibilityCacheTests.swift", "SourceEmptyFolderVisibilityTests.swift",
    "SourceMediaOrganizationTests.swift", "SourceBrowserRowStorageTests.swift",
]
ALL_CASES = [
    "tree", "files", "folders", "no_match", "hide_first", "hide_middle", "hide_last",
    "hide_most", "hide_all", "annotate_first", "annotate_middle", "annotate_last",
    "preannotated", "reset_annotations", "search", "media", "cache_hit",
]
DEFAULT_CASES = [
    "tree", "files", "folders", "no_match", "hide_first", "hide_last", "hide_most",
    "annotate_first", "annotate_last", "preannotated", "search", "cache_hit",
]
METRICS = [
    "retained_fixture_delta_bytes", "retained_projection_delta_bytes",
    "loop_wall_nanoseconds", "loop_cpu_nanoseconds", "output_row_capacity",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceBrowserRowStorageQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SourceBrowserRowStorageBenchmark", targets: ["SourceBrowserRowStorageBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .target(name: "CSourceBrowserRowStorage", publicHeadersPath: "include"),
        .executableTarget(name: "SourceBrowserRowStorageBenchmark",
            dependencies: ["IlliquidCore", "IlliquidApp", "CSourceBrowserRowStorage"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ], swiftLanguageModes: [.v6]
)
'''


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_support():
    spec = importlib.util.spec_from_file_location("source_tree_visibility_support", SUPPORT_RUNNER)
    if spec is None or spec.loader is None:
        raise ValueError("Cannot load the source-tree snapshot helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def visibility_partition(raw: bytes) -> tuple[bytes, bytes, bytes]:
    start = b"    private func visibility(\n"
    end = b"\n    private static func organizeMedia("
    if raw.count(start) != 1 or raw.count(end) != 1:
        raise ValueError("Visibility method extraction boundaries changed")
    begin, finish = raw.index(start), raw.index(end)
    if finish <= begin:
        raise ValueError("Reversed visibility method boundaries")
    return raw[:begin], raw[begin:finish], raw[finish:]


def add_excerpt(files, records, read_source, repository_path, name, start, end=None):
    raw = read_source(repository_path)
    source = raw.decode()
    if source.count(start) != 1 or (end is not None and source.count(end) != 1):
        raise ValueError(f"Ambiguous extra extraction boundary: {repository_path}")
    begin = source.index(start)
    finish = source.index(end) if end is not None else len(source)
    if finish <= begin:
        raise ValueError(f"Reversed extra extraction boundary: {repository_path}")
    section = source[begin:finish]
    staged = ("import Foundation\nimport IlliquidCore\n\n" + section + "\n").encode()
    destination = "Sources/IlliquidApp/" + name
    files[destination] = staged
    records[destination] = {
        "repository_path": repository_path, "source_sha256": sha(raw),
        "git_blob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
        "snapshot_sha256": sha(staged),
        "excerpts": [{"start": start, "end": end or "EOF", "sha256": sha(section.encode())}],
    }


def adapt(relative: str, raw: bytes) -> tuple[bytes, list[str]]:
    changes = []
    if platform.system() != "Linux":
        return raw, changes
    replacements = []
    if relative.endswith("/MediaSidecarReader.swift"):
        replacements = [(b"import Darwin\n", b"import Glibc\n", "Darwin import -> Glibc")]
    elif relative.endswith("/NFOMetadataHints.swift"):
        replacements = [(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", "add FoundationXML import")]
    elif relative.endswith("/SourceMediaOrganizationTests.swift"):
        replacements = [(b'appendingPathComponent("media-sidecars-" + UUID().uuidString)',
                         b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)',
                         "explicit directory hint for legacy sidecarsReachRowsForFoldersAndExplicitFiles fixture")]
    for old, new, description in replacements:
        if raw.count(old) != 1:
            raise ValueError(f"Platform adaptation boundary changed: {relative}: {description}")
        raw = raw.replace(old, new, 1)
        changes.append(description)
    return raw, changes


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory; existing evidence is not overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = args.swift or shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH, or supply --swift /absolute/path/to/swift")
        self.env = os.environ.copy()
        cache = str(self.output / "module-cache")
        self.env.update(CLANG_MODULE_CACHE_PATH=cache, SWIFT_MODULECACHE_PATH=cache,
                        SWIFTPM_MODULECACHE_OVERRIDE=cache, TERM="dumb", NO_COLOR="1")
        self.originals, self.manifests, self.packages, self.binaries = {}, {}, {}, {}

    def execute(self, arguments, label, allowed=(0,), timeout=900):
        arguments = [str(item) for item in arguments]
        started = time.monotonic()
        result = subprocess.run(arguments, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        record = {"label": label, "arguments": arguments, "returncode": result.returncode,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout": result.stdout, "stderr": result.stderr}
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode})\n" + (result.stdout + result.stderr)[-14000:])
        return result

    def read_current(self, relative):
        if relative not in self.originals:
            self.originals[relative] = (ROOT / relative).read_bytes()
        return self.originals[relative]

    def prepare(self):
        support = load_support()
        self.read_current(str(SUPPORT_RUNNER.relative_to(ROOT)))
        head = self.execute(["git", "rev-parse", "HEAD"], "candidate-revision").stdout.strip()
        baseline = self.execute(["git", "rev-parse", f"{BASELINE}^{{commit}}"], "baseline-revision").stdout.strip()
        if baseline != BASELINE:
            raise ValueError("Unexpected baseline revision")
        baseline_filter = self.execute(["git", "show", f"{BASELINE}:{FOCAL}"], "baseline-filter").stdout.encode()
        baseline_blob = self.execute(["git", "rev-parse", f"{BASELINE}:{FOCAL}"], "baseline-filter-blob").stdout.strip()
        if hashlib.sha1(b"blob " + str(len(baseline_filter)).encode() + b"\0" + baseline_filter).hexdigest() != baseline_blob:
            raise ValueError("Decoded baseline bytes do not match the pinned Git blob")
        candidate_filter = self.read_current(FOCAL)
        before = visibility_partition(baseline_filter)
        after = visibility_partition(candidate_filter)
        if before[0] != after[0] or before[2] != after[2]:
            raise ValueError("Production comparison changes code outside visibility(); requalify the comparison scope")
        if before[1] == after[1]:
            raise ValueError("Baseline and candidate visibility implementations are identical")
        difference = "".join(difflib.unified_diff(baseline_filter.decode().splitlines(True),
                                                 candidate_filter.decode().splitlines(True),
                                                 fromfile=BASELINE + "/" + FOCAL,
                                                 tofile="working-tree/" + FOCAL))
        (self.output / "production.diff").write_text(difference)

        def read_baseline(relative):
            return baseline_filter if relative == FOCAL else self.read_current(relative)

        snapshots = {}
        for variant, read in [("baseline", read_baseline), ("candidate", self.read_current)]:
            files, records = support.snapshot(read)
            add_excerpt(files, records, read, "Sources/IlliquidApp/UI/SourcesSidebar.swift", "DirectoryValues.swift",
                        "struct SourceDirectoryListing:", "\nenum SourceRecursiveMediaLoader {")
            add_excerpt(files, records, read, "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift", "PresenceCursor.swift",
                        "final class SourceMediaPresenceCursor:")
            snapshots[variant] = (files, records)
        baseline_files, baseline_records, candidate_records, comparison = support.comparison_sources(
            *snapshots["baseline"], *snapshots["candidate"], focal_sources={STAGED_FOCAL},
            baseline_revision=BASELINE, worktree_head=head, current_support=True,
        )
        candidate_files = snapshots["candidate"][0]
        unequal = [name for name in candidate_files if candidate_files[name] != baseline_files[name]]
        if unequal != [STAGED_FOCAL]:
            raise ValueError(f"Only the focal production filter may differ: {unequal}")
        comparison.update(visibility_only_diff=True, shared_production_file_count=len(candidate_files) - 1,
                          production_diff_sha256=sha(difference.encode()))
        harness = {
            "Sources/SourceBrowserRowStorageBenchmark/Harness.swift": self.read_current("Benchmarks/SourceBrowserRowStorage/Harness.swift"),
            "Sources/CSourceBrowserRowStorage/heap.c": self.read_current("Benchmarks/SourceBrowserRowStorage/CSourceBrowserRowStorage/heap.c"),
            "Sources/CSourceBrowserRowStorage/include/CSourceBrowserRowStorage.h": self.read_current("Benchmarks/SourceBrowserRowStorage/CSourceBrowserRowStorage/include/CSourceBrowserRowStorage.h"),
            "Package.swift": PACKAGE.encode(),
        }
        for name in TESTS:
            path = "Tests/IlliquidAppTests/" + name
            harness[path] = self.read_current(path)
        self.read_current(str(Path(__file__).resolve().relative_to(ROOT)))
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            package = self.output / "packages" / variant
            manifest = {"variant": variant, "comparison": comparison, "production": records,
                        "staged": {}, "adaptations": []}
            for relative, raw in {**files, **harness}.items():
                compiled, adaptations = adapt(relative, raw)
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(compiled)
                manifest["staged"][relative] = {"source_sha256": sha(raw), "compiled_sha256": sha(compiled)}
                if adaptations:
                    manifest["adaptations"].append({"file": relative, "changes": adaptations})
            self.packages[variant], self.manifests[variant] = package, manifest
            save(self.output / f"{variant}-sources.json", manifest)
        # This second gate covers platform adaptations, tests, helper code, and
        # the package manifest, not only the original production snapshots.
        for path, record in self.manifests["candidate"]["staged"].items():
            if path != STAGED_FOCAL and record != self.manifests["baseline"]["staged"][path]:
                raise ValueError(f"Unequal staged support input: {path}")
        save(self.output / "environment.json", {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
            "compiler": self.execute([self.swift, "--version"], "compiler-version").stdout.strip(),
            "candidate_head": head, "baseline": baseline, "comparison": comparison,
            "pid_namespace": {"pid": os.getpid(), "proc_self": os.readlink("/proc/self")}
                if Path("/proc/self").exists() else None,
            "candidate_source_identity": "working-tree hashes; HEAD is the checkout ancestor, not an assertion of a clean tree",
            "worktree": self.execute(["git", "status", "--short"], "worktree").stdout,
            "original_source_hashes": {path: sha(raw) for path, raw in sorted(self.originals.items())},
            "pairs": self.args.pairs, "sizes": self.args.sizes, "cases": self.args.cases,
            "iterations": self.args.iterations, "tests_only": self.args.tests_only,
            "skip_tests": self.args.skip_tests, "exploratory": self.args.smoke,
            "full_semantic_comparison": {"cases": ALL_CASES, "count": 257},
            "measurement": "retained allocator bytes after projection while fixture, actor cache, and result are live; not RSS",
            "timing": "awaited project calls only; fixture setup, actor recreation, and diagnostics excluded",
            "ordering": "alternating AB/BA, one fresh process per variant per pair",
            "cache_hit_control": "cache is primed before the projection baseline; fixture delta includes that cache",
        })
        self.check_sources()

    def check_sources(self):
        for path, raw in self.originals.items():
            if (ROOT / path).read_bytes() != raw:
                raise ValueError(f"Source changed during qualification: {path}")
        for variant, manifest in self.manifests.items():
            for path, record in manifest["staged"].items():
                if sha((self.packages[variant] / path).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{path}")
            if variant in self.binaries and sha(self.binaries[variant].read_bytes()) != manifest["binary_sha256"]:
                raise ValueError(f"Benchmark binary changed: {variant}")

    def swift_command(self, variant, operation, configuration):
        command = [self.swift, operation, "--package-path", self.packages[variant],
                   "--scratch-path", self.output / "build" / variant,
                   "--cache-path", self.output / "swiftpm-cache", "--config-path", self.output / "swiftpm-config",
                   "--security-path", self.output / "swiftpm-security", "--jobs", self.args.jobs,
                   "--configuration", configuration, "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def test(self):
        records = []
        inventory = None
        for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
            self.check_sources()
            print(f"Test {variant} {configuration}", flush=True)
            arguments = self.swift_command(variant, "test", configuration) + [
                "--disable-xctest", "--enable-swift-testing", "--no-parallel"]
            if variant == "baseline":
                # Swift Testing also matches source filenames. The suite/method
                # boundary avoids excluding semantic tests in the same file.
                arguments += ["--skip", r"\.SourceBrowserRowStorageTests/"]
            result = self.execute(arguments, f"tests-{variant}-{configuration}")
            log = result.stdout + result.stderr
            (self.output / f"tests-{variant}-{configuration}.log").write_text(log)
            counts = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", log)
            if not counts or int(counts[-1]) == 0:
                raise ValueError(f"No passing Swift Testing run found: {variant}/{configuration}")
            if "Test hiddenExclusionPreservesThePrefixAndSuffix(index:) started." not in log:
                raise ValueError(f"New semantic tests did not execute: {variant}/{configuration}")
            listed = self.execute(self.swift_command(variant, "test", configuration) + ["--skip-build", "list"],
                                  f"test-inventory-{variant}-{configuration}").stdout
            identifiers = sorted(line for line in listed.splitlines() if line.startswith("IlliquidAppTests."))
            if inventory is None:
                inventory = identifiers
            elif identifiers != inventory:
                raise ValueError("Baseline and candidate test identifiers differ")
            expected = [name for name in identifiers
                        if variant != "baseline" or ".SourceBrowserRowStorageTests/" not in name]
            if not any(".SourceBrowserRowSemanticsTests/" in name for name in expected) or int(counts[-1]) != len(expected):
                raise ValueError(f"Reported test count disagrees with the observed test-ID selection: {variant}/{configuration}")
            records.append({"variant": variant, "configuration": configuration, "passed": True,
                            "reported_tests": int(counts[-1]),
                            "skip": r"\.SourceBrowserRowStorageTests/" if variant == "baseline" else None})
        if self.args.prove_baseline_failure:
            arguments = self.swift_command("baseline", "test", "release") + [
                "--disable-xctest", "--enable-swift-testing", "--no-parallel", "--filter", r"\.SourceBrowserRowStorageTests/"]
            result = self.execute(arguments, "baseline-storage-regression", allowed=(1,))
            log = result.stdout + result.stderr
            (self.output / "expected-baseline-storage-failure.log").write_text(log)
            if "SourceBrowserRowStorageTests" not in log or "Expectation failed" not in log:
                raise ValueError("Baseline storage failure did not reach the expected assertions")
            if "Test hiddenExclusionPreservesThePrefixAndSuffix(index:) started." in log:
                raise ValueError("Baseline storage-failure filter also selected semantic tests")
            records.append({"variant": "baseline", "expected_storage_regression": True, "returncode": 1})
        save(self.output / "tests.json", {"suites": TESTS, "observed_test_identifiers": inventory, "runs": records})

    def build(self):
        for variant in ["baseline", "candidate"]:
            print(f"Build {variant} optimized benchmark", flush=True)
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "SourceBrowserRowStorageBenchmark"], f"build-{variant}")
            directory = self.execute(command + ["--show-bin-path"], f"binary-path-{variant}").stdout.strip()
            self.binaries[variant] = Path(directory) / "SourceBrowserRowStorageBenchmark"
            self.manifests[variant]["binary_sha256"] = sha(self.binaries[variant].read_bytes())
            save(self.output / f"{variant}-sources.json", self.manifests[variant])
        self.check_sources()

    def observe(self, variant, scenario, count, iterations, label, semantic_path=None):
        command = [self.binaries[variant], "--case", scenario, "--count", count, "--iterations", iterations]
        if semantic_path is not None:
            command += ["--semantic-output", semantic_path]
        data = json.loads(self.execute(command, label).stdout)
        if (data.get("schema"), data.get("mode"), data.get("scenario"), data.get("count"), data.get("iterations")) != (1, "measure", scenario, count, iterations):
            raise ValueError(f"Unexpected benchmark response: {label}")
        if data["allocator_metric"] == "unsupported" or type(data["shares_input_storage"]) is not bool:
            raise ValueError(f"Unsupported allocation/storage evidence: {label}")
        for metric in METRICS:
            if type(data[metric]) is not int:
                raise ValueError(f"Noninteger measurement: {label}: {metric}")
        if min(data["loop_wall_nanoseconds"], data["loop_cpu_nanoseconds"]) <= 0:
            raise ValueError(f"Missing timing measurement: {label}")
        for kind in ["fixture", "projection"]:
            if data[f"retained_{kind}_delta_bytes"] != data["allocator_after_projection_bytes"] - data[f"allocator_before_{kind}_bytes"]:
                raise ValueError(f"Inconsistent allocation delta: {label}")
        return data

    def verify_semantics(self):
        receipts = []
        directory = self.output / "semantic-output"
        directory.mkdir()
        for scenario in ALL_CASES:
            observed, contents = {}, {}
            for variant in ["baseline", "candidate"]:
                destination = directory / f"{scenario}-{variant}.json"
                observed[variant] = self.observe(variant, scenario, 257, 1, f"verify-{variant}-{scenario}", destination)
                contents[variant] = destination.read_bytes()
                checksum = 14_695_981_039_346_656_037
                for byte in contents[variant]:
                    checksum = ((checksum ^ byte) * 1_099_511_628_211) & ((1 << 64) - 1)
                checks = observed[variant]["checks"]
                if checks["semantic_byte_count"] != len(contents[variant]) or checks["semantic_fnv1a64"] != str(checksum):
                    raise ValueError(f"Full semantic output disagrees with its observation: {scenario}/{variant}")
                destination.unlink()
            if contents["baseline"] != contents["candidate"] or observed["baseline"]["checks"] != observed["candidate"]["checks"]:
                raise ValueError(f"Complete semantic output differs: {scenario}")
            (directory / f"{scenario}.json.gz").write_bytes(gzip.compress(contents["baseline"], mtime=0))
            receipts.append({"case": scenario, "count": 257, "complete_bytes_equal": True,
                             "byte_count": len(contents["baseline"]), "sha256": sha(contents["baseline"]),
                             "checks": observed["baseline"]["checks"]})
        save(self.output / "parity.json", {"method": "complete canonical JSON byte equality; every row/projection field",
                                          "cases": receipts})
        print(f"Complete semantic output parity passed for {len(receipts)} cases", flush=True)

    def measure(self):
        if platform.system() == "Linux" and Path("/proc/self").exists() and os.readlink("/proc/self") != str(os.getpid()):
            raise ValueError("Inconsistent Linux PID namespace: libdispatch worker-monitor failures invalidate measurements")
        rows, summaries = [], []
        for count in self.args.sizes:
            for scenario in self.args.cases:
                expected_checks = None
                group = {"baseline": [], "candidate": []}
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    for position, variant in enumerate(order):
                        data = self.observe(variant, scenario, count, self.args.iterations,
                                            f"measure-{variant}-{scenario}-{count}-{pair}")
                        if expected_checks is None:
                            expected_checks = data["checks"]
                        elif data["checks"] != expected_checks:
                            raise ValueError(f"Measured output differs: {scenario}/{count}/{pair}/{variant}")
                        data.update(variant=variant, pair=pair, process_order=position)
                        group[variant].append(data)
                        rows.append(data)
                        with (self.output / "observations.jsonl").open("a") as stream:
                            stream.write(json.dumps(data, sort_keys=True) + "\n")
                metrics = {}
                for metric in METRICS:
                    baseline = [row[metric] for row in group["baseline"]]
                    candidate = [row[metric] for row in group["candidate"]]
                    ratios = [c / b for b, c in zip(baseline, candidate)] if all(b > 0 for b in baseline) else []
                    metrics[metric] = {
                        "baseline_median": statistics.median(baseline), "candidate_median": statistics.median(candidate),
                        "baseline_range": [min(baseline), max(baseline)], "candidate_range": [min(candidate), max(candidate)],
                        "median_paired_change": statistics.median(c - b for b, c in zip(baseline, candidate)),
                        "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)) if ratios else None,
                    }
                summaries.append({"case": scenario, "count": count, "pairs": self.args.pairs,
                                  "iterations_per_process": self.args.iterations, "metrics": metrics,
                                  "shared_input_storage_observations": {v: sum(row["shares_input_storage"] for row in group[v]) for v in group},
                                  "checks": expected_checks})
                save(self.output / "summary.json", summaries)
                print(f"Measured {scenario}, {count} rows, {self.args.pairs} balanced pairs", flush=True)
        self.check_sources()
        save(self.output / "completion.json", {"passed": True, "paired_output_checks": len(rows) // 2,
                                               "observations": len(rows), "source_and_binary_hashes_rechecked": True})

    def export_evidence(self):
        evidence = self.output / "evidence"
        evidence.mkdir(exist_ok=True)
        for source in self.output.iterdir():
            if source.is_file() and source.suffix in {".json", ".jsonl", ".log", ".txt", ".diff"}:
                shutil.copyfile(source, evidence / source.name)
        semantic = self.output / "semantic-output"
        if semantic.exists():
            shutil.copytree(semantic, evidence / "semantic-output", dirs_exist_ok=True)
        with tarfile.open(evidence / "staged-sources.tar.gz", "w:gz") as archive:
            for variant, package in self.packages.items():
                for path in sorted(package.rglob("*")):
                    if path.is_file():
                        archive.add(path, arcname=f"{variant}/{path.relative_to(package)}", recursive=False)
            for path in [Path(__file__).resolve(), SUPPORT_RUNNER]:
                archive.add(path, arcname=f"drivers/{path.relative_to(ROOT)}", recursive=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1_000, 10_000, 100_000])
    parser.add_argument("--case", dest="cases", action="append", choices=ALL_CASES)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; final evidence must include tests")
    parser.add_argument("--prove-baseline-failure", action="store_true")
    parser.add_argument("--smoke", action="store_true", help="Allow fewer/unbalanced pairs; results are exploratory")
    args = parser.parse_args()
    args.cases = args.cases or DEFAULT_CASES
    if args.jobs < 1 or args.iterations < 1 or args.iterations > 10_000:
        parser.error("Use positive jobs and 1...10000 iterations")
    if args.pairs < 1 or (not args.smoke and (args.pairs < 6 or args.pairs % 2)):
        parser.error("Use an even number of at least six pairs; --smoke permits an exploratory run")
    if any(count < 1 or count > 1_000_000 for count in args.sizes) or len(set(args.sizes)) != len(args.sizes):
        parser.error("Sizes must be distinct values from 1...1000000")
    if len(set(args.cases)) != len(args.cases):
        parser.error("Cases must not repeat")
    if args.skip_tests and (not args.smoke or args.tests_only or args.prove_baseline_failure):
        parser.error("--skip-tests requires --smoke and cannot accompany test-only or baseline-proof options")
    runner = Runner(args)
    try:
        runner.prepare()
        if not args.skip_tests:
            runner.test()
        runner.build()
        runner.verify_semantics()
        if not args.tests_only:
            runner.measure()
        else:
            runner.check_sources()
            save(runner.output / "completion.json", {"passed": True, "tests_only": True,
                                                      "complete_output_comparisons": len(ALL_CASES),
                                                      "source_and_binary_hashes_rechecked": True})
    finally:
        runner.export_evidence()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Source-browser row-storage qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
