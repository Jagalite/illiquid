#!/usr/bin/env python3
"""Compare complete production checkpoint construction in serial AB/BA processes."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TARGET = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
    "Sources/IlliquidCore/Persistence/LegacyPreferencesMigration.swift",
    "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
]
CORE_TESTS = [
    "PlaylistSessionRecordTests.swift", "PlaybackSessionStoreTests.swift",
    "PlaylistMutationTests.swift", "PlaylistOrderRestorationTests.swift",
    "PlaylistDeduplicationTests.swift", "FolderPlaylistTests.swift",
    "NaturalFilenameOrderingTests.swift", "LocalMediaSourceValidationTests.swift",
]
VARIANTS = ("baseline", "candidate")
METRICS = ("wallNanoseconds", "cpuNanoseconds")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def workloads(quick: bool) -> list[dict]:
    counts = [0, 1, 32, 1000] if quick else [0, 1, 32, 1000, 10000]
    scenarios = ["folder-first", "folder-last", "folder-missing",
                 "loose-last", "loose-missing", "remote"]
    result = [dict(id=f"{scenario}-{count}", scenario=scenario, count=count)
              for count in counts for scenario in scenarios]
    if not quick:
        result += [dict(id=f"{scenario}-{count}", scenario=scenario, count=count)
                   for count in [32, 1000, 10000]
                   for scenario in ["folder-middle", "loose-first", "loose-middle"]]
    for row in result:
        row["primary"] = row["count"] >= 1000 and row["scenario"] in {
            "folder-last", "folder-missing", "loose-last", "loose-missing"}
    return result


class Run:
    def __init__(self, output: Path):
        self.output = output
        (output / "logs").mkdir()
        self.number = 0

    def command(self, args: list, label: str) -> str:
        args = [str(a) for a in args]
        self.number += 1
        log = self.output / "logs" / f"{self.number:04d}-{label}.log"
        started = time.monotonic()
        env = os.environ.copy()
        cache = str(self.output / "module-cache")
        env.update(CLANG_MODULE_CACHE_PATH=cache, SWIFT_MODULECACHE_PATH=cache,
                   SWIFTPM_MODULECACHE_OVERRIDE=cache)
        completed = subprocess.run(args, cwd=ROOT, capture_output=True, env=env, timeout=1200)
        log.write_bytes(completed.stdout + completed.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(command=args, returncode=completed.returncode,
                seconds=time.monotonic() - started, log=str(log.relative_to(self.output)))) + "\n")
        if completed.returncode:
            raise RuntimeError(f"Command failed ({completed.returncode}); {log}\n"
                               + completed.stderr.decode(errors="replace")[-12000:])
        return completed.stdout.decode().strip()


def stage(run: Run, manifest: dict, baseline: str, frozen: dict[str, bytes]) -> dict:
    packages = {}
    for variant in VARIANTS:
        package = run.output / "build" / variant
        packages[variant] = package
        receipts = {}
        for relative in [*CORE, TARGET]:
            raw = git("show", f"{baseline}:{relative}") if variant == "baseline" else frozen[relative]
            data, source = raw, baseline if variant == "baseline" else "current worktree"
            if platform.system() == "Linux" and relative.endswith("/LifecyclePerformance.swift"):
                data = frozen["Benchmarks/CheckpointIdentity/LinuxLifecyclePerformance.swift"]
                source = "Linux-only disabled diagnostic flag"
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            receipts[relative] = dict(production_sha256=digest(raw), compiled_sha256=digest(data),
                                      source=source, transformation="none" if data == raw else "Linux diagnostic shim")
        manifest["sources"][variant] = receipts
        for name in CORE_TESTS:
            relative = "Tests/IlliquidCoreTests/" + name
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(frozen[relative])
            manifest["tests"][relative] = digest(target.read_bytes())
        relative = "Tests/IlliquidPlayerTests/PlaybackCheckpointWriterTests.swift"
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(frozen[relative])
        manifest["tests"][relative] = digest(target.read_bytes())
        (package / "Package.swift").write_text(
            '// swift-tools-version: 6.1\nimport PackageDescription\n'
            'let package = Package(name: "CheckpointIdentityQualification", platforms: [.macOS("26.0")],\n'
            'targets: [.target(name: "IlliquidCore"),\n'
            '.target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),\n'
            '.testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),\n'
            '.testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidPlayer", "IlliquidCore"])],\n'
            'swiftLanguageModes: [.v6])\n')
    differences = [p for p in [*CORE, TARGET]
                   if manifest["sources"]["baseline"][p]["production_sha256"]
                   != manifest["sources"]["candidate"][p]["production_sha256"]]
    if differences != [TARGET]:
        raise ValueError(f"Only {TARGET} may change; found {differences}")
    return packages


def build(run: Run, packages: dict, swiftc: str, manifest: dict) -> dict:
    binaries = {}
    native = platform.system() == "Darwin"
    target_flags = ["-target", f"{platform.machine()}-apple-macosx26.0"] if native else []
    if native:
        target_flags += ["-sdk", run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")]
    for variant, package in packages.items():
        directory = package / "measured"
        directory.mkdir()
        suffix = ".dylib" if native else ".so"
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6",
                 "-warnings-as-errors", "-module-cache-path", directory / "module-cache", *target_flags]
        common = [swiftc, *flags, "-parse-as-library"]
        core = directory / ("libIlliquidCore" + suffix)
        player = directory / ("libIlliquidPlayer" + suffix)
        run.command([*common, "-enable-testing", "-emit-library", "-emit-module",
            "-module-name", "IlliquidCore", "-emit-module-path", directory / "IlliquidCore.swiftmodule",
            *[package / p for p in CORE], "-o", core], f"{variant}-core-build")
        link = ["-I", directory, "-L", directory, "-Xlinker", "-rpath", "-Xlinker", directory]
        run.command([*common, "-enable-testing", "-emit-library", "-emit-module",
            "-module-name", "IlliquidPlayer", "-emit-module-path", directory / "IlliquidPlayer.swiftmodule",
            *link, "-lIlliquidCore", package / TARGET, "-o", player], f"{variant}-player-build")
        binary = directory / "checkpoint-benchmark"
        run.command([*common, *link, "-lIlliquidCore", "-lIlliquidPlayer",
                     run.output / "inputs/Benchmarks/CheckpointIdentity/Driver.swift",
                     "-o", binary], f"{variant}-driver-build")
        binaries[variant] = binary
        manifest["binaries"][variant] = {
            p.name: digest(p.read_bytes()) for p in [binary, core, player]}
    return binaries


def run_tests(run: Run, packages: dict, swift: str) -> list[dict]:
    results = []
    for variant, package in packages.items():
        for configuration in ["debug", "release"]:
            command = [swift, "test", "--package-path", package,
                       "--scratch-path", package / "tests-build",
                       "--cache-path", package / "cache", "--config-path", package / "config",
                       "--security-path", package / "security", "--jobs", "2",
                       "--configuration", configuration, "--no-parallel",
                       "-Xswiftc", "-warnings-as-errors"]
            if platform.system() == "Linux":
                command.append("--use-integrated-swift-driver")
            run.command(command, f"tests-{variant}-{configuration}")
            results.append(dict(variant=variant, configuration=configuration, passed=True))
            save(run.output / "tests.json", results)
    return results


def summarize(rows: list[dict], cases: list[dict], pairs: int) -> list[dict]:
    summary = []
    for case in cases:
        cell = [r for r in rows if r["workload"] == case["id"]]
        expected = {(v, p) for v in VARIANTS for p in range(pairs)}
        if len(cell) != len(expected) or {(r["variant"], r["pair"]) for r in cell} != expected:
            raise ValueError("Unbalanced measurement cohort: " + case["id"])
        metrics = {}
        for metric in METRICS:
            data = {v: [next(r[metric] / r["iterations"] for r in cell
                            if r["variant"] == v and r["pair"] == p)
                        for p in range(pairs)] for v in VARIANTS}
            medians = {v: statistics.median(data[v]) for v in VARIANTS}
            savings = [100 * (1 - b / a) for a, b in zip(data["baseline"], data["candidate"])]
            metrics[metric] = dict(baseline_median_ns=medians["baseline"],
                candidate_median_ns=medians["candidate"],
                median_reduction_percent=100 * (1 - medians["candidate"] / medians["baseline"]),
                paired_reduction_percent=savings, paired_median_reduction_percent=statistics.median(savings),
                faster_pairs=sum(s > 0 for s in savings),
                baseline_range_ns=[min(data["baseline"]), max(data["baseline"])],
                candidate_range_ns=[min(data["candidate"]), max(data["candidate"])])
        summary.append(dict(**case, pairs=pairs, metrics=metrics))
    return summary


def measure(run: Run, binaries: dict, cases: list[dict], pairs: int, seconds: float) -> dict:
    semantics = run.output / "semantics"
    semantics.mkdir()
    rows, calibration, parity = [], [], []
    for case in cases:
        print("Measure " + case["id"], flush=True)
        outputs = {}
        for variant in VARIANTS:
            path = semantics / f"{case['id']}-{variant}.json"
            run.command([binaries[variant], "verify", case["scenario"], case["count"], path],
                        f"verify-{case['id']}-{variant}")
            outputs[variant] = path.read_bytes()
        if outputs["baseline"] != outputs["candidate"]:
            raise ValueError("Complete JSON parity failed: " + case["id"])
        reference = outputs["baseline"]
        # Preserve complete semantic output compactly; not just a digest.
        packed = gzip.compress(reference, mtime=0)
        (semantics / f"{case['id']}.json.gz").write_bytes(packed)
        for variant in VARIANTS:
            (semantics / f"{case['id']}-{variant}.json").unlink()
        parity.append(dict(workload=case["id"], bytes=len(reference),
                           sha256=digest(reference), byte_equal=True))
        estimates = []
        for variant in VARIANTS:
            row = json.loads(run.command([binaries[variant], "measure",
                case["scenario"], case["count"], "3"], f"calibrate-{case['id']}-{variant}"))
            estimates.append(row["wallNanoseconds"] / row["iterations"])
            calibration.append(dict(**row, workload=case["id"], variant=variant))
        iterations = min(1_000_000, max(1, math.ceil(seconds * 1e9 / min(estimates))))
        for pair in range(pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            checksums = []
            for variant in order:
                final = semantics / "last-timed-record.json"
                row = json.loads(run.command([binaries[variant], "measure", case["scenario"],
                    case["count"], iterations, final], f"measure-{case['id']}-{pair}-{variant}"))
                if final.read_bytes() != reference:
                    raise ValueError("Final timed record changed: " + case["id"])
                final.unlink()
                if (row["scenario"], row["count"], row["iterations"]) != (
                        case["scenario"], case["count"], iterations):
                    raise ValueError("Measurement identity mismatch")
                if not row["timestampInBounds"] or any(row[m] <= 0 for m in METRICS):
                    raise ValueError("Invalid timer/output receipt")
                row.update(workload=case["id"], variant=variant, pair=pair,
                           order=list(order), semantic_sha256=digest(reference))
                checksums.append(row["checksum"])
                rows.append(row)
                with (run.output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if checksums[0] != checksums[1]:
                raise ValueError("Timed checksum mismatch: " + case["id"])
        save(run.output / "calibration.json", calibration)
        save(run.output / "verification.json", dict(complete_record_parity=True, records=parity))
        save(run.output / "summary.json", summarize(rows, cases[:len(parity)], pairs))
    summary = summarize(rows, cases, pairs)
    primary = [s for s in summary if s["primary"]]
    gate = dict(
        primary_medians_pass=all(m["median_reduction_percent"] >= 15
            for s in primary for m in s["metrics"].values()),
        primary_pair_consistency_pass=all(m["faster_pairs"] >= math.ceil(7 * pairs / 8)
            for s in primary for m in s["metrics"].values()),
        control_flags=[dict(workload=s["id"], metric=name,
                           reduction_percent=m["median_reduction_percent"])
            for s in summary if not s["primary"]
            for name, m in s["metrics"].items() if m["median_reduction_percent"] < -10],
        native_platform=platform.system() == "Darwin",
        pairs=pairs, workloads=len(summary),
    )
    save(run.output / "acceptance.json", gate)
    return gate


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int)
    parser.add_argument("--target-seconds", type=float)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--run-tests", action="store_true")
    parser.add_argument("--enforce-performance", action="store_true")
    args = parser.parse_args()
    pairs = args.pairs if args.pairs is not None else (4 if args.quick else 8)
    seconds = args.target_seconds if args.target_seconds is not None else (0.04 if args.quick else 0.15)
    if pairs < 2 or pairs % 2 or not math.isfinite(seconds) or seconds <= 0:
        parser.error("Use an even positive pair count and a finite positive target duration")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be new and empty")
    run = Run(output)
    swift = str(Path(args.swift).absolute())
    if not Path(swift).is_file():
        found = shutil.which(args.swift)
        if found is None:
            parser.error("Swift executable not found")
        swift = found
    swiftc = str(Path(swift).with_name("swiftc"))
    baseline = git("rev-parse", args.baseline + "^{commit}").decode().strip()
    inputs = [*CORE, TARGET,
              *["Tests/IlliquidCoreTests/" + name for name in CORE_TESTS],
              "Tests/IlliquidPlayerTests/PlaybackCheckpointWriterTests.swift",
              *["Benchmarks/CheckpointIdentity/" + name for name in [
                  "Driver.swift", "run.py", "LinuxLifecyclePerformance.swift", "README.md"]]]
    # Freeze shared support, driver and tests once before building either arm.
    # Both arms use these bytes even if a later worktree edit happens mid-run.
    frozen = {relative: (ROOT / relative).read_bytes() for relative in inputs}
    for relative, data in frozen.items():
        destination = output / "inputs" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    manifest = dict(schema=1, baseline_commit=baseline,
        candidate_head=git("rev-parse", "HEAD").decode().strip(),
        candidate_status=git("status", "--short").decode().splitlines(),
        compiler=run.command([swift, "--version"], "compiler"),
        platform=platform.platform(), machine=platform.machine(),
        cpu_count=os.cpu_count(), pairs=pairs, target_seconds=seconds, quick=args.quick,
        measurement="Complete record construction; excludes JSON, I/O and queue scheduling",
        method="Separate optimized modules; fresh processes; serial balanced AB/BA",
        linux_diagnostic_shim=platform.system() == "Linux",
        sources={}, binaries={}, tests={},
        harnesses={relative: digest(data) for relative, data in frozen.items()
                   if relative.startswith("Benchmarks/")})
    packages = stage(run, manifest, baseline, frozen)
    save(output / "manifest.json", manifest)
    binaries = build(run, packages, swiftc, manifest)
    save(output / "manifest.json", manifest)
    tests = run_tests(run, packages, swift) if args.run_tests else []
    cases = workloads(args.quick)
    save(output / "workloads.json", cases)
    acceptance = measure(run, binaries, cases, pairs, seconds)
    acceptance["qualifying_cohort"] = (
        platform.system() == "Darwin" and not args.quick and pairs >= 8 and len(tests) == 4)
    acceptance["accepted"] = (acceptance["qualifying_cohort"]
        and acceptance["primary_medians_pass"] and acceptance["primary_pair_consistency_pass"]
        and not acceptance["control_flags"])
    save(output / "acceptance.json", acceptance)
    print(json.dumps(acceptance, indent=2), flush=True)
    if args.enforce_performance and not acceptance["accepted"]:
        raise SystemExit("Native performance acceptance was not met; inspect the retained evidence.")


if __name__ == "__main__":
    main()
