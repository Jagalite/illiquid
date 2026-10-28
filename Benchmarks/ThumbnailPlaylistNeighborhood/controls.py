#!/usr/bin/env python3
"""Reuse verified binaries for equal-work full-pool AB and baseline-only AA controls.

This focused follow-up retains the original study and all observations. It does
not rebuild, retest, recalibrate, or discard outliers. Equal iteration counts are
fixed before sampling from the slower original median for each selected case.
"""

from __future__ import annotations

import argparse
import gzip
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import statistics
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location("thumbnail_neighborhood_support", HERE / "run.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)

CONDITIONS = [
    {"name": "AB-first-full", "kind": "baseline_candidate", "case": "candidates-10000-first-full",
     "sides": {"A": "baseline", "B": "candidate"}},
    {"name": "AB-last-full", "kind": "baseline_candidate", "case": "candidates-10000-last-full",
     "sides": {"A": "baseline", "B": "candidate"}},
    {"name": "AB-nil-full", "kind": "baseline_candidate", "case": "candidates-10000-nil-full",
     "sides": {"A": "baseline", "B": "candidate"}},
    {"name": "AA-last-full", "kind": "baseline_repeat", "case": "candidates-10000-last-full",
     "sides": {"A": "baseline", "B": "baseline"}},
]


class Controls(support.Study):
    # Reuse only command logging, checksum-gated measurement, and JSON helpers.
    # The original Study constructor/build/test/calibration methods are not used.
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.original = args.evidence.resolve()
        self.output = args.output.resolve()
        if self.output.exists():
            raise ValueError(f"Use a new output path: {self.output}")
        self.output.mkdir(parents=True)
        self.sequence = 0
        self.original_manifest = json.loads((self.original / "manifest.json").read_bytes())
        if (self.original_manifest.get("complete") is not True
                or self.original_manifest.get("status") != "measured"):
            raise ValueError("Original evidence must be a complete measured study")
        self.environment = os.environ.copy()
        for key, value in self.original_manifest["environment"].items():
            if value is None:
                self.environment.pop(key, None)
            else:
                self.environment[key] = value
        # These are the runner's exact additional overrides in the original run.
        self.environment.update({
            "CLANG_MODULE_CACHE_PATH": str(self.original / "work/cache/clang"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(self.original / "work/cache/swift"),
            "XDG_CACHE_HOME": str(self.original / "work/cache/xdg"),
            "TMPDIR": str(self.original / "work/tmp"),
            "TERM": "dumb", "NO_COLOR": "1",
        })
        self.binary_records = json.loads((self.original / "binaries.json").read_bytes())
        self.binaries = {variant: Path(record["path"]) for variant, record in self.binary_records.items()}
        self.cases = {case["name"]: case for case in json.loads((self.original / "cases.json").read_bytes())}
        self.parity = json.loads((self.original / "parity.json").read_bytes())
        self.expected = self.parity["expected_measurements"]
        self.previous_summary = {row["name"]: row for row in json.loads((self.original / "summary.json").read_bytes())}
        self.previous_observations = [json.loads(line) for line in
            (self.original / "observations.jsonl").read_text().splitlines()]
        self.previous_commands = {row["sequence"]: row for row in
            (json.loads(line) for line in (self.original / "commands.jsonl").read_text().splitlines())}
        self.manifest = {
            "schema": 1, "complete": False, "status": "preflight",
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "arguments": {**vars(args), "evidence": str(self.original), "output": str(self.output)},
            "original_evidence": str(self.original),
            "conditions": CONDITIONS, "pairs_per_condition": args.pairs,
            "platform": platform.platform(), "uname": platform.uname()._asdict(),
            "environment": self.original_manifest["environment"],
            "runner_environment_overrides": {key: self.environment[key] for key in (
                "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "XDG_CACHE_HOME",
                "TMPDIR", "TERM", "NO_COLOR")},
            "design": {
                "purpose": "Focused follow-up of noisy/adverse full-pool cases in the original study",
                "iterations": "Equal A/B work fixed from the slower original median CPU ns/op; no new calibration",
                "sampling": "Fresh process per observation, balanced AB/BA labels, rotating condition order",
                "AA_control": "A and B both execute the same baseline binary for the last-full fixture",
                "retention": "Every observation retained; no trimming or exclusion",
                "compile_flags": "Original executables reused byte-for-byte; no rebuild or tests",
                "measurement_flags": "Same --measure CASE ITERATIONS interface; only iteration count changes",
                "hash_randomness": "Original environment preserved; no deterministic hashing added",
                "inference_limit": "Post hoc focused study; original adverse result remains part of the evidence",
            },
            "statistics": {**self.original_manifest["statistics"],
                "paired_reduction": "100 * (1 - side_B_ns_per_op / side_A_ns_per_op)",
                "AA_sign": "Positive means baseline invocation B faster than baseline invocation A"},
            "binary_hashes": self.binary_records,
            "controls_sha256": support.sha(Path(__file__).read_bytes()),
        }
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        if hasattr(os, "getloadavg"):
            self.manifest["load_average_start"] = os.getloadavg()
        self.update_manifest()

    def verify_inputs(self) -> dict:
        verified = {}
        original = self.original_manifest
        for key in ("system", "machine", "release", "node"):
            if platform.uname()._asdict()[key] != original["uname"][key]:
                raise ValueError(f"Original host changed: {key}")
        if hasattr(os, "sched_getaffinity") and sorted(os.sched_getaffinity(0)) != original.get("cpu_affinity"):
            raise ValueError("CPU affinity differs from the original study")
        pinned = json.loads((HERE / "baseline/manifest.json").read_bytes())
        for name, record in original["input_sources"].items():
            retained = (self.original / "inputs" / name).read_bytes()
            support.checked_source(retained, record, f"retained {name}")
            if name.startswith(("Sources/", "Tests/")):
                current = (ROOT / name).read_bytes()
            elif name == "candidate/ThumbnailBackgroundScheduler.swift":
                current = (ROOT / support.SCHEDULER).read_bytes()
            elif name == "candidate/ThumbnailPlaylistNeighborhood.swift":
                current = (ROOT / support.HELPER).read_bytes()
            elif name == "candidate/runPass-prefix.swift":
                current = support.extract_prefix((ROOT / support.SCHEDULER).read_bytes(), pinned)
            else:
                current = (HERE / name).read_bytes()
            support.checked_source(current, record, f"current {name}")
            verified[name] = record
        for variant, sources in original["generated_sources"].items():
            for name, record in sources.items():
                path = self.original / "work/packages" / variant / name
                support.checked_source(path.read_bytes(), record, f"staged {variant}/{name}")
        for variant, record in self.binary_records.items():
            if support.sha(self.binaries[variant].read_bytes()) != record["sha256"]:
                raise ValueError(f"Original {variant} executable hash changed")
        full = gzip.decompress((self.original / "verification-receipts.json.gz").read_bytes())
        receipts = json.loads(full)
        if (self.parity.get("complete_output_equal") is not True
                or support.sha(support.canonical(receipts)) != self.parity["canonical_receipts_sha256"]
                or len(receipts) != self.parity["receipts"]):
            raise ValueError("Original complete-output verification receipt changed")
        by_name = {receipt["name"]: receipt for receipt in receipts}
        for condition in CONDITIONS:
            name = condition["case"]
            candidates = by_name[name]["candidates"]
            first = candidates[0].get("distance") if candidates else None
            last = candidates[-1].get("distance") if candidates else None
            expected = {"output_count": len(candidates), "signature": 17 + len(candidates) * 31
                        + (first if first is not None else -1) + (last if last is not None else -1)}
            if self.expected[name] != expected:
                raise ValueError(f"Original receipt-derived checksum/count mismatch: {name}")
        expected_total = len(original["selected_cases"]) * original["arguments"]["pairs"] * 2
        if len(self.previous_observations) != expected_total:
            raise ValueError("Original observation count does not match its complete study manifest")
        return verified

    def fixed_iterations(self) -> dict:
        selected = {}
        for name in dict.fromkeys(condition["case"] for condition in CONDITIONS):
            medians = {}
            for variant in ("baseline", "candidate"):
                rows = [row for row in self.previous_observations if row["case"] == name and row["variant"] == variant]
                if len(rows) != self.original_manifest["arguments"]["pairs"]:
                    raise ValueError(f"Original observation count mismatch for {name} {variant}")
                for row in rows:
                    expected = self.expected[name]
                    if (row["checksum"] != expected["signature"] * row["iterations"]
                            or row["expected_checksum"] != row["checksum"]
                            or row["output_count"] != expected["output_count"]
                            or row["postflight_matches"] is not True
                            or min(row["cpu_ns"], row["wall_ns"], row["iterations"]) <= 0):
                        raise ValueError(f"Invalid original observation: {name} {variant}")
                    command = self.previous_commands[row["command_sequence"]]
                    if (command["returncode"] != 0 or command["cwd"] != str(ROOT)
                            or command["argv"] != [str(self.binaries[variant]), "--measure", name, str(row["iterations"])]):
                        raise ValueError("Original measurement invocation no longer matches the reused interface")
                medians[variant] = statistics.median(row["cpu_ns"] / row["iterations"] for row in rows)
                if medians[variant] != self.previous_summary[name][variant]["cpu_ns_per_op"]["median"]:
                    raise ValueError(f"Original summary disagrees with raw observations: {name} {variant}")
            count = min(support.MAX_ITERATIONS, max(1, math.ceil(self.args.target_ms * 1_000_000 / max(medians.values()))))
            selected[name] = {"iterations_both_sides": count, "original_cpu_medians_ns_per_op": medians,
                              "estimated_cpu_ms": {variant: count * value / 1_000_000 for variant, value in medians.items()}}
        return selected

    def summarize(self, rows: list[dict], iterations: dict) -> list[dict]:
        results = []
        for condition in CONDITIONS:
            selected = [row for row in rows if row["condition"] == condition["name"]]
            result = {**condition, "pairs": self.args.pairs, **iterations[condition["case"]]}
            for side in ("A", "B"):
                values = [row for row in selected if row["side"] == side]
                if len(values) != self.args.pairs:
                    raise ValueError("Incomplete condition side")
                result[side] = {"actual_variant": condition["sides"][side], **{
                    metric: support.distribution([row[metric] for row in values])
                    for metric in ("cpu_ns_per_op", "wall_ns_per_op")}}
            for metric in ("cpu_ns_per_op", "wall_ns_per_op"):
                reductions, by_first_side = [], {"A": [], "B": []}
                for pair in range(self.args.pairs):
                    paired = {row["side"]: row for row in selected if row["pair"] == pair}
                    if set(paired) != {"A", "B"}:
                        raise ValueError("Incomplete A/B-labeled pair")
                    value = 100 * (1 - paired["B"][metric] / paired["A"][metric])
                    reductions.append(value)
                    by_first_side[paired["A"]["side_order"][0]].append(value)
                result[metric.replace("_ns_per_op", "_reduction_percent")] = {
                    **support.distribution(reductions), "paired_values": reductions,
                    "B_faster_pairs": sum(value > 0 for value in reductions),
                    "bootstrap_median_95_ci": support.bootstrap_interval(reductions, condition["name"], metric),
                    "ratio_of_medians": 100 * (1 - result["B"][metric]["median"] / result["A"][metric]["median"]),
                    "by_first_side": {side: support.distribution(values) for side, values in by_first_side.items()},
                }
            results.append(result)
        return results

    def run(self) -> None:
        verified = self.verify_inputs()
        iterations = self.fixed_iterations()
        support.save(self.output / "source-verification.json", verified)
        support.save(self.output / "iterations.json", iterations)
        self.manifest["original_files"] = {}
        for name in ("manifest.json", "summary.json", "parity.json", "cases.json", "binaries.json", "tests.json"):
            raw = (self.original / name).read_bytes()
            destination = self.output / "original" / name
            destination.parent.mkdir(exist_ok=True)
            destination.write_bytes(raw)
            self.manifest["original_files"][name] = support.source_record(raw)
        self.manifest["original_files"]["observations.jsonl"] = support.source_record((self.original / "observations.jsonl").read_bytes())
        self.manifest["original_files"]["commands.jsonl"] = support.source_record((self.original / "commands.jsonl").read_bytes())
        (self.output / "controls.py").write_bytes(Path(__file__).read_bytes())
        self.manifest.update(status="measuring", fixed_iterations=iterations)
        self.update_manifest()
        print("Verified original sources/binaries/receipts; fixed equal-work counts: "
              + json.dumps({name: row["iterations_both_sides"] for name, row in iterations.items()}), flush=True)
        rows = []
        indexed = list(enumerate(CONDITIONS))
        for pair in range(self.args.pairs):
            offset = pair % len(indexed)
            rotated = indexed[offset:] + indexed[:offset]
            for index, condition in rotated:
                order = ("A", "B") if (pair + index) % 2 == 0 else ("B", "A")
                for position, side in enumerate(order):
                    variant = condition["sides"][side]
                    row = self.measure(variant, self.cases[condition["case"]],
                        iterations[condition["case"]]["iterations_both_sides"],
                        f"pair-{pair:02d}-{condition['name']}-{side}")
                    row.update(condition=condition["name"], condition_kind=condition["kind"],
                               side=side, pair=pair, position_in_pair=position, side_order=list(order))
                    rows.append(row)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Completed focused pair {pair + 1}/{self.args.pairs}", flush=True)
        if self.verify_inputs() != verified:
            raise ValueError("Source verification changed during the focused run")
        summaries = self.summarize(rows, iterations)
        support.save(self.output / "summary.json", summaries)
        self.manifest.update(complete=True, status="measured", observations=len(rows),
                             finished_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                             source_and_binary_postflight_verified=True)
        if hasattr(os, "getloadavg"):
            self.manifest["load_average_end"] = os.getloadavg()
        self.update_manifest()
        for result in summaries:
            cpu = result["cpu_reduction_percent"]
            print(f"{result['name']}: CPU paired reduction {cpu['median']:.3f}% "
                  f"(95% CI {cpu['bootstrap_median_95_ci']}); B faster {cpu['B_faster_pairs']}/{self.args.pairs}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True, help="Original complete evidence directory with work/binaries retained")
    parser.add_argument("--output", type=Path, required=True, help="New focused evidence directory")
    parser.add_argument("--pairs", type=int, default=16)
    parser.add_argument("--target-ms", type=float, default=400)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--pairs must be even and at least 2; --target-ms must be positive and finite")
    study = None
    try:
        study = Controls(args)
        study.run()
        return 0
    except Exception as error:
        if study is not None:
            support.save(study.output / "failure.json", {"error": str(error), "traceback": traceback.format_exc()})
            study.manifest.update(complete=False, status="failed", error=str(error))
            study.update_manifest()
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
