#!/usr/bin/env python3
"""Qualify bounded thumbnail neighborhoods against the exact prior scheduler."""
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
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
TEST = "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
]
PROBE = "Benchmarks/PlaylistDeduplication/MemoryProbe.c"
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ThumbnailNeighborhoodQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NeighborhoodProbe", targets: ["NeighborhoodProbe"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .target(name: "MemoryProbe", publicHeadersPath: "include"),
        .executableTarget(name: "NeighborhoodProbe",
                          dependencies: ["IlliquidCore", "IlliquidApp", "MemoryProbe"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ])
"""


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, output: Path):
        self.output, self.sequence = output, 0
        (output / "logs").mkdir()
        self.queue = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        self.explained_queue = False

    def run(self, args, label, build=False, timeout=900):
        args = list(map(str, args))
        self.sequence += 1
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        if build and self.queue.is_file():
            cli = [sys.executable, str(self.queue)]
            submitted = subprocess.check_output([*cli, "submit", "--", *args], cwd=ROOT, text=True)
            job_id = str(json.loads(submitted)["id"])
            shown = subprocess.check_output([*cli, "show", job_id], text=True)
            waited = subprocess.run([*cli, "wait", job_id], capture_output=True, text=True, timeout=timeout)
            logged = subprocess.run([*cli, "logs", job_id], capture_output=True, text=True, check=True)
            text = submitted + shown + waited.stdout + waited.stderr + logged.stdout + logged.stderr
            code = waited.returncode
        else:
            if build and not self.explained_queue:
                print("Kyoto is unavailable on this host; building isolated packages directly and serially.", flush=True)
                self.explained_queue = True
            result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
            text, code = result.stdout + result.stderr, result.returncode
        log.write_text(text)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(args=args, returncode=code, seconds=time.monotonic() - started,
                                        log=str(log.relative_to(self.output))), sort_keys=True) + "\n")
        if code:
            raise RuntimeError(f"{label} failed ({code})\n{text[-6000:]}")
        return text


def extract_baseline(text: str) -> tuple[str, str]:
    start = "        let playlist = player.viewStore.playlist.map(\\.url)\n"
    middle = "        var urls = current.map { [$0] } ?? []\n"
    distance_start = "        var distances: [URL: Int] = [:]\n"
    end = "        let candidates = urls.map { url in\n"
    for marker in (start, middle, distance_start, end):
        if text.count(marker) != 1:
            raise RuntimeError(f"Baseline extraction boundary changed: {marker.strip()}")
    prefix = text[text.index(start):text.index(middle)]
    distance = text[text.index(distance_start):text.index(end)]
    if not text.index(start) < text.index(middle) < text.index(distance_start) < text.index(end):
        raise RuntimeError("Baseline extraction order changed")
    prefix = prefix.replace("player.viewStore.playlist", "items")
    source = (
        "import Foundation\nimport IlliquidCore\n\n"
        "struct ThumbnailPlaylistNeighborhood {\n"
        "    let urls: [URL]\n    let distances: [URL: Int]\n"
        "    init(playlist items: [FolderPlaylistItem], current: URL?) {\n"
        + prefix + distance
        + "        self.urls = neighbors\n        self.distances = distances\n    }\n}\n"
    )
    projection = (
        "import Foundation\nimport IlliquidCore\n\n"
        "@inline(never)\nfunc legacyProjection(_ items: [FolderPlaylistItem]) -> [URL] {\n"
        + start.replace("player.viewStore.playlist", "items")
        + "    return playlist\n}\n"
    )
    return source, projection


def cases():
    return ([(0, "none"), (1, "head"), (32, "head"), (32, "middle"), (32, "tail"),
             (1000, "middle"), (1000, "missing")]
            + [(100000, position) for position in ("none", "head", "middle", "tail", "missing")])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=40)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target duration")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    runner = Runner(output)
    summary = {"status": "running", "baseline": BASELINE, "tests": {}, "results": []}
    manifest = {"baseline": BASELINE, "platform": platform.platform(), "machine": platform.machine(),
                "python": platform.python_version(), "pairs": args.pairs, "target_ms": args.target_ms,
                "scope": "Playlist neighborhood construction only; no decode, I/O, UI, or energy measurement.",
                "memory_scope": "Measured capacity and live allocation of the removed legacy URL projection; "
                                "not total app RSS or a measurement of the candidate's peak heap.",
                "method": "Separate Swift modules, fresh processes, independently calibrated loops, "
                          "balanced AB/BA pairs, no empty-loop subtraction; input construction, oracle, "
                          "warmup, validation, allocation inventory, and JSON output are untimed."}
    try:
        swift = shutil.which("swift")
        if not swift:
            raise RuntimeError("Swift is unavailable")
        manifest["swift"] = runner.run([swift, "--version"], "swift-version").strip()
        manifest["head"] = runner.run(["git", "rev-parse", "HEAD"], "head").strip()
        manifest["worktree_status"] = runner.run(["git", "status", "--short"], "status").strip()
        old = runner.run(["git", "show", f"{BASELINE}:{SCHEDULER}"], "baseline-scheduler")
        baseline, projection = extract_baseline(old)
        candidate = (ROOT / HELPER).read_text()
        scheduler = (ROOT / SCHEDULER).read_text()
        if ("let neighborhood = ThumbnailPlaylistNeighborhood(" not in scheduler
                or "neighborDistance: neighborhood.distances[url]" not in scheduler
                or "player.viewStore.playlist.map(\\.url)" in scheduler):
            raise RuntimeError("Scheduler is not wired to the bounded helper")
        dependencies = {}
        for path in CORE:
            raw = (ROOT / path).read_bytes()
            pinned = subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)
            if raw != pinned:
                raise RuntimeError(f"Unrelated benchmark dependency changed: {path}")
            dependencies[path] = raw
        inputs = {path: sha((ROOT / path).read_bytes()) for path in
                  [SCHEDULER, HELPER, TEST, PROBE, *CORE]}
        inputs.update({"Driver.swift": sha((HERE / "Driver.swift").read_bytes()),
                       "run.py": sha(Path(__file__).read_bytes()),
                       "baseline_extracted.swift": sha(baseline.encode()),
                       "baseline_full_scheduler": sha(old.encode()),
                       "Package.swift": sha(PACKAGE.encode())})
        manifest["inputs"] = inputs
        manifest["baseline_extraction"] = "Two exact runPass blocks; only player.viewStore.playlist "
        manifest["baseline_extraction"] += "becomes the input parameter. Existing arrays and distance writes are unchanged."
        save(output / "manifest.json", manifest)
        binaries = {}
        for variant, helper in (("baseline", baseline), ("candidate", candidate)):
            package = output / "packages" / variant
            files = {
                "Package.swift": PACKAGE.encode(),
                "Sources/IlliquidApp/ThumbnailPlaylistNeighborhood.swift": helper.encode(),
                "Sources/NeighborhoodProbe/LegacyProjection.swift": projection.encode(),
                "Sources/NeighborhoodProbe/Driver.swift": (HERE / "Driver.swift").read_bytes(),
                "Sources/MemoryProbe/MemoryProbe.c": (ROOT / PROBE).read_bytes(),
                "Sources/MemoryProbe/include/MemoryProbe.h": b"#include <stdint.h>\nuint64_t illiquid_live_allocated_bytes(void);\n",
                "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift": (ROOT / TEST).read_bytes(),
            }
            files.update({f"Sources/IlliquidCore/{Path(path).name}": data for path, data in dependencies.items()})
            for relative, data in files.items():
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            options = ["--package-path", package, "--scratch-path", package / ".build",
                       "--cache-path", package / "cache", "--config-path", package / "config",
                       "--security-path", package / "security"]
            summary["tests"][variant] = {}
            for configuration in ("debug", "release"):
                text = runner.run([swift, "test", *options, "-c", configuration, "--jobs", "2",
                                   "--no-parallel"], f"{variant}-{configuration}-tests", build=True)
                counts = re.findall(r"Test run with (\d+) tests? .*passed", text)
                if not counts or int(counts[-1]) == 0:
                    raise RuntimeError(f"No positive test completion receipt: {variant}/{configuration}")
                summary["tests"][variant][configuration] = int(counts[-1])
                save(output / "summary.json", summary)
            directory = runner.run([swift, "build", *options, "-c", "release", "--show-bin-path"],
                                   f"{variant}-bin-path").strip()
            binary = Path(directory) / "NeighborhoodProbe"
            if not binary.is_file():
                runner.run([swift, "build", *options, "-c", "release", "--jobs", "2",
                            "--product", "NeighborhoodProbe"], f"{variant}-build-probe", build=True)
            binaries[variant] = binary
        manifest["binaries"] = {variant: sha(path.read_bytes()) for variant, path in binaries.items()}
        save(output / "manifest.json", manifest)

        def sample(variant, count, position, iterations, label, mode="measure"):
            row = json.loads(runner.run([binaries[variant], mode, count, position, iterations], label))
            if (row["count"], row["position"], row["iterations"]) != (count, position, iterations):
                raise RuntimeError("Measurement identity mismatch")
            if row["output_url_count"] > 9:
                raise RuntimeError("Unbounded neighborhood")
            return row

        for count, position in cases():
            case = f"{count}/{position}"
            inventory = sample("candidate", count, position, 1, "allocation-inventory", "inventory")
            if inventory["legacy_projection_count"] != count:
                raise RuntimeError("Projection allocation inventory is incomplete")
            iterations, calibration = {}, {}
            for variant in binaries:
                first = sample(variant, count, position, 1, "calibration-first")
                pilot_count = min(1000000, max(1, math.ceil(args.target_ms * 125000 / max(1, first["wall_ns"]))))
                pilot = sample(variant, count, position, pilot_count, "calibration-pilot")
                iterations[variant] = min(1000000, max(1, math.ceil(
                    args.target_ms * 1000000 * pilot_count / max(1, pilot["wall_ns"]))))
                calibration[variant] = [first, pilot]
            rows = []
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                paired = []
                for variant in order:
                    row = sample(variant, count, position, iterations[variant], f"pair-{pair}-{variant}")
                    for key in ("urls", "distances", "output_url_count"):
                        if row[key] != inventory[key]:
                            raise RuntimeError(f"Exact output differs: {case}/{variant}/{key}")
                    row.update(case=case, pair=pair, variant=variant)
                    rows.append(row)
                    paired.append(row)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            result = {"case": case, "count": count, "position": position,
                      "inventory": inventory, "iterations": iterations, "pairs": args.pairs}
            for clock in ("wall", "cpu"):
                values = {v: [r[f"{clock}_ns"] / r["iterations"] for r in rows if r["variant"] == v]
                          for v in binaries}
                result[clock] = {
                    "baseline_median_ns": statistics.median(values["baseline"]),
                    "candidate_median_ns": statistics.median(values["candidate"]),
                    "paired_median_reduction_percent": statistics.median(
                        100 * (1 - b / a) for a, b in zip(values["baseline"], values["candidate"])),
                    "candidate_faster_pairs": sum(b < a for a, b in zip(values["baseline"], values["candidate"])),
                    "samples_ns": values,
                }
            summary["results"].append(result)
            save(output / "summary.json", summary)
            save(output / ("calibration-" + case.replace("/", "-") + ".json"), calibration)
            print(f"{case}: wall reduction {result['wall']['paired_median_reduction_percent']:.1f}%; "
                  f"CPU reduction {result['cpu']['paired_median_reduction_percent']:.1f}%; "
                  f"removed projection payload {inventory['legacy_projection_payload_bytes']} bytes", flush=True)
        summary["status"] = "passed"
        print("THUMBNAIL_NEIGHBORHOOD_QUALIFICATION_PASS", flush=True)
    except BaseException as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "manifest.json", manifest)
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
