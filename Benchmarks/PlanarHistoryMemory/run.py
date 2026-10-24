#!/usr/bin/env python3
"""Compare exact ownership ledgers with one or two historical identity tables."""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SHARED = ROOT / "Benchmarks/PlanarOwnership"
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
SOURCE = "Sources/IlliquidNativePlayback/Diagnostics/PlanarBufferOwnershipDiagnostics.swift"
SIGNPOSTS = "Sources/IlliquidNativePlayback/Diagnostics/NativePlaybackSignposts.swift"
TESTS = ["PlanarOwnershipTransitionTests.swift", "PlanarOwnershipHistoryTests.swift"]
REMOVED = {"import CoreMedia", "import CoreVideo", "import os.signpost"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Use a new empty output directory")
        self.build = self.out / "build"
        self.evidence = self.out / "evidence"
        self.build.mkdir(parents=True)
        self.evidence.mkdir()
        self.env = dict(os.environ)
        for key in ["CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"]:
            self.env[key] = str(self.build / "module-cache")
        self.env.update(TERM="dumb", NO_COLOR="1")
        self.native = platform.system() == "Darwin"
        self.sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip() if self.native else None
        if self.sdk:
            self.env["SDKROOT"] = self.sdk
        self.binaries = {}

    def command(self, arguments, log=None, timeout=900, record_stdout=True):
        arguments = [str(value) for value in arguments]
        started = time.time()
        result = subprocess.run(arguments, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        if log:
            (self.evidence / log).write_text(result.stdout + result.stderr)
        with (self.evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"command": arguments, "returncode": result.returncode,
                "started_unix": started, "elapsed_seconds": time.time() - started,
                "stdout_sha256": sha(result.stdout.encode()), "stderr_sha256": sha(result.stderr.encode()),
                "stdout": result.stdout if not log and record_stdout else None, "log": log}) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {arguments}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def prepare(self):
        baseline = subprocess.check_output(["git", "show", f"{self.args.baseline}:{SOURCE}"], cwd=ROOT)
        candidate = (ROOT / SOURCE).read_bytes()
        shared = {"Platform.swift": (SHARED / "Platform.swift").read_bytes(),
                  "SemanticHarness.swift": (SHARED / "Harness.swift").read_bytes(),
                  "MemoryHarness.swift": (HERE / "Harness.swift").read_bytes(),
                  "NativePlaybackSignposts.swift": (ROOT / SIGNPOSTS).read_bytes(),
                  "Heap.c": (HERE / "Heap.c").read_bytes(), "Heap.h": (HERE / "Heap.h").read_bytes()}
        for name, data in shared.items():
            (self.build / name).write_bytes(data)
        manifest = {"baseline_commit": self.args.baseline,
            "checkout_head": self.command(["git", "rev-parse", "HEAD"]).strip(),
            "source_path": SOURCE, "source_sha256": {}, "compiled_source_sha256": {},
            "shared_sha256": {name: sha(data) for name, data in shared.items()},
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "tests_sha256": {name: sha((ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes()) for name in TESTS},
            "platform": platform.platform(), "architecture": platform.machine(), "sdk": self.sdk,
            "swift": self.command([self.args.swift, "--version"]).strip(),
            "clang": self.command([self.args.clang, "--version"]).strip(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.args).items()},
            "boundary": "actual CoreMedia/CoreVideo" if self.native else "Linux identity and sample objects; real Foundation/ARC/locks/ledger",
            "scope": "scalar diagnostic history retention; pixel-buffer fixtures predate heap checkpoint; not player RAM",
            "linux_allocator_caveat": "mallinfo2 includes glibc thread-cache residue: inspect destruction control; small-count deltas may not isolate live storage"}
        self.sources = {}
        for variant, original in [("baseline", baseline), ("candidate", candidate)]:
            compiled = original
            if not self.native:
                lines = original.decode().splitlines(keepends=True)
                removed = [line.strip() for line in lines if line.strip() in REMOVED]
                if set(removed) != REMOVED or len(removed) != 3:
                    raise ValueError("Unexpected Linux import boundary")
                compiled = "".join(line for line in lines if line.strip() not in REMOVED).encode()
            path = self.build / f"{variant}.swift"
            path.write_bytes(compiled)
            self.sources[variant] = path
            manifest["source_sha256"][variant] = sha(original)
            manifest["compiled_source_sha256"][variant] = sha(compiled)
        if baseline == candidate:
            raise ValueError("Baseline and candidate are identical")
        self.manifest = manifest
        save(self.evidence / "manifest.json", manifest)

    def compile(self):
        ccflags = ["-isysroot", self.sdk] if self.sdk else []
        self.command([self.args.clang, *ccflags, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-O2",
            "-Wall", "-Wextra", "-Werror", "-c", self.build / "Heap.c", "-o", self.build / "Heap.o"], "heap-compile.log")
        native_flags = ["-sdk", self.sdk, "-target", f"{platform.machine()}-apple-macos26.0"] if self.sdk else []
        for variant, source in self.sources.items():
            for mode, optimization in [("semantics-debug", "-Onone"), ("semantics-release", "-O"), ("memory", "-O")]:
                binary = self.build / f"{variant}-{mode}"
                arguments = [self.args.swiftc, "-swift-version", "6", "-warnings-as-errors", optimization, *native_flags]
                if optimization == "-O":
                    arguments.append("-whole-module-optimization")
                arguments += [source, self.build / "Platform.swift"]
                if self.native:
                    arguments.append(self.build / "NativePlaybackSignposts.swift")
                if mode == "memory":
                    arguments += ["-import-objc-header", self.build / "Heap.h", self.build / "MemoryHarness.swift", self.build / "Heap.o"]
                else:
                    arguments.append(self.build / "SemanticHarness.swift")
                arguments += ["-o", binary]
                self.command(arguments, f"{variant}-{mode}-compile.log")
                self.binaries[variant, mode] = binary
            print("Built", variant, flush=True)
        self.manifest["binary_sha256"] = {f"{variant}-{mode}": sha(path.read_bytes())
            for (variant, mode), path in self.binaries.items()}
        save(self.evidence / "manifest.json", self.manifest)

    def differential(self):
        receipts = []
        for mode in ["semantics-debug", "semantics-release"]:
            for seed in [1, 7, 42, 2026, 65537]:
                reports = {}
                for variant in ["baseline", "candidate"]:
                    result = self.command([self.binaries[variant, mode], "--mode", "trace", "--seed", seed,
                                           "--steps", self.args.steps], record_stdout=False)
                    reports[variant] = json.loads(result)
                if reports["baseline"] != reports["candidate"]:
                    save(self.evidence / "differential-failure.json", reports)
                    raise ValueError("Ledger diagnostic states differ")
                canonical = json.dumps(reports["baseline"], sort_keys=True, separators=(",", ":")).encode()
                # Retain the complete equal trace once; both command outputs are
                # independently hash-bound in commands.jsonl.
                trace_name = f"trace-{mode}-{seed}.json.gz"
                (self.evidence / trace_name).write_bytes(gzip.compress(canonical, mtime=0))
                receipts.append({"mode": mode, "seed": seed, "steps": self.args.steps,
                    "compared_snapshots": len(reports["baseline"]["snapshots"]),
                    "equal": True, "trace_sha256": sha(canonical), "trace_file": trace_name})
            smoke = {variant: json.loads(self.command([self.binaries[variant, mode], "--mode", "smoke"]))
                     for variant in ["baseline", "candidate"]}
            if smoke["baseline"] != smoke["candidate"]:
                raise ValueError("Lifecycle workload semantics differ")
            save(self.evidence / f"workload-{mode}.json", smoke["candidate"])
        save(self.evidence / "differential.json", receipts)
        print("Differential parity:", sum(row["compared_snapshots"] for row in receipts), "snapshots", flush=True)

    def native_tests(self):
        if not self.native:
            save(self.evidence / "native-tests.json", {"executed": False, "reason": "Requires macOS CoreMedia/CoreVideo"})
            return
        package = self.build / "native-tests"
        source_dir = package / "Sources/IlliquidNativePlayback"
        test_dir = package / "Tests/IlliquidNativePlaybackTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        shutil.copyfile(ROOT / SOURCE, source_dir / Path(SOURCE).name)
        shutil.copyfile(ROOT / SIGNPOSTS, source_dir / Path(SIGNPOSTS).name)
        for name in TESTS:
            shutil.copyfile(ROOT / "Tests/IlliquidNativePlaybackTests" / name, test_dir / name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlanarHistoryNative", platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])],
    swiftLanguageModes: [.v6])
''')
        counts = {}
        for configuration in ["debug", "release"]:
            log = f"native-tests-{configuration}.log"
            self.command([self.args.swift, "test", "--package-path", package, "--configuration", configuration,
                "--jobs", "2", "--no-parallel", "--cache-path", self.build / "cache",
                "--config-path", self.build / "config", "--security-path", self.build / "security",
                "-Xswiftc", "-warnings-as-errors"], log)
            count = re.findall(r"Test run with ([1-9][0-9]*) tests? .* passed", (self.evidence / log).read_text())
            if not count:
                raise ValueError("No successful native test summary")
            counts[configuration] = int(count[-1])
            print("Native", configuration, counts[configuration], "tests passed", flush=True)
        save(self.evidence / "native-tests.json", {"executed": True, "counts": counts})

    def measure(self):
        memory = []
        timing = []
        for pair in range(self.args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for count in self.args.counts:
                rows = {}
                for variant in order:
                    row = json.loads(self.command([self.binaries[variant, "memory"], "bench", count]))
                    if row["count"] != count or row["heapMetric"] == "unsupported":
                        raise ValueError("Invalid memory measurement")
                    row.update(pair=pair, order=order, variant=variant)
                    row["retainedAfterPopulateBytes"] = row["heapAfterPopulateBytes"] - row["heapBeforeBytes"]
                    row["retainedAfterReuseBytes"] = row["heapAfterReuseBytes"] - row["heapBeforeBytes"]
                    row["residualAfterDestroyBytes"] = row["heapAfterDestroyBytes"] - row["heapBeforeBytes"]
                    rows[variant] = row
                    memory.append(row)
                for field in ["afterPopulate", "afterReuse", "heapMetric"]:
                    if rows["baseline"][field] != rows["candidate"][field]:
                        raise ValueError(f"Memory experiment differs semantically: {field}")
            for workload in ["pipeline", "lifecycle-mixed"]:
                for occupancy in [1, 16, 32]:
                    rows = {}
                    for variant in order:
                        row = json.loads(self.command([self.binaries[variant, "semantics-release"],
                            "--mode", "bench", "--workload", workload, "--occupancy", occupancy,
                            "--iterations", self.args.iterations, "--warmup", 5000]))
                        row.update(pair=pair, order=order, variant=variant)
                        rows[variant] = row
                        timing.append(row)
                    for field in ["snapshot", "configuration"]:
                        if rows["baseline"][field] != rows["candidate"][field]:
                            raise ValueError(f"Timed lifecycle differs semantically: {field}")
            save(self.evidence / "memory-raw.json", memory)
            save(self.evidence / "timing-raw.json", timing)
            print("Measured pair", pair + 1, "of", self.args.pairs, flush=True)

        def describe(values):
            return {"median": statistics.median(values), "min": min(values), "max": max(values)}

        def comparison(rows, metric):
            by_variant = {variant: [row[metric] for row in rows if row["variant"] == variant]
                          for variant in ["baseline", "candidate"]}
            pairs = []
            for pair in range(self.args.pairs):
                values = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                pairs.append({"pair": pair, "delta": values["candidate"] - values["baseline"],
                    "percent": 100 * (values["candidate"] / values["baseline"] - 1)
                    if values["baseline"] else None})
            percentages = [pair["percent"] for pair in pairs if pair["percent"] is not None]
            return {**{variant: describe(values) for variant, values in by_variant.items()},
                "paired_delta": describe([pair["delta"] for pair in pairs]),
                "paired_percent": describe(percentages) if percentages else None, "pairs": pairs}

        summary = {"pairs": self.args.pairs, "order": "alternating AB/BA, each row in a fresh process",
            "memory_metric": memory[0]["heapMetric"],
            "memory_scope": "Allocator bytes above fixture-only heap checkpoint; destruction control distinguishes live storage from allocator residue; not whole-player RAM",
            "timing_scope": "Uninstrumented component lifecycle wall time; no end-to-end playback or statistical significance claim",
            "memory": [], "timing": []}
        for count in self.args.counts:
            rows = [row for row in memory if row["count"] == count]
            summary["memory"].append({"count": count, **{metric: comparison(rows, metric) for metric in [
                "retainedAfterPopulateBytes", "retainedAfterReuseBytes", "residualAfterDestroyBytes"]}})
        for workload in ["pipeline", "lifecycle-mixed"]:
            for occupancy in [1, 16, 32]:
                rows = [row for row in timing if row["workload"] == workload and row["occupancy"] == occupancy]
                summary["timing"].append({"workload": workload, "occupancy": occupancy,
                    "nanoseconds_per_unit": comparison(rows, "nanoseconds_per_unit")})
        save(self.evidence / "summary.json", summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    parser.add_argument("--clang", default=shutil.which("clang") or "clang")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--counts", type=lambda value: [int(x) for x in value.split(",")], default=[16, 128, 1024, 8192])
    parser.add_argument("--iterations", type=int, default=50000)
    parser.add_argument("--steps", type=int, default=2000)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-native-tests", action="store_true", help="Exploration only on macOS")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.steps < 1 or args.iterations < 1 or any(n < 1 or n > 65536 for n in args.counts):
        parser.error("Use even pairs >= 2 and positive steps/iterations; counts must be 1...65536")
    runner = Runner(args)
    runner.prepare()
    runner.compile()
    runner.differential()
    if not args.skip_native_tests:
        runner.native_tests()
    if not args.tests_only:
        runner.measure()
    save(runner.evidence / "completion.json", {"complete": True, "timing": not args.tests_only,
        "finished_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})


if __name__ == "__main__":
    main()
