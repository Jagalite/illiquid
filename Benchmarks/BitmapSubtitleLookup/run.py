#!/usr/bin/env python3
"""Compare bitmap-subtitle timestamp lookup and pruning on macOS.

Reuses the existing native timeline qualification harness, including complete
production source compilation, exact ASSRenderedRegion extraction, source
hashing, debug/release tests, and balanced fresh-process measurements.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHARED = ROOT / "Benchmarks/BitmapSubtitleTimeline/run.py"
CASES = [
    "lookup-empty", "lookup-latest-1", "lookup-latest-8", "lookup-latest-32", "lookup-latest-128",
    "lookup-penultimate-8", "lookup-penultimate-32", "lookup-penultimate-128",
    "lookup-oldest-8", "lookup-oldest-32", "lookup-oldest-128", "lookup-middle-128",
    "lookup-before-128", "lookup-mixed-8", "lookup-mixed-32", "lookup-mixed-128",
    "prune-noop-8", "prune-noop-32", "prune-noop-128",
    "stream-8", "stream-32", "stream-128",
]


def main() -> None:
    spec = importlib.util.spec_from_file_location("timeline_qualification", SHARED)
    if spec is None or spec.loader is None:
        raise RuntimeError("Timeline qualification harness unavailable")
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    harness.__doc__ = __doc__
    harness.HERE = HERE
    harness.ROOT = ROOT
    harness.CASES = CASES
    harness.TESTS = [*harness.TESTS, "BitmapSubtitleTimelineLookupTests.swift"]
    original_summarize = harness.summarize

    def summarize(records: list[dict]) -> dict:
        # The shared driver also verifies each complete receipt against an
        # independent oracle. Compare decoded paired receipts here as well.
        output = Path(harness_output[0])
        for case in dict.fromkeys(row["case"] for row in records):
            for seed in {row["seed"] for row in records if row["case"] == case}:
                paths = [output / "receipts" / f"{variant}-{case}-{seed}.json"
                         for variant in ("baseline", "candidate")]
                if not all(path.exists() for path in paths):
                    raise RuntimeError(f"Missing paired receipt: {case}/{seed}")
                if json.loads(paths[0].read_text()) != json.loads(paths[1].read_text()):
                    raise RuntimeError(f"Exact receipt mismatch: {case}/{seed}")
        return original_summarize(records)

    # Capture the output directory from the harness's existing run boundary;
    # no command, source, calibration, or timing result is rewritten.
    harness_output: list[str] = []
    original_run = harness.run

    def run(command: list[str], output: Path, **kwargs) -> str:
        harness_output[:] = [str(output)]
        return original_run(command, output, **kwargs)

    original_write_json = harness.write_json

    def write_json(path: Path, value: object) -> None:
        if path.name == "manifest.json" and isinstance(value, dict):
            value["lookup_runner_sha256"] = harness.digest(Path(__file__).read_bytes())
            value["operation_units"] = {
                "lookup": "one composition(at:) query",
                "prune": "one prune(before:) call with nothing old to remove",
                "stream": "one prune + insert + query step at fixed timeline occupancy",
            }
        original_write_json(path, value)

    harness.run = run
    harness.summarize = summarize
    harness.write_json = write_json
    harness.main()


if __name__ == "__main__":
    main()
