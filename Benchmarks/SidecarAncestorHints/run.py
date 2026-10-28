#!/usr/bin/env python3
"""Measure complete sidecar recognition against the frozen ea2ff568 baseline."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE_DIR = Path("Sources/IlliquidCore/MediaLibrary")
READER = "MediaSidecarReader.swift"
SOURCES = ["MediaNameRecognition.swift", "MediaMetadataHints.swift",
           "NFOMetadataHints.swift", "PlexMatchHints.swift", READER]
MANIFEST = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SidecarAncestorHintsQualification", platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
              .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n")


def utc() -> str:
    return datetime.now(timezone.utc).isoformat()


class Experiment:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Output must be new or empty; previous evidence is never overwritten")
        self.evidence = self.out / "evidence"
        self.evidence.mkdir(parents=True)
        self.build = self.out / "build"
        self.build.mkdir()
        self.env = dict(os.environ)
        for name in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.env[name] = str(self.build / "module-cache")
        compiler = shutil.which(args.swiftc)
        if not compiler:
            raise ValueError(f"Swift compiler not found: {args.swiftc}")
        # Preserve swiftc's invocation name; resolving its swift-driver symlink
        # before invoking it selects a different driver mode.
        self.swiftc = str(Path(compiler).absolute())
        self.swift = str(Path(self.swiftc).with_name("swift"))
        self.flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors"]
        if platform.system() == "Darwin":
            sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
            self.flags += ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macos26.0"]
        self.binaries = {}
        self.expected = {}

    def command(self, arguments, log=None, timeout=1200):
        argv = [str(value) for value in arguments]
        started_utc, started = utc(), time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=timeout)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"argv": argv, "cwd": str(ROOT), "started_utc": started_utc,
                "returncode": result.returncode, "elapsed_seconds": time.monotonic() - started,
                "log": log, "stdout_sha256": digest(result.stdout.encode()),
                "stderr_sha256": digest(result.stderr.encode())}) + "\n")
        if log:
            (self.evidence / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv!r}\n{result.stdout[-8000:]}\n{result.stderr[-8000:]}")
        return result.stdout

    def stage(self):
        frozen = json.loads((HERE / "baseline/manifest.json").read_text())
        baseline = {name: (HERE / "baseline" / name).read_bytes() for name in SOURCES}
        for item in frozen["sourceFiles"]:
            if digest(baseline[item["file"]]) != item["sha256"]:
                raise ValueError(f"Frozen baseline integrity failed: {item['file']}")
        current = {name: (ROOT / SOURCE_DIR / name).read_bytes() for name in SOURCES}
        changed = [name for name in SOURCES if current[name] != baseline[name]]
        if changed != [READER]:
            raise ValueError(f"Only the reader may differ from the frozen baseline; got {changed}")
        test_dir = ROOT / "Tests/IlliquidCoreTests"
        names = set()
        for pattern in ("MediaSidecar*Tests.swift", "PlexMatch*Tests.swift", "NFO*Tests.swift",
                        "MediaNameRecognition*Tests.swift", "EpisodeNameRecognitionRegressionTests.swift"):
            names.update(path.name for path in test_dir.glob(pattern))
        required = {"MediaSidecarAncestorHintsTests.swift", "MediaSidecarPathPlanTests.swift",
                    "MediaSidecarNegativeCacheTests.swift"}
        if self.args.run_tests and not required.issubset(names):
            raise ValueError(f"Missing qualification tests: {sorted(required - names)}")
        tests = {name: (test_dir / name).read_bytes() for name in sorted(names)}
        harness = (HERE / "Harness.swift").read_bytes()
        snapshots = self.evidence / "sources"
        snapshots.mkdir()
        for name, data in {**current, **tests, "Harness.swift": harness,
                           "run.py": Path(__file__).read_bytes()}.items():
            (snapshots / name).write_bytes(data)
        (snapshots / ("baseline-" + READER)).write_bytes(baseline[READER])
        receipts, binaries = {}, {}
        for variant in ("baseline", "candidate"):
            package = self.build / variant
            production = package / "Sources/IlliquidCore"
            test_target = package / "Tests/IlliquidCoreTests"
            module = package / "module"
            for path in (production, test_target, module):
                path.mkdir(parents=True)
            (package / "Package.swift").write_text(MANIFEST)
            receipt = {"production": {}, "tests": {}, "manifest_sha256": digest(MANIFEST.encode())}
            for name in SOURCES:
                original = baseline[name] if variant == "baseline" else current[name]
                compiled, adaptation = original, None
                if platform.system() == "Linux":
                    if name == READER:
                        if original.count(b"import Darwin\n") != 1:
                            raise ValueError("Unexpected reader POSIX import; review adaptation")
                        compiled = original.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        adaptation = "Darwin import -> Glibc"
                    elif name == "NFOMetadataHints.swift":
                        if original.count(b"import Foundation\n") != 1:
                            raise ValueError("Unexpected NFO Foundation import; review adaptation")
                        compiled = original.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        adaptation = "add FoundationXML import"
                (production / name).write_bytes(compiled)
                receipt["production"][name] = {"original_sha256": digest(original),
                    "compiled_sha256": digest(compiled), "adaptation": adaptation}
            for name, data in tests.items():
                (test_target / name).write_bytes(data)
                receipt["tests"][name] = digest(data)
            driver = package / "Harness.swift"
            driver.write_bytes(harness)
            suffix = "dylib" if platform.system() == "Darwin" else "so"
            library = module / f"libIlliquidCore.{suffix}"
            self.command([self.swiftc, *self.flags, "-enable-testing", "-parse-as-library",
                "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                "-emit-module-path", module / "IlliquidCore.swiftmodule",
                *[production / name for name in SOURCES], "-o", library], f"{variant}-library-compile.log")
            binary = package / "sidecar-ancestor-hints"
            self.command([self.swiftc, *self.flags, "-parse-as-library", "-I", module, "-L", module,
                "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", module,
                driver, "-o", binary], f"{variant}-harness-compile.log")
            receipts[variant] = receipt
            binaries[variant] = {"executable": file_digest(binary), "library": file_digest(library),
                                "module": file_digest(module / "IlliquidCore.swiftmodule")}
            self.binaries[variant] = binary
            save(self.evidence / f"{variant}-sources.json", receipt)
            print("Built", variant, flush=True)
        save(self.evidence / "binaries.json", binaries)
        save(self.evidence / "provenance.json", {"baseline": frozen,
            "candidate_head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_uses_worktree_source": True, "changed_production_files": changed,
            "driver_sha256": digest(harness), "runner_sha256": file_digest(Path(__file__)),
            "snapshot_sha256": {p.name: file_digest(p) for p in sorted(snapshots.iterdir())}})

    def tests(self):
        results = {}
        for variant in self.binaries:
            for configuration in ("debug", "release"):
                log = f"{variant}-{configuration}-tests.log"
                output = self.command([self.swift, "test", "--package-path", self.build / variant,
                    "--configuration", configuration, "--jobs", self.args.jobs, "--no-parallel"], log)
                combined = (self.evidence / log).read_text()
                counts = re.findall(r"Test run with ([1-9][0-9]*) tests? .* passed", combined)
                if not counts:
                    raise RuntimeError(f"No nonempty Swift Testing success summary: {log}")
                results[f"{variant}-{configuration}"] = int(counts[-1])
                print(variant, configuration, counts[-1], "tests passed", flush=True)
        if len(set(results.values())) != 1:
            raise RuntimeError(f"Test discovery differs between configurations: {results}")
        save(self.evidence / "tests.json", results)

    def verify(self):
        self.fixtures = self.build / "fixtures"
        self.command([self.binaries["baseline"], "prepare", self.fixtures], "fixture-setup.log")
        catalogs, reports = [], []
        for variant, binary in self.binaries.items():
            catalogs.append(json.loads(self.command([binary, "list"])))
            raw = self.command([binary, "verify", self.fixtures])
            with gzip.open(self.evidence / f"{variant}-outputs.json.gz", "wb") as stream:
                stream.write(raw.encode())
            reports.append(json.loads(raw))
        if catalogs[0] != catalogs[1] or canonical(reports[0]) != canonical(reports[1]):
            raise RuntimeError("Exact complete output/filesRead/cancellation parity failed")
        self.expected = {row["scenario"]["name"]: row for row in reports[0]["scans"]}
        measured = [case for case in catalogs[0] if case["measure"]]
        if self.args.cases:
            missing = set(self.args.cases) - {case["name"] for case in measured}
            if missing:
                raise ValueError(f"Unknown measured cases: {sorted(missing)}")
            measured = [case for case in measured if case["name"] in self.args.cases]
        self.cases = measured
        receipt = {"scenarios": len(reports[0]["scans"]),
            "recognized_outputs": sum(len(row["outputs"]) for row in reports[0]["scans"]),
            "cancellation_scenarios": len(reports[0]["cancellations"]),
            "complete_outputs_sha256": digest(canonical(reports[0])), "measured_cases": self.cases,
            "independent_expectations": "kind/title/year/season/episode/range/providers/sources, reads and checkpoint counts"}
        save(self.evidence / "verification.json", receipt)
        print("Verified", receipt["recognized_outputs"], "complete outputs and",
              receipt["cancellation_scenarios"], "throw/resume trajectories", flush=True)

    def sample(self, variant, case, iterations):
        row = json.loads(self.command([self.binaries[variant], "bench", self.fixtures, case, iterations]))
        expected = self.expected[case]
        reads = expected["filesReadAfter"][-1] - expected["filesReadBefore"]
        if (canonical(row["final"]) != canonical(expected["outputs"])
            or row["filesReadPerScan"] != reads or row["totalFilesRead"] != reads * iterations
            or row["iterations"] != iterations or row["scenario"] != case
            or row["fileCount"] != expected["scenario"]["count"]
            or row["checksum"] != (expected["checksum"] * iterations) % (1 << 64)):
            raise RuntimeError(f"Timed output/operation-count mismatch: {variant} {case}")
        row["output_sha256"] = digest(canonical(row.pop("final")))
        return row

    def measure(self):
        calibration, iterations = [], {}
        for case in self.cases:
            pilots = []
            for variant in self.binaries:
                pilot = self.sample(variant, case["name"], 1)
                pilot["variant"] = variant
                pilots.append(pilot["elapsedNS"])
                calibration.append(pilot)
            iterations[case["name"]] = min(100_000, max(1,
                math.ceil(self.args.target_ms * 1_000_000 / min(pilots))))
        save(self.evidence / "calibration.json", {"pilots": calibration, "iterations": iterations})
        rows = []
        for pair in range(self.args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            cases = self.cases if pair % 2 == 0 else list(reversed(self.cases))
            for case in cases:
                for position, variant in enumerate(order):
                    row = self.sample(variant, case["name"], iterations[case["name"]])
                    row.update(variant=variant, pair=pair, process_order=position)
                    rows.append(row)
                    with (self.evidence / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
            print("Completed pair", pair + 1, "of", self.args.pairs, flush=True)
        summaries = []
        for case in self.cases:
            samples = [row for row in rows if row["scenario"] == case["name"]]
            medians, paired = {}, {}
            for variant in self.binaries:
                medians[variant] = {name: statistics.median(row[field] / row["iterations"]
                    for row in samples if row["variant"] == variant)
                    for name, field in (("wall_ns_per_scan", "elapsedNS"), ("cpu_ns_per_scan", "cpuNS"))}
            for metric, field in (("wall", "elapsedNS"), ("cpu", "cpuNS")):
                changes = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[field] for row in samples if row["pair"] == pair}
                    changes.append((values["candidate"] / values["baseline"] - 1) * 100)
                paired[metric] = {"median_change_percent": statistics.median(changes),
                    "changes_percent": changes, "faster_pairs": sum(value < 0 for value in changes)}
            summaries.append({"scenario": case["name"], "files_per_scan": case["count"],
                "iterations": iterations[case["name"]], "pairs": self.args.pairs, "medians": medians,
                "paired": paired, "minimum_sample_ms": min(row["elapsedNS"] for row in samples) / 1_000_000})
            print(case["name"], "wall", f"{paired['wall']['median_change_percent']:+.1f}%",
                  "CPU", f"{paired['cpu']['median_change_percent']:+.1f}%", flush=True)
        if len(rows) != len(self.cases) * self.args.pairs * 2:
            raise RuntimeError("Incomplete measurement campaign")
        save(self.evidence / "summary.json", {"observations": len(rows), "scenarios": summaries})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--pairs", "--rounds", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--case", dest="cases", action="append")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--run-tests", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or args.jobs <= 0:
        parser.error("Use even pairs >= 2 and positive target-ms/jobs")
    run = Experiment(args)
    save(run.evidence / "environment.json", {"started_utc": utc(),
        "platform": platform.platform(), "architecture": platform.machine(),
        "python": platform.python_version(), "compiler_invocation": run.swiftc,
        "compiler_realpath": str(Path(run.swiftc).resolve()), "compiler_sha256": file_digest(Path(run.swiftc)),
        "compiler_version": run.command([run.swiftc, "--version"]).strip(), "compiler_flags": run.flags,
        "head": run.command(["git", "rev-parse", "HEAD"]).strip(),
        "git_status": run.command(["git", "status", "--short"]),
        "LD_LIBRARY_PATH": run.env.get("LD_LIBRARY_PATH"),
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "timing_contract": "complete recognize scans; separate dynamically linked production module; fresh process per sample; cold=new reader each timed pass including first sidecar I/O; warm=primed reused reader; OS caches warm, no cold-disk claim; fixture construction, warmup, calibration and JSON outside timing"})
    run.stage()
    if args.run_tests:
        run.tests()
    run.verify()
    if not args.verify_only:
        run.measure()
    save(run.evidence / "completion.json", {"complete": True, "timing": not args.verify_only,
        "tests_requested": args.run_tests, "finished_utc": utc()})


if __name__ == "__main__":
    main()
