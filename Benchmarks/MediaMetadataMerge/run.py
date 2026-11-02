#!/usr/bin/env python3
"""Paired timings and complete output parity for production metadata merges."""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HINTS = Path("Sources/IlliquidCore/MediaLibrary/MediaMetadataHints.swift")
MASK = (1 << 64) - 1

def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

def digest(data):
    return hashlib.sha256(data).hexdigest()

def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

class Run:
    def __init__(self, output):
        self.output = output
        self.commands = []
        (output / "logs").mkdir()

    def command(self, args, label, structured=False):
        args = [str(x) for x in args]
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
        self.commands.append({"command": args, "label": label, "exit_code": result.returncode,
                              "elapsed_seconds": time.monotonic() - started})
        save(self.output / "commands.json", self.commands)
        if not structured or result.returncode or result.stderr:
            (self.output / "logs" / (label + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"{label} failed:\n{result.stdout}\n{result.stderr}")
        return json.loads(result.stdout) if structured else result.stdout.strip()

def check(row, reference, case, iterations):
    if (row["case_id"] != case["id"] or row["mode"] != "measure"
            or row["iterations"] != iterations or row["pool_size"] != case["pool_size"]
            or row["operations"] != iterations * case["pool_size"]):
        raise ValueError("Incorrect measurement identity or operation count")
    if row["output"] != reference["output"]:
        raise ValueError(case["id"] + ": complete output changed")
    if int(row["checksum"]) != (int(reference["checksum"]) * iterations) & MASK:
        raise ValueError(case["id"] + ": checksum mismatch")
    for key in ("elapsed_ns", "cpu_ns"):
        if not isinstance(row[key], int) or row[key] <= 0:
            raise ValueError("Invalid duration")

def summarize(output):
    manifest = json.loads((output / "manifest.json").read_text())
    verification = json.loads((output / "verification.json").read_text())
    if not verification["equal"]:
        raise ValueError("Differential verification did not pass")
    if len(manifest["tests"]) != 4 or not all(row["passed"] for row in manifest["tests"]):
        raise ValueError("Baseline/candidate debug/release tests are incomplete")
    if manifest["tests_only"]:
        result = {"tests_only": True, "verification_cases": verification["case_count"], "results": []}
        save(output / "summary.json", result)
        return result
    references = json.loads((output / "case-reference.json").read_text())
    calibrations = json.loads((output / "calibrations.json").read_text())
    rows = [json.loads(line) for line in (output / "observations.jsonl").read_text().splitlines()]
    cases = manifest["cases"]
    expected = []
    for pair in range(manifest["pairs"]):
        traversal = cases if pair % 2 == 0 else list(reversed(cases))
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        expected.extend((pair, case["id"], variant) for case in traversal for variant in order)
    if [(row["pair"], row["case_id"], row["variant"]) for row in rows] != expected:
        raise ValueError("Missing, duplicate, or out-of-order observations")
    results = []
    for case in cases:
        name = case["id"]
        group = [row for row in rows if row["case_id"] == name]
        count = calibrations[name]["iterations"]
        for row in group:
            check(row, references[name], case, count)
        metrics = {}
        for key in ("elapsed_ns", "cpu_ns"):
            before = [next(row for row in group if row["pair"] == pair and row["variant"] == "baseline")[key]
                      / (count * case["pool_size"]) for pair in range(manifest["pairs"])]
            after = [next(row for row in group if row["pair"] == pair and row["variant"] == "candidate")[key]
                     / (count * case["pool_size"]) for pair in range(manifest["pairs"])]
            ratios = [c / b for b, c in zip(before, after)]
            metrics[key] = {"baseline_median_ns": statistics.median(before),
                            "candidate_median_ns": statistics.median(after),
                            "paired_ratios": ratios, "paired_median_ratio": statistics.median(ratios),
                            "paired_min_ratio": min(ratios), "paired_max_ratio": max(ratios),
                            "paired_median_reduction_percent": 100 * (1 - statistics.median(ratios))}
        results.append({**case, "iterations": count, "metrics": metrics})
    result = {"tests_only": False, "verification_cases": verification["case_count"],
              "pairs": manifest["pairs"], "observations": len(rows), "results": results}
    save(output / "summary.json", result)
    return result

def benchmark(args):
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Output directory must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    run = Run(output)
    swiftc = shutil.which(args.swiftc)
    if not swiftc:
        raise RuntimeError("A Swift 6.1+ toolchain is required")
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors"]
    if sys.platform == "darwin":
        flags += ["-target", platform.machine() + "-apple-macosx26.0", "-sdk",
                  run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")]
    baseline = HERE / "baseline" / "MediaMetadataHints.swift"
    baseline_manifest = json.loads((HERE / "baseline" / "manifest.json").read_text())
    raw = baseline.read_bytes()
    info = baseline_manifest["files"]["MediaMetadataHints.swift"]
    if (digest(raw) != info["sha256"]
            or hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest() != info["git_blob"]):
        raise ValueError("Frozen baseline source hash does not match its manifest")
    support = [ROOT / "Sources/IlliquidCore/MediaLibrary" / name
               for name in ("MediaNameRecognition.swift", "PlexMatchHints.swift")]
    paths = [ROOT / HINTS, baseline, *support, HERE / "Driver.swift", Path(__file__).resolve(),
             ROOT / "Tests/IlliquidCoreTests/PlexMatchHintsRegressionTests.swift",
             ROOT / "Tests/IlliquidCoreTests/MediaMetadataMergeTests.swift",
             ROOT / "Scripts/test-media-metadata-merge-regressions.sh"]
    sources = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in paths}
    for path in paths:
        target = output / "sources" / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    manifest = {"baseline": baseline_manifest, "compiler": run.command([swiftc, "--version"], "compiler"),
                "host": platform.platform(), "machine": platform.machine(), "flags": flags,
                "git_head": run.command(["git", "rev-parse", "HEAD"], "git-head"),
                "source_sha256": sources, "pairs": args.pairs, "target_ms": args.target_ms,
                "tests_only": args.tests_only, "tests": [], "cases": []}
    save(output / "manifest.json", manifest)
    variants = [("baseline", baseline), ("candidate", ROOT / HINTS)]
    for variant, source in variants:
        for config in ("debug", "release"):
            run.command(["bash", ROOT / "Scripts/test-media-metadata-merge-regressions.sh",
                         "--hints-source", source, "--configuration", config,
                         "--jobs", "2", "-Xswiftc", "-warnings-as-errors"],
                        f"tests-{variant}-{config}")
            manifest["tests"].append({"variant": variant, "configuration": config, "passed": True})
            save(output / "manifest.json", manifest)
            print(f"PASS {variant} {config} tests", flush=True)
    executables = {}
    for variant, source in variants:
        work = output / "build" / variant
        work.mkdir(parents=True)
        run.command([swiftc, *flags, "-parse-as-library", "-emit-library", "-static",
                     "-emit-module", "-enable-testing", "-module-name", "IlliquidCore",
                     "-emit-module-path", work / "IlliquidCore.swiftmodule", source, *support,
                     "-o", work / "libIlliquidCore.a"], "build-" + variant)
        executable = work / "Driver"
        run.command([swiftc, *flags, "-parse-as-library", HERE / "Driver.swift",
                     "-I", work, "-L", work, "-lIlliquidCore", "-o", executable],
                    "driver-" + variant)
        executables[variant] = executable
    manifest["binary_sha256"] = {
        variant: {"Driver": digest(executable.read_bytes()),
                  "libIlliquidCore.a": digest((executable.parent / "libIlliquidCore.a").read_bytes())}
        for variant, executable in executables.items()
    }
    save(output / "manifest.json", manifest)
    verified = {}
    for variant, _ in variants:
        receipt = run.command([executables[variant], "verify"], "verify-" + variant, True)
        if receipt["mode"] != "verify" or receipt["case_count"] != len(receipt["cases"]):
            raise ValueError("Incorrect verification case count")
        verified[variant] = receipt
        (output / ("verification-" + variant + ".json.gz")).write_bytes(
            gzip.compress(encode(receipt) + b"\n", compresslevel=9, mtime=0))
    if verified["baseline"] != verified["candidate"]:
        raise ValueError("Baseline and candidate complete metadata outputs differ")
    save(output / "verification.json", {"equal": True, "case_count": verified["baseline"]["case_count"],
                                       "receipt_sha256": digest(encode(verified["baseline"]))})
    print(f"PASS complete metadata parity: {verified['baseline']['case_count']} cases", flush=True)
    all_cases = run.command([executables["baseline"], "list"], "list-baseline", True)
    if all_cases != run.command([executables["candidate"], "list"], "list-candidate", True):
        raise ValueError("Benchmark inventories differ")
    cases = [case for case in all_cases if not args.case or case["id"] in args.case]
    if args.case and len(cases) != len(set(args.case)):
        raise ValueError("Unknown --case")
    manifest["cases"] = cases
    save(output / "manifest.json", manifest)
    if args.tests_only:
        summarize(output)
        return
    references, calibrations = {}, {}
    for case in cases:
        name = case["id"]
        reference = run.command([executables["baseline"], "measure", name, 1], "reference-" + name, True)
        check(reference, reference, case, 1)
        candidate = run.command([executables["candidate"], "measure", name, 1], "control-" + name, True)
        check(candidate, reference, case, 1)
        references[name] = reference
        count = 1
        samples = [reference]
        for attempt in range(8):
            row = samples[-1]
            if row["elapsed_ns"] >= args.target_ms * 1_000_000 * 0.8 or count == 1_000_000:
                break
            count = min(1_000_000, max(count + 1, math.ceil(
                count * args.target_ms * 1_000_000 / row["elapsed_ns"])))
            row = run.command([executables["baseline"], "measure", name, count],
                              f"calibrate-{name}-{attempt}", True)
            check(row, reference, case, count)
            samples.append(row)
        calibrations[name] = {"iterations": count, "samples": samples}
    save(output / "case-reference.json", references)
    save(output / "calibrations.json", calibrations)
    with (output / "observations.jsonl").open("w") as stream:
        for pair in range(args.pairs):
            traversal = cases if pair % 2 == 0 else list(reversed(cases))
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for case in traversal:
                name = case["id"]
                count = calibrations[name]["iterations"]
                for variant in order:
                    row = run.command([executables[variant], "measure", name, count],
                                      f"pair-{pair}-{variant}-{name}", True)
                    check(row, references[name], case, count)
                    stream.write(json.dumps({**row, "pair": pair, "variant": variant}, sort_keys=True) + "\n")
                    stream.flush()
            print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)
    result = summarize(output)
    for row in result["results"]:
        metric = row["metrics"]["elapsed_ns"]
        print(f"{row['id']}: {metric['baseline_median_ns']:.1f} -> {metric['candidate_median_ns']:.1f} ns; "
              f"paired reduction {metric['paired_median_reduction_percent']:.1f}%", flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["benchmark", "summarize"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--pairs", default=8, type=int)
    parser.add_argument("--target-ms", default=75, type=float)
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even --pairs >= 2 and positive finite --target-ms")
    if args.command == "summarize":
        summarize(args.output)
    else:
        benchmark(args)

if __name__ == "__main__":
    main()

