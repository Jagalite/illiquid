#!/usr/bin/env python3
"""Qualify and measure thumbnail playlist neighbors using native production types."""
from __future__ import annotations

import argparse
import datetime
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighbors.swift"
TEST = "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborsTests.swift"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/ThumbnailPolicy.swift",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailNeighborsQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ThumbnailNeighborsProbe", targets: ["ThumbnailNeighborsProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "ThumbnailNeighborsProbe",
                          dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.env = os.environ.copy()
        self.env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
        self.env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
        self.queue = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        self.reported_fallback = False
        self.sequence = 0
        (output / "logs").mkdir()

    def run(self, arguments: list, label: str, build: bool = False) -> str:
        arguments = [str(value) for value in arguments]
        if build and self.queue.is_file():
            environment = ["env"] + [
                f"{key}={self.env[key]}" for key in
                ("DEVELOPER_DIR", "SWIFTPM_MODULECACHE_OVERRIDE", "CLANG_MODULE_CACHE_PATH")
                if key in self.env
            ]
            cli = [os.sys.executable, str(self.queue)]
            submitted = self.run([*cli, "submit", "--", *environment, *arguments], label + "-submit")
            print(submitted, flush=True)
            job = json.loads(submitted)["id"]
            self.run([*cli, "show", job], label + "-show")
            try:
                self.run([*cli, "wait", job], label + "-wait")
            finally:
                logs = self.run([*cli, "logs", job], label + "-queue-logs")
                print(logs, flush=True)
                self.run([*cli, "show", job], label + "-final-state")
            return logs
        if build and not self.reported_fallback:
            print("Shared Kyoto queue is unavailable on this runner; compiling isolated "
                  "components directly and serially.", flush=True)
            self.reported_fallback = True
        self.sequence += 1
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        result = subprocess.run(arguments, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=1200)
        combined = result.stdout + result.stderr
        log.write_text(combined)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(arguments=arguments, returncode=result.returncode,
                                         seconds=time.monotonic() - started,
                                         log=str(log.relative_to(self.output)))) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed; see {log}\n{combined[-6000:]}")
        # Swift Testing writes its completion receipt to stderr on some toolchains.
        return combined if build else result.stdout


def original_helper(source: str) -> str:
    marker = "    private func runPass(settings: ThumbnailPreferences, id: UUID) async {"
    if source.count(marker) != 1:
        raise RuntimeError("Baseline runPass boundary changed")
    body = source.split(marker, 1)[1]
    first, between, second, end = (
        "        let playlist = player.viewStore.playlist.map(",
        "        var urls = current.map",
        "        var distances: [URL: Int] = [:]",
        "        let candidates = urls.map",
    )
    for boundary in (first, between, second, end):
        if body.count(boundary) != 1:
            raise RuntimeError(f"Baseline extraction boundary changed: {boundary}")
    if not body.index(first) < body.index(between) < body.index(second) < body.index(end):
        raise RuntimeError("Baseline extraction boundaries are out of order")
    projection = body[body.index(first):body.index(between)]
    distances = body[body.index(second):body.index(end)]
    # Only the caller's array expression changes to an initializer parameter.
    projection = projection.replace("player.viewStore.playlist", "items")
    return (
        "import Foundation\nimport IlliquidCore\n\n"
        "struct ThumbnailPlaylistNeighbors {\n"
        "    let urls: [URL]\n    let distances: [URL: Int]\n"
        "    init(items: [FolderPlaylistItem], current: URL?) {\n"
        + projection + distances
        + "        self.urls = neighbors\n        self.distances = distances\n    }\n}\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=30)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer of at least two")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    swift = shutil.which(os.environ.get("SWIFT", "swift"))
    if swift is None:
        parser.error("Swift is unavailable")
    runner = Runner(output)
    source = runner.run(["git", "show", f"{BASE}:{SCHEDULER}"], "baseline-source")
    baseline = original_helper(source).encode()
    candidate = (ROOT / HELPER).read_bytes()
    tests = (ROOT / TEST).read_bytes()
    harness = (HERE / "Harness.swift").read_bytes()
    shared = {Path(path).name: (ROOT / path).read_bytes() for path in CORE}
    inputs = {path: sha((ROOT / path).read_bytes()) for path in [SCHEDULER, HELPER, TEST, *CORE]}
    inputs.update({"Harness.swift": sha(harness), "run.py": sha(Path(__file__).read_bytes())})
    manifest = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "baseline_revision": BASE,
        "baseline_scheduler_sha256": sha(source.encode()),
        "baseline_extracted_helper_sha256": sha(baseline),
        "candidate_revision": runner.run(["git", "rev-parse", "HEAD"], "candidate-head").strip(),
        "relevant_status": runner.run(
            ["git", "status", "--short", "--", SCHEDULER, HELPER, TEST, *CORE,
             str(HERE.relative_to(ROOT))], "source-status").strip(),
        "inputs": inputs,
        "environment": {
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(), "cpu_count": os.cpu_count(),
            "cpu": (runner.run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu-model").strip()
                    if platform.system() == "Darwin" else platform.processor()),
            "swift": runner.run([swift, "--version"], "swift-version").strip(),
            "DEVELOPER_DIR": runner.env.get("DEVELOPER_DIR"),
            "SWIFT_DETERMINISTIC_HASHING": runner.env.get("SWIFT_DETERMINISTIC_HASHING"),
        },
        "method": {
            "scope": "Synchronous neighborhood construction; not whole scheduling, playback, UI, or RSS",
            "baseline": "Exact pinned runPass map/anchor/window/distance blocks, wrapped in the helper API",
            "candidate": "Unmodified production helper",
            "modules": "Separate IlliquidCore and IlliquidApp modules; no cross-module optimization",
            "sampling": "Fresh processes; alternating AB/BA order; rotated workloads; no empty-loop subtraction",
            "timing": "Monotonic wall and process CPU time including loop, result retention, and checksum",
            "excluded": "Fixture creation, independent query construction, warmup, receipts, and JSON output",
            "memory": "URL value stride and eliminated full-array element count are structural evidence, not allocator/RSS measurements",
            "pairs": args.pairs, "target_ms": args.target_ms,
        },
    }
    save(output / "manifest.json", manifest)
    binaries, test_results, receipts, build_receipts = {}, {}, {}, {}
    for variant, helper in (("baseline", baseline), ("candidate", candidate)):
        package = output / "packages" / variant
        contents = {
            "Package.swift": PACKAGE.encode(),
            "Sources/IlliquidApp/ThumbnailPlaylistNeighbors.swift": helper,
            "Sources/ThumbnailNeighborsProbe/main.swift": harness,
            "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborsTests.swift": tests,
            **{f"Sources/IlliquidCore/{name}": data for name, data in shared.items()},
        }
        for name, data in contents.items():
            path = package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        receipts[variant] = {name: sha(data) for name, data in contents.items()}
        save(output / "source-receipts.json", receipts)
        options = ["--package-path", package, "--jobs", "2"]
        test_results[variant] = {}
        for configuration in ("debug", "release"):
            text = runner.run([swift, "test", *options, "-c", configuration, "--no-parallel"],
                              f"{variant}-test-{configuration}", build=True)
            counts = re.findall(r"Test run with (\d+) tests? .*passed", text)
            if not counts or int(counts[-1]) < 9:
                raise RuntimeError(f"Missing nine-test completion receipt for {variant}/{configuration}")
            test_results[variant][configuration] = {"passed": True, "tests": int(counts[-1])}
            save(output / "tests.json", test_results)
        runner.run([swift, "build", *options, "-c", "release", "--product", "ThumbnailNeighborsProbe"],
                   variant + "-build-probe", build=True)
        directory = runner.run([swift, "build", "--package-path", package, "-c", "release",
                                "--show-bin-path"], variant + "-binary-path").strip()
        binaries[variant] = Path(directory) / "ThumbnailNeighborsProbe"
        build_receipts[variant] = {
            "binary_sha256": sha(binaries[variant].read_bytes()),
            "binary": str(binaries[variant].relative_to(output)),
        }
    save(output / "build-receipts.json", build_receipts)
    if args.tests_only:
        save(output / "summary.json", {"tests": test_results, "measurements": 0})
        return

    cases = [(count, position) for count in (10, 10_000, 100_000)
             for position in ("nil", "first", "middle", "last", "missing")]
    reference, iterations, calibration = {}, {}, []

    def measure(variant: str, count: int, position: str, calls: int, label: str,
                allow_zero_cpu: bool = False) -> dict:
        row = json.loads(runner.run(
            [binaries[variant], "measure", count, position, calls], label))
        if (row["count"] != count or row["position"] != position or row["iterations"] != calls
                or row["wall_ns"] <= 0 or row["cpu_ns"] < 0
                or (row["cpu_ns"] == 0 and not allow_zero_cpu) or row["url_stride"] <= 0):
            raise RuntimeError(f"Invalid measurement: {label}")
        receipt = {"urls": row["urls"], "distances": row["distances"],
                   "url_stride": row["url_stride"]}
        key = (count, position)
        if key not in reference:
            if row["checksum"] % calls:
                raise RuntimeError("Checksum is not linear in calls")
            reference[key] = (receipt, row["checksum"] // calls)
        expected_receipt, unit = reference[key]
        if receipt != expected_receipt or row["checksum"] != unit * calls:
            raise RuntimeError(f"Baseline/candidate observable output mismatch: {label}")
        row["wall_ns_per_call"] = row["wall_ns"] / calls
        row["cpu_ns_per_call"] = row["cpu_ns"] / calls
        return row

    for count, position in cases:
        for variant in binaries:
            row = measure(variant, count, position, 8, f"pilot-{count}-{position}-{variant}",
                          allow_zero_cpu=True)
            calls = min(1_000_000, max(1, math.ceil(
                args.target_ms * 1_000_000 * row["iterations"] / row["wall_ns"])))
            iterations[(count, position, variant)] = calls
            calibration.append({"variant": variant, "selected_iterations": calls, **row})
    save(output / "calibration.json", calibration)
    rows = []
    for pair in range(args.pairs):
        variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        ordered = cases[pair % len(cases):] + cases[:pair % len(cases)]
        for count, position in ordered:
            for order, variant in enumerate(variants):
                row = measure(variant, count, position, iterations[(count, position, variant)],
                              f"pair-{pair + 1}-{count}-{position}-{variant}")
                row.update(pair=pair, variant=variant, order=order)
                rows.append(row)
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Completed balanced pair {pair + 1}/{args.pairs}", flush=True)

    results = []
    for count, position in cases:
        record = {"count": count, "position": position, "pairs": args.pairs,
                  "url_stride": reference[(count, position)][0]["url_stride"]}
        for clock in ("wall", "cpu"):
            before = [next(r[f"{clock}_ns_per_call"] for r in rows
                           if r["count"] == count and r["position"] == position
                           and r["pair"] == pair and r["variant"] == "baseline")
                      for pair in range(args.pairs)]
            after = [next(r[f"{clock}_ns_per_call"] for r in rows
                          if r["count"] == count and r["position"] == position
                          and r["pair"] == pair and r["variant"] == "candidate")
                     for pair in range(args.pairs)]
            record[clock] = {
                "baseline_median_ns": statistics.median(before),
                "candidate_median_ns": statistics.median(after),
                "paired_median_reduction_percent": statistics.median(
                    100 * (1 - b / a) for a, b in zip(before, after)),
                "candidate_faster_pairs": sum(b < a for a, b in zip(before, after)),
                "baseline_ns": before, "candidate_ns": after,
            }
        results.append(record)
    report = {"tests": test_results, "pairs": args.pairs, "measurements": len(rows), "results": results}
    save(output / "summary.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
