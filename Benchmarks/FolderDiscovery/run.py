#!/usr/bin/env python3
"""Compare real folder discovery sources; fixture creation/JSON encoding are untimed.

Usage: python3 run.py --baseline-root /path/to/base --candidate-root /path/to/head --output results.json
Requires Swift 6.1+ and Python 3.10+. Sources are compiled unmodified with -O.
This measures warm local filesystem scans, not native UI latency or NAS behavior.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path

SOURCES = [
    "Playlist/ExternalSubtitleMatcher.swift", "Playlist/FolderPlaylist.swift",
    "Playlist/FolderPlaylistDiscovery.swift", "Playlist/PlaylistMutation.swift",
    "Utilities/MediaFileSupport.swift", "Utilities/NaturalFilenameOrdering.swift",
    "Utilities/NormalizedFileURL.swift",
]

def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()

def compile_probe(root: Path, output: Path, driver: Path) -> dict[str, str]:
    paths = [root / "Sources/IlliquidCore" / source for source in SOURCES]
    subprocess.run(["swiftc", "-swift-version", "6", "-O", *map(str, paths), str(driver), "-o", str(output)], check=True)
    return {source: git_blob(path.read_bytes()) for source, path in zip(SOURCES, paths)}

def fixtures(root: Path) -> dict[str, Path]:
    result = {}
    # Ordinary files are empty: discovery inspects identity/metadata, never media contents.
    for name, media, subtitles, unrelated in [
        ("empty", 0, 0, 0), ("small", 3, 3, 0), ("media-only", 250, 0, 0),
        ("mixed", 25, 25, 5000), ("unsupported-only", 0, 0, 5000),
        ("subtitle-heavy", 25, 1000, 0),
    ]:
        folder = root / name
        folder.mkdir()
        result[name] = folder
        for i in range(media): (folder / f"Feature {i:04}.mkv").touch()
        for i in range(subtitles): (folder / f"Feature {i:04}.en.srt").touch()
        for i in range(unrelated): (folder / f"notes-{i:05}.txt").touch()
    folder = root / "symlink-rich"
    targets = root / "targets"
    folder.mkdir(); targets.mkdir()
    result["symlink-rich"] = folder
    for i in range(100):
        for suffix in ["mkv", "srt", "txt"]:
            target = targets / f"Feature {i:04}.{suffix}"
            target.touch()
            # Deliberately no supported extension in the visible aliases.
            (folder / f"alias-{i:04}-{suffix}").symlink_to(target)
    (folder / "broken").symlink_to(targets / "missing.mkv")
    (folder / "directory.mkv").symlink_to(targets, target_is_directory=True)
    (targets / ".Hidden.mkv").touch()
    (folder / ".hidden-alias").symlink_to(targets / ".Hidden.mkv")
    return result

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--candidate-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=9)
    args = parser.parse_args()
    if args.repetitions < 1: parser.error("--repetitions must be positive")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    driver = Path(__file__).resolve().with_name("main.swift")
    report = {"platform": platform.platform(), "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
              "method": "Fresh processes; one excluded warm-up pair per fixture; alternating pair order; warm local filesystem; discover-only timer.",
              "driver_blob": git_blob(driver.read_bytes()), "source_blobs": {}, "rows": [], "summaries": {}}
    receipts = {}
    with tempfile.TemporaryDirectory(prefix="illiquid-folder-benchmark-") as temporary:
        work = Path(temporary)
        probes = {}
        for variant, root in [("baseline", args.baseline_root), ("candidate", args.candidate_root)]:
            probes[variant] = work / variant
            report["source_blobs"][variant] = compile_probe(root, probes[variant], driver)
        cases = fixtures(work)
        expected_counts = {"empty": 0, "small": 3, "media-only": 250, "mixed": 25,
                           "unsupported-only": 0, "subtitle-heavy": 25, "symlink-rich": 100}
        for case, folder in cases.items():
            timing = {"baseline": [], "candidate": []}
            for iteration in range(-1, args.repetitions):
                order = ["baseline", "candidate"] if iteration % 2 == 0 else ["candidate", "baseline"]
                for position, variant in enumerate(order):
                    receipt = json.loads(subprocess.check_output([str(probes[variant]), str(folder)], timeout=60))
                    elapsed = receipt.pop("elapsedNanoseconds")
                    if len(receipt["items"]) != expected_counts[case]:
                        raise RuntimeError(f"Unexpected item count: {case}/{variant}")
                    canonical = json.dumps(receipt, sort_keys=True, separators=(",", ":"))
                    digest = hashlib.sha256(canonical.encode()).hexdigest()
                    if case in receipts and receipt != receipts[case]:
                        raise RuntimeError(f"Playlist/metadata mismatch: {case}/{variant}/round {iteration}")
                    receipts[case] = receipt
                    report["rows"].append({"case": case, "round": iteration, "order": position, "variant": variant,
                                           "nanoseconds": elapsed, "receipt_sha256": digest})
                    if iteration >= 0: timing[variant].append(elapsed / 1_000_000)
            summary = {variant: {"median_ms": statistics.median(values), "min_ms": min(values), "max_ms": max(values)}
                       for variant, values in timing.items()}
            summary["candidate_delta_percent"] = (summary["candidate"]["median_ms"] / summary["baseline"]["median_ms"] - 1) * 100
            summary["media_count"] = expected_counts[case]
            report["summaries"][case] = summary
            print(case, json.dumps(summary), flush=True)
    report["all_receipts_equal"] = True
    # Raw receipts include temporary paths and metadata timestamps for reproducibility.
    output.write_text(json.dumps(report, indent=2) + "\n")
    output.with_suffix(".receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")

if __name__ == "__main__":
    main()
