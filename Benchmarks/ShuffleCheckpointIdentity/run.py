#!/usr/bin/env python3
"""Paired, fresh-process qualification of the shuffled-checkpoint ID projection."""
import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
from pathlib import Path

BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE_PATHS = [
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
SCENARIOS = ["unchanged", "edited", "duplicates", "no-base"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sizes", default="1,32,1000,10000")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=60)
    parser.add_argument("--allocations", action="store_true",
                        help="Separate Linux/glibc malloc-family request measurements")
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",")]
    if not sizes or any(value < 0 for value in sizes) or args.pairs < 2 or args.pairs % 2:
        parser.error("Use nonnegative sizes and an even number of at least two pairs")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    if args.allocations and platform.system() != "Linux":
        parser.error("--allocations requires Linux/glibc")
    if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
        print("Kyoto is unavailable on this host; building serially in a new isolated directory.",
              flush=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = output / "sources"
    logs = output / "logs"
    sources.mkdir()
    logs.mkdir()
    sequence = 0

    def run(command, *, env=None):
        nonlocal sequence
        sequence += 1
        completed = subprocess.run([str(part) for part in command], cwd=ROOT, env=env,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        log = logs / f"{sequence:04d}.log"
        log.write_text(completed.stdout + completed.stderr)
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({
                "sequence": sequence, "argv": [str(part) for part in command],
                "returncode": completed.returncode, "log": str(log.relative_to(output)),
                "allocation_meter": bool(env and env.get("LD_PRELOAD")),
            }, sort_keys=True) + "\n")
        if completed.returncode:
            raise RuntimeError(f"Command failed: {command}\n{completed.stdout}\n{completed.stderr}")
        return completed.stdout

    compile_sources = []
    hashes = {}
    for relative in SOURCE_PATHS:
        content = (ROOT / relative).read_bytes()
        destination = sources / Path(relative).name
        destination.write_bytes(content)
        compile_sources.append(destination)
        hashes[relative] = hashlib.sha256(content).hexdigest()
    baseline = run(["git", "show", f"{BASE}:{SOURCE_PATHS[0]}"])
    declaration = "public enum PlaylistMutation {"
    if baseline.count(declaration) != 1:
        raise RuntimeError("Pinned baseline declaration changed")
    baseline_source = sources / "BaselinePlaylistMutation.swift"
    baseline_source.write_text(baseline.replace(declaration, "enum BaselinePlaylistMutation {", 1))
    compile_sources.append(baseline_source)
    driver = sources / "Driver.swift"
    shutil.copyfile(HERE / "Driver.swift", driver)
    compile_sources.append(driver)
    hashes["baseline/PlaylistMutation.swift"] = hashlib.sha256(baseline.encode()).hexdigest()
    hashes["Benchmarks/ShuffleCheckpointIdentity/Driver.swift"] = hashlib.sha256(driver.read_bytes()).hexdigest()
    hashes["Benchmarks/ShuffleCheckpointIdentity/run.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    compiler = run(["swiftc", "--version"]).strip()
    head = run(["git", "rev-parse", "HEAD"]).strip()
    executable = output / "study"
    run(["swiftc", "-O", "-swift-version", "6", *compile_sources, "-o", executable])
    meter_environment = None
    if args.allocations:
        meter_source = ROOT / "Benchmarks/NonDecodePerformance/allocmeter.c"
        meter_copy = sources / "allocmeter.c"
        shutil.copyfile(meter_source, meter_copy)
        hashes["Benchmarks/NonDecodePerformance/allocmeter.c"] = hashlib.sha256(meter_copy.read_bytes()).hexdigest()
        meter_library = output / "allocmeter.so"
        run(["clang", "-shared", "-fPIC", "-O2", meter_copy, "-o", meter_library])
        meter_environment = dict(os.environ, LD_PRELOAD=str(meter_library))

    manifest = {
        "baseline_commit": BASE, "candidate_commit": head, "compiler": compiler,
        "platform": platform.platform(), "machine": platform.machine(),
        "sources_sha256": hashes, "sizes": sizes, "scenarios": SCENARIOS,
        "pairs": args.pairs, "target_ms": args.target_ms,
        "allocation_scope": "successful malloc/calloc/realloc requested bytes; excludes aligned "
                            "allocations, live/peak heap, RSS and native macOS allocations",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    observations = []
    calibration = []

    def observe(variant, size, scenario, iterations, mode):
        environment = meter_environment if mode == "allocations" else None
        value = json.loads(run([executable, variant, size, scenario, iterations, mode], env=environment))
        if (value["variant"], value["size"], value["scenario"], value["iterations"], value["mode"]) != (
                variant, size, scenario, iterations, mode) or value["byte_parity"] is not True:
            raise RuntimeError("Mismatched observation or failed parity")
        if not all(math.isfinite(value[key]) and value[key] >= 0
                   for key in ["wall_ns_per_call", "cpu_ns_per_call"]):
            raise RuntimeError("Invalid timing observation")
        return value

    for size in sizes:
        for scenario in SCENARIOS:
            trial = [observe(variant, size, scenario, 1, "timing")
                     for variant in ["baseline", "candidate"]]
            calibration.extend(trial)
            slowest = max(row["wall_ns_per_call"] for row in trial)
            iterations = max(1, min(10_000, math.ceil(args.target_ms * 1_000_000 / max(slowest, 1))))
            for mode in ["timing"] + (["allocations"] if args.allocations else []):
                repeats = args.pairs if mode == "timing" else 2
                for pair in range(repeats):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    for position, variant in enumerate(order):
                        row = observe(variant, size, scenario, iterations if mode == "timing" else 1, mode)
                        row.update(pair=pair, process_order=position, order=order)
                        observations.append(row)
                        with (output / "observations.jsonl").open("a") as stream:
                            stream.write(json.dumps(row, sort_keys=True) + "\n")

    summary = []
    for size in sizes:
        for scenario in SCENARIOS:
            for mode in ["timing"] + (["allocations"] if args.allocations else []):
                rows = [r for r in observations if (r["size"], r["scenario"], r["mode"]) == (size, scenario, mode)]
                expected_pairs = args.pairs if mode == "timing" else 2
                for pair in range(expected_pairs):
                    ordered = sorted((r for r in rows if r["pair"] == pair), key=lambda r: r["process_order"])
                    expected_order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    if [r["variant"] for r in ordered] != expected_order:
                        raise RuntimeError("Missing, duplicated or unbalanced paired observations")
                    if ordered[0]["checksum"] != ordered[1]["checksum"]:
                        raise RuntimeError("Paired output checksums differ")
                metrics = ["wall_ns_per_call", "cpu_ns_per_call"] if mode == "timing" else [
                    "allocation_requests_per_call", "requested_bytes_per_call"]
                entry = {"size": size, "scenario": scenario, "mode": mode, "pairs": expected_pairs}
                for metric in metrics:
                    before = statistics.median(r[metric] for r in rows if r["variant"] == "baseline")
                    after = statistics.median(r[metric] for r in rows if r["variant"] == "candidate")
                    entry[metric] = {"baseline": before, "candidate": after,
                                     "reduction_percent": 100 * (1 - after / before) if before else None}
                summary.append(entry)
    (output / "calibration.json").write_text(json.dumps(calibration, indent=2, sort_keys=True) + "\n")
    report = {"manifest": manifest, "observations": len(observations), "results": summary,
              "byte_parity": True, "all_pairs_balanced": True}
    (output / "summary.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("SHUFFLE_CHECKPOINT_SUMMARY " + json.dumps(report, sort_keys=True), flush=True)
    # Keep full raw rows retrievable through ordinary Actions text logs as well as artifacts.
    for row in observations:
        print("SHUFFLE_CHECKPOINT_OBSERVATION " + json.dumps(row, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
