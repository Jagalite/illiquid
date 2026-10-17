#!/usr/bin/env python3
"""Read back saved results; fail on missing pairs, altered binaries or summaries."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics


def verify(output: Path) -> dict:
    environment = json.loads((output / "environment.json").read_text())
    manifest = json.loads((output / "manifest.json").read_text())
    for name, expected in manifest["executables_sha256"].items():
        actual = hashlib.sha256((output / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"Executable hash changed: {name}")
    for name, expected in manifest["generated_sources_sha256"].items():
        actual = hashlib.sha256((output / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"Generated source changed: {name}")
    rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
    summary = json.loads((output / "summary.json").read_text())
    rounds = environment["rounds"]
    expected_count = len(summary) * rounds * 2
    if len(rows) != expected_count:
        raise ValueError(f"Expected {expected_count} measurements, found {len(rows)}")
    commands = [json.loads(line) for line in (output / "commands.jsonl").read_text().splitlines()]
    measured_commands = [record for record in commands
                         if Path(record["command"][0]).name in ["benchmark-baseline", "benchmark-candidate"]]
    if len(measured_commands) != len(rows):
        raise ValueError("Timing commands do not match recorded measurements")
    for row, record in zip(rows, measured_commands):
        if record["returncode"] != 0:
            raise ValueError("A timed process failed")
        raw = json.loads(record["stdout"])
        if any(row[key] != value for key, value in raw.items()):
            raise ValueError("Saved timing differs from process output")
        if not str(record["command"][0]).endswith("benchmark-" + row["variant"]):
            raise ValueError("Variant does not match executed binary")
        if record["command"][1:] != [row["scenario"], str(row["iterations"])]:
            raise ValueError("Timing inputs do not match executed command")
    keys = [(row["scenario"], row["round"], row["variant"]) for row in rows]
    if len(set(keys)) != len(keys):
        raise ValueError("Duplicate measurement")
    for entry in summary:
        scenario = entry["scenario"]
        values = {}
        for variant in ["baseline", "candidate"]:
            cohort = [row for row in rows if row["scenario"] == scenario and row["variant"] == variant]
            if sorted(row["round"] for row in cohort) != list(range(rounds)):
                raise ValueError(f"Missing round: {scenario}/{variant}")
            for row in cohort:
                first = "baseline" if row["round"] % 2 == 0 else "candidate"
                if row["order"] != (0 if row["variant"] == first else 1):
                    raise ValueError("Incorrect AB/BA order")
            values[variant] = statistics.median(row["elapsed_ns"] / row["iterations"] / 1_000 for row in cohort)
            if not math.isclose(values[variant], entry[variant + "_median_us"], rel_tol=1e-12):
                raise ValueError("Summary median does not match saved measurements")
        if not math.isclose(values["baseline"] / values["candidate"], entry["speedup"], rel_tol=1e-12):
            raise ValueError("Summary speedup does not match measurements")
    return {"verified_measurements": len(rows), "scenarios": len(summary), "rounds": rounds,
            "executable_hashes": len(manifest["executables_sha256"]),
            "generated_source_hashes": len(manifest["generated_sources_sha256"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.output.resolve()), indent=2))
