#!/usr/bin/env python3
"""Run opt-in native seek/thumbnail measurements; never launch Illiquid.app."""
import argparse
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import statistics
import subprocess


def distribution(values):
    if not values:
        return {"n": 0}
    ordered = sorted(values)
    return {"n": len(values), "median_ms": statistics.median(values),
            "p95_ms": ordered[math.ceil(len(values) * .95) - 1], "max_ms": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--targets", default="1.5,8.5,9,9.5,10.5,18.5,2,2.5,3")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--thumbnail-only", action="store_true")
    parser.add_argument("--native-only", action="store_true")
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--disable-nonref", action="store_true", help="Baseline exact seeks without decoder-level non-reference skipping")
    parser.add_argument("--disable-software-burst", action="store_true", help="Keep expensive exact seeks on the hardware decoder")
    parser.add_argument("--baseline", action="store_true", help="Use BGRA thumbnails with a seek for every cache miss")
    parser.add_argument("--observe-renderer", action="store_true", help="Compare renderer readback with a separately decoded reference; warms caches")
    parser.add_argument("--show-window", action="store_true", help="Explicitly show the native test surface (does not launch Illiquid.app)")
    args = parser.parse_args()
    if args.native_only and args.thumbnail_only:
        parser.error("native-only and thumbnail-only are mutually exclusive")
    if args.show_window and not args.observe_renderer:
        parser.error("show-window requires observe-renderer")
    if not 1 <= args.repeats <= 20:
        parser.error("repeats must be between 1 and 20")
    try:
        targets = [float(value) for value in args.targets.split(",")]
    except ValueError:
        parser.error("targets must be comma-separated seconds")
    if not targets or any(not math.isfinite(value) or value < 0 for value in targets):
        parser.error("targets must be finite nonnegative seconds within the fixture duration")
    fixtures = [path.resolve(strict=True) for path in args.fixture]
    if any(not path.is_file() for path in fixtures):
        parser.error("each fixture must be a file")
    repository = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("ILLIQUID_SEEK_PROFILE_")}
    selection = "profileThumbnailStages" if args.thumbnail_only else "profileNativeSeekStages" if args.native_only else "SeekPerformanceQualification"
    configuration = ["-c", "release"] if args.release else []
    if not args.skip_build:
        with (output / "build.log").open("w") as log:
            subprocess.run(["swift", "test", *configuration, "--no-parallel", "--filter", selection],
                           cwd=repository, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    summaries = []
    failed_runs = 0
    for index, fixture in enumerate(fixtures):
        callers, stages, seeks = [], [], []
        for repeat in range(args.repeats):
            prefix = output / f"fixture-{index}-run-{repeat}"
            run_env = dict(env, ILLIQUID_SEEK_PROFILE_FIXTURE=str(fixture),
                           ILLIQUID_SEEK_PROFILE_RESULT=str(prefix),
                           ILLIQUID_SEEK_PROFILE_TARGETS=args.targets,
                           ILLIQUID_SEEK_PROFILE_BASELINE="1" if args.baseline else "0",
                           ILLIQUID_SEEK_PROFILE_DISABLE_NONREF="1" if args.disable_nonref else "0",
                           ILLIQUID_SEEK_PROFILE_DISABLE_SOFTWARE_BURST="1" if args.disable_software_burst else "0",
                           ILLIQUID_SEEK_PROFILE_OBSERVE_RENDERER="1" if args.observe_renderer else "0",
                           ILLIQUID_SEEK_PROFILE_SHOW_WINDOW="1" if args.show_window else "0")
            with Path(str(prefix) + ".log").open("w") as log:
                result = subprocess.run(["swift", "test", *configuration, "--skip-build", "--no-parallel",
                                         "--filter", selection], cwd=repository, env=run_env,
                                        stdout=log, stderr=subprocess.STDOUT)
            failed_runs += result.returncode != 0
            for suffix in ("-thumbnail.json", "-seek.json"):
                path = Path(str(prefix) + suffix)
                if not path.exists():
                    continue
                data = json.loads(path.read_text())
                callers.extend(data.get("callers", []))
                stages.extend(data.get("stages", []))
                seeks.extend(data.get("samples", []))
            print(f"{fixture.name} process {repeat + 1}/{args.repeats}: exit {result.returncode}", flush=True)
        digest = hashlib.sha256()
        with fixture.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        summaries.append({"fixture": str(fixture), "bytes": fixture.stat().st_size,
            "sha256": digest.hexdigest(),
            "thumbnail_attempts": len(callers),
            "thumbnail_unavailable": sum(not row["available"] for row in callers),
            "thumbnail_missing_decode_records": max(0, len(callers) - len(stages)),
            "thumbnail_all_callers": distribution([row["caller_ms"] for row in callers]),
            "thumbnail_forward_continuations": sum(row["continuedForward"] for row in stages),
            "thumbnail_output_frames": sum(row["frames"] for row in stages),
            "thumbnail_decoded_frames": sum(row["frames"] + row.get("discardedBeforeOutput", 0)
                                             - int(row.get("usedEOFFallback", False)) for row in stages),
            "seek_attempts": len(seeks), "seek_incomplete": sum(not row["completed"] for row in seeks),
            "verified_renderer_readbacks": sum(row.get("renderer_readback") == "matched-reference" for row in seeks),
            "command_to_verified_readback": distribution([row["command_to_verified_readback_ms"] for row in seeks
                                                           if "command_to_verified_readback_ms" in row]),
            "command_to_observed_preroll": distribution([row["command_to_observed_preroll_ms"] for row in seeks]),
            "native_to_preroll": distribution([row["prerollCompleted_ms"] for row in seeks
                                                if "prerollCompleted_ms" in row])})
    report = {"host": platform.platform(), "baseline": args.baseline,
              "configuration": "release" if args.release else "debug",
              "decoder_nonref_skipping": not args.disable_nonref,
              "software_seek_acceleration": not args.disable_software_burst,
              "cache_conditions": "Fresh test process each run; OS filesystem/driver caches uncontrolled",
              "endpoint": "Native command/preroll and thumbnail availability; physical input/output unmeasured",
              "failed_test_processes": failed_runs, "fixtures": summaries}
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return int(failed_runs != 0)


if __name__ == "__main__":
    raise SystemExit(main())
