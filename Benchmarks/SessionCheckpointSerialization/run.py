#!/usr/bin/env python3
"""Benchmark real session saves and the extracted encoding block against pinned main.

The Linux-only LifecyclePerformance shim disables a macOS signpost/bundle gate;
no persistence, Codable, URL, playlist, locking, or filesystem logic is replaced.
All timings are component measurements, not player CPU or durability guarantees.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
STORE = "Persistence/PlaybackSessionStore.swift"
SOURCES = [STORE, "Persistence/LegacyPreferencesMigration.swift", "Player/MediaSource.swift",
           "Playlist/FolderPlaylist.swift", "Playlist/PlaylistMutation.swift",
           "Utilities/NaturalFilenameOrdering.swift", "Utilities/NormalizedFileURL.swift",
           "Utilities/LifecyclePerformance.swift"]
CASES = [(0, False), (1, False), (25, False), (25, True),
         (250, False), (250, True), (2500, False), (2500, True)]


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Runner:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Output must be new or empty")
        self.evidence = self.out / "evidence"
        self.evidence.mkdir(parents=True)
        self.env = dict(os.environ)
        self.env.update(CLANG_MODULE_CACHE_PATH=str(self.out / "module-cache"),
                        SWIFT_MODULECACHE_PATH=str(self.out / "module-cache"))
        self.hashes = {}
        self.executables = {}

    def write(self, name, value):
        (self.evidence / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, command, timeout=300):
        command = [str(x) for x in command]
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"command": command, "returncode": result.returncode,
                                     "stdout": result.stdout, "stderr": result.stderr}) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def build(self, variant):
        stage = self.out / variant
        core = stage / "Sources/IlliquidCore"
        harness = stage / "Sources/SessionSerializationBenchmark"
        tests = stage / "Tests/IlliquidCoreTests"
        for directory in (core, harness, tests):
            directory.mkdir(parents=True)
        raw_sources, compiled = {}, {}
        for name in SOURCES:
            path = "Sources/IlliquidCore/" + name
            raw = (self.command(["git", "show", f"{BASELINE}:{path}"]).encode()
                   if variant == "baseline" else (ROOT / path).read_bytes())
            raw_sources[name] = raw
            value = raw
            if platform.system() != "Darwin" and name.endswith("/LifecyclePerformance.swift"):
                value = b"public enum LifecyclePerformance { public static let isEnabled = false }\n"
            destination = core / Path(name).name
            destination.write_bytes(value)
            compiled[name] = digest(value)
        # Extract the production statements rather than hand-writing an encoder variant.
        source = raw_sources[STORE].decode()
        match = re.search(r"let encoder = JSONEncoder\(\)\n.*?let data = try encoder.encode\(session\)",
                          source, flags=re.S)
        if not match:
            raise RuntimeError("Session encoding changed; review the probe extraction")
        probe = ("import Foundation\nimport IlliquidCore\n@inline(never)\n"
                 "func encodeSession(_ session: PlaybackSessionRecord) throws -> Data {\n"
                 + match.group(0) + "\nreturn data\n}\n")
        (harness / "EncoderProbe.swift").write_text(probe)
        shutil.copyfile(HERE / "Harness.swift", harness / "Harness.swift")
        test_source = ROOT / "Tests/IlliquidCoreTests/PlaybackSessionStoreTests.swift"
        shutil.copyfile(test_source, tests / test_source.name)
        (stage / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SessionSerializationBenchmark", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .executableTarget(name: "SessionSerializationBenchmark", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
        self.command([self.args.swift, "build", "--package-path", stage, "-c", "release", "--jobs", "2"])
        bin_path = self.command([self.args.swift, "build", "--package-path", stage,
                                 "-c", "release", "--show-bin-path"]).strip()
        self.executables[variant] = Path(bin_path) / "SessionSerializationBenchmark"
        self.hashes[variant] = {name: digest(raw) for name, raw in raw_sources.items()}
        self.write(f"{variant}-sources.json", {
            "production_sha256": self.hashes[variant], "compiled_sha256": compiled,
            "encoder_probe": probe, "encoder_probe_sha256": digest(probe.encode()),
            "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
            "tests_sha256": digest(test_source.read_bytes()),
            "binary_sha256": digest(self.executables[variant].read_bytes()),
            "linux_disabled_lifecycle_shim": platform.system() != "Darwin",
        })
        print("Built", variant, flush=True)

    def validate(self):
        for variant in ("baseline", "candidate"):
            self.build(variant)
        changed = {name for name in SOURCES if self.hashes["baseline"][name] != self.hashes["candidate"][name]}
        if changed != {STORE}:
            raise RuntimeError(f"Only the session store may differ; found {sorted(changed)}")
        verification = {}
        for variant in ("baseline", "candidate"):
            directory = self.out / variant / "verification"
            verification[variant] = json.loads(self.command([self.executables[variant], "verify", directory]))
        comparisons = []
        for count, rich in CASES:
            name = f"{count}-{'rich' if rich else 'plain'}.json"
            paths = [self.out / v / "verification" / name for v in ("baseline", "candidate")]
            before, after = [json.loads(path.read_bytes()) for path in paths]
            if before != after:
                raise RuntimeError(f"Complete JSON state differs for {name}")
            comparisons.append({"case": name, "equal": True,
                                "semantic_sha256": digest(json.dumps(before, sort_keys=True).encode()),
                                "byte_sha256": [digest(path.read_bytes()) for path in paths]})
        for configuration in ("debug", "release"):
            output = self.command([self.args.swift, "test", "--package-path", self.out / "candidate",
                                   "-c", configuration, "--jobs", "2", "--filter", "PlaybackSessionStoreTests"])
            (self.evidence / f"tests-{configuration}.log").write_text(output)
        self.write("validation.json", {"store_and_encoder": verification,
                                       "complete_json_comparisons": comparisons,
                                       "candidate_test_configurations": ["debug", "release"]})
        print("Complete JSON parity and debug/release session-store tests passed", flush=True)

    def measure(self):
        groups = []
        for mode in ("save", "encode"):
            for count, rich in CASES:
                style = "rich" if rich else "plain"
                def run(variant, iterations):
                    return json.loads(self.command([self.executables[variant], "bench", mode, count,
                        style, iterations, self.out / variant / "timed"], timeout=300))
                pilot = run("baseline", 4)
                iterations = min(100_000, max(1, math.ceil(self.args.target_ms * 1_000_000
                                                          * 4 / pilot["elapsed_ns"])))
                with (self.evidence / "calibrations.jsonl").open("a") as stream:
                    stream.write(json.dumps({"pilot": pilot, "iterations": iterations}) + "\n")
                rows = []
                expected = None
                for pair in range(self.args.pairs):
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    for process_order, variant in enumerate(order):
                        row = run(variant, iterations)
                        final = {key: row[key] for key in ("encoded_bytes", "checksum", "final_position", "round_trip")}
                        if expected is not None and final != expected:
                            raise RuntimeError(f"Timed result differs for {mode} {count} {style}")
                        expected = final
                        row.update(variant=variant, pair=pair, process_order=process_order)
                        rows.append(row)
                        with (self.evidence / "measurements.jsonl").open("a") as stream:
                            stream.write(json.dumps(row, sort_keys=True) + "\n")
                summary = {"mode": mode, "items": count, "rich": rich, "iterations": iterations}
                for metric in ("elapsed_ns", "cpu_ns"):
                    values = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                              for variant in ("baseline", "candidate")}
                    medians = {variant: statistics.median(samples) for variant, samples in values.items()}
                    paired = []
                    for pair in range(self.args.pairs):
                        sample = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                        paired.append((sample["candidate"] / sample["baseline"] - 1) * 100)
                    summary[metric] = {"median_per_operation": medians,
                        "range_per_operation": {v: [min(x), max(x)] for v, x in values.items()},
                        "median_change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                        "paired_change_percent": paired, "median_paired_change_percent": statistics.median(paired)}
                groups.append(summary)
                wall = summary["elapsed_ns"]["median_per_operation"]
                cpu = summary["cpu_ns"]["median_per_operation"]
                print(mode, count, style,
                      f'wall {wall["baseline"]:.1f} -> {wall["candidate"]:.1f} ns/op '
                      f'({summary["elapsed_ns"]["median_change_percent"]:+.2f}%); '
                      f'CPU {cpu["baseline"]:.1f} -> {cpu["candidate"]:.1f} ns/op '
                      f'({summary["cpu_ns"]["median_change_percent"]:+.2f}%)', flush=True)
        self.write("summary.json", {"groups": groups, "observations": len(groups) * self.args.pairs * 2,
                                    "pairs": self.args.pairs, "target_ms": self.args.target_ms})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even number of pairs >= 2 and a positive finite target-ms")
    runner = Runner(args)
    hardware = {"processor": platform.processor(), "logical_cpus": os.cpu_count()}
    if platform.system() == "Darwin":
        hardware.update(sw_vers=runner.command(["sw_vers"]).strip(),
                        cpu_model=runner.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
                        hardware_model=runner.command(["sysctl", "-n", "hw.model"]).strip())
    runner.write("environment.json", {"platform": platform.platform(), "machine": platform.machine(),
        "hardware": hardware,
        "compiler": runner.command([args.swift, "--version"]).strip(), "baseline": BASELINE,
        "head": runner.command(["git", "rev-parse", "HEAD"]).strip(),
        "status": runner.command(["git", "status", "--short"]),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()}})
    runner.validate()
    if not args.tests_only:
        runner.measure()


if __name__ == "__main__":
    main()
