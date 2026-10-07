#!/usr/bin/env python3
"""Run opt-in native thumbnail probes sequentially; never launch the installed app.
Build first: swift test --filter ThumbnailOptimizationQualificationTests
"""
import hashlib
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess

MODES = {"baseline": (2, False, False), "one-thread": (1, False, False),
         "four-threads": (4, False, False), "planar": (2, True, False),
         "foreground": (2, False, True), "indexed": (2, False, False),
         "packet-retain": (2, False, False), "packet-prefetch": (2, False, False)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--mode", action="append", choices=MODES)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--direct-runner", action="store_true", help="Bypass repeated SwiftPM manifest planning on macOS")
    parser.add_argument("--packet-workload", action="store_true")
    parser.add_argument("--refill-delay-ms", type=float, default=0, help="Synthetic delay after an AVIO refill, not a disk/NAS benchmark")
    parser.add_argument("--batch", action="store_true", help="Use the first two fixtures, 12 samples each")
    parser.add_argument("--batch-size", type=int, action="append")
    args = parser.parse_args()
    if not 0 <= args.refill_delay_ms <= 10 or (args.packet_workload and args.batch):
        parser.error("refill delay must be 0–10 ms; packet workload cannot use batch mode")
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
        bundle = Path(f".build/{args.configuration}/IlliquidPackageTests.xctest/Contents/MacOS/IlliquidPackageTests").resolve()
        command = [str(helper), "--test-bundle-path", str(bundle), "--testing-library", "swift-testing",
                   "--no-parallel", "--filter", "ThumbnailOptimizationQualificationTests"]
    (output / "protocol.json").write_text(json.dumps({
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "test_binary_sha256": hashlib.sha256(Path(f".build/{args.configuration}/IlliquidPackageTests.xctest/Contents/MacOS/IlliquidPackageTests").read_bytes()).hexdigest(),
        "fixtures": {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in args.fixture},
        "configuration": args.configuration, "packet_workload": args.packet_workload,
        "simulated_refill_delay_ms": args.refill_delay_ms, "runs": args.runs,
        "modes": modes, "limitations": ["warm OS file pages", "AVIO bytes include filesystem cache hits", "no concurrent playback"]
    }, indent=2))
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
                               ILLIQUID_PREVIEW_KEYFRAME_INDEX=str(int(mode in ("indexed", "packet-retain", "packet-prefetch"))),
                               ILLIQUID_PREVIEW_PACKET_WORKLOAD=str(int(args.packet_workload)),
                               ILLIQUID_PREVIEW_PACKET_BYTES=str(32 * 1024 * 1024 if mode.startswith("packet-") else 0),
                               ILLIQUID_PREVIEW_READAHEAD_SECONDS="0.5" if mode == "packet-prefetch" else "0",
                               ILLIQUID_PREVIEW_REFILL_DELAY_MS=str(args.refill_delay_ms))
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
                    if args.packet_workload:
                        row.update(demux_bytes=sum(s["demuxBytesRead"] for s in data["stages"]),
                                   read_ms=sum(s["packetReadMilliseconds"] for s in data["stages"]),
                                   replayed_packets=sum(s["replayedPackets"] for s in data["stages"]),
                                   replay_seeks=sum(s["replayedPacketWindow"] for s in data["stages"]),
                                   retained_bytes_peak=max(s["retainedPacketBytes"] for s in data["stages"]),
                                   prefetch_ms=sum(s["prefetchMilliseconds"] for s in data["stages"]),
                                   backward_median_ms=statistics.median(calls[i]["wall_ms"] for i in (1,2,3,5,6,7,9,10,11)))
                    if not args.packet_workload and not args.batch and row["missing_images"] == 0:
                        row["warm_decode_median_ms"] = statistics.median(calls[i]["wall_ms"] for i in (1, 2, 4, 5))
                        row["ram_hit_median_ms"] = statistics.median(calls[i]["wall_ms"] for i in (3, 6))
                    rows.append(row)
                    (output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
                    print(json.dumps(row), flush=True)

    return int(any(row["exit_code"] != 0 or row["missing_images"] or not row["hashes_match_first_run"] for row in rows))

if __name__ == "__main__":
    raise SystemExit(main())
