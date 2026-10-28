#!/usr/bin/env python3
"""Compare the production thumbnail neighborhood with its former eager projection."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
TEST = "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailNeighborhoodQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NeighborhoodProbe", targets: ["NeighborhoodProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "NeighborhoodProbe", dependencies: ["IlliquidApp", "IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),
    ]
)
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def baseline_helper(source: str) -> str:
    # Preserve both complete production expressions; omit unrelated candidate
    # assembly between them. Only replace the view-store input with a parameter.
    first = "        let playlist = player.viewStore.playlist.map(\\.url)\n"
    middle = "        var urls = current.map { [$0] } ?? []\n"
    distances = "        var distances: [URL: Int] = [:]\n"
    end = "        let candidates = urls.map { url in\n"
    for marker in (first, middle, distances, end):
        if source.count(marker) != 1:
            raise RuntimeError("Baseline extraction boundary changed: " + marker)
    a, b, c, d = (source.index(marker) for marker in (first, middle, distances, end))
    if not a < b < c < d:
        raise RuntimeError("Baseline extraction boundaries are out of order")
    body = (source[a:b] + source[c:d]).replace("player.viewStore.playlist", "items", 1)
    return ("import Foundation\nimport IlliquidCore\n\n"
            "struct ThumbnailPlaylistNeighborhood: Sendable {\n"
            "    let urls: [URL]\n    let distances: [URL: Int]\n"
            "    init(playlist items: [FolderPlaylistItem], current: URL?) {\n"
            + body + "        self.urls = neighbors\n        self.distances = distances\n"
            "    }\n}\n")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.number = 0
        self.env = os.environ.copy()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
                        CLANG_MODULE_CACHE_PATH=str(output / "module-cache"))

    def run(self, args: list, label: str, timeout: int = 900) -> str:
        args = [str(arg) for arg in args]
        self.number += 1
        relative = f"logs/{self.number:04d}-{label}.log"
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        combined = result.stdout + result.stderr
        (self.output / relative).write_text(combined)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(argv=args, returncode=result.returncode,
                seconds=time.monotonic() - started, log=relative), sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{combined[-8000:]}")
        return result.stdout

    def last_log(self) -> str:
        return next((self.output / "logs").glob(f"{self.number:04d}-*.log")).read_text()


def measure(runner: Runner, binary: Path, count: int, position: str,
            iterations: int, label: str) -> dict:
    row = json.loads(runner.run([binary, count, position, iterations], label))
    if (row["count"] != count or row["position"] != position
            or row["iterations"] != iterations or row["wall_ns"] <= 0 or row["cpu_ns"] <= 0
            or row["checksum"] != row["checksum_per_iteration"] * iterations):
        raise RuntimeError("Invalid measurement receipt: " + label)
    row["wall_ns_per_call"] = row["wall_ns"] / iterations
    row["cpu_ns_per_call"] = row["cpu_ns"] / iterations
    return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=50)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer >= 2")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    if platform.system() != "Darwin":
        parser.error("This benchmark measures the native macOS Foundation implementation")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    (output / "logs").mkdir(parents=True, exist_ok=True)
    swift = shutil.which("swift")
    if not swift:
        parser.error("Swift is unavailable")
    runner = Runner(output)
    original = runner.run(["git", "show", f"{BASELINE}:{SCHEDULER}"], "baseline-source")
    before = baseline_helper(original)
    after = (ROOT / HELPER).read_text()
    scheduler = (ROOT / SCHEDULER).read_text()
    if ("playlist: player.viewStore.playlist, current: current)" not in scheduler
            or "neighborDistance: neighborhood.distances[url]" not in scheduler
            or "player.viewStore.playlist.map(\\.url)" in scheduler):
        raise RuntimeError("Scheduler no longer uses the measured helper; review the experiment")

    manifest = {
        "schema": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
        "baseline_revision": BASELINE,
        "candidate_revision": runner.run(["git", "rev-parse", "HEAD"], "head").strip(),
        "candidate_status": runner.run(["git", "status", "--short"], "status").strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift_version": runner.run([swift, "--version"], "swift-version").strip(),
        "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "pairs": args.pairs, "target_ms": args.target_ms,
        "baseline_scheduler_sha256": digest(original.encode()),
        "candidate_scheduler_sha256": digest(scheduler.encode()),
        "inputs": {HELPER: digest(after.encode()), TEST: digest((ROOT / TEST).read_bytes()),
                   "Driver.swift": digest((HERE / "Driver.swift").read_bytes()),
                   "run.py": digest(Path(__file__).read_bytes()),
                   "Package.swift": digest(PACKAGE.encode())},
        "method": {
            "scope": "Synchronous thumbnail playlist neighborhood selection only.",
            "modules": "Separate SwiftPM IlliquidCore, IlliquidApp and driver modules; no cross-module optimization.",
            "baseline": "Unchanged map/anchor/window/distance expressions extracted from the pinned scheduler; only the input and outer type are adapted.",
            "candidate": "Complete, unmodified production helper with real FolderPlaylistItem and URL dependencies.",
            "sampling": "Fresh process for each observation; balanced AB/BA pairs and rotated workload order.",
            "timing": "Release builds; monotonic wall and process CPU clocks; includes result consumption and loop overhead, no subtraction.",
            "excluded": "Input construction, URL normalization, fixture destruction, three warmups, exact output receipts and JSON serialization.",
            "input_lifetime": "withExtendedLifetime((playlist, current)) spans the timed loop and both terminal clock reads.",
            "observability": "Checksum of every call through a non-inlined consumer; exact ordered URLs and distance dictionaries verified separately.",
            "memory": "Source-level elimination of the full URL projection; no allocator, RSS, peak-memory, player FPS or energy measurement.",
            "calibration": "Independent per-variant iteration counts target the same duration; normalized per call.",
        },
    }
    save(output / "manifest.json", manifest)
    binaries, tests, source_receipts = {}, {}, {}
    for variant, helper in (("baseline", before), ("candidate", after)):
        package = output / "packages" / variant
        files = {
            "Package.swift": PACKAGE,
            "Sources/IlliquidApp/ThumbnailPlaylistNeighborhood.swift": helper,
            "Sources/NeighborhoodProbe/Driver.swift": (HERE / "Driver.swift").read_text(),
            "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift": (ROOT / TEST).read_text(),
        }
        for path in CORE:
            files["Sources/IlliquidCore/" + Path(path).name] = (
                runner.run(["git", "show", f"{BASELINE}:{path}"], f"baseline-{Path(path).stem}")
                if variant == "baseline" else (ROOT / path).read_text())
        source_receipts[variant] = {}
        for path, content in files.items():
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
            source_receipts[variant][path] = digest(content.encode())
        options = ["--package-path", package, "--cache-path", output / "package-cache",
                   "--config-path", output / "package-config", "--security-path", output / "package-security"]
        tests[variant] = {}
        for configuration in ("debug", "release"):
            print(f"Testing {variant} {configuration}", flush=True)
            runner.run([swift, "test", *options, "-c", configuration, "--jobs", "2", "--no-parallel"],
                       f"{variant}-{configuration}-tests")
            counts = re.findall(r"Test run with (\d+) tests? .*passed", runner.last_log())
            if not counts or int(counts[-1]) == 0:
                raise RuntimeError("Missing positive Swift Testing receipt")
            tests[variant][configuration] = {"passed": True, "tests": int(counts[-1])}
            save(output / "tests.json", tests)
        runner.run([swift, "build", *options, "-c", "release", "--jobs", "2",
                    "--product", "NeighborhoodProbe"], f"{variant}-build")
        directory = runner.run([swift, "build", *options, "-c", "release", "--show-bin-path"],
                               f"{variant}-bin-path").strip()
        binaries[variant] = Path(directory) / "NeighborhoodProbe"
    manifest["sources"] = source_receipts
    manifest["binaries_sha256"] = {v: digest(p.read_bytes()) for v, p in binaries.items()}
    save(output / "manifest.json", manifest)

    cases = [(0, "none"), (8, "front"), (8, "tail"), (8, "none")]
    cases += [(count, position) for count in (512, 10_000, 100_000)
              for position in ("front", "middle", "tail", "missing", "none")]
    calibration, verification, iterations = {}, {}, {}
    for count, position in cases:
        name = f"{count}-{position}"
        calibration[name], verification[name], iterations[name] = {}, {}, {}
        for variant, binary in binaries.items():
            first = measure(runner, binary, count, position, 1, f"{name}-{variant}-verify")
            verification[name][variant] = first["receipt"]
            pilot_count = min(2_000_000, max(1, math.ceil(args.target_ms * 1_000_000 / 8 / first["wall_ns"])))
            pilot = measure(runner, binary, count, position, pilot_count, f"{name}-{variant}-pilot")
            iterations[name][variant] = min(2_000_000, max(1, math.ceil(
                args.target_ms * 1_000_000 * pilot_count / pilot["wall_ns"])))
            calibration[name][variant] = {"first": first, "pilot": pilot,
                                         "iterations": iterations[name][variant]}
        if verification[name]["baseline"] != verification[name]["candidate"]:
            raise RuntimeError("Ordered URLs or distances differ for " + name)
    save(output / "verification.json", verification)
    save(output / "calibration.json", calibration)

    rows = []
    for pair in range(args.pairs):
        order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        rotation = pair % len(cases)
        for count, position in cases[rotation:] + cases[:rotation]:
            name = f"{count}-{position}"
            for slot, variant in enumerate(order):
                row = measure(runner, binaries[variant], count, position, iterations[name][variant],
                              f"pair-{pair}-{name}-{variant}")
                if row["receipt"] != verification[name]["baseline"]:
                    raise RuntimeError("Timed output differs for " + name)
                row.update(pair=pair, slot=slot, variant=variant, workload=name)
                rows.append(row)
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)

    summaries = []
    for count, position in cases:
        name = f"{count}-{position}"
        subset = [row for row in rows if row["workload"] == name]
        result = {"workload": name, "playlist_count": count, "position": position,
                  "iterations": iterations[name], "pairs": args.pairs}
        for clock in ("wall", "cpu"):
            values = {variant: [next(row[f"{clock}_ns_per_call"] for row in subset
                        if row["pair"] == pair and row["variant"] == variant)
                        for pair in range(args.pairs)] for variant in ("baseline", "candidate")}
            before_values, after_values = values["baseline"], values["candidate"]
            result[clock] = {
                "baseline_median_ns": statistics.median(before_values),
                "candidate_median_ns": statistics.median(after_values),
                "paired_median_reduction_percent": statistics.median(
                    100 * (1 - b / a) for a, b in zip(before_values, after_values)),
                "candidate_faster_pairs": sum(b < a for a, b in zip(before_values, after_values)),
                "samples_ns": values,
            }
        summaries.append(result)
    summary = {"schema": 1, "pairs": args.pairs, "measurements": len(rows),
               "verified_workloads": len(cases), "tests": tests, "results": summaries}
    save(output / "summary.json", summary)
    # Small textual receipts survive artifact expiry and can be copied verbatim
    # into the research record. Full commands, inputs and observations are artifacts.
    for label, value in (("MANIFEST", manifest), ("TESTS", tests),
                         ("VERIFICATION", verification), ("SUMMARY", summary)):
        print("THUMBNAIL_NEIGHBORHOOD_" + label + " " + json.dumps(value, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
