#!/usr/bin/env python3
"""Compare bitmap-subtitle timeline lookups using production sources.

Default mode requires native macOS Foundation/CoreGraphics. Explicit
--portable-linux mode uses the official Swift toolchain's real Foundation
geometry types and only removes unconditional, exact CoreGraphics import lines
from compile copies. It does not supply geometry or platform stubs.

Compile the timeline and budget whole, plus the exact ASSRenderedRegion
declaration. Compile the benchmark driver separately from the optimized
production module. These are warm in-memory component measurements, not
renderer or whole-player measurements. Portable results do not qualify macOS.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import platform
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TIMELINE = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
BUDGET = "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift"
REGIONS = "Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift"
TEST_DIRECTORY = "Tests/IlliquidNativePlaybackTests"
TESTS = [
    "BitmapSubtitleTimelineOrderingTests.swift",
    "SubtitleMemoryBudgetAccountingTests.swift",
    "BitmapSubtitleLookupTests.swift",
]
VARIANTS = ("baseline", "candidate")
QUERIES_PER_CYCLE = 16
UINT64_MASK = (1 << 64) - 1


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def lookup_sections(source: bytes) -> tuple[bytes, bytes, bytes]:
    start_marker = b"    func composition(at seconds: Double)"
    end_marker = b"    mutating func prune(before seconds: Double)"
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError("Timeline lookup boundaries changed")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[:start], source[start:end], source[end:]


def region_declaration(source: bytes) -> tuple[bytes, dict]:
    start_marker = b"struct ASSRenderedRegion: Sendable {"
    end_marker = b"struct ASSRenderResult: Sendable {"
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError("ASSRenderedRegion declaration boundaries changed")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    declaration = source[start:end]
    compiled = b"import Foundation\nimport CoreGraphics\n\n" + declaration
    return compiled, {
        "start_byte_inclusive": start, "end_byte_exclusive": end,
        "original_sha256": sha(source), "declaration_sha256": sha(declaration),
        "compiled_source_sha256": sha(compiled),
    }


class Runner:
    def __init__(self, args):
        self.portable_linux = args.portable_linux
        system = platform.system()
        if self.portable_linux:
            if system != "Linux":
                raise ValueError("--portable-linux requires Linux; omit it for native macOS")
        elif system != "Darwin":
            raise ValueError("Default mode requires native macOS; explicitly select --portable-linux on Linux")
        self.platform_mode = "portable-linux-foundation" if self.portable_linux else "native-macos"
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.swiftc = args.swiftc or shutil.which("swiftc") or "swiftc"
        adjacent_swift = Path(self.swiftc).parent / "swift"
        self.swift = args.swift or (str(adjacent_swift) if adjacent_swift.is_file() else
                                    shutil.which("swift") or "swift")
        self.calibration = {}
        self.controls = {}
        self.cases = []
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "sources": {},
            "binaries": {},
            "mode": ("portable-linux-foundation-timeline-lookup" if self.portable_linux else
                     "native-production-timeline-lookup"),
            "platform_mode": self.platform_mode,
            "adaptation": ("Complete timeline/budget and exact ASSRenderedRegion declaration; "
                           "only unconditional exact import CoreGraphics lines removed from compile copies; "
                           "real Swift Foundation geometry, no substitute types."
                           if self.portable_linux else
                           "Complete timeline/budget; exact ASSRenderedRegion declaration with Foundation/CoreGraphics imports."),
            "compile_copies": {},
            "queries_per_cycle": QUERIES_PER_CYCLE,
            "timing_protocol": {
                "pairs": args.pairs, "target_ms": args.target_ms,
                "minimum_ms": args.minimum_ms, "order": "alternating AB/BA",
                "processes": "fresh process for every pilot and observation",
            },
        }
        self.receipt["candidate_revision"] = self.command(["git", "rev-parse", "HEAD"]).strip()
        self.receipt["compiler"] = self.command([self.swiftc, "--version"]).strip()
        self.receipt["swift_test_compiler"] = self.command([self.swift, "--version"]).strip()
        if self.portable_linux:
            self.receipt["hardware"] = platform.processor() or platform.machine()
            self.receipt["libc"] = list(platform.libc_ver())
            self.receipt["sdk_version"] = None
            cpuinfo = Path("/proc/cpuinfo")
            if cpuinfo.is_file():
                for line in cpuinfo.read_text().splitlines():
                    if line.startswith(("model name", "Hardware")) and ":" in line:
                        self.receipt["hardware"] = line.split(":", 1)[1].strip()
                        break
        else:
            self.receipt["hardware"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
            self.receipt["sdk_version"] = self.command(["xcrun", "--show-sdk-version"]).strip()

    def command_bytes(self, argv, *, log: Path | None = None) -> bytes:
        argv = [str(item) for item in argv]
        index = len(self.commands) + 1
        directory = self.output / "commands"
        directory.mkdir(exist_ok=True)
        prefix = directory / f"{index:04d}"
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout_path = prefix.with_suffix(".stdout")
        stderr_path = prefix.with_suffix(".stderr")
        stdout_path.write_bytes(result.stdout)
        stderr_path.write_bytes(result.stderr)
        record = {
            "index": index, "argv": argv, "cwd": str(ROOT),
            "returncode": result.returncode, "elapsed_seconds": time.monotonic() - start,
            "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
            "stdout_path": str(stdout_path.relative_to(self.output)),
            "stderr_path": str(stderr_path.relative_to(self.output)),
        }
        self.commands.append(record)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_bytes(result.stdout + b"\n--- stderr ---\n" + result.stderr)
        if result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}): {argv}\n"
                f"{result.stdout[-4000:].decode(errors='replace')}\n"
                f"{result.stderr[-8000:].decode(errors='replace')}"
            )
        return result.stdout

    def command(self, argv, *, log: Path | None = None) -> str:
        return self.command_bytes(argv, log=log).decode("utf-8")

    def source(self, path: str, variant: str) -> bytes:
        value = ((ROOT / path).read_bytes() if variant == "candidate" else
                 self.command_bytes(["git", "show", f"{BASELINE}:{path}"]))
        destination = self.output / "sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(value)
        self.receipt["sources"][f"{variant}:{path}"] = {
            "sha256": sha(value), "bytes": len(value),
            "staged_path": str(destination.relative_to(self.output)),
        }
        return value

    def compile_copy(self, label: str, source: bytes) -> bytes:
        """Remove only exact unconditional CoreGraphics imports, retaining native bytes."""
        removed_lines = []
        compiled = source
        if self.portable_linux:
            lines = source.splitlines(keepends=True)
            kept = []
            for index, line in enumerate(lines):
                # An existing guarded import already compiles on Linux unchanged.
                guarded = (index > 0 and index + 1 < len(lines) and
                           lines[index - 1] == b"#if canImport(CoreGraphics)\n" and
                           lines[index + 1] == b"#endif\n")
                if line == b"import CoreGraphics\n" and not guarded:
                    removed_lines.append(index + 1)
                else:
                    kept.append(line)
            compiled = b"".join(kept)
        self.receipt["compile_copies"][label] = {
            "original_sha256": sha(source), "compiled_sha256": sha(compiled),
            "original_bytes": len(source), "compiled_bytes": len(compiled),
            "removed_exact_line": "import CoreGraphics\n" if removed_lines else None,
            "removed_one_based_line_numbers": removed_lines,
            "removed_line_count": len(removed_lines),
            "transformation": "remove-exact-unconditional-CoreGraphics-imports" if removed_lines else "none",
        }
        return compiled

    def prepare(self):
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        self.receipt["candidate_status"] = self.command([
            "git", "status", "--porcelain", "--", TIMELINE, BUDGET, REGIONS,
            *[f"{TEST_DIRECTORY}/{name}" for name in TESTS],
            "Benchmarks/BitmapSubtitleLookup",
        ])
        sources = {v: {path: self.source(path, v) for path in (TIMELINE, BUDGET, REGIONS)}
                   for v in VARIANTS}
        old = lookup_sections(sources["baseline"][TIMELINE])
        new = lookup_sections(sources["candidate"][TIMELINE])
        if old[0] != new[0] or old[2] != new[2]:
            raise ValueError("Production timeline changed outside composition(at:)")
        if old[1] == new[1]:
            raise ValueError("Candidate lookup is identical to the baseline")
        if sources["baseline"][BUDGET] != sources["candidate"][BUDGET]:
            raise ValueError("Shared subtitle budget changed; review/requalify this comparison")
        regions = {v: region_declaration(sources[v][REGIONS]) for v in VARIANTS}
        if regions["baseline"][0] != regions["candidate"][0]:
            raise ValueError("Shared ASSRenderedRegion declaration changed")
        self.receipt["region_extraction"] = {v: regions[v][1] for v in VARIANTS}
        self.receipt["lookup_sha256"] = {"baseline": sha(old[1]), "candidate": sha(new[1])}

        staged = {}
        for variant in VARIANTS:
            directory = self.output / "compile" / variant / "sources"
            directory.mkdir(parents=True)
            staged[variant] = []
            for path in (TIMELINE, BUDGET):
                destination = directory / Path(path).name
                destination.write_bytes(self.compile_copy(f"{variant}:{path}", sources[variant][path]))
                staged[variant].append(destination)
            region = directory / "ASSRenderedRegion.swift"
            region.write_bytes(self.compile_copy(f"{variant}:ASSRenderedRegion.swift", regions[variant][0]))
            staged[variant].append(region)
        test_sources = {}
        for index, name in enumerate(TESTS):
            path = f"{TEST_DIRECTORY}/{name}"
            value = self.source(path, "candidate")
            if index < 2 and self.source(path, "baseline") != value:
                raise ValueError(f"Existing regression suite changed: {name}")
            test_sources[name] = value
        driver = self.output / "compile/Driver.swift"
        driver.write_bytes((HERE / "Driver.swift").read_bytes())
        self.receipt["driver_sha256"] = sha(driver.read_bytes())
        self.receipt["runner_sha256"] = sha(Path(__file__).read_bytes())
        shutil.copyfile(__file__, self.output / "runner.snapshot.py")
        self.test_variants(staged, test_sources)
        self.build(staged, driver)

    def test_variants(self, sources, tests):
        manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "BitmapSubtitleLookupRegressionTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
"""
        self.receipt["test_package_sha256"] = sha(manifest.encode())
        self.receipt["tests"] = {}
        for variant in VARIANTS:
            package = self.output / f"tests-{variant}"
            source_dir = package / "Sources/IlliquidNativePlayback"
            test_dir = package / "Tests/IlliquidNativePlaybackTests"
            source_dir.mkdir(parents=True)
            test_dir.mkdir(parents=True)
            for source in sources[variant]:
                shutil.copyfile(source, source_dir / source.name)
            for name, value in tests.items():
                (test_dir / name).write_bytes(self.compile_copy(f"{variant}:test:{name}", value))
            (package / "Package.swift").write_text(manifest)
            for configuration in ("debug", "release"):
                print(f"Testing {variant} {configuration} ({self.platform_mode})", flush=True)
                log = self.output / f"{variant}-{configuration}-tests.txt"
                self.command([
                    self.swift, "test", "--package-path", package, "--jobs", "2",
                    "--no-parallel", "-c", configuration, "-Xswiftc", "-warnings-as-errors",
                ], log=log)
                counts = re.findall(r"Test run with (\d+) tests?\b", log.read_text())
                if not counts or int(counts[-1]) <= 0:
                    raise ValueError(f"No completed Swift Testing run found for {variant}/{configuration}")
                self.receipt["tests"][f"{variant}:{configuration}"] = {
                    "passed": True, "reported_test_count": int(counts[-1]),
                    "log_sha256": sha(log.read_bytes()), "log_path": log.name,
                }
                write_json(self.output / "tests.json", self.receipt["tests"])
            products = (package.glob(".build/**/*.xctest") if self.portable_linux else
                        package.glob(".build/**/Contents/MacOS/*"))
            self.receipt.setdefault("test_binaries", {})[variant] = {
                str(path.relative_to(self.output)): sha(path.read_bytes())
                for path in sorted(products) if path.is_file()
            }

    def build(self, sources, driver):
        self.receipt["linked_dependencies"] = {}
        self.receipt["libraries"] = {}
        self.receipt["production_flags"] = [
            "-swift-version", "6", "-O", "-whole-module-optimization",
            "-enable-testing", "-warnings-as-errors", "-emit-library", "-emit-module",
        ]
        self.receipt["driver_flags"] = [
            "-swift-version", "6", "-O", "-warnings-as-errors", "-parse-as-library",
        ]
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            library = directory / ("libIlliquidNativePlayback.so" if self.portable_linux else
                                   "libIlliquidNativePlayback.dylib")
            module = directory / "IlliquidNativePlayback.swiftmodule"
            print(f"Building separate {variant} production module and driver", flush=True)
            self.command([
                self.swiftc, *self.receipt["production_flags"],
                "-module-name", "IlliquidNativePlayback", "-emit-module-path", module,
                *sources[variant], "-o", library,
            ], log=directory / "module-compile.log")
            binary = directory / "benchmark"
            self.command([
                self.swiftc, *self.receipt["driver_flags"],
                "-I", directory, "-L", directory, "-lIlliquidNativePlayback",
                "-Xlinker", "-rpath", "-Xlinker", directory, driver, "-o", binary,
            ], log=directory / "driver-compile.log")
            self.receipt["binaries"][variant] = sha(binary.read_bytes())
            library_hash_field = "shared_object_sha256" if self.portable_linux else "dylib_sha256"
            self.receipt["libraries"][variant] = {
                library_hash_field: sha(library.read_bytes()),
                "swiftmodule_sha256": sha(module.read_bytes()),
                "library_path": str(library.relative_to(self.output)),
            }
            linker_tool = ["ldd"] if self.portable_linux else ["otool", "-L"]
            self.receipt["linked_dependencies"][variant] = {
                "driver": self.command([*linker_tool, binary]),
                "module": self.command([*linker_tool, library]),
            }
        write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant, *args):
        return json.loads(self.command([self.output / variant / "benchmark", *args]))

    def verify(self):
        lists, traces = {}, {}
        for variant in VARIANTS:
            names = self.invoke(variant, "list")
            if (not isinstance(names, list) or not names or
                    any(not isinstance(name, str) or not name for name in names) or
                    len(names) != len(set(names))):
                raise ValueError(f"Invalid workload list from {variant}")
            lists[variant] = names
            write_json(self.output / f"{variant}-workloads.json", names)
            trace = self.invoke(variant, "verify")
            write_json(self.output / f"{variant}-trace.json", trace)
            traces[variant] = trace
        if lists["baseline"] != lists["candidate"]:
            raise ValueError("Baseline and candidate workload inventories differ")
        if traces["baseline"] != traces["candidate"]:
            raise ValueError("Complete lookup-result parity failed; inspect the saved traces")
        trace = traces["candidate"]
        rows = trace["rows"]
        if not rows:
            raise ValueError("Verification must include complete output rows")
        if len({row["name"] for row in rows}) != len(rows):
            raise ValueError("Verification row names must be unique")
        if any(not isinstance(row["result"], dict) or type(row["authoredExpectation"]) is not bool
               for row in rows):
            raise ValueError("Verification needs full snapshots and boolean expectation-presence flags")
        if not any(row["authoredExpectation"] for row in rows):
            raise ValueError("At least one independent authored expectation is required")
        self.cases = self.args.cases if self.args.cases is not None else lists["candidate"]
        if len(self.cases) != len(set(self.cases)):
            raise ValueError("Requested cases must be unique")
        unknown = set(self.cases) - set(lists["candidate"])
        if unknown:
            raise ValueError(f"Unknown workload(s): {sorted(unknown)}")
        summary = {
            "equal": True, "compared_cases": len(rows),
            "authored_expectations": sum(row["authoredExpectation"] for row in rows),
            "available_workloads": lists["candidate"], "selected_workloads": self.cases,
        }
        write_json(self.output / "parity.json", summary)
        print(f"Complete lookup-result parity: {len(rows)} cases", flush=True)

    def observation(self, variant, case, iterations):
        result = self.invoke(variant, "measure", case, str(iterations))
        if result["workload"] != case or result["iterations"] != iterations:
            raise ValueError(f"Workload/iteration receipt mismatch in {variant}/{case}")
        for field in ("iterations", "warmupIterations", "elapsedNanoseconds", "cpuNanoseconds"):
            if type(result[field]) is not int or result[field] <= 0:
                raise ValueError(f"Invalid positive integer {field} in {variant}/{case}")
        for field in ("iterations", "warmupIterations"):
            if result[field] % QUERIES_PER_CYCLE:
                raise ValueError(f"{field} must cover complete query cycles")
        if (not isinstance(result["queryTimes"], list) or
                len(result["queryTimes"]) != QUERIES_PER_CYCLE or
                any(type(value) not in (int, float) or not math.isfinite(value)
                    for value in result["queryTimes"])):
            raise ValueError("Query receipt must contain exactly 16 finite timestamps")
        if type(result["occupancy"]) is not int or result["occupancy"] < 0:
            raise ValueError("Timeline occupancy must be a nonnegative integer")
        for field in ("checksum", "cycleChecksum", "warmupChecksum"):
            if type(result[field]) is not int or not 0 <= result[field] <= UINT64_MASK:
                raise ValueError(f"Invalid UInt64 checksum {field}")
        if not isinstance(result["first"], dict) or not isinstance(result["last"], dict):
            raise ValueError("First and last results must be complete lookup snapshots")
        for checksum, count in (("checksum", "iterations"), ("warmupChecksum", "warmupIterations")):
            expected = (result["cycleChecksum"] * (result[count] // QUERIES_PER_CYCLE)) & UINT64_MASK
            if result[checksum] != expected:
                raise ValueError(f"Complete-cycle checksum mismatch in {variant}/{case}: {checksum}")
        controls = {field: result[field] for field in
                    ("cycleChecksum", "warmupChecksum", "warmupIterations", "first", "last", "queryTimes", "occupancy")}
        if case in self.controls and controls != self.controls[case]:
            raise ValueError(f"Timed output/fixture drift in {variant}/{case}")
        self.controls[case] = controls
        return result

    def calibrate(self, variant, case):
        iterations = 4_096
        pilots = []
        self.calibration.setdefault(case, {})[variant] = {"pilots": pilots}
        for _ in range(6):
            result = self.observation(variant, case, iterations)
            pilots.append(result)
            write_json(self.output / "calibration.json", self.calibration)
            measured = min(result["elapsedNanoseconds"], result["cpuNanoseconds"])
            if measured >= self.args.target_ms * 1_000_000:
                self.calibration[case][variant]["iterations"] = iterations
                write_json(self.output / "calibration.json", self.calibration)
                return iterations
            requested = math.ceil(iterations * self.args.target_ms * 1_000_000 * 1.25 / max(1, measured))
            iterations = max(iterations + QUERIES_PER_CYCLE,
                             math.ceil(requested / QUERIES_PER_CYCLE) * QUERIES_PER_CYCLE)
            if iterations > 100_000_000:
                raise ValueError("Calibration exceeds 100 million calls; inspect timer/optimizer")
        raise ValueError(f"Could not calibrate {variant}/{case}")

    def measure(self):
        summaries = []
        minimum = self.args.minimum_ms * 1_000_000
        all_durations_met = True
        observations = 0
        for case in self.cases:
            counts = {variant: self.calibrate(variant, case) for variant in VARIANTS}
            pairs = []
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                values = {}
                for variant in order:
                    record = self.observation(variant, case, counts[variant])
                    record.update({"variant": variant, "pair": pair, "order": list(order)})
                    values[variant] = record
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                    observations += 1
                pairs.append(values)
            summary = {
                "workload": case, "pairs": self.args.pairs, "iterations": counts,
                "query_times": pairs[0]["baseline"]["queryTimes"],
                "occupancy": pairs[0]["baseline"]["occupancy"],
                "minimum_required_ms": self.args.minimum_ms,
            }
            under_minimum = []
            for metric, field in (("wall", "elapsedNanoseconds"), ("cpu", "cpuNanoseconds")):
                normalized = {
                    variant: [p[variant][field] / p[variant]["iterations"] for p in pairs]
                    for variant in VARIANTS
                }
                old, new = (statistics.median(normalized[v]) for v in VARIANTS)
                ratios = [
                    p["candidate"][field] / p["candidate"]["iterations"]
                    / (p["baseline"][field] / p["baseline"]["iterations"]) for p in pairs
                ]
                summary[metric] = {
                    "baseline_ns_per_lookup": old, "candidate_ns_per_lookup": new,
                    "change_percent": (new / old - 1) * 100,
                    "median_paired_change_percent": (statistics.median(ratios) - 1) * 100,
                    "paired_ratios": ratios,
                    "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
                    "minimum_observed_ms": {
                        v: min(p[v][field] for p in pairs) / 1_000_000 for v in VARIANTS
                    },
                    "ranges_ns_per_lookup": {
                        v: [min(normalized[v]), max(normalized[v])] for v in VARIANTS
                    },
                }
                under_minimum.extend(
                    {"variant": v, "pair": p[v]["pair"], "metric": metric,
                     "observed_ms": p[v][field] / 1_000_000}
                    for p in pairs for v in VARIANTS if p[v][field] < minimum
                )
            summary["observations_under_minimum"] = under_minimum
            all_durations_met = all_durations_met and not under_minimum
            summaries.append(summary)
            write_json(self.output / "summary.json", summaries)
            wall = summary["wall"]
            print(
                f"{case}: {wall['baseline_ns_per_lookup']:.1f} -> "
                f"{wall['candidate_ns_per_lookup']:.1f} ns/lookup "
                f"({wall['median_paired_change_percent']:+.1f}% paired wall; "
                f"{summary['cpu']['median_paired_change_percent']:+.1f}% paired CPU)",
                flush=True,
            )
        expected = len(self.cases) * self.args.pairs * len(VARIANTS)
        if observations != expected:
            raise ValueError(f"Incomplete cohort: {observations} of {expected} observations")
        if not all_durations_met:
            raise ValueError("A final observation was under the required duration; preserve this cohort and increase --target-ms")
        return observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--swift", help="Swift package/test tool from the same toolchain as swiftc")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--portable-linux", action="store_true",
                        help="Explicit real-Foundation Linux qualification; does not qualify native macOS")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=240)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--cases", nargs="+", help="Subset of the driver's verified workload inventory")
    args = parser.parse_args()
    if args.pairs < 8 or args.pairs % 2:
        parser.error("Use an even number of at least eight alternating process pairs")
    if (not math.isfinite(args.minimum_ms) or not math.isfinite(args.target_ms) or
            args.minimum_ms < 60 or args.target_ms < max(240, args.minimum_ms)):
        parser.error("Use a target of at least 240 ms and a minimum of at least 60 ms; target >= minimum")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        runner.verify()
        observations = 0 if args.tests_only else runner.measure()
        write_json(runner.output / "completion.json", {
            "complete": True, "tests_only": args.tests_only,
            "platform_mode": runner.platform_mode,
            "minimum_observation_duration_met": None if args.tests_only else True,
            "minimum_ms": args.minimum_ms, "target_ms": args.target_ms,
            "pairs": args.pairs, "observations": observations,
            "workloads": runner.cases,
            "completed_utc": datetime.now(timezone.utc).isoformat(),
        })
    except BaseException as error:
        if runner:
            write_json(runner.output / "completion.json", {
                "complete": False, "platform_mode": runner.platform_mode,
                "error_type": type(error).__name__, "error": str(error),
                "failed_utc": datetime.now(timezone.utc).isoformat(),
            })
        raise
    finally:
        if runner:
            write_json(runner.output / "commands.json", runner.commands)
            write_json(runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()
