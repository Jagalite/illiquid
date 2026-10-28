#!/usr/bin/env python3
"""Measure complete production checkpoint construction with one identity change."""
from __future__ import annotations

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
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PLAYER = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
CORE = [
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift",
]
CORE_TESTS = [
    "PlaylistDeduplicationTests.swift", "PlaylistSessionRecordTests.swift",
    "PlaylistMutationTests.swift", "PlaylistOrderRestorationTests.swift",
    "FolderPlaylistTests.swift", "NaturalFilenameOrderingTests.swift",
]
PLAYER_TEST = "Tests/IlliquidPlayerTests/PlaybackCheckpointWriterTests.swift"
CASES = [
    (0, "missing"), (1, "first"), (1, "missing"),
    (32, "first"), (32, "last"), (32, "missing"),
    (1000, "first"), (1000, "middle"), (1000, "last"), (1000, "missing"),
    (10000, "first"), (10000, "last"), (10000, "missing"),
    (1000, "remote"), (1000, "invalid"),
]


def digest(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("Output must be new or empty")
        self.commands = []
        self.manifest = {}
        self.binaries = {}
        self.reference = None
        self.tests = []
        self.summaries = []
        self.swift = shutil.which("swift")
        self.swiftc = shutil.which("swiftc")
        if not self.swift or not self.swiftc:
            raise RuntimeError("swift and swiftc must be on PATH")

    def save(self, name, value):
        data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        path = self.output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if name.endswith(".gz"):
            path.write_bytes(gzip.compress(data, mtime=0))
        else:
            path.write_bytes(data)

    def command(self, arguments, *, cwd=ROOT, log=None, env=None):
        argv = [str(value) for value in arguments]
        start = time.monotonic()
        completed = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                                   text=True, timeout=600)
        self.commands.append({
            "argv": argv, "cwd": str(cwd), "returncode": completed.returncode,
            "elapsed_seconds": time.monotonic() - start,
            "stdout_sha256": digest(completed.stdout),
            "stderr_sha256": digest(completed.stderr), "log": log,
        })
        self.save("commands.json", self.commands)
        if log:
            path = self.output / log
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(completed.stdout + completed.stderr)
        if completed.returncode:
            raise RuntimeError(
                f"Command failed ({completed.returncode}): {argv}\n"
                f"{completed.stdout[-4000:]}\n{completed.stderr[-6000:]}"
            )
        return completed.stdout

    def prepare(self):
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        if kyoto.exists() and not self.args.kyoto_queued:
            raise RuntimeError("Submit this complete command through Kyoto with --kyoto-queued")
        print("Kyoto queued" if kyoto.exists() else
              "Kyoto unavailable on this host; using serialized isolated component builds",
              flush=True)
        self.manifest = {
            "baseline_revision": BASELINE,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "working_tree_status": self.command(["git", "status", "--short"]),
            "platform": platform.platform(), "machine": platform.machine(),
            "cpu_count": os.cpu_count(), "swift": self.command([self.swiftc, "--version"]).strip(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "arguments": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(self.args).items()},
            "sources": {}, "tests": {}, "artifacts": {},
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
            "qualification": "isolated production checkpoint and playlist component",
        }
        if platform.system() == "Darwin":
            self.manifest["os"] = self.command(["sw_vers"]).strip()
            self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
            self.manifest["sdk"] = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        else:
            cpu = Path("/proc/cpuinfo")
            self.manifest["cpu"] = next(
                (line.split(":", 1)[1].strip() for line in cpu.read_text().splitlines()
                 if line.startswith("model name")), "unknown"
            ) if cpu.exists() else "unknown"
        for variant in ("baseline", "candidate"):
            directory = self.output / "sources" / variant
            directory.mkdir(parents=True)
            self.manifest["sources"][variant] = {}
            for path in [*CORE, PLAYER]:
                raw = (self.command(["git", "show", f"{BASELINE}:{path}"])
                       if variant == "baseline" else (ROOT / path).read_text())
                compiled = raw
                if path.endswith("PlaybackSessionStore.swift"):
                    marker = "\n/// A versioned, atomic Application Support document"
                    if raw.count(marker) != 1:
                        raise RuntimeError("Review PlaybackSessionRecord/protocol extraction boundary")
                    # Complete record and storage protocol, verbatim; omit only
                    # the unrelated atomic disk store and its macOS diagnostics.
                    compiled = raw.split(marker)[0] + "\n"
                (directory / Path(path).name).write_text(compiled)
                if compiled != raw:
                    (directory / (Path(path).name + ".full")).write_text(raw)
                self.manifest["sources"][variant][path] = {
                    "full_sha256": digest(raw), "compiled_sha256": digest(compiled),
                }
            shutil.copyfile(HERE / "Driver.swift", directory / "Driver.swift")
        for path in CORE:
            if self.manifest["sources"]["baseline"][path] != self.manifest["sources"]["candidate"][path]:
                raise RuntimeError(f"Unrelated production dependency changed: {path}")
        if (self.manifest["sources"]["baseline"][PLAYER]
                == self.manifest["sources"]["candidate"][PLAYER]):
            raise RuntimeError("No production change to measure")
        for path in [PLAYER_TEST, *[
            "Tests/IlliquidCoreTests/" + name for name in CORE_TESTS
        ]]:
            self.manifest["tests"][path] = digest((ROOT / path).read_bytes())
        self.save("manifest.json", self.manifest)

    def test(self):
        manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "CheckpointQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    ])
"""
        for variant in ("baseline", "candidate"):
            package = self.output / "tests" / variant
            for directory in ("Sources/IlliquidCore", "Sources/IlliquidPlayer",
                              "Tests/IlliquidCoreTests", "Tests/IlliquidPlayerTests"):
                (package / directory).mkdir(parents=True)
            source = self.output / "sources" / variant
            for path in CORE:
                shutil.copyfile(source / Path(path).name,
                                package / "Sources/IlliquidCore" / Path(path).name)
            shutil.copyfile(source / Path(PLAYER).name,
                            package / "Sources/IlliquidPlayer" / Path(PLAYER).name)
            for name in CORE_TESTS:
                shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name,
                                package / "Tests/IlliquidCoreTests" / name)
            shutil.copyfile(ROOT / PLAYER_TEST,
                            package / "Tests/IlliquidPlayerTests" / Path(PLAYER_TEST).name)
            (package / "Package.swift").write_text(manifest)
            env = os.environ.copy()
            env["CLANG_MODULE_CACHE_PATH"] = str(package / "module-cache")
            env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(package / "module-cache")
            for configuration in ("debug", "release"):
                self.command([
                    self.swift, "test", "--package-path", package,
                    "--scratch-path", package / "build", "--cache-path", package / "cache",
                    "--config-path", package / "config", "--security-path", package / "security",
                    "-c", configuration, "--jobs", "2", "--no-parallel",
                ], env=env, log=f"logs/tests-{variant}-{configuration}.log")
                self.tests.append({"variant": variant, "configuration": configuration, "passed": True})
                self.save("tests.json", self.tests)
                print(f"Tests passed: {variant}/{configuration}", flush=True)

    def build(self):
        darwin = platform.system() == "Darwin"
        suffix = ".dylib" if darwin else ".so"
        target = (["-target", f"{platform.machine()}-apple-macosx26.0",
                   "-sdk", self.manifest["sdk"]] if darwin else [])
        for variant in ("baseline", "candidate"):
            source = self.output / "sources" / variant
            for configuration in ("debug", "release"):
                directory = self.output / "build" / variant / configuration
                directory.mkdir(parents=True)
                optimization = ["-Onone", "-g"] if configuration == "debug" else [
                    "-O", "-whole-module-optimization"
                ]
                flags = [*optimization, "-swift-version", "6", "-enable-testing",
                         "-module-cache-path", directory / "module-cache", *target]
                core = directory / ("libIlliquidCore" + suffix)
                player = directory / ("libIlliquidPlayer" + suffix)
                binary = directory / "checkpoint-driver"
                self.command([
                    self.swiftc, *flags, "-emit-library", "-emit-module",
                    "-module-name", "IlliquidCore", "-emit-module-path",
                    directory / "IlliquidCore.swiftmodule",
                    *[source / Path(path).name for path in CORE], "-o", core,
                ], log=f"logs/build-{variant}-{configuration}-core.log")
                self.command([
                    self.swiftc, *flags, "-emit-library", "-emit-module",
                    "-module-name", "IlliquidPlayer", "-emit-module-path",
                    directory / "IlliquidPlayer.swiftmodule", "-I", directory, "-L", directory,
                    "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory,
                    source / Path(PLAYER).name, "-o", player,
                ], log=f"logs/build-{variant}-{configuration}-player.log")
                self.command([
                    self.swiftc, *flags, "-parse-as-library", "-I", directory, "-L", directory,
                    "-lIlliquidPlayer", "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", directory,
                    source / "Driver.swift", "-o", binary,
                ], log=f"logs/build-{variant}-{configuration}-driver.log")
                self.binaries[(variant, configuration)] = binary
                for path in (core, player, binary):
                    self.manifest["artifacts"][str(path.relative_to(self.output))] = digest(path.read_bytes())
                print(f"Built production modules and driver: {variant}/{configuration}", flush=True)
        self.save("manifest.json", self.manifest)

    def invoke(self, variant, configuration, case, iterations=None):
        count, kind = case
        mode = "verify" if iterations is None else "measure"
        arguments = [self.binaries[(variant, configuration)], mode, count, kind]
        if iterations is not None:
            arguments.append(iterations)
        result = json.loads(self.command(arguments))
        if result["count"] != count or result["kind"] != kind:
            raise RuntimeError("Wrong workload receipt")
        if iterations is not None:
            if result["iterations"] != iterations:
                raise RuntimeError("Wrong iteration count")
            reference = self.reference[f"{kind}/{count}"]
            for field in ("output_fingerprint", "warmup_checksum", "output_count", "belongs_to_folder"):
                if result[field] != reference[field]:
                    raise RuntimeError(f"Timed output diverged: {variant}/{case}/{field}")
        return result

    def verify(self):
        comparisons = []
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                trace = {f"{kind}/{count}": self.invoke(variant, configuration, (count, kind))
                         for count, kind in CASES}
                self.save(f"verification/{variant}-{configuration}.json.gz", trace)
                if self.reference is not None and trace != self.reference:
                    raise RuntimeError(f"Complete record parity failed: {variant}/{configuration}")
                self.reference = trace
                comparisons.append({
                    "variant": variant, "configuration": configuration,
                    "workloads": len(trace), "canonical_trace_sha256": digest(json.dumps(trace, sort_keys=True)),
                })
        self.save("parity.json", {"equal": True, "comparisons": comparisons,
                                 "normalized_field": "updatedAt only"})
        print(f"Exact full-record parity: {len(CASES)} workloads across four binaries", flush=True)

    def measure(self):
        calibrations = []
        for case in CASES:
            count, kind = case
            pilots = {variant: self.invoke(variant, "release", case, 1)
                      for variant in ("baseline", "candidate")}
            fastest = min(row["elapsed_ns"] for row in pilots.values())
            requested = max(1, math.ceil(self.args.target_ms * 1_000_000 * 1.5 / max(1, fastest)))
            iterations = min(1_000_000, requested)
            calibrations.append({"count": count, "kind": kind, "pilots": pilots,
                                 "iterations": iterations, "requested_iterations": requested})
            self.save("calibration.json", calibrations)
            rows = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                paired = {}
                for position, variant in enumerate(order):
                    row = self.invoke(variant, "release", case, iterations)
                    row.update(variant=variant, pair=pair, process_order=position, order=list(order))
                    paired[variant] = row
                    rows.append(row)
                    with (self.output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                if paired["baseline"]["checksum"] != paired["candidate"]["checksum"]:
                    raise RuntimeError(f"Paired checksum mismatch: {case}/{pair}")
            summary = {"count": count, "kind": kind, "iterations": iterations, "pairs": self.args.pairs}
            for metric in ("elapsed_ns", "cpu_ns"):
                values = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                          for variant in ("baseline", "candidate")}
                medians = {variant: statistics.median(sample) for variant, sample in values.items()}
                changes = []
                for pair in range(self.args.pairs):
                    pair_rows = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                    changes.append((pair_rows["candidate"] / pair_rows["baseline"] - 1) * 100)
                summary[metric] = {
                    "median_ns_per_operation": medians,
                    "range_ns_per_operation": {key: [min(value), max(value)] for key, value in values.items()},
                    "change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                    "paired_change_percent": changes,
                    "median_paired_change_percent": statistics.median(changes),
                }
            summary["observations_under_target"] = [
                {"variant": row["variant"], "pair": row["pair"], "ms": row["elapsed_ns"] / 1_000_000}
                for row in rows if row["elapsed_ns"] < self.args.target_ms * 1_000_000
            ]
            self.summaries.append(summary)
            self.save("summary.json", self.summaries)
            wall = summary["elapsed_ns"]["median_ns_per_operation"]
            cpu = summary["cpu_ns"]["median_ns_per_operation"]
            print(f'{kind}/{count}: wall {wall["baseline"] / 1e6:.4f} -> '
                  f'{wall["candidate"] / 1e6:.4f} ms '
                  f'({summary["elapsed_ns"]["change_percent"]:+.2f}%); '
                  f'CPU {cpu["baseline"] / 1e6:.4f} -> {cpu["candidate"] / 1e6:.4f} ms '
                  f'({summary["cpu_ns"]["change_percent"]:+.2f}%)', flush=True)

    def audit_unchanged(self):
        for path, hashes in self.manifest["sources"]["candidate"].items():
            if digest((ROOT / path).read_bytes()) != hashes["full_sha256"]:
                raise RuntimeError(f"Candidate source changed during run: {path}")
        for path, expected in self.manifest["tests"].items():
            if digest((ROOT / path).read_bytes()) != expected:
                raise RuntimeError(f"Test changed during run: {path}")
        for path, expected in self.manifest["artifacts"].items():
            if digest((self.output / path).read_bytes()) != expected:
                raise RuntimeError(f"Binary changed during run: {path}")
        if digest(Path(__file__).read_bytes()) != self.manifest["runner_sha256"]:
            raise RuntimeError("Runner changed during run")
        if digest((HERE / "Driver.swift").read_bytes()) != self.manifest["driver_sha256"]:
            raise RuntimeError("Driver changed during run")

    def execute(self):
        complete = {"complete": False}
        try:
            self.prepare()
            self.test()
            self.build()
            self.verify()
            if not self.args.tests_only:
                self.measure()
            self.audit_unchanged()
            complete = {
                "complete": True, "tests_only": self.args.tests_only,
                "test_configurations": len(self.tests), "verification_workloads": len(CASES),
                "measured_observations": len(self.summaries) * self.args.pairs * 2,
                "minimum_duration_met": all(
                    not group["observations_under_target"] for group in self.summaries),
                "source_test_and_binary_hashes_unchanged": True,
            }
            print("CHECKPOINT_QUALIFICATION_PASS", flush=True)
        except BaseException as error:
            complete["error"] = str(error)
            raise
        finally:
            self.save("completion.json", complete)
            self.save("manifest.json", self.manifest)
            self.save("commands.json", self.commands)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--kyoto-queued", action="store_true",
                        help="The complete harness was submitted through the available Kyoto queue")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even pair count >= 2 and a positive finite target-ms")
    Runner(args).execute()


if __name__ == "__main__":
    main()
