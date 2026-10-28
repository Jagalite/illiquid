#!/usr/bin/env python3
"""Compare the production thumbnail neighborhood with extracted pinned scheduler code."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SCHEDULER = "Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift"
HELPER = "Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift"
TEST = "Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift"
VARIANTS = ("baseline", "candidate")
MAX_ITERATIONS = 10_000_000
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailNeighborhoodQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "IlliquidApp", targets: ["IlliquidApp"])],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),
    ],
    swiftLanguageModes: [.v6]
)
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compact(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def positive(value: str) -> int:
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def extract_baseline(source: str) -> tuple[str, dict]:
    # Retain both exact old blocks. Only the receiver is renamed to the helper's
    # input; wrapper declarations and final property assignments are new.
    start = "        let playlist = player.viewStore.playlist.map(\\.url)\n"
    neighbors_end = "        var urls = current.map { [$0] } ?? []\n"
    distances_start = "        var distances: [URL: Int] = [:]\n"
    distances_end = "        let candidates = urls.map { url in\n"
    for marker in (start, neighbors_end, distances_start, distances_end):
        if source.count(marker) != 1:
            raise RuntimeError("Pinned scheduler extraction marker changed: " + marker)
    first = source.index(start)
    second = source.index(neighbors_end, first)
    third = source.index(distances_start, second)
    fourth = source.index(distances_end, third)
    neighbors = source[first:second]
    distances = source[third:fourth]
    expected_neighbors = (
        "        let playlist = player.viewStore.playlist.map(\\.url)\n"
        "        let anchor = current.flatMap { playlist.firstIndex(of: $0) }\n"
        "        let neighbors = anchor.map { index in\n"
        "            Array(playlist[max(0, index - 4)..<min(playlist.count, index + 5)])\n"
        "        } ?? []\n"
    )
    expected_distances = (
        "        var distances: [URL: Int] = [:]\n"
        "        if let anchor {\n"
        "            for index in max(0, anchor - 4)..<min(playlist.count, anchor + 5) {\n"
        "                distances[playlist[index]] = abs(index - anchor)\n"
        "            }\n"
        "        }\n"
    )
    if neighbors != expected_neighbors or distances != expected_distances:
        raise RuntimeError("Pinned baseline blocks differ from the reviewed implementation")
    wrapper = (
        "import Foundation\nimport IlliquidCore\n\n"
        "struct ThumbnailPlaylistNeighborhood: Sendable {\n"
        "    let urls: [URL]\n    let distances: [URL: Int]\n\n"
        "    init(playlist items: [FolderPlaylistItem], current: URL?) {\n"
        + neighbors.replace("player.viewStore.playlist", "items")
        + distances
        + "        self.urls = neighbors\n        self.distances = distances\n"
        + "    }\n}\n"
    )
    return wrapper, {
        "scheduler_sha256": digest(source.encode()),
        "neighbor_block_sha256": digest(neighbors.encode()),
        "distance_block_sha256": digest(distances.encode()),
        "wrapper_sha256": digest(wrapper.encode()),
        "adaptation": "Exact scheduler blocks; input receiver renamed to items; wrapper stores neighbors and distances.",
    }


def check_integration(baseline: str, candidate: str) -> dict:
    start = "    private func runPass(settings: ThumbnailPreferences, id: UUID) async {\n"
    suffix = "        let source = current, location = folder, now = Date()\n"
    end = "    private func canContinue(_ id: UUID) -> Bool {\n"
    def body(source):
        return source[source.index(start):source.index(end)]
    before, after = body(baseline), body(candidate)
    prefix = after[:after.index(suffix)]
    if prefix.count("player.viewStore.playlist") != 1:
        raise RuntimeError("Scheduler must pass the playlist to the helper exactly once")
    if "ThumbnailPlaylistNeighborhood(" not in prefix or "await " in prefix:
        raise RuntimeError("Neighborhood must be constructed by the helper before suspension")
    if "neighborhood.urls" not in prefix or "neighborDistance: neighborhood.distances[url]" not in prefix:
        raise RuntimeError("Scheduler candidates must use the helper's URLs and distances")
    if before[before.index(suffix):] != after[after.index(suffix):]:
        raise RuntimeError("Scheduler behavior after candidate construction changed")
    return {
        "passed": True,
        "candidate_scheduler_sha256": digest(candidate.encode()),
        "unchanged_run_pass_suffix_sha256": digest(after[after.index(suffix):].encode()),
        "scope": "Source integration guard; not a heap-lifetime measurement.",
    }


class Runner:
    def __init__(self, output: Path):
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("--output must be new or empty")
        (self.output / "logs").mkdir()
        self.sequence = 0

    def save(self, name: str, value) -> None:
        (self.output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        print("NEIGHBORHOOD_EVIDENCE " + name + " " + compact(value), flush=True)

    def command(self, command, name: str, timeout: int = 600, *, combine_output: bool = False) -> str:
        self.sequence += 1
        command = [str(part) for part in command]
        began = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        filename = f"{self.sequence:04d}-{name}.log"
        (self.output / "logs" / filename).write_text(result.stdout + result.stderr)
        entry = {"command": command, "exit_code": result.returncode,
                 "wall_seconds": time.monotonic() - began, "log": "logs/" + filename}
        with (self.output / "commands.jsonl").open("a") as handle:
            handle.write(compact(entry) + "\n")
        if result.returncode:
            print((result.stdout + result.stderr)[-20000:], flush=True)
            raise RuntimeError(f"{name} failed: exit {result.returncode}, see {filename}")
        return result.stdout + result.stderr if combine_output else result.stdout

    def measurement(self, binary: Path, workload: dict, iterations: int) -> dict:
        row = json.loads(self.command(
            [binary, "measure", workload["id"], iterations], "measure-" + workload["id"]
        ))
        if row["workload"] != workload or row["iterations"] != iterations:
            raise RuntimeError("Harness returned a different workload")
        return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=positive, default=6)
    parser.add_argument("--target-ms", type=positive, default=30)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two")
    runner = Runner(args.output)
    tests = []
    try:
        baseline = runner.command(["git", "show", BASELINE + ":" + SCHEDULER], "baseline-source")
        candidate_scheduler = (ROOT / SCHEDULER).read_text()
        wrapper, extraction = extract_baseline(baseline)
        integration = check_integration(baseline, candidate_scheduler)
        helper = (ROOT / HELPER).read_text()
        core = sorted((ROOT / "Sources/IlliquidCore").rglob("*.swift"))
        sources = runner.output / "sources"
        sources.mkdir()
        (sources / "baseline-scheduler.swift").write_text(baseline)
        (sources / "baseline-helper.swift").write_text(wrapper)
        (sources / "candidate-helper.swift").write_text(helper)
        for path in (HERE / "Harness.swift", HERE / "run.py", ROOT / TEST):
            shutil.copyfile(path, sources / path.name)
        shared_hashes = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in core}
        environment = {
            "baseline_commit": BASELINE,
            "candidate_commit": runner.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "candidate_status": runner.command(["git", "status", "--short"], "status").strip(),
            "platform": platform.platform(),
            "architecture": platform.machine(),
            "swift": runner.command(["swift", "--version"], "swift-version").strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "package_manifest": PACKAGE,
            "candidate_helper_sha256": digest(helper.encode()),
            "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
            "runner_sha256": digest(Path(__file__).read_bytes()),
            "tests_sha256": digest((ROOT / TEST).read_bytes()),
            "shared_core_sha256": shared_hashes,
            "baseline_extraction": extraction,
            "integration": integration,
            "measurement_scope": "Release neighborhood construction plus identical result consumption; fixture creation excluded.",
            "warmups_per_process": 8,
            "sampling": "Fresh process per variant/workload/pair; AB/BA order alternates; per-variant calibrated iteration counts.",
            "target_ms": args.target_ms,
            "pairs": args.pairs,
            "memory_scope": "Derived URL element payload, not measured allocations, heap/RSS, or lifetime across await.",
        }
        if platform.system() == "Darwin":
            environment["macos"] = runner.command(["sw_vers"], "macos").strip()
            environment["xcode"] = runner.command(["xcodebuild", "-version"], "xcode").strip()
            environment["cpu"] = runner.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        runner.save("environment.json", environment)
        # GitHub-hosted runners do not mount the shared Kyoto queue. Keep builds
        # serialized, and explicitly record that limitation before direct builds.
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        if not kyoto.exists():
            print("Kyoto is unavailable on this runner; using serialized isolated Swift package builds.", flush=True)
        else:
            print("Shared Kyoto queue detected; the caller must submit this entire runner through Kyoto as documented in AGENTS.md.", flush=True)
        binaries = {}
        with tempfile.TemporaryDirectory(prefix="illiquid-neighborhood-") as temporary:
            for variant in VARIANTS:
                package = Path(temporary) / variant
                app = package / "Sources/IlliquidApp"
                app.mkdir(parents=True)
                shutil.copytree(ROOT / "Sources/IlliquidCore", package / "Sources/IlliquidCore")
                (package / "Package.swift").write_text(PACKAGE)
                (app / "ThumbnailPlaylistNeighborhood.swift").write_text(wrapper if variant == "baseline" else helper)
                shutil.copyfile(HERE / "Harness.swift", app / "Harness.swift")
                target_tests = package / "Tests/IlliquidAppTests"
                target_tests.mkdir(parents=True)
                shutil.copyfile(ROOT / TEST, target_tests / Path(TEST).name)
                for configuration in ("debug", "release"):
                    command = ["swift", "test", "--package-path", package, "-c", configuration,
                               "--jobs", "2", "--no-parallel", "--filter", "ThumbnailPlaylistNeighborhoodTests"]
                    result = runner.command(command, f"tests-{variant}-{configuration}", combine_output=True)
                    tail = "\n".join(result.splitlines()[-12:])
                    if not re.search(r"Test run with 6 tests.*passed", result):
                        raise RuntimeError("Expected six passing shared neighborhood tests in test output")
                    tests.append({"variant": variant, "configuration": configuration,
                                  "passed": True, "output_tail": tail})
                    print(tail, flush=True)
                runner.command(["swift", "build", "--package-path", package, "-c", "release",
                                "--jobs", "2", "--product", "IlliquidApp"], "build-" + variant)
                binpath = runner.command(["swift", "build", "--package-path", package, "-c", "release",
                                          "--jobs", "2", "--show-bin-path"], "bin-path-" + variant).strip()
                binaries[variant] = Path(binpath) / "IlliquidApp"
            runner.save("tests.json", tests)
            environment["binary_sha256"] = {
                variant: digest(binary.read_bytes()) for variant, binary in binaries.items()
            }
            runner.save("environment.json", environment)
            workloads = json.loads(runner.command([binaries["baseline"], "--list"], "workloads"))
            if workloads != json.loads(runner.command([binaries["candidate"], "--list"], "candidate-workloads")):
                raise RuntimeError("Baseline/candidate workload lists differ")
            runner.save("workloads.json", workloads)
            expected = {}
            canonical = []
            for workload in workloads:
                traces = [json.loads(runner.command(
                    [binaries[variant], "verify", workload["id"]], "verify-" + variant + "-" + workload["id"]
                )) for variant in VARIANTS]
                if traces[0] != traces[1]:
                    raise RuntimeError("Full output mismatch for " + workload["id"])
                expected[workload["id"]] = traces[0]
                canonical.append(traces[0])
            runner.save("canonical.json", {"equal": True, "workloads": canonical})
            counts = {}
            target = args.target_ms * 1_000_000
            for workload in workloads:
                identifier = workload["id"]
                counts[identifier] = {}
                trials = {}
                for variant in VARIANTS:
                    iterations = 1
                    trials[variant] = []
                    for _ in range(6):
                        row = runner.measurement(binaries[variant], workload, iterations)
                        trials[variant].append(row)
                        if row["elapsedNanoseconds"] >= target / 2 or iterations == MAX_ITERATIONS:
                            break
                        iterations = min(MAX_ITERATIONS, max(iterations + 1, math.ceil(
                            iterations * target / max(1, row["elapsedNanoseconds"])
                        )))
                    counts[identifier][variant] = row["iterations"]
                runner.save("calibration-" + identifier + ".json", {
                    "workload": workload, "iterations": counts[identifier], "trials": trials
                })
            rows = []
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                ordered = workloads[pair % len(workloads):] + workloads[:pair % len(workloads)]
                for workload in ordered:
                    for position, variant in enumerate(order):
                        identifier = workload["id"]
                        row = runner.measurement(binaries[variant], workload, counts[identifier][variant])
                        reference = expected[identifier]
                        if (row["consumedValue"] != reference["consumedValue"]
                                or row["urlCount"] != len(reference["urls"])
                                or row["distanceCount"] != len(reference["distances"])
                                or row["urlStride"] != reference["urlStride"]):
                            raise RuntimeError("Timed result differs from canonical receipt")
                        row.update(variant=variant, pair=pair, position_in_pair=position)
                        rows.append(row)
                        with (runner.output / "measurements.jsonl").open("a") as handle:
                            handle.write(compact(row) + "\n")
                        print("NEIGHBORHOOD_MEASUREMENT " + compact(row), flush=True)
                print(f"Completed AB/BA pair {pair + 1}/{args.pairs}", flush=True)
            summaries = []
            for workload in workloads:
                identifier = workload["id"]
                selected = [row for row in rows if row["workload"]["id"] == identifier]
                entry = {"workload": workload, "iterations": counts[identifier], "pairs": args.pairs}
                for label, metric in (("wall", "nanosecondsPerCall"), ("cpu", "cpuNanosecondsPerCall")):
                    before = [next(row[metric] for row in selected
                                   if row["variant"] == "baseline" and row["pair"] == pair)
                              for pair in range(args.pairs)]
                    after = [next(row[metric] for row in selected
                                  if row["variant"] == "candidate" and row["pair"] == pair)
                             for pair in range(args.pairs)]
                    entry[label] = {
                        "baseline_median_ns_per_call": statistics.median(before),
                        "candidate_median_ns_per_call": statistics.median(after),
                        "paired_median_reduction_percent": statistics.median(
                            100 * (1 - candidate / baseline) for baseline, candidate in zip(before, after)),
                        "candidate_faster_pairs": sum(candidate < baseline for baseline, candidate in zip(before, after)),
                        "baseline_ns_per_call": before, "candidate_ns_per_call": after,
                    }
                reference = expected[identifier]
                entry["derived_storage"] = {
                    "baseline_mapped_url_elements": workload["count"],
                    "candidate_full_playlist_mapped_url_elements": 0,
                    "returned_url_elements": len(reference["urls"]),
                    "returned_distance_entries": len(reference["distances"]),
                    "url_stride": reference["urlStride"],
                    "removed_mapped_element_payload_bytes": workload["count"] * reference["urlStride"],
                    "interpretation": "Source-level element count times MemoryLayout<URL>.stride. Excludes allocator rounding, headers, URL backing objects; no measured heap/RSS or async retention claim.",
                }
                summaries.append(entry)
            runner.save("summary.json", {
                "status": "passed", "test_runs": len(tests), "tests_per_run": 6,
                "verified_workloads": len(workloads), "measurements": len(rows),
                "pairs": args.pairs, "target_ms": args.target_ms, "results": summaries,
            })
    except BaseException as error:
        runner.save("failure.json", {"status": "failed", "error": f"{type(error).__name__}: {error}",
                                     "completed_test_runs": tests})
        raise


if __name__ == "__main__":
    main()
