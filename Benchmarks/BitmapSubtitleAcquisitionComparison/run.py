#!/usr/bin/env python3
"""Compare three frozen subtitle acquisition strategies on real Linux Swift/FFmpeg.

Research only: no application source or test graph is modified. Every production
body comes from recorded snapshots, verified against its Git object when present.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
from pathlib import Path
import platform
import re
import shlex
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VARIANTS = ("copying", "raw_buffer", "data_nocopy")
REVISIONS = {
    "copying": "ea2ff568237e2667f7b1aeee67b11a44ebe95b72",
    "raw_buffer": "aa71f1df6045ef35301fb0a95518b571f02f23b7",
    "data_nocopy": "6275059f54fc9ec52873fb7d223ad6f598fd0c47",
}
CASES = ["pgs_tiny", "dvb_tiny", "pgs_mixed_4k", "dvb_mixed_4k",
         "pgs_mixed_64k", "dvb_mixed_64k", "pgs_mixed_256k", "dvb_mixed_256k"]
ORDERS = list(itertools.permutations(VARIANTS))
COMPARISONS = (("raw_buffer", "copying"), ("data_nocopy", "copying"), ("raw_buffer", "data_nocopy"))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n")


def between(data, start, end):
    if data.count(start) != 1 or data.count(end) != 1:
        raise ValueError(f"Extraction boundary is not unique: {start!r}, {end!r}")
    return data[data.index(start):data.index(end, data.index(start))]


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty; receipts are never overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands, self.inputs, self.source_paths = [], {}, {}
        self.swiftc = shutil.which(args.swiftc) or args.swiftc
        self.manifest = json.loads((HERE / "frozen/manifest.json").read_text())
        if self.manifest["variants"] != REVISIONS:
            raise ValueError("Frozen source revisions changed; review the study")
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "machine": platform.machine(),
            "variant_revisions": REVISIONS,
            "scope": "Linux acquisition-classification component; not macOS or whole-player qualification",
            "omissions": [
                "Unused CoreGraphics import in classifier prefixes",
                "Unused CoreMedia import and MediaTime.cmTime/timestamp; exact FFmpegRational and seconds retained",
                "Unrelated C shim declarations; exact required production error/packet helpers retained",
                "Only the exact selected static method and original enclosing type declaration from the no-copy demuxer",
            ],
            "input_manifest_sha256": sha((HERE / "frozen/manifest.json").read_bytes()),
            "driver_sha256": sha((HERE / "Driver.swift").read_bytes()),
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "inputs": {}, "compiled_sources": {}, "extractions": {}, "binaries": {},
            "protocol": {"triplets": args.triplets, "orders": ORDERS,
                         "target_ms": args.target_ms, "minimum_ms": args.minimum_ms},
        }
        shutil.copyfile(__file__, self.output / "runner.snapshot.py")
        shutil.copyfile(HERE / "frozen/manifest.json", self.output / "input-manifest.json")

    def command(self, argv, *, log=None):
        argv = [str(value) for value in argv]
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=900)
        self.commands.append({
            "argv": argv, "returncode": result.returncode,
            "elapsed_seconds": time.monotonic() - start,
            "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
        })
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {argv}\n"
                               f"{result.stdout[-3000:].decode(errors='replace')}\n"
                               f"{result.stderr[-8000:].decode(errors='replace')}")
        return result.stdout.decode()

    def load_inputs(self):
        git_cache = {}
        for key, record in self.manifest["inputs"].items():
            path = (HERE / record["snapshot"]).resolve()
            if not path.is_relative_to((HERE / "frozen").resolve()):
                raise ValueError("Input snapshot escapes the frozen directory")
            data = path.read_bytes()
            if sha(data) != record["sha256"] or len(data) != record["bytes"]:
                raise ValueError(f"Frozen bytes changed: {key}")
            identity = record["revision"], record["path"]
            if identity not in git_cache:
                probe = subprocess.run(["git", "cat-file", "-e", ":".join(identity)], cwd=ROOT,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                git_cache[identity] = (self.command(["git", "show", ":".join(identity)]).encode()
                                       if probe.returncode == 0 else None)
            original = git_cache[identity]
            if original is not None:
                if (sha(original) != record["source_sha256"] or len(original) != record["source_bytes"]
                        or original[record["start_byte"]:record["end_byte_exclusive"]] != data):
                    raise ValueError(f"Snapshot does not match its pinned Git source: {key}")
            self.inputs[key] = data
            self.receipt["inputs"][key] = {**record, "verified_against_git": original is not None}
        for path in self.manifest["shared_paths"]:
            name = Path(path).name
            if len({self.inputs[f"shared/{variant}/{name}"] for variant in VARIANTS}) != 1:
                raise ValueError(f"Shared production dependency differs: {name}")
        driver = (HERE / "Driver.swift").read_bytes()
        marker = self.manifest["corpus"]["boundary"].encode()
        if driver.count(marker) != 1:
            raise ValueError("Common corpus boundary changed")
        corpus = driver[driver.index(marker):].rstrip(b"\n") + b"\n"
        if sha(corpus) != self.manifest["corpus"]["suffix_sha256"]:
            raise ValueError("Corpus/timing statements differ from the frozen common driver")
        if b"packet.data.map" not in self.inputs["copying/call-site"]:
            raise ValueError("Copying call site differs from the adapter")
        if b"PGSSubtitlePacket.isAcquisition(packet)" not in self.inputs["raw_buffer/call-site"]:
            raise ValueError("Raw-buffer call site differs from the adapter")
        if b"Self.isSubtitleAcquisition(" not in self.inputs["data_nocopy/call-site"]:
            raise ValueError("No-copy call site differs from the adapter")

    def selected(self, name, original, compiled):
        self.receipt["extractions"][name] = {
            "original_sha256": sha(original), "compiled_sha256": sha(compiled),
            "compiled_bytes": len(compiled),
        }
        return compiled

    def prepare(self):
        self.load_inputs()
        source_root = self.output / "sources"
        module = source_root / "CFFmpeg"
        module.mkdir(parents=True)
        shim = self.inputs["shared/copying/ffmpeg_shim.h"]
        errors = between(shim, b"static inline int illiquid_averror_eagain(",
                         b"// A container keyframe flag alone")
        nopts = between(shim, b"static inline int64_t illiquid_nopts_value(",
                        b"static inline unsigned int illiquid_chapter_count(")
        self.selected("C/error-and-flag-helpers", shim, errors)
        self.selected("C/nopts-helper", shim, nopts)
        (module / "helpers.h").write_bytes(
            b"#pragma once\n#include <errno.h>\n#include <libavcodec/packet.h>\n"
            b"#include <libavutil/avutil.h>\n#include <libavutil/buffer.h>\n"
            b"#include <libavutil/error.h>\n\n" + errors + nopts)
        (module / "module.modulemap").write_text(
            'module CFFmpeg [system] {\n header "helpers.h"\n link "avcodec"\n link "avutil"\n export *\n}\n')
        shared = source_root / "shared"
        shared.mkdir()
        common = []
        for path in self.manifest["shared_paths"]:
            if not path.endswith(".swift"):
                continue
            name = Path(path).name
            data = self.inputs[f"shared/copying/{name}"]
            if name == "MediaTime.swift":
                rational = between(data, b"struct FFmpegRational:", b"\nenum MediaTime {")
                start = data.index(b"    static func seconds(")
                end = data.index(b"\n    }\n", start) + len(b"\n    }\n")
                seconds = data[start:end]
                self.selected("Swift/FFmpegRational", data, rational)
                self.selected("Swift/MediaTime.seconds", data, seconds)
                data = b"import CFFmpeg\nimport Foundation\n\n" + rational + b"\nenum MediaTime {\n" + seconds + b"}\n"
            destination = shared / name
            destination.write_bytes(data)
            common.append(destination)
        self.driver = source_root / "Driver.swift"
        shutil.copyfile(HERE / "Driver.swift", self.driver)
        for variant in VARIANTS:
            directory = source_root / variant
            directory.mkdir()
            data = self.inputs[f"{variant}/classifiers"]
            if data.count(b"import CoreGraphics\n") != 1:
                raise ValueError(f"Unexpected classifier imports: {variant}")
            parser = directory / "BitmapSubtitleClassifiers.swift"
            parser.write_bytes(self.selected(f"{variant}/classifiers", data,
                                             data.replace(b"import CoreGraphics\n", b"")))
            self.source_paths[variant] = [*common, parser]
            if variant == "raw_buffer":
                adapter = directory / "SubtitleAcquisitionPacket.swift"
                adapter.write_bytes(self.inputs["raw_buffer/adapter"])
                self.source_paths[variant].append(adapter)
            if variant == "data_nocopy":
                # Only a namespace is assembled around the exact production
                # static helper; no platform API or ownership behavior is stubbed.
                adapter = directory / "FFmpegDemuxer.swift"
                assembled = (self.inputs["data_nocopy/imports"] + b"\n"
                             + self.inputs["data_nocopy/type"] + self.inputs["data_nocopy/helper"] + b"}\n")
                adapter.write_bytes(assembled)
                self.receipt["extractions"]["data_nocopy/namespace-assembly"] = {
                    "input_keys": ["data_nocopy/imports", "data_nocopy/type", "data_nocopy/helper"],
                    "compiled_sha256": sha(assembled), "added_syntax": "separating newline and enclosing closing brace",
                }
                self.source_paths[variant].append(adapter)
        for path in source_root.rglob("*"):
            if path.is_file():
                self.receipt["compiled_sources"][str(path.relative_to(self.output))] = sha(path.read_bytes())
        write_json(self.output / "source-preparation.json", {
            "verified_snapshots": len(self.inputs),
            "git_verified_snapshots": sum(row["verified_against_git"] for row in self.receipt["inputs"].values()),
            "source_preparation_only": self.args.prepare_only,
        })
        if self.args.prepare_only:
            return
        if platform.system() != "Linux":
            raise ValueError("Execution is Linux-only; macOS qualification requires its native harness")
        self.receipt["compiler"] = self.command([self.swiftc, "--version"]).strip()
        match = re.search(r"Swift version (\d+)\.(\d+)", self.receipt["compiler"])
        if not match or tuple(map(int, match.groups())) < (6, 3):
            raise ValueError("Swift 6.3+ is required for the unchanged PR128 weak-let regression test")
        self.receipt["compiler_binary_sha256"] = sha(Path(self.swiftc).read_bytes())
        self.receipt["ffmpeg_packages"] = self.command(["dpkg-query", "-W", "libavcodec-dev", "libavutil-dev"])
        self.receipt["ffmpeg_versions"] = self.command(["pkg-config", "--modversion", "libavcodec", "libavutil"])
        self.receipt["hardware"] = next((line.strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                                         if line.startswith("model name")), "not reported")
        cflags = shlex.split(self.command(["pkg-config", "--cflags", "libavcodec", "libavutil"]))
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                 "-I", str(module), "-module-cache-path", str(self.output / "module-cache")]
        for flag in cflags:
            flags.extend(["-Xcc", flag])
        self.receipt["flags"] = flags
        for variant in VARIANTS:
            directory = self.output / variant
            directory.mkdir()
            binary = directory / "benchmark"
            define = [] if variant == "copying" else ["-D", variant.upper()]
            print(f"Compiling {variant} from frozen production declarations", flush=True)
            self.command([self.swiftc, *flags, *define, *self.source_paths[variant], self.driver, "-o", binary],
                         log=directory / "compile.log")
            self.receipt["binaries"][variant] = sha(binary.read_bytes())
        linkage = self.command(["ldd", self.output / "raw_buffer/benchmark"])
        self.receipt["linked_dependencies"] = linkage
        self.receipt["ffmpeg_library_sha256"] = {
            match.group(1): sha(Path(match.group(1)).read_bytes())
            for match in re.finditer(r"libav(?:codec|util)\S*\s+=>\s+(/\S+)", linkage)
        }

    def invoke(self, variant, *args):
        return json.loads(self.command([self.output / variant / "benchmark", *args]))

    def verify(self):
        traces = {}
        for variant in VARIANTS:
            trace = self.invoke(variant, "verify")
            write_json(self.output / f"{variant}-trace.json", trace)
            traces[variant] = trace
        if any(traces[v] != traces["copying"] for v in VARIANTS[1:]):
            raise ValueError("Complete three-arm output parity failed; inspect retained traces")
        rows = traces["copying"]["rows"]
        summary = {"equal": True, "variants": list(VARIANTS), "compared_cases": len(rows),
                   "authored_expectations": sum(row["authoredExpectation"] for row in rows),
                   "acquisition_true": sum(row["result"] for row in rows),
                   "acquisition_false": sum(not row["result"] for row in rows),
                   "ffmpeg_version": traces["copying"]["ffmpegVersion"]}
        if summary["compared_cases"] != 605 or summary["authored_expectations"] != 221:
            raise ValueError("The expected common corpus inventory changed")
        write_json(self.output / "parity.json", summary)
        print("All three variants agree across 605 cases (221 authored expectations)", flush=True)

    def test(self):
        results = {}
        for variant in ("raw_buffer", "data_nocopy"):
            package = self.output / "tests" / variant
            target = package / "Sources/IlliquidNativePlayback"
            target.mkdir(parents=True)
            shutil.copytree(self.output / "sources/CFFmpeg", package / "Sources/CFFmpeg")
            for path in self.source_paths[variant]:
                shutil.copyfile(path, target / path.name)
            tests = package / "Tests/IlliquidNativePlaybackTests"
            tests.mkdir(parents=True)
            record = self.manifest["inputs"][f"{variant}/tests"]
            (tests / Path(record["path"]).name).write_bytes(self.inputs[f"{variant}/tests"])
            (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "AcquisitionComparison", targets: [
    .systemLibrary(name: "CFFmpeg", pkgConfig: "libavcodec"),
    .target(name: "IlliquidNativePlayback", dependencies: ["CFFmpeg"]),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback", "CFFmpeg"]),
])
''')
            log = self.output / f"{variant}-tests.log"
            print(f"Running unchanged {variant} PR regression tests in an isolated release package", flush=True)
            self.command([str(Path(self.swiftc).with_name("swift")), "test", "--package-path", package,
                          "-c", "release", "--jobs", "2", "--no-parallel"], log=log)
            clean_log = re.sub(r"\x1b\[[0-9;]*m", "", log.read_text())
            expected = self.manifest["test_counts"][variant]
            match = re.search(r"Test run with (\d+) tests[^\n]*passed", clean_log)
            if not match or int(match.group(1)) != expected:
                raise ValueError(f"Swift Testing did not report all {expected} production tests passing for {variant}")
            results[variant] = {"passed": True, "tests": expected, "source_revision": record["revision"],
                                "source_path": record["path"], "source_sha256": record["sha256"],
                                "log_sha256": sha(log.read_bytes()), "configuration": "release"}
            write_json(self.output / "test-results.json", results)

    def calibrate(self, variant, case):
        iterations, pilots = 4_096, []
        for _ in range(6):
            result = self.invoke(variant, "measure", case, str(iterations))
            pilots.append(result)
            measured = min(result["elapsedNanoseconds"], result["cpuNanoseconds"])
            if measured >= self.args.target_ms * 1_000_000:
                return {"iterations": iterations, "pilots": pilots}
            requested = math.ceil(iterations * self.args.target_ms * 1_000_000 * 1.25 / max(1, measured))
            iterations = max(iterations + 16, math.ceil(requested / 16) * 16)
            if iterations > 100_000_000:
                raise ValueError("Calibration exceeds 100 million calls; inspect timer/optimizer")
        raise ValueError(f"Calibration failed for {variant}/{case}")

    def measure(self):
        calibration, summaries = {}, []
        duration_failed = False
        for case in CASES:
            calibration[case] = {v: self.calibrate(v, case) for v in VARIANTS}
            write_json(self.output / "calibration.json", calibration)
            triplets = []
            for index in range(self.args.triplets):
                order, values = ORDERS[index % len(ORDERS)], {}
                for position, variant in enumerate(order):
                    iterations = calibration[case][variant]["iterations"]
                    record = self.invoke(variant, "measure", case, str(iterations))
                    if record["iterations"] != iterations or record["workload"] != case:
                        raise ValueError("Timed process returned different workload/iterations")
                    if record["checksum"] != (record["cycleChecksum"] * (iterations // 16)) % (1 << 64):
                        raise ValueError("Timed checksum does not consume the expected complete cycles")
                    record.update({"variant": variant, "triplet": index, "order": list(order), "position": position})
                    values[variant] = record
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                for field in ("cycleChecksum", "warmupChecksum", "warmupIterations", "first", "last", "payloadBytes"):
                    if any(values[v][field] != values["copying"][field] for v in VARIANTS[1:]):
                        raise ValueError(f"Timed output mismatch in {case}/{index}: {field}")
                triplets.append(values)
            summary = {"workload": case, "triplets": self.args.triplets,
                       "payload_bytes": triplets[0]["copying"]["payloadBytes"],
                       "minimum_required_ms": self.args.minimum_ms,
                       "variants": {}, "comparisons": {}, "observations_under_minimum": []}
            for variant in VARIANTS:
                summary["variants"][variant] = {"iterations": calibration[case][variant]["iterations"]}
            for metric, field in (("wall", "elapsedNanoseconds"), ("cpu", "cpuNanoseconds")):
                per_call = {v: [t[v][field] / t[v]["iterations"] for t in triplets] for v in VARIANTS}
                for variant in VARIANTS:
                    summary["variants"][variant][metric] = {
                        "median_ns_per_check": statistics.median(per_call[variant]),
                        "range_ns_per_check": [min(per_call[variant]), max(per_call[variant])],
                        "minimum_observed_ms": min(t[variant][field] for t in triplets) / 1_000_000,
                    }
                for numerator, denominator in COMPARISONS:
                    ratios = [t[numerator][field] / t[numerator]["iterations"]
                              / (t[denominator][field] / t[denominator]["iterations"]) for t in triplets]
                    comparison = summary["comparisons"].setdefault(f"{numerator}_vs_{denominator}", {})
                    comparison[metric] = {
                        "paired_ratios": ratios, "median_paired_ratio": statistics.median(ratios),
                        "reduction_percent": (1 - statistics.median(ratios)) * 100,
                        "range_paired_ratio": [min(ratios), max(ratios)],
                    }
                summary["observations_under_minimum"].extend(
                    {"variant": v, "triplet": index, "metric": metric, "observed_ms": t[v][field] / 1_000_000}
                    for index, t in enumerate(triplets) for v in VARIANTS
                    if t[v][field] < self.args.minimum_ms * 1_000_000)
            duration_failed |= bool(summary["observations_under_minimum"])
            summaries.append(summary)
            write_json(self.output / "summary.json", summaries)
            values = ", ".join(f"{v}={summary['variants'][v]['cpu']['median_ns_per_check']:.1f}" for v in VARIANTS)
            print(f"{case}: CPU ns/check {values}", flush=True)
        if duration_failed:
            raise ValueError("At least one observation was too short; retain this cohort and increase --target-ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--triplets", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=240)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--prepare-only", action="store_true", help="Verify and assemble sources without claiming execution")
    args = parser.parse_args()
    if args.triplets < 6 or args.triplets % 6:
        parser.error("Triplets must be a positive multiple of six to balance every order")
    if args.minimum_ms < 60 or args.target_ms < args.minimum_ms:
        parser.error("Target must be at least the minimum, and the minimum at least 60 ms")
    runner = Runner(args)
    try:
        runner.prepare()
        if not args.prepare_only:
            runner.verify()
            runner.test()
            runner.measure()
        write_json(runner.output / "completion.json", {
            "complete": not args.prepare_only, "source_preparation_only": args.prepare_only,
            "linux_component_only": True, "native_macos_qualified": False,
            "variants": list(VARIANTS), "triplets": args.triplets,
            "minimum_observation_duration_met": not args.prepare_only,
        })
    finally:
        write_json(runner.output / "commands.json", runner.commands)
        write_json(runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()

