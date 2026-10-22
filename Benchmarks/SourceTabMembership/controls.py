#!/usr/bin/env python3
"""Compare fixed-count A/B and independent A/A samples of existing probe binaries."""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import statistics

from run import HERE, SEED, Runner, measurement, save, sha


CASES = (
    "files-1-hit", "files-1-miss", "folders-1-hit", "folders-1-miss",
    "files-1000-first", "folders-1000-first",
)
COMPARISONS = {
    "baseline-vs-baseline": {"A": "baseline", "B": "baseline"},
    "baseline-vs-candidate": {"A": "baseline", "B": "candidate"},
}


def contained_path(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    if Path(relative).is_absolute() or not path.is_relative_to(root.resolve()):
        raise RuntimeError(f"Receipt path is outside its evidence directory: {relative}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True,
                        help="Existing run.py output with its original built packages")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--iterations", type=int, default=2048,
                        help="Fixed 16-query batches per sample, identical for all labels")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer of at least 2")
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    evidence = args.evidence.resolve()
    output = evidence / "control-check"
    if output.exists() and any(output.iterdir()):
        parser.error("The evidence/control-check directory must be new or empty")

    receipt_names = ("manifest", "source-receipts", "build-receipts", "verification", "tests")
    receipt_bytes = {name: (evidence / f"{name}.json").read_bytes() for name in receipt_names}
    parent = {name: json.loads(data) for name, data in receipt_bytes.items()}
    parent_manifest = parent["manifest"]
    if parent_manifest["inputs"]["run.py"] != sha((HERE / "run.py").read_bytes()):
        raise RuntimeError("run.py changed since the parent experiment; measurement helpers differ")
    if parent_manifest["method"]["seed"] != SEED:
        raise RuntimeError("Parent experiment used a different fixture seed")
    if parent["verification"]["baseline"] != parent["verification"]["candidate"]:
        raise RuntimeError("Parent experiment did not establish exact input/output parity")

    binaries = {}
    for variant in ("baseline", "candidate"):
        for configuration in ("debug", "release"):
            test = parent["tests"][variant][configuration]
            if test["passed"] is not True or test["tests"] < 1:
                raise RuntimeError(f"Parent test receipt is not passing: {variant}/{configuration}")
        package = evidence / "packages" / variant
        for relative, expected in parent["source-receipts"][variant].items():
            if sha(contained_path(package, relative).read_bytes()) != expected:
                raise RuntimeError(f"Staged source hash mismatch: {variant}/{relative}")
        build = parent["build-receipts"][variant]
        binary = contained_path(evidence, build["binary"])
        if sha(binary.read_bytes()) != build["binary_sha256"]:
            raise RuntimeError(f"Built binary hash mismatch: {variant}")
        if sha((package / "Package.swift").read_bytes()) != build["package_sha256"]:
            raise RuntimeError(f"Built package hash mismatch: {variant}")
        binaries[variant] = binary

    output.mkdir(parents=True, exist_ok=True)
    runner = Runner(output)
    manifest = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "parent_evidence": str(evidence),
        "parent_manifest": parent_manifest,
        "parent_receipt_sha256": {f"{name}.json": sha(data) for name, data in receipt_bytes.items()},
        "inputs": {"controls.py": sha(Path(__file__).read_bytes()),
                   "run.py": sha((HERE / "run.py").read_bytes())},
        "environment": {
            "platform": platform.platform(), "machine": platform.machine(),
            "cpu_count": os.cpu_count(), "python": platform.python_version(),
            "variables": {key: runner.env.get(key) for key in
                          ("LANG", "LC_ALL", "LC_COLLATE", "DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING")},
        },
        "method": {
            "purpose": "Bounded diagnostic of iteration-count and runner noise confounds; retain every sample regardless of direction",
            "unit": "one SourceTabs.contains(candidate, in: tab) lookup",
            "binaries": "reuse the parent experiment's SHA-256-verified release binaries; no rebuild or production substitution",
            "comparisons": COMPARISONS,
            "sampling": "each label is an independent fresh process; rotate cases each pair; alternate A/B and B/A label order; comparison order follows a four-pair cycle with balanced label/order combinations at the default eight pairs",
            "calibration": "none; identical fixed iteration count for both labels and both comparisons",
            "timers": parent_manifest["method"]["timers"],
            "exclusions": parent_manifest["method"]["exclusions"],
            "observability": parent_manifest["method"]["observability"],
            "summary": "independent label medians and median paired 100*(1-B/A) reductions; a positive reduction means label B was faster; A/A measures same-binary variability",
            "pairs": args.pairs, "iterations": args.iterations,
            "queries_per_iteration": 16, "lookups_per_sample": args.iterations * 16,
            "seed": SEED, "workloads": list(CASES),
        },
    }
    save(output / "manifest.json", manifest)
    for name in ("source-receipts", "build-receipts", "tests"):
        save(output / f"{name}.json", parent[name])
    verification = {
        variant: json.loads(runner.run([binary, "verify", str(SEED)], f"{variant}-verify"))
        for variant, binary in binaries.items()
    }
    save(output / "verification.json", verification)
    if verification != parent["verification"]:
        raise RuntimeError("Fresh exact input/output verification differs from the parent receipts")
    records = {record["workload"]: record for record in verification["baseline"]}
    if not all(case in records for case in CASES):
        raise RuntimeError("Parent verification omitted a diagnostic workload")

    rows = []
    comparison_names = list(COMPARISONS)
    for pair in range(args.pairs):
        offset = pair % len(CASES)
        cases = CASES[offset:] + CASES[:offset]
        for case_position, case in enumerate(cases):
            # Four-pair cycle decouples label order from comparison position.
            reverse_comparisons = (pair // 2 + pair + CASES.index(case)) % 2
            comparisons = comparison_names[::-1] if reverse_comparisons else comparison_names
            for comparison_position, comparison in enumerate(comparisons):
                comparison_index = comparison_names.index(comparison)
                labels = ("A", "B") if (pair + comparison_index) % 2 == 0 else ("B", "A")
                for position, label in enumerate(labels):
                    variant = COMPARISONS[comparison][label]
                    row = measurement(
                        runner, binaries[variant], case, args.iterations,
                        f"pair-{pair + 1}-{case}-{comparison}-{label}",
                    )
                    expected = records[case]
                    if (row["booleans"] != expected["booleans"]
                            or not all(type(value) is bool for value in row["booleans"])
                            or row["item_count"] != len(expected["items"])):
                        raise RuntimeError(f"Timed output differs from verified receipt: {case}/{comparison}/{label}")
                    row.update(pair=pair, comparison=comparison, label=label, variant=variant,
                               position=position, comparison_position=comparison_position,
                               case_position=case_position, measurement_sequence=len(rows))
                    rows.append(row)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Completed control pair {pair + 1}/{args.pairs}", flush=True)

    summaries = []
    for comparison, labels in COMPARISONS.items():
        for case in CASES:
            subset = [row for row in rows if row["comparison"] == comparison and row["workload"] == case]
            summary = {"comparison": comparison, "label_variants": labels, "workload": case,
                       "pairs": args.pairs, "iterations": args.iterations,
                       "item_count": len(records[case]["items"])}
            for clock in ("wall", "cpu"):
                values = {
                    label: [next(row[f"{clock}_ns_per_lookup"] for row in subset
                                 if row["pair"] == pair and row["label"] == label)
                            for pair in range(args.pairs)]
                    for label in ("A", "B")
                }
                before, after = values["A"], values["B"]
                summary[clock] = {
                    "a_median_ns_per_lookup": statistics.median(before),
                    "b_median_ns_per_lookup": statistics.median(after),
                    "paired_median_reduction_percent": statistics.median(
                        100 * (1 - b / a) for a, b in zip(before, after)),
                    "paired_median_difference_ns": statistics.median(
                        b - a for a, b in zip(before, after)),
                    "b_faster_pairs": sum(b < a for a, b in zip(before, after)),
                    "a_ns_per_lookup": before, "b_ns_per_lookup": after,
                }
            summaries.append(summary)
    save(output / "summary.json", {
        "pairs": args.pairs, "iterations": args.iterations, "measurements": len(rows),
        "comparisons": COMPARISONS, "verified_workloads": list(CASES), "results": summaries,
    })
    print("comparison | workload | A us/lookup | B us/lookup | paired wall reduction | paired CPU reduction | B faster CPU pairs")
    for row in summaries:
        print(f"{row['comparison']} | {row['workload']} | "
              f"{row['wall']['a_median_ns_per_lookup']/1000:.3f} | "
              f"{row['wall']['b_median_ns_per_lookup']/1000:.3f} | "
              f"{row['wall']['paired_median_reduction_percent']:.1f}% | "
              f"{row['cpu']['paired_median_reduction_percent']:.1f}% | "
              f"{row['cpu']['b_faster_pairs']}/{args.pairs}")


if __name__ == "__main__":
    main()
