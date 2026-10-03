#!/usr/bin/env python3
"""Serial, opt-in release render profiles; generated media stays outside evidence.

Build first: swift build -c release --product SuperplayrRenderProfile
Then: python3 Scripts/profile-rendering.py --output QualificationArtifacts/render
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def validate(result):
    final = result["final_diagnostic"]
    playing = [p for p in result["phases"] if p["phase"].startswith("playing")]
    paused = [p for p in result["phases"] if p["phase"].startswith("paused")]
    return {
        "no_renderer_failure": final.get("rendererFailure") is None,
        "no_software_pool_timeout": final["softwarePoolTimeouts"] == 0,
        "video_queue_within_capacity": final["peakVideoFrameQueueDepth"] <= 12,
        "playing_clock_tracks_wall_time": all(.85 * p["wall_s"] < p["renderer_advance_s"] < 1.15 * p["wall_s"] for p in playing),
        "paused_clock_holds": all(abs(p["renderer_advance_s"]) < .1 for p in paused),
        "software_override_honored": not result["forced_software"] or final["ffmpegPixelFormat"] != "videotoolbox_vld",
    }


def summarize(result):
    phases = []
    for phase in result["phases"]:
        rows = [s for s in result["samples"] if s["phase"] == phase["phase"]]
        phases.append({**phase,
            "rss_peak_mib": max(s["rss_bytes"] for s in rows) / 2**20,
            "rss_end_minus_start_mib": (rows[-1]["rss_bytes"] - rows[0]["rss_bytes"]) / 2**20,
            "heap_peak_mib": max(s["heap_bytes"] for s in rows) / 2**20,
            "footprint_peak_mib": (max(s["footprint_bytes"] for s in rows) / 2**20
                if all(s["footprint_bytes"] is not None for s in rows) else None),
            "heartbeat_p95_ms": percentile([s["heartbeat_late_ms"] for s in rows], .95),
            "heartbeat_max_ms": max(s["heartbeat_late_ms"] for s in rows),
            "submitted_delta": rows[-1]["submitted"] - rows[0]["submitted"],
            "starvations_delta": rows[-1]["starvations"] - rows[0]["starvations"],
            "window_visible_samples": sum(s["window_occlusion_visible"] for s in rows),
            "samples": len(rows)})
    return {k: v for k, v in result.items() if k not in ("samples", "phases")} | {
        "phases": phases, "checks": validate(result)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--case", action="append", dest="selected_cases",
                        choices=["h264-1080p", "h264-4k", "hevc-1080p10", "captions", "caption-control", "software-planar", "software-bgra"])
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases = [
        ("h264-1080p", "TestFixtures/SeekPerformance/h264-1080p-gop10.mp4", {}),
        ("h264-4k", "TestFixtures/SeekPerformance/h264-4k-gop10.mp4", {}),
        ("hevc-1080p10", "TestFixtures/SeekPerformance/hevc-1080p10-gop10.mkv", {}),
        ("captions", "TestFixtures/Generated/long-caption.mkv", {}),
        ("caption-control", "TestFixtures/Generated/long-h264-av-sync.mkv", {}),
        ("software-planar", "TestFixtures/SeekPerformance/h264-1080p-gop10.mp4",
            {"SUPERPLAYR_RENDER_PROFILE_SOFTWARE": "1"}),
        ("software-bgra", "TestFixtures/SeekPerformance/h264-1080p-gop10.mp4",
            {"SUPERPLAYR_RENDER_PROFILE_SOFTWARE": "1", "SUPERPLAYR_RENDER_PROFILE_BGRA": "1"}),
    ]
    if args.selected_cases:
        cases = [case for case in cases if case[0] in args.selected_cases]
    evidence = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "build_configuration": "release", "fixtures": {}, "runs": []}
    for _, relative, _ in cases:
        fixture = root / relative
        if relative not in evidence["fixtures"]:
            evidence["fixtures"][relative] = {
                "sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
                "probe": json.loads(subprocess.check_output(["ffprobe", "-v", "error",
                    "-show_entries", "stream=codec_name,width,height,pix_fmt,r_frame_rate",
                    "-show_entries", "format=duration", "-of", "json", str(fixture)]))}
    for repeat in range(args.repeats):
        # Reverse the second pass to reduce a fixed ordering advantage.
        for name, relative, overrides in (cases if repeat % 2 == 0 else list(reversed(cases))):
            label = f"{name}-{repeat + 1}"
            destination = output / f"{label}.json"
            env = {k: v for k, v in os.environ.items() if not k.startswith("SUPERPLAYR_RENDER_PROFILE_")}
            env.update(overrides)
            env.update(SUPERPLAYR_RENDER_PROFILE_FIXTURE=str(root / relative),
                       SUPERPLAYR_RENDER_PROFILE_RESULT=str(destination))
            command = [str(root / ".build/release/SuperplayrRenderProfile")]
            print(f"Profiling {label}", flush=True)
            with (output / f"{label}.log").open("w") as log:
                subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=120)
            result = summarize(json.loads(destination.read_text()))
            evidence["runs"].append({"label": label, "command": command, **result})
            (output / "summary.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
            if not all(result["checks"].values()):
                raise RuntimeError(f"{label} failed qualification checks: {result['checks']}")
            play = next(p for p in result["phases"] if p["phase"] == "playing-visible")
            print(f"  CPU {play['cpu_percent_one_core']:.1f}% / RSS {play['rss_peak_mib']:.1f} MiB / "
                  f"heartbeat p95 {play['heartbeat_p95_ms']:.2f} ms", flush=True)


if __name__ == "__main__":
    main()
