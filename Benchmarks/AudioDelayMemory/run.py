#!/usr/bin/env python3
"""Qualify production audio-delay ownership and compare identical PCM timelines.

macOS uses CoreMedia. Linux replaces only that framework boundary; Foundation,
Data ownership, the extracted frame type/trimming, and timeline code are real.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

from cases import make_cases, measurement_cases

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TIMELINE = "Sources/IlliquidNativePlayback/Media/AudioDelayTimeline.swift"
DECODER = "Sources/IlliquidNativePlayback/Media/AudioDecoder.swift"
MEMORY_TEST = "Tests/IlliquidNativePlaybackTests/AudioDelayMemoryTests.swift"
EXISTING_TEST = "Tests/IlliquidNativePlaybackTests/AudioDelayTests.swift"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def extract(text, start, end):
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError(f"Production extraction boundaries changed: {start!r}, {end!r}")
    begin = text.index(start)
    finish = text.index(end, begin)
    return text[begin:finish]


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.build = self.output / "build"
        self.build.mkdir(parents=True)
        self.native = platform.system() == "Darwin"
        self.swiftc = shutil.which(args.swiftc)
        if not self.swiftc:
            raise RuntimeError("Swift compiler unavailable; set --swiftc or PATH")
        self.swift = str(Path(self.swiftc).with_name("swift"))
        self.environment = os.environ.copy()
        for key in ("SWIFT_MODULECACHE_PATH", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.environment[key] = str(self.build / "module-cache")
        self.commands = []
        self.binaries = {}
        self.manifest = {
            "platform": platform.platform(), "machine": platform.machine(),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "framework_boundary": "native CoreMedia" if self.native else "finite rational CMTime test shim",
            "measurement_scope": "timeline service time and live immutable PCM payload addresses; not player RSS",
            "arguments": {**vars(args), "output": str(self.output)},
        }

    def run(self, command, *, log=None, expect_failure=False):
        started = time.monotonic()
        process = subprocess.run([str(x) for x in command], cwd=ROOT, env=self.environment,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        record = {"argv": [str(x) for x in command], "returncode": process.returncode,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout_sha256": sha(process.stdout), "stderr_sha256": sha(process.stderr)}
        self.commands.append(record)
        save(self.output / "commands.json", self.commands)
        if log:
            (self.output / log).write_bytes(process.stdout + process.stderr)
        if (process.returncode != 0) != expect_failure:
            raise RuntimeError(f"Unexpected command status: {command!r}\n"
                               + process.stdout.decode(errors="replace")[-12000:]
                               + process.stderr.decode(errors="replace")[-12000:])
        if expect_failure and b"Test run with" not in process.stdout + process.stderr:
            raise RuntimeError("Negative control did not reach test execution")
        return process.stdout

    def source_for_platform(self, text):
        if not self.native:
            text = text.replace("import CoreMedia\n", "")
        return text

    def prepare(self):
        baseline = (HERE / "baseline/AudioDelayTimeline.swift").read_bytes()
        pin = json.loads((HERE / "baseline/manifest.json").read_text())
        if sha(baseline) != pin["sha256"]:
            raise RuntimeError("Frozen baseline source hash mismatch")
        blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
        if blob != pin["git_blob"]:
            raise RuntimeError("Frozen baseline Git blob mismatch")
        candidate = (ROOT / TIMELINE).read_bytes()
        frame = extract((ROOT / DECODER).read_text(), "struct NativeDecodedAudioFrame: Sendable {",
                        "/// Maps decoded source timestamps onto the sample clock")
        if sha(frame.encode()) != pin["frame_excerpt_sha256"]:
            raise RuntimeError("Shared production audio-frame definition changed; update baseline methodology")
        self.frame = self.source_for_platform("import CoreMedia\nimport Foundation\n\n" + frame)
        self.sources = {"baseline": baseline, "candidate": candidate}
        self.manifest.update({
            "baseline": pin,
            "compiler": self.run([self.swiftc, "--version"]).decode().strip(),
            "checkout_head": self.run(["git", "rev-parse", "HEAD"]).decode().strip(),
            "source_sha256": {TIMELINE: sha(candidate), DECODER: sha((ROOT / DECODER).read_bytes()),
                              MEMORY_TEST: sha((ROOT / MEMORY_TEST).read_bytes()),
                              EXISTING_TEST: sha((ROOT / EXISTING_TEST).read_bytes())},
            "harness_sha256": {name: sha((HERE / name).read_bytes()) for name in
                               ("Harness.swift", "Platform.swift", "cases.py", "run.py")},
        })
        if hasattr(os, "sched_getaffinity"):
            self.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        (self.build / "AudioFrame.swift").write_text(self.frame)
        for variant, data in self.sources.items():
            (self.build / f"{variant}.swift").write_text(self.source_for_platform(data.decode()))
        self.cases = make_cases() + measurement_cases()
        self.measurements = measurement_cases()
        save(self.output / "cases.json", self.cases)
        save(self.output / "measurement-cases.json", self.measurements)
        self.manifest["cases_sha256"] = sha((self.output / "cases.json").read_bytes())
        save(self.output / "manifest.json", self.manifest)

    def compile(self, configuration):
        for variant in self.sources:
            binary = self.build / f"{variant}-{configuration}"
            flags = ["-O", "-whole-module-optimization"] if configuration == "release" else ["-Onone"]
            self.run([self.swiftc, *flags, "-swift-version", "6", "-warnings-as-errors",
                      "-module-cache-path", self.build / "module-cache",
                      self.build / f"{variant}.swift", self.build / "AudioFrame.swift",
                      HERE / "Platform.swift", HERE / "Harness.swift", "-o", binary],
                     log=f"build-{variant}-{configuration}.log")
            self.binaries[variant, configuration] = binary
        self.manifest["binary_sha256"] = {f"{variant}-{config}": sha(path.read_bytes())
                                         for (variant, config), path in self.binaries.items()}
        save(self.output / "manifest.json", self.manifest)

    def differential(self, configuration):
        records = {}
        transcripts = {}
        for variant in self.sources:
            path = self.build / f"trace-{variant}-{configuration}.bin"
            records[variant] = json.loads(self.run([
                self.binaries[variant, configuration], "trace", self.output / "cases.json", path]))
            transcripts[variant] = path.read_bytes()
        if records["baseline"] != records["candidate"] or transcripts["baseline"] != transcripts["candidate"]:
            raise RuntimeError(f"{configuration} differential mismatch; raw transcripts retained in build/")
        receipt = {"configuration": configuration, "exact_bytes_equal": True,
                   **records["candidate"], "transcript_bytes": len(transcripts["candidate"]),
                   "transcript_sha256": sha(transcripts["candidate"])}
        save(self.output / f"differential-{configuration}.json", receipt)
        return receipt

    def ownership(self, configuration):
        rows = []
        lifetimes = []
        for channels in (2, 6, 8):
            for count in (48, 469):
                values = {variant: json.loads(self.run([self.binaries[variant, configuration],
                          "residency", channels, count])) for variant in self.sources}
                left, right = values["baseline"], values["candidate"]
                if left["logical_pcm_bytes"] != right["logical_pcm_bytes"]:
                    raise RuntimeError("PCM queue contents differ")
                if left["distinct_payload_addresses"] != count:
                    raise RuntimeError("Baseline ownership mechanism was not reproduced")
                if right["distinct_payload_addresses"] != (1 if count == 48 else 2):
                    raise RuntimeError("Expected immutable full-chunk sharing was not observed")
                rows.append(values)
        for delay in (0, -10):
            values = {variant: json.loads(self.run([self.binaries[variant, configuration],
                      "lifetime", delay])) for variant in self.sources}
            if values["baseline"]["source_releases_while_timeline_alive"] != 0:
                raise RuntimeError("Baseline template retention was not reproduced")
            if values["candidate"]["source_releases_while_timeline_alive"] != 1:
                raise RuntimeError("Candidate timeline retained input PCM")
            lifetimes.append(values)
        save(self.output / f"ownership-{configuration}.json", {"queue_and_stress": rows, "template": lifetimes})

    def tests(self, variant, configuration, negative=False):
        package = self.build / f"tests-{variant}"
        production = package / "Sources/IlliquidNativePlayback"
        tests = package / "Tests/IlliquidNativePlaybackTests"
        production.mkdir(parents=True, exist_ok=True)
        tests.mkdir(parents=True, exist_ok=True)
        (production / "AudioDelayTimeline.swift").write_text(self.source_for_platform(self.sources[variant].decode()))
        (production / "AudioFrame.swift").write_text(self.frame)
        shutil.copyfile(HERE / "Platform.swift", production / "Platform.swift")
        existing = (ROOT / EXISTING_TEST).read_text()
        boundary = "    @Test @MainActor func extremeOffsetsPrepareSeekAndReleaseWithoutVideoBackpressure"
        if existing.count(boundary) != 1:
            raise RuntimeError("Existing pure audio-delay test boundary changed")
        existing = existing[:existing.index(boundary)] + "}\n"
        existing = existing.replace("import IlliquidCore\n", "").replace("import IlliquidPlayback\n", "")
        (tests / "AudioDelayTests.swift").write_text(self.source_for_platform(existing))
        (tests / "AudioDelayMemoryTests.swift").write_text(self.source_for_platform((ROOT / MEMORY_TEST).read_text()))
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "AudioDelayOwnershipQualification", targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
        command = [self.swift, "test"]
        if not self.native:
            command += ["--use-integrated-swift-driver"]
        command += ["--package-path", str(package), "--scratch-path", str(package / ".build"),
                    "--cache-path", str(self.build / "swiftpm-cache"),
                    "--config-path", str(self.build / "swiftpm-config"),
                    "--security-path", str(self.build / "swiftpm-security"),
                    "--jobs", "2", "-c", configuration, "-Xswiftc", "-warnings-as-errors"]
        if negative:
            command += ["--filter", "completedInputStorageIsReleasedWhileTailFormatRemainsAvailable|retainedFullSilenceChunksShareStorageAndTailHasExactSize"]
        elif variant == "baseline":
            command += ["--filter", "AudioDelayTests"]
        log = f"tests-{variant}-{configuration}{'-negative-control' if negative else ''}.log"
        self.run(command, log=log, expect_failure=negative)
        return {"variant": variant, "configuration": configuration, "negative_control": negative,
                "expected_status_observed": True, "log": log, "log_sha256": sha((self.output / log).read_bytes())}

    def benchmark(self):
        calibration = []
        observations = []
        summaries = []
        for index, scenario in enumerate(self.measurements):
            initial = json.loads(self.run([self.binaries["baseline", "release"], "measure",
                                         self.output / "measurement-cases.json", index, 200]))
            iterations = min(500_000, max(10, int(self.args.target_ms * 1e6 / initial["ns_per_iteration"])))
            calibration.append({"case": scenario["name"], "iterations": iterations, "probe": initial})
            paired = []
            for pair in range(self.args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                values = {}
                for ordinal, variant in enumerate(order):
                    value = json.loads(self.run([self.binaries[variant, "release"], "measure",
                                                self.output / "measurement-cases.json", index, iterations]))
                    value.update({"variant": variant, "pair": pair, "ordinal": ordinal})
                    observations.append(value)
                    values[variant] = value
                if values["baseline"]["checksum"] != values["candidate"]["checksum"]:
                    raise RuntimeError("Measured output checksum differs")
                paired.append(1 - values["candidate"]["ns_per_iteration"] / values["baseline"]["ns_per_iteration"])
            summary = {"case": scenario["name"], "pairs": self.args.pairs,
                       "median_paired_time_reduction_percent": 100 * statistics.median(paired),
                       "min_paired_time_reduction_percent": 100 * min(paired),
                       "max_paired_time_reduction_percent": 100 * max(paired)}
            for variant in self.sources:
                summary[variant + "_median_ns"] = statistics.median(
                    row["ns_per_iteration"] for row in observations
                    if row["case"] == scenario["name"] and row["variant"] == variant)
            summaries.append(summary)
        save(self.output / "calibration.json", calibration)
        save(self.output / "observations.json", observations)
        save(self.output / "summary.json", summaries)
        return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=80)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("Use a positive target and an even number of pairs >= 2 for balanced AB/BA order")
    runner = Runner(args)
    runner.prepare()
    tests = []
    differentials = []
    for configuration in ("debug", "release"):
        print(f"Building and qualifying {configuration}", flush=True)
        runner.compile(configuration)
        differentials.append(runner.differential(configuration))
        runner.ownership(configuration)
        for variant in ("baseline", "candidate"):
            tests.append(runner.tests(variant, configuration))
    tests.append(runner.tests("baseline", "release", negative=True))
    save(runner.output / "tests.json", tests)
    print("Measuring balanced fresh-process comparisons", flush=True)
    summaries = runner.benchmark()
    save(runner.output / "completion.json", {"completed": True, "differential": differentials,
                                           "tests": tests, "measurement_cases": len(summaries)})
    print(json.dumps(summaries, indent=2), flush=True)


if __name__ == "__main__":
    main()
