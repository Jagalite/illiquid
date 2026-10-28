#!/usr/bin/env python3
"""Measure real libass position-only mask reuse against exact main sources.

Requires Apple Silicon macOS, Swift 6.1+, Python 3.10+, and the reviewed native
SDK (or an explicit compatible --libass-prefix). This is a component benchmark,
not a playback, GPU, frame-rate, or energy qualification.
"""
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
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
NATIVE = "Sources/IlliquidNativePlayback/"
SOURCE_PATHS = [
    NATIVE + "Subtitles/LibassContext.swift",
    NATIVE + "Subtitles/ASSBitmapCopy.swift",
    NATIVE + "Subtitles/SubtitleMemoryBudget.swift",
    NATIVE + "Subtitles/FontAttachmentStore.swift",
]
ERROR_PATH = NATIVE + "Presentation/SampleBufferVideoPresenter.swift"
HEADER_PATHS = ["Sources/CLibass/module.modulemap", "Sources/CLibass/include/libass_shim.h"]
EXISTING_TESTS = ["ASSBitmapCopyTests.swift"]
NEW_TEST = "LibassPositionReuseTests.swift"
CASES = ["moving-small", "moving-dense", "static", "content-change", "moving-bounded", "moving-fractional"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def run(command: list[str], output: Path, *, timeout: int = 300) -> str:
    logs = output / "logs"
    logs.mkdir(exist_ok=True)
    number = len(list(logs.glob("*.txt")))
    log = logs / f"{number:04d}.txt"
    start = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    log.write_text(result.stdout + result.stderr)
    append(output / "commands.jsonl", {
        "command": command, "returncode": result.returncode,
        "elapsed_seconds": time.monotonic() - start, "log": str(log.relative_to(output)),
    })
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n{log.read_text()}")
    return result.stdout


def source(variant: str, path: str, output: Path) -> bytes:
    if variant == "baseline":
        return run(["git", "show", f"{BASELINE}:{path}"], output).encode()
    return (ROOT / path).read_bytes()


def prepare(variant: str, destination: Path, output: Path) -> tuple[list[Path], dict]:
    destination.mkdir(parents=True, exist_ok=True)
    paths = []
    hashes = {}
    for relative in SOURCE_PATHS:
        content = source(variant, relative, output)
        target = destination / Path(relative).name
        target.write_bytes(content)
        paths.append(target)
        hashes[relative] = sha(content)
    original = source(variant, ERROR_PATH, output).decode()
    begin = "struct PresentationError:"
    end = "\nfunc checkOSStatus("
    if original.count(begin) != 1 or original.count(end) != 1:
        raise RuntimeError("PresentationError extraction boundaries changed")
    declaration = "import Foundation\n\n" + original[original.index(begin):original.index(end)] + "\n"
    target = destination / "PresentationError.swift"
    target.write_text(declaration)
    paths.append(target)
    hashes[ERROR_PATH] = sha(original.encode())
    hashes["extracted/PresentationError.swift"] = sha(declaration.encode())
    return paths, hashes


def native_flags(prefix: Path) -> list[str]:
    return ["-Xcc", f"-I{prefix / 'include'}", "-L", str(prefix / "lib"),
            "-Xlinker", "-rpath", "-Xlinker", str(prefix / "lib")]


def build(variant: str, output: Path, prefix: Path) -> tuple[Path, dict]:
    directory = output / "build" / variant
    sources, hashes = prepare(variant, directory / "sources", output)
    library = directory / "libIlliquidNativePlayback.dylib"
    module = directory / "IlliquidNativePlayback.swiftmodule"
    run(["swiftc", "-swift-version", "6", "-O", "-whole-module-optimization",
         "-enable-testing", "-warnings-as-errors", "-emit-library", "-emit-module",
         "-module-name", "IlliquidNativePlayback", "-emit-module-path", str(module),
         "-I", str(ROOT / "Sources/CLibass"), *native_flags(prefix),
         *map(str, sources), "-o", str(library)], output)
    executable = directory / "benchmark"
    define = ["-D", "POSITION_REUSE"] if variant == "candidate" else []
    run(["swiftc", "-swift-version", "6", "-O", "-warnings-as-errors", "-parse-as-library",
         *define, "-I", str(directory), "-I", str(ROOT / "Sources/CLibass"),
         "-L", str(directory), "-lIlliquidNativePlayback",
         "-Xlinker", "-rpath", "-Xlinker", str(directory),
         *native_flags(prefix), str(HERE / "Driver.swift"), "-o", str(executable)], output)
    return executable, {"source_sha256": hashes, "executable_sha256": sha(executable.read_bytes()),
                        "library_sha256": sha(library.read_bytes())}


def test(variant: str, output: Path, prefix: Path) -> dict:
    package = output / "build" / f"tests-{variant}"
    _, hashes = prepare(variant, package / "Sources/IlliquidNativePlayback", output)
    shutil.copytree(ROOT / "Sources/CLibass", package / "Sources/CLibass")
    directory = package / "Tests/IlliquidNativePlaybackTests"
    directory.mkdir(parents=True)
    names = EXISTING_TESTS + ([NEW_TEST] if variant == "candidate" else [])
    for name in names:
        shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / name, directory / name)
    (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LibassPositionReuseRegressionTests",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CLibass", pkgConfig: "libass"),
        .target(name: "IlliquidNativePlayback", dependencies: ["CLibass"]),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
""")
    for configuration in ("debug", "release"):
        command = ["swift", "test", "--package-path", str(package), "--jobs", "2",
                   "--no-parallel", "-c", configuration, "-Xswiftc", "-warnings-as-errors",
                   "-Xcc", f"-I{prefix / 'include'}",
                   "-Xlinker", f"-L{prefix / 'lib'}",
                   "-Xlinker", "-rpath", "-Xlinker", str(prefix / "lib")]
        run(command, output, timeout=600)
        print(f"{variant} {configuration} tests passed", flush=True)
    return {"debug": "passed", "release": "passed", "tests": names,
            "source_sha256": hashes}


def measure(executable: Path, case: str, iterations: int, seed: int, output: Path) -> dict:
    row = json.loads(run([str(executable), case, str(iterations), str(seed)], output, timeout=180))
    if (row["case"] != case or row["iterations"] != iterations or row["seed"] != seed
            or row["frames"] != iterations * 64 or row["elapsed_ns"] <= 0
            or not row["verification"]["reference_parity"]):
        raise RuntimeError("Invalid benchmark receipt")
    row["ns_per_frame"] = row["elapsed_ns"] / row["frames"]
    row["cpu_ns_per_frame"] = row["cpu_ns"] / row["frames"]
    return row


def parity(left: dict, right: dict) -> None:
    # Copy counters intentionally differ. Visible pixels, geometry, timing
    # inputs, native change classifications and admitted output must agree.
    for field in ("case", "iterations", "seed", "frames", "checksum", "change_counts",
                  "mask_bytes", "verification", "fixture_sha256", "width", "height",
                  "warmup_checksum", "final_visual_sha256", "maximum_image_count"):
        if left[field] != right[field]:
            raise RuntimeError(f"Baseline/candidate receipt mismatch in {field}")


def summarize(rows: list[dict]) -> dict:
    result = {}
    for case in dict.fromkeys(row["case"] for row in rows):
        subset = [row for row in rows if row["case"] == case]
        by_variant = {}
        for variant in ("baseline", "candidate"):
            data = [row for row in subset if row["variant"] == variant]
            values = [row["ns_per_frame"] for row in data]
            cpu = [row["cpu_ns_per_frame"] for row in data]
            by_variant[variant] = {
                "median_ns_per_frame": statistics.median(values),
                "min_ns_per_frame": min(values), "max_ns_per_frame": max(values),
                "median_cpu_ns_per_frame": statistics.median(cpu),
                "median_copies_per_frame": statistics.median(row["bitmap_copies"] / row["frames"] for row in data),
                "median_copied_mask_bytes_per_frame": statistics.median(row["copied_mask_bytes"] / row["frames"] for row in data),
                "change_counts": data[0]["change_counts"],
            }
        reductions = []
        savings = []
        for pair in sorted({row["pair"] for row in subset}):
            values = {row["variant"]: row for row in subset if row["pair"] == pair}
            parity(values["baseline"], values["candidate"])
            before = values["baseline"]["ns_per_frame"]
            after = values["candidate"]["ns_per_frame"]
            reductions.append(100 * (1 - after / before))
            savings.append(before - after)
        by_variant["paired"] = {
            "median_reduction_percent": statistics.median(reductions),
            "min_reduction_percent": min(reductions), "max_reduction_percent": max(reductions),
            "median_saved_ns_per_frame": statistics.median(savings),
            "candidate_faster_pairs": sum(value > 0 for value in reductions),
            "pairs": len(reductions),
        }
        result[case] = by_variant
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("all", "tests", "measure"), default="all")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--max-sample-ms", type=float, default=1500)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--libass-prefix", type=Path, default=Path("/opt/homebrew/opt/libass"))
    args = parser.parse_args()
    cases = args.cases.split(",")
    if sys.platform != "darwin":
        parser.error("Real CoreGraphics/CryptoKit/libass qualification requires macOS")
    if (args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0
            or args.max_sample_ms < args.target_ms or len(set(cases)) != len(cases)
            or any(case not in CASES for case in cases)):
        parser.error("Use distinct known cases, even pairs >= 2, and valid timing bounds")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty; preserve previous attempts separately")
    output.mkdir(parents=True, exist_ok=True)
    prefix = args.libass_prefix.resolve()
    manifest = {
        "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "baseline_commit": BASELINE,
        "git_head": run(["git", "rev-parse", "HEAD"], output).strip(),
        "git_status": run(["git", "status", "--porcelain"], output).strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "hardware": run(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip(),
        "swift": run(["swiftc", "--version"], output).strip(),
        "libass_prefix": str(prefix),
        "libass_version": run(["pkg-config", "--modversion", "libass"], output).strip(),
        "libass_dylib_sha256": sha((prefix / "lib/libass.9.dylib").read_bytes()),
        "libass_header_sha256": sha((prefix / "include/ass/ass.h").read_bytes()),
        "driver_sha256": sha((HERE / "Driver.swift").read_bytes()),
        "runner_sha256": sha(Path(__file__).read_bytes()),
        "headers_sha256": {path: sha((ROOT / path).read_bytes()) for path in HEADER_PATHS},
        "test_sha256": {name: sha((ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes())
                        for name in EXISTING_TESTS + [NEW_TEST]},
        "arguments": {**vars(args), "output": str(output), "libass_prefix": str(prefix)},
        "extraction": "Four complete production Swift files; exact PresentationError declaration "
                      "from SampleBufferVideoPresenter.swift with only a Foundation import added.",
        "method": "Separately compiled optimized production modules; actual libass 0.17.5; "
                  "same-work fresh-process pairs alternating AB/BA; full visual parity outside "
                  "timing; calibration excluded; all measured samples retained.",
    }
    save(output / "manifest.json", manifest)
    try:
        if args.mode in ("all", "tests"):
            results = {variant: test(variant, output, prefix) for variant in ("baseline", "candidate")}
            save(output / "tests.json", results)
        if args.mode in ("all", "measure"):
            builds = {variant: build(variant, output, prefix) for variant in ("baseline", "candidate")}
            manifest["builds"] = {variant: value[1] for variant, value in builds.items()}
            save(output / "manifest.json", manifest)
            rows = []
            for case in cases:
                calibration = {}
                for variant, (executable, _) in builds.items():
                    first = measure(executable, case, 1, 1000, output)
                    cycles = max(1, min(1000, math.ceil(20_000_000 / first["elapsed_ns"])))
                    probe = measure(executable, case, cycles, 1000, output)
                    calibration[variant] = probe["elapsed_ns"] / cycles
                    append(output / "calibration.jsonl", {"variant": variant, "stage": "single", **first})
                    append(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **probe})
                cycles = max(1, min(math.ceil(args.target_ms * 1e6 / min(calibration.values())),
                                    math.floor(args.max_sample_ms * 1e6 / max(calibration.values()))))
                for pair in range(args.pairs):
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    paired = {}
                    for variant in order:
                        row = measure(builds[variant][0], case, cycles, 2000 + pair, output)
                        row.update(variant=variant, pair=pair, order=list(order))
                        append(output / "measurements.jsonl", row)
                        rows.append(row)
                        paired[variant] = row
                    parity(paired["baseline"], paired["candidate"])
                summary = summarize(rows)
                save(output / "summary.json", summary)
                print(case + " " + json.dumps(summary[case], sort_keys=True), flush=True)
            save(output / "qualification.json", {
                "status": "passed", "pairs_per_case": args.pairs, "cases": cases,
                "visual_parity": "passed", "baseline_commit": BASELINE,
                "scope": "warm native component; no live UI/GPU/whole-player qualification",
            })
    except Exception as error:
        save(output / "failure.json", {"error": str(error)})
        raise


if __name__ == "__main__":
    main()
