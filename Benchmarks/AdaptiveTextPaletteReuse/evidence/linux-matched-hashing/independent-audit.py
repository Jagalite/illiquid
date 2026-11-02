#!/usr/bin/env python3
"""Audit an extracted complete cohort without relying on the original /tmp tree.

Related cohorts and the historical live-binary receipt are optional inputs.
The checked-in source-revision binding authenticates the unpublished local
commit from its complete payload and its tree's published Git object.
"""
import argparse
import base64
import hashlib
import itertools
import json
import math
from pathlib import Path
import statistics
import subprocess


PUBLISHED_RESEARCH_COMMIT = "8b89675ce399cb59bbf9a995768d2a32f2e04ffb"
FINAL_SOURCE_COMMIT = "63ae72ba07b514218561caba21980d8d131e914d"
THEME_PATH = "Sources/IlliquidApp/UI/PlayerTheme.swift"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    return json.loads(path.read_text())


def git_bytes(repo, commit, path):
    return subprocess.check_output(["git", "show", commit + ":" + path], cwd=repo)


def equal_number(observed, expected):
    assert math.isclose(observed, expected, rel_tol=1e-12, abs_tol=1e-9), (observed, expected)


def source_bindings(path, repo):
    if path is None:
        return {}, None
    binding = read(path)
    preserved = binding["tested_local_commit_object"]
    assert preserved["encoding"] == "base64" and preserved["type"] == "commit"
    payload = base64.b64decode(preserved["payload"], validate=True)
    assert len(payload) == preserved["byte_length"]
    object_bytes = b"commit " + str(len(payload)).encode("ascii") + b"\0" + payload
    local_commit = hashlib.sha1(object_bytes).hexdigest()
    assert local_commit == binding["tested_local_commit"]
    headers = payload.split(b"\n\n", 1)[0].splitlines()
    tree_headers = [line for line in headers if line.startswith(b"tree ")]
    assert len(tree_headers) == 1 and headers[0] == tree_headers[0]
    tree = tree_headers[0].removeprefix(b"tree ").decode("ascii")
    assert tree == binding["identical_tree"]
    published = binding["published_research_commit"]
    assert published == PUBLISHED_RESEARCH_COMMIT
    published_tree = subprocess.check_output(
        ["git", "rev-parse", published + "^{tree}"], cwd=repo, text=True).strip()
    assert tree == published_tree
    return {local_commit: published}, {"binding_file": str(path),
        "binding_sha256": sha(path.read_bytes()), "tested_local_commit": local_commit,
        "published_research_commit": published, "identical_tree": tree,
        "embedded_commit_object_id_verified": True, "published_tree_verified": True}


def source_audit(root, repo, bindings):
    manifest = read(root / "manifest.json")
    for name, expected in manifest["sources"].items():
        assert sha((root / "sources" / name).read_bytes()) == expected, (root, name)
    actual = (root / "sources/candidate-PlayerTheme.swift").read_bytes()
    frozen = (root / "sources/baseline-PlayerTheme.swift").read_bytes()
    assert frozen == git_bytes(repo, manifest["baseline"]["commit"], manifest["baseline"]["path"])
    assert sha(frozen) == manifest["baseline"]["sha256"]
    def outside_palette(data):
        source = data.decode()
        start = source.index("@MainActor\nstruct PlayerTextPalette {")
        end = source.index("\n@MainActor\nprivate struct DynamicPlayerTextStyleModifier:")
        return source[:start] + source[end:]
    assert outside_palette(actual) == outside_palette(frozen)
    for commit in (PUBLISHED_RESEARCH_COMMIT, FINAL_SOURCE_COMMIT):
        assert actual == git_bytes(repo, commit, THEME_PATH), commit
    for name, metadata in manifest["shared_support"].items():
        assert (root / "sources" / name).read_bytes() == git_bytes(
            repo, manifest["baseline"]["commit"], metadata["original"]), (root, name)
    recorded_head = manifest["candidate_git_head"]
    verification_head = bindings.get(recorded_head, recorded_head)
    return {"cohort": str(root), "source_hashes_verified": len(manifest["sources"]),
            "production_sha256": sha(actual), "shared_source_files_verified": len(manifest["shared_support"]),
            "frozen_baseline_matches_git": True, "theme_outside_palette_unchanged": True,
            "recorded_git_head": recorded_head, "verification_git_head": verification_head,
            "used_verified_tree_binding": verification_head != recorded_head,
            "equals_recorded_git_head": actual == git_bytes(repo, verification_head, THEME_PATH)}


def kernel_range(rows, kernel):
    values = [r for r in rows if r["kernel"] == kernel]
    reductions = [r["median_paired_cpu_reduction_percent"] for r in values]
    deltas = [r["median_paired_cpu_delta_ns"] for r in values]
    return {"workloads": len(values), "faster_medians": sum(x > 0 for x in reductions),
            "slower_medians": sum(x < 0 for x in reductions),
            "cpu_reduction_percent_range": [min(reductions), max(reductions)],
            "median_cpu_reduction_percent_across_workloads": statistics.median(reductions),
            "paired_cpu_delta_ns_range": [min(deltas), max(deltas)],
            "all_six_pairs_faster_workloads": sum(r["candidate_faster_cpu_pairs"] == 6 for r in values),
            "all_six_pairs_slower_workloads": sum(r["candidate_slower_cpu_pairs"] == 6 for r in values),
            "worst_five_by_cpu_reduction": sorted(values, key=lambda r: r["median_paired_cpu_reduction_percent"])[:5]}


def audit(root, repo, related_cohorts=(), binary_receipt=None, binding_path=None):
    manifest = read(root / "manifest.json")
    bindings, binding_verification = source_bindings(binding_path, repo)
    cases = [r["name"] for r in read(root / "cases.json")]
    kernels = ["uncached", "revision", "hit", "component_hit"]
    assert len(cases) == 24 and len(set(cases)) == 24
    assert manifest["arguments"]["rounds"] == 6
    assert manifest["arguments"]["target_ms"] == 150
    assert manifest["arguments"]["cpu"] == 3
    assert manifest["arguments"]["kernels"] == ",".join(kernels)
    assert manifest["environment"]["swift_deterministic_hashing"] == "1"
    assert manifest["environment"]["timed_cpu_affinity"] == 3
    assert manifest["candidate_git_head"] == FINAL_SOURCE_COMMIT
    provenance = source_audit(root, repo, bindings)
    assert provenance["equals_recorded_git_head"]
    live_binary_receipt = read(binary_receipt) if binary_receipt is not None else None
    if live_binary_receipt is not None:
        # Use the recorded identity so extracted evidence can live anywhere.
        assert live_binary_receipt["cohort"] == manifest["arguments"]["output"]
        assert set(live_binary_receipt["binaries"]) == set(manifest["binary_sha256"])
        for name, receipt in live_binary_receipt["binaries"].items():
            assert receipt["matches_manifest"]
            assert receipt["actual_sha256"] == manifest["binary_sha256"][name]

    receipts = (root / "baseline-receipts.jsonl").read_bytes()
    assert receipts == (root / "candidate-receipts.jsonl").read_bytes()
    parsed = [json.loads(line) for line in receipts.splitlines()]
    assert len(parsed) == 5383
    assert len(parsed[0]["cache_key_hashes"]) == 144
    differential = read(root / "differential.json")
    assert differential["exact_match"] and differential["receipt_count"] == 5383
    assert differential["sha256"]["baseline"] == differential["sha256"]["candidate"] == sha(receipts)

    commands = read(root / "commands.json")
    assert len(commands) == 1262, len(commands)
    assert all(c["returncode"] == 0 for c in commands)
    for command in commands:
        assert (root / command["stdout"]).is_file(), command
        assert (root / command["stderr"]).is_file(), command
    by_stdout = {c["stdout"]: c for c in commands}
    assert len(by_stdout) == len(commands)

    measurements = read(root / "measurements.json")
    calibration = read(root / "calibration.json")
    calibrated_counts = {(r["case"], r["kernel"]): r["iterations"] for r in calibration}
    assert len(calibration) == len(calibrated_counts) == 96
    recorded_pairs = read(root / "pairs.json")
    summary = read(root / "summary.json")
    assert len(measurements) == 1152, len(measurements)
    assert len(recorded_pairs) == 576, len(recorded_pairs)
    assert len(summary) == 96, len(summary)
    raw_paths = set((root / "timings").glob("r*.json"))
    assert len(raw_paths) == 1152, len(raw_paths)
    index = {}
    observed_sequence = []
    for record in measurements:
        key = record["case"], record["kernel"], record["round"], record["variant"]
        assert key not in index, key
        index[key] = record
        observed_sequence.append(key)
        filename = f"r{record['round']:02d}-{record['case']}-{record['kernel']}-{record['variant']}.json"
        path = root / "timings" / filename
        raw = read(path)
        assert all(record[k] == v for k, v in raw.items()), filename
        count = record["iterations"]
        assert count == calibrated_counts[key[0], key[1]]
        warmup = max(1, min(64, count // 10))
        assert raw["warmup_iterations"] == warmup
        assert raw["case"] == key[0] and raw["kernel"] == key[1]
        equal_number(raw["ns_per_operation"], raw["elapsed_ns"] / count)
        equal_number(raw["cpu_ns_per_operation"], raw["cpu_elapsed_ns"] / count)
        command = by_stdout["timings/" + filename]
        assert command["cpu_affinity"] == 3
        assert Path(command["argv"][0]).name == key[3]
        assert command["argv"][1:] == ["time", key[0], key[1], str(count), str(warmup)]

    workloads = list(itertools.product(cases, kernels))
    expected_sequence = []
    for round_index in range(6):
        order = ["baseline", "candidate"] if round_index % 2 == 0 else ["candidate", "baseline"]
        rotated = workloads[round_index:] + workloads[:round_index]
        for case, kernel in rotated:
            for variant in order:
                key = case, kernel, round_index + 1, variant
                expected_sequence.append(key)
                assert index[key]["order"] == order
    assert observed_sequence == expected_sequence

    pair_index = {(r["case"], r["kernel"], r["round"]): r for r in recorded_pairs}
    assert len(pair_index) == 576
    recalculated = []
    for case, kernel in workloads:
        cpu_reductions, wall_reductions, cpu_deltas, wall_deltas = [], [], [], []
        baseline_cpu, candidate_cpu, baseline_wall, candidate_wall = [], [], [], []
        for round_number in range(1, 7):
            baseline = index[case, kernel, round_number, "baseline"]
            candidate = index[case, kernel, round_number, "candidate"]
            for field in ("iterations", "warmup_iterations", "checksum", "warmup_checksum", "revision", "generation"):
                assert baseline[field] == candidate[field], (case, kernel, round_number, field)
            for metric, reductions, deltas, old_values, new_values in (
                ("cpu_ns_per_operation", cpu_reductions, cpu_deltas, baseline_cpu, candidate_cpu),
                ("ns_per_operation", wall_reductions, wall_deltas, baseline_wall, candidate_wall),
            ):
                old, new = baseline[metric], candidate[metric]
                reductions.append((old - new) / old * 100)
                deltas.append(new - old)
                old_values.append(old)
                new_values.append(new)
            pair = pair_index[case, kernel, round_number]
            equal_number(pair["cpu_reduction_percent"], cpu_reductions[-1])
            equal_number(pair["wall_reduction_percent"], wall_reductions[-1])
        row = {"case": case, "kernel": kernel, "pairs": 6,
               "iterations_per_process": baseline["iterations"],
               "median_paired_cpu_reduction_percent": statistics.median(cpu_reductions),
               "median_paired_wall_reduction_percent": statistics.median(wall_reductions),
               "candidate_faster_cpu_pairs": sum(x > 0 for x in cpu_reductions),
               "candidate_faster_wall_pairs": sum(x > 0 for x in wall_reductions),
               "baseline_median_cpu_ns_per_operation": statistics.median(baseline_cpu),
               "candidate_median_cpu_ns_per_operation": statistics.median(candidate_cpu),
               "baseline_median_ns_per_operation": statistics.median(baseline_wall),
               "candidate_median_ns_per_operation": statistics.median(candidate_wall)}
        recorded = next(r for r in summary if r["case"] == case and r["kernel"] == kernel)
        assert set(recorded) == set(row), (recorded.keys(), row.keys())
        for field in row:
            if isinstance(row[field], (int, float)):
                equal_number(recorded[field], row[field])
            else:
                assert recorded[field] == row[field]
        row["median_paired_cpu_delta_ns"] = statistics.median(cpu_deltas)
        row["median_paired_wall_delta_ns"] = statistics.median(wall_deltas)
        row["candidate_slower_cpu_pairs"] = sum(x < 0 for x in cpu_reductions)
        recalculated.append(row)

    older_sources = [source_audit(path, repo, bindings) for path in related_cohorts]
    return {"passed": True, "cohort": str(root), "counts": {"cases": 24, "kernels": 4, "rounds": 6,
            "measurements": 1152, "pairs": 576, "workload_summaries": 96, "commands_zero_exit": len(commands),
            "exact_receipts": 5383, "matching_key_hash_values": 144},
            "integrity": {"all_recorded_sources_match_hashes": True, "all_raw_timings_match_records": True,
            "all_paired_checksums_and_counters_match": True, "all_pair_and_summary_statistics_recomputed": True,
            "complete_balanced_and_rotated_order": True,
            "provided_binary_receipt_verified": live_binary_receipt is not None}, "provenance": provenance,
            "earlier_source_provenance": older_sources, "live_binary_audit": live_binary_receipt,
            "source_revision_binding": binding_verification,
            "kernel_results": {kernel: kernel_range(recalculated, kernel) for kernel in kernels},
            "recalculated_workloads": recalculated}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cohort", type=Path)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--related-cohort", type=Path, action="append", default=[],
                        help="optional extracted earlier cohort; may be supplied repeatedly")
    parser.add_argument("--binary-receipt", type=Path,
                        help="optional historical receipt of live binary hashes")
    default_binding = Path(__file__).resolve().parents[1] / "source-revision-binding.json"
    parser.add_argument("--source-binding", type=Path,
                        default=default_binding if default_binding.is_file() else None,
                        help="embedded local-to-published commit/tree binding (auto-detected beside evidence)")
    args = parser.parse_args()
    result = audit(args.cohort.resolve(), args.repo.resolve(),
                   related_cohorts=[path.resolve() for path in args.related_cohort],
                   binary_receipt=args.binary_receipt.resolve() if args.binary_receipt else None,
                   binding_path=args.source_binding.resolve() if args.source_binding else None)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passed": result["passed"], "counts": result["counts"],
                      "kernel_results": result["kernel_results"]}, indent=2))
