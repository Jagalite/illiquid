#!/usr/bin/env python3
"""Measure complete progress analysis from exact baseline/candidate Swift sources."""
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
ANALYZER = "Sources/IlliquidPlaybackStateSpace/PlaybackProgressAnalyzer.swift"


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def command(arguments: list, output: Path, name: str, timeout: int = 900) -> str:
    argv = [str(value) for value in arguments]
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               TERM="dumb", NO_COLOR="1")
    started = time.time()
    result = subprocess.run(argv, capture_output=True, env=env, timeout=timeout)
    stdout = result.stdout.decode()
    stderr = result.stderr.decode()
    (output / f"{name}.stdout").write_text(stdout)
    (output / f"{name}.stderr").write_text(stderr)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": argv, "returncode": result.returncode,
                                 "started_unix": started, "seconds": time.time() - started,
                                 "stdout": f"{name}.stdout", "stderr": f"{name}.stderr"}) + "\n")
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode})\n{stdout}\n{stderr}")
    return stdout


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / variant
    receipts = {}

    def copy(relative: str, destination: str | None = None, current: bool = False) -> None:
        data = (git("show", f"{baseline}:{relative}")
                if variant == "baseline" and not current
                else (ROOT / relative).read_bytes())
        target = package / (destination or relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        receipts[relative] = {"sha256": digest(data),
                              "destination": str(target.relative_to(package)),
                              "transformation": "none"}

    copy("Sources/IlliquidCore/Player/MediaTrack.swift")
    for folder in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace"]:
        # Both variants must have the same production file inventory.
        paths = git("ls-tree", "-r", "--name-only", baseline, "--", folder).decode().splitlines()
        current_paths = [str(p.relative_to(ROOT)) for p in sorted((ROOT / folder).rglob("*.swift"))]
        paths = sorted(p for p in paths if p.endswith(".swift"))
        if paths != current_paths:
            raise ValueError(f"Production source inventory differs in {folder}")
        for relative in paths:
            copy(relative)
    # Run the same current regressions against both versions, including the new
    # fair-reachability/report tests. No test or production source is rewritten.
    for folder in ["Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            copy(str(path.relative_to(ROOT)), current=True)
    copy("Benchmarks/StateSpaceProgress/Harness.swift",
         "Sources/StateSpaceProgressBenchmark/Harness.swift", current=True)
    manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "StateSpaceProgress",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "StateSpaceProgressBenchmark", targets: ["StateSpaceProgressBenchmark"])],
  targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
    .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"],
            swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .executableTarget(name: "StateSpaceProgressBenchmark", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
    .testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"]),
    .testTarget(name: "IlliquidPlaybackStateSpaceTests",
                dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
  ],
  swiftLanguageModes: [.v6]
)
"""
    (package / "Package.swift").write_text(manifest)
    return receipts


def swift_command(args: argparse.Namespace, variant: str, operation: str, configuration: str) -> list:
    result = [args.swift, operation, "--package-path", args.output / variant,
              "--configuration", configuration, "--jobs", "2",
              "--cache-path", args.output / "cache", "--config-path", args.output / "config",
              "--security-path", args.output / "security",
              "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        result += ["--no-parallel"]
    if platform.system() == "Linux":
        result += ["--use-integrated-swift-driver"]
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--min-seconds", type=float, default=0.25)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be a positive even number of at least two")
    if not math.isfinite(args.min_seconds) or args.min_seconds <= 0:
        parser.error("--min-seconds must be finite and positive")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
    manifest = {
        "schema_version": 1, "baseline_commit": baseline,
        "candidate_head": git("rev-parse", "HEAD").decode().strip(),
        "candidate_sources": "current worktree",
        "candidate_status": git("status", "--porcelain").decode(),
        "compiler": command([args.swift, "--version"], args.output, "compiler").strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "python": platform.python_version(), "pairs": args.pairs,
        "minimum_target_seconds": args.min_seconds, "maximum_target_seconds_for_slower_variant": 2.0,
        "method": "separate optimized Swift modules; complete analyze only; graph construction excluded; balanced fresh-process AB/BA pairs",
        "scope": "bounded playback verification tooling, not player playback or UI performance",
        "source_hashes": {},
        "harness_hashes": {p.name: digest(p.read_bytes())
                           for p in sorted(HERE.glob("*")) if p.suffix in {".swift", ".py"}},
    }
    if platform.system() == "Darwin":
        manifest["macos"] = command(["sw_vers"], args.output, "macos").strip()
        manifest["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], args.output, "cpu").strip()
    binaries = {}
    for variant in ["baseline", "candidate"]:
        print(f"Stage and compile {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
        save(args.output / "manifest.json", manifest)
        command([*swift_command(args, variant, "build", "release"), "--product", "StateSpaceProgressBenchmark"],
                args.output, f"{variant}-build")
        binary_path = command([*swift_command(args, variant, "build", "release"), "--show-bin-path"],
                              args.output, f"{variant}-binary-path").strip()
        binaries[variant] = Path(binary_path) / "StateSpaceProgressBenchmark"
    changed = [path for path, receipt in manifest["source_hashes"]["baseline"].items()
               if receipt["sha256"] != manifest["source_hashes"]["candidate"][path]["sha256"]]
    if changed != [ANALYZER]:
        raise ValueError(f"Expected only the progress analyzer to differ; observed {changed}")
    manifest["changed_source_paths"] = changed
    manifest["binary_hashes"] = {name: digest(path.read_bytes()) for name, path in binaries.items()}
    save(args.output / "manifest.json", manifest)

    tests = []
    for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
        print(f"Run {variant} {configuration} regression suites", flush=True)
        name = f"{variant}-{configuration}-tests"
        command(swift_command(args, variant, "test", configuration), args.output, name)
        tests.append({"variant": variant, "configuration": configuration, "passed": True,
                      "stdout": f"{name}.stdout", "stderr": f"{name}.stderr"})
        save(args.output / "tests.json", tests)

    listings = {variant: json.loads(command([binary, "list"], args.output, f"{variant}-list"))
                for variant, binary in binaries.items()}
    if listings["baseline"] != listings["candidate"]:
        raise ValueError("Workload inventories differ")
    workloads = [item["id"] for item in listings["baseline"]["workloads"]]
    verification = []
    for workload in workloads:
        print(f"Compare complete semantic receipts: {workload}", flush=True)
        receipts = {}
        hashes = {}
        for variant, binary in binaries.items():
            raw = command([binary, "verify", workload], args.output, f"{variant}-verify-{workload}")
            receipts[variant] = json.loads(raw)
            hashes[variant] = digest(raw.encode())
        if receipts["baseline"] != receipts["candidate"]:
            raise ValueError(f"Complete semantic receipts differ: {workload}")
        verification.append({
            "workload": workload, "equal": True, "sha256": hashes,
            "kind": receipts["baseline"]["workload"]["kind"],
            "summary": receipts["baseline"]["summary"],
            "report": receipts["baseline"]["report"],
            "failure_count": len(receipts["baseline"]["failures"]),
        })
        save(args.output / "verification.json", verification)

    rows = []
    calibration = {}
    for workload in workloads:
        observed = {}
        for variant, binary in binaries.items():
            observed[variant] = json.loads(command([binary, "benchmark", workload, "1"], args.output,
                                                   f"{variant}-calibrate-{workload}"))
        if observed["baseline"]["measured"] != observed["candidate"]["measured"]:
            raise ValueError(f"Calibration outputs differ: {workload}")
        fastest_seconds = min(row["elapsedNanoseconds"] / 1e9 for row in observed.values())
        slowest_seconds = max(row["elapsedNanoseconds"] / 1e9 for row in observed.values())
        # Keep extreme scaling controls from spending minutes in one baseline
        # sample. Record actual durations; the fast variant may then be shorter
        # than the calibration target.
        iterations = max(1, min(128, math.ceil(args.min_seconds / fastest_seconds),
                                math.floor(2.0 / slowest_seconds)))
        calibration[workload] = {"iterations": iterations, "observations": observed}
        save(args.output / "calibration.json", calibration)
        print(f"Measure {workload}: {iterations} iterations, {args.pairs} pairs", flush=True)
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            paired = {}
            for variant in order:
                row = json.loads(command(
                    [binaries[variant], "benchmark", workload, str(iterations)],
                    args.output, f"{variant}-measure-{workload}-{pair}"))
                row.update(variant=variant, pair=pair, order=order,
                           nanoseconds_per_iteration=row["elapsedNanoseconds"] / iterations)
                rows.append(row)
                paired[variant] = row
                save(args.output / "observations.json", rows)
            for field in ["warmup", "measured", "iterations", "analysesPerIteration", "report", "searchSummary"]:
                if paired["baseline"][field] != paired["candidate"][field]:
                    raise ValueError(f"Measured outputs differ: {workload}, pair {pair}, {field}")

    summary = []
    for workload in workloads:
        values = {variant: [row["nanoseconds_per_iteration"] for row in rows
                            if row["variant"] == variant and row["workload"] == workload]
                  for variant in ["baseline", "candidate"]}
        ratios = [candidate / baseline for baseline, candidate in zip(values["baseline"], values["candidate"])]
        baseline_median = statistics.median(values["baseline"])
        candidate_median = statistics.median(values["candidate"])
        proof = next(item for item in verification if item["workload"] == workload)
        summary.append({
            "workload": workload, "kind": proof["kind"], "pairs": args.pairs,
            "states": proof["summary"]["stateCount"], "edges": proof["summary"]["edgeCount"],
            "transaction_states": proof["report"]["transactionStates"],
            "settled_transaction_states": proof["report"]["settledTransactionStates"],
            "iterations_per_sample": calibration[workload]["iterations"],
            "baseline_median_ms": baseline_median / 1e6,
            "candidate_median_ms": candidate_median / 1e6,
            "median_time_reduction_percent": 100 * (1 - candidate_median / baseline_median),
            "paired_time_reduction_percent": [100 * (1 - ratio) for ratio in ratios],
            "paired_speedup_median": statistics.median(1 / ratio for ratio in ratios),
            "baseline_range_ms": [min(values["baseline"]) / 1e6, max(values["baseline"]) / 1e6],
            "candidate_range_ms": [min(values["candidate"]) / 1e6, max(values["candidate"]) / 1e6],
        })
    save(args.output / "summary.json", summary)
    print("PERFORMANCE_MANIFEST " + json.dumps(manifest, separators=(",", ":")), flush=True)
    print("PERFORMANCE_TESTS " + json.dumps(tests, separators=(",", ":")), flush=True)
    print("PERFORMANCE_VERIFICATION " + json.dumps(verification, separators=(",", ":")), flush=True)
    for row in rows:
        print("PERFORMANCE_OBSERVATION " + json.dumps(row, separators=(",", ":")), flush=True)
    print("PERFORMANCE_SUMMARY " + json.dumps(summary, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
