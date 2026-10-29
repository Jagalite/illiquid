#!/usr/bin/env python3
"""Qualify and time actual TrackSelectionPreferences sources against a pinned baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TEST = Path("Tests/IlliquidCoreTests/TrackSelectionRankingTests.swift")
NATIVE = sys.platform == "darwin"
VARIANTS = ("baseline", "candidate")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args: list[str], log: Path, cache: Path) -> str:
    log.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    for key, directory in {
        "CLANG_MODULE_CACHE_PATH": cache / "clang",
        "SWIFTPM_MODULECACHE_OVERRIDE": cache / "swift",
        "XDG_CACHE_HOME": cache / "xdg",
        "TMPDIR": cache / "tmp",
    }.items():
        directory.mkdir(parents=True, exist_ok=True)
        environment[key] = str(directory)
    result = subprocess.run(args, text=True, capture_output=True, env=environment)
    log.write_text(json.dumps(args) + "\n\n" + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{result.stderr[-6000:]}")
    return result.stdout


def snapshot(out: Path, include_tests: bool, baseline_dir: Path) -> dict[str, object]:
    pinned = json.loads((baseline_dir / "manifest.json").read_text())
    baseline = (baseline_dir / "TrackSelectionPreferences.swift").read_bytes()
    media = (ROOT / pinned["media_track"]["path"]).read_bytes()
    for label, data in (("selection", baseline), ("media_track", media)):
        blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if digest(data) != pinned[label]["sha256"] or blob != pinned[label]["git_blob"]:
            raise RuntimeError(f"Pinned {label} source changed; requalify the baseline manifest")
    inputs = {
        "baseline/TrackSelectionPreferences.swift": baseline,
        "candidate/TrackSelectionPreferences.swift": (ROOT / pinned["selection"]["path"]).read_bytes(),
        "MediaTrack.swift": media,
        "Harness.swift": (HERE / "Harness.swift").read_bytes(),
        "run.py": Path(__file__).read_bytes(),
        "baseline-manifest.json": (baseline_dir / "manifest.json").read_bytes(),
    }
    if include_tests:
        inputs[TEST.name] = (ROOT / TEST).read_bytes()
    hashes = {}
    for name, data in inputs.items():
        destination = out / "inputs" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        hashes[name] = digest(destination.read_bytes())
    return {"baseline_commit": pinned["commit"], "input_sha256": hashes}


def executable(value: str | None, name: str) -> str:
    selected = value or shutil.which(name)
    if not selected:
        raise RuntimeError(f"{name} is required; specify --{name} or {name.upper()}")
    found = shutil.which(selected)
    if not found:
        raise RuntimeError(f"Cannot find executable: {selected}")
    # Retain the swift/swiftc symlink name: it selects the driver's behavior.
    return str(Path(found).absolute())


def toolchain(args: argparse.Namespace, out: Path) -> dict[str, str]:
    swiftc_choice = args.swiftc or os.environ.get("SWIFTC")
    if NATIVE and swiftc_choice is None:
        # /usr/bin/swiftc is an SDK launcher. Resolve Xcode's actual compiler so
        # the recorded binary hashes describe the toolchain that does the work.
        swiftc_choice = command(["xcrun", "--find", "swiftc"], out / "compiler-path.log", out / "cache").strip()
    swiftc = executable(swiftc_choice, "swiftc")
    swift_choice = args.swift or os.environ.get("SWIFT")
    sibling = Path(swiftc).parent / "swift"
    swift = executable(swift_choice or (str(sibling) if sibling.exists() else None), "swift")
    receipt = {
        "swiftc": swiftc, "swift": swift,
        "version": command([swiftc, "--version"], out / "compiler.log", out / "cache").strip(),
        "swiftc_binary_sha256": file_digest(Path(swiftc).resolve()),
        "swift_binary_sha256": file_digest(Path(swift).resolve()),
    }
    frontend = Path(swiftc).parent / "swift-frontend"
    if frontend.exists():
        receipt.update({"swift_frontend": str(frontend), "swift_frontend_sha256": file_digest(frontend.resolve())})
    if NATIVE:
        receipt.update({
            "macos_sdk_path": command(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                      out / "sdk-path.log", out / "cache").strip(),
            "macos_sdk_version": command(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                                         out / "sdk-version.log", out / "cache").strip(),
        })
    return receipt


def build(variant: str, out: Path, compiler: dict[str, str]) -> Path:
    folder = out / "build" / variant
    folder.mkdir(parents=True, exist_ok=True)
    sources = [out / "inputs/MediaTrack.swift", out / "inputs" / variant / "TrackSelectionPreferences.swift"]
    harness = out / "inputs/Harness.swift"
    library = folder / ("libIlliquidCore.dylib" if NATIVE else "libIlliquidCore.so")
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
             "-module-cache-path", str(out / "cache/modules")]
    if NATIVE:
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0",
                  "-sdk", compiler["macos_sdk_path"]]
    module_args = [compiler["swiftc"], *flags, "-emit-library", "-emit-module",
                   "-module-name", "IlliquidCore", "-emit-module-path", str(folder / "IlliquidCore.swiftmodule"),
                   "-o", str(library), *map(str, sources)]
    command(module_args, folder / "build-module.log", out / "cache")
    binary = folder / "track-selection-ranking"
    driver_args = [compiler["swiftc"], *flags, "-parse-as-library", "-I", str(folder), "-L", str(folder),
                   "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                   str(harness), "-o", str(binary)]
    command(driver_args, folder / "build-harness.log", out / "cache")
    write_json(folder / "manifest.json", {
        "variant": variant, "compiler": compiler, "module_command": module_args, "harness_command": driver_args,
        "sources_sha256": {str(path.relative_to(out)): digest(path.read_bytes()) for path in [*sources, harness]},
        "library_sha256": digest(library.read_bytes()), "executable_sha256": digest(binary.read_bytes()),
        "swiftmodule_sha256": digest((folder / "IlliquidCore.swiftmodule").read_bytes()),
    })
    return binary


def test(variant: str, configuration: str, out: Path, compiler: dict[str, str]) -> None:
    folder = out / f"{variant}-{configuration}"
    sources = folder / "Sources/IlliquidCore"
    tests = folder / "Tests/IlliquidCoreTests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    for origin, destination in (
        (out / "inputs/MediaTrack.swift", sources / "MediaTrack.swift"),
        (out / "inputs" / variant / "TrackSelectionPreferences.swift", sources / "TrackSelectionPreferences.swift"),
        (out / "inputs" / TEST.name, tests / TEST.name),
    ):
        shutil.copyfile(origin, destination)
    (folder / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "TrackSelectionRankingQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
    args = [compiler["swift"], "test", "--package-path", str(folder), "--configuration", configuration,
            "--scratch-path", str(folder / "build"), "--jobs", "2",
            "--cache-path", str(out / "cache/packages"), "--config-path", str(out / "cache/config"),
            "--security-path", str(out / "cache/security"), "-Xswiftc", "-warnings-as-errors",
            "-Xswiftc", "-module-cache-path", "-Xswiftc", str(out / "cache/modules")]
    if not NATIVE:
        args.append("--use-integrated-swift-driver")
    log = folder / "tests.log"
    command(args, log, out / "cache")
    write_json(folder / "manifest.json", {
        "variant": variant, "configuration": configuration, "compiler": compiler, "test_command": args,
        "sources_sha256": {str(path.relative_to(folder)): digest(path.read_bytes())
                           for path in [*sources.glob("*.swift"), *tests.glob("*.swift"), folder / "Package.swift"]},
        "test_log_sha256": digest(log.read_bytes()),
    })
    print(f"PASS {variant} {configuration}: {log}", flush=True)


def compare_pair(pair: list[dict[str, object]]) -> None:
    if len(pair) != 2 or {row["variant"] for row in pair} != set(VARIANTS):
        raise RuntimeError("Incomplete or duplicated measurement pair")
    for field in ("workload", "iterations", "operations", "checksum", "selected_count",
                  "warmup_iterations", "warmup_checksum", "warmup_selected_count"):
        if pair[0][field] != pair[1][field]:
            raise RuntimeError(f"Timing receipts differ in {field}: {pair[0]['workload']}")


def summarize(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    summaries = []
    for workload in dict.fromkeys(row["workload"] for row in rows):
        selected = [row for row in rows if row["workload"] == workload]
        values = {}
        ratios = []
        for round_index in sorted({row["round"] for row in selected}):
            pair = [row for row in selected if row["round"] == round_index]
            compare_pair(pair)
            matched = {row["variant"]: row for row in pair}
            ratios.append(matched["candidate"]["elapsed_ns"] / matched["baseline"]["elapsed_ns"])
        for variant in VARIANTS:
            samples = [row["elapsed_ns"] / row["operations"] for row in selected if row["variant"] == variant]
            values[variant] = {"median_ns": statistics.median(samples), "min_ns": min(samples),
                               "max_ns": max(samples), "samples": len(samples)}
        baseline, candidate = values["baseline"]["median_ns"], values["candidate"]["median_ns"]
        values.update({"workload": workload, "change_percent": (candidate / baseline - 1) * 100,
                       "saved_ns": baseline - candidate, "paired_ratio_median": statistics.median(ratios),
                       "paired_ratios": ratios, "iterations": selected[0]["iterations"]})
        summaries.append(values)
    return summaries


def benchmark(out: Path, args: argparse.Namespace, compiler: dict[str, str]) -> None:
    binaries = {variant: build(variant, out, compiler) for variant in VARIANTS}
    verification, workload_lists = {}, {}
    for variant, binary in binaries.items():
        verification[variant] = json.loads(command([str(binary), "verify"], out / f"verify-{variant}.log", out / "cache"))
        workload_lists[variant] = json.loads(command([str(binary), "list"], out / f"list-{variant}.log", out / "cache"))["workloads"]
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Full selected-ID differential receipts differ; inspect verification logs")
    if workload_lists["baseline"] != workload_lists["candidate"]:
        raise RuntimeError("Variant workload lists differ")
    write_json(out / "verification.json", verification["candidate"])
    print(f"PASS full differential: {verification['candidate']['comparisons']} selections", flush=True)
    workloads = workload_lists["candidate"]

    def measure(variant: str, workload: str, iterations: int, label: str) -> dict[str, object]:
        log = out / "processes" / f"{label}-{workload}-{variant}.log"
        command_args = [str(binaries[variant]), "benchmark", workload, str(iterations)]
        row = json.loads(command(command_args, log, out / "cache"))
        if row["workload"] != workload or row["iterations"] != iterations or row["operations"] <= 0 or row["elapsed_ns"] <= 0:
            raise RuntimeError(f"Invalid benchmark receipt: {row}")
        row.update({"variant": variant, "command": command_args, "process_log_sha256": digest(log.read_bytes())})
        return row

    counts = {}
    with (out / "calibration.jsonl").open("w") as receipt:
        for index, workload in enumerate(workloads):
            count = args.iterations or 1_000
            if args.iterations is None:
                for attempt in range(8):
                    order = VARIANTS if (index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
                    pair = [measure(variant, workload, count, f"calibration-{attempt:02d}") for variant in order]
                    compare_pair(pair)
                    for row in pair:
                        row.update({"attempt": attempt, "order": list(order)})
                        receipt.write(json.dumps(row, sort_keys=True) + "\n")
                    receipt.flush()
                    fastest = min(row["elapsed_ns"] for row in pair)
                    if fastest >= args.target_ms * 1_000_000:
                        break
                    count = max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / fastest * 1.1))
                else:
                    raise RuntimeError(f"Unable to calibrate {workload}; choose explicit --iterations")
            counts[workload] = count
    write_json(out / "iteration-counts.json", counts)
    rows = []
    with (out / "measurements.jsonl").open("w") as receipt:
        for round_index in range(args.rounds):
            for index, workload in enumerate(workloads):
                order = VARIANTS if (round_index + index) % 2 == 0 else tuple(reversed(VARIANTS))
                pair = []
                for variant in order:
                    row = measure(variant, workload, counts[workload], f"round-{round_index:02d}")
                    row.update({"round": round_index, "order": list(order)})
                    receipt.write(json.dumps(row, sort_keys=True) + "\n")
                    receipt.flush()
                    rows.append(row)
                    pair.append(row)
                compare_pair(pair)
            print(f"Completed paired round {round_index + 1}/{args.rounds}", flush=True)
    summary = summarize(rows)
    write_json(out / "summary.json", summary)
    for item in summary:
        print(f"{item['workload']}: {item['baseline']['median_ns']:.1f} -> "
              f"{item['candidate']['median_ns']:.1f} ns/selection ({item['change_percent']:+.2f}%)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("test", "benchmark", "summarize"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--variant", choices=(*VARIANTS, "both"), default="both")
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--iterations", type=int, help="Fixed iterations per workload; otherwise calibrate both variants")
    parser.add_argument("--target-ms", type=float, default=20.0, help="Calibration target for the faster variant")
    parser.add_argument("--baseline-dir", type=Path, default=HERE / "baseline",
                        help="Frozen source and manifest directory (defaults to the original ranking baseline)")
    parser.add_argument("--swiftc")
    parser.add_argument("--swift")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2 or (args.iterations is not None and args.iterations <= 0) or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use even --rounds >= 2, positive --iterations, and a finite positive --target-ms")
    out = args.output.resolve()
    if args.mode != "summarize" and out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("Use a fresh --output directory to preserve the previous run's provenance")
    out.mkdir(parents=True, exist_ok=True)
    if args.mode == "summarize":
        write_json(out / "summary.json", summarize([json.loads(line) for line in (out / "measurements.jsonl").read_text().splitlines()]))
        return
    receipt = snapshot(out, args.mode == "test", args.baseline_dir.resolve())
    compiler = toolchain(args, out)
    receipt.update({"recorded_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
                    "machine": platform.machine(), "cpu_count": os.cpu_count(), "python": sys.version,
                    "compiler": compiler, "macos_target": "26.0" if NATIVE else None,
                    "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
                    "method": "Unmodified actual sources; separate optimized shared modules; fresh-process serial balanced AB/BA pairs; full selected-ID parity before timing."})
    write_json(out / "manifest.json", receipt)
    if args.mode == "test":
        for variant in VARIANTS if args.variant == "both" else (args.variant,):
            test(variant, args.configuration, out, compiler)
    else:
        benchmark(out, args, compiler)


if __name__ == "__main__":
    main()
