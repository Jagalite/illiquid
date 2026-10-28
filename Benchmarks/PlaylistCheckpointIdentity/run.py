#!/usr/bin/env python3
"""Compare shuffled checkpoint identity construction using complete production Swift sources."""
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
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
]
CALLER = "Sources/IlliquidPlayer/Player/PlaybackController.swift"
ORACLE_MARKERS = [
    "    public static func restoringOrder(",
    "    public static func deduplicated(_ items:",
    "    private static func uniqueResult(",
]
CALLSITE_MARKER = "    private func checkpointSession() -> Bool {"
CASES = [
    "empty", "singleton_no_base", "singleton_saved",
    "unique_10", "unique_100", "unique_1000", "unique_10000",
    "edited_10000", "duplicates_10000", "no_base_10000",
    "remote_1000", "unicode_1000", "restoration_control_1000",
]
VARIANTS = ("baseline", "candidate")
CYCLE = 4
MINIMUM_MS = 60


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_sha(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write("\n")
    temporary.replace(path)


def append_json(path: Path, value) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def function(source: bytes, marker: str) -> bytes:
    """Extract a pinned function verbatim; frozen hashes guard these known bodies."""
    encoded = marker.encode()
    if source.count(encoded) != 1:
        raise ValueError(f"Expected exactly one function: {marker}")
    start = source.index(encoded)
    opening = source.index(b"{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index:index + 1] == b"{":
            depth += 1
        elif source[index:index + 1] == b"}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1] + b"\n"
    raise ValueError(f"Unterminated function: {marker}")


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("--output must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        compiler = args.swiftc or shutil.which("swiftc")
        if not compiler:
            raise ValueError("Swift compiler not found; provide --swiftc")
        self.swiftc = str(Path(compiler).absolute())
        self.command_count = 0
        self.manifest = {
            "schema_version": 1, "phase": "initializing",
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "platform": platform.platform(), "machine": platform.machine(),
            "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
            "environment": {key: os.environ.get(key) for key in
                            ("LANG", "LC_ALL", "TZ", "DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING")},
            "compiler_path": self.swiftc,
            "compiler_resolved_path": str(Path(self.swiftc).resolve()),
            "compiler_binary_sha256": file_sha(Path(self.swiftc)),
            "sources": {}, "binaries": {},
            "source_mode": "Four complete production IlliquidCore sources; no platform surrogate.",
            "timing_scope": "Restore checkpoint IDs, consume all output UTF8 bytes, and release the result. "
                            "Fixture creation, frozen-oracle comparison, and complete byte equality are outside timing.",
            "sampling": "Fresh process for every pilot/sample; identical iteration counts within each pair; "
                        "AB/BA order alternates. Four varying fixtures repeat in complete cycles.",
            "checksum": "Order-sensitive FNV-1a over every output length/UTF8 byte; position-weighted cycle sum.",
            "memory_scope": "No allocator or RSS measurement. Identity-evaluation counts are derived from source.",
            "darwin_autorelease": "Both variants drain a per-call autorelease pool around restoration and consumption.",
            "pairs": args.pairs, "target_ms": args.target_ms, "minimum_ms": MINIMUM_MS,
            "cases": args.cases,
        }
        self.save_manifest()
        self.manifest["candidate_revision"] = self.command(["git", "rev-parse", "HEAD"]).decode().strip()
        self.manifest["candidate_status"] = self.command(["git", "status", "--short"]).decode().strip()
        self.manifest["compiler_version"] = self.command([self.swiftc, "--version"]).decode().strip()
        if platform.system() == "Linux":
            cpuinfo = Path("/proc/cpuinfo").read_text()
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in cpuinfo.splitlines() if line.startswith("model name")), platform.processor())
        elif platform.system() == "Darwin":
            self.manifest["cpu_model"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).decode().strip()
            self.manifest["macos"] = self.command(["sw_vers"]).decode().strip()
        self.save_manifest()

    def save_manifest(self):
        write_json(self.output / "manifest.json", self.manifest)

    def command(self, argv) -> bytes:
        argv = [str(value) for value in argv]
        index = self.command_count
        self.command_count += 1
        started = datetime.now(timezone.utc).isoformat()
        append_json(self.output / "commands.jsonl",
                    {"event": "start", "index": index, "argv": argv, "cwd": str(ROOT), "started_utc": started})
        begin = time.monotonic()
        process = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stem = self.output / "logs" / f"{index:04d}"
        stem.with_suffix(".stdout").write_bytes(process.stdout)
        stem.with_suffix(".stderr").write_bytes(process.stderr)
        append_json(self.output / "commands.jsonl", {
            "event": "finish", "index": index, "returncode": process.returncode,
            "elapsed_seconds": time.monotonic() - begin,
            "stdout_sha256": sha(process.stdout), "stderr_sha256": sha(process.stderr),
            "stdout_log": str(stem.with_suffix(".stdout").relative_to(self.output)),
            "stderr_log": str(stem.with_suffix(".stderr").relative_to(self.output)),
        })
        if process.returncode:
            raise RuntimeError(f"Command failed ({process.returncode}): {argv}\n"
                               + process.stderr.decode(errors="replace")[-12000:])
        return process.stdout

    def prepare(self):
        frozen = json.loads((HERE / "baseline.json").read_text())
        if frozen["revision"] != BASELINE:
            raise ValueError("Frozen baseline revision changed")
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        source_paths = {variant: [] for variant in VARIANTS}
        values = {}
        for path in [*SOURCES, CALLER]:
            old = self.command(["git", "show", f"{BASELINE}:{path}"])
            current = (ROOT / path).read_bytes()
            if sha(old) != frozen["files"][path]:
                raise ValueError(f"Pinned baseline source hash mismatch: {path}")
            if path in SOURCES[:-1] and old != current:
                raise ValueError(f"Shared dependency changed; review this comparison: {path}")
            values[path] = (old, current)
            for variant, source in zip(VARIANTS, (old, current)):
                folder = "callsite" if path == CALLER else variant
                target = self.output / "sources" / folder / (variant + "-" + Path(path).name if path == CALLER else Path(path).name)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source)
                self.manifest["sources"][f"{variant}:{path}"] = {
                    "sha256": sha(source), "snapshot": str(target.relative_to(self.output))}
                if path != CALLER:
                    source_paths[variant].append(target)

        baseline_mutation, candidate_mutation = values[SOURCES[-1]]
        oracle_parts = []
        for marker in ORACLE_MARKERS:
            part = function(baseline_mutation, marker)
            if sha(part) != frozen["oracle_functions"][marker]:
                raise ValueError(f"Frozen oracle hash mismatch: {marker}")
            if function(candidate_mutation, marker) != part:
                raise ValueError(f"Legacy restoration control changed: {marker}")
            oracle_parts.append(part)
        old_call, new_call = (function(value, CALLSITE_MARKER) for value in values[CALLER])
        if sha(old_call) != frozen["checkpoint_function_sha256"]:
            raise ValueError("Frozen checkpoint function changed")
        if (b"unshuffledPlaylistIDs = PlaylistMutation.restoringOrder(" not in old_call
                or b").map(\\.id)" not in old_call):
            raise ValueError("Baseline checkpoint adapter is not the original item-to-ID chain")
        if (b"unshuffledPlaylistIDs = PlaylistMutation.restoringIdentityOrder(" not in new_call
                or b"unshuffledPlaylistIDs = PlaylistMutation.restoringOrder(" in new_call):
            raise ValueError("Candidate checkpoint does not use the direct identity helper")
        if b"public static func restoringIdentityOrder(" not in candidate_mutation:
            raise ValueError("Candidate identity helper is missing")
        self.manifest["callsite_verified"] = True
        self.manifest["checkpoint_function_sha256"] = {
            "baseline": sha(old_call), "candidate": sha(new_call)}

        support = self.output / "sources" / "support"
        support.mkdir(parents=True)
        for name in ("Driver.swift", "run.py", "baseline.json"):
            target = support / name
            shutil.copyfile(HERE / name, target)
            self.manifest["sources"][f"harness:{name}"] = {
                "sha256": file_sha(target), "snapshot": str(target.relative_to(self.output))}
        oracle = support / "FrozenPlaylistMutation.swift"
        oracle.write_bytes(b"import Foundation\n\nenum FrozenPlaylistMutation {\n"
                           + b"\n".join(oracle_parts) + b"}\n")
        self.manifest["sources"]["harness:FrozenPlaylistMutation.swift"] = {
            "sha256": file_sha(oracle), "snapshot": str(oracle.relative_to(self.output)),
            "derivation": "Verbatim pinned restoringOrder, deduplicated and uniqueResult bodies in a distinct enum.",
        }
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-module-cache-path", str(self.output / "module-cache")]
        self.manifest["compiler_flags"] = flags
        self.manifest["phase"] = "staged"
        self.save_manifest()
        for variant in VARIANTS:
            folder = self.output / variant
            folder.mkdir()
            binary = folder / "benchmark"
            condition = ["-D", "BASELINE"] if variant == "baseline" else []
            print(f"Building {variant} from complete production sources", flush=True)
            self.command([self.swiftc, *flags, *condition, *source_paths[variant],
                          oracle, support / "Driver.swift", "-o", binary])
            self.manifest["binaries"][variant] = {"sha256": file_sha(binary),
                                                "path": str(binary.relative_to(self.output))}
            self.manifest["phase"] = f"compiled-{variant}"
            self.save_manifest()
        dependency_command = ["otool", "-L"] if platform.system() == "Darwin" else ["ldd"]
        self.manifest["linked_dependencies"] = self.command(
            [*dependency_command, self.output / "candidate/benchmark"]).decode()
        self.manifest["phase"] = "compiled"
        self.save_manifest()

    def invoke(self, variant, *arguments):
        return json.loads(self.command([self.output / variant / "benchmark", *arguments]))

    def verify(self):
        traces = {}
        for variant in VARIANTS:
            trace = self.invoke(variant, "verify")
            write_json(self.output / f"verification-{variant}.json", trace)
            traces[variant] = trace
        if traces["baseline"] != traces["candidate"]:
            raise ValueError("Full UTF8 parity receipts differ; inspect saved verification traces")
        self.trace = traces["candidate"]
        write_json(self.output / "parity.json", {
            "equal": True, "full_utf8_equality_verified": self.trace["full_utf8_equality_verified"],
            "timed_fixtures": len(self.trace["timed_fixtures"]),
            "additional_differential_fixtures": len(self.trace["differential_fixtures"]),
            "oracle": "Pinned baseline methods plus independent authored integer identity labels.",
        })
        self.manifest["phase"] = "verified"
        self.save_manifest()
        print(f"Full UTF8 parity: {len(self.trace['timed_fixtures'])} timed fixtures and "
              f"{len(self.trace['differential_fixtures'])} differential fixtures", flush=True)

    def observation(self, variant, case, iterations):
        row = self.invoke(variant, "measure", case, str(iterations))
        expected_fixtures = [entry for entry in self.trace["timed_fixtures"]
                             if entry["fixture"].startswith(case + "/")]
        if (row["workload"] != case or row["iterations"] != iterations
                or row["fixture_count"] != CYCLE or row["fixtures"] != expected_fixtures
                or row["checksum"] != row["expected_checksum"]):
            raise ValueError(f"Timed fixture/output receipt mismatch: {variant}/{case}")
        return row

    def calibrate(self, variant, case):
        iterations = CYCLE
        pilots = []
        for _ in range(8):
            row = self.observation(variant, case, iterations)
            pilots.append(row)
            append_json(self.output / "calibration-observations.jsonl",
                        {"variant": variant, "phase": "calibration", **row})
            duration = min(row["elapsed_nanoseconds"], row["cpu_nanoseconds"])
            if duration >= self.args.target_ms * 1_000_000:
                return {"iterations": iterations, "pilots": pilots}
            requested = math.ceil(iterations * self.args.target_ms * 1_000_000 * 1.25 / max(1, duration))
            iterations = max(iterations + CYCLE, math.ceil(requested / CYCLE) * CYCLE)
            if iterations > 100_000_000:
                raise ValueError("Calibration exceeds 100 million calls")
        raise ValueError(f"Calibration target not met: {variant}/{case}")

    def measure(self):
        summaries, calibrations = [], {}
        all_durations_met = True
        for case in self.args.cases:
            calibration = {variant: self.calibrate(variant, case) for variant in VARIANTS}
            iterations = max(value["iterations"] for value in calibration.values())
            calibrations[case] = {"variants": calibration, "shared_iterations": iterations}
            write_json(self.output / "calibration.json", calibrations)
            pairs = []
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                values = {}
                for position, variant in enumerate(order):
                    row = self.observation(variant, case, iterations)
                    row.update({"variant": variant, "pair": pair, "position_in_pair": position,
                                "order": list(order), "phase": "measurement"})
                    append_json(self.output / "measurements.jsonl", row)
                    values[variant] = row
                for key in ("iterations", "fixture_count", "fixtures", "cycle_checksum", "checksum",
                            "expected_checksum", "restoration_control"):
                    if values["baseline"][key] != values["candidate"][key]:
                        raise ValueError(f"Paired output mismatch in {case}/{pair}: {key}")
                pairs.append(values)
            summary = {"workload": case, "pairs": self.args.pairs, "iterations_per_process": iterations,
                       "fixtures": pairs[0]["baseline"]["fixtures"], "minimum_required_ms": MINIMUM_MS}
            under_minimum = []
            for metric, field in (("wall", "elapsed_nanoseconds"), ("cpu", "cpu_nanoseconds")):
                normalized = {variant: [pair[variant][field] / iterations for pair in pairs]
                              for variant in VARIANTS}
                old, new = (statistics.median(normalized[variant]) for variant in VARIANTS)
                ratios = [pair["candidate"][field] / pair["baseline"][field] for pair in pairs]
                summary[metric] = {
                    "baseline_ns_per_call": old, "candidate_ns_per_call": new,
                    "change_percent": (new / old - 1) * 100,
                    "median_paired_change_percent": (statistics.median(ratios) - 1) * 100,
                    "paired_ratios": ratios, "candidate_faster_pairs": sum(value < 1 for value in ratios),
                    "ranges_ns_per_call": {variant: [min(normalized[variant]), max(normalized[variant])]
                                           for variant in VARIANTS},
                    "minimum_observed_ms": {variant: min(pair[variant][field] for pair in pairs) / 1_000_000
                                            for variant in VARIANTS},
                }
                under_minimum += [{"variant": variant, "pair": pair[variant]["pair"], "metric": metric,
                                   "observed_ms": pair[variant][field] / 1_000_000}
                                  for pair in pairs for variant in VARIANTS
                                  if pair[variant][field] < MINIMUM_MS * 1_000_000]
            summary["observations_under_minimum"] = under_minimum
            all_durations_met = all_durations_met and not under_minimum
            summaries.append(summary)
            write_json(self.output / "summary.json", summaries)
            print(f"{case}: {summary['wall']['change_percent']:+.1f}% wall, "
                  f"{summary['cpu']['change_percent']:+.1f}% CPU", flush=True)
        report = [
            "# Shuffled checkpoint identity benchmark", "",
            "Medians include restoration, full UTF8 checksum consumption, and result release. "
            "Setup and complete output verification are outside timing. "
            "Negative change means lower cost. No allocation or RSS measurements are made.", "",
            "| Workload | Baseline wall µs/call | Candidate wall µs/call | Wall change | CPU change |",
            "|---|---:|---:|---:|---:|",
        ]
        for row in summaries:
            report.append(f"| {row['workload']} | {row['wall']['baseline_ns_per_call'] / 1000:.3f} | "
                          f"{row['wall']['candidate_ns_per_call'] / 1000:.3f} | "
                          f"{row['wall']['change_percent']:+.2f}% | {row['cpu']['change_percent']:+.2f}% |")
        report += ["", "Raw samples, per-pair ratios, ranges, calibration, byte-equality receipts, commands, "
                   "complete source snapshots and hashes accompany this report.", ""]
        (self.output / "report.md").write_text("\n".join(report))
        if not all_durations_met:
            raise ValueError("A raw wall or CPU observation was below 60 ms; rerun with a higher --target-ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2:
        parser.error("--pairs must be an even number of at least six")
    if not math.isfinite(args.target_ms) or args.target_ms < 150:
        parser.error("--target-ms must be at least 150")
    if len(set(args.cases)) != len(args.cases):
        parser.error("--cases must not contain duplicates")
    runner = None
    try:
        runner = Runner(args)
        runner.prepare()
        runner.verify()
        if not args.verify_only:
            runner.measure()
        runner.manifest["phase"] = "complete"
        write_json(runner.output / "completion.json", {
            "complete": True, "verify_only": args.verify_only,
            "full_utf8_equality_verified": True,
            "minimum_observation_duration_met": None if args.verify_only else True,
            "pairs": args.pairs, "target_ms": args.target_ms, "minimum_ms": MINIMUM_MS,
            "cases": args.cases, "finished_utc": datetime.now(timezone.utc).isoformat(),
        })
    except BaseException as error:
        if runner:
            runner.manifest["phase"] = "failed"
            write_json(runner.output / "completion.json",
                       {"complete": False, "error": f"{type(error).__name__}: {error}"})
        raise
    finally:
        if runner:
            runner.save_manifest()


if __name__ == "__main__":
    main()
