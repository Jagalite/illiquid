#!/usr/bin/env python3
"""Validate and measure the actual production awaitPreroll retirement transition."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
VARIANTS = ["baseline", "candidate"]
COUNTS = [0, 1, 8, 64, 4096]
PAIRS = 8
TARGET_CPU_NS = 40_000_000
MIN_CPU_NS = 20_000_000
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def command(args: list, output: Path, *, name: str | None = None) -> str:
    args = [str(value) for value in args]
    env = os.environ.copy()
    # Keep normal randomized Swift hashing; each observation is a new process.
    env.pop("SWIFT_DETERMINISTIC_HASHING", None)
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               TERM="dumb", NO_COLOR="1")
    started = time.time()
    result = subprocess.run(args, capture_output=True, env=env, timeout=900)
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": args, "returncode": result.returncode,
                                 "started_unix": started, "seconds": time.time() - started,
                                 "stdout": stdout, "stderr": stderr}) + "\n")
    if name:
        (output / name).write_text(stdout + stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{stdout}\n{stderr}")
    return stdout


def stage(output: Path, variant: str) -> dict:
    package = output / variant
    revision = BASELINE if variant == "baseline" else None
    receipts = {}

    def copy(relative: str, destination: Path | None = None, *, current: bool = False) -> None:
        data = (git("show", f"{revision}:{relative}") if revision and not current
                else (ROOT / relative).read_bytes())
        target = destination or package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[str(target.relative_to(package))] = {
            "source": relative, "sha256": sha256(data), "transformation": "none"
        }

    copy("Sources/IlliquidCore/Player/MediaTrack.swift")
    for folder in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace",
                   "Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]:
        paths = (git("ls-tree", "-r", "--name-only", revision, "--", folder).decode().splitlines()
                 if revision else [str(p.relative_to(ROOT)) for p in sorted((ROOT / folder).rglob("*.swift"))])
        for relative in paths:
            if relative.endswith(".swift"):
                copy(relative)
    # Run the same new behavioral regression tests against both implementations.
    copy("Tests/IlliquidPlaybackCoreTests/EffectSettlementTests.swift", current=True)
    copy("Benchmarks/EffectSettlement/Harness.swift",
         package / "Sources/EffectSettlementBenchmark/Harness.swift", current=True)
    targets = [
        '.target(name: "IlliquidCore")',
        '.target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"])',
        '.target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"])',
        '.executableTarget(name: "EffectSettlementBenchmark", dependencies: ["IlliquidPlaybackCore"])',
        '.testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"])',
        '.testTarget(name: "IlliquidPlaybackStateSpaceTests", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"])',
    ]
    manifest = ('// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "EffectSettlement", platforms: [.macOS("26.0")],\n'
                'products: [.executable(name: "EffectSettlementBenchmark", targets: ["EffectSettlementBenchmark"])],\n'
                'targets: [\n' + ',\n'.join(targets) + '\n], swiftLanguageModes: [.v6])\n')
    (package / "Package.swift").write_text(manifest)
    receipts["Package.swift"] = {"sha256": sha256(manifest.encode()), "transformation": "isolated manifest"}
    return receipts


def swift_command(args: argparse.Namespace, variant: str, operation: str, configuration: str) -> list:
    result = [args.swift, operation, "--package-path", args.output / variant,
              "--configuration", configuration, "--jobs", "2",
              "--cache-path", args.output / "cache", "--config-path", args.output / "config",
              "--security-path", args.output / "security", "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        result += ["--scratch-path", args.output / variant / ".build/tests", "--no-parallel"]
    if platform.system() == "Linux":
        result.append("--use-integrated-swift-driver")
    return result


def summarize(rows: list[dict], iterations: dict[int, int]) -> dict:
    cases = []
    for count in COUNTS:
        metrics = {}
        for metric in ["cpuNanoseconds", "wallNanoseconds"]:
            values = {v: [r[metric] for r in rows if r["variant"] == v and r["count"] == count]
                      for v in VARIANTS}
            ratios = [candidate / baseline for baseline, candidate
                      in zip(values["baseline"], values["candidate"], strict=True)]
            metrics[metric] = {
                "baseline_median_ns_per_transition": statistics.median(values["baseline"]) / iterations[count],
                "candidate_median_ns_per_transition": statistics.median(values["candidate"]) / iterations[count],
                "paired_ratios": ratios,
                "median_paired_ratio": statistics.median(ratios),
                "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
                "baseline_total_range_ns": [min(values["baseline"]), max(values["baseline"])],
                "candidate_total_range_ns": [min(values["candidate"]), max(values["candidate"])],
            }
        cpu = metrics["cpuNanoseconds"]
        duration_ok = count == 4096 or all(
            r["cpuNanoseconds"] >= MIN_CPU_NS for r in rows if r["count"] == count
        )
        gate = None
        if count in [8, 64]:
            gate = (duration_ok and cpu["median_paired_ratio"] <= 0.95
                    and cpu["candidate_faster_pairs"] >= 6)
        elif count in [0, 1]:
            gate = duration_ok and cpu["median_paired_ratio"] <= 1.05
        cases.append({"count": count, "label": "stress" if count == 4096 else "ordinary",
                      "iterations": iterations[count], "pairs": PAIRS,
                      "duration_sufficient": duration_ok, "success_gate": gate, "metrics": metrics})
    return {
        "scope": "Ubuntu Swift component CPU/wall time for complete PlaybackCore.update; not native playback",
        "allocation_traffic_measured": False,
        "success": all(case["success_gate"] for case in cases if case["count"] != 4096),
        "predeclared_gate": "N8/N64 median paired CPU ratio <=0.95 and >=6/8 faster; "
                            "N0/N1 ratio <=1.05; every ordinary observation >=20ms CPU; semantics/tests pass",
        "cases": cases,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--kyoto-submitted", action="store_true",
                        help="The whole runner was launched as a Kyoto job; inspect its job/log/wait receipt.")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    if KYOTO.exists() and not args.kyoto_submitted:
        raise RuntimeError("Kyoto is available: submit this entire runner through kyoto.py submit -- "
                           "with --kyoto-submitted, then inspect the job, logs, and wait result.")
    print("Kyoto queue owns this run." if args.kyoto_submitted else
          "Kyoto is unavailable on this runner; isolated Swift builds/tests run directly and serially.",
          flush=True)
    baseline = git("rev-parse", f"{BASELINE}^{{commit}}").decode().strip()
    manifest = {
        "baseline_commit": baseline, "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "candidate_sources": "current worktree", "worktree_status": git("status", "--porcelain").decode(),
        "compiler": command([args.swift, "--version"], args.output).strip(),
        "platform": platform.platform(), "machine": platform.machine(), "python": platform.python_version(),
        "method": "unchanged whole core; fresh fixtures; balanced AB/BA; fresh processes; randomized hashing",
        "kyoto_submitted": args.kyoto_submitted, "tests_only": args.tests_only,
        "pairs": PAIRS, "counts": COUNTS, "source_hashes": {},
        "harness_hashes": {p.name: sha256(p.read_bytes()) for p in sorted(HERE.iterdir())
                           if p.is_file() and p.suffix in {".swift", ".py", ".md"}},
    }
    binaries = {}
    for variant in VARIANTS:
        print(f"Stage and build {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant)
        save(args.output / "manifest.json", manifest)
        command([*swift_command(args, variant, "build", "release"), "--product", "EffectSettlementBenchmark"],
                args.output, name=f"{variant}-build.log")
        bin_path = command([*swift_command(args, variant, "build", "release"), "--show-bin-path"], args.output).strip()
        binaries[variant] = Path(bin_path) / "EffectSettlementBenchmark"
    manifest["binary_hashes"] = {v: sha256(path.read_bytes()) for v, path in binaries.items()}
    save(args.output / "manifest.json", manifest)
    for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
        print(f"Test {variant} {configuration}", flush=True)
        command(swift_command(args, variant, "test", configuration), args.output,
                name=f"{variant}-{configuration}-tests.log")
    verification = {}
    for variant in VARIANTS:
        verification[variant] = json.loads(command([binaries[variant], "--verify"], args.output))
    save(args.output / "verification.json", verification)
    if verification["baseline"] != verification["candidate"]:
        raise ValueError("Complete final-state/transition/duplicate parity differs")
    print("Complete semantic parity passed", flush=True)
    if args.tests_only:
        return

    # Pilot results are excluded. Freeze one shared iteration count per workload
    # before the eight pairs; do not choose counts from measured pair outcomes.
    pilots, iterations = [], {}
    for count, initial, cap in [(0, 1024, 262144), (1, 1024, 262144),
                                 (8, 256, 65536), (64, 64, 16384)]:
        results = []
        for variant in VARIANTS:
            result = json.loads(command([binaries[variant], count, initial], args.output))
            pilots.append(dict(result, variant=variant))
            results.append(result["cpuNanoseconds"])
        iterations[count] = min(cap, max(initial, math.ceil(initial * TARGET_CPU_NS / min(results))))
    iterations[4096] = 2  # O(N²) event-driven setup; stress does not gate success.
    save(args.output / "calibration.json", {"pilots_excluded": pilots, "frozen_iterations": iterations,
                                           "target_cpu_ns": TARGET_CPU_NS, "minimum_cpu_ns": MIN_CPU_NS})

    rows = []
    for count in COUNTS:
        print(f"Measure N={count}, {iterations[count]} transitions/process, {PAIRS} fresh pairs", flush=True)
        for pair in range(PAIRS):
            order = VARIANTS if pair % 2 == 0 else list(reversed(VARIANTS))
            observed = {}
            for variant in order:
                result = json.loads(command([binaries[variant], count, iterations[count]], args.output))
                observed[variant] = result
                rows.append(dict(result, variant=variant, pair=pair, order=order))
                save(args.output / "observations.json", rows)
            if observed["baseline"]["checks"] != observed["candidate"]["checks"]:
                raise ValueError(f"Measured fixture semantics differ: N={count}, pair={pair}")
    summary = summarize(rows, iterations)
    save(args.output / "summary.json", summary)
    print(json.dumps(summary, indent=2), flush=True)
    if not summary["success"]:
        raise SystemExit("The predeclared performance gate did not pass; do not claim a successful optimization.")


if __name__ == "__main__":
    main()
