#!/usr/bin/env python3
"""Compare exact startup handoff sources in isolated native source-owner probes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
APP = "Sources/IlliquidApp/App/AppModel.swift"
LOADER = "Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift"
SNAPSHOT = "Sources/IlliquidApp/App/SourceStartupSnapshot.swift"
CORE = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
VARIANTS = ("baseline", "candidate")
COUNTS = (0, 100, 10_000, 100_000)
MODES = ("close", "unchanged")
BOUNDS = {
    "startup": ("    private static var sharedInstance: AppModel?", "\n    static func handleStartupOpenURLs("),
    "properties": ("    private(set) var sourceTabs: [SourceTab]", "\n    @ObservationIgnored var sourceNavigation"),
    "close": ("    func closeSourceTab(_ id: String) {", "\n    func removeSourceItem("),
    "types": ("enum SourceFolderLibrary {", "\nprivate struct PlaybackLifecycleObservation:"),
}
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "StartupSourceLifetimeQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "StartupSourceLifetimeProbe", targets: ["StartupSourceLifetimeProbe"])],
    targets: [
        .target(name: "CStartupMemory", publicHeadersPath: "include"),
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "StartupSourceLifetimeProbe", dependencies: ["IlliquidApp", "CStartupMemory"]),
    ]
)
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def excerpt(source: str, name: str) -> str:
    start, end = BOUNDS[name]
    if source.count(start) != 1 or source.count(end) != 1 or source.index(start) >= source.index(end):
        raise ValueError("Production extraction boundaries changed: " + name)
    text = source[source.index(start):source.index(end)]
    if text.count("{") != text.count("}"):
        raise ValueError("Unbalanced production excerpt: " + name)
    return text


def expected_receipt(count: int, closed: bool = False) -> dict:
    # Independent oracle for deterministic ASCII paths after the real URL
    # normalization/decoding path. No source collections are copied into results.
    prefix = "/media/startup-lifetime/" + "collection-segment-0123456789/" * 7
    value = 14_695_981_039_346_656_037
    total_bytes = 0
    for index in range(0 if closed else count):
        path = (prefix + f"episode-{index:06d}.mkv").encode()
        total_bytes += len(path)
        for byte in path + b"\0":
            value = ((value ^ byte) * 1_099_511_628_211) & ((1 << 64) - 1)
    return {"tabs": 0 if closed else 1, "items": 0 if closed else count,
            "pathUTF8Bytes": total_bytes, "orderedPathChecksum": format(value, "x"),
            "selectedID": None if closed else "startup-tab"}


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use a new or empty output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        self.env = os.environ.copy()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                        CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"))
        self.commands = []
        self.rows = []
        self.binaries = {}
        self.source_bytes = {}
        self.swift = shutil.which(os.environ.get("SWIFT", "swift"))
        if self.swift is None:
            raise ValueError("Swift is unavailable")
        self.bench_sources = {str(p.relative_to(HERE)): p.read_bytes() for p in [
            Path(__file__), HERE / "Owner.swift.in", HERE / "Stubs.swift", HERE / "Driver.swift",
            HERE / "CMemory/memory.c", HERE / "CMemory/include/StartupMemory.h"]}
        self.manifest = {
            "schema_version": 1, "baseline_revision": BASELINE,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "candidate_relevant_status": self.command(["git", "status", "--short", "--",
                APP, LOADER, SNAPSHOT, CORE, str(HERE.relative_to(ROOT))], "status"),
            "environment": {"platform": platform.platform(), "machine": platform.machine(),
                "swift": self.command([self.swift, "--version"], "swift-version").strip(),
                "swift_command": self.swift, "developer_dir": self.env.get("DEVELOPER_DIR"),
                "system": self.command(["sw_vers"], "system").strip()},
            "benchmark_sources": {name: sha(data) for name, data in self.bench_sources.items()},
            "package_sha256": sha(PACKAGE.encode()), "extraction_boundaries": BOUNDS,
            "pairs": args.pairs, "counts": COUNTS, "modes": MODES,
            "scope": "Native staged AppModel source ownership; exact production startup/loadShared/close excerpts and loader/source types",
            "excluded": "Native player graph, source root indexing, real preference stores and writes, UI, playback, shared persistence history",
            "memory_measurement": "Live malloc/all-zone statistics plus current Mach resident/footprint and process peak RSS; no whole-app estimate",
        }
        for name, data in self.bench_sources.items():
            target = self.output / "benchmark-source" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.expected = {count: expected_receipt(count) for count in COUNTS}
        self.expected_closed = expected_receipt(0, closed=True)
        save(self.output / "oracle.json", {"published": self.expected, "closed": self.expected_closed})

    def command(self, args, label, timeout=600):
        args = [str(x) for x in args]
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=timeout)
        log = self.output / "logs" / (f"{len(self.commands):04d}-" + label + ".log")
        log.write_text(result.stdout + result.stderr)
        self.commands.append({"argv": args, "returncode": result.returncode,
                              "seconds": time.monotonic() - started,
                              "stdout_sha256": sha(result.stdout.encode()),
                              "stderr_sha256": sha(result.stderr.encode()),
                              "log": str(log.relative_to(self.output))})
        save(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"Command failed: {label}\n{result.stdout[-3000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def prepare(self):
        original = {}
        extractions = {}
        for variant in VARIANTS:
            original[variant] = {}
            for name in (APP, LOADER, SNAPSHOT, CORE):
                data = ((ROOT / name).read_bytes() if variant == "candidate" else
                        subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT))
                original[variant][name] = data
                target = self.output / "production-source" / variant / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                self.source_bytes[f"{variant}:{name}"] = data
            extractions[variant] = {name: excerpt(original[variant][APP].decode(), name) for name in BOUNDS}
        for name in (SNAPSHOT, CORE):
            if original["baseline"][name] != original["candidate"][name]:
                raise ValueError("Unrelated production source changed: " + name)
        for name in ("properties", "close", "types"):
            if extractions["baseline"][name] != extractions["candidate"][name]:
                raise ValueError("Unrelated production excerpt changed: " + name)
        if "guard let startup = await historyStartup.load()" not in extractions["baseline"]["startup"]:
            raise ValueError("Pinned baseline does not contain the expected legacy handoff")
        if "await historyStartup.loadShared(" not in extractions["candidate"]["startup"]:
            raise ValueError("Candidate does not exercise the production shared-publication helper")
        self.manifest["production_sources"] = {name: sha(data) for name, data in self.source_bytes.items()}
        self.manifest["excerpts"] = {v: {name: sha(text.encode()) for name, text in values.items()}
                                     for v, values in extractions.items()}
        self.manifest["compiled_sources"] = {}
        self.manifest["binaries"] = {}
        for variant in VARIANTS:
            owner = self.bench_sources["Owner.swift.in"].decode()
            for token, name in (("STARTUP", "startup"), ("SOURCE_PROPERTIES", "properties"), ("CLOSE_TAB", "close")):
                marker = "// PRODUCTION_" + token
                if owner.count(marker) != 1:
                    raise ValueError("Owner template marker changed")
                owner = owner.replace(marker, extractions[variant][name])
            package = self.output / "packages" / variant
            files = {
                "Package.swift": PACKAGE.encode(),
                "Sources/IlliquidCore/NormalizedFileURL.swift": original[variant][CORE],
                "Sources/IlliquidApp/ReadOnlyStartupLoader.swift": original[variant][LOADER],
                "Sources/IlliquidApp/SourceStartupSnapshot.swift": original[variant][SNAPSHOT],
                "Sources/IlliquidApp/AppModel.swift": owner.encode(),
                "Sources/IlliquidApp/SourceTypes.swift": ("import Foundation\nimport IlliquidCore\n\n" + extractions[variant]["types"]).encode(),
                "Sources/IlliquidApp/Stubs.swift": self.bench_sources["Stubs.swift"],
                "Sources/StartupSourceLifetimeProbe/Driver.swift": self.bench_sources["Driver.swift"],
                "Sources/CStartupMemory/memory.c": self.bench_sources["CMemory/memory.c"],
                "Sources/CStartupMemory/include/StartupMemory.h": self.bench_sources["CMemory/include/StartupMemory.h"],
            }
            for name, data in files.items():
                target = package / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            self.manifest["compiled_sources"][variant] = {name: sha(data) for name, data in files.items()}
            save(self.output / "manifest.json", self.manifest)
            options = ["--package-path", package, "--cache-path", self.output / "cache",
                       "--config-path", self.output / "config", "--security-path", self.output / "security"]
            self.command([self.swift, "build", *options, "-c", "release", "--jobs", "2",
                          "--product", "StartupSourceLifetimeProbe", "-Xswiftc", "-warnings-as-errors"], variant + "-build")
            directory = self.command([self.swift, "build", *options, "-c", "release", "--show-bin-path"], variant + "-bin-path").strip()
            binary = Path(directory) / "StartupSourceLifetimeProbe"
            self.binaries[variant] = binary
            self.manifest["binaries"][variant] = {"sha256": sha(binary.read_bytes()),
                                                   "linkage": self.command(["otool", "-L", binary], variant + "-linkage")}
        save(self.output / "manifest.json", self.manifest)

    def sample(self, variant, count, mode, pair, order):
        row = json.loads(self.command([self.binaries[variant], count, mode],
                                     f"{mode}-{count}-pair{pair}-{variant}"))
        if row["itemCount"] != count or row["mode"] != mode:
            raise ValueError("Workload receipt mismatch")
        if row["sourceBeforeAction"] != self.expected[count]:
            raise ValueError("Restored source paths differ from the independent oracle")
        expected = self.expected_closed if mode == "close" else self.expected[count]
        if row["sourceAfterAction"] != expected or row["sourceAfterDiagnosticStop"] != expected:
            raise ValueError("Post-action source state differs from the oracle")
        if row["sourceReadCount"] != 1 or row["sharedIdentityPreserved"] is not True:
            raise ValueError("Singleton or one-read semantics regressed")
        for stage in ("before", "published", "afterAction", "afterDiagnosticStop"):
            if any(not isinstance(value, int) or value < 0 for value in row[stage].values()):
                raise ValueError("Invalid memory metric")
        for metric in ("loadWallSeconds", "loadCPUSeconds", "actionWallSeconds", "actionCPUSeconds",
                       "diagnosticStopWallSeconds", "diagnosticStopCPUSeconds"):
            if not math.isfinite(row[metric]) or row[metric] < 0:
                raise ValueError("Invalid timing metric")
        row.update(variant=variant, pair=pair, order=order)
        self.rows.append(row)
        with (self.output / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")

    def measure(self):
        cases = [(count, mode) for count in COUNTS for mode in MODES]
        for pair in range(self.args.pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            rotated = cases[pair % len(cases):] + cases[:pair % len(cases)]
            for count, mode in rotated:
                for position, variant in enumerate(order):
                    self.sample(variant, count, mode, pair, position)
            print(json.dumps({"completed_pair": pair + 1, "pairs": self.args.pairs}), flush=True)
        results = []
        for count, mode in cases:
            rows = [r for r in self.rows if r["itemCount"] == count and r["mode"] == mode]
            metrics = {
                "published_live_malloc_bytes": lambda r: r["published"]["liveMallocBytes"],
                "post_action_live_malloc_bytes": lambda r: r["afterAction"]["liveMallocBytes"],
                "post_action_incremental_live_malloc_bytes": lambda r: r["afterAction"]["liveMallocBytes"] - r["before"]["liveMallocBytes"],
                "action_released_live_malloc_bytes": lambda r: r["published"]["liveMallocBytes"] - r["afterAction"]["liveMallocBytes"],
                "diagnostic_stop_released_live_malloc_bytes": lambda r: r["afterAction"]["liveMallocBytes"] - r["afterDiagnosticStop"]["liveMallocBytes"],
                "post_action_resident_bytes": lambda r: r["afterAction"]["residentBytes"],
                "post_action_physical_footprint_bytes": lambda r: r["afterAction"]["physicalFootprintBytes"],
                "post_action_peak_resident_bytes": lambda r: r["afterAction"]["peakResidentBytes"],
                "load_wall_seconds": lambda r: r["loadWallSeconds"],
                "load_cpu_seconds": lambda r: r["loadCPUSeconds"],
            }
            if mode == "close":
                metrics.update(close_wall_seconds=lambda r: r["actionWallSeconds"],
                               close_cpu_seconds=lambda r: r["actionCPUSeconds"])
            result = {"items": count, "mode": mode, "pairs": self.args.pairs, "metrics": {}}
            for name, get in metrics.items():
                values = {v: [get(next(r for r in rows if r["variant"] == v and r["pair"] == pair))
                              for pair in range(self.args.pairs)] for v in VARIANTS}
                differences = [c - b for b, c in zip(values["baseline"], values["candidate"])]
                result["metrics"][name] = {
                    v: {"median": statistics.median(data), "minimum": min(data), "maximum": max(data), "values": data}
                    for v, data in values.items()}
                result["metrics"][name].update(paired_candidate_minus_baseline=differences,
                    median_paired_difference=statistics.median(differences),
                    candidate_lower_pairs=sum(x < 0 for x in differences))
            results.append(result)
        if len(self.rows) != len(cases) * self.args.pairs * 2:
            raise ValueError("Incomplete balanced observation cohort")
        return {"status": "complete", "observations": len(self.rows), "results": results,
                "parity": "Exact independent ordered-path/count/selection oracle in every observation; shared identity and one read verified",
                "scope": self.manifest["scope"], "excluded": self.manifest["excluded"],
                "note": "The unchanged control should retain live source data in both variants; large fixtures are stress cases"}

    def verify(self):
        for name, data in self.source_bytes.items():
            variant, path = name.split(":", 1)
            if variant == "candidate" and (ROOT / path).read_bytes() != data:
                raise ValueError("Production source changed during the run: " + path)
        for name, data in self.bench_sources.items():
            if (HERE / name).read_bytes() != data:
                raise ValueError("Benchmark source changed during the run: " + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=8)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Native macOS is required for the Foundation/allocator experiment")
    if args.pairs < 6 or args.pairs % 2:
        parser.error("Use at least six balanced, even AB/BA pairs")
    if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
        print("Kyoto is unavailable on this host; using isolated direct benchmark builds.", flush=True)
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        summary = runner.measure()
        runner.verify()
        runner.manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
        save(runner.output / "manifest.json", runner.manifest)
        save(runner.output / "summary.json", summary)
        print("STARTUP_SOURCE_LIFETIME_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    except Exception as error:
        if runner is not None:
            save(runner.output / "failure.json", {"error": str(error)})
        raise


if __name__ == "__main__":
    main()
