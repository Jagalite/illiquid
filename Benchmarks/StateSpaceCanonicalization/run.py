#!/usr/bin/env python3
"""Measure exact production state-space searches in balanced fresh processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCENARIOS = [
    ("seek", "ready-playing", 4, "disabled", "validation"),
    ("eof-drain", "playing-av", 4, "disabled", "validation"),
    ("recovery", "playing-hardware", 4, "disabled", "validation"),
    ("track-subtitles", "automatic", 4, "disabled", "validation"),
    ("stop-shutdown", "opening", 4, "disabled", "validation"),
    ("preroll-buffering", "partial-av", 4, "disabled", "validation"),
    ("stop-shutdown", "opening", 3, "validation", "validation"),
    ("track-subtitles", "external-subtitle", 12, "disabled", "pr"),
]


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def command(args, output, name=None):
    args = list(map(str, args))
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               TERM="dumb", NO_COLOR="1")
    started = time.monotonic()
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=600)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": args, "returncode": result.returncode,
                                 "seconds": time.monotonic() - started,
                                 "stdout": result.stdout, "stderr": result.stderr}) + "\n")
    if name:
        (output / name).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def stage(output, variant, baseline):
    package = output / variant
    receipts = {}
    paths = ["Sources/IlliquidCore/Player/MediaTrack.swift"]
    for folder in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace",
                   "Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]:
        if variant == "baseline" and folder.startswith("Sources/"):
            paths.extend(p for p in git("ls-tree", "-r", "--name-only", baseline, "--", folder)
                         .decode().splitlines() if p.endswith(".swift"))
        else:
            paths.extend(str(p.relative_to(ROOT)) for p in sorted((ROOT / folder).rglob("*.swift")))
    for relative in paths:
        # Both variants use exactly the same current test suite.
        data = (git("show", f"{baseline}:{relative}")
                if variant == "baseline" and not relative.startswith("Tests/")
                else (ROOT / relative).read_bytes())
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[relative] = {"sha256": sha256(data), "transformation": "none"}
    driver = package / "Sources/StateSpaceBenchmark/Driver.swift"
    driver.parent.mkdir(parents=True)
    driver.write_bytes((HERE / "Driver.swift").read_bytes())
    manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "StateSpaceCanonicalization",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "StateSpaceBenchmark", targets: ["StateSpaceBenchmark"])],
  targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
    .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
    .executableTarget(name: "StateSpaceBenchmark", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
    .testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"]),
    .testTarget(name: "IlliquidPlaybackStateSpaceTests",
      dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"])
  ], swiftLanguageModes: [.v6]
)
'''
    (package / "Package.swift").write_text(manifest)
    return receipts


def swift_command(args, variant, operation, configuration):
    command = [args.swift, operation, "--package-path", args.output / variant,
               "-c", configuration, "--jobs", "2",
               "--cache-path", args.output / "cache",
               "--config-path", args.output / "config",
               "--security-path", args.output / "security",
               "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        command += ["--no-parallel"]
    if platform.system() == "Linux":
        command += ["--use-integrated-swift-driver"]
    return command


def compact(observation):
    semantics = observation.pop("semantics")
    observation["summary"] = semantics["summary"]
    observation["semantics_sha256"] = sha256(json.dumps(semantics, sort_keys=True).encode())
    return semantics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be a positive even number of at least 2")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("--output must be empty")
    baseline = (None if args.tests_only else
                git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip())
    manifest = {
        "baseline_commit": baseline,
        "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "candidate_source": "current worktree",
        "compiler": command([args.swift, "--version"], args.output).strip(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "method": "balanced AB/BA; fresh processes; release Swift 6; identical complete search graphs",
        "scope": "bounded verification throughput; no decoding or playback measurements",
        "pairs": 0 if args.tests_only else args.pairs,
        "tests_only": args.tests_only,
        "source_hashes": {},
        "harness_sha256": {name: sha256((HERE / name).read_bytes())
                           for name in ["Driver.swift", "run.py"]},
    }
    binaries = {}
    variants = ["candidate"] if args.tests_only else ["baseline", "candidate"]
    for variant in variants:
        print(f"Build {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
        save(args.output / "manifest.json", manifest)
        command([*swift_command(args, variant, "build", "release"), "--product", "StateSpaceBenchmark"],
                args.output, f"{variant}-build.log")
        binary_dir = command([*swift_command(args, variant, "build", "release"), "--show-bin-path"],
                             args.output).strip()
        binaries[variant] = Path(binary_dir) / "StateSpaceBenchmark"
    manifest["binary_sha256"] = {name: sha256(binary.read_bytes()) for name, binary in binaries.items()}
    save(args.output / "manifest.json", manifest)
    tests = [("candidate", "debug"), ("candidate", "release")]
    if not args.tests_only:
        tests.insert(0, ("baseline", "release"))
    for variant, configuration in tests:
        print(f"Test {variant} {configuration}", flush=True)
        command(swift_command(args, variant, "test", configuration), args.output,
                f"{variant}-{configuration}-tests.log")

    if args.tests_only:
        save(args.output / "verification.json", {"mode": "candidate-regression-only", "benchmark_ran": False})
        print("Candidate debug/release regression suites passed; no historical graph comparison requested.", flush=True)
        return

    observations = []
    verification = []
    for model, seed, depth, por, profile in SCENARIOS:
        print(f"Compare {model}/{seed}, depth={depth}, por={por}, profile={profile}", flush=True)
        reference = None
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for variant in order:
                observed = json.loads(command([binaries[variant], model, seed, depth, por, profile], args.output))
                semantics = compact(observed)
                if reference is None:
                    reference = semantics
                if semantics != reference:
                    save(args.output / "semantic-mismatch.json",
                         {"reference": reference, "actual": semantics})
                    raise ValueError(f"Search semantics differ: {model}/{seed}/{por}")
                observed.update(variant=variant, pair=pair, model=model, seed=seed, depth=depth, por=por, profile=profile)
                observations.append(observed)
                save(args.output / "observations.json", observations)
        verification.append({"model": model, "seed": seed, "depth": depth, "por": por, "profile": profile,
                             "states": reference["summary"]["stateCount"],
                             "edges": reference["summary"]["edgeCount"],
                             "canonical_digest": reference["summary"]["canonicalDigest"],
                             "semantics_equal": True})
    save(args.output / "verification.json", verification)
    summary = []
    for model, seed, depth, por, profile in SCENARIOS:
        rows = [row for row in observations if
                (row["model"], row["seed"], row["depth"], row["por"], row["profile"]) == (model, seed, depth, por, profile)]
        metrics = {}
        for metric in ["wallNanoseconds", "cpuNanoseconds"]:
            values = {variant: [row[metric] for row in rows if row["variant"] == variant]
                      for variant in ["baseline", "candidate"]}
            medians = {variant: statistics.median(data) for variant, data in values.items()}
            metrics[metric] = {
                "baseline_median": medians["baseline"], "candidate_median": medians["candidate"],
                "reduction_percent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                "speedup": medians["baseline"] / medians["candidate"],
                "baseline_range": [min(values["baseline"]), max(values["baseline"])],
                "candidate_range": [min(values["candidate"]), max(values["candidate"])],
            }
        summary.append({"model": model, "seed": seed, "depth": depth, "por": por, "profile": profile, "metrics": metrics})
    save(args.output / "summary.json", summary)
    print(json.dumps({"verification": verification, "summary": summary}, indent=2), flush=True)


if __name__ == "__main__":
    main()
