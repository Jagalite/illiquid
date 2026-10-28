#!/usr/bin/env python3
"""Compare native Swift restoration time and populated-map live-heap storage."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AREA = Path("Benchmarks/PlaylistRestorationMemory")
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TARGET = "Sources/IlliquidCore/Playlist/PlaylistMutation.swift"
BASELINE_BLOB = "ff86a4830377c695df8ac700cd0fdff194b4f778"
DEPENDENCIES = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
SCENARIOS = ("unchanged", "edited", "duplicates", "no-base")
FLAGS = [
    "-swift-version", "6", "-O", "-whole-module-optimization",
    "-parse-as-library", "-warnings-as-errors",
]
MARKER = "        var restored: [FolderPlaylistItem] = []\n"
INJECTION = (
    "        restoration_memory_checkpoint(UInt64(byID.count), "
    "UInt64(byID.capacity), UInt64(currentOrder.capacity))\n"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def positive(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def save_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sizes", type=positive, nargs="+", default=[100, 10_000, 100_000])
    parser.add_argument("--pairs", type=positive, default=8)
    parser.add_argument("--rounds", type=positive, default=3)
    args = parser.parse_args()
    native = platform.system() == "Darwin"
    if platform.system() not in ("Darwin", "Linux"):
        raise SystemExit("This experiment supports macOS and glibc Linux.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "receipts.json").exists():
        raise SystemExit("Use a fresh output directory so observations cannot be mixed.")

    driver_paths = [AREA / name for name in ("Harness.swift", "MemoryProbe.h", "MemoryProbe.c", "run.py")]
    tracked = [Path(TARGET), *(Path(path) for path in DEPENDENCIES), *driver_paths]
    start_hashes = {str(path): sha256((ROOT / path).read_bytes()) for path in tracked}
    baseline = git("show", f"{BASELINE}:{TARGET}")
    if git_blob(baseline) != BASELINE_BLOB:
        raise SystemExit("Pinned baseline source does not match the reviewed Git blob.")
    candidate = (ROOT / TARGET).read_bytes()
    sources = {"baseline": baseline, "candidate": candidate}

    receipts = {
        "baseline_commit": BASELINE,
        "baseline_target_blob": BASELINE_BLOB,
        "candidate_commit": git("rev-parse", "HEAD").decode().strip(),
        "git_status": git("status", "--porcelain").decode(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "sw_vers": subprocess.check_output(["sw_vers"], text=True).strip() if native else None,
        "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
        "compiler_flags": FLAGS,
        "environment": {key: os.environ.get(key) for key in ("DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING")},
        "sizes": args.sizes,
        "pairs": args.pairs,
        "rounds": args.rounds,
        "timing": "Uninstrumented production sources; warm-up and full-item equality outside timing.",
        "memory": (
            "malloc_zone_statistics(NULL).size_in_use delta at populated map; not peak or RSS."
            if native else "glibc mallinfo2 uordblks+hblkhd delta at populated map, including allocator caches; not macOS live heap or RSS."
        ),
        "instrumentation": {"marker": MARKER, "inserted_before_marker": INJECTION},
        "input_sha256": start_hashes,
        "source_sha256": {},
        "binary_sha256": {},
        "build_commands": [],
    }
    driver = output / "driver"
    driver.mkdir()
    for path in driver_paths:
        (driver / path.name).write_bytes((ROOT / path).read_bytes())

    def command(arguments: list[str], log_name: str) -> None:
        receipts["build_commands"].append(arguments)
        save_json(output / "receipts.json", receipts)
        with (output / log_name).open("w") as log:
            subprocess.run(arguments, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)

    probe = output / "MemoryProbe.o"
    command([*(["xcrun", "clang"] if native else ["clang"]), "-O2", "-Wall", "-Wextra", "-Werror",
             "-c", str(driver / "MemoryProbe.c"), "-o", str(probe)], "build-probe.log")
    executables = {}
    for variant, source in sources.items():
        for mode in ("timing", "memory"):
            directory = output / "sources" / variant / mode
            directory.mkdir(parents=True)
            text = source.decode()
            if mode == "memory":
                if text.count(MARKER) != 1:
                    raise SystemExit("Expected exactly one restoration instrumentation marker.")
                text = text.replace(MARKER, INJECTION + MARKER)
            target_copy = directory / Path(TARGET).name
            target_copy.write_text(text)
            inputs = [target_copy]
            for dependency in DEPENDENCIES:
                path = directory / Path(dependency).name
                # Identical current dependencies isolate the map representation.
                path.write_bytes((ROOT / dependency).read_bytes())
                inputs.append(path)
            for path in inputs:
                receipts["source_sha256"][str(path.relative_to(output))] = sha256(path.read_bytes())
            executable = output / f"{variant}-{mode}"
            arguments = ["swiftc", *FLAGS]
            if mode == "memory":
                arguments += ["-D", "RESTORATION_MEMORY"]
            arguments += [
                "-import-objc-header", str(driver / "MemoryProbe.h"),
                *(str(path) for path in inputs), str(driver / "Harness.swift"),
                str(probe), "-o", str(executable),
            ]
            command(arguments, f"build-{variant}-{mode}.log")
            receipts["binary_sha256"][executable.name] = sha256(executable.read_bytes())
            executables[variant, mode] = executable
    save_json(output / "receipts.json", receipts)

    rows = []
    summaries = []
    raw_path = output / "samples.jsonl"
    # Fresh processes, paired with balanced AB/BA order, and identical work.
    for mode in ("memory", "timing"):
        for count in args.sizes:
            for scenario in SCENARIOS:
                if mode == "memory" and scenario == "no-base":
                    continue  # This guard creates no restoration map to sample.
                case = []
                for pair in range(args.pairs):
                    variants = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    pair_rows = {}
                    for position, variant in enumerate(variants):
                        result = subprocess.run(
                            [str(executables[variant, mode]), mode, str(count), scenario, str(args.rounds)],
                            text=True, capture_output=True, check=False,
                        )
                        if result.returncode != 0:
                            (output / f"failed-{mode}-{count}-{scenario}-{pair}-{variant}.log").write_text(
                                result.stdout + "\n" + result.stderr
                            )
                            raise RuntimeError("Harness failed; inspect the retained failure log.")
                        row = json.loads(result.stdout)
                        assert row["fullItemsEqual"] is True
                        assert row["requestedCount"] == count and row["scenario"] == scenario
                        row.update(variant=variant, pair=pair, position=position)
                        pair_rows[variant] = row
                        case.append(row)
                        rows.append(row)
                        with raw_path.open("a") as stream:
                            stream.write(json.dumps(row, sort_keys=True) + "\n")
                    before, after = pair_rows["baseline"], pair_rows["candidate"]
                    for key in ("inputCount", "savedIDCount", "validatedItemCount", "itemStride", "indexStride"):
                        assert before[key] == after[key], f"Different fixtures/layouts: {key}"
                    if mode == "memory":
                        for key in ("mapCapacity", "orderCapacity", "checkpointCount"):
                            assert before[key] == after[key], f"Different container shape: {key}"
                metric = "checkpointDeltaBytes" if mode == "memory" else "milliseconds"
                values = {
                    variant: [
                        row[metric] if mode == "memory" else statistics.median(row[metric])
                        for row in case if row["variant"] == variant
                    ]
                    for variant in ("baseline", "candidate")
                }
                before = statistics.median(values["baseline"])
                after = statistics.median(values["candidate"])
                paired_reductions = [
                    100 * (1 - right / left) for left, right in zip(values["baseline"], values["candidate"])
                ]
                summary = {
                    "mode": mode, "count": count, "scenario": scenario, "pairs": args.pairs,
                    "metric": (
                        ("populated_map_live_heap_delta_bytes" if native else "populated_map_glibc_allocator_delta_bytes")
                        if mode == "memory" else "call_milliseconds"
                    ),
                    "baseline_median": before, "candidate_median": after,
                    "median_saving": before - after,
                    "median_reduction_percent": 100 * (1 - after / before),
                    "baseline_range": [min(values["baseline"]), max(values["baseline"])],
                    "candidate_range": [min(values["candidate"]), max(values["candidate"])],
                    "paired_reduction_percent_range": [min(paired_reductions), max(paired_reductions)],
                }
                summaries.append(summary)
                save_json(output / "summary.json", summaries)
                print(json.dumps(summary, sort_keys=True), flush=True)

    end_hashes = {str(path): sha256((ROOT / path).read_bytes()) for path in tracked}
    if end_hashes != start_hashes:
        raise RuntimeError("Source files changed during qualification.")
    receipts["source_unchanged_after_run"] = True
    receipts["process_observations"] = len(rows)
    receipts["full_item_validation"] = "passed in every warm-up and measured call"
    save_json(output / "receipts.json", receipts)
    print(json.dumps({"observations": len(rows), "source_unchanged": True}), flush=True)


if __name__ == "__main__":
    main()
