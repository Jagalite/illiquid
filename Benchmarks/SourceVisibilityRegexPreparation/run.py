#!/usr/bin/env python3
"""Compare lazy regex candidate preparation in exact native source projections.

macOS only. Uses whole production files and guarded verbatim declarations from
the existing source-tree snapshot helper. Fixture construction and projection
receipts are outside timing; each measured projection uses a fresh filter actor.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
FOCAL = "Sources/IlliquidApp/SidebarValues.swift"
HELPER = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
VARIANTS = ("baseline", "candidate")
CASES = ("tree_manual_hide", "tree_always_show", "files_manual_ancestor",
         "disabled_regex", "invalid_regex", "regex_nonmatch", "regex_match",
         "default_empty")
TESTS = ("SourceBrowserFilterTests.swift", "SourceTreeVisibilityCacheTests.swift",
         "SourceEmptyFolderVisibilityTests.swift", "SourceVisibilityStorageTests.swift",
         "SourceVisibilityMatcherTests.swift")
PRODUCT = "VisibilityRegexBenchmark"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def append(path: Path, value) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def snapshot(read_source):
    spec = importlib.util.spec_from_file_location("source_tree_snapshot", HELPER)
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    files, records = support.snapshot(read_source)
    # The existing empty-folder tests use real directory loading and traversal.
    # Add those exact declarations without importing the SwiftUI shell.
    excerpts = (
        ("DirectoryValues.swift", "Sources/IlliquidApp/UI/SourcesSidebar.swift",
         "struct SourceDirectoryListing:", "\nenum SourceRecursiveMediaLoader {"),
        ("PresenceCursor.swift", "Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift",
         "final class SourceMediaPresenceCursor:", None),
    )
    for name, source, start, end in excerpts:
        raw = read_source(source)
        text = raw.decode()
        if text.count(start) != 1 or (end is not None and text.count(end) != 1):
            raise ValueError(f"Support extraction boundary changed: {source}")
        begin, finish = text.index(start), text.index(end) if end else len(text)
        if finish <= begin:
            raise ValueError(f"Reversed support extraction: {source}")
        selected = text[begin:finish].encode()
        staged = b"import Foundation\nimport IlliquidCore\n\n" + selected + b"\n"
        destination = "Sources/IlliquidApp/" + name
        files[destination] = staged
        records[destination] = {
            "repository_path": source, "source_sha256": sha(raw),
            "snapshot_sha256": sha(staged),
            "excerpts": [{"start": start, "end": end, "sha256": sha(selected)}],
        }
    return files, records, support.PACKAGE


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH")
        self.environment = os.environ.copy()
        self.environment.update(
            CLANG_MODULE_CACHE_PATH=str(self.output / "module-cache"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(self.output / "module-cache"),
            TERM="dumb", NO_COLOR="1",
        )
        self.packages, self.binaries, self.staged_hashes = {}, {}, {}
        self.rows, self.verification = [], []
        self.manifest = {
            "schema": 1, "complete": False, "baseline": BASELINE,
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(),
            "python": sys.version, "pairs": args.pairs, "sizes": args.sizes,
            "cases": args.cases, "target_ms": args.target_ms,
            "max_sample_ms": args.max_sample_ms, "tests_only": args.tests_only,
            "source_manifests": {}, "binary_hashes": {},
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "support_helper_sha256": sha(HELPER.read_bytes()),
            "build_coordination": "Kyoto" if KYOTO.is_file() else "isolated direct build; shared Kyoto unavailable",
            "measurement": {
                "included": "One awaited production SourceBrowserFilter.project(rows:) call per fresh actor",
                "excluded": ["fixture construction", "actor construction", "output receipts/checksums",
                             "compilation", "filesystem traversal", "UI presentation"],
                "order": "Fresh process per sample; equal-iteration AB/BA pairs",
                "calibration": "Separate fresh processes, retained and excluded from reported samples",
                "controls": ["default_empty", "regex_nonmatch", "regex_match"],
                "claim_boundary": "Native source-browser projection component, not application frame time",
            },
        }

    def command(self, argv, label, *, timeout=600, allowed=(0,)):
        argv = [str(value) for value in argv]
        begin = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=self.environment,
                                capture_output=True, text=True, timeout=timeout)
        append(self.output / "commands.jsonl", {
            "label": label, "argv": argv, "returncode": result.returncode,
            "seconds": time.monotonic() - begin,
            "stdout": result.stdout, "stderr": result.stderr,
        })
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n"
                               + (result.stdout + result.stderr)[-16000:])
        return result

    def compile(self, argv, label):
        if not KYOTO.is_file():
            print("Shared Kyoto unavailable on this host; compiling isolated " + label, flush=True)
            result = self.command(argv, label, timeout=900)
            output = result.stdout + result.stderr
        else:
            # Queue the exact command with its compiler/cache environment.
            keys = ("PATH", "DEVELOPER_DIR", "SDKROOT", "CLANG_MODULE_CACHE_PATH",
                    "SWIFTPM_MODULECACHE_OVERRIDE", "TERM", "NO_COLOR")
            environment = [f"{key}={self.environment[key]}" for key in keys if key in self.environment]
            submitted = self.command(
                [sys.executable, KYOTO, "submit", "--", "env", *environment, *argv],
                label + "-kyoto-submit")
            job = str(json.loads(submitted.stdout)["id"])
            self.command([sys.executable, KYOTO, "show", job], label + "-kyoto-show")
            waited = self.command([sys.executable, KYOTO, "wait", job],
                                  label + "-kyoto-wait", timeout=1800, allowed=tuple(range(256)))
            logs = self.command([sys.executable, KYOTO, "logs", job], label + "-kyoto-logs")
            self.command([sys.executable, KYOTO, "show", job], label + "-kyoto-completed")
            output = logs.stdout + logs.stderr
            if waited.returncode:
                raise RuntimeError(f"Kyoto build {job} failed:\n" + output[-16000:])
        (self.output / (label + ".log")).write_text(output)
        return output

    def prepare(self):
        self.manifest["head"] = self.command(["git", "rev-parse", "HEAD"], "head").stdout.strip()
        self.manifest["worktree"] = self.command(["git", "status", "--porcelain"], "worktree").stdout
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestry")
        self.manifest["swift"] = self.command([self.swift, "--version"], "swift").stdout.strip()
        self.manifest["macos"] = self.command(["sw_vers"], "macos").stdout.strip()
        self.manifest["cpu"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").stdout.strip()

        historical_cache = {}
        def historical(path):
            if path not in historical_cache:
                argv = ["git", "show", f"{BASELINE}:{path}"]
                result = subprocess.run(argv, cwd=ROOT, env=self.environment,
                                        capture_output=True, timeout=30)
                append(self.output / "commands.jsonl", {
                    "label": "historical-source", "argv": argv, "returncode": result.returncode,
                    "stdout_sha256": sha(result.stdout), "stderr": result.stderr.decode(errors="replace"),
                })
                result.check_returncode()
                historical_cache[path] = result.stdout
            return historical_cache[path]
        baseline, before_records, package = snapshot(historical)
        candidate, after_records, _ = snapshot(lambda path: (ROOT / path).read_bytes())
        if baseline.keys() != candidate.keys():
            raise ValueError("Production source inventories differ")
        changed = [path for path in baseline if baseline[path] != candidate[path]]
        if changed != [FOCAL]:
            raise ValueError(f"Expected only {FOCAL} to differ, got {changed}")
        package = package.replace("SourceTreeVisibilityQualification", "SourceVisibilityRegexPreparation")
        package = package.replace("SourceTreeBenchmark", PRODUCT)
        if "dependencies: [" in package.split("targets:")[0]:
            raise ValueError("Isolated package unexpectedly has external dependencies")
        harness = {
            "Package.swift": package.encode(),
            f"Sources/{PRODUCT}/Harness.swift": (HERE / "Harness.swift").read_bytes(),
        }
        harness.update({"Tests/IlliquidAppTests/" + name:
                        (ROOT / "Tests/IlliquidAppTests" / name).read_bytes() for name in TESTS})
        self.manifest["harness_hashes"] = {path: sha(data) for path, data in harness.items()}
        self.manifest["changed_staged_sources"] = changed
        for variant, files, records in (
            ("baseline", baseline, before_records), ("candidate", candidate, after_records)
        ):
            folder = self.output / "packages" / variant
            staging = {**files, **harness}
            hashes = {}
            for path, data in staging.items():
                destination = folder / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                hashes[path] = sha(data)
            self.packages[variant], self.staged_hashes[variant] = folder, hashes
            self.manifest["source_manifests"][variant] = {
                "production": records, "staged_sha256": hashes, "adaptations": [],
            }
        save(self.output / "manifest.json", self.manifest)

    def check_sources(self):
        if sha(Path(__file__).read_bytes()) != self.manifest["runner_sha256"]:
            raise ValueError("Runner changed during execution")
        if sha(HELPER.read_bytes()) != self.manifest["support_helper_sha256"]:
            raise ValueError("Snapshot helper changed during execution")
        for variant, hashes in self.staged_hashes.items():
            for path, digest in hashes.items():
                if sha((self.packages[variant] / path).read_bytes()) != digest:
                    raise ValueError(f"Staged source changed: {variant}/{path}")

    def swift_command(self, variant, action, configuration):
        return [self.swift, action, "--package-path", self.packages[variant],
                "--scratch-path", self.output / "build" / variant,
                "--cache-path", self.output / "swiftpm-cache",
                "--config-path", self.output / "swiftpm-config",
                "--security-path", self.output / "swiftpm-security",
                "--jobs", "2", "-c", configuration, "-Xswiftc", "-warnings-as-errors"]

    def test(self):
        results = []
        for variant in VARIANTS:
            for configuration in ("debug", "release"):
                self.check_sources()
                command = self.swift_command(variant, "test", configuration) + [
                    "--disable-xctest", "--enable-swift-testing", "--no-parallel"]
                log = self.compile(command, f"tests-{variant}-{configuration}")
                completed = re.search(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", log)
                if not completed or int(completed.group(1)) == 0:
                    raise ValueError("Swift Testing did not report completed tests")
                results.append({"variant": variant, "configuration": configuration,
                                "tests": int(completed.group(1)), "passed": True, "skips": []})
                save(self.output / "tests.json", {"suites": TESTS, "runs": results})
        self.check_sources()

    def build(self):
        for variant in VARIANTS:
            command = self.swift_command(variant, "build", "release")
            self.compile(command + ["--product", PRODUCT], f"build-{variant}")
            binary_path = self.command(command + ["--show-bin-path"], f"binary-path-{variant}").stdout.strip()
            self.binaries[variant] = Path(binary_path) / PRODUCT
            self.manifest["binary_hashes"][variant] = sha(self.binaries[variant].read_bytes())
        save(self.output / "manifest.json", self.manifest)
        self.check_sources()

    def invoke(self, variant, mode, case, size, iterations=None, label=None):
        argv = [self.binaries[variant], mode, case, str(size)]
        if iterations is not None:
            argv.append(str(iterations))
        data = json.loads(self.command(argv, label or f"{mode}-{variant}-{case}-{size}",
                                      timeout=120).stdout)
        if data["case"] != case or data["size"] != size:
            raise ValueError("Harness returned an unexpected workload")
        if iterations is not None:
            if data["iterations"] != iterations or data["wall_ns"] <= 0 or data["cpu_ns"] < 0:
                raise ValueError("Harness returned invalid timing accounting")
            for metric in ("wall", "cpu"):
                samples = data[metric + "_samples_ns"]
                if (len(samples) != iterations or any(type(value) is not int or value < 0 for value in samples)
                        or sum(samples) != data[metric + "_ns"]):
                    raise ValueError("Per-call timing samples do not match their total")
            if data["warmup_checksum"] != data["checksum"]:
                raise ValueError("Warmup projection differs from timed projection")
        return data

    def measure(self):
        for size in self.args.sizes:
            for case in self.args.cases:
                receipts = {}
                for variant in VARIANTS:
                    receipts[variant] = self.invoke(variant, "verify", case, size)
                    save(self.output / "receipts" / f"{variant}-{case}-{size}.json", receipts[variant])
                if receipts["baseline"] != receipts["candidate"]:
                    raise ValueError(f"Complete projection differs: {case}/{size}")
                reference = receipts["baseline"]
                semantic = ("checksum", "output_rows", "hidden_count", "media_paths", "thumbnails", "rule_counts")
                verification = {"case": case, "size": size, "equal": True,
                                "receipt_sha256": sha(json.dumps(reference, sort_keys=True).encode())}
                self.verification.append(verification)
                save(self.output / "verification.json", self.verification)
                calibration = {}
                for variant in VARIANTS:
                    probe = self.invoke(variant, "measure", case, size, 2)
                    if any(probe[key] != reference[key] for key in semantic):
                        raise ValueError(f"Calibration projection differs: {variant}/{case}/{size}")
                    append(self.output / "calibration.jsonl", {"variant": variant, **probe})
                    calibration[variant] = probe["wall_ns"] / 2
                iterations = max(2, min(
                    self.args.max_iterations,
                    math.ceil(self.args.target_ms * 1e6 / min(calibration.values())),
                    math.floor(self.args.max_sample_ms * 1e6 / max(calibration.values())),
                ))
                for pair in range(self.args.pairs):
                    order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                    pair_rows = []
                    for position, variant in enumerate(order):
                        data = self.invoke(variant, "measure", case, size, iterations,
                                           f"measure-{variant}-{case}-{size}-{pair}")
                        if any(data[key] != reference[key] for key in semantic):
                            raise ValueError(f"Timed projection differs: {variant}/{case}/{size}/{pair}")
                        data.update(variant=variant, pair=pair, process_order=position)
                        data["wall_ns_per_projection"] = data["wall_ns"] / iterations
                        data["cpu_ns_per_projection"] = data["cpu_ns"] / iterations
                        self.rows.append(data)
                        pair_rows.append(data)
                        append(self.output / "measurements.jsonl", data)
                    for field in ("case", "size", "iterations", "combined_checksum", "warmup_checksum", *semantic):
                        if pair_rows[0][field] != pair_rows[1][field]:
                            raise ValueError(f"Pair mismatch: {case}/{size}/{pair}/{field}")
                self.summarize()
                print(f"Completed {case}/{size}: {self.args.pairs} AB/BA pairs", flush=True)
        self.check_sources()
        for variant, binary in self.binaries.items():
            if sha(binary.read_bytes()) != self.manifest["binary_hashes"][variant]:
                raise ValueError(f"Binary changed: {variant}")

    def summarize(self):
        result = []
        for case, size in dict.fromkeys((row["case"], row["size"]) for row in self.rows):
            rows = [row for row in self.rows if row["case"] == case and row["size"] == size]
            summary = {"case": case, "size": size, "pairs": self.args.pairs}
            for metric in ("wall_ns_per_projection", "cpu_ns_per_projection"):
                metrics = {}
                for variant in VARIANTS:
                    values = [row[metric] for row in rows if row["variant"] == variant]
                    metrics[variant] = {"median": statistics.median(values),
                                        "min": min(values), "max": max(values)}
                reductions = []
                for pair in range(self.args.pairs):
                    values = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                    if values["baseline"] > 0:
                        reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
                metrics["paired_reduction_percent"] = {
                    "median": statistics.median(reductions) if reductions else None,
                    "min": min(reductions) if reductions else None,
                    "max": max(reductions) if reductions else None,
                    "candidate_faster_pairs": sum(value > 0 for value in reductions),
                }
                summary[metric] = metrics
            result.append(summary)
        save(self.output / "summary.json", result)

    def finish(self, success):
        self.manifest["complete"] = success
        self.manifest["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.manifest["measurement_rows"] = len(self.rows)
        self.manifest["verified_workloads"] = len(self.verification)
        save(self.output / "manifest.json", self.manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--sizes", type=int, nargs="+", default=[100, 1000, 10000])
    parser.add_argument("--case", dest="cases", choices=CASES, action="append")
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--max-sample-ms", type=float, default=1500)
    parser.add_argument("--max-iterations", type=int, default=10000)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    args.cases = args.cases or list(CASES)
    if platform.system() != "Darwin":
        parser.error("This experiment requires native macOS; no source adaptations are applied")
    if args.pairs < 10 or args.pairs % 2:
        parser.error("Use an even pair count of at least ten")
    if (args.target_ms <= 0 or args.max_sample_ms < args.target_ms or args.max_iterations < 2
            or not args.sizes or any(size < 1 for size in args.sizes)
            or len(set(args.sizes)) != len(args.sizes) or len(set(args.cases)) != len(args.cases)):
        parser.error("Use unique positive workloads and valid timing bounds")
    study = Study(args)
    success = False
    try:
        study.prepare()
        study.test()
        if not args.tests_only:
            study.build()
            study.measure()
        success = True
    except Exception as error:
        save(study.output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        study.finish(success)


if __name__ == "__main__":
    main()
