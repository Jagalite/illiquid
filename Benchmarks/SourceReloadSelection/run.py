#!/usr/bin/env python3
"""Verify exact reload selection and compare verbatim production method slices.

This portable component harness excludes SwiftUI, filesystem I/O, and directory
loading. Separate optimized modules prevent the timing loop from being folded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import runpy
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE = "Sources/IlliquidApp/UI/SourceTreeDirectoryState.swift"
NORMALIZED = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
SUPPORT = {
    "Sources/IlliquidApp/UI/SourcesSidebar.swift": "SourceTreeIdentity",
    "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift": "SourceFilesystemInvalidationPlan",
}
EXTRACTOR = "Scripts/test-source-browser-search.py"
MAX_ITERATIONS = 10_000_000


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def method(source: str) -> tuple[str, int, int]:
    """Retain the exact method bytes, using the source's indentation boundary."""
    starts = list(re.finditer(r"(?m)^    static func reloadPaths\(", source))
    if len(starts) != 1:
        raise ValueError("Expected exactly one reloadPaths declaration")
    start = starts[0].start()
    closing = re.search(r"(?m)^    }$", source[start:])
    if closing is None:
        raise ValueError("No reloadPaths closing brace; review the extraction")
    end = start + closing.end()
    return source[start:end], source.count("\n", 0, start) + 1, source.count("\n", 0, end) + 1


class Runner:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            raise ValueError("Output directory must be new or empty")
        for name in ("sources", "logs", "build"):
            (self.out / name).mkdir(parents=True, exist_ok=True)
        self.swiftc = args.swiftc or shutil.which("swiftc")
        if not self.swiftc:
            raise ValueError("Swift 6.1+ is required; set PATH or --swiftc")
        self.binaries = {}
        self.manifest = {"sources": {}, "compiled_slices": {}, "binaries": {}}
        self.command_index = 0

    def write(self, name, value):
        (self.out / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(self, arguments, label, timeout=600):
        argv = [str(value) for value in arguments]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        self.command_index += 1
        stem = f"{self.command_index:04d}-{label}"
        for stream in ("stdout", "stderr"):
            (self.out / "logs" / f"{stem}.{stream}.txt").write_text(getattr(result, stream))
        with (self.out / "commands.jsonl").open("a") as output:
            output.write(json.dumps({"argv": argv, "label": label, "returncode": result.returncode,
                "seconds": time.monotonic() - started, "log_stem": stem,
                "stdout_sha256": sha(result.stdout.encode()), "stderr_sha256": sha(result.stderr.encode())},
                sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode})\n{result.stdout[-2000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    def snapshot(self, name, data, origin):
        destination = self.out / "sources" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        self.manifest["sources"][name] = {"origin": origin, "sha256": sha(data)}
        return destination

    def prepare(self):
        if platform.system() not in ("Darwin", "Linux"):
            raise ValueError("This harness supports macOS and Linux")
        pinned = json.loads((HERE / "baseline/manifest.json").read_text())
        baseline = (HERE / "baseline/SourceTreeDirectoryState.swift").read_bytes()
        if pinned != {"revision": BASELINE, "production_path": SOURCE, "sha256": sha(baseline)}:
            raise ValueError("Frozen baseline does not match its pinned source receipt")
        self.manifest.update({"baseline": pinned, "platform": platform.platform(),
            "architecture": platform.machine(), "logical_cpus": os.cpu_count(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "swift": self.command([self.swiftc, "--version"], "swift-version").strip(),
            "head": self.command(["git", "rev-parse", "HEAD"], "head").strip(),
            "git_status": self.command(["git", "status", "--short"], "git-status"),
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.args).items()},
            "scope": "Reload path selection only; excludes SwiftUI, I/O, and directory loading",
            "extraction": "Exact reloadPaths method in actor-isolated enum wrappers; no method-body substitutions"})
        if platform.system() == "Darwin":
            self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
            self.manifest["sdk"] = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk").strip()
        else:
            self.manifest["cpu"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown")
        for name in ("run.py", "Harness.swift", "Adapter.swift", "baseline/manifest.json"):
            self.snapshot(name, (HERE / name).read_bytes(), str((HERE / name).relative_to(ROOT)))
        self.snapshot("declaration-extractor.py", (ROOT / EXTRACTOR).read_bytes(), EXTRACTOR)
        declaration = runpy.run_path(str(ROOT / EXTRACTOR))["declaration"]
        support = "import Foundation\n\n"
        for path, name in SUPPORT.items():
            data = (ROOT / path).read_bytes()
            self.snapshot("originals/shared/" + Path(path).name, data, path)
            extracted, first, last = declaration(data.decode(), name)
            support += extracted + "\n\n"
            self.manifest["compiled_slices"][name] = {"source": path, "first_line": first,
                "last_line": last, "sha256": sha(extracted.encode())}
        self.support = self.snapshot("Support.swift", support.encode(), "verbatim shared declarations")
        self.normalized = self.snapshot("NormalizedFileURL.swift", (ROOT / NORMALIZED).read_bytes(), NORMALIZED)
        self.wrappers = {}
        for variant, data in (("baseline", baseline), ("candidate", (ROOT / SOURCE).read_bytes())):
            self.snapshot(f"originals/{variant}/SourceTreeDirectoryState.swift", data, SOURCE)
            extracted, first, last = method(data.decode())
            self.manifest["compiled_slices"][variant] = {"source": SOURCE, "first_line": first,
                "last_line": last, "sha256": sha(extracted.encode())}
            wrapper = "import Foundation\n\n@MainActor\nenum SourceTreeDirectoryState {\n" + extracted + "\n}\n"
            self.wrappers[variant] = self.snapshot(f"{variant}/Selector.swift", wrapper.encode(), "exact method in enum wrapper")
            if variant == "baseline":
                oracle = "import Foundation\n\n@MainActor\nenum BaselineSourceTreeDirectoryState {\n" + extracted + "\n}\n"
                self.oracle = self.snapshot("verifier/BaselineSelector.swift", oracle.encode(), "exact baseline method in renamed enum wrapper")
        if self.manifest["compiled_slices"]["baseline"]["sha256"] == self.manifest["compiled_slices"]["candidate"]["sha256"]:
            raise ValueError("Baseline and candidate reload selectors are identical")
        self.write("manifest.json", self.manifest)

    def build(self):
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
                 "-module-cache-path", self.out / "module-cache"]
        if platform.system() == "Darwin":
            flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
        for variant in ("baseline", "candidate", "verifier"):
            folder = self.out / "build" / variant
            folder.mkdir()
            definitions = ["-D", "DIFFERENTIAL_VERIFY"] if variant == "verifier" else []
            selector = self.wrappers["candidate" if variant == "verifier" else variant]
            sources = [self.normalized, self.support, selector, self.out / "sources/Adapter.swift"]
            if variant == "verifier":
                sources.append(self.oracle)
            extension = "dylib" if platform.system() == "Darwin" else "so"
            library = folder / ("libReloadSelection." + extension)
            self.command([self.swiftc, *flags, *definitions, "-emit-library", "-emit-module",
                "-module-name", "ReloadSelection", "-emit-module-path", folder / "ReloadSelection.swiftmodule",
                *sources, "-o", library], f"build-{variant}-module")
            binary = folder / "reload-selection"
            self.command([self.swiftc, *flags, *definitions, "-parse-as-library", "-I", folder, "-L", folder,
                "-lReloadSelection", "-Xlinker", "-rpath", "-Xlinker", folder,
                self.out / "sources/Harness.swift", "-o", binary], f"build-{variant}-harness")
            self.binaries[variant] = binary
            self.manifest["binaries"][variant] = {"executable_sha256": sha(binary.read_bytes()),
                "library_sha256": sha(library.read_bytes()), "flags": [str(flag) for flag in flags + definitions]}
            self.write("manifest.json", self.manifest)
            print("Built", variant, flush=True)

    def invoke(self, variant, *arguments):
        return json.loads(self.command([self.binaries[variant], *arguments], "run-" + variant))

    def verify(self):
        catalog = self.invoke("baseline", "--catalog")
        if catalog != self.invoke("candidate", "--catalog"):
            raise ValueError("Workload catalogs differ")
        self.write("catalog.json", catalog)
        verification = self.invoke("verifier", "--verify")
        if not verification.get("exact_utf8") or verification.get("cases", 0) < 1:
            raise ValueError("Verifier did not confirm exact UTF-8 parity")
        self.write("equivalence.json", verification)
        print(f'Exact UTF-8 parity: {verification["cases"]} fixtures', flush=True)
        workloads = catalog["workloads"]
        if len({row["name"] for row in workloads}) != len(workloads):
            raise ValueError("Duplicate workload names")
        if self.args.workloads:
            unknown = set(self.args.workloads) - {row["name"] for row in workloads}
            if unknown:
                raise ValueError(f"Unknown workloads: {sorted(unknown)}")
            workloads = [row for row in workloads if row["name"] in self.args.workloads]
        return workloads

    def sample(self, variant, workload, iterations):
        row = self.invoke(variant, "--case", workload["name"], "--iterations", iterations)
        if any(row.get(key) != value for key, value in {"workload": workload["name"], "iterations": iterations,
                "operations": iterations, "paths_per_call": workload["paths"]}.items()):
            raise ValueError("Timed sample metadata does not match its requested workload")
        if row["elapsed_ns"] <= 0 or row["cpu_ns"] <= 0:
            raise ValueError("Invalid wall or CPU duration")
        if row["warmup_checksum"] % 8 or row["checksum"] != row["warmup_checksum"] // 8 * iterations:
            raise ValueError("Timed selected-path count differs from the per-call warmup result")
        return row

    def measure(self, workloads):
        summaries, calibrations, total_samples = [], [], 0
        for workload in workloads:
            pilots, candidate_pilots, pilot_iterations = [], [], 1
            candidate_requested = None
            baseline_cap = MAX_ITERATIONS
            if self.args.iterations is None:
                while True:
                    pilot = self.sample("baseline", workload, pilot_iterations)
                    pilots.append(pilot)
                    if pilot["elapsed_ns"] >= 5_000_000:
                        break
                    if pilot_iterations >= MAX_ITERATIONS:
                        raise ValueError("Baseline pilot did not reach 5 ms within the iteration cap")
                    pilot_iterations = min(MAX_ITERATIONS, pilot_iterations * max(2,
                        math.ceil(5_500_000 / pilot["elapsed_ns"])))
                baseline_ns_per_call = pilot["elapsed_ns"] / pilot_iterations
                baseline_cap = max(1, min(MAX_ITERATIONS, math.floor(2_000_000_000 / baseline_ns_per_call)))
                requested = math.ceil(self.args.target_ms * 1_000_000 / baseline_ns_per_call)
                iterations = min(baseline_cap, max(1, requested))
                candidate_pilot = self.sample("candidate", workload, iterations)
                candidate_pilots.append(candidate_pilot)
                if candidate_pilot["warmup_checksum"] != pilot["warmup_checksum"]:
                    raise ValueError("Pilot selected-path counts differ across variants")
                if candidate_pilot["elapsed_ns"] < 5_000_000:
                    candidate_requested = math.ceil(5_000_000 * iterations / candidate_pilot["elapsed_ns"])
                    adjusted = min(baseline_cap, max(iterations, candidate_requested))
                    if adjusted > iterations:
                        iterations = adjusted
                        confirmation = self.sample("candidate", workload, iterations)
                        if confirmation["warmup_checksum"] != pilot["warmup_checksum"]:
                            raise ValueError("Candidate pilot count changed after calibration")
                        candidate_pilots.append(confirmation)
            else:
                requested = iterations = self.args.iterations
            calibrations.append({"workload": workload["name"], "baseline_pilots": pilots,
                "candidate_pilots": candidate_pilots, "iterations": iterations,
                "baseline_requested_iterations": requested, "candidate_requested_iterations": candidate_requested,
                "cap_applied": max(requested, candidate_requested or 0) > iterations,
                "iteration_cap": baseline_cap, "baseline_target_ms": self.args.target_ms,
                "candidate_target_ms": 5, "estimated_baseline_cap_ms": 2000,
                "estimated_baseline_ms": (iterations * baseline_ns_per_call / 1_000_000
                                           if self.args.iterations is None else None),
                "cap_policy": "Automatic counts are capped at 10M and an estimated 2s baseline; at least one call is required. Explicit --iterations bypasses calibration.",
                "override": self.args.iterations is not None})
            self.write("calibration.json", calibrations)
            rows, expected_count = [], None
            for pair in range(self.args.rounds):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                samples = {}
                for position, variant in enumerate(order):
                    row = self.sample(variant, workload, iterations)
                    count = row["warmup_checksum"] // 8
                    if expected_count is not None and count != expected_count:
                        raise ValueError("Timed selected-path count differs across variants or repetitions")
                    expected_count = count
                    row.update(variant=variant, pair=pair, process_order=position)
                    rows.append(row)
                    samples[variant] = row
                    with (self.out / "measurements.jsonl").open("a") as output:
                        output.write(json.dumps(row, sort_keys=True) + "\n")
                for key in ("checksum", "warmup_checksum", "iterations", "paths_per_call"):
                    if samples["baseline"][key] != samples["candidate"][key]:
                        raise ValueError(f"Timed pair output mismatch: {key}")
            summary = {**workload, "iterations": iterations, "pairs": self.args.rounds}
            for metric in ("elapsed_ns", "cpu_ns"):
                values = {variant: [row[metric] / iterations for row in rows if row["variant"] == variant]
                          for variant in ("baseline", "candidate")}
                changes = []
                for pair in range(self.args.rounds):
                    sample = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                    changes.append(100 * (sample["candidate"] / sample["baseline"] - 1))
                summary[metric] = {"median_ns_per_call": {key: statistics.median(value) for key, value in values.items()},
                    "range_ns_per_call": {key: [min(value), max(value)] for key, value in values.items()},
                    "paired_change_percent": changes, "median_paired_change_percent": statistics.median(changes)}
            summary["samples_under_1ms"] = [{"variant": row["variant"], "pair": row["pair"], "elapsed_ns": row["elapsed_ns"]}
                                           for row in rows if row["elapsed_ns"] < 1_000_000]
            summaries.append(summary)
            total_samples += len(rows)
            self.write("results.json", summaries)
            wall = summary["elapsed_ns"]["median_ns_per_call"]
            print(workload["name"], f'wall {wall["baseline"]:.1f} -> {wall["candidate"]:.1f} ns/call; '
                  f'paired change {summary["elapsed_ns"]["median_paired_change_percent"]:+.2f}%', flush=True)
        return total_samples

    def emit_evidence(self):
        for name in ("manifest.json", "catalog.json", "equivalence.json", "calibration.json",
                     "measurements.jsonl", "results.json", "completion.json"):
            path = self.out / name
            if path.exists():
                data = path.read_text()
                value = [json.loads(line) for line in data.splitlines()] if name.endswith(".jsonl") else json.loads(data)
                print(f"EVIDENCE_BEGIN {name}\n{json.dumps(value, sort_keys=True)}\nEVIDENCE_END {name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--workloads", nargs="+")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.rounds < 6 or args.rounds % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even --rounds >= 6 and a positive finite --target-ms")
    if args.iterations is not None and not 1 <= args.iterations <= MAX_ITERATIONS:
        parser.error(f"--iterations must be between 1 and {MAX_ITERATIONS}")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.build()
        workloads = runner.verify()
        samples = 0 if args.verify_only else runner.measure(workloads)
        runner.write("completion.json", {"complete": True, "verify_only": args.verify_only, "timed_samples": samples})
    finally:
        runner.emit_evidence()


if __name__ == "__main__":
    main()
