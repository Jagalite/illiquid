#!/usr/bin/env python3
"""One bounded A/A timing control: labels A and B run the identical binary.

Reproduce without rebuilding:
  source /tmp/illiquid-swift-toolchain/env.sh
  python3 run.py --output /path/to/new-empty-output

The default output is this script's directory. Existing result files are never
overwritten. The driver and preflight use the production baseline binary from
the complete SubtitleQualifierStorage qualification run.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

DEFAULT_BINARY = Path("/workspace/scratch/f4995c2fe1e0/qualifier-linux-final/baseline/.build/release/AssociationDriver")
EXPECTED_BINARY_SHA256 = "ce275ba0930c23f825debc25416522e91f797dd5765911aa34804861a6642699"
CASES = ("ascii_4096", "plain_4096")
PAIRS = 6
ITERATIONS = 5
WARMUP = 4


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def describe(values):
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(path.name != "run.py" for path in output.iterdir()):
        parser.error("Output must be empty except for run.py; no result may be overwritten")
    binary = args.binary.resolve(strict=True)
    if digest(binary.read_bytes()) != EXPECTED_BINARY_SHA256:
        raise RuntimeError("The provided binary differs from the qualified baseline binary")
    swift = shutil.which("swift")
    if swift is None:
        raise RuntimeError("Source the toolchain env.sh before running this control")
    env = os.environ.copy()
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    receipts = []

    def command(argv, *, name: str, timeout: int = 180):
        if digest(binary.read_bytes()) != EXPECTED_BINARY_SHA256:
            raise RuntimeError("Baseline binary changed during the control")
        argv = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(argv, env=env, capture_output=True, timeout=timeout)
        receipt = {
            "name": name, "argv": argv, "returncode": result.returncode,
            "outer_wall_seconds": time.monotonic() - started,
            "stdout_bytes": len(result.stdout), "stdout_sha256": digest(result.stdout),
            "stderr_bytes": len(result.stderr), "stderr_sha256": digest(result.stderr),
            "binary_sha256_after": digest(binary.read_bytes()),
        }
        receipts.append(receipt)
        write_json(output / "commands.json", receipts)
        if result.stderr:
            (output / (name + ".stderr.txt")).write_bytes(result.stderr)
        if result.returncode or receipt["binary_sha256_after"] != EXPECTED_BINARY_SHA256:
            raise RuntimeError(f"Control command failed or binary changed: {name}; see command receipt")
        return result.stdout

    compiler = command([swift, "--version"], name="compiler").decode().strip()
    selected_env = {name: env.get(name) for name in (
        "PATH", "LD_LIBRARY_PATH", "SWIFT_DETERMINISTIC_HASHING", "LANG", "LC_ALL",
        "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH",
    )}
    manifest = {
        "schema_version": 1,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "control": "A/A identical-binary control; A and B are arbitrary labels",
        "label_binary": {"A": str(binary), "B": str(binary)},
        "label_binary_sha256": {"A": EXPECTED_BINARY_SHA256, "B": EXPECTED_BINARY_SHA256},
        "compiler": compiler, "platform": platform.platform(),
        "machine": platform.machine(), "python": platform.python_version(),
        "environment": selected_env, "cases": list(CASES), "pairs_per_case": PAIRS,
        "iterations_per_sample": ITERATIONS, "warmup_per_sample": WARMUP,
        "ordering": "Pair 0 A/B, pair 1 B/A, alternating for six pairs per case",
        "processes": "Fresh process for every label/sample, sequential invocation",
        "timing_scope": "Existing driver: complete association, count consumption and result destruction; excludes fixture/oracle/preflight",
        "runner_sha256": digest(Path(__file__).read_bytes()),
    }
    toolchain_env = Path("/tmp/illiquid-swift-toolchain/env.sh")
    if toolchain_env.exists():
        manifest["toolchain_env_sha256"] = digest(toolchain_env.read_bytes())
    if hasattr(os, "sched_getaffinity"):
        manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.exists():
        manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
            for line in cpuinfo.read_text().splitlines() if line.startswith("model name")), None)
    write_json(output / "manifest.json", manifest)

    preflight_bytes = command([binary, "--verify"], name="full-output-preflight")
    (output / "preflight.json").write_bytes(preflight_bytes)
    preflight = json.loads(preflight_bytes)
    if preflight["recordCount"] != 25 or len(preflight["records"]) != 25:
        raise RuntimeError("Expected all 25 original, control and edge-fixture oracles")
    by_case = {row["caseName"]: row for row in preflight["records"]}
    if len(by_case) != 25:
        raise RuntimeError("Duplicate preflight case name")
    root = Path("/tmp/illiquid-subtitle-tokenization")
    for case in CASES:
        row = by_case[case]
        if row["mediaCount"] != 4096 or row["inputSubtitleCount"] != 4096:
            raise RuntimeError("Unexpected preflight input cardinality")
        expected = {}
        for index in range(1, 4097):
            stem = f"Example.Series.Episode.{index:06d}"
            suffix = ".1080p.WEB-DL.x265" if case == "ascii_4096" else ""
            expected[(root / (stem + suffix + ".mkv")).as_uri()] = [
                (root / (stem + ".en.srt")).as_uri()]
        if row["associations"] != expected:
            raise RuntimeError("Complete measured-case output differs from independent oracle")
    write_json(output / "preflight-receipt.json", {
        "status": "passed", "record_count": 25,
        "full_output_sha256": digest(preflight_bytes),
        "full_output_bytes": len(preflight_bytes),
        "driver_oracles": "All 25 fixtures verified by the existing driver's independent fixture oracles",
        "additional_python_oracles": {case: "All 4096 exact media-to-subtitle mappings match" for case in CASES},
        "binary_sha256": EXPECTED_BINARY_SHA256,
    })

    rows = []
    pairs = []
    for case in CASES:
        for pair in range(PAIRS):
            order = ("A", "B") if pair % 2 == 0 else ("B", "A")
            observations = {}
            for order_index, label in enumerate(order):
                raw = command([binary, "--case", case, "--iterations", ITERATIONS,
                               "--warmup", WARMUP], name=f"{case}-{pair}-{label}")
                measurement = json.loads(raw)
                if measurement["caseName"] != case or measurement["iterations"] != ITERATIONS \
                        or measurement["warmupIterations"] != WARMUP \
                        or measurement["mediaCount"] != 4096 \
                        or measurement["inputSubtitleCount"] != 4096 \
                        or measurement["checksum"] != measurement["expectedChecksum"]:
                    raise RuntimeError("A/A measurement receipt failed its protocol or oracle checks")
                row = {"case": case, "pair": pair, "label": label,
                       "order_index": order_index, "order": list(order),
                       "binary_sha256": EXPECTED_BINARY_SHA256, "measurement": measurement}
                rows.append(row)
                observations[label] = measurement
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
            a, b = observations["A"], observations["B"]
            if a["checksum"] != b["checksum"]:
                raise RuntimeError("Identical-binary result checksums differ")
            result = {
                "case": case, "pair": pair, "order": list(order),
                "cpu_A_ms": a["cpuNsPerLookup"] / 1e6,
                "cpu_B_ms": b["cpuNsPerLookup"] / 1e6,
                "cpu_B_minus_A_ms": (b["cpuNsPerLookup"] - a["cpuNsPerLookup"]) / 1e6,
                "cpu_B_relative_to_A_pct": 100 * (b["cpuNsPerLookup"] / a["cpuNsPerLookup"] - 1),
                "wall_B_relative_to_A_pct": 100 * (b["nsPerLookup"] / a["nsPerLookup"] - 1),
            }
            pairs.append(result)
            with (output / "pairs.jsonl").open("a") as stream:
                stream.write(json.dumps(result, sort_keys=True, allow_nan=False) + "\n")

    summary = {
        "control": "A/A: both labels execute the exact same qualified baseline binary",
        "observations": len(rows), "pairs": len(pairs), "cases": [],
        "interpretation": "Label differences quantify observed run-to-run variation under this host/protocol. They measure no code change and establish neither a candidate slowdown nor a speedup.",
    }
    for case in CASES:
        selected = [row for row in rows if row["case"] == case]
        paired = [row for row in pairs if row["case"] == case]
        summary["cases"].append({
            "case": case,
            "cpu_ms_per_association": {label: describe([row["measurement"]["cpuNsPerLookup"] / 1e6
                for row in selected if row["label"] == label]) for label in ("A", "B")},
            "wall_ms_per_association": {label: describe([row["measurement"]["nsPerLookup"] / 1e6
                for row in selected if row["label"] == label]) for label in ("A", "B")},
            "paired_cpu_B_relative_to_A_pct": describe([row["cpu_B_relative_to_A_pct"] for row in paired]),
            "paired_cpu_B_minus_A_ms": describe([row["cpu_B_minus_A_ms"] for row in paired]),
            "paired_wall_B_relative_to_A_pct": describe([row["wall_B_relative_to_A_pct"] for row in paired]),
        })
    write_json(output / "summary.json", summary)
    write_json(output / "completion.json", {"status": "passed", "completed_utc": datetime.now(timezone.utc).isoformat(),
        "observations": len(rows), "pairs": len(pairs), "binary_sha256": digest(binary.read_bytes())})
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
