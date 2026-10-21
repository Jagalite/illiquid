#!/usr/bin/env python3
"""Paired native frame-step measurements using the real reader and decoder."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "a2de305c8dbcaa81aac1477df7c9a0017c14eae3"
HARNESS = Path("Tests/IlliquidNativePlaybackTests/FrameStepPerformanceTests.swift")
SOURCES = [Path("Sources/IlliquidNativePlayback/Media/VideoDecoder.swift"),
           Path("Sources/IlliquidNativePlayback/Media/NativeFrameStepReader.swift")]


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Native CoreMedia/CoreVideo measurements require macOS.")
    if args.output.exists() or not 3 <= args.pairs <= 12 or not 1 <= args.iterations <= 10:
        parser.error("Use a new output directory, 3–12 pairs, and 1–10 iterations.")
    output = args.output.resolve()
    fixtures = args.fixtures.resolve()
    output.mkdir(parents=True)
    fixtures.mkdir(parents=True, exist_ok=True)
    commands = []

    def run(command, *, env=None, timeout=900):
        command = [str(item) for item in command]
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        log = f"command-{len(commands):03}.log"
        (output / log).write_text(result.stdout)
        commands.append({"argv": command, "exit": result.returncode, "log": log,
                         "seconds": time.monotonic() - started})
        save(output / "commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command}\n{result.stdout[-18000:]}")
        return result.stdout

    baseline = run(["git", "rev-parse", f"{args.baseline}^{{commit}}"], timeout=30).strip()
    environment = {
        "baseline_commit": baseline,
        "candidate_commit": run(["git", "rev-parse", "HEAD"], timeout=30).strip(),
        "candidate_sources_sha256": {str(p): digest(ROOT / p) for p in SOURCES},
        "harness_sha256": digest(ROOT / HARNESS),
        "runner_sha256": digest(Path(__file__).resolve()),
        "swift": run(["swift", "--version"], timeout=30).strip(),
        "macos": run(["sw_vers"], timeout=30).strip(),
        "hardware": run(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"], timeout=30).strip(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "ffmpeg": run(["ffmpeg", "-version"], timeout=30).splitlines()[0],
        "pairs": args.pairs, "iterations_per_process": args.iterations,
        "build": "SwiftPM release, production package, two build jobs, serial tests",
        "method": "alternating baseline/candidate fresh processes; one warm-up request per process",
        "scope": "reader target discovery, including open/probe/seek/decode; excludes subsequent display seek, renderer and UI",
    }
    save(output / "environment.json", environment)

    # Deterministic long GOPs make the amount of discarded pixel preparation
    # reproducible. Also retain small/short-GOP and normal full-decode controls.
    fixture_specs = [
        ("bench-small.mp4", "320x180", 150),
        ("bench-1080p-long.mp4", "1920x1080", 150),
        ("bench-1080p-short.mp4", "1920x1080", 15),
        ("bench-4k-long.mp4", "3840x2160", 150),
    ]
    for filename, size, gop in fixture_specs:
        run(["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
             "-f", "lavfi", "-i", f"testsrc2=size={size}:rate=30", "-t", "5",
             "-an", "-c:v", "libx264", "-preset", "veryfast", "-threads", "2",
             "-g", str(gop), "-keyint_min", str(gop), "-sc_threshold", "0",
             "-bf", "3", "-pix_fmt", "yuv420p", fixtures / filename], timeout=180)
        run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-xerror",
             "-threads", "2", "-i", fixtures / filename, "-map", "0:v:0",
             "-threads", "2", "-f", "null", "-"], timeout=120)
    save(output / "fixtures.json", [{"file": name, "dimensions": size, "gop": gop,
          "sha256": digest(fixtures / name), "bytes": (fixtures / name).stat().st_size}
          for name, size, gop in fixture_specs])

    def workload(name, filename, direction=-1, full=False):
        return {"name": name, "filename": filename, "position": 3.2, "direction": direction,
                "iterations": args.iterations, "fullDecode": full}

    cases = [
        workload("small-backward", "bench-small.mp4"),
        workload("1080p-long-backward", "bench-1080p-long.mp4"),
        workload("1080p-long-forward", "bench-1080p-long.mp4", 1),
        workload("1080p-short-backward", "bench-1080p-short.mp4"),
        workload("4k-long-backward", "bench-4k-long.mp4"),
        workload("4k-long-forward", "bench-4k-long.mp4", 1),
        workload("full-frame-decode-control", "bench-1080p-long.mp4", full=True),
    ]
    save(output / "workloads.json", cases)
    baseline_tree = output / "baseline-tree"
    run(["git", "worktree", "add", "--detach", baseline_tree, baseline], timeout=180)
    shutil.copy2(ROOT / HARNESS, baseline_tree / HARNESS)
    roots = {"baseline": baseline_tree, "candidate": ROOT}
    base_environment = os.environ.copy()
    base_environment.update(ILLIQUID_FRAME_STEP_BENCHMARK="1",
                            ILLIQUID_FRAME_STEP_FIXTURE_DIR=str(fixtures),
                            TERM="dumb", NO_COLOR="1")

    def measure(variant, case, *, build=False):
        env = base_environment.copy()
        env["ILLIQUID_FRAME_STEP_WORKLOAD"] = json.dumps(case)
        command = ["swift", "test", "--package-path", roots[variant],
                   "--scratch-path", output / f"{variant}-build",
                   "--force-resolved-versions", "-c", "release", "--jobs", "2",
                   "--no-parallel", "--filter", "FrameStepPerformanceTests"]
        if not build:
            command.append("--skip-build")
        raw = run(command, env=env, timeout=1500 if build else 180)
        matches = re.findall(r"^FRAME_STEP_MEASUREMENT (\{.*\})$", raw, re.MULTILINE)
        if len(matches) != 1:
            raise RuntimeError("Expected exactly one measured native workload; check test discovery")
        row = json.loads(matches[0])
        if row["scenario"] != case["name"] or row["iterations"] != case["iterations"]:
            raise RuntimeError("Benchmark did not execute the requested workload")
        if case["fullDecode"]:
            if row["frame_counts"] != [150] * case["iterations"]:
                raise RuntimeError("Full decode control did not return all 150 frames")
        else:
            expected = case["position"] + case["direction"] / 30
            if len(row["targets"]) != case["iterations"] or any(
                    value is None or abs(value - expected) > 1e-6 for value in row["targets"]):
                raise RuntimeError(f"Unexpected adjacent timestamp: {row}")
        return row

    for variant in ["baseline", "candidate"]:
        print(f"Building and qualifying {variant}", flush=True)
        measure(variant, cases[0], build=True)
    rows = []
    for case in cases:
        print(f"Measuring {case['name']}", flush=True)
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            pair_rows = {}
            for variant in order:
                row = measure(variant, case)
                row.update(variant=variant, pair=pair, ordinal=len(rows))
                rows.append(row)
                pair_rows[variant] = row
                with (output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            for key in ["targets", "frame_counts", "timestamp_sums"]:
                if pair_rows["baseline"][key] != pair_rows["candidate"][key]:
                    raise RuntimeError(f"Baseline/candidate output mismatch: {case['name']} {key}")

    summary = []
    for case in cases:
        record = {"scenario": case["name"], "pairs": args.pairs}
        for metric in ["wall_ns_per_request", "cpu_ns_per_request", "peak_process_rss_bytes"]:
            values = {variant: [row[metric] for row in rows
                      if row["scenario"] == case["name"] and row["variant"] == variant]
                      for variant in ["baseline", "candidate"]}
            record[metric] = {variant: {"median": statistics.median(value),
                              "min": min(value), "max": max(value)}
                              for variant, value in values.items()}
            record[metric]["paired_reduction_percent_median"] = statistics.median(
                [(1 - after / before) * 100 for before, after in
                 zip(values["baseline"], values["candidate"])])
        summary.append(record)
    save(output / "summary.json", summary)
    save(output / "verification.json", {"rows": len(rows), "outputs_equal": True,
         "expected_adjacent_timestamps_verified": True,
         "full_decode_frame_counts_verified": True, "alternating_order": True})
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
