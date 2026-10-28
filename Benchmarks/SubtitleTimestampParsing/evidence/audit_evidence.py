#!/usr/bin/env python3
"""Independently audit saved conversion evidence; never run or import run.py.

Usage: python3 audit_evidence.py EVIDENCE_DIRECTORY [EVIDENCE_DIRECTORY ...]
An integrity pass does not approve the optimization: the native primary gate
and the need to review every control are reported separately. Compact Linux
archives lack complete output/source snapshots and remain development evidence.
"""
import argparse
import base64
import gzip
import hashlib
import json
import math
import re
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
SOURCE = "ExternalTextSubtitleConverter.swift"
VARIANTS = ("baseline", "candidate")
MASK = (1 << 64) - 1
TIMED = [
    "srt-1-plain", "srt-100-plain", "srt-2000-plain", "srt-10000-plain",
    "srt-2000-multilingual", "srt-2000-escaped", "vtt-100-plain", "vtt-2000-plain",
    "vtt-10000-plain", "vtt-2000-multilingual", "vtt-short-2000", "srt-legacy-2000",
    "srt-long-hours-2000", "vtt-long-hours-2000", "srt-empty",
    "vtt-missing-signature", "srt-no-valid-cues",
]
ERROR_TOKENS = {
    "missingWebVTTSignature": 0x1000000000000001,
    "noValidCues.srt": 0x1000000000000002,
    "noValidCues.webVTT": 0x1000000000000003,
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def same(actual, expected, label):
    if isinstance(expected, dict):
        require(isinstance(actual, dict) and actual.keys() == expected.keys(), label + ": keys")
        for key in expected:
            same(actual[key], expected[key], label + "." + key)
    elif isinstance(expected, list):
        require(isinstance(actual, list) and len(actual) == len(expected), label + ": length")
        for index, value in enumerate(expected):
            same(actual[index], value, label + f"[{index}]")
    elif isinstance(expected, float):
        require(type(actual) in (int, float) and math.isfinite(actual)
                and math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9), label + ": value")
    else:
        require(type(actual) is type(expected) and actual == expected, label + ": value")


def fnv(data):
    value = 14695981039346656037
    for byte in data:
        value = ((value ^ byte) * 1099511628211) & MASK
    return format(value, "x")


def check_sample(row, receipt, operations):
    require(type(operations) is int and 0 < operations <= 1_000_000, "Invalid operation count")
    for key in ("case", "format", "cues", "input_bytes", "input_fnv1a", "timed",
                "output_bytes", "output_fnv1a", "error"):
        same(row[key], receipt[key], row["case"] + "." + key)
    same(row["operations"], operations, "Unequal work")
    token = receipt["output_bytes"] + 1 if receipt["error"] is None else ERROR_TOKENS[receipt["error"]]
    require(int(receipt["token"]) == token, "Invalid reference token")
    total = (operations * token + 131 * (operations * (operations - 1) // 2)) % (1 << 64)
    require(isinstance(row["checksum"], str) and row["checksum"].isdigit()
            and int(row["checksum"]) == total, "Invalid measured checksum")
    for metric in ("cpu_ns", "elapsed_ns"):
        require(type(row[metric]) is int and row[metric] > 0, "Invalid measured duration")


def check_timestamps(folder, header, required):
    paths = [folder / "timestamp-cases.json", folder / "timestamp-verification.json",
             *[folder / f"timestamp-parity-{variant}.json.gz" for variant in VARIANTS]]
    available = all(path.is_file() for path in paths)
    require(not required or available, "Native timestamp receipts missing")
    if not available:
        return {"outputs_verified": False, "golden_cases_replayed": 0}
    cases, metadata = read(paths[0]), read(paths[1])
    require(digest(paths[0]) == metadata["corpus_sha256"], "Timestamp corpus SHA-256")
    require(len(cases) == metadata["cases"] and len({c["id"] for c in cases}) == len(cases),
            "Timestamp corpus count or duplicate ID")
    golden_count = sum("expected_error" in c or "expected_dialogue" in c for c in cases)
    require(golden_count == metadata["golden_cases"] and metadata["exact_utf8_and_errors_match"] is True,
            "Timestamp golden count or comparison receipt")
    outputs = [json.loads(gzip.decompress(path.read_bytes())) for path in paths[2:]]
    require(outputs[0] == outputs[1], "Timestamp complete bytes or exact errors differ")
    for variant, path, rows in zip(VARIANTS, paths[2:], outputs):
        require(digest(path) == metadata["receipts"][variant]["sha256"]
                and len(rows) == metadata["receipts"][variant]["cases"], "Timestamp output receipt digest/count")
        require([row["id"] for row in rows] == [c["id"] for c in cases], "Timestamp ordered IDs")
    require(not required or header is not None, "No independently verified ASS header")
    for case, result in zip(cases, outputs[0]):
        require(set(result) in ({"id", "output"}, {"id", "error"}), "Ambiguous timestamp outcome")
        data = base64.b64decode(result["output"], validate=True) if "output" in result else None
        require(data is not None or result["error"] in ERROR_TOKENS, "Unknown timestamp error")
        require(not ("expected_error" in case and "expected_dialogue" in case), "Ambiguous golden")
        if "expected_error" in case:
            require(result.get("error") == case["expected_error"], "Timestamp expected error: " + case["id"])
        if "expected_dialogue" in case and header is not None:
            require(data == header + case["expected_dialogue"].encode("utf-8"),
                    "Timestamp full-byte golden: " + case["id"])
    return {"outputs_verified": True, "cases": len(cases),
            "golden_cases_replayed": golden_count if header is not None else 0}


def check_tests(folder, manifest, required):
    path = folder / "tests.json"
    require(not required or path.is_file(), "Native test receipts missing")
    if not path.is_file():
        return False
    tests = read(path)
    require(len(tests) == 4 and {(r["variant"], r["configuration"]) for r in tests}
            == {(v, c) for v in VARIANTS for c in ("debug", "release")}, "Incomplete test matrix")
    require(len({r["passed_tests"] for r in tests}) == 1, "Test counts differ")
    for row in tests:
        variant, configuration = row["variant"], row["configuration"]
        require(type(row["passed_tests"]) is int and row["passed_tests"] > 0, "Zero/invalid tests")
        require(row["source_sha256"] == manifest["variants"][variant]["source_sha256"], "Test source identity")
        log = folder / f"tests-{variant}-{configuration}.log"
        require(digest(log) == row["log_sha256"], "Test log hash")
        counts = re.findall(r"Test run with (\d+) tests?[^\n]*passed", log.read_text())
        require(counts and int(counts[-1]) == row["passed_tests"], "Test execution count")
        require(row["tests"] == tests[0]["tests"] and len(row["tests"]) == 3, "Unequal regression sources")
        for name, expected in row["tests"].items():
            require(Path(name).name == name, "Unsafe test filename")
            require(digest(ROOT / "Tests/IlliquidNativePlaybackTests" / name) == expected, "Regression source hash")
    return True


def audit(folder):
    folder = folder.resolve()
    manifest, config = read(folder / "manifest.json"), read(folder / "benchmark.json")
    cases, rounds = config["cases"], config["rounds"]
    require(cases and len(set(cases)) == len(cases) and set(cases) <= set(TIMED), "Invalid case selection")
    require(type(rounds) is int and rounds >= 2 and rounds % 2 == 0, "Unbalanced rounds")
    require(type(config["target_ms"]) in (int, float) and math.isfinite(config["target_ms"])
            and config["target_ms"] > 0, "Invalid target duration")
    require(set(config["iterations"]) == set(cases), "Iteration map differs from cohort")
    native = manifest["platform"].lower().startswith(("macos", "darwin"))
    formal = native and cases == TIMED and rounds == 10 and config["target_ms"] >= 250
    pin = read(HERE / "baseline/manifest.json")
    baseline = (HERE / "baseline" / SOURCE).read_bytes()
    require(hashlib.sha256(baseline).hexdigest() == pin["sha256"], "Frozen baseline SHA-256")
    require(hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
            == pin["git_blob"], "Frozen baseline Git blob")
    for key in ("commit", "sha256", "git_blob"):
        require(manifest["baseline"][key] == pin[key], "Manifest baseline differs: " + key)
    require(set(manifest["variants"]) == set(VARIANTS), "Invalid variants")
    require(manifest["variants"]["baseline"]["source_sha256"] == pin["sha256"], "Measured baseline differs")
    snapshots = {
        "runner.snapshot.py": manifest["runner_sha256"], "Driver.swift": manifest["driver_sha256"],
        **{variant + "/" + SOURCE: manifest["variants"][variant]["source_sha256"] for variant in VARIANTS},
    }
    for name, key in (("TimestampParity.swift", "timestamp_driver_sha256"),
                      ("TimestampCases.py", "timestamp_cases_generator_sha256")):
        if key in manifest:
            snapshots[name] = manifest[key]
    snapshot_count = 0
    for name, expected in snapshots.items():
        path = folder / name
        require(not formal or path.is_file(), "Native source snapshot missing: " + name)
        if path.is_file():
            require(digest(path) == expected, "Snapshot changed: " + name)
            snapshot_count += 1
    current_source_matches = digest(ROOT / pin["path"]) == manifest["variants"]["candidate"]["source_sha256"]
    if (folder / "evidence-receipt.json").is_file():
        archived = read(folder / "evidence-receipt.json")
        for name, expected in archived["files"].items():
            require((folder / name).resolve().is_relative_to(folder), "Unsafe archive filename")
            require(digest(folder / name) == expected, "Archived evidence changed: " + name)
    receipt_path = folder / "verification.json"
    if not receipt_path.is_file():
        receipt_path = folder / "verification-timed.json"
    receipts = read(receipt_path)
    require(set(cases) <= receipts.keys(), "Missing common input/output receipt")
    raw_paths = [folder / f"verification-{variant}.json.gz" for variant in VARIANTS]
    full_outputs = all(path.is_file() for path in raw_paths)
    header = None
    require(not formal or full_outputs, "Native complete outputs are missing")
    if full_outputs:
        raw = [json.loads(gzip.decompress(path.read_bytes())) for path in raw_paths]
        require(raw[0] == raw[1], "Complete baseline/candidate bytes or errors differ")
        require(len({item["case"] for item in raw[0]}) == len(raw[0]), "Duplicate full output receipt")
        require({item["case"] for item in raw[0]} == set(receipts), "Full receipt set differs")
        for item in raw[0]:
            projected = {key: value for key, value in item.items() if not key.endswith("_base64")}
            for prefix in ("input", "output"):
                encoded = item[prefix + "_base64"]
                data = None if encoded is None else base64.b64decode(encoded, validate=True)
                projected[prefix + "_sha256"] = None if data is None else hashlib.sha256(data).hexdigest()
                require(item[prefix + "_bytes"] == (0 if data is None else len(data)), "Output/input length")
                require(item[prefix + "_fnv1a"] == (None if data is None else fnv(data)), "Output/input FNV")
                if prefix == "output" and data is not None and header is None:
                    header, delimiter, _ = data.partition(b"\nDialogue: ")
                    require(delimiter, "Verified output has no ASS dialogue")
            same(projected, receipts[item["case"]], item["case"] + ".full_receipt")
    timestamp_audit = check_timestamps(folder, header, formal)
    tests_verified = check_tests(folder, manifest, formal)
    rows = [json.loads(line) for line in (folder / "measurements.jsonl").read_text().splitlines()]
    require(len(rows) == len(cases) * rounds * 2, "Incomplete observation cohort")
    pairs = {}
    for index, row in enumerate(rows):
        name, turn, variant, position = row["case"], row["round"], row["variant"], row["pair_position"]
        require(name in cases and variant in VARIANTS and type(turn) is int and 0 <= turn < rounds
                and type(position) is int and position in (0, 1), "Malformed sample identity")
        offset = cases.index(name) if turn % 2 == 0 else len(cases) - 1 - cases.index(name)
        require(type(row["sequence"]) is int
                and row["sequence"] == index == (turn * len(cases) + offset) * 2 + position
                and variant == VARIANTS[position ^ (turn % 2)], "Observation order differs")
        identity = (name, turn, variant)
        require(identity not in pairs, "Duplicate observation")
        pairs[identity] = row
        check_sample(row, receipts[name], config["iterations"][name])
    calibration = read(folder / "calibration.json")
    for row in calibration:
        require(row["case"] in cases and (row.get("variant") in VARIANTS
                or (not formal and "variant" not in row)), "Calibration identity")
        check_sample(row, receipts[row["case"]], row["operations"])
    reconstructed, decisions = [], {}
    for name in cases:
        summary = {"case": name, "cues": receipts[name]["cues"], "input_bytes": receipts[name]["input_bytes"],
                   "operations_per_sample": config["iterations"][name], "pairs": rounds}
        for metric in ("cpu_ns", "elapsed_ns"):
            values = {v: [pairs[name, turn, v][metric] / config["iterations"][name]
                          for turn in range(rounds)] for v in VARIANTS}
            ratios = [values["candidate"][turn] / values["baseline"][turn] for turn in range(rounds)]
            median = statistics.median(ratios)
            summary[metric] = {v: {"median_per_operation": statistics.median(values[v]),
                                  "min_per_operation": min(values[v]), "max_per_operation": max(values[v])}
                               for v in VARIANTS}
            summary[metric].update(paired_candidate_over_baseline=ratios, median_paired_ratio=median,
                                   median_paired_change_percent=100 * (median - 1))
        cpu = summary["cpu_ns"]
        decisions[name] = {"median_paired_cpu_change_percent": cpu["median_paired_change_percent"],
                           "median_paired_cpu_ratio": cpu["median_paired_ratio"],
                           "winning_cpu_pairs": sum(value < 1 for value in cpu["paired_candidate_over_baseline"]),
                           "pairs": rounds}
        reconstructed.append(summary)
    same(read(folder / "summary.json"), reconstructed, "independent_summary")
    primary = ["srt-100-plain", "srt-2000-plain", "srt-10000-plain"]
    gate = all(decisions[name]["median_paired_cpu_ratio"] <= 0.9
               and decisions[name]["winning_cpu_pairs"] >= 9 for name in primary) if formal else None
    if formal:
        completion = read(folder / "completion.json")
        require(completion["passed"] is True and completion["mode"] == "benchmark"
                and completion["source_and_binary_hashes_unchanged"] is True, "No successful completion receipt")
    return {"directory": str(folder), "integrity_passed": True, "observations": len(rows),
            "cases": len(cases), "pairs_per_case": rounds,
            "classification": "native_complete_cohort" if formal else "development_only",
            "complete_output_bytes_independently_verified": full_outputs,
            "timestamp_audit": timestamp_audit, "four_test_configurations_verified": tests_verified,
            "source_snapshots_rehashed": snapshot_count, "candidate_matches_current_source": current_source_matches,
            "calibration_variants_recorded": all("variant" in row for row in calibration),
            "minimum_cpu_ns": min(row["cpu_ns"] for row in rows),
            "minimum_elapsed_ns": min(row["elapsed_ns"] for row in rows),
            "native_primary_gate_passed": gate,
            "primary_gate": "At least 10% median paired CPU reduction and 9/10 wins in all three SRT sizes",
            "control_review": "Required; an integrity/primary-gate pass is not whole-player qualification",
            "cases_recomputed": decisions}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", type=Path, nargs="+")
    args = parser.parse_args()
    print(json.dumps([audit(path) for path in args.directories], indent=2, sort_keys=True))
