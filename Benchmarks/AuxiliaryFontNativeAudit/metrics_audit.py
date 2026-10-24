#!/usr/bin/env python3
"""Independently audit run 40101084730's recorded font-input measurements.

Uses Python's standard library. Executes no benchmark, build, network request,
or Git mutation. --repository optionally checks the pinned Git source objects.
--evidence accepts either the artifact root or its auxiliary-font-results child.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess

BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
CANDIDATE = "4e64b3d2b6098536c61710dca2354442c718961c"
RUN = 40101084730
PAIRS = 6
MIB = 1024 ** 2
MASK = (1 << 64) - 1
VARIANTS = ("baseline", "candidate")
CASES = {"none": 0, "fonts-2mib": 2*MIB, "fonts-16mib": 16*MIB, "fonts-64mib": 64*MIB}
WORKLOADS = (("auxiliary", 1), ("auxiliary", 2), ("auxiliary", 3), ("default", 1))
FOCAL = {"Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift",
         "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift"}
FULL_SOURCES = [
    "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift",
    "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
]
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
BITMAP = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
SOURCE_PATHS = FULL_SOURCES + [PRESENTATION, BITMAP,
    "Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
METRICS = {
    "retained_allocator_delta_bytes": ("memory", lambda r: r["retained_allocator_delta_bytes"]),
    "live_allocator_bytes": ("memory", lambda r: r["after_inputs"]["allocator_bytes"]),
    "live_resident_bytes": ("memory", lambda r: r["after_inputs"]["resident_bytes"]),
    "process_peak_resident_bytes": ("memory", lambda r: r["after_inputs"]["peak_resident_bytes"]),
    "released_allocator_delta_bytes": ("memory", lambda r: r["released_allocator_delta_bytes"]),
    "open_close_wall_seconds_per_batch": ("timing", lambda r: r["wall_seconds"] / r["iterations"]),
    "open_close_cpu_seconds_per_batch": ("timing", lambda r: r["cpu_seconds"] / r["iterations"]),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def extract(source, begin, end):
    require(source.count(begin) == source.count(end) == 1, "Ambiguous extraction markers")
    start, finish = source.index(begin), source.index(end)
    require(start < finish, "Reversed extraction markers")
    return source[start:finish]


def provenance(manifest, repository):
    require(manifest["baseline_revision"] == BASELINE, "Unexpected baseline")
    require(manifest["candidate_worktree_head"] == CANDIDATE, "Unexpected candidate")
    require(manifest["candidate_worktree_status"] == "", "Candidate checkout was dirty")
    require(manifest["source_transformations"].startswith("None."), "Source transformations reported")
    require(set(manifest["allowed_production_differences"]) == FOCAL, "Unexpected focal sources")
    expected = {f"{v}:{p}" for v in VARIANTS for p in SOURCE_PATHS}
    require(set(manifest["sources"]) == expected, "Unexpected source inventory")
    differences = {p for p in SOURCE_PATHS if manifest["sources"][f"baseline:{p}"]["sha256"]
                   != manifest["sources"][f"candidate:{p}"]["sha256"]}
    require(differences == FOCAL, "Nonfocal compiled production source differs")
    for variant in VARIANTS:
        compiled = manifest["compiled_sources"][variant]
        names = {f"{variant}/{Path(p).name}" for p in FULL_SOURCES}
        require(set(compiled) == names | {f"{variant}/ExtractedDeclarations.swift"},
                "Unexpected compiled source inventory")
        for path in FULL_SOURCES:
            require(compiled[f"{variant}/{Path(path).name}"]
                    == manifest["sources"][f"{variant}:{path}"]["sha256"],
                    f"Compiled/production source disagreement: {variant}:{path}")
    require(manifest["compiled_sources"]["baseline"]["baseline/ExtractedDeclarations.swift"]
            == manifest["compiled_sources"]["candidate"]["candidate/ExtractedDeclarations.swift"],
            "Extracted supporting declarations differ")
    checked = {"manifest_source_entries": 26, "compiled_source_hash_links": 18,
               "shared_extracted_hashes_match": True, "git_object_hashes_verified": 0}
    if repository is not None:
        def git_source(revision, path):
            return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=repository)
        for variant, revision in (("baseline", BASELINE), ("candidate", CANDIDATE)):
            texts = {}
            for path in SOURCE_PATHS:
                raw = git_source(revision, path)
                recorded = manifest["sources"][f"{variant}:{path}"]
                require(sha(raw) == recorded["sha256"] and len(raw) == recorded["bytes"],
                        f"Git production source mismatch: {variant}:{path}")
                texts[path] = raw.decode()
                checked["git_object_hashes_verified"] += 1
            helper = "import Foundation\n\n" + extract(texts[PRESENTATION],
                "struct PresentationError:", "\nfunc checkOSStatus(")
            helper += "\n" + extract(texts[BITMAP], "enum PGSSubtitlePacket {",
                                     "\nstruct NativeBitmapSubtitleRegion:")
            require(sha(helper) == manifest["compiled_sources"][variant][f"{variant}/ExtractedDeclarations.swift"],
                    "Extracted compiled declarations differ from pinned Git source")
        for path, digest in manifest["drivers"].items():
            require(sha(git_source(CANDIDATE, path)) == digest, f"Git driver mismatch: {path}")
            checked["git_object_hashes_verified"] += 1
        checked["extracted_declarations_reconstructed_from_git"] = 2
    return checked


def stats(a, b):
    savings = [x-y for x, y in zip(a, b)]
    reductions = [100*(x-y)/x if x > 0 else None for x, y in zip(a, b)]
    finite = [x for x in reductions if x is not None]
    return {"baseline": {"median": statistics.median(a), "minimum": min(a), "maximum": max(a)},
            "candidate": {"median": statistics.median(b), "minimum": min(b), "maximum": max(b)},
            "paired_savings": savings, "paired_reduction_percent": reductions,
            "median_paired_savings": statistics.median(savings),
            "median_paired_reduction_percent": statistics.median(finite) if finite else None,
            "candidate_lower_pairs": sum(x > 0 for x in savings)}


def audit(root, repository):
    if not (root / "observations.jsonl").is_file():
        root = root / "auxiliary-font-results"
    manifest = read_json(root / "manifest.json")
    summary = read_json(root / "summary.json")
    fixtures = read_json(root / "fixtures.json")
    calibration = read_json(root / "calibration.json")
    rows = read_jsonl(root / "observations.jsonl")
    commands = read_jsonl(root / "commands.jsonl")
    require(summary["status"] == "complete" and summary["pairs"] == PAIRS, "Incomplete protocol")
    require(summary["measurement_processes"] == 384, "Incorrect declared measurement process count")
    require(manifest["protocol"]["pairs"] == PAIRS and tuple(map(tuple, manifest["workloads"])) == WORKLOADS,
            "Unexpected declared workload protocol")
    source_checks = provenance(manifest, repository)
    require(len(fixtures) == len(CASES), "Unexpected fixture count")
    for fixture in fixtures:
        require(fixture["name"] in CASES and fixture["accepted_payload_bytes"] == CASES[fixture["name"]],
                "Unexpected fixture payload")
        require(sum(x["bytes"] for x in fixture["attachments"]) == fixture["accepted_payload_bytes"],
                "Fixture attachment inventory mismatch")
        require(all(0 < x["bytes"] <= 16*MIB and x["supported_font"] for x in fixture["attachments"]),
                "Fixture violates per-font admission limits")
    require(len({f["name"] for f in fixtures}) == 4, "Duplicate fixture")
    stage_counts = Counter((r["stage"], r["mode"]) for r in rows)
    require(stage_counts == Counter({("measurement", "memory"): 192,
            ("measurement", "timing"): 192, ("calibration", "timing"): 32}), "Unexpected process matrix")
    measurements = [r for r in rows if r["stage"] == "measurement"]
    expected_identities = {(case, policy, count, mode, pair, variant)
        for case in CASES for policy, count in WORKLOADS for mode in ("memory", "timing")
        for pair in range(PAIRS) for variant in VARIANTS}
    identities = [(r["case"], r["policy"], r["inputs"], r["mode"], r["pair"], r["variant"])
                  for r in measurements]
    require(len(identities) == len(set(identities)) == 384 and set(identities) == expected_identities,
            "Missing or duplicate measured observation")
    command_by_label = {c["label"]: c for c in commands}
    require(len(command_by_label) == len(commands), "Duplicate command receipt")
    require(all(c["returncode"] == 0 for c in commands), "Failed benchmark command")
    raw_stdout_checks = 0
    metadata_checksums = {}
    measurement_labels = []
    measurement_by_label = {}
    for row in rows:
        case, variant, mode = row["case"], row["variant"], row["mode"]
        require(case in CASES and variant in VARIANTS and (row["policy"], row["inputs"]) in WORKLOADS,
                "Unknown observation identity")
        require(row["accepted_payload_bytes"] == CASES[case], "Payload receipt mismatch")
        loads = variant == "baseline" or row["policy"] != "auxiliary"
        require(row["loads_fonts"] is loads, "Wrong constructor policy")
        require(type(row["iterations"]) is int and row["iterations"] > 0, "Invalid iterations")
        if row["stage"] == "measurement":
            expected_order = row["pair"] % 2 if variant == "baseline" else 1-row["pair"] % 2
            require(row["order_index"] == expected_order, "Unbalanced AB/BA ordering")
        label = f"{row['stage']}-{mode}-{case}-{row['policy']}-{row['inputs']}-{row.get('pair', 0)}-{variant}"
        if row["stage"] == "measurement":
            measurement_labels.append(label)
            measurement_by_label[label] = row
        require(label in command_by_label, "Missing process invocation receipt")
        command = command_by_label[label]
        argv = command["argv"]
        require(len(argv) == 7 and Path(argv[0]).parent.name == variant
                and argv[1] == mode and Path(argv[2]).name == case + ".mkv"
                and argv[3:] == [row["policy"], str(row["inputs"]), str(row["iterations"]), str(CASES[case])],
                "Invocation and observation disagree")
        stdout_path = root / command["stdout"]
        if stdout_path.is_file():
            raw = stdout_path.read_bytes()
            require(sha(raw) == command["stdout_sha256"], "Raw process stdout hash mismatch")
            added = {"variant", "case", "stage", "pair", "order_index"}
            require(json.loads(raw) == {k: v for k, v in row.items() if k not in added},
                    "Observation differs from raw process stdout")
            raw_stdout_checks += 1
        if mode == "memory":
            require(row["iterations"] == 1, "Memory measurement repeated within process")
            require(row["main_font_bytes"] == CASES[case]
                    and row["auxiliary_font_bytes"] == (row["inputs"]*CASES[case] if loads else 0),
                    "Font ownership inventory mismatch")
            checkpoints = [row[name] for name in ("before_main", "after_main", "after_inputs",
                                                "after_input_release", "after_all_release")]
            for cp in checkpoints:
                require(all(type(cp[k]) is int and cp[k] > 0 for k in
                            ("allocator_bytes", "resident_bytes", "peak_resident_bytes", "cpu_nanoseconds")),
                        "Invalid native checkpoint")
                require(cp["peak_resident_bytes"] >= cp["resident_bytes"], "Peak below current RSS")
            require(all(a["cpu_nanoseconds"] <= b["cpu_nanoseconds"] and
                        a["peak_resident_bytes"] <= b["peak_resident_bytes"]
                        for a, b in zip(checkpoints, checkpoints[1:])), "Nonmonotonic process counter")
            require(row["retained_allocator_delta_bytes"] == checkpoints[2]["allocator_bytes"]-checkpoints[1]["allocator_bytes"],
                    "Incorrect live allocator delta")
            require(row["retained_resident_delta_bytes"] == checkpoints[2]["resident_bytes"]-checkpoints[1]["resident_bytes"],
                    "Incorrect live RSS delta")
            require(row["released_allocator_delta_bytes"] == checkpoints[3]["allocator_bytes"]-checkpoints[1]["allocator_bytes"],
                    "Incorrect release allocator delta")
            expected_checksum = metadata_checksums.setdefault(case, row["metadata_checksum"])
            require(row["metadata_checksum"] == expected_checksum, "Metadata checksum changed")
        else:
            require(all(type(row[k]) in (int, float) and math.isfinite(row[k]) and row[k] > 0
                        for k in ("wall_seconds", "cpu_seconds")), "Invalid timing")
            require(int(row["checksum"]) == int(row["checksum_per_iteration"])*row["iterations"] & MASK,
                    "Incorrect consumed timing checksum")
    # The recorded invocation and observation sequences must independently
    # agree with AB/BA. Do not infer chronology from the claimed order_index.
    command_measurement_labels = [c["label"] for c in commands if c["label"].startswith("measurement-")]
    require(command_measurement_labels == measurement_labels,
            "Invocation and observation measurement chronology differ")
    command_measurements = [measurement_by_label[label] for label in command_measurement_labels]
    expected_sequence = [(pair, variant) for pair in range(PAIRS)
                         for variant in (VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS)))]
    chronology_cohorts = 0
    for case in CASES:
        for policy, count in WORKLOADS:
            for mode in ("memory", "timing"):
                cohort = (case, policy, count, mode)
                for origin, ordered_rows in (("observations", measurements), ("commands", command_measurements)):
                    sequence = [(r["pair"], r["variant"]) for r in ordered_rows
                                if (r["case"], r["policy"], r["inputs"], r["mode"]) == cohort]
                    require(sequence == expected_sequence,
                            f"Recorded {origin} chronology is not balanced AB/BA: {cohort}")
                chronology_cohorts += 1
    for row in rows:
        if row["mode"] == "timing":
            require(int(row["checksum_per_iteration"]) == int(metadata_checksums[row["case"]])*row["inputs"] & MASK,
                    "Timing checksum does not match memory fixture")
    require(raw_stdout_checks in (0, 416), "Partial raw stdout bundle; cannot audit consistently")
    require(len(calibration) == 16, "Incomplete calibration receipt")
    for item in calibration:
        group = [r for r in rows if r["stage"] == "calibration" and
                 (r["case"], r["policy"], r["inputs"]) == (item["case"], item["policy"], item["inputs"])]
        require(len(group) == 2 and {r["variant"] for r in group} == set(VARIANTS), "Calibration pair missing")
        iterations = min(manifest["protocol"]["max_iterations"], max(1,
            math.ceil(manifest["protocol"]["target_ms"] / 1000 / min(r["wall_seconds"] for r in group))))
        require(item["iterations"] == iterations, "Calibration iteration selection differs")
        require(all(r["iterations"] == iterations for r in measurements if r["mode"] == "timing" and
                    (r["case"], r["policy"], r["inputs"]) == (item["case"], item["policy"], item["inputs"])),
                "Measured iterations differ from calibration")
    summary_by_key = {(r["case"], r["policy"], r["inputs"]): r for r in summary["results"]}
    require(len(summary["results"]) == len(summary_by_key) == 16, "Summary workload count mismatch")
    recalculated = []
    tables = []
    for case in CASES:
        for policy, count in WORKLOADS:
            identity = (case, policy, count)
            recorded = summary_by_key[identity]
            require(recorded["font_bytes_per_input"] == CASES[case], "Summary font inventory mismatch")
            result = {"case": case, "policy": policy, "inputs": count, "font_bytes_per_input": CASES[case], "metrics": {}}
            require(set(recorded["metrics"]) == set(METRICS), "Unexpected summary metrics")
            for name, (mode, value) in METRICS.items():
                group = [r for r in measurements if (r["case"], r["policy"], r["inputs"], r["mode"])
                         == (*identity, mode)]
                a = [value(next(r for r in group if r["pair"] == p and r["variant"] == "baseline")) for p in range(PAIRS)]
                b = [value(next(r for r in group if r["pair"] == p and r["variant"] == "candidate")) for p in range(PAIRS)]
                calculated = stats(a, b)
                require(calculated == recorded["metrics"][name], f"Summary mismatch: {identity}/{name}")
                result["metrics"][name] = calculated
            recalculated.append(result)
            entry = {"case": case, "policy": policy, "auxiliary_inputs": count}
            for field, metric in (("heap", "retained_allocator_delta_bytes"), ("rss", "live_resident_bytes"),
                                  ("peak_rss", "process_peak_resident_bytes"),
                                  ("wall", "open_close_wall_seconds_per_batch"),
                                  ("cpu", "open_close_cpu_seconds_per_batch")):
                data = result["metrics"][metric]
                entry[field] = {"baseline_median": data["baseline"]["median"],
                                "candidate_median": data["candidate"]["median"],
                                "median_paired_saving": data["median_paired_savings"],
                                "median_paired_reduction_percent": data["median_paired_reduction_percent"],
                                "favorable_pairs": data["candidate_lower_pairs"], "pairs": PAIRS}
            tables.append(entry)
    large = [r for r in recalculated if r["policy"] == "auxiliary" and r["case"] in ("fonts-16mib", "fonts-64mib")]
    rss_deltas = [-x for r in large for x in r["metrics"]["live_resident_bytes"]["paired_savings"]]
    require(len(rss_deltas) == 36 and all(x > 0 for x in rss_deltas), "Large-font RSS regression count differs")
    fonts = [r for r in recalculated if r["policy"] == "auxiliary" and r["case"] != "none"]
    heap = [x for r in fonts for x in r["metrics"]["retained_allocator_delta_bytes"]["paired_savings"]]
    require(len(heap) == 54 and all(x > 0 for x in heap), "Font allocator benefit count differs")
    cpu = [x for r in fonts for x in r["metrics"]["open_close_cpu_seconds_per_batch"]["paired_savings"]]
    wall = [x for r in fonts for x in r["metrics"]["open_close_wall_seconds_per_batch"]["paired_savings"]]
    require(sum(x > 0 for x in cpu) == 54 and sum(x > 0 for x in wall) == 52, "Font setup timing counts differ")
    controls = [r for r in recalculated if r["policy"] == "default" or r["case"] == "none"]
    control_savings = [x for r in controls for x in r["metrics"]["retained_allocator_delta_bytes"]["paired_savings"]]
    require(len(control_savings) == 42 and control_savings.count(0) == 41
            and [x for x in control_savings if x != 0] == [-352], "Default/no-font control pattern differs")
    control_exceptions = [{"case": r["case"], "policy": r["policy"], "inputs": r["inputs"],
                           "pair": pair, "candidate_extra_live_allocator_bytes": -saving}
                          for r in controls for pair, saving in enumerate(r["metrics"]["retained_allocator_delta_bytes"]["paired_savings"])
                          if saving != 0]
    release = [r["after_all_release"] for r in measurements if r["mode"] == "memory"
               and r["policy"] == "auxiliary" and r["case"] in ("fonts-16mib", "fonts-64mib")]
    input_names = ["manifest.json", "observations.jsonl", "summary.json", "calibration.json",
                   "commands.jsonl", "fixtures.json", "parity.json", "fixture-manifest.snapshot.json"]
    return {
        "status": "passed", "run_id": RUN, "run_url": f"https://github.com/Jagalite/illiquid/actions/runs/{RUN}",
        "baseline_revision": BASELINE, "candidate_revision": CANDIDATE,
        "audit_script_sha256": sha(Path(__file__).read_bytes()),
        "input_sha256": {name: sha((root/name).read_bytes()) for name in input_names},
        "counts": {"measurement_processes": 384, "memory_processes": 192, "timing_processes": 192,
                   "calibration_processes": 32, "raw_stdout_and_hash_matches": raw_stdout_checks,
                   "paired_metric_records_recomputed_exactly": 112, "native_checkpoints_validated": 960,
                   "balanced_measurement_pairs": 192, "scenario_invocations_validated": 416,
                   "ordered_measurement_cohorts_verified": chronology_cohorts,
                   "command_observation_measurement_sequences_match": True},
        "source_provenance": source_checks,
        "host": {"platform": manifest["platform"], "machine": manifest["machine"], "compiler": manifest["compiler"]},
        "boundaries": {"memory": summary["memory_boundary"], "timing": summary["timing_boundary"],
                       "allocator": "malloc_zone_statistics(NULL).size_in_use; allocator-reported live allocated bytes",
                       "resident": "task_info(MACH_TASK_BASIC_INFO).resident_size; current process RSS",
                       "peak": "getrusage(RUSAGE_SELF).ru_maxrss at the live-input checkpoint"},
        "findings": {
            "font_allocator_inventory": {"favorable_pairs": 54, "pairs": 54,
                "workload_median_saving_range_bytes": [min(r["metrics"]["retained_allocator_delta_bytes"]["median_paired_savings"] for r in fonts),
                                                      max(r["metrics"]["retained_allocator_delta_bytes"]["median_paired_savings"] for r in fonts)],
                "interpretation": "The saving scales approximately as font payload bytes times auxiliary-input count. The metric includes allocator and container overhead, and is not an exact payload-only or physical-memory measure."},
            "default_and_no_font_allocator_controls": {"exact_ties": 41, "pairs": 42,
                "exceptions": control_exceptions,
                "interpretation": "All seven control workload medians tie. One fonts-16mib/default/one-input pair has 352 more live allocator bytes in the candidate; the other 41 pairs tie exactly."},
            "large_font_rss_regressions": {"worse_pairs": 36, "pairs": 36,
                "individual_paired_increase_range_bytes": [min(rss_deltas), max(rss_deltas)],
                "workload_median_increase_range_bytes": [min(-r["metrics"]["live_resident_bytes"]["median_paired_savings"] for r in large),
                                                       max(-r["metrics"]["live_resident_bytes"]["median_paired_savings"] for r in large)]},
            "font_setup_timing": {"cpu_favorable_pairs": 54, "wall_favorable_pairs": 52, "pairs": 54,
                "cpu_workload_median_reduction_percent_range": [min(r["metrics"]["open_close_cpu_seconds_per_batch"]["median_paired_reduction_percent"] for r in fonts),
                                                               max(r["metrics"]["open_close_cpu_seconds_per_batch"]["median_paired_reduction_percent"] for r in fonts)],
                "wall_workload_median_reduction_percent_range": [min(r["metrics"]["open_close_wall_seconds_per_batch"]["median_paired_reduction_percent"] for r in fonts),
                                                                max(r["metrics"]["open_close_wall_seconds_per_batch"]["median_paired_reduction_percent"] for r in fonts)]},
            "after_all_release_large_fonts": {"live_allocator_range_bytes": [min(r["allocator_bytes"] for r in release), max(r["allocator_bytes"] for r in release)],
                                              "resident_range_bytes": [min(r["resident_bytes"] for r in release), max(r["resident_bytes"] for r in release)]},
            "interpretation": "Removing unused auxiliary Swift font copies reduces live allocation inventory and repeated input setup work. This run does not demonstrate lower process RAM: large-font current RSS increases consistently while peak RSS is nearly unchanged.",
            "mechanism": "Unresolved. Allocator caching or virtual-memory behavior is plausible, but the supplied checkpoints do not identify the cause of the RSS difference.",
        },
        "assumptions_and_limits": [
            "This is a deterministic audit of recorded observations, not a new experiment or independent rerun of native code.",
            "The audited implementation is exactly 4e64b3d2b6098536c61710dca2354442c718961c. It is not qualification of another branch, PR head, enum-policy implementation, or later commit.",
            "Four synthetic two-second Matroska fixtures contain video, audio, ASS, chapters and 0/2/16/64 MiB of font-labeled payload. Synthetic font payloads are not a font-rendering correctness test.",
            "Each fresh memory process holds one primary input and 1/2/3 additional serialized inputs. The default-policy control also holds one primary plus one default additional input.",
            "Timing measures repeated open-and-close batches with the primary alive and one warmup batch excluded. It excludes actual playback, rendering, whole-player startup, and long-running resident-memory behavior.",
            "Percent changes are medians of within-pair ratios. They need not equal the ratio of separately displayed medians.",
            "One six-pair cohort on a virtual Apple M1/macOS host provides limited generalization. Fixed workload order and noisy no-font/default timing controls remain visible; no outliers were removed.",
            "Allocator live bytes, current RSS, and peak RSS are distinct metrics. The ~95.7 KB live allocator after release does not prove why RSS remains elevated.",
            "The benchmark source/library/driver compiled, but the run's separate application tests failed to compile. Passing measurement data do not establish passing native application regression tests.",
            "This metrics audit checks source/driver Git bytes only when --repository is supplied. A separate trace audit covers raw semantic traces and native artifact/binary hashes.",
        ],
        "workload_table": tables, "recomputed_results": recalculated,
        "complementary_pr_value": "An evidence-only PR can preserve this independent audit and the RSS tradeoff without duplicating implementation PR #101. It must name the measured revision, retain unfavorable outcomes, and avoid asserting qualification of #101's exact head.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("metrics_audit.json"))
    args = parser.parse_args()
    result = audit(args.evidence.resolve(), args.repository.resolve() if args.repository else None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(json.dumps({"status": result["status"], "output": str(args.output), "counts": result["counts"],
                      "source_provenance": result["source_provenance"], "findings": result["findings"]}, sort_keys=True))


if __name__ == "__main__":
    main()
