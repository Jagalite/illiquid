#!/usr/bin/env python3
"""Compare the actual source-presence publication loop and result mutations.

Filesystem traversal, revision acceptance, scheduling, fixture construction and
result verification are outside timing. Foundation, Observation, MainActor,
Swift collections and the production propagation implementations are real.
No subscribed SwiftUI view is constructed. See manifest.json for exact sources
and the shared/unique initial dictionary ownership boundary.
"""
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
import tempfile
import textwrap
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift"
HELPER = "Sources/IlliquidApp/UI/SourceMediaPresenceRecomputation.swift"
PIN = "68274d1b09dcc866296321a5a8858efc297c4f19"
BASELINE_SHA = "189923662492651098f89f5a4deebc7c9f8891ded3b30b339e183b36c7de26f5"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source, marker):
    """Extract one known declaration; these fragments have no braced literals."""
    if source.count(marker) != 1:
        raise RuntimeError(f"Expected one declaration: {marker!r}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise RuntimeError(f"Unclosed declaration: {marker!r}")


def scanner_shell(data, variant):
    source = data.decode()
    marker = "                            for folder in "
    terminator = "                            bufferedSummaries.removeAll(keepingCapacity: true)"
    if source.count(marker) != 1 or source.count(terminator) != 1:
        raise RuntimeError("Publication extraction markers no longer uniquely match")
    loop = textwrap.dedent(source[source.index(marker):source.index(terminator)])
    expected = "bufferedSummaries.keys.sorted" if variant == "baseline" else \
        "SourceMediaPresenceRecomputation.orderedPaths"
    if expected not in loop or loop.count("self.recompute(folder)") != 1:
        raise RuntimeError(f"Unexpected {variant} publication loop")
    fields = [
        "private(set) var results: [String: Bool] = [:]",
        "@ObservationIgnored private var roots: [String] = []",
        "@ObservationIgnored private var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]",
    ]
    if "@MainActor @Observable\nfinal class SourceMediaPresenceScanner" not in source \
            or any(source.count(field) != 1 for field in fields):
        raise RuntimeError("Production observation/storage declarations changed")
    methods = [declaration(source, marker) for marker in (
        "    private func recompute(", "    private func isWatched(",
        "    private static func contains(")]
    summary = declaration(source, "    struct Summary: Sendable {")
    generated = "import Foundation\nimport Observation\n\n" \
        + "enum SourceMediaPresenceCursor {\n" + summary + "\n}\n\n" \
        + "@MainActor @Observable\nfinal class BenchmarkScanner {\n" \
        + "\n".join("    " + field for field in fields) + "\n" + '''
    init(roots: [String], summaries: [String: SourceMediaPresenceCursor.Summary]) {
        self.roots = roots
        self.summaries = summaries
    }

    // Setup only, excluded from every measured publication.
    func resetResults(_ initial: [String: Bool], unique: Bool) {
        results = initial
        if unique { results.reserveCapacity(max(1, initial.count)) }
    }

    @inline(never)
    func publish(_ bufferedSummaries: [String: SourceMediaPresenceCursor.Summary]) {
''' + textwrap.indent(loop, "        ") + "    }\n\n" \
        + "\n\n".join(methods) + "\n}\n"
    return generated.encode(), {
        "publication_loop_sha256": sha(loop.encode()),
        "recompute_sha256": sha(methods[0].encode()),
        "summary_sha256": sha(summary.encode()),
    }


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output).resolve() if args.output else Path(
            tempfile.mkdtemp(prefix="illiquid-source-presence-"))
        if self.output.exists() and any(self.output.iterdir()):
            raise RuntimeError("Use a new, empty --output directory to preserve prior evidence")
        self.build = self.output / "build"
        self.build.mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1")
        compiler = args.swiftc or os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not compiler:
            raise RuntimeError("Swift compiler unavailable; set --swiftc, SWIFTC, or PATH")
        self.swiftc = str(Path(compiler).absolute())
        self.sources = {}
        self.binaries = {}
        self.manifest = {
            "baseline_commit": PIN, "baseline_source_sha256": BASELINE_SHA,
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(), "arguments": vars(args),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "environment": {"SWIFT_DETERMINISTIC_HASHING": "1"},
            "clock": "DispatchTime.now().uptimeNanoseconds; one bracket per publication",
            "scope": "Actual publication ordering and recompute bodies, real Foundation and "
                "@MainActor @Observable result setters; no subscribed view. Excludes scanning, "
                "acceptance gates, async scheduling, fixture/reset work and verification.",
            "ownership": "Initial result snapshot retained: first mutation CoW is timed"
                if args.ownership == "shared" else
                "reserveCapacity forces unique initial storage before timing",
            "source_snapshots": {}, "generated_sources": {}, "binary_sha256": {},
        }
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        if Path("/proc/cpuinfo").exists():
            self.manifest["cpu_model"] = next((line.split(":", 1)[1].strip()
                for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), "unknown")

    def run(self, command):
        command = [str(item) for item in command]
        start = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True)
        record = {"argv": command, "wall_seconds": time.monotonic() - start,
                  "returncode": result.returncode, "stdout_sha256": sha(result.stdout),
                  "stdout_bytes": len(result.stdout)}
        if result.stderr:
            record["stderr"] = result.stderr.decode(errors="replace")
        self.append("commands.jsonl", record)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n"
                               + result.stderr.decode(errors="replace"))
        return result.stdout

    def append(self, name, value):
        with (self.output / name).open("a") as handle:
            handle.write(json.dumps(value, sort_keys=True) + "\n")

    def save(self):
        write_json(self.output / "manifest.json", self.manifest)

    def snapshot(self, label, data):
        path = self.output / "sources" / label
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.manifest["source_snapshots"][label] = {
            "sha256": sha(data), "git_blob_sha1": blob(data), "bytes": len(data)}
        return path

    def prepare(self):
        if self.args.baseline_source:
            baseline = Path(self.args.baseline_source).read_bytes()
        else:
            try:
                baseline = self.run(["git", "show", f"{PIN}:{SOURCE}"])
            except RuntimeError as error:
                raise RuntimeError("Pinned baseline unavailable. Use --baseline-source with "
                    "sources/baseline/SourceMediaPresenceScanner.swift from retained evidence; "
                    "its SHA256 is checked.") from error
        if sha(baseline) != BASELINE_SHA:
            raise RuntimeError("Baseline source does not match the pinned SHA256")
        candidate = (ROOT / SOURCE).read_bytes()
        self.manifest["compiler"] = self.run([self.swiftc, "--version"]).decode().strip()
        self.manifest["checkout_head"] = self.run(["git", "rev-parse", "HEAD"]).decode().strip()
        self.driver = self.snapshot("harness/Driver.swift", (HERE / "Driver.swift").read_bytes())
        self.snapshot("harness/run.py", Path(__file__).read_bytes())
        self.helper = self.snapshot("candidate/SourceMediaPresenceRecomputation.swift",
                                    (ROOT / HELPER).read_bytes())
        for name, data in (("baseline", baseline), ("candidate", candidate)):
            self.snapshot(f"{name}/SourceMediaPresenceScanner.swift", data)
            generated, fragments = scanner_shell(data, name)
            path = self.build / f"Scanner-{name}.swift"
            path.write_bytes(generated)
            self.sources[name] = path
            self.manifest["generated_sources"][name] = {
                "sha256": sha(generated), "fragments": fragments}
        self.save()

    def compile(self, configuration):
        flags = ["-O", "-whole-module-optimization"] if configuration == "release" else ["-Onone"]
        for name, source in self.sources.items():
            binary = self.build / f"{name}-{configuration}"
            command = [self.swiftc, *flags, "-swift-version", "6", "-parse-as-library",
                       "-warnings-as-errors", "-module-cache-path", self.build / "module-cache",
                       source, self.driver]
            if name == "candidate":
                command.append(self.helper)
            self.run([*command, "-o", binary])
            self.binaries[name, configuration] = binary
            self.manifest["binary_sha256"][f"{name}-{configuration}"] = sha(binary.read_bytes())
        self.save()

    def differential(self, configuration):
        receipts = []
        for seed in self.args.seeds:
            maps = {}
            for name in ("baseline", "candidate"):
                maps[name] = json.loads(self.run([
                    self.binaries[name, configuration], "--mode", "check", "--seed", seed,
                    "--ownership", self.args.ownership]))
            if maps["baseline"] != maps["candidate"]:
                write_json(self.output / "differential-failure.json", maps)
                raise RuntimeError("Full final result maps differ; see differential-failure.json")
            receipts.append({"seed": seed, "equal": True,
                "cases": [{"case": row["case"], "result_count": len(row["results"]),
                           "results_sha256": sha(canonical(row["results"]))}
                          for row in maps["candidate"]]})
        write_json(self.output / f"differential-{configuration}.json", receipts)

    def measure(self, variant, case, iterations, seed):
        row = json.loads(self.run([
            self.binaries[variant, "release"], "--mode", "time", "--case", case,
            "--iterations", iterations, "--warmup", self.args.warmup,
            "--seed", seed, "--ownership", self.args.ownership]))
        results = row.pop("results")
        row.update(variant=variant, results_sha256=sha(canonical(results)),
                   result_count=len(results))
        return row, results

    def timings(self):
        cases = json.loads(self.run([self.binaries["candidate", "release"], "--mode", "list"]))
        if self.args.case:
            unknown = set(self.args.case) - {row["case"] for row in cases}
            if unknown:
                raise RuntimeError(f"Unknown cases: {sorted(unknown)}")
            cases = [row for row in cases if row["case"] in self.args.case]
        target = self.args.target_ms * 1_000_000
        measurements = []
        for case in cases:
            name = case["case"]
            iterations = {}
            for variant in ("baseline", "candidate"):
                count = 1
                for attempt in range(4):
                    row, _ = self.measure(variant, name, count, self.args.seeds[0])
                    self.append("calibration.jsonl", dict(row, attempt=attempt))
                    if row["timed_nanoseconds"] >= target or count >= 100_000:
                        break
                    count = min(100_000, max(count + 1, math.ceil(
                        count * target / max(1, row["timed_nanoseconds"]) * 1.15)))
                iterations[variant] = count
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                pair_maps = {}
                rows = {}
                for variant in order:
                    row, pair_maps[variant] = self.measure(
                        variant, name, iterations[variant], self.args.seeds[0] + pair * 17)
                    row.update(pair=pair, order="AB" if pair % 2 == 0 else "BA")
                    rows[variant] = row
                    measurements.append(row)
                    self.append("measurements.jsonl", row)
                if pair_maps["baseline"] != pair_maps["candidate"]:
                    write_json(self.output / "timing-results-failure.json", pair_maps)
                    raise RuntimeError(f"Final result map differs: {name}, pair {pair}")
                self.append("pairs.jsonl", {
                    "case": name, "pair": pair, "order": rows["baseline"]["order"],
                    "equal": True, "results_sha256": rows["baseline"]["results_sha256"],
                    "baseline_ns": rows["baseline"]["nanoseconds_per_publication"],
                    "candidate_ns": rows["candidate"]["nanoseconds_per_publication"]})
            print(f"Completed {name}: {self.args.pairs} paired comparisons", flush=True)
        summary = {"units": "nanoseconds per publication", "ownership": self.args.ownership,
                   "pairs": self.args.pairs, "target_sample_ms": self.args.target_ms, "cases": []}
        for case in cases:
            rows = [row for row in measurements if row["case"] == case["case"]]
            entry = dict(case)
            times = {}
            for variant in ("baseline", "candidate"):
                values = [row["nanoseconds_per_publication"] for row in rows if row["variant"] == variant]
                times[variant] = values
                entry[variant] = {"min": min(values), "median": statistics.median(values),
                                  "max": max(values)}
            ratios = [a / b for a, b in zip(times["baseline"], times["candidate"])]
            entry["median_paired_speedup"] = statistics.median(ratios)
            entry["median_paired_reduction_percent"] = statistics.median(
                [(1 - 1 / ratio) * 100 for ratio in ratios])
            entry["short_samples"] = sum(row["timed_nanoseconds"] < target for row in rows)
            summary["cases"].append(entry)
        write_json(self.output / "summary.json", summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="New, empty evidence directory")
    parser.add_argument("--swiftc", help="Compiler path; otherwise SWIFTC or PATH")
    parser.add_argument("--baseline-source", help="Checked retained baseline for shallow clones")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=30)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--ownership", choices=("shared", "unique"), default="shared")
    parser.add_argument("--seeds", type=int, nargs="+", default=[1, 17, 65])
    parser.add_argument("--case", action="append", help="Time selected case(s); all correctness cases still run")
    parser.add_argument("--tests-only", action="store_true", help="Debug/release fixture differential checks, no timings")
    parser.add_argument("--quick", action="store_true", help="Smoke run: 3 pairs, 5 ms target, one correctness seed")
    args = parser.parse_args()
    if args.quick:
        args.pairs, args.target_ms, args.seeds = 3, 5, args.seeds[:1]
    if args.pairs < 1 or args.target_ms <= 0 or args.warmup < 0 or any(seed < 0 for seed in args.seeds):
        parser.error("Pairs/target must be positive; warmup and seeds nonnegative")
    runner = Runner(args)
    print(f"Evidence: {runner.output}", flush=True)
    try:
        runner.prepare()
        for configuration in ("debug", "release"):
            runner.compile(configuration)
            runner.differential(configuration)
        if not args.tests_only:
            runner.timings()
    finally:
        runner.save()


if __name__ == "__main__":
    main()
