#!/usr/bin/env python3
"""Compare exact playlist-construction snapshots using fresh workers for every pair."""
import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

BASELINE = "33fff16155c3472960f88e04c72dfdfdefd56dcf"
SOURCES = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylistDiscovery.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
]
CHANGED = set(SOURCES[:2])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def command(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.STDOUT).decode().strip()


def corpus(args):
    cases = {}

    def add(scope, sizes, patterns, orders, subtitles):
        for size in sizes:
            if size > args.max_media_size or (subtitles and size > args.max_subtitle_size):
                continue
            for pattern in patterns:
                for order in orders:
                    id = f"{scope}/{pattern}/{size}/s{subtitles}/{order}"
                    cases[id] = dict(id=id, scope=scope, size=size, pattern=pattern,
                                     order=order, subtitles=subtitles)

    patterns, orders = ["unique", "multilingual", "ties"], ["sorted", "reverse", "shuffled"]
    if args.quick:
        add("make-playlist", [0, 1, 2, 10], ["unique"], ["shuffled"], 0)
        add("make-playlist", [100], patterns, orders, 0)
        add("make-playlist", [10, 100], patterns[:2], ["shuffled"], 2)
        add("make-playlist", [10], ["ties"], ["shuffled"], 2)
        add("public-constructor", [2, 100], patterns, ["shuffled"], 2)
    else:
        add("make-playlist", [0, 1, 2, 10, 100, 1000, 10000], patterns, orders, 0)
        add("make-playlist", [0, 1, 2, 10, 100, 1000], patterns[:2], ["shuffled"], 2)
        # Large equal stems stress quadratic ambiguous-subtitle matching, a
        # different subsystem. Keep small correctness/performance controls only.
        add("make-playlist", [2, 10], ["ties"], ["shuffled"], 2)
        add("public-constructor", [0, 1, 2, 10, 100, 1000], ["unique"], ["shuffled"], 2)
        add("public-constructor", [1000], ["multilingual", "ties"], ["shuffled"], 2)
    return list(cases.values())


class Worker:
    def __init__(self, binary, log):
        self.log = log.open("w")
        try:
            self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=self.log, text=True, bufsize=1)
        except BaseException:
            self.log.close()
            raise

    def request(self, operation, **kwargs):
        self.process.stdin.write(json.dumps(dict(operation=operation, **kwargs)) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"Worker exited ({self.process.poll()}); inspect logs")
        return json.loads(line)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
        self.log.close()


def calibrate(worker, label, case, pair, destination):
    iterations = 1
    while True:
        sample = worker.request("measure", iterations=iterations)
        destination.write(json.dumps(dict(variant=label, pair=pair, scenario=case, **sample)) + "\n")
        if sample["wall_ns"] >= 5_000_000 or iterations >= 1_000_000:
            return sample["wall_ns"] / iterations
        iterations = min(1_000_000, max(iterations + 1, math.ceil(
            iterations * 5_000_000 / max(1, sample["wall_ns"]))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", "--swiftc", default="swiftc", help="Swift compiler path")
    parser.add_argument("--baseline", default=BASELINE, help="Pinned baseline ref")
    parser.add_argument("--output", required=True, type=Path, help="Empty evidence directory")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=50)
    parser.add_argument("--max-media-size", type=int, default=10000)
    parser.add_argument("--max-subtitle-size", type=int, default=1000)
    parser.add_argument("--quick", action="store_true", help="Smaller development corpus, not formal evidence")
    parser.add_argument("--verify-only", action="store_true", help="Compile and compare outputs without timing")
    args = parser.parse_args()
    if (args.pairs < 1 or not math.isfinite(args.target_ms) or args.target_ms <= 0
            or args.max_media_size < 0 or args.max_subtitle_size < 0):
        parser.error("pairs/target-ms must be positive; sizes must be nonnegative")
    here = Path(__file__).resolve().parent
    repo = here.parents[1]
    out = args.output.resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error(f"Evidence directory must be empty: {out}")
    swift = shutil.which(args.swift)
    if not swift:
        parser.error(f"Swift compiler not found: {args.swift}")
    swift = str(Path(swift).absolute())
    out.mkdir(parents=True, exist_ok=True)
    (out / "logs").mkdir()
    baseline = command(["git", "rev-parse", f"{args.baseline}^{{commit}}"], repo)
    manifest = dict(baseline_commit=baseline, candidate_head=command(["git", "rev-parse", "HEAD"], repo),
                    candidate_status=command(["git", "status", "--short"], repo),
                    swift_compiler=swift, swift_version=command([swift, "--version"]),
                    platform=platform.uname()._asdict(), python=sys.version,
                    environment={k: os.environ.get(k) for k in ["LANG", "LC_ALL", "LC_COLLATE", "SWIFT_DETERMINISTIC_HASHING"]},
                    arguments={**vars(args), "output": str(out)},
                    harness_sha256=sha((here / "Harness.swift").read_bytes()),
                    runner_sha256=sha(Path(__file__).read_bytes()),
                    process_policy="Fresh baseline/candidate workers for every timed pair",
                    sources={}, compile_commands={})
    # Retain the exact driver, independent of subsequent worktree edits.
    (out / "run.py").write_bytes(Path(__file__).read_bytes())
    cases = corpus(args)
    edge_cases = [dict(id=f"{scope}/edge/s{subtitles}/{order}", scope=scope, size=21,
                       pattern="edge", order=order, subtitles=subtitles)
                  for scope in ["make-playlist", "public-constructor"]
                  for subtitles in [0, 2] for order in ["sorted", "reverse", "shuffled"]]
    write_json(out / "scenarios.json", cases)
    binaries = {}
    started = time.monotonic()
    for label in ["baseline", "candidate"]:
        build = out / "build" / label
        build.mkdir(parents=True)
        files, entries = [], []
        for source in SOURCES:
            current = label == "candidate" and source in CHANGED
            data = (repo / source).read_bytes() if current else subprocess.check_output(
                ["git", "show", f"{baseline}:{source}"], cwd=repo)
            target = build / Path(source).name
            target.write_bytes(data)
            files.append(str(target))
            entries.append(dict(path=source, sha256=sha(data), origin="working-tree" if current else baseline))
        harness = build / "Harness.swift"
        harness.write_bytes((here / "Harness.swift").read_bytes())
        binary = build / "benchmark"
        compile_args = [swift, "-O", "-whole-module-optimization", "-module-cache-path",
                        str(out / "module-cache"), *files, str(harness), "-o", str(binary)]
        manifest["sources"][label] = entries
        manifest["compile_commands"][label] = compile_args
        write_json(out / "manifest.json", manifest)
        with (out / f"{label}-build.log").open("w") as log:
            subprocess.run(compile_args, check=True, stdout=log, stderr=subprocess.STDOUT)
        binaries[label] = binary
        manifest.setdefault("binaries", {})[label] = dict(path=str(binary), sha256=sha(binary.read_bytes()))
        write_json(out / "manifest.json", manifest)

    # Admit no timed samples until every case has passed complete-output equality.
    workers, verified = {}, []
    try:
        for label, binary in binaries.items():
            workers[label] = Worker(binary, out / "logs" / f"verify-{label}.txt")
        manifest["runtime"] = {label: worker.request("environment") for label, worker in workers.items()}
        write_json(out / "manifest.json", manifest)
        with gzip.open(out / "verification-snapshots.jsonl.gz", "wt", encoding="utf-8") as snapshots:
            for case in cases + edge_cases:
                outputs = {label: worker.request("verify", spec=case)["output"] for label, worker in workers.items()}
                snapshots.write(json.dumps(dict(scenario=case, outputs=outputs), ensure_ascii=False) + "\n")
                equal = outputs["baseline"] == outputs["candidate"]
                verified.append(dict(scenario=case, equal=equal,
                                     output_sha256={k: sha(canonical(v)) for k, v in outputs.items()},
                                     url_order_sha256={k: sha(canonical([i["url"] for i in v["items"]]))
                                                       for k, v in outputs.items()}))
                if not equal:
                    write_json(out / "verification.json", verified)
                    raise RuntimeError(f"Complete-output mismatch: {case['id']}")
        write_json(out / "verification.json", verified)
    finally:
        for worker in workers.values():
            worker.close()
    print(f"Verified {len(verified)} complete-output cases.", flush=True)
    if args.verify_only:
        return

    summaries = []
    with (out / "measurements.jsonl").open("w") as raw, (out / "calibration.jsonl").open("w") as calibration:
        for case_index, case in enumerate(cases):
            samples = {"baseline": [], "candidate": []}
            for pair in range(args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                workers, per_op, pair_samples = {}, {}, {}
                try:
                    # Alternate launch, setup, calibration, and measurement order.
                    for label in order:
                        worker = Worker(binaries[label], out / "logs" / f"{case_index:03d}-{pair:02d}-{label}.txt")
                        workers[label] = worker
                        worker.request("activate", spec=case)
                        per_op[label] = calibrate(worker, label, case, pair, calibration)
                    iterations = min(10_000_000, max(1, round(args.target_ms * 1_000_000 /
                                                            statistics.mean(per_op.values()))))
                    for position, label in enumerate(order):
                        sample = workers[label].request("measure", iterations=iterations)
                        samples[label].append(sample)
                        pair_samples[label] = sample
                        raw.write(json.dumps(dict(scenario=case, variant=label, pair=pair,
                                                  order="AB" if pair % 2 == 0 else "BA", position=position,
                                                  pid=workers[label].process.pid, **sample)) + "\n")
                        raw.flush()
                    if pair_samples["baseline"]["witness"] != pair_samples["candidate"]["witness"]:
                        raise RuntimeError(f"Timed output witness mismatch: {case['id']}")
                finally:
                    for worker in workers.values():
                        worker.close()

            def median_ms(label, clock):
                return statistics.median(s[clock] / s["iterations"] / 1_000_000 for s in samples[label])

            paired = [(a["wall_ns"] / a["iterations"]) / (b["wall_ns"] / b["iterations"])
                      for a, b in zip(samples["baseline"], samples["candidate"])]
            summary = dict(scenario=case, pairs=args.pairs,
                           baseline_ms=median_ms("baseline", "wall_ns"), candidate_ms=median_ms("candidate", "wall_ns"),
                           baseline_cpu_ms=median_ms("baseline", "cpu_ns"), candidate_cpu_ms=median_ms("candidate", "cpu_ns"),
                           paired_speedup_median=statistics.median(paired), paired_speedup_range=[min(paired), max(paired)])
            summary["reduction_percent"] = 100 * (1 - summary["candidate_ms"] / summary["baseline_ms"])
            summaries.append(summary)
            write_json(out / "summary.json", dict(cases=summaries, verified_cases=len(verified),
                                                 elapsed_seconds=time.monotonic() - started))
            print(f"[{case_index + 1}/{len(cases)}] {case['id']}: {summary['baseline_ms']:.4f} -> "
                  f"{summary['candidate_ms']:.4f} ms ({summary['reduction_percent']:+.1f}% reduction)", flush=True)
    print(f"Evidence: {out}", flush=True)


if __name__ == "__main__":
    main()
