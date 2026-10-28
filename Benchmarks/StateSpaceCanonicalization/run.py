#!/usr/bin/env python3
"""Compare exact state-space sources in balanced, fresh CLI processes."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import platform
import re
import resource
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_digest(value: object) -> str:
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def command(arguments: list, review: Path, name: str, *, extra_env: dict | None = None,
            timeout: int = 900) -> tuple[str, dict]:
    arguments = [str(value) for value in arguments]
    env = os.environ.copy()
    env.update(TERM="dumb", NO_COLOR="1")
    env.update(extra_env or {})
    before_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    started_unix = time.time()
    start = time.perf_counter()
    timed_out = False
    try:
        result = subprocess.run(arguments, capture_output=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        timed_out = True
        result = subprocess.CompletedProcess(
            arguments, 124, error.stdout or b"", error.stderr or b"")
    wall = time.perf_counter() - start
    after_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((after_cpu.ru_utime - before_cpu.ru_utime)
           + (after_cpu.ru_stime - before_cpu.ru_stime))
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    log = review / "logs" / (name + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(stdout + stderr)
    receipt = {"command": arguments, "started_unix": started_unix,
               "wall_seconds": wall, "cpu_seconds": cpu, "returncode": result.returncode,
               "timeout_seconds": timeout, "timed_out": timed_out,
               "log": str(log.relative_to(review)), "log_sha256": sha256(log.read_bytes())}
    with (review / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps(receipt, sort_keys=True) + "\n")
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}):\n{stdout}\n{stderr}")
    return stdout, receipt


def stage(output: Path, variant: str, baseline: str) -> dict:
    package = output / variant
    hashes = {}
    source_folders = ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace"]
    sources = ["Sources/IlliquidCore/Player/MediaTrack.swift",
               "Validation/IlliquidStateSpaceExplorer/main.swift"]
    for folder in source_folders:
        sources.extend(git("ls-tree", "-r", "--name-only", baseline, "--", folder).decode().splitlines()
                       if variant == "baseline"
                       else [str(p.relative_to(ROOT)) for p in sorted((ROOT / folder).rglob("*.swift"))])
    for relative in sources:
        if not relative.endswith(".swift"):
            continue
        data = (git("show", f"{baseline}:{relative}") if variant == "baseline"
                else (ROOT / relative).read_bytes())
        repository_hash = sha256(data)
        transformation = "none"
        if relative == "Validation/IlliquidStateSpaceExplorer/main.swift" and platform.system() == "Linux":
            if not data.startswith(b"import Darwin\n"):
                raise ValueError("Unexpected CLI import; inspect the portability adapter")
            data = data.replace(
                b"import Darwin\n",
                b"import Glibc\nnonisolated(unsafe) let stderr = Glibc.stderr\n", 1)
            transformation = "Darwin import -> Glibc and immutable stderr alias; CLI logic unchanged"
        destination = (Path("Sources/IlliquidStateSpaceExplorer/main.swift")
                       if relative.startswith("Validation/") else Path(relative))
        target = package / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        hashes[relative] = {"sha256": sha256(data), "repository_sha256": repository_hash,
                            "transformation": transformation}
    # Identical current tests exercise both versions, including new regressions.
    for folder in ["Tests/IlliquidPlaybackCoreTests", "Tests/IlliquidPlaybackStateSpaceTests"]:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            relative = str(path.relative_to(ROOT))
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())
            hashes[relative] = {"sha256": sha256(path.read_bytes()), "origin": "current tests"}
    target = package / "Sources/StateSpaceParity/Parity.swift"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((HERE / "Parity.swift").read_bytes())
    (package / "Package.swift").write_text(
        '// swift-tools-version: 6.1\nimport PackageDescription\n'
        'let package = Package(name: "StateSpaceCanonicalization", platforms: [.macOS("26.0")],\n'
        'products: [.executable(name: "IlliquidStateSpaceExplorer", targets: ["IlliquidStateSpaceExplorer"]),\n'
        '.executable(name: "StateSpaceParity", targets: ["StateSpaceParity"])], targets: [\n'
        '.target(name: "IlliquidCore"),\n'
        '.target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),\n'
        '.target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),\n'
        '.executableTarget(name: "IlliquidStateSpaceExplorer", dependencies: ["IlliquidPlaybackStateSpace"]),\n'
        '.executableTarget(name: "StateSpaceParity", dependencies: ["IlliquidPlaybackStateSpace"]),\n'
        '.testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"]),\n'
        '.testTarget(name: "IlliquidPlaybackStateSpaceTests", dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"])\n'
        '], swiftLanguageModes: [.v6])\n')
    hashes["standalone_Package.swift"] = {"sha256": sha256((package / "Package.swift").read_bytes())}
    return hashes


def compact_parity(value: object) -> object:
    """Hash exact serialized receipts outside Swift; the probe needs no crypto dependency."""
    if isinstance(value, list):
        return [compact_parity(item) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key.endswith("JSONBase64"):
                result[key.removesuffix("JSONBase64") + "SHA256"] = sha256(
                    base64.b64decode(item, validate=True))
            else:
                result[key] = compact_parity(item)
        return result
    return value


def normalized_records(directory: Path) -> list:
    records = json.loads((directory / "manifest-shard-0-of-1.json").read_text())
    for record in records:
        record.pop("sourceRevision", None)
        record.pop("sourceDirty", None)
        if (record["summary"]["termination"] != "completeWithinBounds"
                or record["failureArtifactPaths"] or record["trendViolations"]
                or record["progress"]["stuckStates"] or record["progress"]["closedNonterminalSCCs"]
                or record["summary"]["nonCommutingDiamondCount"]):
            raise ValueError("Incomplete or failing search; not performance evidence")
    return sorted(records, key=lambda r: (r["summary"]["model"], r["summary"]["seedProfile"]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=4)
    args = parser.parse_args()
    if platform.system() not in {"Darwin", "Linux"}:
        raise ValueError("Use macOS or Linux with Swift 6.1 or later")
    if args.pairs < 2 or args.pairs % 2:
        raise ValueError("Use a positive even pair count for balanced AB/BA ordering")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new, empty output directory")
    review = args.output / "review"
    review.mkdir()
    baseline = git("rev-parse", f"{args.baseline}^{{commit}}").decode().strip()
    candidate = git("rev-parse", "HEAD").decode().strip()
    candidate_dirty = bool(git("status", "--porcelain").strip())
    compiler, _ = command([args.swift, "--version"], review, "compiler")
    manifest = {"baseline_commit": baseline, "candidate_commit": candidate,
                "candidate_sources": "current worktree", "candidate_dirty": candidate_dirty,
                "compiler": compiler.strip(),
                "platform": platform.platform(), "machine": platform.machine(),
                "method": "release CLI; exact core/explorer; full PR seed inventory; balanced AB/BA; fresh serial processes",
                "pairs": args.pairs, "scope": "state-space qualification, not media playback",
                "source_hashes": {}, "binary_hashes": {},
                "harness_hashes": {p.name: sha256(p.read_bytes()) for p in sorted(HERE.glob("*"))
                                   if p.suffix in {".py", ".swift"}},
                "ci": {name: os.environ.get(name) for name in
                       ["GITHUB_RUN_ID", "GITHUB_SHA", "GITHUB_REF", "RUNNER_OS", "RUNNER_ARCH"]}}
    binaries = {}
    parity_binaries = {}
    tests = []
    for variant in ["baseline", "candidate"]:
        print(f"Stage {variant}", flush=True)
        manifest["source_hashes"][variant] = stage(args.output, variant, baseline)
        save(review / "manifest.json", manifest)
        package_args = ["--package-path", args.output / variant, "--jobs", "2",
                        "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux":
            package_args.append("--use-integrated-swift-driver")
        for configuration in ["debug", "release"]:
            print(f"Test {variant} {configuration}", flush=True)
            _, receipt = command([args.swift, "test", *package_args, "-c", configuration, "--no-parallel"],
                                 review, f"{variant}-{configuration}-tests")
            log_text = (review / receipt["log"]).read_text()
            matches = re.findall(r"Test run with (\d+) tests?.*passed", log_text)
            if not matches:
                raise ValueError("Missing Swift Testing completion receipt")
            tests.append({"variant": variant, "configuration": configuration,
                          "passed_tests": int(matches[-1]), **receipt})
            save(review / "tests.json", tests)
        # Restore ordinary release products after test builds, then hash the executed bytes.
        for product in ["IlliquidStateSpaceExplorer", "StateSpaceParity"]:
            command([args.swift, "build", *package_args, "-c", "release", "--product", product],
                    review, f"{variant}-build-{product}")
        bin_path, _ = command([args.swift, "build", *package_args, "-c", "release", "--show-bin-path"],
                              review, f"{variant}-bin-path")
        binaries[variant] = Path(bin_path.strip()) / "IlliquidStateSpaceExplorer"
        parity_binaries[variant] = Path(bin_path.strip()) / "StateSpaceParity"
        manifest["binary_hashes"][variant] = sha256(binaries[variant].read_bytes())
        save(review / "manifest.json", manifest)

    parity = {}
    for variant in ["baseline", "candidate"]:
        output, _ = command([parity_binaries[variant]], review, f"{variant}-parity")
        parity[variant] = compact_parity(json.loads(output))
    save(review / "parity.json", parity)
    if parity["baseline"] != parity["candidate"]:
        raise ValueError("Graph, predecessor, POR, or counterexample replay receipts differ")
    expected_seeds = {(entry["model"], seed) for entry in parity["baseline"]["inventory"]
                      for seed in entry["seeds"]}
    print(f"Exact validation/POR/replay parity passed; {len(expected_seeds)} PR seeds", flush=True)

    # Warm both executables before primary timings. These samples are not reported as wins.
    for variant in ["baseline", "candidate"]:
        command([binaries[variant], "--profile", "pr", "--model", "seek",
                 "--seed", "ready-playing", "--output", review / "warmup" / variant],
                review, f"{variant}-warmup")

    reference = None
    measurements = []
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        for position, variant in enumerate(order):
            print(f"Measure pair {pair + 1}/{args.pairs}: {variant}", flush=True)
            directory = review / "runs" / f"pair-{pair}" / variant
            _, receipt = command(
                [binaries[variant], "--profile", "pr", "--all-seeds", "--output", directory],
                review, f"pair-{pair}-{variant}",
                extra_env={"ILLIQUID_SOURCE_REVISION": baseline if variant == "baseline" else candidate,
                           "ILLIQUID_SOURCE_DIRTY": "1" if variant == "candidate" and candidate_dirty else "0"})
            records = normalized_records(directory)
            observed_seeds = {(r["summary"]["model"], r["summary"]["seedProfile"]) for r in records}
            if observed_seeds != expected_seeds or len(records) != len(expected_seeds):
                raise ValueError("PR seed inventory differs or contains duplicates")
            if reference is None:
                reference = records
                save(review / "canonical-results.json", reference)
            if records != reference:
                raise ValueError(f"Full PR search/progress output differs: pair {pair}, {variant}")
            measurements.append({"pair": pair, "position": position, "variant": variant,
                                 "seed_count": len(records),
                                 "state_count": sum(r["summary"]["stateCount"] for r in records),
                                 "edge_count": sum(r["summary"]["edgeCount"] for r in records),
                                 "semantic_sha256": json_digest(records), **receipt})
            save(review / "measurements.json", measurements)
            print(f"  {receipt['wall_seconds']:.3f}s wall, {receipt['cpu_seconds']:.3f}s CPU; exact parity", flush=True)

    summary = {}
    for metric in ["wall_seconds", "cpu_seconds"]:
        values = {variant: [r[metric] for r in measurements if r["variant"] == variant]
                  for variant in ["baseline", "candidate"]}
        ratios = []
        for pair in range(args.pairs):
            paired = {r["variant"]: r[metric] for r in measurements if r["pair"] == pair}
            ratios.append(paired["candidate"] / paired["baseline"])
        summary[metric] = {
            "baseline_median": statistics.median(values["baseline"]),
            "candidate_median": statistics.median(values["candidate"]),
            "baseline_range": [min(values["baseline"]), max(values["baseline"])],
            "candidate_range": [min(values["candidate"]), max(values["candidate"])],
            "paired_candidate_over_baseline": ratios,
            "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
        }
    save(review / "summary.json", summary)
    print(json.dumps(summary, indent=2), flush=True)
    evidence = {path.name: json.loads(path.read_text()) for path in [
        review / "manifest.json", review / "tests.json", review / "parity.json",
        review / "canonical-results.json", review / "measurements.json", review / "summary.json"]}
    # A compact, exact receipt also supports review when only GitHub API logs are available.
    print("STATE_SPACE_EVIDENCE_JSON " + json.dumps(evidence, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
