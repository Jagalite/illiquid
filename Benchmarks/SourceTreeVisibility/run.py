#!/usr/bin/env python3
"""Qualify real source-tree projection sources in a small, offline Swift package.

The macOS sources are unchanged copies or guarded verbatim declarations. Linux
adapts POSIX/XML imports and one legacy test fixture's directory URL hint.
Fixtures, cache diagnostics, checksums and compilation are outside projection timings.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "33fff16155c3472960f88e04c72dfdfdefd56dcf"
CORE = [
    "Utilities/NormalizedFileURL.swift", "Utilities/MediaFileSupport.swift",
    "Utilities/SourcePreparationExecutor.swift", "MediaLibrary/MediaNameRecognition.swift",
    "MediaLibrary/MediaMetadataHints.swift", "MediaLibrary/NFOMetadataHints.swift",
    "MediaLibrary/PlexMatchHints.swift", "MediaLibrary/MediaSidecarReader.swift",
]
APP = ["UI/SourceBrowserFilter.swift", "UI/SourceTreeProjectionInput.swift"]
EXCERPTS = {
    "AppValues.swift": ("App/AppModel.swift", [
        ("struct SourceTabItem:", "\nenum SourceTabStore {"),
    ]),
    "SidebarValues.swift": ("UI/SourcesSidebar.swift", [
        ("struct SourceTreeEntry:", "\nstruct SourceDirectoryListing:"),
        ("enum SourceRecursiveMediaLoader {", "\nstruct SourceTreeDisplayRow:"),
        ("struct SourceTreeDisplayRow:", "\nstruct SourcesSidebarExpansionSnapshot:"),
    ]),
}
TESTS = ["SourceBrowserFilterTests.swift", "SourceMediaOrganizationTests.swift",
         "SourceTreeVisibilityCacheTests.swift"]
CASES = ["tree_rules", "tree_show_hidden", "tree_manual_hide", "tree_always_show",
         "files_rules", "media_rules", "same_input_search", "preview_only",
         "cold_tree", "changed_sort"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceTreeVisibilityQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SourceTreeBenchmark", targets: ["SourceTreeBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        // The driver needs internal APIs; tests never link its @main entry point.
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "SourceTreeBenchmark", dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def snapshot(read_source) -> tuple[dict[str, bytes], dict]:
    """Read each production file once; hash exactly the bytes used for staging."""
    files, records = {}, {}
    for relative in CORE + APP:
        module = "IlliquidCore" if relative in CORE else "IlliquidApp"
        original = f"Sources/{module}/{relative}"
        raw = read_source(original)
        name = f"Sources/{module}/{Path(relative).name}"
        files[name] = raw
        records[name] = {"repository_path": original, "source_sha256": digest(raw),
                         "git_blob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
                         "snapshot_sha256": digest(raw), "excerpts": []}
    for name, (relative, anchors) in EXCERPTS.items():
        original = "Sources/IlliquidApp/" + relative
        raw = read_source(original)
        source = raw.decode()
        sections = []
        for start, end in anchors:
            if source.count(start) != 1 or source.count(end) != 1:
                raise ValueError(f"Ambiguous or missing extraction boundary: {original}: {start!r}/{end!r}")
            begin, finish = source.index(start), source.index(end)
            if finish <= begin:
                raise ValueError(f"Reversed extraction boundary: {original}")
            sections.append(source[begin:finish])
        staged = ("import Foundation\nimport IlliquidCore\n\n" + "\n\n".join(sections) + "\n").encode()
        destination = "Sources/IlliquidApp/" + name
        files[destination] = staged
        records[destination] = {"repository_path": original, "source_sha256": digest(raw),
                               "git_blob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
                               "snapshot_sha256": digest(staged),
                               "excerpts": [{"start": a, "end": b, "sha256": digest(s.encode())}
                                            for (a, b), s in zip(anchors, sections)]}
    return files, records


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty; previous evidence is not overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        cache = self.output / "module-cache"
        cache.mkdir()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
        self.swift = args.swift or shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH, or supply --swift /path/to/swift")
        self.driver_hashes = {name: digest((HERE / name).read_bytes()) for name in ["run.py", "Harness.swift"]}
        self.packages, self.manifests, self.binaries = {}, {}, {}
        shutil.copyfile(HERE / "run.py", self.output / "runner.py")

    def execute(self, command, label: str, timeout: int = 600, allowed=(0,)) -> subprocess.CompletedProcess:
        command = [str(x) for x in command]
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        record = {"label": label, "command": command, "returncode": result.returncode,
                  "elapsed_seconds": time.monotonic() - started, "stdout": result.stdout, "stderr": result.stderr}
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode}): {' '.join(command)}\n"
                               + (result.stdout + result.stderr)[-12000:])
        return result

    def prepare(self):
        baseline = json.loads((HERE / "baseline/manifest.json").read_text())
        if baseline["revision"] != BASELINE:
            raise ValueError("Unexpected baseline revision")
        baseline_files = {}
        for relative, record in baseline["files"].items():
            raw = (HERE / "baseline" / relative).read_bytes()
            if digest(raw) != record["snapshot_sha256"]:
                raise ValueError(f"Retained baseline changed: {relative}")
            baseline_files[relative] = raw
        candidate_files, candidate_records = snapshot(lambda name: (ROOT / name).read_bytes())
        for relative, raw in candidate_files.items():
            if Path(relative).name not in {"SourceBrowserFilter.swift", "SourceTreeProjectionInput.swift"}:
                if raw != baseline_files[relative]:
                    raise ValueError(f"Unrelated staged production dependency changed: {relative}")
        for variant, files, records in [("baseline", baseline_files, baseline["files"]),
                                        ("candidate", candidate_files, candidate_records)]:
            package = self.output / "packages" / variant
            manifest = {"variant": variant, "baseline_revision": BASELINE, "production": records,
                        "staged": {}, "adaptations": []}
            staging = dict(files)
            staging["Sources/SourceTreeBenchmark/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            for name in TESTS:
                staging["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            staging["Package.swift"] = PACKAGE.encode()
            for relative, raw in staging.items():
                adapted = raw
                changes = []
                if platform.system() == "Linux":
                    if relative.endswith("/MediaSidecarReader.swift"):
                        if raw.count(b"import Darwin\n") != 1:
                            raise ValueError("POSIX import boundary changed")
                        adapted = raw.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        changes.append("Darwin import -> Glibc")
                    elif relative.endswith("/NFOMetadataHints.swift"):
                        if raw.count(b"import Foundation\n") != 1:
                            raise ValueError("XML import boundary changed")
                        adapted = raw.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        changes.append("add FoundationXML import")
                    elif relative.endswith("/SourceMediaOrganizationTests.swift"):
                        original = b'appendingPathComponent("media-sidecars-" + UUID().uuidString)'
                        replacement = b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'
                        if raw.count(original) != 1:
                            raise ValueError("Legacy sidecar fixture directory boundary changed")
                        # This root is constructed before the directory exists.
                        # Corelibs retains its missing directory hint, unlike the
                        # file's parent URL, so the reader's root URL equality
                        # fails despite equal paths. Keep production untouched.
                        adapted = raw.replace(original, replacement, 1)
                        changes.append("explicit directory hint for sidecarsReachRowsForFoldersAndExplicitFiles fixture root")
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(adapted)
                manifest["staged"][relative] = {"source_sha256": digest(raw), "compiled_sha256": digest(adapted)}
                if changes:
                    manifest["adaptations"].append({"file": relative, "changes": changes})
            self.packages[variant], self.manifests[variant] = package, manifest
            write_json(self.output / f"{variant}-sources.json", manifest)
        environment = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
            "swift": self.execute([self.swift, "--version"], "swift-version").stdout.strip(),
            "head": self.execute(["git", "rev-parse", "HEAD"], "revision").stdout.strip(),
            "worktree": self.execute(["git", "status", "--short"], "worktree").stdout,
            "baseline": BASELINE, "driver_hashes": self.driver_hashes,
            "sizes": self.args.sizes, "cases": self.args.cases, "pairs": self.args.pairs,
            "exploratory": self.args.smoke,
            "measurement": "DispatchTime uptime nanoseconds around each awaited actor.project call; fixture setup, receipt calculation and diagnostics excluded",
            "fixtures": "Synthetic lexical local URLs; one wide folder; metadata recognition prepopulated outside timing; no filesystem I/O in measured work",
            "ordering": "AB, BA alternating per case and size; fresh process for every member",
            "cold_definition": "Fresh SourceBrowserFilter instance; process and input fixture already initialized",
            "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        }
        if Path("/proc/cpuinfo").exists():
            environment["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
        write_json(self.output / "environment.json", environment)

    def check_sources(self):
        for name, expected in self.driver_hashes.items():
            if digest((HERE / name).read_bytes()) != expected:
                raise ValueError(f"Harness changed during the run: {name}")
        for variant, manifest in self.manifests.items():
            for relative, record in manifest["staged"].items():
                if digest((self.packages[variant] / relative).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{relative}")

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.packages[variant],
                   "--scratch-path", self.output / "build" / variant,
                   "--cache-path", self.output / "swiftpm-cache", "--config-path", self.output / "swiftpm-config",
                   "--security-path", self.output / "swiftpm-security", "--jobs", str(self.args.jobs),
                   "--configuration", configuration]
        # The standalone Linux driver probes child PIDs through /proc; the
        # integrated driver avoids that fragile path in restricted namespaces.
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def test(self):
        records = []
        for configuration in self.args.configurations:
            for variant in ["baseline", "candidate"]:
                self.check_sources()
                print(f"Testing {variant} ({configuration})", flush=True)
                command = self.swift_command(variant, "test", configuration) + [
                    "--disable-xctest", "--enable-swift-testing", "--no-parallel"]
                if variant == "baseline":
                    command += ["--skip", "reuseTreeAcrossVisibilityChanges"]
                if self.args.test_filter:
                    command += ["--filter", self.args.test_filter]
                result = self.execute(command, f"tests-{variant}-{configuration}")
                (self.output / f"tests-{variant}-{configuration}.txt").write_text(result.stdout + result.stderr)
                records.append({"variant": variant, "configuration": configuration, "passed": True,
                                "filter": self.args.test_filter,
                                "skip": "reuseTreeAcrossVisibilityChanges" if variant == "baseline" else None})
        if self.args.prove_baseline_failure:
            command = self.swift_command("baseline", "test", self.args.configurations[0]) + [
                "--disable-xctest", "--enable-swift-testing", "--no-parallel",
                "--filter", "reuseTreeAcrossVisibilityChanges"]
            result = self.execute(command, "expected-baseline-cache-failure", allowed=(1,))
            text = result.stdout + result.stderr
            if "treeBuildCount" not in text or "failed" not in text:
                raise ValueError("Expected baseline failure did not identify the cache count assertion")
            (self.output / "expected-baseline-cache-failure.txt").write_text(text)
            records.append({"variant": "baseline", "expected_cache_count_failure": True, "returncode": 1})
        write_json(self.output / "tests.json", {"suites": TESTS, "runs": records})
        self.check_sources()

    def build(self):
        for variant in ["baseline", "candidate"]:
            print(f"Building {variant} benchmark (release)", flush=True)
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "SourceTreeBenchmark"], f"build-{variant}")
            bin_path = self.execute(command + ["--show-bin-path"], f"bin-path-{variant}").stdout.strip()
            self.binaries[variant] = Path(bin_path) / "SourceTreeBenchmark"
            self.manifests[variant]["binary_sha256"] = digest(self.binaries[variant].read_bytes())
            write_json(self.output / f"{variant}-sources.json", self.manifests[variant])
        self.check_sources()

    def measure(self):
        rows = []
        expected = {}
        for size in self.args.sizes:
            for case in self.args.cases:
                iterations = self.args.iterations or {100: 12, 1000: 6, 10000: 2, 100000: 2}[size]
                if self.args.iterations is None and case in {"same_input_search", "preview_only"}:
                    # These controls avoid tree construction in both variants.
                    # Accumulate more calls so their process average is not
                    # dominated by a handful of sub-millisecond observations.
                    iterations = max(iterations, {100: 100, 1000: 24, 10000: 4, 100000: 2}[size])
                for variant in ["baseline", "candidate"]:
                    result = self.execute([self.binaries[variant], "diagnose", case, size, 2],
                                          f"diagnose-{variant}-{case}-{size}")
                    data = json.loads(result.stdout)
                    key = (case, size, "diagnostic")
                    if key in expected and data["receipts"] != expected[key]:
                        raise ValueError(f"Diagnostic projection differs: {case}/{size}")
                    expected[key] = data["receipts"]
                    data.update(variant=variant)
                    with (self.output / "diagnostics.jsonl").open("a") as log:
                        log.write(json.dumps(data, sort_keys=True) + "\n")
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    for position, variant in enumerate(order):
                        result = self.execute([self.binaries[variant], "measure", case, size, iterations],
                                              f"measure-{variant}-{case}-{size}-{pair}")
                        data = json.loads(result.stdout)
                        if (data["case"], data["size"], data["iterations"]) != (case, size, iterations):
                            raise ValueError("Unexpected timed workload")
                        if len(data["durations_ns"]) != iterations or any(
                            type(n) is not int or n < 0 for n in data["durations_ns"]):
                            raise ValueError("Invalid projection durations")
                        if data["elapsed_ns"] != sum(data["durations_ns"]):
                            raise ValueError("Inconsistent projection duration total")
                        key = (case, size, "measurement")
                        if key in expected and data["receipts"] != expected[key]:
                            raise ValueError(f"Timed projection differs: {case}/{size}")
                        expected[key] = data["receipts"]
                        data.update(variant=variant, pair=pair, process_order=position)
                        rows.append(data)
                        with (self.output / "measurements.jsonl").open("a") as log:
                            log.write(json.dumps(data, sort_keys=True) + "\n")
                print(f"Measured {case}, {size} files, {self.args.pairs} pairs", flush=True)
        groups = collections.defaultdict(dict)
        for row in rows:
            groups[(row["case"], row["size"])].setdefault(row["variant"], []).append(
                row["elapsed_ns"] / row["iterations"])
        summary = []
        for (case, size), variants in groups.items():
            baseline, candidate = variants["baseline"], variants["candidate"]
            summary.append({"case": case, "size": size, "pairs": len(baseline),
                            "baseline_ns": {"median": statistics.median(baseline), "min": min(baseline), "max": max(baseline)},
                            "candidate_ns": {"median": statistics.median(candidate), "min": min(candidate), "max": max(candidate)},
                            "median_paired_candidate_over_baseline": statistics.median(c / b for b, c in zip(baseline, candidate)),
                            "median_paired_reduction_percent": 100 * (1 - statistics.median(c / b for b, c in zip(baseline, candidate)))})
        write_json(self.output / "summary.json", summary)
        self.check_sources()
        for variant, binary in self.binaries.items():
            if digest(binary.read_bytes()) != self.manifests[variant]["binary_sha256"]:
                raise ValueError(f"Benchmark binary changed: {variant}")

    def export_evidence(self):
        """Keep an uploadable receipt without compiler caches or build products."""
        evidence = self.output / "evidence"
        evidence.mkdir(exist_ok=True)
        for source in self.output.iterdir():
            if source.is_file() and source.suffix in {".json", ".jsonl", ".txt", ".py"}:
                shutil.copyfile(source, evidence / source.name)
        packages = self.output / "packages"
        if packages.exists():
            with tarfile.open(evidence / "staged-sources.tar.gz", "w:gz") as archive:
                for source in sorted(packages.rglob("*")):
                    if source.is_file():
                        archive.add(source, arcname=str(source.relative_to(packages)), recursive=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "test", "benchmark", "build"], default="all")
    parser.add_argument("--swift")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--pairs", "--samples", dest="pairs", type=int, default=6)
    parser.add_argument("--tests-only", action="store_true", help="alias for --mode test")
    parser.add_argument("--sizes", type=int, nargs="+", default=[100, 1000, 10000])
    parser.add_argument("--case", dest="cases", action="append", choices=CASES)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--configuration", dest="configurations", action="append", choices=["debug", "release"])
    parser.add_argument("--test-filter")
    parser.add_argument("--prove-baseline-failure", action="store_true")
    parser.add_argument("--smoke", action="store_true", help="allow fewer pairs; results are exploratory")
    args = parser.parse_args()
    if args.tests_only:
        args.mode = "test"
    args.cases = args.cases or CASES
    args.configurations = args.configurations or ["debug", "release"]
    if args.jobs < 1 or args.pairs < 1 or (not args.smoke and (args.pairs < 6 or args.pairs % 2)):
        parser.error("Use positive jobs and an even number of at least six pairs; --smoke permits fewer")
    if any(size not in [100, 1000, 10000, 100000] for size in args.sizes):
        parser.error("Supported sizes are 100, 1000, 10000, 100000")
    if args.iterations is not None and (args.iterations < 2 or args.iterations % 2):
        parser.error("Iterations must be even and at least two so both toggle states are measured")
    runner = Runner(args)
    try:
        runner.prepare()
        if args.mode in {"all", "test"}:
            runner.test()
        if args.mode in {"all", "benchmark", "build"}:
            runner.build()
        if args.mode in {"all", "benchmark"}:
            runner.measure()
    finally:
        runner.export_evidence()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Source tree qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
