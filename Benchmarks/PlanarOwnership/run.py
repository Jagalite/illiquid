#!/usr/bin/env python3
"""Build actual production ledger variants; check semantics and compare service work.

No FFmpeg, decoder, pixel conversion, renderer, or playback timing is modeled as
measured. On Linux only framework boundaries are replaced by Platform.swift.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = "Sources/IlliquidNativePlayback/Diagnostics/PlanarBufferOwnershipDiagnostics.swift"
PIN = "8c3cc3d4008d5d1b8d436bcf2d51d891382b6548"
BLOB = "0c597cde8a1219d53d3ce0dad760d6d20c8453e3"
NATIVE_TEST = "Tests/IlliquidNativePlaybackTests/PlanarOwnershipTransitionTests.swift"
REMOVED_IMPORTS = {"import CoreMedia", "import CoreVideo", "import os.signpost"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output).resolve() if args.output else Path(
            tempfile.mkdtemp(prefix="illiquid-planar-ownership-")
        )
        if self.output.exists() and any(self.output.iterdir()):
            raise RuntimeError("Use a fresh output directory; evidence must not mix runs")
        self.pin = args.baseline_commit or PIN
        self.blob = args.baseline_blob or BLOB
        self.build = self.output / "build"
        self.build.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.sources = {}
        self.binaries = {}
        self.swiftc = args.swiftc or shutil.which("swiftc")
        if not self.swiftc:
            raise RuntimeError("Swift compiler unavailable; set --swiftc or update PATH")
        self.swiftc = str(Path(self.swiftc).absolute())
        self.native = platform.system() == "Darwin"
        self.manifest = {
            "baseline_commit": self.pin, "baseline_blob_sha1": self.blob,
            "source_path": SOURCE, "platform": platform.platform(),
            "machine": platform.machine(), "python": platform.python_version(),
            "clock": "DispatchTime.now().uptimeNanoseconds",
            "execution_started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "framework_boundary": "actual CoreMedia/CoreVideo" if self.native else
                "Linux identity objects; real ledger, Foundation, locks, ARC; inert signposts",
            "allocation_scope": "cumulative successful malloc/calloc/realloc requested bytes; not RSS",
            "arguments": vars(args),
        }
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        if Path("/proc/cpuinfo").exists():
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    self.manifest["cpu_model"] = line.split(":", 1)[1].strip()
                    break
        elif self.native:
            self.manifest["cpu_model"] = subprocess.check_output(
                ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
            ).strip()

    def run(self, command, *, env=None):
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True)
        record = {
            "argv": [str(value) for value in command],
            "seconds": time.monotonic() - started, "returncode": result.returncode,
        }
        if result.stderr:
            record["stderr"] = result.stderr.decode(errors="replace")
        self.commands.append(record)
        with (self.output / "commands.jsonl").open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}): {command!r}\n"
                + result.stdout.decode(errors="replace")
                + result.stderr.decode(errors="replace")
            )
        return result.stdout

    def prepare(self):
        baseline = self.run(["git", "show", f"{self.pin}:{SOURCE}"])
        actual_blob = self.run(["git", "rev-parse", f"{self.pin}:{SOURCE}"]).decode().strip()
        if actual_blob != self.blob:
            raise RuntimeError(f"Pinned baseline blob mismatch: {actual_blob}")
        candidate = (ROOT / SOURCE).read_bytes()
        self.manifest["compiler"] = self.run([self.swiftc, "--version"]).decode().strip()
        self.manifest["checkout_head"] = self.run(["git", "rev-parse", "HEAD"]).decode().strip()
        self.manifest["source_sha256"] = {"baseline": sha(baseline), "candidate": sha(candidate)}
        self.manifest["harness_sha256"] = {
            name: sha((HERE / name).read_bytes())
            for name in ("Harness.swift", "Platform.swift", "run.py")
        }
        self.manifest["native_source_sha256"] = {
            path: sha((ROOT / path).read_bytes())
            for path in (NATIVE_TEST,
                "Sources/IlliquidNativePlayback/Diagnostics/NativePlaybackSignposts.swift")
            if (ROOT / path).exists()
        }
        for name, data in (("baseline", baseline), ("candidate", candidate)):
            source = data.decode()
            if not self.native:
                lines = source.splitlines(keepends=True)
                removed = [line.strip() for line in lines if line.strip() in REMOVED_IMPORTS]
                if set(removed) != REMOVED_IMPORTS or len(removed) != 3:
                    raise RuntimeError("Expected exactly the three documented platform imports")
                source = "".join(line for line in lines if line.strip() not in REMOVED_IMPORTS)
            destination = self.build / f"{name}.swift"
            destination.write_text(source)
            self.sources[name] = destination
        self.save_manifest()

    def compile(self, optimization):
        suffix = "release" if optimization == "-O" else "debug"
        for name, source in self.sources.items():
            binary = self.build / f"{name}-{suffix}"
            command = [
                self.swiftc, optimization, "-swift-version", "6", "-warnings-as-errors",
                "-module-cache-path", str(self.build / "module-cache"),
                str(source), str(HERE / "Platform.swift"), str(HERE / "Harness.swift"),
            ]
            if optimization == "-O":
                command.append("-whole-module-optimization")
            if self.native:
                command.append(str(ROOT / "Sources/IlliquidNativePlayback/Diagnostics/NativePlaybackSignposts.swift"))
            command += ["-o", str(binary)]
            self.run(command)
            self.binaries[name, suffix] = binary
        self.manifest.setdefault("binary_sha256", {}).update({
            f"{name}-{suffix}": sha(self.binaries[name, suffix].read_bytes())
            for name in self.sources
        })
        self.save_manifest()

    def differential(self, suffix):
        receipts = []
        for seed in self.args.seeds:
            results = {}
            for name in ("baseline", "candidate"):
                output = self.run([
                    str(self.binaries[name, suffix]), "--mode", "trace", "--seed", str(seed),
                    "--steps", str(self.args.steps),
                ])
                results[name] = json.loads(output)
            left, right = results["baseline"], results["candidate"]
            if left != right:
                discrepancy = next((
                    {"baseline": a, "candidate": b}
                    for a, b in zip(left["snapshots"], right["snapshots"]) if a != b
                ), {"baseline": left, "candidate": right})
                write_json(self.output / "first-differential-failure.json", discrepancy)
                raise RuntimeError("Baseline/candidate semantic trace mismatch; see failure artifact")
            canonical = json.dumps(left, sort_keys=True, separators=(",", ":")).encode()
            receipts.append({
                "optimization": suffix, "seed": seed, "steps": self.args.steps,
                "compared_snapshots": len(left["snapshots"]), "equal": True,
                "canonical_trace_sha256": sha(canonical),
            })
        write_json(self.output / f"differential-{suffix}.json", receipts)
        smoke = {
            name: json.loads(self.run([str(self.binaries[name, suffix]), "--mode", "smoke"]))
            for name in ("baseline", "candidate")
        }
        if smoke["baseline"] != smoke["candidate"]:
            write_json(self.output / "workload-correctness-failure.json", smoke)
            raise RuntimeError("Untimed workload correctness mismatch")
        write_json(self.output / f"workload-correctness-{suffix}.json", smoke["candidate"])
        return receipts

    def native_tests(self):
        if not self.native:
            return {"executed": False, "reason": "macOS CoreMedia/CoreVideo required"}
        runs = []
        for variant, source in self.sources.items():
            package = self.build / f"native-tests-{variant}"
            sources = package / "Sources/IlliquidNativePlayback"
            tests = package / "Tests/IlliquidNativePlaybackTests"
            sources.mkdir(parents=True, exist_ok=True)
            tests.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, sources / Path(SOURCE).name)
            shutil.copy2(
                ROOT / "Sources/IlliquidNativePlayback/Diagnostics/NativePlaybackSignposts.swift",
                sources / "NativePlaybackSignposts.swift",
            )
            shutil.copy2(ROOT / NATIVE_TEST, tests / Path(NATIVE_TEST).name)
            (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PlanarOwnershipNativeTests", platforms: [.macOS(.v14)],
    targets: [.target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])])
''')
            swift = str(Path(self.swiftc).with_name("swift"))
            for configuration in ("debug", "release"):
                output = self.run([
                    swift, "test", "--package-path", str(package), "--configuration", configuration,
                    "--scratch-path", str(self.build / f"native-test-build-{variant}"),
                    "-Xswiftc", "-warnings-as-errors",
                ])
                (self.output / f"native-tests-{variant}-{configuration}.txt").write_bytes(output)
                runs.append({"variant": variant, "configuration": configuration, "passed": True})
        return {"executed": True, "runs": runs, "test_sha256": sha((ROOT / NATIVE_TEST).read_bytes())}

    def benchmark(self):
        env = os.environ.copy()
        if self.args.allocations:
            if self.native or platform.system() != "Linux":
                raise RuntimeError("Allocation interposition is Linux/glibc-only")
            meter_source = ROOT / "Benchmarks/NonDecodePerformance/allocmeter.c"
            meter = self.build / "allocmeter.so"
            compiler = shutil.which("cc") or shutil.which("clang")
            if not compiler:
                raise RuntimeError("Allocation mode requires a C compiler")
            self.run([compiler, "-shared", "-fPIC", "-std=c11", "-O2", str(meter_source), "-o", str(meter)])
            env["LD_PRELOAD"] = str(meter) + (":" + env["LD_PRELOAD"] if env.get("LD_PRELOAD") else "")
            self.manifest["allocation_interposer_sha256"] = sha(meter_source.read_bytes())
        rows = []
        raw_path = self.output / "measurements.jsonl"
        cases = [(workload, size) for workload in self.args.workloads for size in self.args.occupancies]
        if self.args.include_peak_controls:
            cases = list(dict.fromkeys([*cases, ("phase", 11), ("aliased", 11)]))
        for round_index in range(self.args.rounds):
            for case_index, (workload, size) in enumerate(cases):
                order = ("baseline", "candidate") if (round_index + case_index) % 2 == 0 else ("candidate", "baseline")
                for order_index, variant in enumerate(order):
                    command = [
                        str(self.binaries[variant, "release"]), "--mode", "bench",
                        "--workload", workload, "--occupancy", str(size),
                        "--iterations", str(self.args.iterations), "--warmup", str(self.args.warmup),
                    ]
                    if self.args.allocations:
                        command.append("--meter")
                    row = json.loads(self.run(command, env=env))
                    row.update(variant=variant, round=round_index, order=order_index)
                    rows.append(row)
                    with raw_path.open("a") as handle:
                        handle.write(json.dumps(row, sort_keys=True) + "\n")
        summary = []
        for workload, size in cases:
            item = {"workload": workload, "occupancy": size, "variants": {}}
            selected = [row for row in rows if row["workload"] == workload and row["occupancy"] == size]
            for round_index in range(self.args.rounds):
                pair = [row for row in selected if row["round"] == round_index]
                if pair[0]["snapshot"] != pair[1]["snapshot"]:
                    raise RuntimeError("Timed workload finished in differing semantic states")
            fields = ["allocation_requests", "allocation_requested_bytes"] if self.args.allocations else ["nanoseconds_per_unit"]
            for variant in ("baseline", "candidate"):
                values = [row for row in selected if row["variant"] == variant]
                entry = {"samples": len(values), "configuration": values[0]["configuration"]}
                for field in fields:
                    numbers = [row[field] for row in values]
                    entry[field] = {"median": statistics.median(numbers), "min": min(numbers), "max": max(numbers)}
                item["variants"][variant] = entry
            for field in fields:
                before = item["variants"]["baseline"][field]["median"]
                after = item["variants"]["candidate"][field]["median"]
                item.setdefault("median_change_percent", {})[field] = 100 * (after / before - 1) if before else None
            summary.append(item)
        write_json(self.output / "summary.json", summary)
        self.save_manifest()

    def save_manifest(self):
        write_json(self.output / "manifest.json", self.manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc")
    parser.add_argument("--baseline-commit",
                        help="Override the historical baseline; requires --baseline-blob")
    parser.add_argument("--baseline-blob",
                        help="Expected full Git blob SHA for the overridden baseline source")
    parser.add_argument("--output")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--allocations", action="store_true")
    parser.add_argument("--include-peak-controls", action="store_true",
                        help="Also measure unchanged phase and duplicate-identity controls at 11 owners")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--iterations", type=int, default=100_000)
    parser.add_argument("--warmup", type=int, default=10_000)
    parser.add_argument("--occupancies", type=lambda value: [int(x) for x in value.split(",")], default=[1, 7, 11, 16, 32])
    parser.add_argument("--workloads", type=lambda value: value.split(","), default=["pipeline", "lifecycle-mixed"])
    parser.add_argument("--seeds", type=lambda value: [int(x) for x in value.split(",")], default=[1, 7, 42, 2026, 65537])
    parser.add_argument("--steps", type=int, default=2000)
    args = parser.parse_args()
    if args.rounds < 1 or args.iterations < 1 or args.warmup < 0 or args.steps < 0:
        parser.error("Invalid round/iteration/warmup/step count")
    if bool(args.baseline_commit) != bool(args.baseline_blob):
        parser.error("--baseline-commit and --baseline-blob must be supplied together")
    if args.baseline_commit and not all(
        re.fullmatch(r"[0-9a-f]{40}", value)
        for value in (args.baseline_commit, args.baseline_blob)
    ):
        parser.error("Baseline commit and blob must be full lowercase 40-digit Git SHAs")
    if not args.occupancies or any(value < 1 for value in args.occupancies):
        parser.error("Occupancies must be positive")
    if "aliased" in args.workloads and any(value < 4 for value in args.occupancies):
        parser.error("The aliased fallback control requires occupancy >= 4")
    if not args.workloads or any(
        value not in {"pipeline", "lifecycle-mixed", "phase", "aliased"}
        for value in args.workloads
    ):
        parser.error("Unknown or empty workload list")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.compile("-O")
        if not args.build_only:
            runner.differential("release")
            if args.tests_only:
                runner.compile("-Onone")
                runner.differential("debug")
                write_json(runner.output / "native-tests.json", runner.native_tests())
            else:
                runner.benchmark()
        print(str(runner.output), flush=True)
    finally:
        runner.save_manifest()


if __name__ == "__main__":
    main()
