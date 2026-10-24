#!/usr/bin/env python3
"""Independently audit completed media-section memory receipts; never run benchmarks.

Usage: python3 audit-results.py --results MAIN [STRESS] --output audit.json
Source reconstruction requires the proposed checkout and its pinned baseline.
Compact evidence may omit binaries, staged packages, and large verification
traces; the receipt explicitly reports which optional files were available.
"""
from __future__ import annotations

import argparse
import ast
from collections import Counter
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys

VARIANTS = ("baseline", "candidate")
METRICS = ("process_peak_rss_before_bytes", "process_peak_rss_after_bytes",
           "process_peak_rss_growth_bytes", "elapsed_ns", "cpu_ns")
DRIVERS = {"run.py": "Benchmarks/MediaSectionMemory/run.py",
           "Harness.swift": "Benchmarks/MediaSectionMemory/Harness.swift",
           "source-snapshot-helper.py": "Benchmarks/SourceTreeVisibility/run.py"}
ADAPTATIONS = {
    "Sources/IlliquidCore/MediaSidecarReader.swift": ("import Darwin\n", "import Glibc\n"),
    "Sources/IlliquidCore/NFOMetadataHints.swift":
        ("import Foundation\n", "import Foundation\nimport FoundationXML\n"),
    "Tests/IlliquidAppTests/SourceMediaOrganizationTests.swift": (
        'appendingPathComponent("media-sidecars-" + UUID().uuidString)',
        'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def equal_files(left, right):
    with left.open("rb") as a, right.open("rb") as b:
        while True:
            x, y = a.read(1024 * 1024), b.read(1024 * 1024)
            if x != y:
                return False
            if not x:
                return True


def read_json(path):
    return json.loads(path.read_text())


def read_lines(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def close_number(actual, expected, label):
    require(actual is None if expected is None else
            isinstance(actual, (int, float)) and math.isfinite(actual)
            and math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9), label)


def source_audit(root, repo, environment):
    manifests = {v: read_json(root / (v + "-sources.json")) for v in VARIANTS}
    comparison = environment["comparison"]
    require(comparison["mode"] in {"historical-strict", "current-support"}
            and comparison["focal_baseline_revision"] == environment["baseline"]
            and comparison["candidate_worktree_head"] == environment["head"], "Invalid comparison provenance")
    focal = set(comparison["focal_sources"])
    require(bool(focal), "Missing focal production source")
    current_drivers = {name: (repo / path).read_bytes() for name, path in DRIVERS.items()}
    for name, raw in current_drivers.items():
        require(digest(raw) == environment["driver_hashes"][name], "Current driver changed: " + name)
        require(file_digest(root / name) == digest(raw), "Saved driver differs: " + name)
    syntax = ast.parse(current_drivers["source-snapshot-helper.py"])
    package = next(ast.literal_eval(node.value) for node in syntax.body
                   if isinstance(node, ast.Assign) and any(
                       isinstance(target, ast.Name) and target.id == "PACKAGE" for target in node.targets))
    package = package.replace("SourceTreeVisibilityQualification", "MediaSectionMemoryQualification")
    package = package.replace("SourceTreeBenchmark", "MediaSectionMemoryBenchmark").encode()
    cached = {}
    staged_present = 0
    for variant, manifest in manifests.items():
        require(manifest["variant"] == variant and manifest["baseline_revision"] == environment["baseline"],
                "Source variant/baseline mismatch")
        require(manifest["comparison"] == environment["comparison"], "Source comparison mismatch")
        snapshots = {}
        for name, record in manifest["production"].items():
            pinned = variant == "baseline" and (name in focal or comparison["mode"] == "historical-strict")
            require(record["origin"] == ("pinned-baseline" if pinned else "working-tree")
                    and record.get("revision") == (environment["baseline"] if pinned else None),
                    "Mislabeled source provenance: " + name)
            require(record["comparison_role"] == ("focal" if name in focal else "support"),
                    "Mislabeled source role: " + name)
            revision = record.get("revision") if record["origin"] == "pinned-baseline" else None
            key = (revision, record["repository_path"])
            if key not in cached:
                cached[key] = (subprocess.check_output(["git", "show", f"{revision}:{key[1]}"], cwd=repo)
                               if revision else (repo / key[1]).read_bytes())
            raw = cached[key]
            require(digest(raw) == record["source_sha256"], "Original source changed: " + str(key))
            require(hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
                    == record["git_blob"], "Git blob mismatch: " + name)
            if record["excerpts"]:
                source, sections = raw.decode(), []
                for excerpt in record["excerpts"]:
                    start, end = excerpt["start"], excerpt["end"]
                    require(source.count(start) == source.count(end) == 1, "Ambiguous excerpt: " + name)
                    require(source.index(start) < source.index(end), "Reversed excerpt: " + name)
                    section = source[source.index(start):source.index(end)]
                    require(digest(section.encode()) == excerpt["sha256"], "Excerpt mismatch: " + name)
                    sections.append(section)
                raw = ("import Foundation\nimport IlliquidCore\n\n" + "\n\n".join(sections) + "\n").encode()
            require(digest(raw) == record["snapshot_sha256"], "Snapshot mismatch: " + name)
            snapshots[name] = raw
        adaptations = {a["path"]: (a["before"], a["after"]) for a in manifest["adaptations"]}
        expected_adaptations = ADAPTATIONS if environment["platform"].startswith("Linux") else {}
        require(adaptations == expected_adaptations, "Unexpected platform source adaptations")
        for name, hashes in manifest["staged"].items():
            if name in snapshots:
                raw = snapshots[name]
            elif name == "Package.swift":
                raw = package
            elif name == "Sources/MediaSectionMemoryBenchmark/Harness.swift":
                raw = current_drivers["Harness.swift"]
            else:
                require(name.startswith("Tests/IlliquidAppTests/"), "Unexpected staged source: " + name)
                raw = (repo / name).read_bytes()
            require(digest(raw) == hashes["source_sha256"], "Staged input mismatch: " + name)
            if name in adaptations:
                before, after = (s.encode() for s in adaptations[name])
                require(raw.count(before) == 1, "Adaptation boundary changed: " + name)
                raw = raw.replace(before, after, 1)
            require(digest(raw) == hashes["compiled_sha256"], "Compiled source mismatch: " + name)
            actual = root / "packages" / variant / name
            if actual.exists():
                require(file_digest(actual) == digest(raw), "Staged file changed: " + name)
                staged_present += 1
    require(manifests["baseline"]["staged"].keys() == manifests["candidate"]["staged"].keys(),
            "Variant source inventories differ")
    require(focal <= manifests["baseline"]["production"].keys(), "Missing focal source in manifest")
    for name, hashes in manifests["baseline"]["staged"].items():
        if name not in focal:
            require(hashes == manifests["candidate"]["staged"][name], "Unequal support source: " + name)
    return manifests, staged_present


def audit(root, repo):
    environment = read_json(root / "environment.json")
    completion = read_json(root / "completion.json")
    require(completion["complete"] is True and completion["mode"] == environment["mode"], "Incomplete run")
    require(environment["mode"] in {"all", "benchmark"}, "Run does not contain a full measured cohort")
    commands = read_lines(root / "commands.jsonl")
    require(len(commands) == completion["commands"], "Completion command count differs")
    by_label = {c["label"]: c for c in commands}
    require(len(by_label) == len(commands), "Duplicate command labels")
    logs_checked, logs_omitted = 0, 0
    for command in commands:
        require(command["returncode"] == 0, "Failed command: " + command["label"])
        for channel in ("stdout", "stderr"):
            path = root / command[channel]
            if path.exists():
                require(file_digest(path) == command[channel + "_sha256"], "Command log changed: " + str(path))
                logs_checked += 1
            else:
                logs_omitted += 1

    manifests, staged_present = source_audit(root, repo, environment)
    tests = read_json(root / "tests.json") if (root / "tests.json").exists() else []
    if environment["mode"] == "all" or tests:
        require(len(tests) == 4 and {(t["variant"], t["configuration"]) for t in tests}
                == set(itertools.product(VARIANTS, ("debug", "release"))), "Missing test variant/configuration")
        require(len({t["count"] for t in tests}) == 1, "Test counts differ across configurations")
        for test in tests:
            require(test["passed"] is True and test["count"] > 0, "Failed/empty tests")
            command = by_label[f"tests-{test['variant']}-{test['configuration']}"]
            paths = [root / command[channel] for channel in ("stdout", "stderr")]
            if all(p.exists() for p in paths):
                counts = re.findall(r"Test run with (\d+) tests?", "\n".join(p.read_text() for p in paths))
                require(counts and int(counts[-1]) == test["count"], "Test log count differs")

    grid = list(itertools.product(environment["cases"], environment["sizes"], environment["measurements"]))
    require(grid and len(grid) == len(set(grid)), "Empty or repeated case/size/mode")
    pairs = environment["pairs"]
    require(pairs >= 2 and pairs % 2 == 0, "Pair count cannot provide balanced ordering")
    rows = read_lines(root / "observations.jsonl")
    identities = [(r["case"], r["size"], r["measurement"], r["pair"], r["variant"]) for r in rows]
    expected = [(*cell, pair, variant) for cell in grid for pair in range(pairs)
                for variant in (VARIANTS if pair % 2 == 0 else VARIANTS[::-1])]
    require(identities == expected, "Observation grid/order differs or is incomplete")
    require([r["label"] for r in rows] == [c["label"] for c in commands if c["label"].startswith("pair-")],
            "Command and observation order differ")
    indexed = dict(zip(identities, rows))
    binaries = read_json(root / "binaries.json")
    build = by_label["build-baseline"]["command"]
    original_root = Path(build[build.index("--scratch-path") + 1]).parent.parent
    binaries_present = 0
    for info in binaries.values():
        path = Path(info["path"])
        if path.is_relative_to(root) and path.exists():
            require(file_digest(path) == info["sha256"], "Measured executable changed")
            binaries_present += 1
    for row in rows:
        require(row["order"] == list(VARIANTS if row["pair"] % 2 == 0 else VARIANTS[::-1]), "Wrong AB/BA order")
        require(row["complete_output_byte_verified"] is True and row["complete_output_verified"] is True,
                "Output verification missing")
        iterations = 1 if row["measurement"] == "cold" else environment["refresh_iterations"]
        require(row["iterations"] == iterations and iterations > 0, "Wrong iteration count")
        require(row["priming_projections"] == (row["measurement"] == "refresh"), "Wrong priming count")
        require(row["process_peak_rss_after_bytes"] >= row["process_peak_rss_before_bytes"] > 0,
                "Invalid RSS high-water readings")
        require(row["process_peak_rss_growth_bytes"] == row["process_peak_rss_after_bytes"]
                - row["process_peak_rss_before_bytes"], "Wrong high-water difference")
        require(row["elapsed_ns"] > 0 and row["cpu_ns"] > 0, "Invalid timing")
        command = by_label[row["label"]]
        oracle = original_root / by_label[f"verify-{row['case']}-{row['size']}-baseline"]["stdout"]
        require(command["command"] == [binaries[row["variant"]]["path"], "measure", row["case"],
                str(row["size"]), row["measurement"], str(iterations), str(oracle)], "Wrong measured command/oracle")
        path = root / command["stdout"]
        if path.exists():
            raw = {k: v for k, v in row.items() if k not in {"variant", "pair", "order", "label"}}
            require(read_json(path) == raw, "Raw observation differs from process output")

    saved = read_json(root / "summary.json")
    require([(s["case"], s["size"], s["measurement"]) for s in saved] == grid, "Summary grid differs")
    highlights = []
    for cell, summary in zip(grid, saved):
        require(summary["pairs"] == pairs, "Summary pair count differs")
        for pair in range(pairs):
            a, b = (indexed[(*cell, pair, v)] for v in VARIANTS)
            for key in ("checksum", "rows", "sections", "tree_build_count", "visibility_build_count",
                        "row_stride_bytes", "index_stride_bytes"):
                require(a[key] == b[key], "Paired output receipt differs: " + key)
        for metric in METRICS:
            result = summary[metric]
            for variant in VARIANTS:
                samples = [indexed[(*cell, p, variant)] for p in range(pairs)]
                values = [r[metric] / (r["iterations"] if metric.endswith("_ns") else 1) for r in samples]
                for name, value in (("median", statistics.median(values)), ("min", min(values)), ("max", max(values))):
                    close_number(result[variant][name], value, "Wrong summary: " + str((cell, metric, variant, name)))
            changes = []
            for pair in range(pairs):
                a, b = (indexed[(*cell, pair, v)][metric] for v in VARIANTS)
                changes.append(100 * (b / a - 1) if a else None)
            require(len(result["paired_change_percent"]) == pairs, "Wrong paired-change count")
            for actual, expected_change in zip(result["paired_change_percent"], changes):
                close_number(actual, expected_change, "Wrong paired change")
            defined = [x for x in changes if x is not None]
            close_number(result["median_paired_change_percent"], statistics.median(defined) if defined else None,
                         "Wrong median paired change")
            require(result["lower_pairs"] == sum(x < 0 for x in defined), "Wrong lower-pair count")
        highlights.append(dict(zip(("case", "size", "measurement"), cell)) | {
            "rss_median_paired_change_percent": summary["process_peak_rss_after_bytes"]["median_paired_change_percent"],
            "rss_lower_pairs": summary["process_peak_rss_after_bytes"]["lower_pairs"],
            "wall_median_paired_change_percent": summary["elapsed_ns"]["median_paired_change_percent"],
            "cpu_median_paired_change_percent": summary["cpu_ns"]["median_paired_change_percent"]})

    verification = read_json(root / "verification.json")
    require(Counter((r["case"], r["size"]) for r in verification)
            == Counter(itertools.product(environment["cases"], environment["sizes"])), "Wrong verification grid")
    traces_checked = 0
    for record in verification:
        require(record["complete_output_equal"] is True, "Separate output verification failed")
        for variant in VARIANTS:
            command = by_label[f"verify-{record['case']}-{record['size']}-{variant}"]["command"]
            require(command == [binaries[variant]["path"], "verify", record["case"], str(record["size"])],
                    "Wrong verification command")
        paths = [root / by_label[f"verify-{record['case']}-{record['size']}-{v}"]["stdout"] for v in VARIANTS]
        for path in paths:
            if path.exists():
                require(path.stat().st_size == record["trace_bytes"] and file_digest(path) == record["trace_sha256"],
                        "Verification trace receipt differs")
        if all(p.exists() for p in paths):
            require(equal_files(*paths), "Verification traces differ byte for byte")
            traces_checked += 1
    input_names = ["environment.json", "completion.json", "commands.jsonl", "observations.jsonl",
                   "summary.json", "verification.json", "baseline-sources.json", "candidate-sources.json"]
    return {"path": str(root), "observations": len(rows), "pairs": len(rows) // 2,
            "grid_cells": len(grid), "pairs_per_cell": pairs, "ab_pairs_per_cell": pairs // 2,
            "ba_pairs_per_cell": pairs // 2, "byte_verified_observations": len(rows),
            "platform": environment["platform"], "swift": environment["swift"],
            "comparison_mode": environment["comparison"]["mode"],
            "row_stride_bytes": sorted({r["row_stride_bytes"] for r in rows}),
            "index_stride_bytes": sorted({r["index_stride_bytes"] for r in rows}),
            "tests": tests, "verification_datasets": len(verification), "trace_pairs_byte_compared": traces_checked,
            "command_logs_hashed": logs_checked, "command_logs_omitted": logs_omitted,
            "staged_files_present_and_hashed": staged_present, "binaries_present_and_hashed": binaries_present,
            "all_proposed_sources_reconstructed": True, "driver_hashes": environment["driver_hashes"],
            "baseline": environment["baseline"], "exploratory": environment["exploratory"],
            "input_sha256": {name: file_digest(root / name) for name in input_names}, "workloads": highlights}, manifests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, nargs="+", required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    receipt = {"status": "failed", "audited_at_utc": datetime.now(timezone.utc).isoformat(),
               "audit_script_sha256": file_digest(Path(__file__)), "cohorts": [],
               "limits": ["RSS is process high-water memory, not live heap or whole-player memory.",
                          "Refresh RSS includes priming; high-water growth is not allocated bytes.",
                          "Timing changes are reported for every workload, including regressions and controls.",
                          "Omitted binaries/logs/traces are not independently revalidated from hashes alone."]}
    manifests = []
    try:
        for path in args.results:
            result, sources = audit(path.resolve(), args.repo.resolve())
            receipt["cohorts"].append(result)
            manifests.append(sources)
        for sources in manifests[1:]:
            for variant in VARIANTS:
                require(sources[variant]["staged"] == manifests[0][variant]["staged"],
                        "Cohorts measured different staged sources: " + variant)
        require(all(c["driver_hashes"] == receipt["cohorts"][0]["driver_hashes"] for c in receipt["cohorts"]),
                "Cohort drivers differ")
        receipt.update(status="passed", total_observations=sum(c["observations"] for c in receipt["cohorts"]),
                       total_pairs=sum(c["pairs"] for c in receipt["cohorts"]),
                       same_staged_sources_across_cohorts=True if len(manifests) > 1 else None)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        receipt["error"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(json.dumps({k: receipt[k] for k in ("status", "total_observations", "total_pairs", "error") if k in receipt}))
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
