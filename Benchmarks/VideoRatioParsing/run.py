#!/usr/bin/env python3
"""Native macOS differential tests and paired timings for production ratio parsing."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
GEOMETRY = "Sources/IlliquidCore/Player/VideoPresentationGeometry.swift"
SOURCES = [GEOMETRY, "Sources/IlliquidCore/Player/PlaybackModels.swift",
           "Sources/IlliquidCore/Player/MediaSource.swift", "Sources/IlliquidCore/Player/PlaybackPhase.swift",
           "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
           "Sources/IlliquidCore/Utilities/PlaybackTimeInput.swift"]
TESTS = ["Tests/IlliquidCoreTests/VideoRatioParsingTests.swift", "Tests/IlliquidCoreTests/PlaybackToolsTests.swift"]
SCENARIOS = ["ratio_nil", "ratio_scalar", "ratio_colon", "ratio_invalid", "geometry_defaults",
             "geometry_aspect", "geometry_crop", "geometry_both", "geometry_invalid"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def outside_ratio(raw: bytes) -> bytes:
    start, end = b"    public static func ratio(", b"\n    public init(sourceSize:"
    if raw.count(start) != 1 or raw.count(end) != 1 or raw.index(start) >= raw.index(end):
        raise ValueError("Production declaration boundaries changed; review the experiment")
    return raw[:raw.index(start)] + raw[raw.index(end):]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--inside-kyoto", action="store_true",
                        help="The entire runner was submitted through the available Kyoto queue")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2:
        parser.error("Use an even number of pairs, at least six")
    if not 100 <= args.target_ms <= 150 or not 60 <= args.minimum_ms < args.target_ms:
        parser.error("target-ms must be 100...150; minimum-ms must be at least 60 and less than target-ms")
    if not args.prepare_only and sys.platform != "darwin":
        parser.error("Native CoreGraphics requires macOS; --prepare-only does not compile or execute Swift")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Use a new or empty output directory to preserve previous evidence")
    out.mkdir(parents=True, exist_ok=True)
    (out / "commands").mkdir()
    (out / "harness").mkdir()
    tracked = {ROOT / path: (ROOT / path).read_bytes() for path in SOURCES + TESTS}
    for path in HERE.iterdir():
        if path.is_file() and path.suffix in [".swift", ".py", ".json", ".md"]:
            tracked[path] = path.read_bytes()
            (out / "harness" / path.name).write_bytes(tracked[path])
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    commands: list[dict] = []

    def run(argv: list[str | Path], timeout: int = 600) -> str:
        command = [str(value) for value in argv]
        number = len(commands)
        started = time.time()
        result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, timeout=timeout)
        stdout, stderr = out / "commands" / f"{number:04d}.stdout", out / "commands" / f"{number:04d}.stderr"
        stdout.write_bytes(result.stdout); stderr.write_bytes(result.stderr)
        receipt = {"command": command, "returncode": result.returncode, "started_unix": started,
                   "elapsed_seconds": time.time() - started,
                   "stdout": str(stdout.relative_to(out)), "stdout_sha256": sha(result.stdout),
                   "stderr": str(stderr.relative_to(out)), "stderr_sha256": sha(result.stderr)}
        commands.append(receipt)
        with (out / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(receipt, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{result.stderr.decode(errors='replace')[-5000:]}")
        return result.stdout.decode()

    manifest = json.loads(tracked[HERE / "baseline.json"])
    if manifest["revision"] != BASELINE or set(manifest["source_sha256"]) != set(SOURCES):
        raise ValueError("Pinned baseline manifest differs from the experiment's source set")
    baseline = {path: run(["git", "show", f"{BASELINE}:{path}"]).encode() for path in SOURCES}
    candidate = {path: tracked[ROOT / path] for path in SOURCES}
    for path in SOURCES:
        if sha(baseline[path]) != manifest["source_sha256"][path]:
            raise ValueError(f"Pinned baseline hash mismatch: {path}")
        if path != GEOMETRY and baseline[path] != candidate[path]:
            raise ValueError(f"Unrelated dependency changed: {path}; review rather than silently comparing it")
    if outside_ratio(baseline[GEOMETRY]) != outside_ratio(candidate[GEOMETRY]):
        raise ValueError("Only the production ratio declaration may differ in this focused experiment")
    receipt = {"baseline_revision": BASELINE, "candidate_revision": run(["git", "rev-parse", "HEAD"]).strip(),
               "working_tree": run(["git", "status", "--short"]), "pairs": args.pairs,
               "target_ms": args.target_ms, "minimum_ms": args.minimum_ms,
               "input_sha256": {str(path.relative_to(ROOT)): sha(raw) for path, raw in tracked.items()},
               "baseline_sha256": manifest["source_sha256"], "sources": SOURCES, "tests": TESTS,
               "scope": "Ratio parser and complete geometry component; no whole-player or RSS measurement"}
    save(out / "receipt.json", receipt)
    packages: dict[str, Path] = {}
    for variant, values in [("baseline", baseline), ("candidate", candidate)]:
        package = out / variant
        source_dir, test_dir = package / "Sources" / "IlliquidCore", package / "Tests" / "IlliquidCoreTests"
        source_dir.mkdir(parents=True); test_dir.mkdir(parents=True)
        for path, raw in values.items():
            (source_dir / Path(path).name).write_bytes(raw)
        for path in TESTS:
            (test_dir / Path(path).name).write_bytes(tracked[ROOT / path])
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "VideoRatioParsingStudy", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
        packages[variant] = package
    if args.prepare_only:
        save(out / "completion.json", {"prepared": True, "compiled": False, "qualified": False})
        print("Prepared exact source/test packages; Swift compilation and execution were not run.")
        return

    # Kyoto is the repository's preferred build coordinator. Hosted macOS
    # runners do not provide that local queue; say so before compiling directly.
    kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
    def build(command: list[str | Path]) -> str:
        return run(command)
    if kyoto.is_file() and not args.inside_kyoto:
        raise RuntimeError("Kyoto is available: submit this entire runner through it with --inside-kyoto")
    if not kyoto.is_file():
        print("Kyoto is unavailable on this host; running isolated component builds directly and serially.", flush=True)
    swiftc = run(["xcrun", "--find", "swiftc"]).strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    flags = ["-swift-version", "6", "-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    save(out / "environment.json", {"platform": platform.platform(), "machine": platform.machine(),
        "compiler": run([swiftc, "--version"]).strip(), "macos": run(["sw_vers"]).strip(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(), "sdk": sdk,
        "developer_dir": environment.get("DEVELOPER_DIR"), "flags": flags,
        "timing": "Fresh process per observation; six or more alternating AB/BA pairs; serial execution",
        "calibration_target_ms": args.target_ms, "minimum_observation_ms": args.minimum_ms})
    binaries: dict[str, Path] = {}
    binary_hashes: dict[Path, str] = {}
    traces: dict[str, dict] = {}
    for variant, package in packages.items():
        print(f"Testing exact {variant} sources in debug and release", flush=True)
        for configuration in ["debug", "release"]:
            build(["swift", "test", "--package-path", package, "-c", configuration, "--jobs", "2", "--no-parallel"])
        folder = package / "component"
        folder.mkdir()
        production = [package / "Sources" / "IlliquidCore" / Path(path).name for path in SOURCES]
        library = folder / "libIlliquidCore.dylib"
        module = folder / "IlliquidCore.swiftmodule"
        build([swiftc, *flags, "-O", "-whole-module-optimization", "-parse-as-library", "-emit-library",
               "-emit-module", "-module-name", "IlliquidCore", "-emit-module-path", module, *production,
               "-Xlinker", "-install_name", "-Xlinker", "@rpath/libIlliquidCore.dylib", "-o", library])
        binary = folder / "driver"
        build([swiftc, *flags, "-O", "-whole-module-optimization", "-parse-as-library",
               "-I", folder, "-L", folder, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", folder,
               out / "harness" / "Driver.swift", "-o", binary])
        binaries[variant] = binary
        for artifact in [library, module, binary]:
            binary_hashes[artifact] = sha(artifact.read_bytes())
        trace = run([binary, "verify"])
        (out / f"{variant}-trace.json").write_text(trace)
        traces[variant] = json.loads(trace)
    if traces["baseline"] != traces["candidate"]:
        raise ValueError("Production variants disagree: inspect retained complete ratio and geometry traces")
    verification = {"exact_trace_match": True, "ratio_cases": len(traces["candidate"]["ratio"]),
                    "geometry_cases": len(traces["candidate"]["geometry"]),
                    "authored_checks_per_variant": traces["candidate"]["authored_checks"],
                    "debug_release_test_variants": 4,
                    "trace_sha256": {v: sha((out / f"{v}-trace.json").read_bytes()) for v in packages}}
    save(out / "verification.json", verification)

    def measure(variant: str, scenario: str, count: int) -> dict:
        row = json.loads(run([binaries[variant], scenario, str(count)]))
        if row["scenario"] != scenario or row["iterations"] != count or min(row["wall_ns"], row["cpu_ns"]) <= 0:
            raise ValueError("Malformed timing result")
        return row

    counts: dict[str, int] = {}
    calibration: list[dict] = []
    for scenario in SCENARIOS:
        needs = []
        for variant in packages:
            count = 16_384
            for _ in range(8):
                row = measure(variant, scenario, count)
                calibration.append(dict(row, variant=variant))
                elapsed = min(row["cpu_ns"], row["wall_ns"])
                if elapsed >= args.target_ms * 1_000_000:
                    break
                count = math.ceil(count * max(1.5, args.target_ms * 1_100_000 / elapsed) / 32) * 32
                if count > 100_000_000:
                    raise ValueError("Calibration requires too many iterations")
            else:
                raise ValueError("Calibration did not converge")
            needs.append(count)
        counts[scenario] = max(needs)  # Identical work counts and checksums in both variants.
    save(out / "calibration.json", {"iterations": counts, "observations": calibration})
    rows: list[dict] = []
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        print(f"Timing pair {pair + 1}/{args.pairs}: {'/'.join(order)}", flush=True)
        for scenario in SCENARIOS:
            pair_rows = []
            for position, variant in enumerate(order):
                row = dict(measure(variant, scenario, counts[scenario]), variant=variant, pair=pair, order=position)
                if min(row["wall_ns"], row["cpu_ns"]) < args.minimum_ms * 1_000_000:
                    raise ValueError("Observation below minimum duration: retain this evidence and rerun with a new output directory")
                rows.append(row); pair_rows.append(row)
                with (out / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if pair_rows[0]["checksum"] != pair_rows[1]["checksum"]:
                raise ValueError("Timed output checksums differ")
    summary: dict = {}
    for scenario in SCENARIOS:
        result: dict = {}
        for metric in ["wall_ns", "cpu_ns"]:
            values = {v: [r[metric] / r["iterations"] for r in rows if r["scenario"] == scenario and r["variant"] == v]
                      for v in packages}
            result[metric + "_per_operation"] = {v: {"median": statistics.median(data), "min": min(data), "max": max(data)}
                                                   for v, data in values.items()}
            result[metric + "_speedup"] = statistics.median(values["baseline"]) / statistics.median(values["candidate"])
        summary[scenario] = result
    for path, raw in tracked.items():
        if path.read_bytes() != raw:
            raise ValueError(f"Input changed during experiment: {path}")
    for path, expected in binary_hashes.items():
        if sha(path.read_bytes()) != expected:
            raise ValueError(f"Compiled artifact changed during experiment: {path}")
    save(out / "summary.json", summary)
    save(out / "artifacts.json", {str(path.relative_to(out)): value for path, value in binary_hashes.items()})
    save(out / "completion.json", {"prepared": True, "compiled": True, "qualified": True,
        "observations": len(rows), "expected_observations": args.pairs * len(SCENARIOS) * 2,
        "input_stability_checked": True, "binary_stability_checked": True,
        "scope": "Focused production component and actual unit tests; no whole-app execution or memory measurement"})
    print(json.dumps({"verification": verification, "summary": summary}, indent=2), flush=True)


if __name__ == "__main__":
    main()
