#!/usr/bin/env python3
"""Reproduce exact-output verification and paired filename-recognition timings."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = Path("Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift")
BASELINE_REVISION = "68274d1b09dcc866296321a5a8858efc297c4f19"
DECLARATION = "public enum MediaNameRecognition {"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)
    if path.read_bytes() != data:
        raise RuntimeError(f"Saved JSON differs from written data: {path}")


def append_json(path: Path, value: object) -> None:
    with path.open("a", encoding="utf-8") as output:
        output.write(json.dumps(value, sort_keys=True) + "\n")
        output.flush()
        os.fsync(output.fileno())


def command(arguments: list[str], out: Path, label: str) -> str:
    result = subprocess.run(arguments, text=True, capture_output=True, cwd=ROOT)
    stdout_path = out / "logs" / f"{label}.stdout.txt"
    stderr_path = out / "logs" / f"{label}.stderr.txt"
    stdout_path.write_text(result.stdout)
    stderr_path.write_text(result.stderr)
    append_json(out / "commands.jsonl", {
        "label": label, "arguments": arguments, "returncode": result.returncode,
        "stdout": str(stdout_path.relative_to(out)), "stderr": str(stderr_path.relative_to(out)),
        "stdout_sha256": sha256(stdout_path.read_bytes()),
        "stderr_sha256": sha256(stderr_path.read_bytes()),
    })
    if result.returncode:
        raise RuntimeError(f"{label} failed ({result.returncode}): {result.stderr[-6000:]}")
    return result.stdout


def stage(out: Path) -> dict[str, object]:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline = (HERE / "baseline/MediaNameRecognition.swift").read_bytes()
    candidate = (ROOT / SOURCE).read_bytes()
    if pinned["revision"] != BASELINE_REVISION or sha256(baseline) != pinned["sha256"]:
        raise RuntimeError("Frozen baseline differs from its pinned manifest")
    original = baseline.decode()
    current = candidate.decode()
    if original.count(DECLARATION) != 1 or current.count(DECLARATION) != 1:
        raise RuntimeError("Recognizer extraction anchor changed; review the verifier")
    original_type, original_enum = original.split(DECLARATION)
    current_type, _ = current.split(DECLARATION)
    if original_type != current_type:
        raise RuntimeError("RecognizedMediaName changed; the shared-type oracle requires review")
    oracle = ("import Foundation\n\npublic enum BaselineMediaNameRecognition {" + original_enum).encode()
    sources = {
        "baseline.swift": baseline, "candidate.swift": candidate, "oracle.swift": oracle,
        "Harness.swift": (HERE / "Harness.swift").read_bytes(),
        "run.py": Path(__file__).read_bytes(),
    }
    for name, data in sources.items():
        (out / "sources" / name).write_bytes(data)
    return {
        "baseline_revision": BASELINE_REVISION, "production_path": str(SOURCE),
        "source_sha256": {name: sha256(data) for name, data in sources.items()},
        "oracle_transform": "Remove unchanged result type; rename baseline enum declaration only",
    }


def build(variant: str, out: Path, swiftc: str) -> dict[str, object]:
    folder = out / "build" / variant
    folder.mkdir(parents=True)
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
             "-module-cache-path", str(out / "module-cache")]
    native = sys.platform == "darwin"
    if native:
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    sources = [out / "sources" / ("baseline.swift" if variant == "baseline" else "candidate.swift")]
    definitions: list[str] = []
    if variant == "verifier":
        sources.append(out / "sources/oracle.swift")
        definitions = ["-D", "DIFFERENTIAL_VERIFY"]
    library = folder / ("libMediaRecognition.dylib" if native else "libMediaRecognition.so")
    module_arguments = [swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "MediaRecognition",
                        "-emit-module-path", str(folder / "MediaRecognition.swiftmodule"),
                        *map(str, sources), "-o", str(library)]
    command(module_arguments, out, f"build-{variant}-module")
    executable = folder / "recognize"
    harness_arguments = [swiftc, *flags, *definitions, "-parse-as-library", "-I", str(folder),
                         "-L", str(folder), "-lMediaRecognition", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                         str(out / "sources/Harness.swift"), "-o", str(executable)]
    command(harness_arguments, out, f"build-{variant}-harness")
    return {
        "executable": str(executable), "executable_sha256": sha256(executable.read_bytes()),
        "library": str(library), "library_sha256": sha256(library.read_bytes()),
        "module_command": module_arguments, "harness_command": harness_arguments,
    }


def summarize(rows: list[dict[str, object]], workloads: list[str], rounds: int) -> list[dict[str, object]]:
    summary = []
    if len(rows) != len(workloads) * rounds * 2:
        raise RuntimeError("Measurement count differs from the planned complete cohort")
    for workload in workloads:
        selected = [row for row in rows if row["workload"] == workload]
        group: dict[str, object] = {"workload": workload, "pairs": rounds}
        for variant in ("baseline", "candidate"):
            values = [row["elapsed_ns"] / row["operations"] for row in selected if row["variant"] == variant]
            if len(values) != rounds:
                raise RuntimeError(f"Wrong sample count for {workload}/{variant}")
            group[variant] = {"min_ns_per_name": min(values), "median_ns_per_name": statistics.median(values),
                              "max_ns_per_name": max(values)}
        ratios = []
        for round_index in range(rounds):
            pair = [row for row in selected if row["round"] == round_index]
            expected_order = ["baseline", "candidate"] if round_index % 2 == 0 else ["candidate", "baseline"]
            if [row["variant"] for row in pair] != expected_order:
                raise RuntimeError(f"Pair order differs for {workload}/{round_index}")
            by_variant = {row["variant"]: row for row in pair}
            baseline, candidate = by_variant["baseline"], by_variant["candidate"]
            for key in ("operations", "iterations", "paths_per_iteration", "checksum", "warmup_checksum"):
                if baseline[key] != candidate[key]:
                    raise RuntimeError(f"Timing receipt {key} differs for {workload}/{round_index}")
            ratios.append(candidate["elapsed_ns"] / baseline["elapsed_ns"])
        group["paired_candidate_over_baseline"] = ratios
        group["median_paired_time_reduction_percent"] = 100 * (1 - statistics.median(ratios))
        group["candidate_faster_pairs"] = sum(ratio < 1 for ratio in ratios)
        summary.append(group)
    return summary


def emit_evidence(out: Path, names: list[str]) -> None:
    # Hosted logs retain these compact artifacts if an artifact download fails.
    # measurements.jsonl is rendered as one JSON array between its markers.
    for name in names:
        raw = (out / name).read_text()
        value = [json.loads(line) for line in raw.splitlines()] if name.endswith(".jsonl") else json.loads(raw)
        print(f"EVIDENCE_BEGIN {name}", flush=True)
        print(json.dumps(value, sort_keys=True), flush=True)
        print(f"EVIDENCE_END {name}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=16, help="complete workload cycles per observation")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.rounds < 6 or args.rounds % 2:
        parser.error("--rounds must be even and at least 6 for balanced AB/BA pairs")
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("--output must be absent or empty; use a fresh directory for each cohort")
    out.mkdir(parents=True, exist_ok=True)
    (out / "logs").mkdir()
    (out / "sources").mkdir()
    swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise RuntimeError("swiftc is required; select a Swift 6 toolchain via PATH or SWIFTC")
    manifest = stage(out)
    manifest.update({
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor(),
        "logical_cpu_count": os.cpu_count(), "python": sys.version,
        "compiler": command([swiftc, "--version"], out, "compiler-version").strip(),
        "rounds": args.rounds, "iterations": args.iterations,
        "timer_scope": "recognize(relativePath:) and append; inputs/reservation/warmup/full-result digest excluded",
        "builds": {},
    })
    if sys.platform == "darwin":
        manifest["macos"] = command(["sw_vers"], out, "macos-version").strip()
        manifest["hardware"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], out, "hardware").strip()
    write_json(out / "manifest.json", manifest)
    verifier = build("verifier", out, swiftc)
    manifest["builds"]["verifier"] = verifier
    catalog = json.loads(command([verifier["executable"], "--catalog"], out, "catalog"))
    write_json(out / "fixtures.json", catalog)
    equivalence = json.loads(command([verifier["executable"], "--verify"], out, "equivalence"))
    if equivalence["checks"] != len(catalog["verification_paths"]) or not equivalence["exact_utf8_fields"]:
        raise RuntimeError("Verifier did not check the complete fixture corpus")
    equivalence["fixtures_sha256"] = sha256((out / "fixtures.json").read_bytes())
    equivalence["source_sha256"] = manifest["source_sha256"]
    write_json(out / "equivalence.json", equivalence)
    print(f"PASS: {equivalence['checks']} exact UTF-8 / metadata comparisons", flush=True)
    if args.verify_only:
        write_json(out / "manifest.json", manifest)
        emit_evidence(out, ["manifest.json", "equivalence.json"])
        return
    builds = {variant: build(variant, out, swiftc) for variant in ("baseline", "candidate")}
    manifest["builds"].update(builds)
    manifest["workloads"] = [{"name": item["name"], "paths": len(item["paths"])} for item in catalog["workloads"]]
    write_json(out / "manifest.json", manifest)
    rows: list[dict[str, object]] = []
    for item in catalog["workloads"]:
        workload = item["name"]
        for round_index in range(args.rounds):
            order = ("baseline", "candidate") if round_index % 2 == 0 else ("candidate", "baseline")
            for order_index, variant in enumerate(order):
                arguments = [builds[variant]["executable"], "--case", workload, "--iterations", str(args.iterations)]
                row = json.loads(command(arguments, out, f"timing-{workload}-{round_index}-{variant}"))
                if row["workload"] != workload or row["operations"] != len(item["paths"]) * args.iterations:
                    raise RuntimeError("Unexpected workload or operation count in timing output")
                if row["elapsed_ns"] <= 0:
                    raise RuntimeError("Nonpositive measured interval")
                row.update({"variant": variant, "round": round_index, "order_in_pair": order_index})
                rows.append(row)
                append_json(out / "measurements.jsonl", row)
        print(f"Measured {workload}: {args.rounds} fresh-process pairs", flush=True)
    saved_rows = [json.loads(line) for line in (out / "measurements.jsonl").read_text().splitlines()]
    if saved_rows != rows:
        raise RuntimeError("Persisted timing rows differ from the completed in-memory cohort")
    summary = summarize(saved_rows, [item["name"] for item in catalog["workloads"]], args.rounds)
    write_json(out / "summary.json", summary)
    for name, expected in manifest["source_sha256"].items():
        if sha256((out / "sources" / name).read_bytes()) != expected:
            raise RuntimeError(f"Staged source changed during execution: {name}")
    for variant, receipt in manifest["builds"].items():
        for key in ("executable", "library"):
            if sha256(Path(receipt[key]).read_bytes()) != receipt[f"{key}_sha256"]:
                raise RuntimeError(f"Built {key} changed during execution: {variant}")
    manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
    manifest["artifacts_sha256"] = {name: sha256((out / name).read_bytes()) for name in (
        "commands.jsonl", "fixtures.json", "equivalence.json", "measurements.jsonl", "summary.json")}
    write_json(out / "manifest.json", manifest)
    emit_evidence(out, ["manifest.json", "equivalence.json", "measurements.jsonl", "summary.json"])


if __name__ == "__main__":
    main()
