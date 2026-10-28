#!/usr/bin/env python3
"""Qualify thumbnail neighbor projection using production Swift components.

Timing and Linux/glibc allocation-request measurements are separate cohorts.
Every observation is a fresh process, with balanced sequential AB/BA pairs.
"""
from __future__ import annotations

import argparse
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
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighbors.swift"
METER = "Benchmarks/NonDecodePerformance/allocmeter.c"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/ThumbnailPolicy.swift",
    "Sources/IlliquidCore/Player/ThumbnailPassCursor.swift",
    "Sources/IlliquidCore/Player/ThumbnailVisibilityPolicy.swift",
]
TESTS = [
    "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborsTests.swift",
    "Tests/IlliquidCoreTests/ThumbnailPolicyTests.swift",
    "Tests/IlliquidCoreTests/ThumbnailSchedulingPolicyRegressionTests.swift",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailPlaylistNeighborsQualification", platforms: [.macOS("26.0")],
    products: [.executable(name: "NeighborBenchmark", targets: ["NeighborBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        METER_TARGET
        .executableTarget(name: "NeighborBenchmark", dependencies: ["IlliquidApp", "IlliquidCore"METER_DEPENDENCY]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ], swiftLanguageModes: [.v6]
)
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def baseline_helper() -> tuple[bytes, dict]:
    manifest = json.loads((HERE / "baseline/manifest.json").read_text())
    data = (HERE / "baseline/ThumbnailBackgroundScheduler.swift").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if (manifest["commit"] != BASELINE or sha(data) != manifest["sha256"]
            or blob != manifest["git_blob"] or manifest["path"] != SCHEDULER):
        raise ValueError("Frozen baseline scheduler provenance mismatch")
    source = data.decode()
    start = "        let playlist = player.viewStore.playlist.map(\\.url)\n"
    middle = "        var urls = current.map { [$0] } ?? []\n"
    distance = "        var distances: [URL: Int] = [:]\n"
    end = "        let candidates = urls.map { url in\n"
    if any(source.count(marker) != 1 for marker in (start, middle, distance, end)):
        raise ValueError("Baseline extraction markers changed")
    a, b, c, d = (source.index(marker) for marker in (start, middle, distance, end))
    if not a < b < c < d:
        raise ValueError("Baseline extraction order changed")
    projection = source[a:b] + source[c:d]
    if sha(projection.encode()) != manifest["projection_sha256"]:
        raise ValueError("Baseline projection changed; review extraction")
    projection = projection.replace(
        "player.viewStore.playlist.map(\\.url)", "items.map(\\.url)", 1)
    wrapper = ("import Foundation\nimport IlliquidCore\n"
               "struct ThumbnailPlaylistNeighbors: Equatable, Sendable {\n"
               "    let urls: [URL]\n    let distances: [URL: Int]\n"
               "    init(playlist items: [FolderPlaylistItem], current: URL?) {\n"
               + projection + "        self.urls = neighbors\n"
               "        self.distances = distances\n    }\n}\n")
    return wrapper.encode(), manifest


def distribution(values: list[float]) -> dict:
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--sizes", default="0,16,512,10000,100000")
    parser.add_argument("--case", action="append", help="COUNT/nil|miss|first|middle|last; repeatable")
    parser.add_argument("--iterations", type=int, help="Fixed iterations; otherwise calibrate timing")
    parser.add_argument("--allocations", action="store_true", help="Separate Linux/glibc request-count cohort")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",")]
    if not args.swift or args.pairs < 2 or args.pairs % 2 or not 1 <= args.target_ms <= 1000:
        parser.error("Need Swift 6.1+, even pairs >= 2, and target-ms in 1...1000")
    if any(value < 0 or value > 1000000 for value in sizes) or len(set(sizes)) != len(sizes):
        parser.error("Sizes must be unique integers in 0...1000000")
    if args.iterations is not None and args.iterations < 1:
        parser.error("Iterations must be positive")
    if args.tests_only and args.skip_tests:
        parser.error("Conflicting test options")
    if args.allocations and (platform.system() != "Linux" or platform.libc_ver()[0] != "glibc"):
        parser.error("Allocation instrumentation requires Linux/glibc")
    cases = [(count, scenario) for count in sizes for scenario in
             (("nil", "miss", "first", "middle", "last") if count else ("nil", "miss"))]
    if args.case:
        names = {f"{count}/{scenario}" for count, scenario in cases}
        if set(args.case) - names:
            parser.error(f"Unknown cases: {sorted(set(args.case) - names)}")
        cases = [case for case in cases if f"{case[0]}/{case[1]}" in args.case]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use a new or empty output directory")
    env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb",
               CLANG_MODULE_CACHE_PATH=str(out / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(out / "module-cache"))
    swift = os.path.abspath(args.swift)

    def execute(argv, log=None) -> str:
        command = list(map(str, argv))
        start = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        with (out / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": command, "returncode": result.returncode,
                                    "wall_seconds": time.monotonic() - start,
                                    "stdout": result.stdout, "stderr": result.stderr}) + "\n")
        if log:
            (out / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
        return result.stdout + result.stderr if log else result.stdout

    original, baseline = baseline_helper()
    paths = [*CORE, *TESTS, HELPER, SCHEDULER] + ([METER] if args.allocations else [])
    tracked = {path: (ROOT / path).read_bytes() for path in paths}
    integration = tracked[SCHEDULER].decode()
    if ("ThumbnailPlaylistNeighbors(playlist: player.viewStore.playlist, current: current)" not in integration
            or "player.viewStore.playlist.map(\\.url)" in integration):
        raise ValueError("Scheduler integration changed; review component attribution")
    manifest = {"baseline": baseline, "compiler": execute([swift, "--version"]).strip(),
                "platform": platform.platform(), "machine": platform.machine(),
                "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "checkout": execute(["git", "rev-parse", "HEAD"]).strip(),
                "working_tree": execute(["git", "status", "--porcelain"]).splitlines(),
                "mode": "allocations" if args.allocations else "timing",
                "source_sha256": {path: sha(data) for path, data in tracked.items()},
                "harness_sha256": {
                    "Harness.swift": sha((HERE / "Harness.swift").read_bytes()),
                    "run.py": sha(Path(__file__).read_bytes()),
                    **({"allocmeter.c": sha(tracked[METER])} if args.allocations else {})},
                "measurement_environment": {key: env.get(key) for key in (
                    "SWIFT_DETERMINISTIC_HASHING", "TERM", "LANG", "LC_ALL",
                    "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE")},
                "scope": "Production neighbor projection component, not full app or playback",
                "baseline_extraction": "Verbatim map/anchor/window/distance blocks; replace owner access with parameter; wrap same result interface",
                "iteration_policy": (
                    "Equal fixed iterations per variant; normalize to one projection"
                    if args.allocations or args.iterations is not None else
                    "Independently calibrated per variant; normalize to one projection"),
                "allocation_scope": "Successful glibc malloc/calloc/realloc request count and requested bytes, not live/peak memory or RSS",
                "cases": [f"{count}/{scenario}" for count, scenario in cases], "pairs": args.pairs,
                "target_ms": args.target_ms, "fixed_iterations": args.iterations,
                "builds": {}, "tests": []}
    if hasattr(os, "sched_getaffinity"):
        manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
    source_dir = out / "sources"
    source_dir.mkdir()
    for path, data in tracked.items():
        destination = source_dir / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    shutil.copy2(HERE / "run.py", source_dir / "run.py")
    shutil.copy2(HERE / "Harness.swift", source_dir / "Harness.swift")
    shutil.copytree(HERE / "baseline", source_dir / "baseline")
    save(out / "manifest.json", manifest)
    binaries = {}
    for variant, helper in (("baseline", original), ("candidate", tracked[HELPER])):
        package = out / "build" / variant
        for path in [*CORE, *TESTS]:
            parts = Path(path).parts
            destination = package / parts[0] / parts[1] / parts[-1]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(tracked[path])
        app = package / "Sources/IlliquidApp"
        app.mkdir(parents=True)
        (app / "ThumbnailPlaylistNeighbors.swift").write_bytes(helper)
        driver = package / "Sources/NeighborBenchmark"
        driver.mkdir()
        shutil.copy2(HERE / "Harness.swift", driver / "Harness.swift")
        spec = PACKAGE.replace("METER_TARGET", '.target(name: "CAllocationMeter"),' if args.allocations else "")
        spec = spec.replace("METER_DEPENDENCY", ', "CAllocationMeter"' if args.allocations else "")
        (package / "Package.swift").write_text(spec)
        if args.allocations:
            meter = package / "Sources/CAllocationMeter"
            (meter / "include").mkdir(parents=True)
            (meter / "allocmeter.c").write_bytes(tracked[METER])
            (meter / "include/AllocationMeter.h").write_text(
                "#include <stdint.h>\nvoid meter_begin(void);\nvoid meter_end(void);\n"
                "uint64_t meter_requests(void);\nuint64_t meter_bytes(void);\n")
        flags = ["--package-path", package, "--cache-path", out / "package-cache",
                 "--config-path", out / "package-config", "--security-path", out / "package-security",
                 "--jobs", "2", "-Xswiftc", "-enable-testing", "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux":
            flags.append("--use-integrated-swift-driver")
        if args.allocations:
            flags += ["-Xswiftc", "-DALLOCATION_METER"]
        if not args.skip_tests:
            for configuration in ("debug", "release"):
                print(f"Test {variant} {configuration}", flush=True)
                log = f"tests-{variant}-{configuration}.log"
                text = execute([swift, "test", *flags, "-c", configuration], log=log)
                counts = re.findall(r"Test run with (\d+) tests? .*passed", text)
                if not counts or int(counts[-1]) == 0:
                    raise ValueError(f"No successful Swift Testing result in {log}")
                manifest["tests"].append({"variant": variant, "configuration": configuration,
                                          "passed": int(counts[-1]), "log": log})
                save(out / "manifest.json", manifest)
        if not args.tests_only:
            print(f"Build {variant} release benchmark", flush=True)
            execute([swift, "build", *flags, "-c", "release", "--product", "NeighborBenchmark"],
                    log=f"build-{variant}.log")
            bindir = execute([swift, "build", *flags, "-c", "release", "--show-bin-path"]).strip()
            binaries[variant] = Path(bindir) / "NeighborBenchmark"
        manifest["builds"][variant] = {
            "files": {str(path.relative_to(package)): sha(path.read_bytes())
                      for base in ("Sources", "Tests") for path in sorted((package / base).rglob("*"))
                      if path.is_file()},
            "package_sha256": sha((package / "Package.swift").read_bytes()),
            "binary_sha256": sha(binaries[variant].read_bytes()) if variant in binaries else None}
        save(out / "manifest.json", manifest)
    if not args.tests_only:
        verify, calibration, iterations, rows = {}, [], {}, []

        def observe(variant, mode, case, count):
            row = json.loads(execute([binaries[variant], mode, *case, count]))
            if (row["mode"], row["count"], row["scenario"], row["iterations"], row["oracle_equal"]) != (
                    mode, *case, count, True):
                raise ValueError("Observation identity or oracle mismatch")
            if mode == "allocations" and case[0] > 0 and case[1] == "nil":
                if variant == "baseline" and (
                        row["allocation_requests"] < count
                        or row["allocation_requested_bytes"] < case[0] * row["url_stride_bytes"] * count):
                    raise ValueError("Allocation meter did not observe the baseline URL buffer; refuse ineffective instrumentation")
                if variant == "candidate" and (
                        row["allocation_requests"] != 0 or row["allocation_requested_bytes"] != 0):
                    raise ValueError("The warmed nil-current candidate unexpectedly allocated")
            return row

        if args.allocations:
            # Always qualify interposition, even when selected measurement cases
            # omit nil current. Warmup and fixture creation are excluded.
            control = {variant: observe(variant, "allocations", (16, "nil"), 3)
                       for variant in binaries}
            save(out / "allocation-meter-control.json", {"passed": True, "observations": control})
        for case in cases:
            name = f"{case[0]}/{case[1]}"
            pair = {variant: observe(variant, "verify", case, 1) for variant in binaries}
            if pair["baseline"]["receipt"] != pair["candidate"]["receipt"]:
                raise ValueError(f"Full-output parity failed: {name}")
            manifest["layout_bytes"] = {key: pair["candidate"][key] for key in
                                        ("url_stride_bytes", "playlist_item_stride_bytes")}
            verify[name] = pair
            for variant in binaries:
                n = args.iterations or (3 if args.allocations else (128 if case[0] <= 512 else 4))
                if args.iterations is None and not args.allocations:
                    while True:
                        pilot = observe(variant, "timing", case, n)
                        calibration.append({"variant": variant, "case": name, **pilot})
                        if pilot["cpu_ns"] >= 5_000_000 or n >= 10_000_000:
                            break
                        n = min(10_000_000, n * 8)
                    n = max(3, min(100_000_000, math.ceil(n * args.target_ms * 1_000_000 / max(1, pilot["cpu_ns"]))))
                iterations[(variant, case)] = n
            save(out / "verification.json", verify)
            save(out / "calibration.json", calibration)
            save(out / "manifest.json", manifest)
        save(out / "iteration-counts.json", [
            {"variant": variant, "case": f"{case[0]}/{case[1]}", "iterations": count}
            for (variant, case), count in iterations.items()])
        for pair in range(args.pairs):
            for case in (cases if pair % 2 == 0 else list(reversed(cases))):
                name = f"{case[0]}/{case[1]}"
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for ordinal, variant in enumerate(order):
                    row = observe(variant, manifest["mode"], case, iterations[(variant, case)])
                    if row["receipt"] != verify[name][variant]["receipt"]:
                        raise ValueError("Measured output differs from verified output")
                    row.update(variant=variant, case=name, pair=pair, ordinal=ordinal)
                    rows.append(row)
                    with (out / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)
        metrics = ("allocation_requests", "allocation_requested_bytes") if args.allocations else ("cpu_ns", "elapsed_ns")
        summary = []
        for case in cases:
            name = f"{case[0]}/{case[1]}"
            group = [row for row in rows if row["case"] == name]
            entry = {"case": name, "variants": {}, "paired_change_percent": {}}
            for variant in binaries:
                selected = [row for row in group if row["variant"] == variant]
                entry["variants"][variant] = {metric: distribution([
                    row[metric] / row["iterations"] for row in selected]) for metric in metrics}
            for metric in metrics:
                changes = []
                for pair in range(args.pairs):
                    values = {row["variant"]: row[metric] / row["iterations"] for row in group if row["pair"] == pair}
                    changes.append(100 * (values["candidate"] / values["baseline"] - 1) if values["baseline"] else None)
                measured = [value for value in changes if value is not None]
                entry["paired_change_percent"][metric] = {
                    **(distribution(measured) if measured else {}),
                    "all": changes, "candidate_lower_pairs": sum(value < 0 for value in measured)}
            summary.append(entry)
        save(out / "summary.json", summary)
    if any((ROOT / path).read_bytes() != data for path, data in tracked.items()):
        raise ValueError("Repository source changed during qualification; retain this run but do not attribute it to the current files")
    save(out / "completion.json", {"completed": True, "tests_executed": not args.skip_tests,
                                  "measurements": 0 if args.tests_only else len(rows),
                                  "scope": manifest["scope"]})


if __name__ == "__main__":
    main()
