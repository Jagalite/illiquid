#!/usr/bin/env python3
"""Measure the real source-presence repair snapshot in balanced fresh processes.

Compiles verbatim baseline/candidate scanner snapshot blocks, their real Summary
type, and the complete candidate helper. Each retained-memory or timing sample
gets a new process. Input setup, semantic verification and JSON are unmeasured.
"""
from __future__ import annotations

import argparse
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
SCANNER = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
HELPER = "Sources/IlliquidApp/UI/SourceMediaPresenceSnapshot.swift"
SIDEBAR = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
NORMALIZED_URL = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
BASELINE_SHA256 = "a90ba7735ac9790bf7f7d3aa42233f4558c7712b4e22cab9c9fff92d87a6db1b"
BASELINE_IDENTITY_SHA256 = "3618ed409ed18dff737bbc352431b69e5e486100c898b05efdc518c075072654"
BASELINE_NORMALIZED_URL_SHA256 = "3b65c98b88722ca4d51c315a7fd5e2fde0e40c846071b6b1e34cd1f1eddb3fd2"
SCENARIOS = ("empty", "narrow8", "narrow256", "library", "root")
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourcePresenceSnapshotQualification", platforms: [.macOS("26.0")],
    products: [.executable(name: "SnapshotBenchmark", targets: ["SnapshotBenchmark"])],
    targets: [
        .target(name: "CSourcePresenceHeap", publicHeadersPath: "include"),
        .executableTarget(name: "SnapshotBenchmark", dependencies: ["CSourcePresenceHeap"]),
    ], swiftLanguageModes: [.v6]
)
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise ValueError(f"Expected exactly one declaration: {marker!r}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for position in range(opening, len(source)):
        depth += (source[position] == "{") - (source[position] == "}")
        if depth == 0:
            return source[start:position + 1]
    raise ValueError(f"Unclosed declaration: {marker!r}")


def shell(scanner: bytes, variant: str) -> tuple[bytes, dict]:
    source = scanner.decode()
    start = "                let jobRevision = self.revision\n"
    end = "                let cursor = SourceMediaPresenceCursor("
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("The production snapshot block extraction anchors changed")
    first, last = source.index(start) + len(start), source.index(end)
    if last <= first:
        raise ValueError("Snapshot block extraction anchors are reversed")
    block = source[first:last]
    expected = ("self.results.filter { entry in" if variant == "baseline"
                else "SourceMediaPresenceSnapshot.reusableResults(")
    if expected not in block or block.count("let reusableResults =") != 1:
        raise ValueError(f"Unexpected {variant} snapshot construction block")
    summary = declaration(source, "    struct Summary: Sendable {")
    generated = (
        "import Foundation\n\n"
        + f'let snapshotVariant = "{variant}"\n\n'
        + "enum SourceMediaPresenceCursor {\n" + summary + "\n}\n\n"
        + "struct SnapshotSubject {\n"
        + "    let results: [String: Bool]\n"
        + "    let summaries: [String: SourceMediaPresenceCursor.Summary]\n\n"
        + "    @inline(never)\n"
        + "    func snapshot(under path: String) -> [String: Bool] {\n"
        + block
        + "        return reusableResults\n"
        + "    }\n}\n"
    ).encode()
    return generated, {
        "snapshot_block_sha256": digest(block.encode()),
        "snapshot_block_first_line": source.count("\n", 0, first) + 1,
        "snapshot_block_last_line": source.count("\n", 0, last),
        "summary_sha256": digest(summary.encode()),
        "generated_shell_sha256": digest(generated),
        "transformations": "Snapshot block and Summary copied verbatim into a minimal collection owner; no Observation/UI/scanning code compiled",
    }


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError("Use a new, empty --output directory; old evidence is never overwritten")
        self.env = os.environ.copy()
        self.env.update(
            SWIFT_DETERMINISTIC_HASHING="1", TERM="dumb", NO_COLOR="1",
            CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
            SWIFT_MODULECACHE_PATH=str(self.output / "module-cache"),
        )
        self.binaries: dict[str, Path] = {}
        self.manifest = {
            "baseline_commit": BASELINE,
            "candidate_sources": "current worktree captured once before compilation",
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
            "method": "Sequential balanced AB/BA pairs; new process per variant and measurement mode",
            "memory_boundary": "Warm tiny collection paths, build source fixture, read allocator, construct one snapshot, read allocator with source dictionaries and snapshot alive; verify afterward",
            "timing_boundary": "Three warm constructions, then bracket each construction; same iterations per pair; destruction and result consumption outside brackets; both CPU and monotonic wall clocks",
            "scope": "Additional live allocator-accounted storage for a repair snapshot; neither RSS, whole-player memory nor copied string payload bytes",
            "environment": {"SWIFT_DETERMINISTIC_HASHING": "1"},
            "source_hashes": {}, "generated_sources": {}, "binary_hashes": {},
        }
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.exists():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in cpuinfo.read_text().splitlines() if line.startswith("model name")), "unknown")

    def append(self, name: str, value: object) -> None:
        with (self.output / name).open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")

    def command(self, arguments: list, *, log: str | None = None, timeout: int = 600) -> bytes:
        command = [str(value) for value in arguments]
        start = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, timeout=timeout)
        self.append("commands.jsonl", {
            "argv": command, "returncode": result.returncode,
            "wall_seconds": time.monotonic() - start,
            "stdout_sha256": digest(result.stdout), "stderr_sha256": digest(result.stderr),
            "stdout": result.stdout.decode(errors="replace"),
            "stderr": result.stderr.decode(errors="replace"),
        })
        if log:
            (self.output / log).write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n"
                               + (result.stdout + result.stderr).decode(errors="replace"))
        return result.stdout

    def snapshot(self, label: str, data: bytes) -> Path:
        path = self.output / "sources" / label
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.manifest["source_hashes"][label] = {
            "sha256": digest(data), "bytes": len(data),
            "git_blob_sha1": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
        }
        return path

    def save_manifest(self) -> None:
        save(self.output / "manifest.json", self.manifest)

    def prepare(self) -> None:
        self.manifest["toolchain"] = self.command([self.args.swift, "--version"]).decode().strip()
        self.manifest["checkout_head"] = self.command(["git", "rev-parse", "HEAD"]).decode().strip()
        baseline = (self.args.baseline_source.read_bytes() if self.args.baseline_source else
                    self.command(["git", "show", f"{BASELINE}:{SCANNER}"]))
        if digest(baseline) != BASELINE_SHA256:
            raise ValueError("Baseline scanner differs from the pinned source SHA-256")
        candidate = (ROOT / SCANNER).read_bytes()
        helper = (ROOT / HELPER).read_bytes()
        sidebar = (ROOT / SIDEBAR).read_bytes()
        identity = declaration(sidebar.decode(), "enum SourceTreeIdentity {")
        normalized_url = (ROOT / NORMALIZED_URL).read_bytes()
        if (digest(identity.encode()) != BASELINE_IDENTITY_SHA256
                or digest(normalized_url) != BASELINE_NORMALIZED_URL_SHA256):
            raise ValueError("Source identity support differs between baseline and candidate")
        self.snapshot("shared/SourcesSidebar.swift", sidebar)
        self.snapshot("shared/NormalizedFileURL.swift", normalized_url)
        identity_source = ("import Foundation\n\n" + identity + "\n").encode()
        self.snapshot("shared/SourceTreeIdentity.swift", identity_source)
        self.manifest["source_identity"] = {
            "declaration_sha256": digest(identity.encode()),
            "normalized_file_url_sha256": digest(normalized_url),
            "identical_to_baseline": True,
        }
        harness = (HERE / "Harness.swift").read_bytes()
        common = {
            "Harness.swift": harness,
            "CSourcePresenceHeap/heap.c": (HERE / "CSourcePresenceHeap/heap.c").read_bytes(),
            "CSourcePresenceHeap/include/CSourcePresenceHeap.h":
                (HERE / "CSourcePresenceHeap/include/CSourcePresenceHeap.h").read_bytes(),
        }
        self.snapshot("harness/run.py", Path(__file__).read_bytes())
        for name, data in common.items():
            self.snapshot("harness/" + name, data)
        self.snapshot("candidate/SourceMediaPresenceSnapshot.swift", helper)
        summary_hashes = []
        for variant, source in (("baseline", baseline), ("candidate", candidate)):
            self.snapshot(f"{variant}/SourceMediaPresenceScanner.swift", source)
            generated, receipt = shell(source, variant)
            summary_hashes.append(receipt["summary_sha256"])
            self.manifest["generated_sources"][variant] = receipt
            self.snapshot(f"{variant}/SnapshotSubject.swift", generated)
            package = self.output / "build" / variant
            executable = package / "Sources/SnapshotBenchmark"
            executable.mkdir(parents=True)
            (package / "Package.swift").write_text(PACKAGE)
            (executable / "Harness.swift").write_bytes(harness)
            (executable / "SnapshotSubject.swift").write_bytes(generated)
            (executable / "SourceTreeIdentity.swift").write_bytes(identity_source)
            (executable / "NormalizedFileURL.swift").write_bytes(normalized_url)
            if variant == "candidate":
                (executable / "SourceMediaPresenceSnapshot.swift").write_bytes(helper)
            for relative in ("heap.c", "include/CSourcePresenceHeap.h"):
                destination = package / "Sources/CSourcePresenceHeap" / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(common["CSourcePresenceHeap/" + relative])
        if len(set(summary_hashes)) != 1:
            raise ValueError("Baseline and candidate Summary layouts differ")
        self.manifest["package_sha256"] = digest(PACKAGE.encode())
        self.save_manifest()
        for variant in ("baseline", "candidate"):
            print(f"Build {variant} source snapshot", flush=True)
            package = self.output / "build" / variant
            base = [self.args.swift, "build", "--package-path", package, "--configuration", "release",
                    "--jobs", "2", "--cache-path", self.output / "package-cache",
                    "--config-path", self.output / "package-config",
                    "--security-path", self.output / "package-security",
                    "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-whole-module-optimization"]
            if platform.system() == "Linux":
                base.append("--use-integrated-swift-driver")
            self.command([*base, "--product", "SnapshotBenchmark"], log=f"{variant}-build.log")
            binary = Path(self.command([*base, "--show-bin-path"]).decode().strip()) / "SnapshotBenchmark"
            self.binaries[variant] = binary
            self.manifest["binary_hashes"][variant] = digest(binary.read_bytes())
        self.save_manifest()

    def observe(self, variant: str, mode: str, scenario: str, size: int, iterations: int) -> dict:
        value = json.loads(self.command([self.binaries[variant], mode, scenario, size, iterations]))
        expected = {"variant": variant, "mode": mode, "scenario": scenario,
                    "folders": size, "iterations": iterations}
        if any(value[key] != requested for key, requested in expected.items()):
            raise ValueError("Benchmark receipt does not match requested run")
        self.validate_receipt(value)
        return value

    @staticmethod
    def validate_receipt(value: dict) -> None:
        def integer(name: str, *, positive: bool = False) -> int:
            number = value[name]
            if type(number) is not int or number < (1 if positive else 0):
                raise ValueError(f"Invalid benchmark receipt field {name}: {number!r}")
            return number

        folders = integer("folders", positive=True)
        iterations = integer("iterations", positive=True)
        if integer("sourceResultsCount") != folders or integer("sourceSummariesCount") > folders:
            raise ValueError("Benchmark fixture counts do not match source storage")
        capacity = integer("snapshotCapacity")
        verification = value["verification"]
        for name in ("snapshotCount", "snapshotTrue", "snapshotFalse",
                     "relevantCount", "relevantTrue", "relevantFalse"):
            if type(verification[name]) is not int or not 0 <= verification[name] <= folders:
                raise ValueError(f"Invalid verification count: {name}")
        if verification["snapshotCount"] != verification["snapshotTrue"] + verification["snapshotFalse"] \
                or verification["relevantCount"] != verification["relevantTrue"] + verification["relevantFalse"] \
                or verification["snapshotCount"] > capacity:
            raise ValueError("Benchmark snapshot counts are inconsistent")
        if value["heapMetric"] not in {"malloc_zone_statistics(NULL).size_in_use",
                                      "mallinfo2.uordblks + mallinfo2.hblkhd"}:
            raise ValueError("Unsupported allocator metric in benchmark receipt")
        if value["mode"] == "memory":
            before = integer("heapBeforeBytes")
            after = integer("heapWithSnapshotBytes")
            delta = value["retainedAllocatorDeltaBytes"]
            if type(delta) is not int or delta != after - before or iterations != 1:
                raise ValueError("Invalid retained-memory boundary receipt")
            if any(value.get(name) is not None for name in ("constructionWallNanoseconds",
                                                       "constructionCPUNanoseconds", "consumedCountAndCapacity")):
                raise ValueError("Memory observation contains timing values")
        elif value["mode"] == "timing":
            integer("constructionWallNanoseconds", positive=True)
            integer("constructionCPUNanoseconds", positive=True)
            if integer("consumedCountAndCapacity") != iterations * (verification["snapshotCount"] + capacity):
                raise ValueError("Timed snapshot consumption differs from the verified output")
            if any(value.get(name) is not None for name in ("heapBeforeBytes", "heapWithSnapshotBytes",
                                                       "retainedAllocatorDeltaBytes")):
                raise ValueError("Timing observation contains memory values")
        else:
            raise ValueError("Unknown measurement mode in benchmark receipt")

    @staticmethod
    def parity(baseline: dict, candidate: dict) -> None:
        for key in ("relevantCount", "relevantTrue", "relevantFalse", "relevantDigest"):
            if baseline["verification"][key] != candidate["verification"][key]:
                raise ValueError(f"Reachable snapshot parity failed for {key}")
        if candidate["verification"]["snapshotCount"] != candidate["verification"]["relevantCount"]:
            raise ValueError("Candidate retained unreachable results")
        if candidate["scenario"] in ("root", "library"):
            if baseline["verification"] != candidate["verification"]:
                raise ValueError("Full-library/root control changed result content")

    def run(self) -> None:
        rows = []
        calibrations = []
        for size in self.args.sizes:
            for scenario in self.args.scenarios:
                if self.args.iterations is None:
                    samples = {variant: self.observe(variant, "timing", scenario, size, 3)
                               for variant in ("baseline", "candidate")}
                    self.parity(samples["baseline"], samples["candidate"])
                    slowest = max(value["constructionWallNanoseconds"] / value["iterations"]
                                  for value in samples.values())
                    iterations = max(3, min(100_000, math.ceil(self.args.target_ms * 1e6 / max(1, slowest))))
                    calibrations.append({"folders": size, "scenario": scenario, "iterations": iterations,
                                         "observations": samples})
                    save(self.output / "calibration.json", calibrations)
                else:
                    iterations = self.args.iterations
                for mode in ("memory", "timing"):
                    for pair in range(self.args.pairs):
                        order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                        observations = {}
                        for variant in order:
                            row = self.observe(variant, mode, scenario, size, iterations if mode == "timing" else 1)
                            row.update(pair=pair, order="AB" if pair % 2 == 0 else "BA")
                            observations[variant] = row
                            self.append("observations.jsonl", row)
                            rows.append(row)
                        self.parity(observations["baseline"], observations["candidate"])
                print(f"Verified {size} folders / {scenario} / {self.args.pairs} pairs per mode", flush=True)
        save(self.output / "summary.json", summarize(rows))
        self.manifest["completed_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.manifest["observations"] = len(rows)
        self.manifest["all_pair_parity_checks_passed"] = True
        self.save_manifest()


def describe(values: list[float]) -> dict:
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}


def summarize(rows: list[dict]) -> dict:
    cases = []
    for size, scenario in sorted({(row["folders"], row["scenario"]) for row in rows}):
        selected = [row for row in rows if row["folders"] == size and row["scenario"] == scenario]
        result = {"folders": size, "scenario": scenario}
        for mode, key, label in (
            ("memory", "retainedAllocatorDeltaBytes", "retained_allocator_delta_bytes"),
            ("timing", "constructionWallNanoseconds", "construction_wall_ns_per_snapshot"),
            ("timing", "constructionCPUNanoseconds", "construction_cpu_ns_per_snapshot"),
        ):
            observations = [row for row in selected if row["mode"] == mode]
            per_variant = {variant: [row[key] / row["iterations"] for row in observations
                                    if row["variant"] == variant]
                           for variant in ("baseline", "candidate")}
            result[label] = {variant: describe(values) for variant, values in per_variant.items()}
            pairs = {index: {row["variant"]: row[key] / row["iterations"] for row in observations
                             if row["pair"] == index}
                     for index in {row["pair"] for row in observations}}
            changes = [(pair["candidate"] / pair["baseline"] - 1) * 100
                       for pair in pairs.values() if pair["baseline"] > 0]
            result[label]["paired_percent_change"] = describe(changes) if changes else None
        example = {variant: next(row for row in selected if row["variant"] == variant and row["mode"] == "memory")
                   for variant in ("baseline", "candidate")}
        result["snapshot_counts"] = {variant: row["verification"]["snapshotCount"] for variant, row in example.items()}
        result["snapshot_capacities"] = {variant: row["snapshotCapacity"] for variant, row in example.items()}
        result["relevant_count"] = example["candidate"]["verification"]["relevantCount"]
        result["relevant_digest"] = example["candidate"]["verification"]["relevantDigest"]
        cases.append(result)
    return {"observations": len(rows), "all_reachable_content_parity_checks_passed": True,
            "metric_warning": "Allocator-accounted retained growth is not RSS, total player memory, peak allocation, or copied string bytes",
            "cases": cases}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline-source", type=Path,
                        help="Use retained baseline scanner bytes if the pinned commit is absent; SHA-256 must match")
    parser.add_argument("--sizes", default="1000,10000,100000")
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--iterations", type=int, help="Use fixed equal iterations instead of per-case calibration")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    args.sizes = [int(value) for value in args.sizes.split(",")]
    args.scenarios = args.scenarios.split(",")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive and even for balanced AB/BA order")
    if not args.sizes or any(size < 1 for size in args.sizes):
        parser.error("--sizes must contain positive integers")
    if not args.scenarios or any(case not in SCENARIOS for case in args.scenarios):
        parser.error(f"--scenarios must be selected from {SCENARIOS}")
    if args.target_ms <= 0 or (args.iterations is not None and args.iterations < 1):
        parser.error("--target-ms and --iterations must be positive")
    runner = Runner(args)
    runner.prepare()
    if not args.prepare_only:
        runner.run()
    print(f"Evidence: {runner.output}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Source-presence snapshot qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
