#!/usr/bin/env python3
"""Independently audit archived Linux evidence without compiling or timing code.

This script does not import the benchmark runner. It recomputes all statistics,
matches measurements to process transcripts, and replays the serialized corpus
snapshots through the harness's documented FNV-1a checksum format.
"""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import itertools
import json
from pathlib import Path
import re


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
EVIDENCE = HERE
WORKLOADS = ("dated-forward", "dated-reverse", "dated-invalid", "dated-unicode",
             "movies", "episodes", "ambiguous", "tags")
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
CHECKSUM_CACHE: dict[tuple[str, int], str] = {}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def read_json(path):
    return json.loads(path.read_text())


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def current_source(role, path):
    if role == "candidate":
        return ROOT / "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
    if role == "baseline":
        return ROOT / "Benchmarks/MediaNameRecognition/baseline/MediaNameRecognition.swift"
    if role == "baselineManifest":
        return ROOT / "Benchmarks/MediaNameRecognition/baseline/manifest.json"
    if role in ("harness", "runner"):
        return ROOT / "Benchmarks/MediaNameRecognition" / ("Harness.swift" if role == "harness" else "run.py")
    if role == "test":
        return ROOT / "Tests/IlliquidCoreTests" / Path(path).name
    return None


def audit_sources(directory):
    manifest = read_json(directory / "sources.json")
    require(manifest["baselineRevision"] == BASELINE, f"{directory.name}: baseline revision")
    records = []
    for entry in manifest["files"]:
        path = directory / entry["path"]
        actual = digest(path)
        require(actual == entry["sha256"] and path.stat().st_size == entry["bytes"],
                f"{directory.name}: snapshot differs: {entry['path']}")
        current = current_source(entry["role"], entry["path"])
        record = {"role": entry["role"], "path": entry["path"], "sha256": actual,
                  "bytes": path.stat().st_size, "snapshotVerified": True}
        if current is not None:
            record.update(currentPath=str(current.relative_to(ROOT)),
                          currentSHA256=digest(current), matchesCurrent=digest(current) == actual)
        records.append(record)
    return records


def audit_archive(directory):
    provenance = read_json(directory / "archive-provenance.json")
    for entry in provenance["copiedFiles"]:
        path = directory / entry["path"]
        require(path.stat().st_size == entry["bytes"] and digest(path) == entry["sha256"],
                f"{directory.name}: archived file differs: {entry['path']}")
    return {"copiedFilesVerified": len(provenance["copiedFiles"]),
            "originalBuildProductsRehashedAtArchiveTime": sum(
                entry["hashVerifiedAtArchiveTime"] for entry in provenance["originalBuildProductChecks"]),
            "buildProductsIncludedInArchive": False}


def audit_corpus(directory):
    report = read_json(directory / "differential/report.json")
    receipts = report["receipts"]
    require([entry["variant"] for entry in receipts] == ["baseline", "candidate"], "Corpus order")
    for entry in receipts:
        require(digest(directory / entry["path"]) == entry["sha256"], "Compressed corpus hash")
    snapshots = []
    hashes = [hashlib.sha256(), hashlib.sha256()]
    count = valid_dates = invalid_dates = 0
    with gzip.open(directory / receipts[0]["path"], "rb") as left, \
            gzip.open(directory / receipts[1]["path"], "rb") as right:
        for first, second in itertools.zip_longest(left, right):
            require(first is not None and first == second, f"Corpus mismatch at {count + 1}")
            hashes[0].update(first)
            hashes[1].update(second)
            record = json.loads(first)
            require(set(record) == {"path", "result"}, "Corpus record shape")
            if count < 512:
                # These are the eight 64-input workloads, in declared order.
                raw = first.split(b',"result":', 1)[1][:-2]
                require(json.loads(raw) == record["result"], "Snapshot byte extraction")
                snapshots.append(raw)
            if report["exhaustiveDates"] and count >= 3734:
                index = count - 3734
                year = 1900 + index // (14 * 33 * 2)
                month = (index // (33 * 2)) % 14
                day = (index // 2) % 33
                spelling = f"{year}-{month:02}-{day:02}" if index % 2 == 0 else f"{day:02}.{month:02}.{year}"
                require(record["path"] == f"News - {spelling} - Headlines.mkv", "Exhaustive input order")
                try:
                    expected = datetime.date(year, month, day).isoformat()
                except ValueError:
                    invalid_dates += 1
                    require("airDate" not in record["result"], "Invalid calendar date accepted")
                else:
                    valid_dates += 1
                    require(record["result"].get("airDate") == expected, "Valid calendar date rejected")
            count += 1
    for value, entry in zip(hashes, receipts):
        require(value.hexdigest() == entry["canonicalSHA256"], "Canonical corpus hash")
        require(count == entry["records"], "Corpus receipt count")
    expected_count = 188534 if report["exhaustiveDates"] else 3734
    require(count == report["records"] == expected_count, "Corpus count")
    if report["exhaustiveDates"]:
        require(valid_dates == 146098 and invalid_dates == 38702, "Independent Gregorian case counts")
    return {"records": count, "byteExactEqual": True, "canonicalSHA256": hashes[0].hexdigest(),
            "exhaustiveDates": report["exhaustiveDates"],
            "independentlyValidatedGregorianRecords": valid_dates + invalid_dates,
            "validDateRecords": valid_dates, "invalidDateRecords": invalid_dates}, snapshots


def replay_checksum(snapshots, count):
    key = (hashlib.sha256(b"\n".join(snapshots)).hexdigest(), count)
    if key in CHECKSUM_CACHE:
        return CHECKSUM_CACHE[key]
    data = b"[" + b",".join(snapshots[index % len(snapshots)] for index in range(count)) + b"]"
    value = 14695981039346656037
    for byte in data:
        value = ((value ^ byte) * 1099511628211) & 0xffffffffffffffff
    result = f"{value:016x}"
    CHECKSUM_CACHE[key] = result
    return result


def audit_timings(directory, snapshots):
    environment = read_json(directory / "environment.json")
    settings = environment["settings"]
    rows = read_rows(directory / "measurements.jsonl")
    summary = read_json(directory / "summary.json")
    commands = read_rows(directory / "commands.jsonl")
    require(len({entry["name"] for entry in commands}) == len(commands), "Duplicate command receipt")
    require(all(entry["returncode"] == 0 for entry in commands), "Failed command in complete cohort")
    by_name = {entry["name"]: entry for entry in commands}
    require(tuple(settings["workloads"]) == WORKLOADS and settings["pairs"] % 2 == 0, "Timing settings")
    expected_count = len(WORKLOADS) * settings["pairs"] * 2
    require(len(rows) == expected_count == summary["processes"], "Incomplete timing matrix")
    require(summary["balancedVariantOrder"] is True, "Unbalanced summary")
    lookup = {}
    for index, row in enumerate(rows):
        pair = index // 16
        position = index % 2
        slot = (index % 16) // 2
        workload = WORKLOADS[(pair + slot) % 8]
        variant = ("baseline", "candidate")[(position + pair) % 2]
        require((row["pair"], row["position"], row["workload"], row["variant"], row["processIndex"])
                == (pair, position, workload, variant, index), "Process order mismatch")
        require(row["iterations"] == settings["iterations"] and row["warmupCount"] == settings["warmup"]
                and row["fixtureCount"] == 64 and row["schemaVersion"] == 1, "Unequal workload settings")
        require(row["wallNanoseconds"] > 0 and row["cpuNanoseconds"] > 0, "Nonpositive duration")
        name = f"timing-{index:03}-{workload}-{variant}"
        command = by_name[name]
        require(command["command"][1:] == ["benchmark", workload, str(settings["iterations"]), str(settings["warmup"])],
                "Timed command arguments differ")
        require(Path(command["command"][0]).parts[-2:] == (variant, "harness"), "Timed binary variant differs")
        text = (directory / command["log"]).read_text()
        require(json.loads(text.splitlines()[0].removeprefix("COMMAND ")) == command["command"], "Transcript command differs")
        stdout, stderr = text.split("\n\nSTDOUT\n", 1)[1].split("\nSTDERR\n", 1)
        payload = {key: value for key, value in row.items() if key not in ("pair", "position", "variant", "processIndex")}
        require(json.loads(stdout) == payload and not stderr.strip(), "Measurement differs from process transcript")
        lookup[(workload, pair, variant)] = row
    results = {}
    for position, workload in enumerate(WORKLOADS):
        selected = [row for row in rows if row["workload"] == workload]
        fixture_snapshots = snapshots[position * 64:(position + 1) * 64]
        expected_checksum = replay_checksum(fixture_snapshots, settings["iterations"])
        expected_warmup = replay_checksum(fixture_snapshots, settings["warmup"])
        require(all(row["checksum"] == expected_checksum and row["warmupChecksum"] == expected_warmup for row in selected),
                f"{workload}: checksum differs from independently replayed corpus")
        expected_group = {"pairs": settings["pairs"], "iterationsPerProcess": settings["iterations"],
                          "checksum": expected_checksum}
        details = {}
        for metric in ("wallNanoseconds", "cpuNanoseconds"):
            ratios = [lookup[(workload, pair, "candidate")][metric] / lookup[(workload, pair, "baseline")][metric]
                      for pair in range(settings["pairs"])]
            operation = {}
            for variant in ("baseline", "candidate"):
                values = [row[metric] / row["iterations"] for row in selected if row["variant"] == variant]
                operation[variant] = {"median": median(values), "min": min(values), "max": max(values)}
            recomputed = {"perOperation": operation, "pairedCandidateOverBaseline": ratios,
                          "medianPairedRatio": median(ratios),
                          "medianPairedReductionPercent": 100 * (1 - median(ratios))}
            expected_group[metric] = recomputed
            details[metric] = {**recomputed, "candidateWins": sum(ratio < 1 for ratio in ratios),
                               "ties": sum(ratio == 1 for ratio in ratios),
                               "pairedRatioRange": [min(ratios), max(ratios)],
                               "pairedReductionPercentRange": [100 * (1 - max(ratios)), 100 * (1 - min(ratios))]}
        require(summary["workloads"][workload] == expected_group, f"{workload}: summary differs from raw observations")
        results[workload] = {"pairs": settings["pairs"], "checksum": expected_checksum,
                             "warmupChecksum": expected_warmup, "checksumsRecomputedFromCorpus": True, **details}
    return {"processes": len(rows), "pairedComparisons": len(rows) // 2,
            "allMeasurementsMatchProcessTranscripts": True, "allSummariesIndependentlyRecomputed": True,
            "iterationsPerProcess": settings["iterations"], "workloads": results}


def audit_complete(name):
    directory = EVIDENCE / name
    corpus, snapshots = audit_corpus(directory)
    sources = audit_sources(directory)
    if name == "linux":
        require(all(entry.get("matchesCurrent", True) for entry in sources), "Final evidence differs from current sources")
    else:
        require(all(entry.get("matchesCurrent", True) for entry in sources if entry["role"] != "candidate"),
                "Ablation harness, baseline, runner or tests differ from current sources")
    result = {"status": "complete", "usedAsFinalTiming": name == "linux", "archive": audit_archive(directory),
              "sources": sources, "corpus": corpus, "timings": audit_timings(directory, snapshots)}
    return result


def audit_validation():
    directory = EVIDENCE / "linux-validation"
    receipts = read_json(directory / "test-results.json")
    require(len(receipts) == 4 and {(entry["variant"], entry["configuration"]) for entry in receipts}
            == set(itertools.product(("baseline", "candidate"), ("debug", "release"))), "Test configuration matrix")
    commands = read_rows(directory / "commands.jsonl")
    results = []
    for receipt in receipts:
        require(receipt["returncode"] == 0, "Failed test receipt")
        log = (directory / receipt["log"]).read_text()
        match = re.findall(r"Test run with (\d+) tests in (\d+) suite(?:s)? passed", log)
        require(match == [("12", "1")], "Expected 12-test pass summary")
        name = f"tests-{receipt['variant']}-{receipt['configuration']}"
        command = next(entry for entry in commands if entry["name"] == name)
        require(command["returncode"] == 0 and command["log"] == receipt["log"], "Test command receipt differs")
        results.append({**receipt, "reportedTests": 12, "reportedSuites": 1, "passSummaryVerified": True})
    failures = [entry for entry in commands if entry["returncode"] != 0]
    require(len(failures) == 1 and failures[0]["name"] == "corpus-baseline" and failures[0]["returncode"] == -4,
            "Original baseline corpus failure missing")
    with gzip.open(directory / "differential/baseline.jsonl.gz", "rb") as stream:
        partial_records = sum(1 for line in stream if json.loads(line))
    sources = audit_sources(directory)
    require(all(entry.get("matchesCurrent", True) for entry in sources if entry["role"] in ("baseline", "candidate", "test")),
            "Validated production or test sources differ")
    return {"status": "tests_passed_then_original_corpus_failed", "overallVerified": False,
            "usedAsFinalTiming": False, "archive": audit_archive(directory), "sources": sources,
            "testRuns": results, "reportedTestInvocations": 48, "originalFailure": failures[0],
            "partialBaselineCorpusRecords": partial_records,
            "note": "Harness and runner snapshots precede the directory-dot corpus exclusion; current production and tests are identical."}


def audit_interrupted():
    directory = EVIDENCE / "linux-interrupted"
    rows = read_rows(directory / "measurements.jsonl")
    require(len(rows) == 86 and [row["processIndex"] for row in rows] == list(range(86)), "Interrupted row count")
    require(not (directory / "summary.json").exists() and not (directory / "verification.json").exists(), "Interrupted cohort labeled complete")
    corpus, _ = audit_corpus(directory)
    return {"status": "incomplete", "overallVerified": False, "usedAsFinalTiming": False,
            "archive": audit_archive(directory), "sources": audit_sources(directory), "corpus": corpus,
            "expectedProcesses": 96, "recordedProcesses": 86, "missingProcessIndexes": list(range(86, 96)),
            "causeReportedByResearchSession": "Disk exhaustion while recording the next timing process; preserved command receipts precede that failure.",
            "note": "No statistics are computed from this incomplete attempt."}


def audit_dot_diagnostic():
    directory = EVIDENCE / "linux-dot-diagnostic"
    results = read_json(directory / "results.json")
    for name, expected in results["sources"].items():
        require(digest(directory / name) == expected, "Diagnostic source hash")
    expected = {"baseline-dot": -4, "candidate-dot": -4, "foundation-dot": -4,
                "baseline-control": 0, "candidate-control": 0,
                "build-baseline": 0, "build-candidate": 0, "build-foundation": 0}
    require({entry["name"]: entry["returncode"] for entry in results["records"]} == expected, "Diagnostic result matrix")
    for record in results["records"]:
        require((directory / record["stdout"]).is_file() and (directory / record["stderr"]).is_file(), "Diagnostic stream missing")
    require((directory / "baseline-control.stdout").read_bytes() == (directory / "candidate-control.stdout").read_bytes(),
            "Diagnostic successful control differs")
    return {"status": "diagnostic", "usedAsFinalTiming": False, "archive": audit_archive(directory),
            "sourceHashesVerified": 2, "returnCodes": expected,
            "note": "The directory-only dot input traps in both variants and a direct Linux Foundation probe; .mkv controls complete identically."}


def main():
    global ROOT, EVIDENCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", type=Path, default=HERE,
                        help="Directory containing the six extracted Linux cohort directories")
    parser.add_argument("--repository-root", type=Path, default=ROOT,
                        help="Repository whose current source files should match final evidence")
    parser.add_argument("--output", type=Path, help="Defaults to EVIDENCE_ROOT/independent-audit.json")
    args = parser.parse_args()
    ROOT = args.repository_root.resolve()
    EVIDENCE = args.evidence_root.resolve()
    cohorts = {}
    for name in ("linux", "linux-date-only", "linux-tags-only"):
        cohorts[name] = audit_complete(name)
        print(f"Audited {name}: {cohorts[name]['timings']['processes']} measurements; {cohorts[name]['corpus']['records']} corpus records")
    cohorts["linux-validation"] = audit_validation()
    cohorts["linux-interrupted"] = audit_interrupted()
    cohorts["linux-dot-diagnostic"] = audit_dot_diagnostic()
    final = cohorts["linux"]["timings"]
    totals = {}
    for metric in ("wallNanoseconds", "cpuNanoseconds"):
        groups = final["workloads"].values()
        totals[metric] = {"candidateWinningPairs": sum(group[metric]["candidateWins"] for group in groups),
                          "pairedComparisons": final["pairedComparisons"],
                          "workloadsWinningEveryPair": [name for name, group in final["workloads"].items()
                                                       if group[metric]["candidateWins"] == group["pairs"]]}
    result = {"schemaVersion": 1, "auditedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "auditScriptSHA256": digest(Path(__file__)), "success": True,
              "method": "Independent Python audit; no benchmark runner import, compiler invocation, or new measurement.",
              "finalCohort": "linux", "finalTotals": totals, "cohorts": cohorts}
    destination = args.output or EVIDENCE / "independent-audit.json"
    destination.write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(json.dumps(totals, indent=2))


if __name__ == "__main__":
    main()
