#!/usr/bin/env python3
"""Print compact, lossless benchmark receipts for inspection through CI logs.

The workflow artifact remains the full evidence bundle. Each line is one JSON
file or one JSONL/summary record, so large cohorts do not exceed log line limits.
This runs only after successful test and measurement steps; it also requires
every expected cohort's completion marker before printing anything.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--allocations", action="store_true")
    args = parser.parse_args()
    root = args.directory
    cohorts = ["timing"] + (["allocations"] if args.allocations else [])
    for cohort in cohorts:
        completion = json.loads((root / cohort / "completion.json").read_text())
        expected = 216 if cohort == "timing" else 72
        if completion != {"complete": True, "cases": 18, "measurements": expected}:
            raise ValueError(f"Incomplete {cohort} cohort: {completion}")

    def emit(path: str, value: object, index: int | None = None) -> None:
        record = {"path": path, "value": value}
        if index is not None:
            record["index"] = index
        print("SOURCE_SEARCH_EVIDENCE " + json.dumps(record, sort_keys=True), flush=True)

    emit("host.txt", (root / "host.txt").read_text())
    for variant in ("baseline", "candidate"):
        for configuration in ("debug", "release"):
            prefix = f"{variant}-{configuration}"
            receipt = json.loads((root / prefix / "receipt.json").read_text())
            if receipt["exit_code"] != 0 or receipt["test_count"] < 1:
                raise ValueError(f"No passing tests for {prefix}")
            emit(f"{prefix}/receipt.json", receipt)
            emit(f"{prefix}/test.log", (root / prefix / "test.log").read_text())
    for cohort in cohorts:
        for filename in ("environment.json", "baseline-build.json", "candidate-build.json", "completion.json"):
            path = f"{cohort}/{filename}"
            emit(path, json.loads((root / path).read_text()))
        path = f"{cohort}/measurements.jsonl"
        for index, line in enumerate((root / path).read_text().splitlines()):
            emit(path, json.loads(line), index)
        path = f"{cohort}/summary.json"
        for index, summary in enumerate(json.loads((root / path).read_text())):
            emit(path, summary, index)


if __name__ == "__main__":
    main()
