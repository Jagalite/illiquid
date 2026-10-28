#!/usr/bin/env python3
"""Paired benchmark of thumbnail neighborhood preparation, with exact output receipts."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import textwrap

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
SUPPORT = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
]
FLAGS = ["-swift-version", "6", "-O"]
MODULE_FLAGS = [*FLAGS, "-whole-module-optimization", "-parse-as-library", "-enable-testing"]
POSITIONS = ["nil", "front", "middle", "last", "absent"]


def command(arguments: list[str], **kwargs) -> str:
    return subprocess.check_output(arguments, text=True, **kwargs).strip()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def baseline_adapter(scheduler: str) -> str:
    """Copy both original blocks; adapt only the source of the playlist input."""
    method = scheduler.split("    private func runPass(", 1)[1]
    beginning = "        let playlist = player.viewStore.playlist.map(\\.url)\n"
    urls_boundary = "        var urls = current.map { [$0] } ?? []\n"
    distances_beginning = "        var distances: [URL: Int] = [:]\n"
    candidates_boundary = "        let candidates = urls.map { url in\n"
    for marker in [beginning, urls_boundary, distances_beginning, candidates_boundary]:
        if method.count(marker) != 1:
            raise RuntimeError("Original scheduler block did not match: " + marker.strip())
    neighbors = beginning + method.split(beginning, 1)[1].split(urls_boundary, 1)[0]
    distances = distances_beginning + method.split(distances_beginning, 1)[1].split(candidates_boundary, 1)[0]
    body = (neighbors + distances).replace("player.viewStore.playlist", "items")
    return (
        "import Foundation\nimport IlliquidCore\n\n"
        "struct ThumbnailPlaylistNeighborhood: Sendable {\n"
        "    let urls: [URL]\n    let distances: [URL: Int]\n"
        "    init(playlist items: [FolderPlaylistItem], current: URL?) {\n"
        + textwrap.indent(textwrap.dedent(body), "        ")
        + "        self.urls = neighbors\n        self.distances = distances\n"
        "    }\n}\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-revision", default=BASELINE)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=50)
    parser.add_argument("--counts", default="32,10000,100000")
    args = parser.parse_args()
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be even and at least two for balanced AB/BA pairs")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    try:
        counts = [int(value) for value in args.counts.split(",")]
        if not counts or min(counts) <= 0 or len(set(counts)) != len(counts):
            raise ValueError()
    except ValueError:
        parser.error("--counts must be distinct positive integers")
    root = Path(__file__).resolve().parents[2]
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise SystemExit("swiftc is unavailable")
    revision = command(["git", "-C", str(root), "rev-parse", args.baseline_revision + "^{commit}"])
    original = subprocess.check_output(["git", "-C", str(root), "show", revision + ":" + SCHEDULER])
    baseline = baseline_adapter(original.decode()).encode()
    candidate = (root / HELPER).read_bytes()
    driver = Path(__file__).with_name("main.swift")
    report = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu": command(["sysctl", "-n", "machdep.cpu.brand_string"]) if platform.system() == "Darwin" else platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "swift": command([swiftc, "--version"]),
            "python": platform.python_version(),
        },
        "provenance": {
            "baseline_revision": revision,
            "candidate_revision": command(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "relevant_status": command(["git", "-C", str(root), "status", "--short", "--", SCHEDULER, HELPER, *SUPPORT]),
            "baseline_scheduler_sha256": sha256(original),
            "baseline_adapter_sha256": sha256(baseline),
            "candidate_helper_sha256": sha256(candidate),
            "candidate_scheduler_sha256": sha256((root / SCHEDULER).read_bytes()),
            "driver_sha256": sha256(driver.read_bytes()),
            "runner_sha256": sha256(Path(__file__).read_bytes()),
            "support_sha256": {path: sha256((root / path).read_bytes()) for path in SUPPORT},
        },
        "method": {
            "compiler_flags": FLAGS,
            "module_flags": MODULE_FLAGS,
            "baseline": "Both neighborhood blocks copied from the pinned scheduler; only player.viewStore.playlist is adapted to the items parameter. The resulting arrays are returned through the same value type as the candidate.",
            "candidate": "Unmodified production ThumbnailPlaylistNeighborhood.swift.",
            "boundary": "Both helpers compiled as a separate optimized IlliquidApp module; identical unmodified IlliquidCore support sources and benchmark driver.",
            "sampling": "Fresh processes in balanced AB/BA pairs. One untimed warmup per process. Independent calibration per variant, capped at 1000000 calls.",
            "timer": "DispatchTime interval around repeated helper calls, output count consumption, and result destruction. Fixture creation, normalization, warmup, and exact output validation are outside the interval.",
            "scope": "Synchronous neighborhood preparation only; no actor scheduling, decoding, rendering, full-app latency, or energy measurement.",
            "memory_model": "Source-level removed intermediate URL array payload = playlist count * MemoryLayout<URL>.stride. This is not allocator, peak RSS, or total process memory measurement; shared URL backing objects and allocator overhead are excluded.",
            "rounds": args.rounds,
            "target_ms": args.target_ms,
            "counts": counts,
            "positions": POSITIONS,
        },
        "calibration": {},
        "receipts": {},
        "rows": [],
        "summaries": {},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".thumbnail-playlist-neighborhood-", dir=root) as temporary:
        work = Path(temporary)
        core = work / "core"
        core.mkdir()
        core_object = core / "IlliquidCore.o"
        subprocess.run([
            swiftc, *MODULE_FLAGS, "-emit-module", "-emit-object", "-module-name", "IlliquidCore",
            "-emit-module-path", str(core / "IlliquidCore.swiftmodule"),
            *[str(root / path) for path in SUPPORT], "-o", str(core_object),
        ], check=True)
        probes = {}
        for variant, source in [("baseline", baseline), ("candidate", candidate)]:
            directory = work / variant
            directory.mkdir()
            path = directory / "ThumbnailPlaylistNeighborhood.swift"
            path.write_bytes(source)
            object_file = directory / "IlliquidApp.o"
            subprocess.run([
                swiftc, *MODULE_FLAGS, "-I", str(core), "-emit-module", "-emit-object",
                "-module-name", "IlliquidApp", "-emit-module-path", str(directory / "IlliquidApp.swiftmodule"),
                str(path), "-o", str(object_file),
            ], check=True)
            probe = directory / "probe"
            subprocess.run([
                swiftc, *FLAGS, "-I", str(core), "-I", str(directory), str(driver),
                str(object_file), str(core_object), "-o", str(probe),
            ], check=True)
            probes[variant] = probe

        def run(variant: str, count: int, position: str, iterations: int) -> dict:
            result = json.loads(command([str(probes[variant]), str(count), position, str(iterations)], timeout=180))
            if (result["iterations"] != iterations or result["count"] != count
                    or result["position"] != position or result["elapsed_nanoseconds"] <= 0):
                raise RuntimeError("Invalid benchmark result")
            key = f"{count}/{position}"
            if key in report["receipts"] and report["receipts"][key] != result["receipt"]:
                raise RuntimeError("Exact output mismatch for " + key + "/" + variant)
            report["receipts"][key] = result["receipt"]
            stride = result["url_stride_bytes"]
            if report["environment"].setdefault("url_stride_bytes", stride) != stride:
                raise RuntimeError("URL layout differs between variants")
            return result

        for count in counts:
            for position in POSITIONS:
                key = f"{count}/{position}"
                iterations = {}
                calibration = {}
                for variant in ["baseline", "candidate"]:
                    sample = run(variant, count, position, 1)
                    iterations[variant] = max(1, min(1_000_000, math.ceil(args.target_ms * 1_000_000 / sample["elapsed_nanoseconds"])))
                    calibration[variant] = {
                        "nanoseconds": sample["elapsed_nanoseconds"],
                        "iterations": iterations[variant],
                    }
                report["calibration"][key] = calibration
                timings = {"baseline": [], "candidate": []}
                ratios = []
                for round_number in range(args.rounds):
                    order = ["baseline", "candidate"] if round_number % 2 == 0 else ["candidate", "baseline"]
                    pair = {}
                    for order_index, variant in enumerate(order):
                        result = run(variant, count, position, iterations[variant])
                        ns = result["elapsed_nanoseconds"] / result["iterations"]
                        pair[variant] = ns
                        timings[variant].append(ns)
                        report["rows"].append({
                            "case": key, "round": round_number, "order": order_index, "variant": variant,
                            "iterations": result["iterations"], "elapsed_nanoseconds": result["elapsed_nanoseconds"],
                            "nanoseconds_per_call": ns, "checksum": result["checksum"],
                        })
                    ratios.append(pair["baseline"] / pair["candidate"])
                summary = {
                    variant: {
                        "median_ns": statistics.median(values), "min_ns": min(values), "max_ns": max(values),
                    } for variant, values in timings.items()
                }
                summary.update({
                    "median_paired_speedup": statistics.median(ratios),
                    "candidate_faster_pairs": sum(value > 1 for value in ratios),
                    "pairs": args.rounds,
                    "removed_intermediate_url_payload_model_bytes": count * report["environment"]["url_stride_bytes"],
                })
                report["summaries"][key] = summary
                print(key, json.dumps(summary, sort_keys=True), flush=True)
    report["all_exact_receipts_equal"] = True
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    # Retain a readable receipt in job logs as well as the downloadable artifact.
    print("THUMBNAIL_NEIGHBORHOOD_REPORT_BEGIN", flush=True)
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    print("THUMBNAIL_NEIGHBORHOOD_REPORT_END", flush=True)


if __name__ == "__main__":
    main()
