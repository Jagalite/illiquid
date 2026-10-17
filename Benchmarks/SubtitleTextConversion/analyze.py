#!/usr/bin/env python3
"""Validate complete converter evidence and summarize every fresh-process pair.

The input may be results.json or a gzip-compressed copy. This checks recorded
output-verification receipts; it does not rerun conversion or authenticate the
recorded hashes against files that may no longer be present.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import itertools
import json
import math
import statistics
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def positive_integer(value: object) -> bool:
    return type(value) is int and value > 0


def finite_number(value: object) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def check_digest(value: object, label: str) -> None:
    require(isinstance(value, str) and len(value) == 64
            and set(value) <= set("0123456789abcdef"), f"invalid SHA-256: {label}")


def close(actual: object, expected: float, label: str) -> None:
    require(finite_number(actual) and math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-12),
            f"summary disagrees with observations: {label}")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def analyze(evidence: dict) -> dict:
    require(type(evidence["schema"]) is int and evidence["schema"] == 1, "unsupported evidence schema")
    require(evidence["status"] == "complete" and "failure" not in evidence,
            "evidence is incomplete or records a failure")
    sizes, scenarios, formats = (evidence[key] for key in ("sizes", "scenarios", "formats"))
    for key, values in (("sizes", sizes), ("scenarios", scenarios), ("formats", formats)):
        require(isinstance(values, list) and len(values) > 0 and len(values) == len(set(values)),
                f"empty or duplicated planned {key}")
    require(all(positive_integer(size) for size in sizes), "invalid planned cue count")
    require(all(isinstance(value, str) and value for value in scenarios), "invalid scenario")
    require(set(formats) <= {"srt", "webvtt"}, "invalid format")
    repeats, rounds = evidence["repeats"], evidence["rounds"]
    require(positive_integer(repeats) and positive_integer(rounds), "invalid repeats or rounds")
    require(type(evidence["warmup_conversions_per_process"]) is int
            and evidence["warmup_conversions_per_process"] == 1, "unexpected warmup count")
    workloads = list(itertools.product(sizes, scenarios, formats))
    rows, verifications, summaries = (evidence[key] for key in ("runs", "verification", "summary"))
    require(len(rows) == len(workloads) * repeats * 2, "incomplete or extra process observations")
    require(len(verifications) == len(workloads) and len(summaries) == len(workloads),
            "incomplete or extra workload verification/summary records")
    for field in ("source_sha256", "executables_sha256"):
        require(set(evidence[field]) == {"baseline", "candidate"}, f"invalid {field} variants")
        for variant, value in evidence[field].items():
            check_digest(value, f"{field}/{variant}")
    for field in ("driver_sha256", "runner_sha256"):
        check_digest(evidence[field], field)

    commands, flags = evidence["commands"], evidence["compiler_flags"]
    require(len(commands) == 2 + len(workloads) * (2 + repeats * 2),
            "incomplete or extra command records")
    require(all(isinstance(command, list) and all(isinstance(arg, str) for arg in command)
                for command in commands), "invalid command record")
    require(isinstance(flags, list) and all(isinstance(flag, str) for flag in flags),
            "invalid compiler flags")
    executables = {}
    for index, variant in enumerate(("baseline", "candidate")):
        command = commands[index]
        require(len(command) == len(flags) + 5, "unexpected compiler command shape")
        executable = Path(command[-1])
        expected = [commands[0][0], *flags,
                    str(executable.parent / "ExternalTextSubtitleConverter.swift"),
                    str(executable.parent / "main.swift"), "-o", str(executable)]
        require(command == expected and executable.parent.name == variant,
                f"compiler command disagrees with variant/flags: {variant}")
        executables[variant] = str(executable)
    output_root = Path(executables["baseline"]).parent.parent
    require(Path(executables["candidate"]).parent.parent == output_root,
            "executables belong to different experiment directories")

    results = []
    row_index, command_index = 0, 2
    for workload_index, (cues, scenario, format_name) in enumerate(workloads):
        case = {"cues": cues, "scenario": scenario, "format": format_name}
        verification, summary = verifications[workload_index], summaries[workload_index]
        for label, record in (("verification", verification), ("summary", summary)):
            require(all(type(record[key]) is type(value) and record[key] == value
                        for key, value in case.items()),
                    f"{label} workload order/identity mismatch: {case}")
        for field in ("input_sha256", "output_sha256"):
            check_digest(verification[field], f"{case}/{field}")
        require(all(positive_integer(verification[field]) for field in ("input_bytes", "output_bytes")),
                f"invalid verification byte counts: {case}")
        fixture_name = f"{cues}-{scenario}-{format_name}"
        source = str(output_root / "fixtures" / f"{fixture_name}.txt")
        expected = str(output_root / "fixtures" / f"{fixture_name}-baseline.ass")
        for variant in ("baseline", "candidate"):
            destination = str(output_root / "fixtures" / f"{fixture_name}-{variant}.ass")
            require(commands[command_index] == [executables[variant], "emit", format_name, source, destination],
                    f"output-verification command order/identity mismatch: {case}/{variant}")
            command_index += 1
        samples = {"baseline": [], "candidate": []}
        pairs = []
        for repeat in range(repeats):
            order = ("baseline", "candidate") if repeat % 2 == 0 else ("candidate", "baseline")
            observations = {}
            sequences = {}
            for position, variant in enumerate(order):
                row = rows[row_index]
                identity = {**case, "variant": variant, "repeat": repeat,
                            "pair_position": position, "sequence": row_index}
                require(all(type(row[key]) is type(value) and row[key] == value
                            for key, value in identity.items()),
                        f"process sequence/order/pair identity mismatch at observation {row_index}")
                require(commands[command_index] == [executables[variant], "measure", format_name,
                                                    source, expected, str(rounds)],
                        f"measurement command mismatch at observation {row_index}")
                require(type(row["verified_rounds"]) is int and row["verified_rounds"] == rounds,
                        f"unverified or incomplete rounds at observation {row_index}")
                require(all(type(row[field]) is int and row[field] == verification[field]
                            for field in ("input_bytes", "output_bytes")),
                        f"verification byte-count mismatch at observation {row_index}")
                durations = row["milliseconds"]
                require(isinstance(durations, list) and len(durations) == rounds
                        and all(finite_number(value) and value > 0 for value in durations),
                        f"invalid or incomplete durations at observation {row_index}")
                observations[variant] = statistics.median(durations)
                samples[variant].append(observations[variant])
                sequences[variant] = row_index
                row_index += 1
                command_index += 1
            ratio = observations["candidate"] / observations["baseline"]
            pairs.append({"repeat": repeat, "baseline_first": repeat % 2 == 0,
                          "process_sequences": sequences,
                          "baseline_median_ms": observations["baseline"],
                          "candidate_median_ms": observations["candidate"],
                          "candidate_baseline_ratio": ratio})
        baseline, candidate = (statistics.median(samples[variant]) for variant in ("baseline", "candidate"))
        close(summary["baseline_median_ms"], baseline, f"{case}/baseline")
        close(summary["candidate_median_ms"], candidate, f"{case}/candidate")
        close(summary["reduction_percent"], 100 * (1 - candidate / baseline), f"{case}/reduction")
        ranges = {variant: [min(values), max(values)] for variant, values in samples.items()}
        for variant, values in ranges.items():
            require(len(summary["process_median_range_ms"][variant]) == 2, "invalid summary range")
            for index, value in enumerate(values):
                close(summary["process_median_range_ms"][variant][index], value, f"{case}/{variant}/range")
        ratios = [pair["candidate_baseline_ratio"] for pair in pairs]
        median_ratio = statistics.median(ratios)
        results.append({**case, "baseline_median_ms": baseline, "candidate_median_ms": candidate,
                        "ratio_of_variant_medians": candidate / baseline,
                        "process_median_range_ms": ranges,
                        "median_paired_ratio": median_ratio,
                        "paired_reduction_percent": 100 * (1 - median_ratio),
                        "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
                        "equal_pairs": sum(ratio == 1 for ratio in ratios),
                        "candidate_slower_pairs": sum(ratio > 1 for ratio in ratios),
                        "pairs": pairs})
    return {
        "schema": 1, "status": "complete", "workloads": len(workloads),
        "process_observations": len(rows), "timed_conversions": len(rows) * rounds,
        "sizes": sizes, "scenarios": scenarios, "formats": formats,
        "repeats": repeats, "rounds": rounds,
        "method": "Median of within-pair candidate/baseline process medians; all pairs retained.",
        "interpretation": "Descriptive comparison; no significance test, performance threshold, or discarded observations.",
        "output_verification_scope": "Validates recorded per-round verification counts, byte counts, and fixture hash format; does not rerun conversion or rehash external artifacts.",
        "source_sha256": evidence["source_sha256"], "baseline_commit": evidence["baseline_commit"],
        "driver_sha256": evidence["driver_sha256"], "runner_sha256": evidence["runner_sha256"],
        "executables_sha256": evidence["executables_sha256"],
        "swift": evidence["swift"], "platform": evidence["platform"], "summary": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="completed results.json or results.json.gz")
    parser.add_argument("--output", required=True, type=Path, help="new JSON file; existing files are refused")
    args = parser.parse_args()
    try:
        raw = args.input.read_bytes()
        if raw.startswith(b"\x1f\x8b"):
            raw = gzip.decompress(raw)
        evidence = json.loads(raw, object_pairs_hook=unique_object)
        result = analyze(evidence)
        result["input_json_sha256"] = hashlib.sha256(raw).hexdigest()
        result["analyzer_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    except (OSError, EOFError, ValueError, KeyError, TypeError, IndexError) as error:
        parser.exit(2, f"Evidence validation failed: {error}\n")
    print(f"Validated {result['workloads']} workloads, {result['process_observations']} processes, "
          f"and {result['timed_conversions']} timed conversions; wrote {args.output}")


if __name__ == "__main__":
    main()
