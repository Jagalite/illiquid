#!/usr/bin/env python3
"""Qualify complete production checkpoint records against a pinned Git baseline.

The only differing production file is PlaybackCheckpointWriter.swift. Supporting
Core sources, including the real session initializer and its deduplication, are
identical. The driver is compiled separately from both production libraries.
"""
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
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CHECKPOINT = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE_PATHS = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
]
CORE_TESTS = [
    "PlaylistDeduplicationTests.swift",
    "PlaylistSessionRecordTests.swift",
    "PlaylistMutationTests.swift",
    "PlaylistOrderRestorationTests.swift",
    "FolderPlaylistTests.swift",
    "NaturalFilenameOrderingTests.swift",
]
PLAYER_TESTS = ["PlaybackCheckpointMembershipTests.swift"]
COMPONENT_TEST_SUITES = (
    "Playback checkpoint records",
    "Folder playlist",
    "Natural filename ordering parity",
    "Playlist deduplication",
    "Playlist mutation",
    "Playlist order restoration",
    "Playlist session record semantics",
)
COMPONENT_TEST_COUNTS = (43, 7)
QUICK_CASES = [
    "valid-32-last", "valid-1000-last", "nil-index-1000",
    "no-folder-1000", "remote-1000", "single-valid",
]
SESSION_BOUNDARY = (
    b"\n/// A versioned, atomic Application Support document for crash-safe playback\n"
)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# Reviewed support bytes from prepared integration tree 4f11661eca2cfb73fa6625fbec1502b53e28bc56
REGRESSION_SUPPORT_SHA256 = {'Sources/IlliquidCore/Playlist/FolderPlaylist.swift': '8a3c017132f0e79cb8280551ff686066b9a3005c49bd7833efc54bb11dfe75fe', 'Sources/IlliquidCore/Playlist/PlaylistMutation.swift': 'adb8778743e85252e1b432e26541964ca9a2b4bdd706ba59ce1bf677293d27a3', 'Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift': 'c09072130b113b90faa49b17ff95ce8983668734e69dddf6244572f5de80de62', 'Sources/IlliquidCore/Utilities/NormalizedFileURL.swift': '5cd5d029b7a5d8573ac3688676d5ea15117848e10249ed74b1f4df8a9566c18c', 'Sources/IlliquidCore/Player/MediaSource.swift': 'd3e776abaa9bdae73a6a656114eee1bc761ddbea78017a6b710ed22895f6d254', 'Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift': '4318a57a49833f22c3b1181c53694fc31e3a74535ee1644d82bce3134c54228f'}


def guard_support(path: str, current: bytes, historical: bytes, regression_only: bool) -> None:
    if regression_only:
        if sha(current) != REGRESSION_SUPPORT_SHA256[path]:
            raise RuntimeError(f"Supporting source differs from reviewed regression pin: {path}")
    elif current != historical:
        raise RuntimeError(f"Supporting source changed since the frozen baseline: {path}")


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def commit_sha(value: str) -> str:
    if re.fullmatch(r"[0-9a-fA-F]{40}", value) is None:
        raise argparse.ArgumentTypeError("baseline-ref must be an exact 40-character hexadecimal commit SHA")
    return value.lower()


def swift_testing_receipt(raw: bytes | str, *, required_suites: tuple[str, ...],
                          expected_counts: tuple[int, int] | None = None) -> dict:
    """Count combined (Swift 6.3) or per-module (Swift 6.4) successful runs.

    The frozen qualification selects named suites. Require their success lines
    and reconcile the reported suite total so a missing or duplicated module
    summary cannot silently become a complete test receipt.
    """
    text = raw.decode("utf-8") if isinstance(raw, bytes) else raw
    summary_lines = [line.split("Test run with ", 1)[1].strip()
                     for line in text.splitlines() if "Test run with " in line]
    if not summary_lines:
        raise ValueError("Swift Testing did not report a successful test run")
    summaries = []
    for line in summary_lines:
        match = re.fullmatch(
            r"(\d+) tests?(?: in (\d+) suites?)? passed(?: after .+)?", line)
        if match is None:
            raise ValueError(f"Malformed or unsuccessful Swift Testing summary: {line}")
        tests = int(match.group(1))
        suites = int(match.group(2) or "0")
        if tests == 0 and suites != 0:
            raise ValueError("A zero-test Swift Testing run cannot qualify a selected suite")
        summaries.append({"test_count": tests, "suite_count": suites})
    test_count = sum(row["test_count"] for row in summaries)
    suite_count = sum(row["suite_count"] for row in summaries)
    if test_count <= 0 or suite_count <= 0:
        raise ValueError("No Swift Testing tests or suites executed")
    passed_suites = re.findall(r'\bSuite "([^"\r\n]+)" passed(?: after [^\r\n]+)?', text)
    missing = set(required_suites).difference(passed_suites)
    if missing:
        raise ValueError(f"Required Swift Testing suites did not report success: {sorted(missing)}")
    if len(passed_suites) != len(set(passed_suites)) or suite_count != len(passed_suites):
        raise ValueError("Swift Testing summaries do not account for the unique successful named suites")
    if expected_counts is not None and (test_count, suite_count) != expected_counts:
        raise ValueError(f"Expected {expected_counts[0]} tests in {expected_counts[1]} suites; "
                         f"received {test_count} tests in {suite_count} suites")
    return {"test_count": test_count, "suite_count": suite_count,
            "run_summaries": summaries, "passed_suites": sorted(passed_suites)}


def session_api(raw: bytes) -> bytes:
    """Retain the complete record and storage protocol, without a replacement."""
    if raw.count(SESSION_BOUNDARY) != 1:
        raise ValueError("PlaybackSessionStore disk-store extraction boundary changed")
    prefix, suffix = raw.split(SESSION_BOUNDARY)
    required = (
        b"public struct PlaybackSessionRecord: Codable, Equatable, Sendable {",
        b"public protocol PlaybackSessionStoring: Sendable {",
    )
    if any(prefix.count(marker) != 1 for marker in required):
        raise ValueError("Session staging must include the actual record and protocol")
    if not prefix.rstrip().endswith(b"}") or not suffix.startswith(
        b"/// restoration. Preferences intentionally live in a separate store.\n"
        b"public final class AtomicPlaybackSessionStore:"
    ):
        raise ValueError("Unexpected declarations at the session staging boundary")
    return prefix + b"\n"


class Experiment:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.baseline = commit_sha(args.baseline_ref)
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty; evidence is never overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir()
        self.logs = self.evidence / "logs"
        self.logs.mkdir()
        self.source_root = self.evidence / "sources"
        self.source_root.mkdir()
        self.build_root = self.output / "build"
        self.build_root.mkdir()
        compiler = shutil.which(args.swiftc)
        if compiler is None:
            raise ValueError(f"Swift compiler not found: {args.swiftc}")
        self.swiftc = Path(compiler)
        self.swift = self.swiftc.with_name("swift")
        if not self.swift.is_file():
            raise ValueError(f"Swift package tool not found beside compiler: {self.swift}")
        self.environment = dict(os.environ)
        for variable in (
            "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"
        ):
            self.environment[variable] = str(self.output / "module-cache")
        self.command_number = 0
        self.core_sources: list[Path] = []
        self.player_sources: dict[str, Path] = {}
        self.binaries: dict[tuple[str, str], Path] = {}
        self.swift_sdk: str | None = None
        self.manifest: dict = {"mode": "current-source-regression" if args.regression_only else "historical-performance", "performance_qualified": False, "baseline": self.baseline, "production_sources": {}, "builds": {}}

    def command(self, argv: list, label: str, *, timeout: int = 900,
                compress_stdout: bool = False, combined_output: bool = False) -> bytes:
        self.command_number += 1
        command = [str(value) for value in argv]
        stem = f"{self.command_number:04d}-{label}"
        started = datetime.now(timezone.utc).isoformat()
        before = time.monotonic()
        process = subprocess.run(command, cwd=ROOT, env=self.environment,
                                 capture_output=True, timeout=timeout)
        elapsed = time.monotonic() - before
        stdout = self.logs / (stem + (".stdout.gz" if compress_stdout else ".stdout"))
        stderr = self.logs / (stem + ".stderr")
        stdout.write_bytes(gzip.compress(process.stdout, mtime=0)
                           if compress_stdout else process.stdout)
        stderr.write_bytes(process.stderr)
        receipt = {
            "argv": command, "cwd": str(ROOT), "started_utc": started,
            "elapsed_seconds": elapsed, "returncode": process.returncode,
            "stdout_file": str(stdout.relative_to(self.evidence)),
            "stdout_sha256": sha(process.stdout), "stdout_bytes": len(process.stdout),
            "stderr_file": str(stderr.relative_to(self.evidence)),
            "stderr_sha256": sha(process.stderr), "stderr_bytes": len(process.stderr),
        }
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(receipt, sort_keys=True) + "\n")
        if process.returncode:
            raise RuntimeError(
                f"Command failed ({process.returncode}); see {stdout} and {stderr}\n"
                + process.stdout[-4000:].decode(errors="replace")
                + process.stderr[-4000:].decode(errors="replace")
            )
        return process.stdout + process.stderr if combined_output else process.stdout

    def prepare(self) -> None:
        resolved = self.command(["git", "rev-parse", self.baseline + "^{commit}"],
                                "baseline-revision").decode().strip()
        if resolved != self.baseline:
            raise RuntimeError("Pinned baseline did not resolve to the recorded commit")
        self.manifest["baseline_resolved_commit"] = resolved
        self.manifest["candidate_revision"] = self.command(
            ["git", "rev-parse", "HEAD"], "candidate-revision"
        ).decode().strip()
        self.manifest["working_tree_status"] = self.command(
            ["git", "status", "--short"], "working-tree-status"
        ).decode()
        environment = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "architecture": platform.machine(),
            "cpu_count": os.cpu_count(), "python": platform.python_version(),
            "swift": self.command([self.swiftc, "--version"], "swift-version").decode().strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "github_sha": os.environ.get("GITHUB_SHA"),
            "github_event": os.environ.get("GITHUB_EVENT_NAME"),
            "baseline_resolved_commit": resolved,
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
            "timing_scope": "complete PlaybackCheckpoint.record() including production playlist deduplication, bounded scalar validation/checksum consumption, result destruction and a per-call autorelease pool on macOS",
            "excluded_scope": "input creation, complete-output verification, JSON encoding, disk I/O, coalescing, UI and playback",
        }
        if platform.system() == "Darwin":
            environment["macos"] = self.command(["sw_vers"], "macos-version").decode().strip()
            environment["cpu"] = self.command(
                ["sysctl", "-n", "machdep.cpu.brand_string"], "cpu"
            ).decode().strip()
            environment["sdk"] = self.command(
                ["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version"
            ).decode().strip()
            self.swift_sdk = self.command(
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk-path"
            ).decode().strip()
            environment["sdk_path"] = self.swift_sdk
        else:
            cpuinfo = Path("/proc/cpuinfo")
            if cpuinfo.is_file():
                environment["cpu"] = next((line.partition(":")[2].strip()
                    for line in cpuinfo.read_text().splitlines()
                    if line.startswith("model name")), "unknown")
        save(self.evidence / "environment.json", environment)

        shared = self.source_root / "shared-core"
        shared.mkdir()
        for path in CORE_PATHS:
            current = (ROOT / path).read_bytes()
            historical = self.command(["git", "show", f"{self.baseline}:{path}"],
                                      "baseline-support-" + Path(path).stem)
            guard_support(path, current, historical, self.args.regression_only)
            compiled = session_api(current) if path.endswith("PlaybackSessionStore.swift") else current
            destination = shared / Path(path).name
            destination.write_bytes(compiled)
            self.core_sources.append(destination)
            if compiled != current:
                (shared / (Path(path).name + ".full-source")).write_bytes(current)
            self.manifest["production_sources"][path] = {
                "shared_by_both_variants": True, "matches_baseline": current == historical,
                "historical_sha256": sha(historical),
                "support_policy": "reviewed-current" if self.args.regression_only else "historical-byte-identical",
                "full_sha256": sha(current), "compiled_sha256": sha(compiled),
                "compiled_bytes": len(compiled),
            }
        baseline = self.command(["git", "show", f"{self.baseline}:{CHECKPOINT}"], "baseline-checkpoint")
        candidate = (ROOT / CHECKPOINT).read_bytes()
        if baseline == candidate:
            raise RuntimeError("Baseline and candidate checkpoint implementations are identical")
        self.manifest["production_sources"][CHECKPOINT] = {}
        for variant, raw in (("baseline", baseline), ("candidate", candidate)):
            directory = self.source_root / variant
            directory.mkdir()
            path = directory / "PlaybackCheckpointWriter.swift"
            path.write_bytes(raw)
            self.player_sources[variant] = path
            self.manifest["production_sources"][CHECKPOINT][variant] = {
                "full_sha256": sha(raw), "compiled_sha256": sha(raw), "compiled_bytes": len(raw),
                "source_commit": self.baseline if variant == "baseline" else self.manifest["candidate_revision"],
                "from_working_tree": variant == "candidate",
            }
        self.manifest["harness"] = {}
        for name in ("Driver.swift", "run.py", "test_harness.py"):
            data = (HERE / name).read_bytes()
            (self.source_root / name).write_bytes(data)
            self.manifest["harness"][name] = sha(data)
        save(self.evidence / "manifest.json", self.manifest)

    def compiler_flags(self, configuration: str) -> list:
        optimization = ["-O", "-whole-module-optimization"] if configuration == "release" else ["-Onone", "-g"]
        result = [*optimization, "-swift-version", "6", "-warnings-as-errors",
                  "-module-cache-path", self.output / "module-cache"]
        if platform.system() == "Darwin":
            if not self.swift_sdk:
                raise RuntimeError("Native compilation requires the recorded macOS SDK")
            result += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", self.swift_sdk]
        return result

    def build(self) -> None:
        suffix = ".dylib" if platform.system() == "Darwin" else ".so"
        for configuration in ("debug", "release"):
            flags = self.compiler_flags(configuration)
            core = self.build_root / ("shared-core-" + configuration)
            core.mkdir()
            library = core / ("libIlliquidCore" + suffix)
            self.command([
                self.swiftc, *flags, "-enable-testing", "-emit-library", "-emit-module",
                "-module-name", "IlliquidCore", "-emit-module-path", core / "IlliquidCore.swiftmodule",
                *self.core_sources, "-o", library,
            ], "build-core-" + configuration)
            self.manifest["builds"]["shared-core-" + configuration] = {
                "library_sha256": sha(library.read_bytes()), "flags": [str(x) for x in flags]
            }
            for variant in ("baseline", "candidate"):
                directory = self.build_root / (variant + "-" + configuration)
                directory.mkdir()
                player_library = directory / ("libIlliquidPlayer" + suffix)
                self.command([
                    self.swiftc, *flags, "-enable-testing", "-emit-library", "-emit-module",
                    "-module-name", "IlliquidPlayer", "-emit-module-path", directory / "IlliquidPlayer.swiftmodule",
                    "-I", core, "-L", core, "-lIlliquidCore",
                    "-Xlinker", "-rpath", "-Xlinker", core,
                    self.player_sources[variant], "-o", player_library,
                ], f"build-player-{variant}-{configuration}")
                binary = directory / "checkpoint-driver"
                self.command([
                    self.swiftc, *flags, "-parse-as-library",
                    "-I", core, "-I", directory, "-L", core, "-L", directory,
                    "-lIlliquidCore", "-lIlliquidPlayer",
                    "-Xlinker", "-rpath", "-Xlinker", core,
                    "-Xlinker", "-rpath", "-Xlinker", directory,
                    self.source_root / "Driver.swift", "-o", binary,
                ], f"build-driver-{variant}-{configuration}")
                self.binaries[(variant, configuration)] = binary
                self.manifest["builds"][variant + "-" + configuration] = {
                    "player_library_sha256": sha(player_library.read_bytes()),
                    "binary_sha256": sha(binary.read_bytes()),
                    "flags": [str(x) for x in flags], "separate_production_modules": True,
                }
                save(self.evidence / "manifest.json", self.manifest)
                print(f"Built {variant}/{configuration} with shared production Core", flush=True)

    def test(self) -> None:
        results = []
        self.manifest["tests"] = {}
        for variant in ("baseline", "candidate"):
            package = self.build_root / (variant + "-tests")
            for part in ("Sources/IlliquidCore", "Sources/IlliquidPlayer",
                         "Tests/IlliquidCoreTests", "Tests/IlliquidPlayerTests"):
                (package / part).mkdir(parents=True)
            for source in self.core_sources:
                shutil.copyfile(source, package / "Sources/IlliquidCore" / source.name)
            shutil.copyfile(self.player_sources[variant],
                            package / "Sources/IlliquidPlayer/PlaybackCheckpointWriter.swift")
            for module, names in (("IlliquidCoreTests", CORE_TESTS), ("IlliquidPlayerTests", PLAYER_TESTS)):
                for name in names:
                    path = f"Tests/{module}/{name}"
                    data = (ROOT / path).read_bytes()
                    (package / path).write_bytes(data)
                    self.manifest["tests"][path] = sha(data)
                    snapshot = self.source_root / "tests" / module / name
                    snapshot.parent.mkdir(parents=True, exist_ok=True)
                    if snapshot.exists() and snapshot.read_bytes() != data:
                        raise RuntimeError("Test sources changed between baseline and candidate builds")
                    snapshot.write_bytes(data)
            manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "CheckpointMembershipQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    ])
'''
            (package / "Package.swift").write_text(manifest)
            for configuration in ("debug", "release"):
                raw = self.command([
                    self.swift, "test", "--package-path", package,
                    "--scratch-path", package / "build", "--cache-path", package / "cache",
                    "--config-path", package / "config", "--security-path", package / "security",
                    "--jobs", "2", "--no-parallel", "-c", configuration,
                    "-Xswiftc", "-warnings-as-errors",
                ], f"tests-{variant}-{configuration}", timeout=1200, combined_output=True)
                # A zero-exit build without executing the selected tests is not
                # qualification. Swift Testing may put its summary on stderr.
                receipt = swift_testing_receipt(raw, required_suites=COMPONENT_TEST_SUITES,
                                                expected_counts=COMPONENT_TEST_COUNTS)
                test_count, suite_count = receipt["test_count"], receipt["suite_count"]
                if results and (test_count, suite_count) != (results[0]["test_count"], results[0]["suite_count"]):
                    raise RuntimeError("Different test or suite counts across production variants/configurations")
                results.append({"variant": variant, "configuration": configuration, "passed": True,
                                **receipt})
                save(self.evidence / "tests.json", {"runs": results})
                print(f"Passed {variant}/{configuration} repository tests", flush=True)
        save(self.evidence / "manifest.json", self.manifest)

    def validate(self) -> None:
        reference = None
        rows = []
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                raw = self.command([self.binaries[(variant, configuration)], "verify"],
                                   f"verify-{variant}-{configuration}", compress_stdout=True)
                value = json.loads(raw)
                if not isinstance(value, dict) or not value.get("cases"):
                    raise RuntimeError("Driver did not return a nonempty complete verification trace")
                canonical = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
                if reference is None:
                    reference = canonical
                    (self.evidence / "complete-records.json.gz").write_bytes(
                        gzip.compress(canonical, mtime=0))
                elif canonical != reference:
                    raise RuntimeError(f"Complete-record parity failed for {variant}/{configuration}")
                rows.append({"variant": variant, "configuration": configuration,
                             "complete_record_count": len(value["cases"]),
                             "raw_sha256": sha(raw), "canonical_sha256": sha(canonical),
                             "exact_complete_record_parity": True})
                print(f"Verified {len(value['cases'])} complete records: {variant}/{configuration}", flush=True)
        save(self.evidence / "validation.json", {"equal": True, "comparisons": rows})

    def sample(self, variant: str, case: str, iterations: int, label: str) -> dict:
        row = json.loads(self.command([
            self.binaries[(variant, "release")], "bench", case, iterations,
        ], label))
        if row.get("case") != case or row.get("iterations") != iterations or row.get("validated") is not True:
            raise RuntimeError("Invalid benchmark case/iteration/output receipt")
        for metric in ("elapsed_ns", "cpu_ns"):
            if not isinstance(row.get(metric), (float, int)) or not math.isfinite(row[metric]) or row[metric] <= 0:
                raise RuntimeError(f"Invalid positive timing metric: {metric}")
        if row.get("output_fingerprint") != row.get("expected_fingerprint"):
            raise RuntimeError(f"Independent output check failed for {case}/{variant}")
        for field in ("checksum", "warmup_checksum", "output_fingerprint", "expected_fingerprint",
                      "input_count", "output_count"):
            if field not in row:
                raise RuntimeError(f"Missing result receipt: {field}")
        return row

    def measure(self) -> None:
        cases = json.loads(self.command([self.binaries[("baseline", "release")], "cases"], "baseline-cases"))
        candidate_cases = json.loads(self.command([self.binaries[("candidate", "release")], "cases"], "candidate-cases"))
        if not isinstance(cases, list) or not cases or len(set(cases)) != len(cases) or cases != candidate_cases:
            raise RuntimeError("Workload lists are invalid or differ between implementations")
        wanted = QUICK_CASES if self.args.quick else cases
        if not set(wanted).issubset(cases):
            raise RuntimeError("Quick workload list no longer matches the driver")
        cases = [case for case in cases if case in wanted]
        save(self.evidence / "workloads.json", cases)
        summary = {"pairs": self.args.pairs, "observations": 0, "workloads": []}
        cap = 1_000_000
        for case in cases:
            suggestions = []
            for variant in ("baseline", "candidate"):
                iterations = 1
                while True:
                    row = self.sample(variant, case, iterations, f"calibrate-{case}-{variant}")
                    with (self.evidence / "calibration.jsonl").open("a") as stream:
                        stream.write(json.dumps(dict(row, variant=variant), sort_keys=True) + "\n")
                    if row["elapsed_ns"] >= 10_000_000 or iterations == cap:
                        break
                    iterations = min(cap, max(iterations + 1,
                        math.ceil(iterations * 15_000_000 / row["elapsed_ns"])))
                suggestions.append(min(cap, max(1, math.ceil(
                    iterations * self.args.target_ms * 1_000_000 * 1.25 / row["elapsed_ns"]))))
            iterations = max(suggestions)
            rows = []
            expected = None
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = self.sample(variant, case, iterations, f"sample-{case}-{pair}-{variant}")
                    result = {key: row[key] for key in (
                        "checksum", "warmup_checksum", "output_fingerprint", "expected_fingerprint",
                        "input_count", "output_count",
                    )}
                    if expected is not None and result != expected:
                        raise RuntimeError(f"Output parity changed during timing: {case}/{pair}/{variant}")
                    expected = result
                    row.update(variant=variant, pair=pair, process_order=position, order=list(order))
                    rows.append(row)
                    with (self.evidence / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            group = {"case": case, "iterations": iterations, "pairs": self.args.pairs,
                     "input_count": expected["input_count"], "output_count": expected["output_count"],
                     "iteration_cap_reached": iterations == cap}
            for metric in ("elapsed_ns", "cpu_ns"):
                by_variant = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                              for variant in ("baseline", "candidate")}
                paired = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                    paired.append((values["candidate"] / values["baseline"] - 1) * 100)
                group[metric] = {
                    "median_ns_per_record": {v: statistics.median(s) for v, s in by_variant.items()},
                    "range_ns_per_record": {v: [min(s), max(s)] for v, s in by_variant.items()},
                    "paired_change_percent": paired,
                    "median_paired_change_percent": statistics.median(paired),
                    "pairs_faster": sum(change < 0 for change in paired),
                }
            group["observations_below_target"] = [
                {"variant": row["variant"], "pair": row["pair"], "elapsed_ns": row["elapsed_ns"]}
                for row in rows if row["elapsed_ns"] < self.args.target_ms * 1_000_000
            ]
            summary["observations"] += len(rows)
            summary["workloads"].append(group)
            save(self.evidence / "summary.json", summary)
            wall = group["elapsed_ns"]["median_ns_per_record"]
            print(f"{case}: {wall['baseline'] / 1000:.2f} -> {wall['candidate'] / 1000:.2f} us/record; "
                  f"paired wall {group['elapsed_ns']['median_paired_change_percent']:+.2f}%, "
                  f"CPU {group['cpu_ns']['median_paired_change_percent']:+.2f}%", flush=True)
        if summary["observations"] != len(cases) * self.args.pairs * 2:
            raise RuntimeError("Incomplete observation cohort")
        summary["complete"] = True
        save(self.evidence / "summary.json", summary)

    def verify_sources_unchanged(self) -> None:
        for path in CORE_PATHS:
            if sha((ROOT / path).read_bytes()) != self.manifest["production_sources"][path]["full_sha256"]:
                raise RuntimeError(f"Supporting production source changed during qualification: {path}")
        if sha((ROOT / CHECKPOINT).read_bytes()) != self.manifest["production_sources"][CHECKPOINT]["candidate"]["full_sha256"]:
            raise RuntimeError("Candidate checkpoint changed during qualification")
        for path, expected in self.manifest["tests"].items():
            if sha((ROOT / path).read_bytes()) != expected:
                raise RuntimeError(f"Test changed during qualification: {path}")
        for name, expected in self.manifest["harness"].items():
            if sha((HERE / name).read_bytes()) != expected:
                raise RuntimeError(f"Harness changed during qualification: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--baseline-ref", type=commit_sha, default=BASELINE,
                        help="Exact 40-character comparison commit SHA (default: original main baseline)")
    parser.add_argument("--pairs", type=int, default=None)
    parser.add_argument("--target-ms", type=float, default=None)
    parser.add_argument("--quick", action="store_true", help="Smoke cohort: six cases, two pairs, 20 ms target")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--regression-only", action="store_true",
                        help="Use exact reviewed current support for both variants; run all correctness checks without timing")
    args = parser.parse_args()
    if args.pairs is None:
        args.pairs = 2 if args.quick else 8
    if args.target_ms is None:
        args.target_ms = 20 if args.quick else 100
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even number of pairs >= 2 and a positive finite target-ms")
    experiment = Experiment(args)
    completion = {"mode": experiment.manifest["mode"], "timings_collected": False, "performance_qualified": False, "complete": False, "tests_only": args.tests_only, "quick": args.quick}
    try:
        experiment.prepare()
        experiment.build()
        experiment.test()
        experiment.validate()
        if not args.tests_only and not args.regression_only:
            experiment.measure()
            completion["timings_collected"] = True
        experiment.verify_sources_unchanged()
        completion["complete"] = True
        print("CHECKPOINT_MEMBERSHIP_REGRESSION_PASS" if args.regression_only else
              "CHECKPOINT_MEMBERSHIP_QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        completion["error"] = str(error)
        raise
    finally:
        save(experiment.evidence / "completion.json", completion)


if __name__ == "__main__":
    main()
