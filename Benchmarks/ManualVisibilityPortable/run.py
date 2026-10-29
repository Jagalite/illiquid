#!/usr/bin/env python3
"""Portable Linux qualification of manual source-browser visibility rebuilds.

Reuses the native study's tests, harness, pairing, timing and parity checks.
Only three guarded, symmetric compatibility adaptations are applied. Results
qualify Linux component behavior and latency; they do not qualify macOS playback,
UI responsiveness, or native Foundation performance.
"""
from __future__ import annotations

import argparse
import importlib.util
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

PORTABLE = Path(__file__).resolve()
NATIVE = PORTABLE.parents[1] / "ManualVisibility" / "run.py"
spec = importlib.util.spec_from_file_location("manual_visibility_native", NATIVE)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)

ADAPTERS = {
    "Sources/IlliquidCore/MediaSidecarReader.swift": (
        b"import Darwin\n", b"import Glibc\n", "Darwin import -> Glibc",
    ),
    "Sources/IlliquidCore/NFOMetadataHints.swift": (
        b"import Foundation\n", b"import Foundation\nimport FoundationXML\n",
        "add FoundationXML import",
    ),
    "Tests/IlliquidAppTests/SourceMediaOrganizationTests.swift": (
        b'appendingPathComponent("media-sidecars-" + UUID().uuidString)',
        b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)',
        "explicit directory hint for existing Linux sidecar fixture",
    ),
}


class PortableStudy(native.Study):
    def __init__(self, args):
        if platform.system() != "Linux":
            raise ValueError("Portable qualification requires Linux; use the native runner on macOS")
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH")
        self.env = os.environ.copy()
        self.env.update(CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
                        SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
                        TERM="dumb", NO_COLOR="1")
        self.packages, self.binaries, self.expected = {}, {}, {}
        self.driver_hashes = {
            path: native.sha(path.read_bytes())
            for path in [PORTABLE, NATIVE, native.HELPER, native.HERE / "Harness.swift"]
        }
        self.manifest = {
            "schema": 1, "complete": False, "baseline": native.BASELINE,
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(),
            "python": sys.version, "libc": platform.libc_ver(),
            "qualification": "Linux portable component only; macOS native performance unqualified",
            "cases": args.cases, "sizes": args.sizes, "pairs": args.pairs,
            "target_ms": args.target_ms, "sources": {}, "binary_sha256": {},
            "runner_sha256": self.driver_hashes[PORTABLE],
            "native_runner_sha256": self.driver_hashes[NATIVE],
            "support_helper_sha256": self.driver_hashes[native.HELPER],
            "harness_sha256": self.driver_hashes[native.HERE / "Harness.swift"],
            "driver_hashes": {
                str(path.relative_to(native.ROOT)): value
                for path, value in self.driver_hashes.items()
            },
            "boundary": {
                "included": "One awaited production SourceBrowserFilter.project(input:) call per duration",
                "excluded": ["fixture and recognition setup", "warmups", "receipt hashing",
                             "filesystem I/O", "compilation", "process startup", "UI rendering and playback"],
                "cache": "Raw tree warm; every measured call asserts a visibility rebuild after timing",
                "ordering": "Balanced AB/BA pairs, fresh process per member, equal iteration counts",
                "fixtures": "Same native harness; synthetic lexical local URLs, flat or nested",
                "statistics": "Per-process mean latency; median paired baseline/candidate ratio; all samples retained",
                "duration": "target_ms is a pilot-based target, capped at 1024 iterations; inspect actual totals",
            },
        }

    def prepare(self):
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head").strip()
        self.manifest["worktree"] = self.command(["git", "status", "--short"], "worktree")
        self.command(["git", "merge-base", "--is-ancestor", native.BASELINE, "HEAD"], "baseline-ancestry")
        self.manifest["swift"] = self.command([self.swift, "--version"], "swift").strip()
        if Path("/etc/os-release").exists():
            self.manifest["os_release"] = Path("/etc/os-release").read_text()
        if Path("/proc/cpuinfo").exists():
            self.manifest["cpu"] = next((line.split(":", 1)[1].strip()
                for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), "")
        self.manifest["cpu_affinity"] = (
            sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None
        )

        def historical(path):
            return subprocess.check_output([
                "git", "-C", str(native.ROOT), "show", f"{native.BASELINE}:{path}",
            ])
        baseline, baseline_records = native.support.snapshot(historical)
        candidate, candidate_records = native.support.snapshot(
            lambda path: (native.ROOT / path).read_bytes())
        # Check original production bytes before making any Linux adaptation.
        if baseline.keys() != candidate.keys():
            raise ValueError("Source inventories differ")
        for path in baseline:
            if path != native.FOCAL and baseline[path] != candidate[path]:
                raise ValueError(f"Unrelated production source changed: {path}; requalify explicitly")
        if native.outside_matcher(baseline[native.FOCAL]) != native.outside_matcher(candidate[native.FOCAL]):
            raise ValueError("Production changes extend outside SourceVisibilityMatcher")
        if baseline[native.FOCAL] == candidate[native.FOCAL]:
            raise ValueError("No focal production change")

        package = native.support.PACKAGE.replace(
            "SourceTreeVisibilityQualification", "ManualVisibilityPortableQualification")
        package = package.replace("SourceTreeBenchmark", "ManualVisibilityBenchmark")
        shared = {
            "Package.swift": package.encode(),
            "Sources/ManualVisibilityBenchmark/Harness.swift": (native.HERE / "Harness.swift").read_bytes(),
        }
        for name in native.TESTS:
            shared["Tests/IlliquidAppTests/" + name] = (
                native.ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
        self.manifest["shared_sha256"] = {path: native.sha(raw) for path, raw in shared.items()}
        for variant, files, records in [
            ("baseline", baseline, baseline_records), ("candidate", candidate, candidate_records),
        ]:
            folder = self.output / "packages" / variant
            staged = dict(files)
            staged.update(shared)
            hashes, compiled, adaptations = {}, {}, []
            for path, raw in staged.items():
                adapted = raw
                if path in ADAPTERS:
                    before, after, description = ADAPTERS[path]
                    if raw.count(before) != 1 or after in raw:
                        raise ValueError(f"Compatibility adaptation boundary changed: {path}")
                    adapted = raw.replace(before, after, 1)
                    adaptations.append({
                        "path": path, "change": description,
                        "original_sha256": native.sha(raw), "compiled_sha256": native.sha(adapted),
                    })
                destination = folder / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(adapted)
                compiled[path] = native.sha(adapted)
                hashes[path] = {"original_sha256": native.sha(raw), "compiled_sha256": compiled[path]}
            if {record["path"] for record in adaptations} != set(ADAPTERS):
                raise ValueError("A required compatibility adaptation was not applied")
            self.packages[variant] = folder
            self.manifest["sources"][variant] = {
                "production": records, "staged": hashes,
                "compiled_sha256": compiled, "adaptations": adaptations,
            }
        if (self.manifest["sources"]["baseline"]["adaptations"]
                != self.manifest["sources"]["candidate"]["adaptations"]):
            raise ValueError("Baseline and candidate compatibility adaptations differ")
        native.save(self.output / "manifest.json", self.manifest)

    def swift_command(self, variant, action, configuration):
        return super().swift_command(variant, action, configuration) + ["--use-integrated-swift-driver"]

    def check_sources(self):
        super().check_sources()
        for path, expected in self.driver_hashes.items():
            if native.sha(path.read_bytes()) != expected:
                raise ValueError(f"Qualification driver changed: {path}")
        for variant, binary in self.binaries.items():
            if native.sha(binary.read_bytes()) != self.manifest["binary_sha256"][variant]:
                raise ValueError(f"Benchmark binary changed: {variant}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sizes", default="100,1000,10000")
    parser.add_argument("--cases", default=",".join(native.CASES))
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    args.sizes = [int(value) for value in args.sizes.split(",")]
    args.cases = args.cases.split(",")
    if (args.pairs < 2 or args.pairs % 2
            or not math.isfinite(args.target_ms) or args.target_ms <= 0
            or any(value <= 0 for value in args.sizes)
            or len(set(args.cases)) != len(args.cases)
            or not set(args.cases) <= set(native.CASES)):
        parser.error("Use positive sizes/target, an even pair count >=2, and unique known cases")
    study = PortableStudy(args)
    try:
        study.run()
    except Exception as error:
        native.save(study.output / "failure.json", {"type": type(error).__name__, "error": str(error)})
        raise


if __name__ == "__main__":
    main()
