#!/usr/bin/env python3
"""Compile production scanner code, qualify scoped snapshots, and measure retention.

The isolated package has no external dependencies or filesystem mocks. It uses
the complete production scanner and core helpers, plus the exact SourceTreeIdentity
declaration extracted from the SwiftUI sidebar file. No dependencies are fetched.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
SCANNER = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
CORE = [
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/SourcePreparationExecutor.swift",
]
APP = [
    SCANNER,
    "Sources/IlliquidApp/UI/SourceMediaPresenceRecomputation.swift",
    "Sources/IlliquidApp/App/SourceRootPruning.swift",
]
TESTS = [
    "Tests/IlliquidAppTests/SourceMediaPresenceSnapshotTests.swift",
    "Tests/IlliquidAppTests/SourceMediaPresenceRecomputationTests.swift",
]
CASES = [
    "empty", "narrow-1000", "narrow-10000", "narrow-100000",
    "mixed-100000", "whole-root-10000", "filesystem-root-10000", "no-reuse-10000",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--case", action="append", choices=CASES)
    args = parser.parse_args()
    if not args.swift:
        parser.error("Swift 6.1 or newer is required")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("Use an even number of pairs, at least two")
    if args.tests_only and args.skip_tests:
        parser.error("--tests-only and --skip-tests cannot be combined")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    package = output / "package"
    package.mkdir()
    env = os.environ.copy()
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    commands = []
    sources = {}

    def command(argv, log=None, timeout=600):
        argv = [str(value) for value in argv]
        result = subprocess.run(argv, cwd=ROOT, env=env, text=True,
                                capture_output=True, timeout=timeout)
        commands.append({"argv": argv, "returncode": result.returncode,
                         "stdout_sha256": digest(result.stdout.encode()),
                         "stderr_sha256": digest(result.stderr.encode())})
        write_json(output / "commands.json", commands)
        if log:
            (output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-3000:]}\n{result.stderr[-9000:]}")
        return result.stdout

    def copy_source(relative, destination):
        data = (ROOT / relative).read_bytes()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        sources[relative] = {"sha256": digest(data), "bytes": len(data)}

    for path in CORE:
        copy_source(path, package / "Sources/IlliquidCore" / Path(path).name)
    for path in APP:
        copy_source(path, package / "Sources/IlliquidApp" / Path(path).name)
    for path in TESTS:
        copy_source(path, package / "Tests/IlliquidAppTests" / Path(path).name)

    sidebar_path = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
    sidebar = (ROOT / sidebar_path).read_text()
    start, end = "enum SourceTreeIdentity {", "\nstruct SourcesSidebarExpansionSnapshot:"
    if sidebar.count(start) != 1 or sidebar.count(end) != 1:
        raise ValueError("SourceTreeIdentity extraction markers changed")
    identity = sidebar[sidebar.index(start):sidebar.index(end)]
    if identity.count("{") != identity.count("}"):
        raise ValueError("Unbalanced SourceTreeIdentity declaration")
    (package / "Sources/IlliquidApp/SourceTreeIdentity.swift").write_text(
        "import Foundation\nimport IlliquidCore\n\n" + identity)
    sources[sidebar_path] = {"sha256": digest(sidebar.encode()),
                             "extracted_identity_sha256": digest(identity.encode())}

    targets = [
        '.target(name: "IlliquidCore")',
        '.target(name: "IlliquidApp", dependencies: ["IlliquidCore"])',
        '.testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"])',
    ]
    if not args.tests_only:
        for name, destination in [
            ("Harness.swift", "Sources/SnapshotBenchmark/main.swift"),
            ("MemoryProbe.c", "Sources/CMemoryProbe/MemoryProbe.c"),
            ("MemoryProbe.h", "Sources/CMemoryProbe/include/MemoryProbe.h"),
        ]:
            copy_source(str(HERE.relative_to(ROOT) / name), package / destination)
        targets.extend([
            '.target(name: "CMemoryProbe", publicHeadersPath: "include")',
            '.executableTarget(name: "SnapshotBenchmark", dependencies: ["IlliquidApp", "CMemoryProbe"])',
        ])
    (package / "Package.swift").write_text(
        '// swift-tools-version: 6.1\nimport PackageDescription\n'
        'let package = Package(name: "SourcePresenceSnapshotQualification", targets: [\n'
        + ",\n".join(targets) + "\n])\n")

    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift": command([args.swift, "--version"]).strip(),
        "baseline_commit": BASELINE,
        "candidate_commit": command(["git", "rev-parse", "HEAD"]).strip(),
        "worktree_status": command(["git", "status", "--porcelain=v1"]),
        "sources": sources, "runner_sha256": digest(Path(__file__).read_bytes()),
        "hashing": "SWIFT_DETERMINISTIC_HASHING=1", "pairs": args.pairs,
        "cases": args.case or CASES,
    }
    write_json(output / "manifest.json", manifest)
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    flags = ["--package-path", package, "--jobs", "2", "-Xswiftc", "-warnings-as-errors"]
    if not args.skip_tests:
        for configuration in ("debug", "release"):
            print(f"Running {configuration} production scanner regressions", flush=True)
            command([args.swift, "test", *flags, "-c", configuration],
                    log=f"tests-{configuration}.log")
    if args.tests_only:
        return

    # Preserve and verify the original production filter rather than trusting a
    # hand-written approximation of the baseline ownership behavior.
    original = command(["git", "show", f"{BASELINE}:{SCANNER}"])
    (output / "baseline-scanner.swift").write_text(original)
    baseline_filter = """self.results.filter { entry in
                    self.summaries[entry.key]?.isComplete == true
                        && self.summaries[entry.key]?.isReadable == true
                }"""
    if original.count(baseline_filter) != 1:
        raise ValueError("Pinned production baseline filter changed")
    harness = (HERE / "Harness.swift").read_text()
    begin_marker, end_marker = "// BEGIN BASELINE FILTER", "// END BASELINE FILTER"
    if harness.count(begin_marker) != 1 or harness.count(end_marker) != 1:
        raise ValueError("Baseline harness markers changed")
    actual = harness.split(begin_marker)[1].split(end_marker)[0]
    normalize = lambda text: "".join(text.replace("self.", "").replace("return ", "").split())
    if normalize(actual) != normalize(baseline_filter):
        raise ValueError("Harness does not contain the exact baseline predicate")
    manifest["baseline_scanner_sha256"] = digest(original.encode())
    write_json(output / "manifest.json", manifest)

    print("Building release snapshot benchmark", flush=True)
    command([args.swift, "build", *flags, "-c", "release", "--product", "SnapshotBenchmark",
             "-Xswiftc", "-enable-testing"], log="benchmark-build.log")
    binary_path = command([args.swift, "build", "--package-path", package,
                           "-c", "release", "--show-bin-path"]).strip()
    binary = Path(binary_path) / "SnapshotBenchmark"
    manifest["benchmark_sha256"] = digest(binary.read_bytes())
    write_json(output / "manifest.json", manifest)
    observations = []
    cases = args.case or CASES
    with (output / "observations.jsonl").open("w") as stream:
        for case in cases:
            print(f"Measuring {case}", flush=True)
            for pair in range(args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                pair_values = {}
                for position, variant in enumerate(order):
                    text = command([binary, variant, case, "1"], timeout=120)
                    row = json.loads(text)
                    if row["case"] != case or row["variant"] != variant:
                        raise ValueError("Benchmark response does not match invocation")
                    row.update(pair=pair, order_index=position)
                    observations.append(row)
                    pair_values[variant] = row
                    stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
                    stream.flush()
                if pair_values["baseline"]["scoped_checksum"] != pair_values["candidate"]["scoped_checksum"]:
                    raise ValueError(f"Scoped snapshot behavior differs for {case}/{pair}")
    summary = {"platform": manifest["platform"], "pairs": args.pairs, "cases": []}
    for case in cases:
        by_variant = {v: [r for r in observations if r["case"] == case and r["variant"] == v]
                      for v in ("baseline", "candidate")}
        entry = {"case": case}
        for variant, rows in by_variant.items():
            numeric_keys = [key for key, value in rows[0].items()
                            if isinstance(value, (int, float)) and key not in {"pair", "order_index"}]
            values = {key: {"min": min(r[key] for r in rows),
                            "median": statistics.median(r[key] for r in rows),
                            "max": max(r[key] for r in rows)} for key in numeric_keys}
            for name, after in (("snapshot_heap_delta", "heap_after_snapshot"),
                                ("publication_heap_delta", "heap_after_publication")):
                deltas = [r[after] - r["heap_before"] for r in rows]
                values[name] = {"min": min(deltas), "median": statistics.median(deltas), "max": max(deltas)}
            entry[variant] = values
        summary["cases"].append(entry)
    write_json(output / "summary.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
