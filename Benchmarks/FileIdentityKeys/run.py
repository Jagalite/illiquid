#!/usr/bin/env python3
"""Measure exact production persistence keys and warm playlist lookups offline."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import random
import shlex
import shutil
import statistics
import subprocess
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MAX_ROUNDS = 20_000_000
MODULE_FLAGS = ["-swift-version", "6", "-O", "-whole-module-optimization", "-parse-as-library"]
DRIVER_FLAGS = ["-swift-version", "6", "-O", "-parse-as-library"]


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_hashes(data: bytes) -> dict[str, str]:
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "git_blob_sha1": hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest(),
    }


def host_cpu() -> str:
    if sys.platform == "darwin":
        return subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    path = Path("/proc/cpuinfo")
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    return platform.processor() or platform.machine()


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.commands: list[dict] = []
        (output / "logs").mkdir()

    def call(self, arguments: list[str], label: str, *, timeout: int = 240) -> str:
        identifier = len(self.commands)
        stem = f"{identifier:04d}-{label}"
        record = {
            "id": identifier, "label": label, "arguments": arguments, "cwd": str(ROOT),
            "started_utc": now(), "stdout": f"logs/{stem}.stdout.txt", "stderr": f"logs/{stem}.stderr.txt",
        }
        self.commands.append(record)
        write_json(self.output / "commands.json", self.commands)
        # Retain stdout/stderr even when a command fails. No shell interpolation
        # or network access is involved in building or running the benchmark.
        with (self.output / record["stdout"]).open("w") as stdout, (self.output / record["stderr"]).open("w") as stderr:
            result = subprocess.run(arguments, cwd=ROOT, text=True, stdout=stdout, stderr=stderr, timeout=timeout)
        record.update(returncode=result.returncode, completed_utc=now())
        write_json(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"{label} failed with exit {result.returncode}; see {record['stderr']}")
        return (self.output / record["stdout"]).read_text()


def metric(pairs: list[dict], field: str, seed: int) -> dict:
    before = [pair["baseline"][field] / pair["baseline"]["operations"] for pair in pairs]
    after = [pair["candidate"][field] / pair["candidate"]["operations"] for pair in pairs]
    ratios = [right / left for left, right in zip(before, after)]
    generator = random.Random(seed)
    bootstraps = sorted(statistics.median(generator.choices(ratios, k=len(ratios))) for _ in range(5000))
    return {
        "baseline_median_ns_per_operation": statistics.median(before),
        "candidate_median_ns_per_operation": statistics.median(after),
        "baseline_range_ns_per_operation": [min(before), max(before)],
        "candidate_range_ns_per_operation": [min(after), max(after)],
        "median_paired_change_percent": (statistics.median(ratios) - 1) * 100,
        "median_paired_delta_ns_per_operation": statistics.median(b - a for a, b in zip(before, after)),
        "paired_change_percent_range": [(min(ratios) - 1) * 100, (max(ratios) - 1) * 100],
        "median_change_bootstrap_95_percent": [
            (bootstraps[124] - 1) * 100, (bootstraps[4874] - 1) * 100,
        ],
        "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
        "pair_count": len(pairs),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--seed", type=int, default=20261028)
    parser.add_argument("--case", action="append", dest="cases")
    parser.add_argument("--parity-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two for balanced AB/BA measurements")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    swiftc = shutil.which(args.swiftc)
    if swiftc is None:
        parser.error(f"Swift compiler not found: {args.swiftc}")
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must be a new directory; existing observations are never overwritten")
    output.mkdir(parents=True)
    runner = Runner(output)
    manifest = {
        "schema_version": 1, "started_utc": now(), "status": "running",
        "environment": {
            "platform": platform.platform(), "machine": platform.machine(), "cpu": host_cpu(),
            "logical_cpus": os.cpu_count(), "python": platform.python_version(),
            "swiftc_invocation_path": swiftc, "swiftc_resolved_path": str(Path(swiftc).resolve()),
            "variables": {name: os.environ.get(name) for name in [
                "LANG", "LC_ALL", "LC_COLLATE", "SWIFT_DETERMINISTIC_HASHING", "SDKROOT", "DEVELOPER_DIR",
            ]},
        },
        "method": {
            "pairs": args.pairs, "baseline_target_cpu_ms": args.target_ms, "seed": args.seed,
            "module_flags": MODULE_FLAGS, "driver_flags": DRIVER_FLAGS,
            "boundary": "Frozen baseline and live candidate are separate optimized Swift modules/objects. The driver is compiled separately with no explicit CMO flag; Swift default CMO remains enabled. Production methods are not @inlinable. Inspect the executable to confirm retained per-iteration work when changing toolchains.",
            "scope": "Warm in-memory persistence keys and actual FolderPlaylist.index(of:) calls. No filesystem scan, whole-player CPU, frame-rate, or visible UI latency claim.",
            "timers": "One DispatchTime wall interval inside one CLOCK_PROCESS_CPUTIME_ID CPU interval per process. CPU includes wall-clock sampling and all process threads.",
            "outside_timers": "Fixture creation, actual playlist construction/sorting, full receipts before and after, two warmup rounds, and validation.",
            "included_work": "Production call plus driver loop/closure and checksum consumption; identical caller structure for both variants.",
            "autorelease_scope": "On macOS, one autorelease pool covers the complete measured batch and drains inside both timers. Warmup uses a separate untimed pool; there is no pool per key/lookup.",
            "sampling": "Fresh processes in adjacent AB/BA pairs; alternating order gives equal baseline-first/candidate-first counts. Case order is seeded and shuffled for each pair.",
            "calibration": "Retained baseline calibration reaches at least 10 ms process CPU, then selects equal rounds for both variants targeting the requested baseline CPU duration. Calibration is not included in fixed-work summaries.",
            "statistics": "All fixed-work observations retained; median paired change and absolute per-operation times, ranges, faster-pair counts, and seeded 5000-resample percentile bootstrap interval. No outlier deletion.",
            "limitations": "Process CPU removes descheduled waiting but not frequency/cache/host-load effects. Bootstrap intervals describe these samples, not every device or workload.",
        },
        "source_hashes": {}, "binary_hashes": {},
    }
    write_json(output / "manifest.json", manifest)
    try:
        manifest["environment"]["swift_version"] = runner.call([swiftc, "--version"], "swift-version").strip()
        manifest["environment"]["swift_target_info"] = json.loads(runner.call([swiftc, "-print-target-info"], "swift-target-info"))
        if sys.platform == "darwin":
            for label, arguments in [
                ("macos-version", ["sw_vers"]), ("sdk-path", ["xcrun", "--show-sdk-path"]),
                ("sdk-version", ["xcrun", "--show-sdk-version"]),
            ]:
                manifest["environment"][label] = runner.call(arguments, label).strip()
        try:
            manifest["checkout"] = {
                "head": runner.call(["git", "rev-parse", "HEAD"], "git-head").strip(),
                "relevant_status": runner.call(["git", "status", "--short", "--", "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift", str(HERE.relative_to(ROOT))], "git-status").strip(),
            }
        except (FileNotFoundError, RuntimeError):
            manifest["checkout"] = {"head": None, "note": "No usable Git metadata; frozen source hashes remain available."}

        frozen = json.loads((HERE / "baseline/manifest.json").read_text())
        manifest["baseline"] = frozen
        (output / "sources").mkdir()
        for name in ["Driver.swift", "Differential.swift", "run.py"]:
            shutil.copyfile(HERE / name, output / "sources" / name)
            manifest["source_hashes"][name] = source_hashes((HERE / name).read_bytes())
        source_paths = {}
        for variant in ["baseline", "candidate"]:
            folder = output / "sources" / variant
            folder.mkdir()
            source_paths[variant] = []
            manifest["source_hashes"][variant] = {}
            for name, expected in frozen["files"].items():
                baseline_bytes = (HERE / "baseline" / name).read_bytes()
                if source_hashes(baseline_bytes) != {key: expected[key] for key in ["sha256", "git_blob_sha1"]}:
                    raise RuntimeError(f"Frozen baseline hash mismatch for {name}")
                data = baseline_bytes if variant == "baseline" else (ROOT / expected["source"]).read_bytes()
                if variant == "candidate" and name != "NormalizedFileURL.swift" and data != baseline_bytes:
                    raise RuntimeError(f"Support source {name} changed; review the benchmark boundary before rebasing its baseline")
                target = folder / name
                target.write_bytes(data)
                source_paths[variant].append(str(target))
                manifest["source_hashes"][variant][name] = source_hashes(data)

        build = output / "build"
        modules = build / "modules"
        modules.mkdir(parents=True)
        cache = build / "module-cache"
        cache.mkdir()
        objects = []
        frontends = set()
        print("Compiling separate baseline and candidate modules", flush=True)
        for variant, module in [("baseline", "URLBaseline"), ("candidate", "URLCandidate")]:
            object_file = build / f"{module}.o"
            arguments = [swiftc, *MODULE_FLAGS, "-module-cache-path", str(cache),
                         "-emit-module", "-emit-object", "-module-name", module,
                         "-emit-module-path", str(modules / f"{module}.swiftmodule"),
                         *source_paths[variant], "-o", str(object_file)]
            runner.call([*arguments, "-###"], f"{variant}-compiler-plan")
            for stream in ["stdout", "stderr"]:
                plan = (output / runner.commands[-1][stream]).read_text()
                for line in plan.splitlines():
                    try:
                        words = shlex.split(line)
                    except ValueError:
                        continue
                    if words and Path(words[0]).name == "swift-frontend":
                        frontends.add(str(Path(words[0]).resolve()))
            runner.call(arguments, f"build-{variant}")
            objects.append(str(object_file))
            manifest["binary_hashes"][object_file.name] = sha256(object_file)
        manifest["environment"]["actual_swift_frontends"] = [
            {"path": path, "sha256": sha256(Path(path))} for path in sorted(frontends)
        ]
        if not frontends:
            raise RuntimeError("Compiler dry-run did not identify the actual swift-frontend; inspect compiler-plan logs")
        programs = {}
        for name in ["Driver", "Differential"]:
            program = build / name.lower()
            runner.call([swiftc, *DRIVER_FLAGS, "-module-cache-path", str(cache), "-I", str(modules),
                         str(output / "sources" / f"{name}.swift"), *objects, "-o", str(program)], f"build-{name.lower()}")
            programs[name] = program
            manifest["binary_hashes"][program.name] = sha256(program)
        write_json(output / "manifest.json", manifest)

        differential = json.loads(runner.call([str(programs["Differential"])], "differential"))
        write_json(output / "differential.json", differential)
        if differential["mismatches"] != 0:
            raise RuntimeError("Exact UTF-8 differential comparison failed")
        available = json.loads(runner.call([str(programs["Driver"]), "--list"], "case-list"))
        selected = args.cases or available
        if len(set(selected)) != len(selected) or any(case not in available for case in selected):
            raise ValueError("--case must be distinct values from " + ", ".join(available))
        receipts = {}
        for case in selected:
            receipt = json.loads(runner.call([str(programs["Driver"]), "--receipt", case], f"receipt-{case}"))
            receipts[case] = receipt
            write_json(output / "receipts.json", receipts)
            if receipt["baseline"] != receipt["candidate"]:
                raise RuntimeError(f"Complete key/item/index receipt mismatch for {case}")
        manifest["method"]["cases"] = selected
        print(f"Exact differential: {differential['cases']} cases; {len(receipts)} full workload receipts match", flush=True)
        if args.parity_only:
            manifest.update(status="parity-only", completed_utc=now())
            write_json(output / "summary.json", {"complete": True, "parity_only": True, "differential": differential, "cases": selected})
            write_json(output / "manifest.json", manifest)
            return

        def probe(variant: str, case: str, rounds: int, label: str) -> dict:
            result = json.loads(runner.call([str(programs["Driver"]), variant, case, str(rounds)], label))
            if (result["variant"] != variant or result["case"] != case or result["rounds"] != rounds
                    or result["operationsPerRound"] <= 0
                    or result["operations"] != rounds * result["operationsPerRound"]
                    or result["wallNanoseconds"] <= 0 or result["cpuNanoseconds"] <= 0
                    or result["checksum"] != result["expectedChecksumPerRound"] * rounds):
                raise RuntimeError(f"Invalid retained observation for {variant}/{case}")
            return result

        calibrations = {}
        rounds_by_case = {}
        for case in selected:
            rounds = 1
            samples = []
            calibrations[case] = {"samples": samples, "included_in_summary": False}
            for attempt in range(8):
                result = probe("baseline", case, rounds, f"calibrate-{case}-{attempt}")
                samples.append(result)
                write_json(output / "calibrations.json", calibrations)
                if result["cpuNanoseconds"] >= 10_000_000 or rounds == MAX_ROUNDS:
                    break
                rounds = min(MAX_ROUNDS, max(rounds + 1, math.ceil(rounds * 10_000_000 / result["cpuNanoseconds"])))
            measured = samples[-1]
            selected_rounds = min(MAX_ROUNDS, max(1, math.ceil(measured["rounds"] * args.target_ms * 1_000_000 / measured["cpuNanoseconds"])))
            rounds_by_case[case] = selected_rounds
            calibrations[case]["selected_rounds"] = selected_rounds
            calibrations[case]["at_round_cap"] = selected_rounds == MAX_ROUNDS
            write_json(output / "calibrations.json", calibrations)

        pairs = {case: [] for case in selected}
        schedule = []
        rng = random.Random(args.seed)
        with (output / "observations.jsonl").open("w") as observations:
            for pair_index in range(args.pairs):
                shuffled = list(selected)
                rng.shuffle(shuffled)
                order = ["baseline", "candidate"] if pair_index % 2 == 0 else ["candidate", "baseline"]
                schedule.append({"pair": pair_index, "cases": shuffled, "variants": order})
                write_json(output / "schedule.json", schedule)
                for case in shuffled:
                    pair = {}
                    for position, variant in enumerate(order):
                        result = probe(variant, case, rounds_by_case[case], f"measure-{pair_index:02d}-{case}-{variant}")
                        row = {**result, "pair": pair_index, "order": order, "position": position,
                               "command_id": runner.commands[-1]["id"]}
                        observations.write(json.dumps(row, sort_keys=True) + "\n")
                        observations.flush()
                        pair[variant] = result
                    if (pair["baseline"]["checksum"] != pair["candidate"]["checksum"]
                            or pair["baseline"]["operations"] != pair["candidate"]["operations"]):
                        raise RuntimeError(f"Paired workload mismatch for {case}/{pair_index}")
                    pairs[case].append(pair)
                print(f"Completed paired round {pair_index + 1}/{args.pairs}", flush=True)

        summary = {
            "schema_version": 1, "complete": True, "pairs": args.pairs,
            "baseline_revision": frozen["revision"], "baseline_target_cpu_ms": args.target_ms,
            "differential": differential, "cases": {},
        }
        for index, case in enumerate(selected):
            series = pairs[case]
            summary["cases"][case] = {
                "unit": series[0]["baseline"]["unit"], "rounds": rounds_by_case[case],
                "operations_per_round": series[0]["baseline"]["operationsPerRound"],
                "cpu": metric(series, "cpuNanoseconds", args.seed + index),
                "wall": metric(series, "wallNanoseconds", args.seed + index),
            }
        summary["screening"] = {
            "threshold_percent": 5,
            "median_cpu_improvements_over_threshold": [case for case in selected if summary["cases"][case]["cpu"]["median_paired_change_percent"] < -5],
            "median_cpu_regressions_over_threshold": [case for case in selected if summary["cases"][case]["cpu"]["median_paired_change_percent"] > 5],
            "note": "Descriptive screening only; review absolute costs, paired distributions, native correctness, and workload relevance before claiming success.",
        }
        for name, expected in frozen["files"].items():
            if source_hashes((ROOT / expected["source"]).read_bytes()) != manifest["source_hashes"]["candidate"][name]:
                raise RuntimeError(f"Candidate source changed during the campaign: {name}")
        write_json(output / "summary.json", summary)
        manifest.update(status="complete", completed_utc=now())
        write_json(output / "manifest.json", manifest)
        for case, values in summary["cases"].items():
            cpu = values["cpu"]
            print(f"{case}: CPU {cpu['median_paired_change_percent']:+.2f}%, "
                  f"{cpu['baseline_median_ns_per_operation']:.1f} -> {cpu['candidate_median_ns_per_operation']:.1f} ns/{values['unit']}")
    except BaseException as error:
        manifest.update(status="failed", completed_utc=now())
        write_json(output / "manifest.json", manifest)
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error), "traceback": traceback.format_exc()})
        raise


if __name__ == "__main__":
    main()
