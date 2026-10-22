#!/usr/bin/env python3
"""Compare actual state-to-view publication sources against a pinned Git baseline."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "a2de305c8dbcaa81aac1477df7c9a0017c14eae3"
STATE = "Sources/IlliquidCore/Player/PlaybackState.swift"
SOURCES = [
    STATE,
    "Sources/IlliquidCore/Player/PlaybackViewStore.swift",
    "Sources/IlliquidCore/Player/PlaybackModels.swift",
    "Sources/IlliquidCore/Player/PlaybackPhase.swift",
    "Sources/IlliquidCore/Player/PlaybackRecoveryIssue.swift",
    "Sources/IlliquidCore/Player/PictureInPictureState.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Player/MediaTrack.swift",
    "Sources/IlliquidCore/Player/TrackSelectionPreferences.swift",
    "Sources/IlliquidCore/Player/SubtitleFallbackEncoding.swift",
    "Sources/IlliquidCore/Player/VideoPresentationGeometry.swift",
    "Sources/IlliquidCore/Persistence/PlaybackPreferences.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NonDecodePerformance.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/PlaybackStatePublicationTests.swift",
    "Tests/IlliquidCoreTests/TrackSelectionProjectionTests.swift",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Runner:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Output must be new or empty; previous evidence is never overwritten")
        self.out.mkdir(parents=True, exist_ok=True)
        self.evidence = self.out / "evidence"
        self.evidence.mkdir()
        self.env = dict(os.environ)
        self.env["CLANG_MODULE_CACHE_PATH"] = str(self.out / "module-cache")
        self.env["SWIFT_MODULECACHE_PATH"] = str(self.out / "module-cache")
        self.executables = {}
        self.production_hashes = {}

    def command(self, command, timeout=300):
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=self.env,
                                capture_output=True, text=True, timeout=timeout)
        with (self.evidence / "commands.jsonl").open("a") as f:
            f.write(json.dumps({"command": [str(x) for x in command], "returncode": result.returncode,
                                "stderr": result.stderr}) + "\n")
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout

    def build(self, variant, configuration):
        folder = self.out / variant / configuration
        folder.mkdir(parents=True)
        sources = []
        hashes = {}
        for name in SOURCES:
            raw = (self.command(["git", "show", f"{self.args.baseline}:{name}"]).encode()
                   if variant == "baseline" else (ROOT / name).read_bytes())
            hashes[name] = digest(raw)
            # Foundation supplies CGRect/CGSize on Linux. No implementation is changed.
            compiled = raw.replace(b"import CoreGraphics\n", b"#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n")
            path = folder / Path(name).name
            path.write_bytes(compiled)
            sources.append(path)
        flags = ["-O", "-whole-module-optimization"] if configuration == "release" else ["-Onone", "-g"]
        # Both variants use the same linked runtime and native deployment target.
        if platform.system() == "Darwin":
            flags += ["-target", f"{platform.machine()}-apple-macos26.0"]
        common = [self.args.swiftc, "-swift-version", "6", "-warnings-as-errors", *flags]
        self.command([*common, "-emit-library", "-static", "-emit-module", "-enable-testing",
                      "-module-name", "IlliquidCore", *sources,
                      "-emit-module-path", folder / "IlliquidCore.swiftmodule", "-o", folder / "libIlliquidCore.a"])
        exe = folder / "projection-harness"
        self.command([*common, "-D", "PORTABLE_STATE_TESTS", "-I", folder, "-L", folder, "-lIlliquidCore",
                      HERE / "Harness.swift", *[ROOT / p for p in TESTS], "-o", exe])
        receipt = {"variant": variant, "configuration": configuration, "baseline": self.args.baseline,
                   "production_sha256": hashes,
                   "compiled_sha256": {p.name: digest(p.read_bytes()) for p in sources},
                   "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
                   "test_sha256": {p: digest((ROOT / p).read_bytes()) for p in TESTS},
                   "executable_sha256": digest(exe.read_bytes())}
        (self.evidence / f"{variant}-{configuration}-sources.json").write_text(json.dumps(receipt, indent=2) + "\n")
        self.production_hashes[(variant, configuration)] = hashes
        self.executables[(variant, configuration)] = exe
        print("Built", variant, configuration, flush=True)
        return exe

    def validate(self):
        validation = {}
        for configuration in ("debug", "release"):
            traces = []
            for variant in ("baseline", "candidate"):
                exe = self.build(variant, configuration)
                tests = json.loads(self.command([exe, "tests"]))
                (self.evidence / f"{variant}-{configuration}-tests.json").write_text(json.dumps(tests, indent=2) + "\n")
                trace = self.command([exe, "verify"])
                # Keep a compact digest after comparing complete step receipts in memory.
                traces.append(json.loads(trace))
                validation[f"{variant}-{configuration}"] = {
                    "tests_passed": tests["passed"], "trace_sha256": digest(trace.encode()),
                    "trace_steps": len(traces[-1]["steps"]),
                }
            if traces[0] != traces[1]:
                for i, (before, after) in enumerate(zip(traces[0]["steps"], traces[1]["steps"])):
                    if before != after:
                        raise RuntimeError(f"Differential mismatch in {configuration} step {i}: {before} != {after}")
                raise RuntimeError("Differential trace length mismatch")
            before = self.production_hashes[("baseline", configuration)]
            after = self.production_hashes[("candidate", configuration)]
            changed = {name for name in SOURCES if before[name] != after[name]}
            if changed != {STATE}:
                raise RuntimeError(f"Expected only the state implementation to differ, got {sorted(changed)}")
        (self.evidence / "validation.json").write_text(json.dumps(validation, indent=2) + "\n")
        print("Debug/release behavior tests and 4,000-step differential traces match", flush=True)

    def measure(self):
        rows = []
        cases = []
        for audio, subtitle in ((1, 0), (2, 8), (8, 32), (16, 128), (16, 1_024)):
            for workload in ("first", "last", "subtitles_off", "missing"):
                cases.append((workload, audio, subtitle, "connected"))
        for audio, subtitle in ((2, 8), (8, 32), (16, 128)):
            for workload in ("switch", "catalog_refresh"):
                cases.append((workload, audio, subtitle, "connected"))
        cases += [("last", 16, 128, "disconnected"), ("subtitles_off", 16, 128, "disconnected")]
        if self.args.quick:
            cases = [c for c in cases if c[1:3] in ((2, 8), (16, 128))]
        summary = []
        for workload, audio, subtitle, connection in cases:
            iterations = 5_000 if workload == "catalog_refresh" else 20_000
            expected = None
            selected = []
            for repeat in range(self.args.pairs):
                order = ("baseline", "candidate") if repeat % 2 == 0 else ("candidate", "baseline")
                for process_order, variant in enumerate(order):
                    row = json.loads(self.command([self.executables[(variant, "release")], "bench",
                                                  workload, audio, subtitle, iterations, connection]))
                    if expected is not None and row["final"] != expected:
                        raise RuntimeError(f"Benchmark result mismatch: {workload} {audio} {subtitle} {connection}")
                    expected = row["final"]
                    row.update(variant=variant, repeat=repeat, process_order=process_order)
                    rows.append(row)
                    selected.append(row)
                    with (self.evidence / "measurements.jsonl").open("a") as f:
                        f.write(json.dumps(row, sort_keys=True) + "\n")
            stats = {}
            for variant in ("baseline", "candidate"):
                values = [r["elapsed_ns"] / r["iterations"] for r in selected if r["variant"] == variant]
                cpu = [r["cpu_ns"] / r["iterations"] for r in selected if r["variant"] == variant]
                stats[variant] = {"median_ns": statistics.median(values), "min_ns": min(values),
                                  "max_ns": max(values), "median_cpu_ns": statistics.median(cpu), "samples": len(values)}
            change = (stats["candidate"]["median_ns"] / stats["baseline"]["median_ns"] - 1) * 100
            summary.append({"workload": workload, "audio_count": audio, "subtitle_count": subtitle,
                            "connected": connection == "connected", "change_percent": change, **stats})
            print(workload, audio, subtitle, connection, round(stats["baseline"]["median_ns"], 1),
                  "->", round(stats["candidate"]["median_ns"], 1), "ns", f"{change:+.1f}%", flush=True)
        # Check exact process identities/order; no outliers or failed rows are discarded.
        assert len(rows) == len(cases) * self.args.pairs * 2
        for i in range(0, len(rows), 2):
            pair = rows[i:i + 2]
            assert [r["process_order"] for r in pair] == [0, 1]
            assert [r["variant"] for r in pair] == (["baseline", "candidate"] if pair[0]["repeat"] % 2 == 0 else ["candidate", "baseline"])
        (self.evidence / "summary.json").write_text(json.dumps({"observations": len(rows), "groups": summary}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("Use a positive even number of pairs (at least two) for balanced AB/BA order")
    runner = Runner(args)
    env = {"platform": platform.platform(), "architecture": platform.machine(),
           "compiler": runner.command([args.swiftc, "--version"]).strip(),
           "baseline": args.baseline, "head": runner.command(["git", "rev-parse", "HEAD"]).strip(),
           "status": runner.command(["git", "status", "--short"]),
           "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
           "runner_sha256": digest(Path(__file__).read_bytes())}
    (runner.evidence / "environment.json").write_text(json.dumps(env, indent=2) + "\n")
    runner.validate()
    if not args.tests_only:
        runner.measure()


if __name__ == "__main__":
    main()
