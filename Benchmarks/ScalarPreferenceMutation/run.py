#!/usr/bin/env python3
"""Compare exact scalar preference setters in isolated Swift packages."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
FOCAL = (
    "Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift",
    "Sources/IlliquidCore/Persistence/PlaybackPreferences.swift",
)
SUPPORT = (
    "Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift",
    "Sources/IlliquidCore/Persistence/MediaPlaybackSettings.swift",
    "Sources/IlliquidCore/Persistence/MediaContentVersion.swift",
    "Sources/IlliquidCore/Persistence/PlaybackRestoreTarget.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NonDecodePerformance.swift",
    "Sources/IlliquidCore/Player/MediaTrack.swift",
    "Sources/IlliquidCore/Player/TrackSelectionPreferences.swift",
    "Sources/IlliquidCore/Player/SubtitleFallbackEncoding.swift",
)
DECLARATIONS = (
    ("Sources/IlliquidCore/Playlist/PlaylistMutation.swift", "PlaybackRepeatMode",
     "public enum PlaylistMutation {"),
    ("Sources/IlliquidCore/Player/PlaybackModels.swift", "HardwareDecodingPolicy",
     "public struct HardwareDecodingStatus: Codable, Equatable, Sendable {"),
)
TESTS = (
    "PlaybackPersistenceStoreTests.swift", "IdempotentPersistenceTests.swift",
    "DeferredPersistenceTests.swift", "ScalarPreferenceMutationTests.swift",
)
VARIANTS = ("baseline", "candidate")
TIMINGS = ("caller_ns", "total_through_flush_ns", "flush_ns")
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ScalarPreferenceMutation", platforms: [.macOS("26.0")],
    products: [.executable(name: "ScalarPreferenceBenchmark", targets: ["ScalarPreferenceBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "ScalarPreferenceBenchmark", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ], swiftLanguageModes: [.v6]
)
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Run:
    def __init__(self, output: Path):
        self.output = output
        self.evidence = output / "evidence"
        (self.evidence / "logs").mkdir(parents=True)
        self.command_count = 0

    def command(self, argv: list, *, timeout: int = 900,
                environment: dict | None = None) -> tuple[str, str]:
        argv = [str(value) for value in argv]
        self.command_count += 1
        log = f"logs/{self.command_count:04d}.log"
        started = time.time()
        record = {"command": argv, "cwd": str(ROOT), "timeout_seconds": timeout,
                  "started_unix": started, "log": log}
        env = os.environ.copy()
        env.update(TERM="dumb", NO_COLOR="1")
        if environment:
            env.update(environment)
        try:
            result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                                    timeout=timeout)
            stdout = result.stdout.decode("utf-8", errors="replace")
            stderr = result.stderr.decode("utf-8", errors="replace")
            record.update(returncode=result.returncode, timed_out=False)
        except subprocess.TimeoutExpired as error:
            stdout = (error.stdout or b"").decode("utf-8", errors="replace")
            stderr = (error.stderr or b"").decode("utf-8", errors="replace")
            record.update(returncode=None, timed_out=True)
        except OSError as error:
            stdout, stderr = "", str(error)
            record.update(returncode=None, timed_out=False, launch_error=str(error))
        record["seconds"] = time.time() - started
        (self.evidence / log).write_text(stdout + "\n[stderr]\n" + stderr)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if record["returncode"] != 0:
            raise RuntimeError(f"Command failed or timed out: {argv}; see {self.evidence / log}")
        return stdout, stderr

    def git(self, *args: str) -> str:
        return self.command(["git", "-C", ROOT, *args], timeout=60)[0]


def declaration(data: bytes, name: str, following: str) -> tuple[bytes, dict]:
    """Extract one simple top-level enum; reject changed lexical boundaries."""
    text = data.decode("utf-8")
    opening = f"public enum {name}: String, Codable, CaseIterable, Sendable {{"
    if text.count(opening) != 1 or text.count(following) != 1:
        raise ValueError(f"Ambiguous declaration boundaries for {name}")
    start = text.index(opening)
    end = text.index("\n}", start) + 2
    value = text[start:end]
    if (start > 0 and text[start - 1] != "\n") or value.count("{") != 1:
        raise ValueError(f"Unexpected nested or non-top-level declaration: {name}")
    if value.count("}") != 1 or not text[end:].startswith("\n\n" + following):
        raise ValueError(f"Changed closing boundary for {name}")
    lines = value.splitlines()[1:-1]
    if not lines or any(re.fullmatch(r"    case [A-Za-z][A-Za-z0-9_]*", line) is None for line in lines):
        raise ValueError(f"Unexpected enum contents for {name}; review the extraction")
    return (value + "\n").encode(), {
        "declaration": name, "start_line": text[:start].count("\n") + 1,
        "end_line": text[:end].count("\n") + 1,
        "opening_boundary": opening, "following_boundary": following,
    }


def stage(run: Run, head: str) -> dict:
    paths = list(FOCAL + SUPPORT) + [item[0] for item in DECLARATIONS]
    paths += [f"Tests/IlliquidCoreTests/{name}" for name in TESTS]
    paths += ["Benchmarks/ScalarPreferenceMutation/Harness.swift"]
    # Read current support once. Both variants receive those same exact bytes.
    current = {path: (ROOT / path).read_bytes() for path in paths}
    baseline = {path: run.git("show", f"{BASELINE}:{path}").encode() for path in FOCAL}
    manifests = {}
    for variant in VARIANTS:
        package = run.output / "work" / variant / "package"
        entries = {}

        def put(source: str, destination: str, *, role: str,
                extracted: bytes | None = None, boundaries: dict | None = None) -> None:
            historical = variant == "baseline" and source in FOCAL
            original = baseline[source] if historical else current[source]
            data = extracted if extracted is not None else original
            target = package / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            entries[source] = {
                "destination": destination, "role": role,
                "origin": "git" if historical else "current_worktree_snapshot",
                "revision": BASELINE if historical else None,
                "worktree_head": None if historical else head,
                "original_sha256": sha(original), "staged_sha256": sha(data),
                "transformation": "verbatim declaration extraction" if extracted is not None else "none",
            }
            if boundaries:
                entries[source]["boundaries"] = boundaries

        for path in FOCAL + SUPPORT:
            put(path, "Sources/IlliquidCore/" + Path(path).name,
                role="focal" if path in FOCAL else "shared_current_support")
        for path, name, following in DECLARATIONS:
            data, boundaries = declaration(current[path], name, following)
            put(path, f"Sources/IlliquidCore/{name}.swift", role="shared_current_support",
                extracted=data, boundaries=boundaries)
        for name in TESTS:
            put(f"Tests/IlliquidCoreTests/{name}", f"Tests/IlliquidCoreTests/{name}", role="shared_test")
        put("Benchmarks/ScalarPreferenceMutation/Harness.swift",
            "Sources/ScalarPreferenceBenchmark/Harness.swift", role="shared_driver")
        (package / "Package.swift").write_text(PACKAGE)
        entries["<generated Package.swift>"] = {
            "destination": "Package.swift", "role": "shared_package_manifest",
            "origin": "run.py", "revision": None,
            "staged_sha256": sha(PACKAGE.encode()), "transformation": "generated isolated package",
        }
        manifests[variant] = entries
    differences = {path for path in manifests["baseline"]
                   if manifests["baseline"][path]["staged_sha256"] != manifests["candidate"][path]["staged_sha256"]}
    if differences != set(FOCAL):
        raise ValueError(f"Only the two focal sources may differ; actual differences: {sorted(differences)}")
    save(run.evidence / "sources.json", manifests)
    with tarfile.open(run.evidence / "sources.tar.gz", "w:gz") as archive:
        for variant in VARIANTS:
            package = run.output / "work" / variant / "package"
            archive.add(package, arcname=variant)
    return manifests


def swift_command(args: argparse.Namespace, variant: str, operation: str,
                  configuration: str) -> tuple[list, dict]:
    work = args.output / "work" / variant
    scratch = work / (f"tests-{configuration}" if operation == "test" else "benchmark-build")
    argv = [args.swift, operation, "--package-path", work / "package",
            "--configuration", configuration, "--jobs", "2", "--scratch-path", scratch,
            "--cache-path", work / "cache", "--config-path", work / "config",
            "--security-path", work / "security", "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        argv += ["--no-parallel"]
    if platform.system() == "Linux":
        argv += ["--use-integrated-swift-driver"]
    cache = str(work / "module-cache")
    return argv, {"CLANG_MODULE_CACHE_PATH": cache, "SWIFT_MODULECACHE_PATH": cache,
                  "SWIFTPM_MODULECACHE_OVERRIDE": cache}


def test_counts(output: str) -> dict:
    xctest = re.findall(r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?", output)
    testing = re.findall(r"Test run with\s+(\d+)\s+tests?\b[^\n]*\bpassed\b", output)
    if not xctest or not testing or any(int(failures) for _, failures in xctest):
        raise ValueError("Missing successful XCTest/Swift Testing completion receipts")
    counts = {"xctest": max(int(count) for count, _ in xctest), "swift_testing": int(testing[-1])}
    if min(counts.values()) <= 0:
        raise ValueError("Both staged test frameworks must execute tests")
    counts["total"] = sum(counts.values())
    return counts


def matrix(smoke: bool) -> list[dict]:
    languages = (0, 3) if smoke else (0, 1, 3, 32)
    return [{"field": field, "mode": mode, "language_count": count,
             "updates": 1_000 if mode in ("noop", "blocked") else 16}
            for field in ("volume", "speed")
            for mode in ("noop", "blocked", "burst", "flushed")
            for count in ((0, 3) if mode == "flushed" else languages)]


def validate_receipt(receipt: dict, cell: dict) -> dict:
    for key, value in cell.items():
        if receipt.get(key) != value:
            raise ValueError(f"Wrong benchmark input receipt for {key}: {receipt.get(key)} != {value}")
    for name in TIMINGS:
        value = receipt.get(name)
        if type(value) is not int or value < 0 or not math.isfinite(value):
            raise ValueError(f"Invalid timing {name}: {value}")
    if receipt["caller_ns"] <= 0 or receipt["total_through_flush_ns"] < receipt["caller_ns"]:
        raise ValueError("Invalid caller/complete-operation timing relationship")
    expected_writes = {"noop": 0, "blocked": 2, "burst": 1, "flushed": cell["updates"]}[cell["mode"]]
    if receipt.get("writes") != expected_writes:
        raise ValueError(f"Unexpected write count: {receipt.get('writes')} != {expected_writes}")
    expected_during = cell["updates"] if cell["mode"] == "flushed" else 0
    if receipt.get("writes_during_timing") != expected_during:
        raise ValueError("Background callbacks contaminated caller timing")
    for key in ("actual_audio_languages", "actual_subtitle_languages"):
        values = receipt.get(key)
        if (not isinstance(values, list) or len(values) != cell["language_count"]
                or not all(isinstance(value, str) for value in values)):
            raise ValueError(f"Unexpected actual language list: {key}")
    if receipt.get("unchanged_history") is not True:
        raise ValueError("Playback history changed")
    final, persisted = receipt.get("final_preferences"), receipt.get("persisted_preferences")
    if not isinstance(final, str) or final != persisted or not isinstance(json.loads(final), dict):
        raise ValueError("Complete final preferences did not persist identically")
    return {key: value for key, value in receipt.items() if key not in TIMINGS}


def summarize(rows: list[dict], cells: list[dict], pairs: int) -> list[dict]:
    results = []
    for index, cell in enumerate(cells):
        selected = [row for row in rows if row["cell"] == index]
        expected = {(variant, pair) for variant in VARIANTS for pair in range(pairs)}
        if len(selected) != len(expected) or {(row["variant"], row["pair"]) for row in selected} != expected:
            raise ValueError("Incomplete or duplicate benchmark pairs")
        metrics = {}
        for name in TIMINGS:
            data = {variant: [next(row[name] for row in selected
                                  if row["variant"] == variant and row["pair"] == pair)
                              for pair in range(pairs)] for variant in VARIANTS}
            if any(value <= 0 for value in data["baseline"]):
                raise ValueError(f"Cannot compute ratio for nonpositive {name}")
            ratios = [candidate / baseline for baseline, candidate in zip(data["baseline"], data["candidate"])]
            metrics[name] = {
                "baseline_median_ns": statistics.median(data["baseline"]),
                "candidate_median_ns": statistics.median(data["candidate"]),
                "baseline_range_ns": [min(data["baseline"]), max(data["baseline"])],
                "candidate_range_ns": [min(data["candidate"]), max(data["candidate"])],
                "baseline_median_ns_per_update": statistics.median(data["baseline"]) / cell["updates"],
                "candidate_median_ns_per_update": statistics.median(data["candidate"]) / cell["updates"],
                "paired_candidate_over_baseline_median": statistics.median(ratios),
                "paired_candidate_over_baseline_range": [min(ratios), max(ratios)],
                "paired_percent_change_median": (statistics.median(ratios) - 1) * 100,
            }
        results.append({**cell, "pairs": pairs, "metrics": metrics})
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--mode", choices=("all", "test", "benchmark"), default="all")
    parser.add_argument("--pairs", type=int)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    args.pairs = args.pairs if args.pairs is not None else (2 if args.smoke else 6)
    if args.pairs % 2 or args.pairs < (2 if args.smoke else 6):
        parser.error("Use an even pair count of at least six (two with --smoke)")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("Use a new, empty output directory")
    run = Run(args.output)
    manifest = {"schema": 1, "status": "in_progress", "completed": False,
                "baseline_focal_revision": BASELINE, "mode": args.mode, "pairs": args.pairs,
                "smoke": args.smoke, "platform": platform.platform(), "machine": platform.machine(),
                "python": platform.python_version(), "started_unix": time.time(),
                "method": "fresh release processes; balanced AB/BA pairs; no discarded samples",
                "scope": "scalar preference caller work and complete operation through flush; no live app measurement"}
    save(run.evidence / "manifest.json", manifest)
    try:
        head = run.git("rev-parse", "HEAD").strip()
        if run.git("rev-parse", f"{BASELINE}^{{commit}}").strip() != BASELINE:
            raise ValueError("Pinned baseline commit is unavailable")
        manifest.update(worktree_head=head, worktree_status=run.git("status", "--porcelain=v1").splitlines(),
                        compiler=run.command([args.swift, "--version"], timeout=60)[0].strip(),
                        runner_sha256=sha(Path(__file__).read_bytes()),
                        selected_environment={key: os.environ[key] for key in
                            ("DEVELOPER_DIR", "LD_LIBRARY_PATH", "SWIFT_EXEC") if key in os.environ})
        manifest["logical_cpu_count"] = os.cpu_count()
        if platform.system() == "Darwin":
            manifest["cpu"] = run.command(["sysctl", "-n", "machdep.cpu.brand_string"], timeout=60)[0].strip()
            manifest["macos"] = run.command(["sw_vers"], timeout=60)[0].strip()
        elif Path("/proc/cpuinfo").is_file():
            manifest["cpu"] = next((line.split(":", 1)[1].strip()
                                    for line in Path("/proc/cpuinfo").read_text().splitlines()
                                    if line.startswith("model name")), "unknown")
            quota = Path("/sys/fs/cgroup/cpu.max")
            if quota.is_file():
                manifest["cpu_quota"] = quota.read_text().strip()
        sources = stage(run, head)
        manifest["source_manifest_sha256"] = sha((run.evidence / "sources.json").read_bytes())
        manifest["source_archive_sha256"] = sha((run.evidence / "sources.tar.gz").read_bytes())
        cells = matrix(args.smoke)
        manifest["matrix"] = cells
        save(run.evidence / "manifest.json", manifest)
        tests = []
        if args.mode in ("all", "test"):
            for variant in VARIANTS:
                for configuration in ("debug", "release"):
                    print(f"Test {variant} {configuration}", flush=True)
                    command, environment = swift_command(args, variant, "test", configuration)
                    stdout, stderr = run.command(command, environment=environment)
                    tests.append({"variant": variant, "configuration": configuration,
                                  "counts": test_counts(stdout + "\n" + stderr)})
                    save(run.evidence / "tests.json", tests)
            if any(test["counts"] != tests[0]["counts"] for test in tests):
                raise ValueError("Baseline/candidate debug/release test counts differ")
        if args.mode in ("all", "benchmark"):
            binaries = {}
            for variant in VARIANTS:
                print(f"Build {variant} release benchmark", flush=True)
                command, environment = swift_command(args, variant, "build", "release")
                run.command(command + ["--product", "ScalarPreferenceBenchmark"], environment=environment)
                directory = run.command(command + ["--show-bin-path"], environment=environment)[0].strip()
                binaries[variant] = Path(directory) / "ScalarPreferenceBenchmark"
            manifest["binary_sha256"] = {variant: sha(path.read_bytes()) for variant, path in binaries.items()}
            save(run.evidence / "manifest.json", manifest)
            rows, parity = [], []
            for index, cell in enumerate(cells):
                print(f"Measure {cell['field']} {cell['mode']} languages={cell['language_count']}", flush=True)
                reference = None
                for pair in range(args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    for order_index, variant in enumerate(order):
                        stdout, _ = run.command([binaries[variant], cell["field"], cell["mode"],
                                                 cell["language_count"], cell["updates"]], timeout=120)
                        receipt = json.loads(stdout)
                        semantics = validate_receipt(receipt, cell)
                        if reference is None:
                            reference = semantics
                        elif semantics != reference:
                            raise ValueError(f"Exact complete-receipt parity failed in cell {cell}")
                        row = {**receipt, "variant": variant, "cell": index, "pair": pair,
                               "order_index": order_index}
                        rows.append(row)
                        with (run.evidence / "observations.jsonl").open("a") as stream:
                            stream.write(json.dumps(row, sort_keys=True) + "\n")
                parity.append({**cell, "observations_compared": args.pairs * 2, "reference": reference})
                save(run.evidence / "parity.json", parity)
            save(run.evidence / "summary.json", summarize(rows, cells, args.pairs))
            if any(sha(path.read_bytes()) != manifest["binary_sha256"][variant]
                   for variant, path in binaries.items()):
                raise ValueError("A measured executable changed during the run")
            manifest["observations"] = len(rows)
        for variant, entries in sources.items():
            package = args.output / "work" / variant / "package"
            for entry in entries.values():
                if sha((package / entry["destination"]).read_bytes()) != entry["staged_sha256"]:
                    raise ValueError("A staged source changed during the run")
        if sha(Path(__file__).read_bytes()) != manifest["runner_sha256"]:
            raise ValueError("Runner changed during execution")
        manifest.update(status="completed", completed=True, tests=tests, finished_unix=time.time())
        save(run.evidence / "manifest.json", manifest)
        print(f"Completed; evidence: {run.evidence}", flush=True)
    except BaseException as error:
        manifest.update(status="failed", completed=False, error=f"{type(error).__name__}: {error}",
                        finished_unix=time.time())
        save(run.evidence / "manifest.json", manifest)
        raise


if __name__ == "__main__":
    main()
