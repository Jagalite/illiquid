#!/usr/bin/env python3
"""Run isolated alternatives against the frozen production baseline."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OLD_LOOP = "        for mediaURL in Array(result.keys) {\n            guard !isCancelled() else { return [:] }\n            result[mediaURL] = NaturalFilenameOrdering.sort(result[mediaURL, default: []])\n        }"
INDEXED_LOOP = "        // Value-only mutation preserves indices. A standalone cursor avoids\n        // retaining the dictionary through an indices view while sorting.\n        var resultIndex = result.startIndex\n        while resultIndex != result.endIndex {\n            guard !isCancelled() else { return [:] }\n            if result.values[resultIndex].count > 1 {\n                result.values[resultIndex] = NaturalFilenameOrdering.sort(result.values[resultIndex])\n            }\n            result.formIndex(after: &resultIndex)\n        }"
GUARDED_LOOP = """        for mediaURL in Array(result.keys) {
            guard !isCancelled() else { return [:] }
            let subtitles = result[mediaURL, default: []]
            if subtitles.count > 1 {
                result[mediaURL] = NaturalFilenameOrdering.sort(subtitles)
            }
        }"""
OLD_WEIGHT = """        let sharedTokens = Array(mediaTokens.prefix(sharedCount))
        let sharedWeight = tokenWeight(sharedTokens)"""
SLICE_WEIGHT = """        let sharedWeight = mediaTokens.prefix(sharedCount).reduce(0) { $0 + $1.count }"""
CASES = ",".join([
    "one_to_one_16", "one_to_one_256", "two_subtitles_256",
    "multilingual_256", "sparse_1024", "broad_prefix_1024",
    "unicode_256", "empty_16",
])


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise RuntimeError("Expected exactly one frozen baseline substitution")
    return source.replace(before, after, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--target-ms", type=int, default=75)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be empty")
    if args.pairs <= 0 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("--pairs must be positive and even; --target-ms must be positive")
    baseline = (HERE / "baseline/ExternalSubtitleMatcher.swift").read_text()
    variants = {
        "guard_only": replace_once(baseline, OLD_LOOP, GUARDED_LOOP),
        "slice_only": replace_once(baseline, OLD_WEIGHT, SLICE_WEIGHT),
        "indexed_and_slice": replace_once(
            replace_once(baseline, OLD_LOOP, INDEXED_LOOP), OLD_WEIGHT, SLICE_WEIGHT
        ),
    }
    sources = output / "variants"
    sources.mkdir()
    for name, source in variants.items():
        matcher = sources / (name + ".swift")
        matcher.write_text(source)
        print("CAMPAIGN " + name, flush=True)
        subprocess.run([
            sys.executable, str(HERE / "run.py"),
            "--output", str(output / name),
            "--mode", "benchmark",
            "--pairs", str(args.pairs),
            "--target-ms", str(args.target_ms),
            "--cases", CASES,
            "--candidate-matcher", str(matcher),
        ], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
