#!/usr/bin/env python3
"""Run opt-in native thumbnail probes sequentially; never launch the installed app.
Build first: swift test --filter ThumbnailOptimizationQualificationTests
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess

MODES = {"baseline": (2, False, False), "one-thread": (1, False, False),
         "four-threads": (4, False, False), "planar": (2, True, False),
         "foreground": (2, False, True), "indexed": (2, False, False)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--mode", action="append", choices=MODES)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--direct-runner", action="store_true", help="Bypass repeated SwiftPM manifest planning on macOS")
    parser.add_argument("--batch", action="store_true", help="Use the first two fixtures, 12 samples each")
    parser.add_argument("--batch-size", type=int, action="append")
    args = parser.parse_args()
    if args.runs < 1 or (args.batch and len(args.fixture) < 2):
        parser.error("runs must be positive; batch needs two fixtures")
    if any(not file.is_file() for file in args.fixture):
        parser.error("every fixture must exist")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output must be empty to preserve earlier receipts")
    output.mkdir(parents=True, exist_ok=True)
    modes = args.mode or ["indexed"]
    chunks = args.batch_size or ([4] if args.batch else [1])
    fixtures = args.fixture[:1] if args.batch else args.fixture
    command = ["swift", "test", "-c", args.configuration, "--skip-build", "--no-parallel",
               "--filter", "ThumbnailOptimizationQualificationTests"]
    if args.direct_runner:
        swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
        helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
        bundle = Path(f".build/{args.configuration}/SuperplayrPackageTests.xctest/Contents/MacOS/SuperplayrPackageTests").resolve()
        command = [str(helper), "--test-bundle-path", str(bundle), "--testing-library", "swift-testing",
                   "--no-parallel", "--filter", "ThumbnailOptimizationQualificationTests"]
    rows = []
    references = {}
    for run in range(args.runs):
        for fixture_index, fixture in enumerate(fixtures):
            for mode in (modes if run % 2 == 0 else list(reversed(modes))):
                for chunk in chunks:
                    name = f"{fixture_index}-{fixture.stem}-{mode}-chunk{chunk}-{run}"
                    env = {k: v for k, v in os.environ.items() if not k.startswith("ILLIQUID_PREVIEW_")}
                    threads, planar, foreground = MODES[mode]
                    env.update(ILLIQUID_PREVIEW_FIXTURE=str(fixture.resolve()),
                               ILLIQUID_PREVIEW_RECEIPT=str(output / f"{name}.json"),
                               ILLIQUID_PREVIEW_THREADS=str(threads),
                               ILLIQUID_PREVIEW_PLANAR=str(int(planar)),
                               ILLIQUID_PREVIEW_FOREGROUND_PRIORITY=str(int(foreground)),
                               ILLIQUID_PREVIEW_KEYFRAME_INDEX=str(int(mode == "indexed")))
                    if args.batch:
                        env.update(ILLIQUID_PREVIEW_SECOND_FIXTURE=str(args.fixture[1].resolve()),
                                   ILLIQUID_PREVIEW_BATCH_SIZE=str(chunk))
                    with (output / f"{name}.log").open("w") as log:
                        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
                    if not (output / f"{name}.json").exists():
                        raise RuntimeError(f"Probe failed without a receipt: {name}, exit {result.returncode}")
                    data = json.loads((output / f"{name}.json").read_text())
                    calls = data["requests"]
                    hashes = {(r["file"], r["target"]): r.get("sha256") for r in calls}
                    ref_key = str(fixture)
                    references.setdefault(ref_key, hashes)
                    row = {"fixture": fixture.name, "mode": mode, "exit_code": result.returncode,
                           "missing_images": sum(not r["available"] for r in calls), "chunk": chunk, "run": run,
                           "first_ms": calls[0]["wall_ms"], "batch_ms": data["batch_wall_ms"],
                           "cpu_ms": data["batch_cpu_ms"],
                           "decoder_opens": sum(not s["reusedContext"] for s in data["stages"]),
                           "hashes_match_first_run": hashes == references[ref_key]}
                    if not args.batch and row["missing_images"] == 0:
                        row["warm_decode_median_ms"] = statistics.median(calls[i]["wall_ms"] for i in (1, 2, 4, 5))
                        row["ram_hit_median_ms"] = statistics.median(calls[i]["wall_ms"] for i in (3, 6))
                    rows.append(row)
                    (output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
                    print(json.dumps(row), flush=True)

    return int(any(row["exit_code"] != 0 or row["missing_images"] for row in rows))

if __name__ == "__main__":
    raise SystemExit(main())
