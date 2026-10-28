#!/usr/bin/env python3
"""Measure actual checkpoint construction and JSON encoding on native macOS."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PLAYER = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE = [
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
    "Sources/IlliquidCore/Persistence/LegacyPreferencesMigration.swift",
]
TESTS = [
    "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift",
    "Tests/IlliquidCoreTests/PlaylistSessionRecordTests.swift",
]
VARIANTS = ("baseline", "candidate")
MASK = (1 << 64) - 1


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Run:
    def __init__(self, output: Path):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.number = 0

    def command(self, args: list, label: str, cwd: Path = ROOT) -> str:
        self.number += 1
        log = self.logs / f"{self.number:04d}-{label}.log"
        arguments = [str(arg) for arg in args]
        env = dict(os.environ)
        env["CLANG_MODULE_CACHE_PATH"] = str(self.output / "module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(self.output / "module-cache")
        start = time.monotonic()
        result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True)
        log.write_bytes(result.stdout + b"\n--- stderr ---\n" + result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"args": arguments, "cwd": str(cwd),
                "log": str(log.relative_to(self.output)), "returncode": result.returncode,
                "elapsed_seconds": time.monotonic() - start}) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {log}\n"
                               + result.stderr.decode(errors="replace")[-6000:])
        return result.stdout.decode()


def snapshots(run: Run, manifest: dict) -> dict[str, Path]:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline = (HERE / "baseline/PlaybackCheckpointWriter.swift").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
    if digest(baseline) != pinned["sha256"] or blob != pinned["git_blob"]:
        raise ValueError("Frozen baseline does not match its source manifest")
    manifest["baseline"] = pinned
    manifest["source_sha256"] = {}
    common = run.output / "sources/core"
    common.mkdir(parents=True)
    # Full, unchanged production files. No copied types, source extraction,
    # fake URL implementation, or substitute persistence record is compiled.
    for path in CORE:
        data = (ROOT / path).read_bytes()
        (common / Path(path).name).write_bytes(data)
        manifest["source_sha256"][path] = digest(data)
    players = {}
    for variant in VARIANTS:
        data = baseline if variant == "baseline" else (ROOT / PLAYER).read_bytes()
        path = run.output / "sources" / variant / "PlaybackCheckpointWriter.swift"
        path.parent.mkdir()
        path.write_bytes(data)
        players[variant] = path
        manifest[variant + "_player_sha256"] = digest(data)
    for path in TESTS:
        data = (ROOT / path).read_bytes()
        target = run.output / "sources/tests" / Path(path).name
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(data)
        manifest["source_sha256"][path] = digest(data)
    for name in ("Driver.swift", "run.py"):
        data = (HERE / name).read_bytes()
        (run.output / "sources" / name).write_bytes(data)
        manifest[name + "_sha256"] = digest(data)
    return players


def tests(run: Run, players: dict, swift: str, summary: dict) -> None:
    summary["tests"] = []
    for variant, player in players.items():
        package = run.output / "build" / (variant + "-tests")
        core = package / "Sources/IlliquidCore"
        target = package / "Sources/IlliquidPlayer"
        suite = package / "Tests/CheckpointTests"
        for directory in (core, target, suite):
            directory.mkdir(parents=True)
        for source in (run.output / "sources/core").glob("*.swift"):
            shutil.copyfile(source, core / source.name)
        shutil.copyfile(player, target / player.name)
        for source in (run.output / "sources/tests").glob("*.swift"):
            shutil.copyfile(source, suite / source.name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlaybackCheckpointQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .testTarget(name: "CheckpointTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    ])
''')
        for configuration in ("debug", "release"):
            run.command([swift, "test", "--package-path", package,
                "--scratch-path", package / "build", "--cache-path", package / "cache",
                "--config-path", package / "config", "--security-path", package / "security",
                "--no-parallel", "-c", configuration], f"tests-{variant}-{configuration}")
            summary["tests"].append({"variant": variant, "configuration": configuration, "passed": True})
            save(run.output / "summary.json", summary)
            print(f"PASS {variant} {configuration} semantic tests", flush=True)


def build(run: Run, players: dict, swiftc: str, manifest: dict) -> dict[str, Path]:
    sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").strip()
    core = run.output / "build/core"
    core.mkdir(parents=True, exist_ok=True)
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
             "-module-cache-path", run.output / "module-cache", "-sdk", sdk,
             "-target", f"{platform.machine()}-apple-macosx26.0"]
    manifest["flags"] = [str(value) for value in flags]
    shared = core / "libIlliquidCore.dylib"
    run.command([swiftc, *flags, "-parse-as-library", "-emit-library", "-emit-module", "-enable-testing",
        "-module-name", "IlliquidCore", "-emit-module-path", core / "IlliquidCore.swiftmodule",
        *sorted((run.output / "sources/core").glob("*.swift")), "-o", shared], "build-core")
    manifest["core_library_sha256"] = digest(shared.read_bytes())
    binaries = {}
    manifest["binaries"] = {}
    for variant, player in players.items():
        folder = run.output / "build" / variant
        folder.mkdir()
        library = folder / "libIlliquidPlayer.dylib"
        link_core = ["-I", core, "-L", core, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", core]
        run.command([swiftc, *flags, "-parse-as-library", "-emit-library", "-emit-module", "-enable-testing",
            "-module-name", "IlliquidPlayer", "-emit-module-path", folder / "IlliquidPlayer.swiftmodule",
            *link_core, player, "-o", library], f"build-{variant}-player")
        binary = folder / "driver"
        run.command([swiftc, *flags, "-parse-as-library", *link_core, "-I", folder, "-L", folder,
            "-lIlliquidPlayer", "-Xlinker", "-rpath", "-Xlinker", folder,
            run.output / "sources/Driver.swift", "-o", binary], f"build-{variant}-driver")
        binaries[variant] = binary
        manifest["binaries"][variant] = {"driver_sha256": digest(binary.read_bytes()),
                                        "player_library_sha256": digest(library.read_bytes())}
    return binaries


def verify(run: Run, binaries: dict) -> dict[str, dict]:
    records = {}
    for variant, binary in binaries.items():
        raw = run.command([binary, "verify"], f"verify-{variant}")
        (run.output / f"verification-{variant}.json.gz").write_bytes(gzip.compress(raw.encode(), mtime=0))
        rows = json.loads(raw)
        records[variant] = {row["case"]: row for row in rows}
        if len(records[variant]) != len(rows):
            raise ValueError("Duplicate verification case")
    if records["baseline"].keys() != records["candidate"].keys():
        raise ValueError("Baseline/candidate case lists differ")
    verified = {}
    for name, baseline in records["baseline"].items():
        candidate = records["candidate"][name]
        left = base64.b64decode(baseline["output_base64"], validate=True)
        right = base64.b64decode(candidate["output_base64"], validate=True)
        if left != right:
            raise ValueError(f"Full encoded record differs: {name}")
        for key in ("scope", "count", "selection", "token", "output_bytes", "output_fnv1a"):
            if baseline[key] != candidate[key]:
                raise ValueError(f"Verification metadata differs: {name}: {key}")
        verified[name] = {key: value for key, value in candidate.items() if key != "output_base64"}
        verified[name]["output_sha256"] = digest(right)
    save(run.output / "verification.json", verified)
    print(f"PASS exact serialized records: {len(verified)} workloads", flush=True)
    return verified


def validate(row: dict, expected: dict, iterations: int) -> None:
    for key in ("case", "scope", "count", "selection", "token", "output_bytes", "output_fnv1a"):
        if row[key] != expected[key]:
            raise ValueError(f"Incorrect receipt: {expected['case']}: {key}")
    checksum = (iterations * int(expected["token"]) + 131 * iterations * (iterations - 1) // 2) & MASK
    if row["iterations"] != iterations or int(row["checksum"]) != checksum:
        raise ValueError("Wrong iteration count/checksum")
    if row["elapsed_ns"] <= 0 or row["cpu_ns"] <= 0:
        raise ValueError("Invalid measured duration")


def summarize(output: Path) -> list[dict]:
    config = json.loads((output / "benchmark.json").read_text())
    verified = json.loads((output / "verification.json").read_text())
    rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
    cases, pairs = config["cases"], config["pairs"]
    expected_order = []
    for pair in range(pairs):
        order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
        traversal = cases if pair % 2 == 0 else cases[::-1]
        expected_order.extend((pair, case, variant, position)
                              for case in traversal for position, variant in enumerate(order))
    if len(rows) != len(expected_order):
        raise ValueError("Incomplete observation cohort")
    for sequence, (row, identity) in enumerate(zip(rows, expected_order)):
        if row["sequence"] != sequence or (row["pair"], row["case"], row["variant"], row["pair_position"]) != identity:
            raise ValueError("Duplicate, missing, or incorrectly ordered observation")
        validate(row, verified[row["case"]], config["iterations"][row["case"]])
    results = []
    for name in cases:
        selected = [row for row in rows if row["case"] == name]
        result = {"case": name, "scope": verified[name]["scope"], "count": verified[name]["count"],
                  "pairs": pairs, "iterations_per_sample": config["iterations"][name]}
        for metric in ("elapsed_ns", "cpu_ns"):
            values = {variant: [row[metric] / row["iterations"] for row in selected if row["variant"] == variant]
                      for variant in VARIANTS}
            ratios = []
            for pair in range(pairs):
                paired = {row["variant"]: row for row in selected if row["pair"] == pair}
                ratios.append(paired["candidate"][metric] / paired["baseline"][metric])
            result[metric] = {variant: {"median_per_operation": statistics.median(samples),
                "min_per_operation": min(samples), "max_per_operation": max(samples)}
                for variant, samples in values.items()}
            result[metric].update({"paired_candidate_over_baseline": ratios,
                "median_paired_ratio": statistics.median(ratios),
                "median_paired_change_percent": (statistics.median(ratios) - 1) * 100})
        results.append(result)
    save(output / "timing-summary.json", results)
    print(f"PASS complete ordered cohort: {len(rows)} observations", flush=True)
    for result in results:
        print(f"{result['case']}: {result['elapsed_ns']['median_paired_change_percent']:+.1f}% wall time", flush=True)
    return results


def measure(run: Run, binaries: dict, verified: dict, args: argparse.Namespace) -> None:
    cases = args.case or list(verified)
    if len(cases) != len(set(cases)) or any(case not in verified for case in cases):
        raise ValueError("--case must name unique verification cases")
    counts, calibration = {}, []
    for case in cases:
        count = 1
        for attempt in range(4):
            row = json.loads(run.command([binaries["baseline"], "measure", case, count], f"calibrate-{case}-{attempt}"))
            validate(row, verified[case], count)
            calibration.append(row)
            if row["elapsed_ns"] >= args.target_ms * 500_000 or count >= 100_000:
                break
            count = min(100_000, max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / row["elapsed_ns"])))
        counts[case] = count
    save(run.output / "calibration.json", calibration)
    save(run.output / "benchmark.json", {"cases": cases, "pairs": args.pairs, "iterations": counts,
        "target_ms": args.target_ms,
        "protocol": "Fresh processes; adjacent AB/BA pairs; reversed case traversal on alternate pairs; no samples discarded."})
    sequence = 0
    with (run.output / "measurements.jsonl").open("w") as stream:
        for pair in range(args.pairs):
            order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
            traversal = cases if pair % 2 == 0 else cases[::-1]
            for case in traversal:
                for position, variant in enumerate(order):
                    row = json.loads(run.command([binaries[variant], "measure", case, counts[case]],
                        f"pair-{pair}-{case}-{variant}"))
                    validate(row, verified[case], counts[case])
                    row.update({"sequence": sequence, "pair": pair, "pair_position": position, "variant": variant})
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    sequence += 1
            print(f"Finished paired round {pair + 1}/{args.pairs}", flush=True)
    summarize(run.output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mode", choices=("all", "tests", "benchmark", "summarize"), default="all")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--case", action="append")
    args = parser.parse_args()
    output = args.output.resolve()
    if args.mode == "summarize":
        summarize(output)
        return
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target duration")
    if platform.system() != "Darwin":
        parser.error("This exact-source native component harness requires macOS 26 and Xcode")
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    run = Run(output)
    summary = {"status": "running", "mode": args.mode}
    manifest = {"platform": platform.platform(), "machine": platform.machine(),
        "python": platform.python_version(), "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "arguments": vars(args) | {"output": str(output)},
        "kyoto_available": Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file()}
    try:
        swift = run.command(["xcrun", "--find", "swift"], "find-swift").strip()
        swiftc = run.command(["xcrun", "--find", "swiftc"], "find-swiftc").strip()
        manifest["compiler"] = run.command([swiftc, "--version"], "compiler-version").strip()
        manifest["xcode"] = run.command(["xcodebuild", "-version"], "xcode-version").strip()
        manifest["compiler_sha256"] = digest(Path(swiftc).read_bytes())
        players = snapshots(run, manifest)
        save(output / "manifest.json", manifest)
        if args.mode in ("all", "tests"):
            tests(run, players, swift, summary)
        if args.mode in ("all", "benchmark"):
            binaries = build(run, players, swiftc, manifest)
            save(output / "manifest.json", manifest)
            verified = verify(run, binaries)
            measure(run, binaries, verified, args)
        summary["status"] = "passed"
        print("CHECKPOINT_QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
