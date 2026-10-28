#!/usr/bin/env python3
"""Measure timing variability by running the same baseline binary under both labels."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def describe(values):
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--case", default="exact_256")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("pairs must be even and >= 2")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    source = args.source.resolve()
    manifest = json.loads((source / "manifest.json").read_text())
    calibration = json.loads((source / "calibrations.json").read_text())[args.case]
    binary = Path(manifest["binaries"]["baseline"]["path"])
    if sha(binary) != manifest["binaries"]["baseline"]["sha256"]:
        raise ValueError("Baseline binary does not match its source receipt")
    iterations = calibration["iterations"]
    env = os.environ.copy()
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    started_utc = datetime.now(timezone.utc).isoformat()
    rows = []
    raw_path = output / "observations.jsonl"
    for pair in range(args.pairs):
        order = ("A", "B") if pair % 2 == 0 else ("B", "A")
        for position, label in enumerate(order):
            result = subprocess.run(
                [str(binary), "--case", args.case, "--iterations", str(iterations), "--warmup", "4"],
                env=env, capture_output=True, text=True, check=True, timeout=180,
            )
            row = json.loads(result.stdout)
            if (row["caseName"] != args.case or row["iterations"] != iterations
                    or row["checksum"] != row["expectedChecksum"]):
                raise ValueError("Identical-binary observation failed validation")
            row.update(label=label, pair=pair, orderIndex=position)
            rows.append(row)
            with raw_path.open("a") as stream:
                stream.write(json.dumps(row, sort_keys=True) + "\n")
    persisted = [json.loads(line) for line in raw_path.read_text().splitlines()]
    grid = {(row["label"], row["pair"]) for row in persisted}
    expected = {(label, pair) for label in ("A", "B") for pair in range(args.pairs)}
    if persisted != rows or len(persisted) != 2 * args.pairs or grid != expected:
        raise ValueError("Incomplete retained identical-binary observations")
    groups = {label: sorted((row for row in persisted if row["label"] == label),
                           key=lambda row: row["pair"]) for label in ("A", "B")}
    summary = {"purpose": "Identical baseline binary under both labels", "caseName": args.case,
               "pairs": args.pairs, "rowCount": len(persisted)}
    for metric in ("cpuNsPerAssociation", "wallNsPerAssociation"):
        changes = [100 * (groups["B"][index][metric] / groups["A"][index][metric] - 1)
                   for index in range(args.pairs)]
        summary[metric] = {
            "A": describe([row[metric] for row in groups["A"]]),
            "B": describe([row[metric] for row in groups["B"]]),
            "pairedChangePercent": describe(changes),
            "BFasterPairs": sum(change < 0 for change in changes),
        }
    receipt = {
        "startedUTC": started_utc,
        "sourceManifestSHA256": sha(source / "manifest.json"),
        "binarySHA256": sha(binary), "binaryPath": str(binary),
        "sourceBaselineCommit": manifest["baselineCommit"],
        "compiler": manifest["compiler"], "platform": manifest["platform"],
        "caseName": args.case, "pairs": args.pairs, "iterations": iterations,
        "hashing": "SWIFT_DETERMINISTIC_HASHING=1",
        "observationsSHA256": sha(raw_path), "scriptSHA256": sha(Path(__file__)),
    }
    write_json(output / "manifest.json", receipt)
    write_json(output / "summary.json", summary)
    for name in ("manifest.json", "summary.json"):
        print("FUZZY_AA_EVIDENCE " + json.dumps(
            {"file": name, "value": json.loads((output / name).read_text())}, sort_keys=True))
    for row in persisted:
        print("FUZZY_AA_EVIDENCE " + json.dumps(
            {"file": "observations.jsonl", "value": row}, sort_keys=True))


if __name__ == "__main__":
    main()
