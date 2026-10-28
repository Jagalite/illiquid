#!/usr/bin/env python3
"""Measure the actual video color sampler with native macOS CoreVideo buffers.

Compile unmodified source snapshots from the baseline and working tree, verify
complete outputs in debug and release, then run alternating fresh-process pairs.
No Linux substitute for CoreVideo is used.
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
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SAMPLER = "Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift"
MAPPING = "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift"
CORE = "Sources/IlliquidCore/Player/VideoColorSample.swift"
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")


def sha(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        self.swiftc = args.swiftc or shutil.which("swiftc") or "swiftc"
        self.commands = []
        self.binaries = {}
        self.sources = {}
        self.tracked_inputs = {}
        self.build_policy_reported = False

    def write(self, name, value):
        (self.output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, argv, label, timeout=600):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        log = self.output / "logs" / (label + ".log")
        try:
            result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            def decoded(value):
                return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")
            log.write_text(decoded(error.stdout) + decoded(error.stderr))
            self.commands.append({"argv": argv, "cwd": str(ROOT), "returncode": None,
                                  "timed_out": True, "seconds": time.monotonic() - started,
                                  "log": str(log.relative_to(self.output)), "log_sha256": sha(log.read_bytes())})
            self.write("commands.json", self.commands)
            raise RuntimeError(f"{label} exceeded {timeout}s; partial output retained in {log}") from error
        log.write_text(result.stdout + result.stderr)
        self.commands.append({
            "argv": argv, "cwd": str(ROOT), "returncode": result.returncode,
            "seconds": time.monotonic() - started,
            "log": str(log.relative_to(self.output)), "log_sha256": sha(log.read_bytes()),
            "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
        })
        self.write("commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(f"{label} exited {result.returncode}\n{log.read_text()[-7000:]}")
        return result.stdout

    def build(self, argv, label):
        if KYOTO.is_file():
            cli = ["python3", KYOTO]
            submitted = json.loads(self.command([*cli, "submit", "--", *argv], label + "-submit"))
            job = str(submitted["id"])
            self.command([*cli, "show", job], label + "-show")
            try:
                self.command([*cli, "wait", job], label + "-wait", timeout=3600)
            finally:
                self.command([*cli, "logs", job], label + "-logs")
        else:
            if not self.build_policy_reported:
                print("Kyoto is unavailable on this host; compiling serially in isolated build directories.", flush=True)
                self.build_policy_reported = True
            self.command(argv, label)

    def prepare(self):
        if platform.system() != "Darwin":
            raise RuntimeError("Native macOS CoreVideo is required; no emulated performance result is accepted")
        self.args.baseline = self.command(
            ["git", "rev-parse", f"{self.args.baseline}^{{commit}}"], "baseline-commit"
        ).strip()
        sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk-path").strip()
        self.write("environment.json", {
            "schema": 1,
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "baseline_revision": self.args.baseline,
            "candidate_revision": self.command(["git", "rev-parse", "HEAD"], "git-head").strip(),
            "working_tree_status": self.command(["git", "status", "--short"], "git-status"),
            "macos": self.command(["sw_vers"], "macos").strip(),
            "cpu": self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip(),
            "model": self.command(["sysctl", "-n", "hw.model"], "hardware-model").strip(),
            "architecture": platform.machine(), "logical_cpus": os.cpu_count(),
            "swift": self.command([self.swiftc, "--version"], "swift-version").strip(),
            "sdk_version": self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version").strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "kyoto_available": KYOTO.is_file(),
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.args).items()},
        })
        inputs = [ROOT / path for path in (SAMPLER, MAPPING, CORE)] + [HERE / "Benchmark.swift", Path(__file__)]
        self.tracked_inputs = {str(path.relative_to(ROOT)): sha(path.read_bytes()) for path in inputs}
        snapshots = {}
        for variant in ("baseline", "candidate"):
            directory = self.output / "sources" / variant
            directory.mkdir(parents=True)
            snapshots[variant] = {}
            self.sources[variant] = {"files": {}, "builds": {}}
            for path in (CORE, MAPPING, SAMPLER):
                raw = (self.command(["git", "show", f"{self.args.baseline}:{path}"],
                                    "baseline-" + Path(path).stem)
                       if variant == "baseline" else (ROOT / path).read_text())
                staged = directory / Path(path).name
                staged.write_text(raw)
                snapshots[variant][path] = staged
                self.sources[variant]["files"][path] = sha(raw)
        for path in (CORE, MAPPING):
            if self.sources["baseline"]["files"][path] != self.sources["candidate"]["files"][path]:
                raise RuntimeError(f"Shared dependency changed: {path}; isolate the sampler comparison first")
        if self.sources["baseline"]["files"][SAMPLER] == self.sources["candidate"]["files"][SAMPLER]:
            raise RuntimeError("Baseline and candidate samplers are identical")
        harness = self.output / "sources" / "Benchmark.swift"
        shutil.copyfile(HERE / "Benchmark.swift", harness)
        shutil.copyfile(Path(__file__), self.output / "sources" / "run.py")
        for variant in ("baseline", "candidate"):
            for configuration in ("debug", "release"):
                directory = self.output / "build" / variant / configuration
                directory.mkdir(parents=True)
                flags = ["-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                         "-target", f"{platform.machine()}-apple-macos26.0", "-sdk", sdk,
                         "-module-cache-path", self.output / "module-cache"]
                flags += ["-Onone", "-g"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
                core_library = directory / "libIlliquidCore.dylib"
                self.build([self.swiftc, *flags, "-module-name", "IlliquidCore", "-emit-library",
                            "-emit-module", "-emit-module-path", directory / "IlliquidCore.swiftmodule",
                            snapshots[variant][CORE], "-o", core_library], f"{variant}-{configuration}-core")
                binary = directory / "benchmark"
                self.build([self.swiftc, *flags, "-I", directory, "-L", directory, "-lIlliquidCore",
                            "-Xlinker", "-rpath", "-Xlinker", directory,
                            snapshots[variant][MAPPING], snapshots[variant][SAMPLER], harness,
                            "-o", binary], f"{variant}-{configuration}-benchmark")
                self.binaries[(variant, configuration)] = binary
                self.sources[variant]["builds"][configuration] = {
                    "flags": [str(value) for value in flags], "binary_sha256": sha(binary.read_bytes()),
                    "core_library_sha256": sha(core_library.read_bytes()),
                }
                print(f"Built {variant}/{configuration}", flush=True)
        self.write("source-receipts.json", {"variants": self.sources, "tracked_inputs": self.tracked_inputs})

    def invoke(self, variant, configuration, mode, *arguments, label=None):
        name = label or f"{variant}-{configuration}-{mode.lstrip('-')}"
        return json.loads(self.command([self.binaries[(variant, configuration)], mode, *arguments], name))

    def verify(self):
        reference = None
        comparisons = []
        cases = None
        for configuration in ("debug", "release"):
            for variant in ("baseline", "candidate"):
                actual_cases = self.invoke(variant, configuration, "--list")
                if cases is not None and cases != actual_cases:
                    raise RuntimeError("Workload definitions differ between binaries")
                cases = actual_cases
                trace = self.invoke(variant, configuration, "--verify")
                self.write(f"{variant}-{configuration}-verification.json", trace)
                if reference is not None and trace != reference:
                    raise RuntimeError(f"Complete color/state parity failed for {variant}/{configuration}")
                reference = trace
                comparisons.append({"variant": variant, "configuration": configuration,
                                    "trace_sha256": sha(json.dumps(trace, sort_keys=True)),
                                    "records": len(trace["records"]), "golden_checks": trace["goldenChecks"]})
        self.write("parity.json", {"equal": True, "comparisons": comparisons})
        self.write("workloads.json", cases)
        print(f"Exact debug/release parity: {len(reference['records'])} records per binary", flush=True)
        return cases

    def measure(self, cases):
        summaries, calibrations = [], []
        selected = [case for case in cases if not self.args.case or case["name"] in self.args.case]
        if self.args.case and {case["name"] for case in selected} != set(self.args.case):
            raise ValueError("Unknown --case; inspect --list from the compiled harness")
        for case_index, case in enumerate(selected):
            name = case["name"]
            pilots = {variant: self.invoke(variant, "release", "--bench", name, 10_000,
                                          label=f"pilot-{case_index}-{variant}")
                      for variant in ("baseline", "candidate")}
            fastest = min(row["wallNanoseconds"] / row["iterations"] for row in pilots.values())
            requested = math.ceil(self.args.target_ms * 1_000_000 * 1.5 / max(fastest, 1))
            iterations = min(100_000_000, max(10_000, math.ceil(requested / 1024) * 1024))
            calibrations.append({"case": name, "pilots": pilots, "iterations": iterations,
                                 "requested_iterations": requested, "cap_applied": requested > 100_000_000,
                                 "target_ms": self.args.target_ms, "margin": 1.5})
            self.write("calibration.json", calibrations)
            rows = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if (pair + case_index) % 2 == 0 else ("candidate", "baseline")
                pair_rows = {}
                for position, variant in enumerate(order):
                    row = self.invoke(variant, "release", "--bench", name, iterations,
                                      label=f"sample-{case_index}-{pair}-{variant}")
                    if row["iterations"] != iterations or row["case"] != name:
                        raise RuntimeError("Harness returned a different workload or iteration count")
                    if row["wallNanoseconds"] <= 0 or row["cpuNanoseconds"] <= 0:
                        raise RuntimeError("Invalid timer result")
                    row.update(variant=variant, pair=pair, process_order=position, order=list(order))
                    rows.append(row)
                    pair_rows[variant] = row
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                for field in ("checksum", "warmupChecksum", "layout", "iterations"):
                    if pair_rows["baseline"][field] != pair_rows["candidate"][field]:
                        raise RuntimeError(f"Timed output mismatch: {name}/{pair}/{field}")
            summary = {"case": name, "iterations": iterations, "pairs": self.args.pairs}
            for metric in ("wallNanoseconds", "cpuNanoseconds"):
                values = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                          for variant in ("baseline", "candidate")}
                medians = {variant: statistics.median(values[variant]) for variant in values}
                paired_changes = []
                for pair in range(self.args.pairs):
                    samples = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                    paired_changes.append(100 * (samples["candidate"] / samples["baseline"] - 1))
                summary[metric] = {
                    "median_ns_per_operation": medians,
                    "range_ns_per_operation": {variant: [min(value), max(value)] for variant, value in values.items()},
                    "change_percent": 100 * (medians["candidate"] / medians["baseline"] - 1),
                    "paired_change_percent": paired_changes,
                    "pairs_improved": sum(value < 0 for value in paired_changes),
                }
            summary["observations_under_target"] = [
                {"variant": row["variant"], "pair": row["pair"], "ms": row["wallNanoseconds"] / 1_000_000}
                for row in rows if row["wallNanoseconds"] < self.args.target_ms * 1_000_000]
            summaries.append(summary)
            self.write("summary.json", summaries)
            wall = summary["wallNanoseconds"]
            print(f"{name}: {wall['median_ns_per_operation']['baseline']:.1f} -> "
                  f"{wall['median_ns_per_operation']['candidate']:.1f} ns/op "
                  f"({wall['change_percent']:+.2f}%)", flush=True)
        return {"cases": len(selected), "observations": len(selected) * self.args.pairs * 2,
                "minimum_duration_met": all(not row["observations_under_target"] for row in summaries)}

    def check_sources_unchanged(self):
        for path, expected in self.tracked_inputs.items():
            if sha((ROOT / path).read_bytes()) != expected:
                raise RuntimeError(f"Input changed while benchmark was running: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=200)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--case", action="append", help="Measure only this named case; may repeat")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even number of pairs >= 2 and a positive finite target-ms")
    runner = Runner(args)
    try:
        runner.prepare()
        cases = runner.verify()
        result = {} if args.tests_only else runner.measure(cases)
        runner.check_sources_unchanged()
        runner.write("completion.json", {"complete": True, "tests_only": args.tests_only, **result})
    except Exception as error:
        runner.write("completion.json", {"complete": False, "error": str(error)})
        raise
    finally:
        runner.write("commands.json", runner.commands)


if __name__ == "__main__":
    main()
