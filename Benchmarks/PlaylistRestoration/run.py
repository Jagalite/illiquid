#!/usr/bin/env python3
"""Fresh-process, alternating-order comparison of actual Swift playlist sources."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Benchmarks/PlaylistRestoration/Baseline.swift",
    "Benchmarks/PlaylistRestoration/main.swift",
]
SCENARIOS = ("unchanged", "edited", "duplicates", "no-base")


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=positive_int, nargs="+", default=[100, 1000, 10000])
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument("--repeats", type=positive_int, default=5)
    parser.add_argument("--rounds", type=positive_int, default=3)
    parser.add_argument("--output", type=Path, default=Path("playlist-restoration-results.json"))
    args = parser.parse_args()
    results = {
        "platform": platform.platform(),
        "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
        "compiler_flags": ["-O", "-swift-version", "6"],
        "source_sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES},
        "sizes": args.sizes, "scenarios": args.scenarios, "repeats": args.repeats, "rounds": args.rounds,
        "runs": [], "summary": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save() -> None:
        args.output.write_text(json.dumps(results, ensure_ascii=False, separators=(",", ":")) + "\n")

    with tempfile.TemporaryDirectory(prefix="illiquid-playlist-bench-") as directory:
        executable = str(Path(directory) / "playlist-bench")
        subprocess.run(["swiftc", "-O", "-swift-version", "6",
                        *(str(ROOT / name) for name in SOURCES), "-o", executable], check=True)
        for count in args.sizes:
            for scenario in args.scenarios:
                samples = {"baseline": [], "candidate": []}
                for repeat in range(args.repeats):
                    # Swap which implementation runs first in consecutive pairs.
                    variants = ("baseline", "candidate") if repeat % 2 == 0 else ("candidate", "baseline")
                    for variant in variants:
                        output = subprocess.check_output(
                            [executable, variant, str(count), scenario, str(args.rounds)], text=True)
                        row = json.loads(output)
                        row["repeat"] = repeat
                        results["runs"].append(row)
                        save()
                        samples[variant].append(statistics.median(row["milliseconds"]))
                before, after = (statistics.median(samples[key]) for key in ("baseline", "candidate"))
                summary = {"count": count, "scenario": scenario,
                           "baseline_median_ms": before, "candidate_median_ms": after,
                           "reduction_percent": 100 * (1 - after / before)}
                results["summary"].append(summary)
                save()
                print(json.dumps(summary), flush=True)
    save()


if __name__ == "__main__":
    main()
