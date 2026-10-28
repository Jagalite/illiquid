#!/usr/bin/env python3
"""Compare real checkpoint ID projection in isolated optimized Swift processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Benchmarks/PlaylistCheckpointIDs/Harness.swift",
]
INPUTS = SOURCES + ["Benchmarks/PlaylistCheckpointIDs/run.py"]
SCENARIOS = ["unchanged", "edited", "duplicates", "no-base"]


def positive(value: str) -> int:
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def method(source: str, name: str) -> str:
    # These baseline functions contain no string/comment brace literals.
    start = source.index("func " + name + "(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=positive, nargs="+", default=[32, 100, 1000, 10000])
    parser.add_argument("--pairs", type=positive, default=7)
    parser.add_argument("--target-ms", type=positive, default=60)
    parser.add_argument("--memory-size", type=positive, default=50000)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-improvement", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("--output must be an empty or new directory")
    out.mkdir(parents=True, exist_ok=True)
    commands: list[dict] = []
    observations: list[dict] = []

    def save(name: str, value: object) -> None:
        (out / name).write_text(json.dumps(value, indent=2) + "\n")

    def run(command: list[str]) -> str:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        commands.append({
            "argv": command, "returncode": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr,
        })
        save("commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command}\n{result.stderr}")
        return result.stdout

    flags = ["-O", "-swift-version", "6"]
    manifest = {
        "candidate_commit": run(["git", "rev-parse", "HEAD"]).strip(),
        "baseline_commit": BASE,
        "working_tree_status": run(["git", "status", "--porcelain"]),
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "swift": run(["swiftc", "--version"]).strip(),
        "flags": flags,
        "arguments": {**vars(args), "output": str(out)},
        "source_sha256": {
            path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
            for path in INPUTS
        },
        "metric_scope": "selected-source checkpoint projection, not full player",
        "rss_scope": "fresh-process maximum resident set; not exact allocations",
    }
    if platform.system() == "Darwin":
        manifest["macos"] = run(["sw_vers"]).strip()
        manifest["xcode"] = run(["xcodebuild", "-version"]).strip()
    save("manifest.json", manifest)
    for path in SOURCES[:3]:
        assert run(["git", "show", f"{BASE}:{path}"]) == (ROOT / path).read_text()
    original = run(["git", "show", f"{BASE}:{SOURCES[3]}"])
    current = (ROOT / SOURCES[3]).read_text()
    for name in ["restoringOrder", "deduplicated", "uniqueResult"]:
        assert method(original, name) == method(current, name), f"baseline changed: {name}"
    save("baseline-verification.json", {
        "dependencies_unchanged": True, "baseline_methods_unchanged": True,
    })
    for path in INPUTS:
        target = out / "sources" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / path).read_bytes())

    with tempfile.TemporaryDirectory(prefix="illiquid-checkpoint-") as directory:
        binary = str(Path(directory) / "checkpoint")
        run(["swiftc", *flags, *(str(ROOT / path) for path in SOURCES), "-o", binary])
        manifest["binary_sha256"] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        save("manifest.json", manifest)

        def measure(
            mode: str, variant: str, count: int, scenario: str, iterations: int,
            **labels: object,
        ) -> dict:
            row = json.loads(run([
                binary, mode, variant, str(count), scenario, str(iterations),
            ]))
            row.update(labels)
            observations.append(row)
            save("observations.json", observations)
            return row

        summaries = []
        for count in args.sizes:
            for scenario in SCENARIOS:
                parity = measure("parity", "candidate", count, scenario, 1)
                expected_checksum = parity["checksum"]
                pilots = []
                for variant in ["baseline", "candidate"]:
                    pilot = measure(
                        "timing", variant, count, scenario, 1, phase="calibration"
                    )
                    assert pilot["checksum"] == expected_checksum
                    pilots.append(pilot["ns_per_operation"])
                # Same repetition count for both variants; aim for at least
                # target-ms in the faster variant as well as the slower one.
                iterations = min(10000, max(
                    1, math.ceil(args.target_ms * 1_000_000 / min(pilots)),
                ))
                pairs = []
                for pair in range(args.pairs):
                    order = (
                        ["baseline", "candidate"] if pair % 2 == 0
                        else ["candidate", "baseline"]
                    )
                    measured = {}
                    for variant in order:
                        row = measure(
                            "timing", variant, count, scenario, iterations,
                            phase="measurement", pair=pair, order=order,
                        )
                        assert row["checksum"] == expected_checksum
                        measured[variant] = row["ns_per_operation"]
                    pairs.append(measured)
                ratios = [p["baseline"] / p["candidate"] for p in pairs]
                before = statistics.median(p["baseline"] for p in pairs)
                after = statistics.median(p["candidate"] for p in pairs)
                summary = {
                    "count": count, "scenario": scenario, "pairs": len(pairs),
                    "iterations": iterations,
                    "baseline_ms": before / 1e6, "candidate_ms": after / 1e6,
                    "reduction_percent": 100 * (1 - after / before),
                    "paired_speedup_median": statistics.median(ratios),
                    "paired_speedup_min": min(ratios),
                    "paired_speedup_max": max(ratios),
                }
                summaries.append(summary)
                save("timing-summary.json", summaries)
                print("TIMING " + json.dumps(summary), flush=True)

        memory_summaries = []
        for scenario in SCENARIOS:
            expected_checksum = measure(
                "parity", "candidate", args.memory_size, scenario, 1
            )["checksum"]
            samples = {"baseline": [], "candidate": []}
            for pair in range(args.pairs):
                order = (
                    ["baseline", "candidate"] if pair % 2 == 0
                    else ["candidate", "baseline"]
                )
                for variant in order:
                    row = measure(
                        "memory", variant, args.memory_size, scenario, 1,
                        pair=pair, order=order,
                    )
                    assert row["checksum"] == expected_checksum
                    samples[variant].append(row)
            summary = {
                "count": args.memory_size, "scenario": scenario, "pairs": args.pairs,
            }
            for variant, rows in samples.items():
                for key in [
                    "fixture_peak_rss_bytes", "peak_rss_bytes", "peak_growth_bytes",
                ]:
                    values = [row[key] for row in rows]
                    summary[f"{variant}_{key}_median"] = statistics.median(values)
                    summary[f"{variant}_{key}_range"] = [min(values), max(values)]
            memory_summaries.append(summary)
            save("memory-summary.json", memory_summaries)
            print("MEMORY " + json.dumps(summary), flush=True)

        primary = next(
            row for row in summaries
            if row["count"] == max(args.sizes) and row["scenario"] == "unchanged"
        )
        qualified = (
            args.pairs >= 5 and primary["paired_speedup_median"] >= 1.10
            and primary["paired_speedup_min"] > 1
        )
        completion = {
            "parity_passed": True,
            "performance_qualified": qualified,
            "criterion": (
                "largest unchanged case: >=5 pairs, median speedup >=1.10, all pairs >1"
            ),
            "rss_qualified": False,
            "rss_note": (
                "contextual process high-water data, not allocation attribution"
            ),
        }
        save("completion.json", completion)
        print("COMPLETION " + json.dumps(completion), flush=True)
        # Keep raw machine-readable receipts retrievable through job logs too.
        # Sources and command stdout/stderr remain in the uploaded artifact.
        for name in [
            "manifest.json", "baseline-verification.json",
            "timing-summary.json", "memory-summary.json", "completion.json",
        ]:
            print("RECEIPT " + json.dumps({
                "name": name, "content": json.loads((out / name).read_text()),
            }), flush=True)
        for row in observations:
            print("OBSERVATION " + json.dumps(row), flush=True)
        if args.require_improvement and not qualified:
            raise SystemExit("Primary improvement criterion was not met")


if __name__ == "__main__":
    main()
