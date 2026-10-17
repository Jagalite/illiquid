#!/usr/bin/env python3
"""Compare exact full-converter output and benchmark separate release executables.

Requires Python 3.10+ and Swift 6.1+; no packages or network access are used.
Run from any directory, for example:
  python3 Benchmarks/ExternalSubtitleConversion/run.py --output /tmp/subtitle-run
"""

from __future__ import annotations

import argparse
import base64
from collections import Counter
from datetime import datetime, timezone
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = Path("Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def distribution(values: list[float]) -> dict:
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def finalize_cohort(output: Path, measurements: list[dict], commands: list[dict],
                    selected: list[str], rounds: int) -> dict:
    """Replace streaming checkpoints with complete, validated atomic receipts."""
    for filename, records in (("measurements.jsonl", measurements), ("commands.jsonl", commands)):
        path = output / filename
        temporary = path.with_suffix(".jsonl.tmp")
        with temporary.open("w", encoding="utf-8") as stream:
            stream.write("".join(json.dumps(record, sort_keys=True) + "\n" for record in records))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        restored = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        if restored != records:
            raise RuntimeError(f"Final {filename} does not match its complete in-memory receipts")

    expected = []
    for round_index in range(rounds):
        order = ["baseline", "candidate"] if round_index % 2 == 0 else ["candidate", "baseline"]
        offset = round_index % len(selected)
        for case in selected[offset:] + selected[:offset]:
            expected.extend((case, round_index + 1, variant, position + 1, order)
                            for position, variant in enumerate(order))
    actual = [(row["case"], row["round"], row["variant"], row["position"], row["order"])
              for row in measurements]
    if actual != expected:
        raise RuntimeError("Final cohort has missing, duplicate, or out-of-order case/round/variant receipts")
    timing_commands = [command for command in commands if command["argv"][1:2] == ["time"]]
    if len(timing_commands) != len(selected) + len(expected):
        raise RuntimeError("Final command receipts do not contain every calibration and measurement")
    for command, row in zip(timing_commands[len(selected):], measurements):
        expected_argv = ["time", row["case"], str(row["iterations"]), str(row["warmup_iterations"])]
        raw = json.loads(command["stdout"])
        if (command["argv"][1:] != expected_argv or Path(command["argv"][0]).name != row["variant"]
                or any(row.get(key) != value for key, value in raw.items())):
            raise RuntimeError("Final measurement does not match its command receipt")
    for left, right in zip(measurements[::2], measurements[1::2]):
        if any(left[key] != right[key] for key in ("iterations", "warmup_iterations", "input_bytes", "output_sink")):
            raise RuntimeError("Final paired measurement inputs or output sinks differ")
    return {"complete_cohort": True, "measurements": len(measurements), "commands": len(commands),
            "measurements_sha256": sha256(output / "measurements.jsonl"),
            "commands_sha256": sha256(output / "commands.jsonl")}


def verify_receipts(output: Path, paths: dict[str, Path]) -> dict:
    """Compare complete successful UTF-8 bytes and error labels, outside timers."""
    data = {label: path.read_bytes() for label, path in paths.items()}
    records = {label: [json.loads(line) for line in raw.splitlines()] for label, raw in data.items()}
    # JSON is emitted with sorted keys, and all input/output text is base64.
    exact = data["baseline"] == data["candidate"]
    result = {"exact_match": exact, "fixtures": len(records["baseline"]),
              "receipt_sha256": {label: hashlib.sha256(raw).hexdigest() for label, raw in data.items()}}
    for label, raw in data.items():
        (output / f"verification-{label}.jsonl.gz").write_bytes(gzip.compress(raw, mtime=0))
    if not exact:
        for index in range(max(len(records["baseline"]), len(records["candidate"]))):
            left = records["baseline"][index] if index < len(records["baseline"]) else None
            right = records["candidate"][index] if index < len(records["candidate"]) else None
            if left != right:
                result["first_mismatch"] = {"index": index, "baseline": left, "candidate": right}
                break
    outcomes = []
    errors: Counter[str] = Counter()
    for receipt in records["baseline"]:
        source = base64.b64decode(receipt["input_utf8_base64"], validate=True)
        outcome = {"name": receipt["name"], "format": receipt["format"],
                   "input_bytes": len(source), "input_sha256": hashlib.sha256(source).hexdigest(),
                   "error": receipt["error"]}
        if receipt["error"] is None:
            converted = base64.b64decode(receipt["output_utf8_base64"], validate=True)
            outcome.update(output_bytes=len(converted), output_sha256=hashlib.sha256(converted).hexdigest())
        else:
            errors[receipt["error"]] += 1
        outcomes.append(outcome)
    result.update(successful_fixtures=len(outcomes) - sum(errors.values()),
                  error_counts=dict(errors), outcomes=outcomes)
    write_json(output / "verification.json", result)
    if not exact:
        raise RuntimeError("Full output/error verification failed; see verification.json")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new or empty evidence directory")
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--samples", "--rounds", dest="rounds", type=int, default=6,
                        help="positive even sample count per variant, in balanced AB/BA pairs")
    parser.add_argument("--target-ms", type=float, default=200, help="baseline-calibrated time per measured loop")
    parser.add_argument("--cases", default="all", help="comma-separated workload names, or all")
    parser.add_argument("--cpu", type=int, help="optional allowed Linux CPU for calibration and timing")
    parser.add_argument("--verify-only", action="store_true", help="build and verify without timing")
    parser.add_argument("--list-cases", action="store_true", help="build, print workloads, and exit")
    args = parser.parse_args()
    if args.rounds <= 0 or args.rounds % 2:
        parser.error("--rounds must be positive and even")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    if args.cpu is not None and (not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0)):
        parser.error("--cpu requires Linux affinity support and an allowed CPU")
    output = args.output.expanduser().resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("--output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    sources = output / "sources"
    sources.mkdir()

    baseline = json.loads((HERE / "baseline/manifest.json").read_text(encoding="utf-8"))
    original = HERE / "baseline/ExternalTextSubtitleConverter.swift"
    if sha256(original) != baseline["sha256"]:
        raise RuntimeError("Frozen baseline SHA-256 does not match its manifest")
    original_bytes = original.read_bytes()
    blob_sha = hashlib.sha1(f"blob {len(original_bytes)}\0".encode() + original_bytes).hexdigest()
    if "git_blob_sha" in baseline and blob_sha != baseline["git_blob_sha"]:
        raise RuntimeError("Frozen baseline Git blob does not match its manifest")
    source_inputs = {"baseline.swift": original, "candidate.swift": ROOT / SOURCE,
                     "Driver.swift": HERE / "Driver.swift", "run.py": HERE / "run.py",
                     "baseline-manifest.json": HERE / "baseline/manifest.json"}
    for name, path in source_inputs.items():
        shutil.copyfile(path, sources / name)

    with tempfile.TemporaryDirectory(prefix="illiquid-subtitle-") as temporary:
        build = Path(temporary)
        environment = dict(os.environ)
        environment["CLANG_MODULE_CACHE_PATH"] = str(build / "clang-module-cache")
        command_receipts = []

        def run(command: list[str], *, stdout: Path | None = None, cpu: int | None = None) -> str:
            started = datetime.now(timezone.utc).isoformat()
            start = time.monotonic()
            before_exec = None if cpu is None else lambda: os.sched_setaffinity(0, {cpu})
            if stdout is None:
                process = subprocess.run(command, cwd=ROOT, env=environment, text=True,
                                         capture_output=True, preexec_fn=before_exec)
                captured = process.stdout
            else:
                with stdout.open("w", encoding="utf-8") as stream:
                    process = subprocess.run(command, cwd=ROOT, env=environment, text=True,
                                             stdout=stream, stderr=subprocess.PIPE, preexec_fn=before_exec)
                captured = ""
            command_receipt = {"argv": command, "cwd": str(ROOT), "started_at": started,
                               "elapsed_seconds": time.monotonic() - start, "cpu_affinity": cpu,
                               "returncode": process.returncode, "stderr": process.stderr,
                               "stdout": captured, "stdout_file": str(stdout) if stdout else None}
            command_receipts.append(command_receipt)
            with (output / "commands.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(command_receipt, sort_keys=True) + "\n")
            if process.returncode:
                raise RuntimeError(f"Command failed: {command!r}\n{process.stderr}\n{captured}")
            return captured

        # Preserve the swiftc basename: it can be a symlink to the Swift driver.
        swiftc = os.path.abspath(shutil.which(args.swiftc) or os.path.expanduser(args.swiftc))
        version = run([swiftc, "--version"]).strip()
        version_match = re.search(r"Swift version (\d+)\.(\d+)", version)
        if not version_match or tuple(map(int, version_match.groups())) < (6, 1):
            raise RuntimeError(f"Swift 6.1+ is required; found {version}")
        target_info = json.loads(run([swiftc, "-print-target-info"]))
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-module-cache-path", str(build / "swift-module-cache")]
        cpu_model = platform.processor()
        if Path("/proc/cpuinfo").exists():
            cpu_model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                              if line.startswith("model name")), cpu_model)
        elif platform.system() == "Darwin":
            cpu_model = run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        manifest = {
            "baseline": baseline,
            "sources": {name: {"original_path": str(path.relative_to(ROOT)), "sha256": sha256(sources / name)}
                        for name, path in source_inputs.items()},
            "compiler": {"path": swiftc, "version": version, "target_info": target_info, "flags": flags},
            "environment": {"platform": platform.platform(), "machine": platform.machine(),
                            "python": platform.python_version(), "cpu_model": cpu_model,
                            "logical_cpu_count": os.cpu_count(),
                            "allowed_cpus": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
                            "runtime_overrides": {key: environment[key] for key in (
                                "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "SDKROOT", "DEVELOPER_DIR",
                                "MACOSX_DEPLOYMENT_TARGET", "LANG", "LC_ALL") if key in environment},
                            "module_cache_environment": {"CLANG_MODULE_CACHE_PATH": environment["CLANG_MODULE_CACHE_PATH"]}},
            "git_head": run(["git", "rev-parse", "HEAD"]).strip(),
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
            "measurement_scope": "Full convert() plus a no-inline UTF-8 count/first/last-byte sink and returned-string lifetime. Input generation, process startup, warmup, verification, and JSON output are outside both clocks.",
            "clocks": {"wall": "DispatchTime.uptimeNanoseconds", "cpu": "clock_gettime(CLOCK_PROCESS_CPUTIME_ID)"},
            "limitations": "Synthetic full-converter workloads; no file I/O, decoding, renderer, playback, allocation, or peak-memory measurements. Platform-specific Foundation costs can differ.",
        }
        write_json(output / "manifest.json", manifest)
        executables = {}
        for label in ("baseline", "candidate"):
            executable = build / label
            run([swiftc, *flags, str(sources / f"{label}.swift"), str(sources / "Driver.swift"), "-o", str(executable)])
            executables[label] = executable
        manifest["binary_sha256"] = {label: sha256(path) for label, path in executables.items()}
        write_json(output / "manifest.json", manifest)

        cases = json.loads(run([str(executables["baseline"]), "cases"]))
        if cases != json.loads(run([str(executables["candidate"]), "cases"])):
            raise RuntimeError("Executable workload definitions differ")
        write_json(output / "cases.json", cases)
        available = {case["name"] for case in cases}
        selected = [case["name"] for case in cases] if args.cases == "all" else args.cases.split(",")
        if not selected or len(set(selected)) != len(selected) or not set(selected) <= available:
            parser.error("--cases must contain distinct names from cases.json")
        if args.list_cases:
            print(json.dumps(cases, indent=2))
            return

        receipt_paths = {}
        for label, executable in executables.items():
            receipt_paths[label] = build / f"verification-{label}.jsonl"
            run([str(executable), "verify"], stdout=receipt_paths[label])
        verification = verify_receipts(output, receipt_paths)
        print(f"Exact UTF-8/error comparison passed: {verification['fixtures']} fixtures "
              f"({verification['successful_fixtures']} successful).", flush=True)
        if args.verify_only:
            return

        def timed(label: str, case: str, iterations: int, warmup: int) -> dict:
            value = json.loads(run([str(executables[label]), "time", case, str(iterations), str(warmup)], cpu=args.cpu))
            if value["case"] != case or value["iterations"] != iterations or value["warmup_iterations"] != warmup:
                raise RuntimeError("Timing receipt does not describe the requested workload")
            if value["wall_nanoseconds"] <= 0 or value["cpu_nanoseconds"] <= 0:
                raise RuntimeError("Nonpositive timing interval")
            return value

        calibrations = {}
        for case in selected:
            pilot = timed("baseline", case, 3, 3)
            iterations = max(1, min(1_000_000, math.ceil(args.target_ms * 1_000_000 / pilot["wall_ns_per_conversion"])))
            calibrations[case] = {"pilot": pilot, "iterations": iterations,
                                  "warmup_iterations": max(2, min(10, iterations // 10))}
        write_json(output / "calibration.json", calibrations)
        measurements = []
        for round_index in range(args.rounds):
            order = ("baseline", "candidate") if round_index % 2 == 0 else ("candidate", "baseline")
            offset = round_index % len(selected)
            for case in selected[offset:] + selected[:offset]:
                calibration = calibrations[case]
                pair = []
                for position, label in enumerate(order):
                    value = timed(label, case, calibration["iterations"], calibration["warmup_iterations"])
                    value.update(variant=label, round=round_index + 1, position=position + 1, order=list(order))
                    measurements.append(value)
                    pair.append(value)
                    with (output / "measurements.jsonl").open("a", encoding="utf-8") as stream:
                        stream.write(json.dumps(value, sort_keys=True) + "\n")
                if pair[0]["output_sink"] != pair[1]["output_sink"]:
                    raise RuntimeError(f"Timed output sinks differ for {case}")
            print(f"Finished balanced sample round {round_index + 1}/{args.rounds}.", flush=True)

        integrity = finalize_cohort(output, measurements, command_receipts, selected, args.rounds)
        summaries = []
        for case in selected:
            variants = {}
            for label in ("baseline", "candidate"):
                samples = [m for m in measurements if m["case"] == case and m["variant"] == label]
                variants[label] = {metric: distribution([m[metric] for m in samples])
                                   for metric in ("wall_ns_per_conversion", "cpu_ns_per_conversion")}
            summary = {"case": case, "samples_per_variant": args.rounds, "variants": variants}
            for clock in ("wall", "cpu"):
                metric = f"{clock}_ns_per_conversion"
                old = variants["baseline"][metric]["median"]
                new = variants["candidate"][metric]["median"]
                summary[f"{clock}_speedup"] = old / new
                summary[f"{clock}_reduction_percent"] = (1 - new / old) * 100
            summaries.append(summary)
            print(f"{case}: wall {summary['wall_speedup']:.3f}x, CPU {summary['cpu_speedup']:.3f}x", flush=True)
        write_json(output / "summary.json", {"verification_exact_match": True, "integrity": integrity, "cases": summaries,
                                              "method": "Ratio of medians from balanced AB/BA process pairs; no timing pass/fail threshold."})


if __name__ == "__main__":
    main()
