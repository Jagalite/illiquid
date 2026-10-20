#!/usr/bin/env python3
"""Exact-source runtime lease history tests and balanced fresh-process timings."""
from __future__ import annotations

import argparse
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
ROOT = HERE.parent.parent
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCES = {
    "metadata": "Sources/IlliquidNativePlayback/Runtime/PlaybackRuntimeMetadata.swift",
    "identity": "Sources/IlliquidPlaybackCore/IdentityAndTime.swift",
    "track": "Sources/IlliquidCore/Player/MediaTrack.swift",
    "events": "Sources/IlliquidPlaybackCore/EventsAndEffects.swift",
}
TEST_SOURCE = "Tests/IlliquidNativePlaybackTests/RuntimeLeaseHistoryTests.swift"
PASS_TESTS = (
    "snapshotsPreserveFullProvenanceAndSortLiveAndReleasedEvidence",
    "supersessionMatchesCompleteAuthorityAndKeepsRequestedReleasesPending",
)
NEGATIVE_TEST = "completedHistoryRemainsBoundedAcrossManySessionReplacements"
MASK = (1 << 64) - 1


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def command(args: list[str | Path], output: Path, *, expected_failure: bool = False,
            timeout: int = 300) -> subprocess.CompletedProcess[str]:
    args = [str(arg) for arg in args]
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"), TERM="dumb", NO_COLOR="1")
    started = time.time()
    raw_result = subprocess.run(args, env=env, capture_output=True, timeout=timeout)
    # Decode explicitly so newline translation cannot change copied Git source.
    result = subprocess.CompletedProcess(args, raw_result.returncode,
                                         raw_result.stdout.decode(), raw_result.stderr.decode())
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": args, "returncode": result.returncode,
                                 "started_unix": started, "elapsed_seconds": time.time() - started,
                                 "stdout": result.stdout, "stderr": result.stderr}) + "\n")
    if result.returncode != 0 and not expected_failure:
        raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{result.stdout}\n{result.stderr}")
    return result


def harness_hashes() -> dict[str, str]:
    return {str(p.relative_to(HERE)): sha256(p.read_bytes())
            for p in sorted(HERE.rglob("*")) if p.is_file()
            and "__pycache__" not in p.parts and p.suffix in {".py", ".swift", ".c", ".h", ".md"}}


def prepare(args: argparse.Namespace) -> dict:
    output = args.output
    manifest_path = output / "manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if manifest["swift"] != str(args.swift):
            raise ValueError("Selected compiler changed; use a new output directory")
        if command([args.swift, "--version"], output).stdout.strip() != manifest["compiler"]:
            raise ValueError("Compiler version changed; use a new output directory")
        if command(["git", "-C", ROOT, "rev-parse", f"{args.baseline}^{{commit}}"], output).stdout.strip() != manifest["baseline_commit"]:
            raise ValueError("Requested baseline changed; use a new output directory")
        if platform.system() == "Darwin" and command(["xcrun", "--find", "swiftc"], output).stdout.strip() != manifest["effective_swiftc"]:
            raise ValueError("Selected Xcode compiler changed; use a new output directory")
        for path, expected in manifest["compiler_artifacts_sha256"].items():
            if sha256(Path(path).read_bytes()) != expected:
                raise ValueError(f"Compiler artifact changed: {path}")
        if manifest["harness_sha256"] != harness_hashes():
            raise ValueError("Harness changed after preparation; use a new output directory")
        for relative, expected in manifest["candidate_source_sha256"].items():
            if sha256((ROOT / relative).read_bytes()) != expected:
                raise ValueError(f"Candidate source changed after preparation: {relative}")
        for relative, expected in manifest["prepared_files_sha256"].items():
            if sha256((output / relative).read_bytes()) != expected:
                raise ValueError(f"Prepared source changed: {relative}")
        return manifest
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a new empty output directory, or resume an existing manifest")
    output.mkdir(parents=True, exist_ok=True)
    baseline = command(["git", "-C", ROOT, "rev-parse", f"{args.baseline}^{{commit}}"], output).stdout.strip()
    candidate_head = command(["git", "-C", ROOT, "rev-parse", "HEAD"], output).stdout.strip()
    compiler = command([args.swift, "--version"], output).stdout.strip()
    source_hashes: dict[str, dict[str, str]] = {}
    for variant in ["baseline", "candidate"]:
        package = output / variant
        modules = package / "Sources"
        raw = {}
        for key, relative in SOURCES.items():
            if variant == "baseline":
                data = command(["git", "-C", ROOT, "show", f"{baseline}:{relative}"], output).stdout.encode()
            else:
                data = (ROOT / relative).read_bytes()
            raw[key] = data
            full_path = output / "production-sources" / variant / relative
            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_bytes(data)
        marker = b"\npublic struct EffectResultKind:"
        if not raw["events"].startswith(b"public enum ExecutorKind:") or raw["events"].count(marker) != 1:
            raise ValueError("ExecutorKind source boundary changed")
        executor_kind = raw["events"][:raw["events"].index(marker) + 1]
        copies = {
            modules / "IlliquidCore/MediaTrack.swift": raw["track"],
            modules / "IlliquidPlaybackCore/IdentityAndTime.swift": raw["identity"],
            modules / "IlliquidPlaybackCore/ExecutorKind.swift": executor_kind,
            modules / "IlliquidNativePlayback/PlaybackRuntimeMetadata.swift": raw["metadata"],
            modules / "IlliquidNativePlayback/Harness.swift": (HERE / "Harness.swift").read_bytes(),
            modules / "CLeaseHeap/heap.c": (HERE / "CLeaseHeap/heap.c").read_bytes(),
            modules / "CLeaseHeap/include/CLeaseHeap.h": (HERE / "CLeaseHeap/include/CLeaseHeap.h").read_bytes(),
            package / "Tests/IlliquidNativePlaybackTests/RuntimeLeaseHistoryTests.swift": (ROOT / TEST_SOURCE).read_bytes(),
        }
        for path, data in copies.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RuntimeLeaseHistory", platforms: [.macOS("26.0")],
    products: [.executable(name: "RuntimeLeaseHistory", targets: ["IlliquidNativePlayback"])],
    targets: [
        .target(name: "CLeaseHeap", publicHeadersPath: "include"),
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .executableTarget(name: "IlliquidNativePlayback", dependencies: ["IlliquidPlaybackCore", "CLeaseHeap"]),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ], swiftLanguageModes: [.v6])
''')
        source_hashes[variant] = {SOURCES[key]: sha256(value) for key, value in raw.items()}
        source_hashes[variant]["ExecutorKind exact prefix"] = sha256(executor_kind)
    for key in ["identity", "track", "events"]:
        if source_hashes["baseline"][SOURCES[key]] != source_hashes["candidate"][SOURCES[key]]:
            raise ValueError(f"Dependency changed between variants: {SOURCES[key]}")
    effective_swiftc = (command(["xcrun", "--find", "swiftc"], output).stdout.strip()
                       if platform.system() == "Darwin" else str(Path(args.swift).resolve().with_name("swiftc")))
    compiler_directory = Path(effective_swiftc).parent
    compiler_hashes = {str(p): sha256(p.read_bytes()) for name in ["swiftc", "swift-frontend", "clang"]
                       if (p := compiler_directory / name).exists()}
    environment = {
        "platform": platform.platform(), "machine": platform.machine(),
        "processor": platform.processor(), "logical_cpus": os.cpu_count(),
        "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "compiler": compiler, "swift": str(Path(args.swift).resolve()),
        "effective_swiftc": effective_swiftc, "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "compiler_artifacts_sha256": compiler_hashes,
        "ld_library_path": os.environ.get("LD_LIBRARY_PATH"),
        "build_flags": "SwiftPM debug (-Onone), release (-O -whole-module-optimization); Swift 6; -warnings-as-errors",
        "linux_integrated_driver": platform.system() == "Linux",
        "baseline_commit": baseline, "candidate_head": candidate_head,
        "candidate_worktree_sources": True, "source_sha256": source_hashes,
        "method": "isolated exact-source SwiftPM package; alternating AB/BA; sequential fresh processes",
        "scope": "runtime metadata component; excludes decoding, windowing, whole-player CPU/RSS and input-to-screen latency",
    }
    if Path("/proc/cpuinfo").exists():
        names = re.findall(r"^model name\s*:\s*(.*)$", Path("/proc/cpuinfo").read_text(), re.MULTILINE)
        environment["cpu_models"] = sorted(set(names))
    save(output / "environment.json", environment)
    manifest = {
        "baseline_commit": baseline, "compiler": compiler, "swift": str(args.swift),
        "effective_swiftc": effective_swiftc,
        "compiler_artifacts_sha256": compiler_hashes,
        "source_sha256": source_hashes, "harness_sha256": harness_hashes(),
        "candidate_source_sha256": {p: sha256((ROOT / p).read_bytes()) for p in [*SOURCES.values(), TEST_SOURCE]},
        "prepared_files_sha256": {str(p.relative_to(output)): sha256(p.read_bytes())
                                  for p in output.rglob("*") if p.is_file() and p.suffix in {".swift", ".c", ".h"}},
    }
    save(manifest_path, manifest)
    return manifest


def swift_command(args: argparse.Namespace, variant: str, operation: str, configuration: str) -> list:
    result = [args.swift, operation, "--package-path", args.output / variant,
              "--configuration", configuration, "--jobs", str(args.jobs),
              "--cache-path", args.output / "cache", "--config-path", args.output / "config",
              "--security-path", args.output / "security", "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        # Testable imports must never rebuild the measured release executable.
        result += ["--scratch-path", args.output / variant / ".build/focused-tests"]
    if platform.system() == "Linux":
        # Avoid standalone-driver child-process statistics failures in restricted
        # PID namespaces. Compiler and test source semantics remain unchanged.
        result.append("--use-integrated-swift-driver")
    return result


def build(args: argparse.Namespace, manifest: dict) -> None:
    binaries = {}
    for variant in ["baseline", "candidate"]:
        print(f"Building {variant} release", flush=True)
        command([*swift_command(args, variant, "build", "release"), "--verbose", "--product", "RuntimeLeaseHistory"], args.output)
        bin_path = command([*swift_command(args, variant, "build", "release"), "--show-bin-path"], args.output).stdout.strip()
        binary = Path(bin_path) / "RuntimeLeaseHistory"
        binaries[variant] = {"path": str(binary), "sha256": sha256(binary.read_bytes())}
    manifest["binaries"] = binaries
    save(args.output / "manifest.json", manifest)


def test(args: argparse.Namespace) -> None:
    receipts = []
    for configuration in ["debug", "release"]:
        print(f"Testing candidate {configuration}", flush=True)
        result = command(swift_command(args, "candidate", "test", configuration), args.output)
        log = result.stdout + result.stderr
        (args.output / f"candidate-{configuration}-tests.txt").write_text(log)
        if not re.search(r"Test run with 7 tests.*passed", log):
            raise ValueError("Candidate did not execute all seven tests")
        receipts.append({"variant": "candidate", "configuration": configuration, "passed": 7})
        print(f"Testing baseline {configuration} unchanged contract", flush=True)
        result = command([*swift_command(args, "baseline", "test", configuration),
                          "--filter", "|".join(PASS_TESTS)], args.output)
        log = result.stdout + result.stderr
        (args.output / f"baseline-{configuration}-compatible-tests.txt").write_text(log)
        if not re.search(r"Test run with 2 tests.*passed", log):
            raise ValueError("Baseline did not execute both unchanged-contract tests")
        print(f"Testing baseline {configuration} history-bound negative control", flush=True)
        result = command([*swift_command(args, "baseline", "test", configuration),
                          "--skip-build", "--filter", NEGATIVE_TEST], args.output, expected_failure=True)
        log = result.stdout + result.stderr
        (args.output / f"baseline-{configuration}-negative-control.txt").write_text(log)
        issues = [line for line in log.splitlines() if "recorded an issue" in line]
        if (result.returncode != 1 or len(issues) != 2
                or any(NEGATIVE_TEST not in line for line in issues)
                or not any("snapshots.count" in line and "128" in line for line in issues)
                or not any("snapshots.map" in line for line in issues)
                or not re.search(r"Test run with 1 test.*failed.*2 issues", log)
                or "error:" in log.lower() or "signal" in log.lower()):
            raise ValueError("Baseline negative control did not fail only at the two expected history assertions")
        receipts.append({"variant": "baseline", "configuration": configuration,
                         "compatible_passed": list(PASS_TESTS), "expected_failed": NEGATIVE_TEST,
                         "expected_issues": 2})
    save(args.output / "tests.json", receipts)


def case_list(args: argparse.Namespace) -> list[tuple[int, int]]:
    return [(h, 0) for h in args.histories] + [(8192, 256)]


def validate_work(row: dict, history: int, pending: int, cycles: int) -> None:
    checksum = 0
    for index in range(cycles):
        old = 4 + pending + history + index
        for value in [old, old + 1, old + 1]:
            checksum = ((checksum * 16_777_619) ^ value) & MASK
    if row["work"] != {"succeededReleases": cycles, "checksum": checksum}:
        raise ValueError("Replacement API result/checksum changed")


def canonical(args: argparse.Namespace, manifest: dict) -> None:
    receipts = []
    for history, pending in case_list(args):
        for cycles in [0, args.cycles]:
            pair = {}
            for variant in ["baseline", "candidate"]:
                binary = manifest["binaries"][variant]["path"]
                result = command([binary, "canonical", history, pending, cycles, args.snapshot_calls], args.output)
                data = json.loads(result.stdout)
                validate_work(data, history, pending, cycles)
                expected = pending + 4 + min(history + cycles, 128)
                if len(data["snapshots"]) != expected:
                    raise ValueError("Projected diagnostic snapshot count changed")
                released = history + cycles if variant == "baseline" else min(history + cycles, 128)
                if data["retainedActual"] != {"snapshots": pending + 4 + released,
                                              "unresolved": pending + 4, "released": released,
                                              "activeBorrows": pending + 2}:
                    raise ValueError("Canonical checkpoint retained custody/history count changed")
                pair[variant] = data
                save(args.output / f"canonical-{variant}-h{history}-p{pending}-c{cycles}.json", data)
            if pair["baseline"]["snapshots"] != pair["candidate"]["snapshots"]:
                raise ValueError(f"Canonical contract snapshots differ: {history}, {pending}, {cycles}")
            receipts.append({"history": history, "pending": pending, "cycles": cycles,
                             "projected_snapshots": expected, "identical": True,
                             "retained_actual": {v: row["retainedActual"] for v, row in pair.items()}})
    save(args.output / "canonical-comparison.json", receipts)


def measure(args: argparse.Namespace, manifest: dict) -> None:
    if "binaries" not in manifest:
        raise ValueError("Run build before measure")
    if (args.output / "measurements.jsonl").exists():
        raise ValueError("Measurements already exist; use a new output directory")
    for spec in manifest["binaries"].values():
        if sha256(Path(spec["path"]).read_bytes()) != spec["sha256"]:
            raise ValueError("Built executable changed")
    canonical(args, manifest)
    save(args.output / "protocol.json", {"pairs": args.pairs, "cases": case_list(args),
                                        "cycles": args.cycles, "snapshot_calls": args.snapshot_calls,
                                        "order": "AB on even zero-based pairs; BA on odd pairs"})
    rows = []
    for pair_index in range(args.pairs):
        order = ["baseline", "candidate"] if pair_index % 2 == 0 else ["candidate", "baseline"]
        print(f"Timing pair {pair_index + 1}/{args.pairs}: {'/'.join(order)}", flush=True)
        for history, pending in case_list(args):
            for order_index, variant in enumerate(order):
                binary = manifest["binaries"][variant]["path"]
                result = command([binary, "measure", history, pending, args.cycles, args.snapshot_calls], args.output)
                row = json.loads(result.stdout)
                validate_work(row, history, pending, args.cycles)
                released = history + args.cycles if variant == "baseline" else min(history + args.cycles, 128)
                expected_counts = {"snapshots": pending + 4 + released,
                                   "unresolved": pending + 4, "released": released, "activeBorrows": pending + 2}
                if row["retainedAfter"] != expected_counts:
                    raise ValueError("Unresolved custody or retained history count changed")
                snapshot_checksum = 0
                for _ in range(args.snapshot_calls):
                    for value in [expected_counts["snapshots"], 1, 4 + pending + history + args.cycles]:
                        snapshot_checksum = ((snapshot_checksum * 16_777_619) ^ value) & MASK
                if row["snapshotChecksum"] != snapshot_checksum:
                    raise ValueError("Diagnostic snapshot result checksum changed")
                row.update(variant=variant, pair=pair_index, order=order_index)
                rows.append(row)
                with (args.output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row) + "\n")
    summary = []
    for history, pending in case_list(args):
        report = {"historyStart": history, "historyEnd": history + args.cycles, "pending": pending}
        for metric, divisor in [("replacementWallNS", args.cycles), ("replacementCPUNS", args.cycles),
                                ("snapshotWallNS", args.snapshot_calls), ("snapshotCPUNS", args.snapshot_calls)]:
            samples = {v: [r[metric] / divisor for r in rows if r["variant"] == v
                           and r["historyStart"] == history and r["pending"] == pending]
                       for v in ["baseline", "candidate"]}
            before, after = [statistics.median(samples[v]) for v in ["baseline", "candidate"]]
            report[metric + "PerCall"] = {"baselineMedian": before, "candidateMedian": after,
                                          "reductionPercent": 100 * (1 - after / before),
                                          "speedup": before / after,
                                          "range": {v: [min(s), max(s)] for v, s in samples.items()}}
        for phase in ["allocatorAfterSeed", "allocatorAfterCycles"]:
            report[phase + "IncrementBytes"] = {
                v: statistics.median(r[phase] - r["allocatorBeforeFixture"] for r in rows
                                     if r["variant"] == v and r["historyStart"] == history and r["pending"] == pending)
                for v in ["baseline", "candidate"]}
        summary.append(report)
    save(args.output / "summary.json", summary)
    save(args.output / "measurement-receipt.json", {
        "complete": True, "observations": len(rows), "expected": args.pairs * len(case_list(args)) * 2,
        "measurements_sha256": sha256((args.output / "measurements.jsonl").read_bytes()),
        "canonical_comparison_sha256": sha256((args.output / "canonical-comparison.json").read_bytes()),
        "binary_sha256": {v: s["sha256"] for v, s in manifest["binaries"].items()},
    })
    print(json.dumps(summary, indent=2), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "test", "measure", "all"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", default=6, type=int)
    parser.add_argument("--histories", default="0,32,128,1024,8192")
    parser.add_argument("--cycles", default=128, type=int)
    parser.add_argument("--snapshot-calls", default=16, type=int)
    parser.add_argument("--jobs", default=2, type=int)
    args = parser.parse_args()
    args.output = args.output.resolve()
    resolved_swift = shutil.which(args.swift)
    if not resolved_swift:
        parser.error("Swift executable not found; set --swift")
    args.swift = resolved_swift
    args.histories = [int(value) for value in args.histories.split(",")]
    if (args.pairs < 1 or args.cycles < 1 or args.snapshot_calls < 1 or args.jobs < 1
            or any(h < 0 for h in args.histories) or len(set(args.histories)) != len(args.histories)):
        parser.error("Counts must be positive; histories must be distinct nonnegative integers")
    manifest = prepare(args)
    if args.action in {"test", "all"}:
        test(args)
    if args.action in {"build", "all"}:
        build(args, manifest)
    if args.action in {"measure", "all"}:
        measure(args, manifest)
    prepare(args)  # Reject source/harness changes made during the experiment.


if __name__ == "__main__":
    main()
