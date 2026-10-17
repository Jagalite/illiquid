#!/usr/bin/env python3
"""Build and test exact tab sources, then run paired admission measurements."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE_REF = "8c3cc3d4008d5d1b8d436bcf2d51d891382b6548"
CORE = "Sources/IlliquidCore/Player/OpenVideoTabs.swift"
STORE = "Sources/IlliquidApp/App/OpenVideoTabStore.swift"
COMMON = [
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
TESTS = {
    "IlliquidCoreTests": ["OpenVideoTabsTests.swift", "OpenVideoTabResourceIndexTests.swift"],
    "IlliquidAppTests": ["OpenVideoTabStoreTests.swift", "OpenVideoTabAdmissionTests.swift"],
}
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "VideoTabAdmissionQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "TabAdmissionBenchmark", targets: ["IlliquidApp"])],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_blob(path: Path) -> str:
    content = path.read_bytes()
    return hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def execute(command: list[str | Path], output: Path, env: dict[str, str], *, timeout: int = 600,
            save_output: Path | None = None) -> str:
    args = [str(argument) for argument in command]
    started = time.monotonic()
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    with (output / "commands.jsonl").open("a") as log:
        log.write(json.dumps({
            "command": args, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - started,
            "stdout": result.stdout, "stderr": result.stderr,
        }, sort_keys=True) + "\n")
    if save_output is not None:
        save_output.write_text("STDOUT\n" + result.stdout + "\nSTDERR\n" + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def checked_baseline() -> dict:
    manifest = json.loads((HERE / "baseline/manifest.json").read_text())
    if manifest["revision"] != BASELINE_REF:
        raise RuntimeError("Unexpected baseline revision")
    for name, expected in manifest["files"].items():
        path = HERE / "baseline" / name
        if sha256(path) != expected["sha256"] or git_blob(path) != expected["git_blob"]:
            raise RuntimeError(f"Retained baseline changed: {name}")
    return manifest


def prepare_package(output: Path, variant: str, baseline: dict) -> tuple[Path, dict]:
    package = output / "packages" / variant
    mapping = {str(package / "Sources/IlliquidCore" / Path(name).name):
        (HERE / "baseline" / Path(name).name if variant == "baseline" else ROOT / name) for name in COMMON}
    mapping[str(package / "Sources/IlliquidCore/OpenVideoTabs.swift")] = (
        HERE / "baseline/OpenVideoTabs.swift" if variant == "baseline" else ROOT / CORE
    )
    mapping[str(package / "Sources/IlliquidApp/OpenVideoTabStore.swift")] = (
        HERE / "baseline/OpenVideoTabStore.swift" if variant == "baseline" else ROOT / STORE
    )
    mapping[str(package / "Sources/IlliquidApp/Harness.swift")] = HERE / "Harness.swift"
    for module, names in TESTS.items():
        for name in names:
            mapping[str(package / "Tests" / module / name)] = ROOT / "Tests" / module / name
    manifest = {"variant": variant, "baseline": baseline, "sources": {}}
    for destination, source in mapping.items():
        path = Path(destination)
        path.parent.mkdir(parents=True, exist_ok=True)
        # Read once and hash exactly the staged bytes. Concurrent work elsewhere
        # in the checkout must not produce a receipt for a different source.
        path.write_bytes(source.read_bytes())
        manifest["sources"][str(path.relative_to(package))] = {
            "repository_path": str(source.relative_to(ROOT)),
            "sha256": sha256(path), "git_blob": git_blob(path),
        }
    (package / "Package.swift").write_text(PACKAGE)
    manifest["package_sha256"] = sha256(package / "Package.swift")
    write_json(output / f"{variant}-sources.json", manifest)
    return package, manifest


def swift_command(swift: str, package: Path, output: Path, variant: str,
                  action: str, configuration: str, jobs: int) -> list[str | Path]:
    return [swift, action, "--package-path", package,
            "--scratch-path", output / "build" / variant,
            "--cache-path", output / "swiftpm-cache",
            "--config-path", output / "swiftpm-config",
            "--security-path", output / "swiftpm-security",
            "--configuration", configuration, "--jobs", str(jobs)]


def verify_staged_sources(package: Path, manifest: dict) -> None:
    if sha256(package / "Package.swift") != manifest["package_sha256"]:
        raise RuntimeError("Staged Package.swift changed during execution")
    for relative, expected in manifest["sources"].items():
        if sha256(package / relative) != expected["sha256"]:
            raise RuntimeError(f"Staged source changed during execution: {relative}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new or empty output directory")
    parser.add_argument("--swift", default="swift", help="Swift executable (defaults to PATH)")
    parser.add_argument("--tests-only", action="store_true", help="run both variants in debug and release")
    parser.add_argument("--samples", type=int, default=6)
    parser.add_argument("--jobs", type=int, default=1, help="concurrent Swift build jobs (not benchmark workers)")
    parser.add_argument("--sizes", type=int, nargs="+", default=[1, 10, 100, 500, 1000])
    args = parser.parse_args()
    if not 1 <= args.samples <= 25:
        parser.error("samples must be 1...25")
    if args.jobs < 1:
        parser.error("jobs must be positive")
    if not args.sizes or any(size not in [1, 10, 100, 500, 1000] for size in args.sizes):
        parser.error("sizes must be drawn from 1, 10, 100, 500, 1000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output must be new or empty; previous evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    baseline = checked_baseline()
    env = os.environ.copy()
    cache = output / "module-cache"
    cache.mkdir()
    env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
    version = execute([args.swift, "--version"], output, env).strip()
    head = execute(["git", "rev-parse", "HEAD"], output, env).strip()
    status = execute(["git", "status", "--short"], output, env)
    environment = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "architecture": platform.machine(),
        "logical_cpus": os.cpu_count(), "python": sys.version, "swift": version,
        "head_revision": head, "working_tree_status": status,
        "baseline_revision": BASELINE_REF, "samples": args.samples, "sizes": args.sizes, "build_jobs": args.jobs,
        "configuration": "debug and release tests; release timing",
        "ordering": "AB, BA, AB, BA, AB, BA for each scope/size by default",
        "cold_definition": "Fresh empty container per iteration; source URLs and playlists are preconstructed. No retained prefix snapshots or UI rendering.",
        "timing_clock": "DispatchTime.uptimeNanoseconds",
        "driver_hashes": {name: sha256(HERE / name) for name in ["run.py", "Harness.swift"]},
    }
    if Path("/proc/cpuinfo").exists():
        environment["cpu_model"] = next((line.split(":", 1)[1].strip()
            for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
    write_json(output / "environment.json", environment)
    packages, manifests, binaries = {}, {}, {}
    for variant in ["baseline", "candidate"]:
        packages[variant], manifests[variant] = prepare_package(output, variant, baseline)
    for configuration in ["debug", "release"]:
        for variant in ["baseline", "candidate"]:
            print(f"Testing {variant} ({configuration})", flush=True)
            verify_staged_sources(packages[variant], manifests[variant])
            command = swift_command(args.swift, packages[variant], output, variant, "test", configuration, args.jobs)
            execute(command, output, env, save_output=output / f"tests-{variant}-{configuration}.txt")
            verify_staged_sources(packages[variant], manifests[variant])
    write_json(output / "tests.json", {"passed": True, "variants": ["baseline", "candidate"],
        "configurations": ["debug", "release"], "suites": TESTS})
    if args.tests_only:
        print("Both source variants passed all four suites in debug and release.", flush=True)
        return
    for variant in ["baseline", "candidate"]:
        command = swift_command(args.swift, packages[variant], output, variant, "build", "release", args.jobs)
        execute(command + ["--product", "TabAdmissionBenchmark"], output, env)
        bin_path = execute(command + ["--show-bin-path"], output, env).strip()
        binaries[variant] = Path(bin_path) / "TabAdmissionBenchmark"
        manifests[variant]["binary_sha256"] = sha256(binaries[variant])
        write_json(output / f"{variant}-sources.json", manifests[variant])
        verify_staged_sources(packages[variant], manifests[variant])
    rows, expected = [], {}
    for scope in ["core", "store"]:
        for size in dict.fromkeys(args.sizes):
            cold = {1: 1000, 10: 100, 100: 2, 500: 1, 1000: 1}[size]
            warm = max(10, 5000 // size)
            for sample in range(args.samples):
                order = ["baseline", "candidate"] if sample % 2 == 0 else ["candidate", "baseline"]
                for process_order, variant in enumerate(order):
                    raw = execute([binaries[variant], scope, str(size), str(cold), str(warm)], output, env)
                    values = [json.loads(line) for line in raw.splitlines() if line]
                    operations = {value["operation"] for value in values}
                    wanted = {"unique_add", "duplicate_last", "record_last"}
                    if size <= 10:
                        wanted.add("close_reopen_last")
                    if operations != wanted or len(values) != len(wanted):
                        raise RuntimeError(f"Unexpected measurements: {scope}/{size}: {operations}")
                    for row in values:
                        key = (row["operation"], size)
                        if row["scope"] != scope or row["size"] != size:
                            raise RuntimeError("Benchmark returned the wrong workload")
                        iterations = cold if row["operation"] == "unique_add" else warm
                        if type(row.get("iterations")) is not int or row["iterations"] != iterations:
                            raise RuntimeError("Benchmark returned the wrong iteration count")
                        if type(row.get("elapsed_ns")) is not int or row["elapsed_ns"] < 0:
                            raise RuntimeError("Benchmark returned an invalid duration")
                        if key in expected and row["checksum"] != expected[key]:
                            raise RuntimeError(f"Semantic checksum differs: {key}/{scope}/{variant}")
                        expected[key] = row["checksum"]
                        row.update(variant=variant, sample=sample, process_order=process_order)
                        rows.append(row)
                        with (output / "measurements.jsonl").open("a") as log:
                            log.write(json.dumps(row, sort_keys=True) + "\n")
            cold_rows = [row for row in rows if row["scope"] == scope and row["size"] == size and row["operation"] == "unique_add"]
            medians = {variant: statistics.median(row["elapsed_ns"] / row["iterations"] / 1e6
                for row in cold_rows if row["variant"] == variant) for variant in ["baseline", "candidate"]}
            print(f"{scope} {size}: unique admission ms/batch {medians}", flush=True)
    groups = collections.defaultdict(list)
    for row in rows:
        groups[(row["scope"], row["operation"], row["size"], row["variant"])].append(row)
    summary = []
    for (scope, operation, size, variant), values in sorted(groups.items()):
        ns = [row["elapsed_ns"] / row["iterations"] for row in values]
        summary.append({"scope": scope, "operation": operation, "size": size, "variant": variant,
            "samples": len(values), "iterations_per_sample": values[0]["iterations"],
            "ns_per_iteration": {"median": statistics.median(ns), "min": min(ns), "max": max(ns)},
            "checksum": values[0]["checksum"]})
    write_json(output / "summary.json", {"groups": summary, "measurements": len(rows),
        "all_checksums_equal_across_variants_and_scopes": True})
    for variant in packages:
        verify_staged_sources(packages[variant], manifests[variant])
        if sha256(binaries[variant]) != manifests[variant]["binary_sha256"]:
            raise RuntimeError(f"Benchmark binary changed during execution: {variant}")
    print(f"Completed {len(rows)} checked measurements.", flush=True)


if __name__ == "__main__":
    main()
