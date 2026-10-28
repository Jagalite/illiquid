#!/usr/bin/env python3
"""Qualify source-root index reuse using exact baseline/candidate production sources."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import time
from pathlib import Path

from stage import APP, INDEX, stage

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CASES = [
    ("visibility", 1_000, 1),
    ("visibility", 10_000, 1),
    ("visibility", 100_000, 1),
    ("visibility", 100_000, 16),
    ("remove", 100_000, 1),
    ("replaceLast", 100_000, 1),
    ("equalCopy", 100_000, 1),
]
HEAP_CASES = [
    ("visibility", 100_000, 1),
    ("visibility", 100_000, 16),
    ("remove", 100_000, 1),
]


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command: list[str | Path], out: Path, env: dict, *, allow_failure=False, timeout=900) -> dict:
    args = [str(value) for value in command]
    number = len(list((out / "logs").glob("*.log")))
    log = out / "logs" / f"{number:03d}.log"
    start = time.monotonic()
    completed = subprocess.run(args, cwd=ROOT, env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write_text(completed.stdout)
    receipt = {"command": args, "returncode": completed.returncode,
               "wall_seconds": time.monotonic() - start, "log": str(log.relative_to(out)),
               "log_sha256": sha(log)}
    with (out / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps(receipt, sort_keys=True) + "\n")
    if completed.returncode and not allow_failure:
        print(completed.stdout, flush=True)
        raise RuntimeError(f"Command failed ({completed.returncode}): {args}")
    return {**receipt, "stdout": completed.stdout}


def json_output(command: list[str | Path], out: Path, env: dict) -> dict:
    result = execute(command, out, env)
    return json.loads(result["stdout"])


def check_pair(rows: list[dict], case: tuple, iterations: int) -> None:
    before, after = sorted(rows, key=lambda row: row["variant"] != "baseline")
    if before["snapshot"] != after["snapshot"] or before["final_input_files"] != after["final_input_files"]:
        raise RuntimeError(f"Full-result receipt mismatch for {case}")
    if before["readiness_invalidations"] != iterations:
        raise RuntimeError(f"Baseline did not execute every requested rebuild: {case}")
    expected = 0 if case[0] == "visibility" else iterations
    if after["readiness_invalidations"] != expected:
        raise RuntimeError(f"Candidate invalidation behavior changed: {case}")


def summarize(rows: list[dict]) -> list[dict]:
    summaries = []
    for key in dict.fromkeys(row["case"] for row in rows):
        group = [row for row in rows if row["case"] == key]
        entry = {"case": key, "iterations": group[0]["iterations"],
                 "pairs": len(group) // 2, "variants": {}, "paired_reduction_percent": {}}
        metrics = ("wall_ns_per_op", "cpu_ns_per_op", "synchronous_mutation_ns_per_op",
                   "readiness_invalidations", "heap_before_bytes", "heap_after_bytes",
                   "peak_rss_bytes")
        if group[0]["allocation_sampled"]:
            metrics += ("sampled_peak_heap_bytes", "sampled_peak_growth_bytes")
        for variant in ("baseline", "candidate"):
            selected = [row for row in group if row["variant"] == variant]
            entry["variants"][variant] = {}
            for metric in metrics:
                values = [row[metric] for row in selected]
                entry["variants"][variant][metric] = {
                    "median": statistics.median(values), "min": min(values), "max": max(values)}
        for metric in ("wall_ns_per_op", "cpu_ns_per_op", "synchronous_mutation_ns_per_op"):
            reductions = []
            for pair in sorted({row["pair"] for row in group}):
                values = {row["variant"]: row[metric] for row in group if row["pair"] == pair}
                if values["baseline"]:
                    reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
            entry["paired_reduction_percent"][metric] = {
                "median": statistics.median(reductions), "all": reductions,
                "candidate_faster_pairs": sum(value > 0 for value in reductions)}
        summaries.append(entry)
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Native Foundation/Observation and malloc probes require macOS")
    if args.pairs < 2 or args.pairs > 12 or args.pairs % 2:
        parser.error("--pairs must be even and between 2 and 12")
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift is unavailable")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Output must be new or empty; evidence is never overwritten")
    (out / "logs").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["LC_ALL"] = "en_US.UTF-8"
    env["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(out / "swift-module-cache")

    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "baseline": BASELINE,
        "head": execute(["git", "rev-parse", "HEAD"], out, env)["stdout"].strip(),
        "compiler": execute([swift, "--version"], out, env)["stdout"].strip(),
        "macos": execute(["sw_vers"], out, env)["stdout"].strip(),
        "cpu": execute(["sysctl", "-n", "machdep.cpu.brand_string"], out, env)["stdout"].strip(),
        "pairs": args.pairs, "tests_only": args.tests_only,
        "source_hashes": {path: sha(ROOT / path) for path in (APP, INDEX)},
        "harness_hashes": {str(path.relative_to(ROOT)): sha(path)
                          for path in sorted(HERE.rglob("*")) if path.is_file()
                          and path.suffix in {".py", ".swift", ".c", ".h"}
                          and "__pycache__" not in path.parts and "evidence" not in path.parts},
        "github_run": {name: os.environ.get(name) for name in
                       ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_EVENT_NAME")},
    }
    save(out / "manifest.json", manifest)
    receipts = {}
    packages = {}
    for variant, revision in (("baseline", BASELINE), ("candidate", None)):
        packages[variant] = out / variant
        receipts[variant] = stage(ROOT, packages[variant], revision)
    save(out / "source-receipts.json", receipts)
    if receipts["baseline"][APP]["model_slice_sha256"] != receipts["candidate"][APP]["model_slice_sha256"]:
        raise RuntimeError("Shared production model declarations changed")
    baseline_sources = receipts["baseline"]["compiled_sources"]
    candidate_sources = receipts["candidate"]["compiled_sources"]
    changed = [path for path in baseline_sources if baseline_sources[path] != candidate_sources[path]]
    if set(changed) != {"Sources/IlliquidApp/App/SourceRootIndex.swift", "Sources/IlliquidApp/Owner.swift"}:
        raise RuntimeError(f"Unexpected baseline/candidate source difference: {changed}")

    binaries = {}
    builds = []
    tests = []
    verifications = {}
    # Keep all Swift builds/tests serialized, including those sharing .build.
    for variant in ("baseline", "candidate"):
        package = packages[variant]
        for configuration in ("debug", "release"):
            command = [swift, "build", "--package-path", package, "-c", configuration,
                       "--product", "RootIndexBenchmark", "--jobs", "2", "-Xswiftc", "-warnings-as-errors"]
            build = execute(command, out, env)
            build.pop("stdout")
            location = execute([swift, "build", "--package-path", package, "-c", configuration,
                                "--show-bin-path"], out, env)["stdout"].strip()
            binary = Path(location) / "RootIndexBenchmark"
            build.update(variant=variant, configuration=configuration, binary_sha256=sha(binary))
            builds.append(build)
            verification = json_output([binary, "verify", str(variant == "candidate").lower()], out, env)
            if verification["checks"] < 15 or not verification["observation_delivered"]:
                raise RuntimeError("Observer verification did not execute expected cases")
            verifications[f"{variant}-{configuration}"] = verification
            if configuration == "release":
                binaries[variant] = binary
            if variant == "candidate":
                result = execute([swift, "test", "--package-path", package, "-c", configuration,
                                  "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"], out, env)
                counts = re.findall(r"Test run with (\d+) tests?\b", result["stdout"])
                if not counts or int(counts[-1]) != 8:
                    raise RuntimeError("Expected all eight reuse regression tests to execute")
                result.pop("stdout")
                tests.append({**result, "configuration": configuration, "test_count": int(counts[-1])})
    expected = verifications["baseline-release"]["receipts"]
    for name, value in verifications.items():
        if value["receipts"] != expected:
            raise RuntimeError(f"Behavioral receipts differ for {name}")

    negative = execute([binaries["baseline"], "verify", "true"], out, env, allow_failure=True)
    if negative["returncode"] == 0 or "ready visibility edit had unexpected invalidation behavior" not in negative["stdout"]:
        raise RuntimeError("Baseline negative control did not reach the intended runtime assertion")
    negative.pop("stdout")
    negative["expected_failure"] = "ready visibility edit had unexpected invalidation behavior"
    save(out / "builds.json", builds)
    save(out / "tests.json", tests)
    save(out / "verification.json", verifications)
    save(out / "negative-control.json", negative)
    print("Baseline/candidate debug/release observer verification passed; candidate 8 tests passed in both modes.", flush=True)

    rows = []
    calibrations = {}
    if not args.tests_only:
        for case in CASES:
            key = "/".join(map(str, case))
            samples = []
            for variant in ("baseline", "candidate"):
                row = json_output([binaries[variant], "measure", *map(str, case), "1"], out, env)
                row["variant"] = variant
                samples.append(row)
            check_pair(samples, case, 1)
            # Equal work in each pair; cap changing-input cases at eight edits.
            longest = max(row["wall_ns"] for row in samples)
            iterations = max(1, min(8, math.ceil(100_000_000 / max(1, longest))))
            calibrations[key] = {"samples": samples, "iterations": iterations}
            save(out / "calibrations.json", calibrations)
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                selected = []
                for position, variant in enumerate(order):
                    row = json_output([binaries[variant], "measure", *map(str, case), str(iterations)], out, env)
                    row.update(case=key, pair=pair, position=position, variant=variant)
                    selected.append(row)
                    rows.append(row)
                    with (out / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                check_pair(selected, case, iterations)
            entry = summarize(rows)[-1]
            print(key, json.dumps(entry, sort_keys=True), flush=True)
        for case in HEAP_CASES:
            key = "heap/" + "/".join(map(str, case))
            for pair in range(4):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                selected = []
                for position, variant in enumerate(order):
                    row = json_output([binaries[variant], "measure", *map(str, case), "1", "heap"], out, env)
                    row.update(case=key, pair=pair, position=position, variant=variant)
                    row["sampled_peak_growth_bytes"] = max(
                        0, row["sampled_peak_heap_bytes"] - row["heap_before_bytes"])
                    selected.append(row)
                    rows.append(row)
                    with (out / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                check_pair(selected, case, 1)
            print(key, json.dumps(summarize(rows)[-1], sort_keys=True), flush=True)

    evidence = {"manifest": manifest, "sources": receipts, "builds": builds, "tests": tests,
                "verification": verifications, "negative_control": negative,
                "calibrations": calibrations, "measurements": rows, "summary": summarize(rows)}
    save(out / "evidence.json", evidence)
    save(out / "summary.json", evidence["summary"])
    save(out / "completion.json", {"complete": True, "measurements": len(rows)})
    # Plain JSON can be retrieved through GitHub logs when a local executor is unavailable.
    print("ROOT_INDEX_REUSE_EVIDENCE=" + json.dumps(evidence, sort_keys=True, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
