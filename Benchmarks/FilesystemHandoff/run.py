#!/usr/bin/env python3
"""Measure actual monitor callbacks pending on a stalled macOS main actor."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CORE = "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift"
APP = [
    "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift",
    "Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift",
    "Sources/IlliquidApp/UI/SourceVolumeChangePolicy.swift",
]
MAILBOX = "Sources/IlliquidApp/UI/SourceFilesystemEventMailbox.swift"
CASES = [
    ("single", 1, 1),
    ("small-32", 32, 1),
    ("boundary-4096", 4096, 128),
    ("overflow-4097", 4097, 128),
    ("storm-100k", 100000, 128),
    ("storm-100k-small-batches", 100000, 16),
    ("oversized-callback", 100000, 100000),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive and even (at least two)")
    if sys.platform != "darwin":
        parser.error("This experiment compiles the real AppKit/FSEvents monitor on macOS")
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    logs = output / "logs"
    logs.mkdir()
    command_index = 0

    def run(command, timeout=300):
        nonlocal command_index
        command_index += 1
        command = [str(value) for value in command]
        stem = f"{command_index:04d}"
        started = time.monotonic_ns()
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=timeout)
        (logs / f"{stem}.stdout").write_text(result.stdout)
        (logs / f"{stem}.stderr").write_text(result.stderr)
        record = {"argv": command, "cwd": str(root), "returncode": result.returncode,
                  "elapsed_ns": time.monotonic_ns() - started,
                  "stdout": f"logs/{stem}.stdout", "stderr": f"logs/{stem}.stderr"}
        with (output / "commands.jsonl").open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            raise RuntimeError(f"Command failed: {command}")
        return result.stdout

    def write_json(name, value):
        (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    swift = run(["xcrun", "--find", "swiftc"]).strip()
    clang = run(["xcrun", "--find", "clang"]).strip()
    environment = {
        "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(), "architecture": platform.machine(),
        "swift": run([swift, "--version"]), "macos": run(["sw_vers"]),
        "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    }
    write_json("environment.json", environment)
    manifest = {
        "baseline_commit": BASELINE,
        "candidate_commit": run(["git", "rev-parse", "HEAD"]).strip(),
        "metric": "malloc_zone_statistics(NULL).size_in_use; live allocator bytes, not RSS",
        "pairs": args.pairs, "cases": CASES, "source_sha256": {}, "executable_sha256": {},
    }
    for path in [Path(__file__), root / "Benchmarks/FilesystemHandoff/Driver.swift",
                 root / "Benchmarks/FilesystemHandoff/Heap.c",
                 root / "Scripts/test-filesystem-handoff.sh"]:
        manifest["source_sha256"][str(path.relative_to(root))] = digest(path)
    write_json("manifest.json", manifest)
    binaries = {}
    for variant in ["baseline", "candidate"]:
        staged = output / "sources" / variant
        build = output / "build" / variant
        build.mkdir(parents=True)
        sources = [CORE, *APP] + ([MAILBOX] if variant == "candidate" else [])
        for name in sources:
            destination = staged / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            contents = (run(["git", "show", f"{BASELINE}:{name}"])
                        if variant == "baseline" else (root / name).read_text())
            destination.write_text(contents)
            manifest["source_sha256"][str(destination.relative_to(output))] = digest(destination)
        flags = ["-swift-version", "6", "-warnings-as-errors", "-O", "-parse-as-library",
                 "-module-cache-path", str(build / "module-cache")]
        library = build / "libIlliquidCore.dylib"
        run([swift, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
             "-emit-module-path", build / "IlliquidCore.swiftmodule",
             staged / CORE, "-o", library])
        object_file = build / "Heap.o"
        run([clang, "-O2", "-Wall", "-Wextra", "-Werror", "-c",
             root / "Benchmarks/FilesystemHandoff/Heap.c", "-o", object_file])
        binary = build / "FilesystemHandoff"
        run([swift, *flags, "-module-name", "FilesystemHandoffBenchmark",
             "-I", build, "-L", build, "-lIlliquidCore",
             "-Xlinker", "-rpath", "-Xlinker", build,
             "-framework", "AppKit", "-framework", "CoreServices",
             *[staged / name for name in sources if name != CORE],
             root / "Benchmarks/FilesystemHandoff/Driver.swift", object_file, "-o", binary])
        binaries[variant] = binary
        manifest["executable_sha256"][variant] = digest(binary)
    write_json("manifest.json", manifest)

    observations = []
    for case, total, batch in CASES:
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for variant in order:
                measurement = json.loads(run([binaries[variant], variant, total, batch], timeout=120))
                assert measurement["variant"] == variant
                assert measurement["total_events"] == total and measurement["batch_size"] == batch
                assert measurement["verified"] is True
                measurement.update(case=case, pair=pair, order=order)
                observations.append(measurement)
                line = json.dumps(measurement, sort_keys=True)
                with (output / "observations.jsonl").open("a") as handle:
                    handle.write(line + "\n")
                print("HANDOFF_OBSERVATION " + line, flush=True)

    summary = []
    for case, total, batch in CASES:
        records = [item for item in observations if item["case"] == case]
        baseline = [item for item in records if item["variant"] == "baseline"]
        candidate = [item for item in records if item["variant"] == "candidate"]
        semantic_results = {json.dumps(item["semantic"], sort_keys=True) for item in records}
        assert len(semantic_results) == 1, f"Cross-variant semantic parity failed: {case}"
        paired = [
            next(item["held_delta_bytes"] for item in baseline if item["pair"] == pair)
            - next(item["held_delta_bytes"] for item in candidate if item["pair"] == pair)
            for pair in range(args.pairs)
        ]
        def summarize(items, key):
            values = [item[key] for item in items]
            return {"median": statistics.median(values), "min": min(values), "max": max(values)}
        summary.append({
            "case": case, "total_events": total, "batch_size": batch,
            "baseline_held_delta_bytes": summarize(baseline, "held_delta_bytes"),
            "candidate_held_delta_bytes": summarize(candidate, "held_delta_bytes"),
            "paired_reduction_bytes": {"median": statistics.median(paired), "min": min(paired), "max": max(paired)},
            "baseline_deliveries": sorted(set(item["delivery_count"] for item in baseline)),
            "candidate_deliveries": sorted(set(item["delivery_count"] for item in candidate)),
            "baseline_after_drain_delta_bytes": summarize(baseline, "after_drain_delta_bytes"),
            "candidate_after_drain_delta_bytes": summarize(candidate, "after_drain_delta_bytes"),
            "baseline_after_stop_delta_bytes": summarize(baseline, "after_stop_delta_bytes"),
            "candidate_after_stop_delta_bytes": summarize(candidate, "after_stop_delta_bytes"),
        })
    write_json("summary.json", summary)
    verification = {"observations": len(observations), "all_verified": True,
                    "control_sequence_and_planner_parity": True,
                    "overflow_all_root_recovery": True}
    write_json("verification.json", verification)
    print("HANDOFF_MANIFEST " + json.dumps(manifest, sort_keys=True))
    print("HANDOFF_ENVIRONMENT " + json.dumps(environment, sort_keys=True))
    print("HANDOFF_VERIFICATION " + json.dumps(verification, sort_keys=True))
    print("HANDOFF_SUMMARY " + json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
