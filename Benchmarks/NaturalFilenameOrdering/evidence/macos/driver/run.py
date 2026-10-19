#!/usr/bin/env python3
"""Compare exact frozen/current filename-ordering sources in fresh processes.

Example: python3 Benchmarks/NaturalFilenameOrdering/run.py --output /tmp/filename-run
Use --swiftc /path/to/swiftc for a particular toolchain. --quick --samples 2 is
a smoke run, not the full matrix. Output must not already exist. Sources,
commands, errors, verification receipts and raw timings survive a failed run.
Only component costs are measured; there are no timing acceptance thresholds.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
REVISION = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCES = [
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
]


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")
        stream.flush()


def fingerprint(path: Path) -> dict:
    data = path.read_bytes()
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "git_blob": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
        "bytes": len(data),
    }


def checked_baseline() -> dict:
    manifest = json.loads((HERE / "baseline/manifest.json").read_text())
    expected_names = {Path(path).name for path in SOURCES}
    if manifest["revision"] != REVISION or set(manifest["files"]) != expected_names:
        raise RuntimeError("Unexpected retained baseline manifest")
    for relative in SOURCES:
        name = Path(relative).name
        expected = manifest["files"][name]
        actual = fingerprint(HERE / "baseline" / name)
        if expected["repository_path"] != relative or any(
            actual[key] != expected[key] for key in ["sha256", "git_blob"]
        ):
            raise RuntimeError(f"Retained baseline differs: {name}")
    return manifest


def stage(output: Path, baseline: dict) -> dict:
    manifest = {"baseline_revision": REVISION, "baseline_manifest": baseline, "files": {}}
    for variant in ["baseline", "candidate"]:
        destination = output / "sources" / variant
        destination.mkdir(parents=True)
        for relative in SOURCES + ["Benchmarks/NaturalFilenameOrdering/Harness.swift"]:
            name = Path(relative).name
            source = (HERE / "baseline" / name if variant == "baseline" and relative in SOURCES
                      else ROOT / relative)
            staged = destination / name
            # No import removal, source substitution, or injected implementation.
            staged.write_bytes(source.read_bytes())
            manifest["files"][str(staged.relative_to(output))] = {
                "repository_path": str(source.relative_to(ROOT)), **fingerprint(staged),
            }
    for name in ["run.py", "baseline/manifest.json"]:
        target = output / "driver" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((HERE / name).read_bytes())
        manifest["files"][str(target.relative_to(output))] = {
            "repository_path": str((HERE / name).relative_to(ROOT)), **fingerprint(target),
        }
    write_json(output / "sources.json", manifest)
    return manifest


def execute(command: list[str | Path], output: Path, *, tag: str,
            timeout: int = 600) -> str:
    args = [str(value) for value in command]
    record = {"tag": tag, "command": args, "cwd": str(ROOT),
              "started_utc": datetime.now(timezone.utc).isoformat()}
    started = time.monotonic()
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        record.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    except (OSError, subprocess.TimeoutExpired) as error:
        def decoded(value: str | bytes | None) -> str:
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        record.update(returncode=None, error=repr(error),
                      stdout=decoded(getattr(error, "stdout", None)),
                      stderr=decoded(getattr(error, "stderr", None)))
        raise
    finally:
        record["elapsed_seconds"] = time.monotonic() - started
        append_json(output / "commands.jsonl", record)
        (output / "logs" / f"{tag}.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see logs/{tag}.json")
    return result.stdout


def workload(operation: str, pattern: str, order: str, count: int, quick: bool) -> dict:
    if count <= 1:
        iterations = 20_000
    elif count <= 2:
        iterations = 4_000
    elif count <= 8:
        iterations = 1_000
    else:
        iterations = max(1, round(20_000 / (count * math.log2(count))))
    if quick:
        iterations = min(iterations, 20)
    return {"case": f"{operation}-{pattern}-{order}-{count}", "operation": operation,
            "pattern": pattern, "order": order, "count": count,
            "iterations": iterations, "warmup_iterations": min(iterations, 3)}


def matrix(quick: bool) -> list[dict]:
    specifications = []
    if quick:
        specifications += [("sort", "natural", "shuffled", 100),
                           ("playlist", "natural", "reversed", 100),
                           ("sort", "unicode_long", "shuffled", 100),
                           ("playlist", "ties", "shuffled", 100)]
    else:
        for operation in ["sort", "playlist"]:
            for count in [100, 1_000, 10_000]:
                specifications += [(operation, "natural", order, count)
                                   for order in ["shuffled", "sorted", "reversed"]]
                specifications += [(operation, pattern, "shuffled", count)
                                   for pattern in ["unicode_long", "ties"]]
    for operation in ["sort", "subtitle_item"]:
        specifications += [(operation, "subtitles", "shuffled", count) for count in [0, 1, 2, 8]]
    return [workload(*specification, quick) for specification in specifications]


def parse_receipt(text: str) -> dict:
    lines = text.strip().splitlines()
    if len(lines) != 1:
        raise RuntimeError("Driver did not emit exactly one JSON receipt")
    value = json.loads(lines[0])
    if not isinstance(value, dict):
        raise RuntimeError("Driver receipt is not an object")
    return value


def distribution(values: list[float]) -> dict:
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}


def summarize(rows: list[dict], cases: list[dict], samples: int) -> list[dict]:
    groups = defaultdict(dict)
    for row in rows:
        identity = (row["sample"], row["variant"])
        if identity in groups[row["case"]]:
            raise RuntimeError("Duplicate raw observation")
        groups[row["case"]][identity] = row
    if set(groups) != {case["case"] for case in cases}:
        raise RuntimeError("Incomplete case inventory")
    summary = []
    for case in cases:
        observed = groups[case["case"]]
        if set(observed) != {(sample, variant) for sample in range(samples)
                             for variant in ["baseline", "candidate"]}:
            raise RuntimeError("Incomplete paired observations")
        costs = {variant: [observed[sample, variant]["elapsed_ns"] / case["iterations"]
                           for sample in range(samples)] for variant in ["baseline", "candidate"]}
        ratios = [before / after for before, after in zip(costs["baseline"], costs["candidate"])]
        differences = [before - after for before, after in zip(costs["baseline"], costs["candidate"])]
        improvements = [100 * (1 - after / before)
                        for before, after in zip(costs["baseline"], costs["candidate"])]
        summary.append({**case, "pairs": samples,
                        "baseline_ns_per_operation": distribution(costs["baseline"]),
                        "candidate_ns_per_operation": distribution(costs["candidate"]),
                        "paired_speedup": distribution(ratios),
                        "paired_saved_ns_per_operation": distribution(differences),
                        "paired_reduction_percent": distribution(improvements),
                        "receipt": observed[0, "baseline"]["receipt"]})
    return summary


def verify_sources(output: Path, manifest: dict, binaries: dict) -> None:
    for relative, expected in manifest["files"].items():
        if fingerprint(output / relative)["sha256"] != expected["sha256"]:
            raise RuntimeError(f"Staged source changed during execution: {relative}")
    for relative, expected in binaries.items():
        if fingerprint(output / relative)["sha256"] != expected["sha256"]:
            raise RuntimeError(f"Executable changed during execution: {relative}")


def run(args: argparse.Namespace, output: Path) -> None:
    (output / "logs").mkdir()
    baseline = checked_baseline()
    manifest = stage(output, baseline)
    cases = matrix(args.quick)
    write_json(output / "cases.json", cases)
    compiler = shutil.which(args.swiftc) or str(Path(args.swiftc).expanduser().resolve())
    environment = {
        "platform": platform.platform(), "machine": platform.machine(),
        "processor": platform.processor(), "cpu_count": os.cpu_count(),
        "python": sys.version, "swiftc": compiler,
        "locale_environment": {key: os.environ.get(key) for key in ["LANG", "LC_ALL", "LC_COLLATE", "TZ"]},
        "invocation": sys.argv, "samples": args.samples, "quick": args.quick,
        "started_utc": datetime.now(timezone.utc).isoformat(),
    }
    write_json(output / "environment.json", environment)
    environment["compiler_version"] = execute([compiler, "--version"], output, tag="compiler-version")
    environment["checkout_head"] = execute(["git", "rev-parse", "HEAD"], output, tag="checkout-head").strip()
    environment["source_changes"] = execute(["git", "status", "--short", "--", *SOURCES],
                                               output, tag="source-changes")
    write_json(output / "environment.json", environment)

    binaries = {}
    verification = {}
    for variant in ["baseline", "candidate"]:
        source_directory = output / "sources" / variant
        binary = output / "bin" / variant
        binary.parent.mkdir(exist_ok=True)
        cache = output / "module-cache" / variant
        cache.mkdir(parents=True)
        command = [compiler, "-O", "-whole-module-optimization", "-swift-version", "6",
                   "-parse-as-library", "-module-cache-path", cache,
                   *[source_directory / Path(path).name for path in SOURCES],
                   source_directory / "Harness.swift", "-o", binary]
        execute(command, output, tag=f"build-{variant}")
        binaries[str(binary.relative_to(output))] = fingerprint(binary)
        write_json(output / "binaries.json", binaries)
        verification[variant] = parse_receipt(execute([binary, "--verify-only"], output,
                                                      tag=f"verify-{variant}"))
        if verification[variant].get("verification") is not True:
            raise RuntimeError(f"Verification did not pass for {variant}")
        write_json(output / "verification.json", verification)
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Baseline/candidate representation or item-payload receipts differ")
    verify_sources(output, manifest, binaries)

    rows = []
    expected_receipts = {}
    for sample in range(args.samples):
        order = ["baseline", "candidate"] if sample % 2 == 0 else ["candidate", "baseline"]
        for case in cases:
            pair = []
            for position, variant in enumerate(order):
                binary = output / "bin" / variant
                command = [binary, case["operation"], case["pattern"], case["order"],
                           str(case["count"]), str(case["iterations"]), str(case["warmup_iterations"])]
                tag = f"timing-{sample:02d}-{case['case']}-{position}-{variant}"
                receipt = parse_receipt(execute(command, output, tag=tag))
                for key in ["operation", "pattern", "order", "count", "iterations", "warmup_iterations"]:
                    if receipt.get(key) != case[key]:
                        raise RuntimeError(f"Driver returned a mismatched {key}")
                if receipt.get("full_output_verified") is not True or not (
                    isinstance(receipt.get("elapsed_ns"), (int, float))
                    and math.isfinite(receipt["elapsed_ns"]) and receipt["elapsed_ns"] > 0
                ):
                    raise RuntimeError("Invalid timed verification or elapsed time")
                row = {**receipt, "case": case["case"], "sample": sample,
                       "variant": variant, "position_in_pair": position, "pair_order": order}
                append_json(output / "observations.jsonl", row)
                rows.append(row)
                pair.append(row)
            comparable = lambda row: (row["receipt"], row["observed"], row["locale"])
            if comparable(pair[0]) != comparable(pair[1]):
                raise RuntimeError(f"Paired output mismatch: {case['case']}")
            value = comparable(pair[0])
            if case["case"] in expected_receipts and expected_receipts[case["case"]] != value:
                raise RuntimeError(f"Output changed between processes: {case['case']}")
            expected_receipts[case["case"]] = value
    verify_sources(output, manifest, binaries)
    summary = {
        "status": "complete", "timed_observations": len(rows), "cases": summarize(rows, cases, args.samples),
        "method": "Fresh process per observation; paired AB/BA order alternates by sample; no discarded completed rows.",
        "scope": "Optimized component operations with a shared O(1) result observer; fixture preparation, full verification and hashing excluded.",
        "limitations": "Host/locale-specific Foundation costs; no full-player, energy, filesystem-I/O or macOS-UI claim. No timing CI threshold.",
        "quick": args.quick,
    }
    write_json(output / "summary.json", summary)
    print(f"Completed {len(rows)} timed observations across {len(cases)} cases; evidence: {output}")
    for case in summary["cases"]:
        before = case["baseline_ns_per_operation"]["median"] / 1_000_000
        after = case["candidate_ns_per_operation"]["median"] / 1_000_000
        reduction = case["paired_reduction_percent"]["median"]
        print(f"{case['case']}: {before:.6f} ms -> {after:.6f} ms; "
              f"paired median reduction {reduction:.1f}%")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--samples", type=int, default=6, help="even number of paired samples (default: 6)")
    parser.add_argument("--output", type=Path, required=True, help="new directory; existing output is never overwritten")
    parser.add_argument("--quick", action="store_true", help="small smoke matrix and short batches")
    args = parser.parse_args()
    if args.samples < 2 or args.samples > 100 or args.samples % 2:
        parser.error("--samples must be an even number from 2 to 100")
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error("--output must be a new directory; previous evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=False)
    try:
        run(args, output)
    except Exception as error:
        write_json(output / "failure.json", {"status": "failed", "error": repr(error),
                                             "traceback": traceback.format_exc()})
        print(f"Benchmark failed: {error}\nEvidence retained: {output}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
