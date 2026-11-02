#!/usr/bin/env python3
"""Compare copied and borrowed bitmap-subtitle acquisition checks.

The generated component contains exact production declarations and real FFmpeg
packet ownership. It excludes unrelated CoreMedia/CoreGraphics declarations and
VideoToolbox C helpers, so the same experiment can run on Linux and macOS. This
is not a complete native application or demuxer build.
"""
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
import time
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PARSER = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
ADAPTER = "Sources/IlliquidNativePlayback/Subtitles/SubtitleAcquisitionPacket.swift"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
PACKET = "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift"
TIME = "Sources/IlliquidNativePlayback/Media/MediaTime.swift"
ERROR = "Sources/IlliquidNativePlayback/Media/FFmpegError.swift"
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
SHARED = (PACKET, TIME, ERROR, SHIM)
VARIANTS = ("baseline", "candidate")
CONFIGURATIONS = ("debug", "release")
CASES = (
    "pgs_tiny", "pgs_object_4k", "pgs_object_64k", "pgs_acquisition_256k",
    "dvb_tiny", "dvb_object_4k", "dvb_object_64k", "dvb_acquisition_256k",
)
C_HELPERS = (
    "illiquid_averror_eagain", "illiquid_averror_nomem",
    "illiquid_averror_invaliddata", "illiquid_averror_exit",
    "illiquid_packet_is_corrupt", "illiquid_packet_is_keyframe",
    "illiquid_nopts_value",
)
ALLOCATION_METER = ROOT / "Benchmarks/NonDecodePerformance/allocmeter.c"
UINT64_MASK = (1 << 64) - 1


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def exact_between(text: str, start: str, end: str) -> str:
    """Fail closed if a known complete-declaration boundary is ambiguous."""
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError(f"Source boundary is not unique: {start!r} / {end!r}")
    first, last = text.index(start), text.index(end)
    if first >= last:
        raise ValueError(f"Source boundaries are out of order: {start!r}")
    return text[first:last]


def c_helper(text: str, name: str) -> str:
    # Each selected helper is a complete one-level function with no nested
    # scopes. Keep its actual source bytes, including its signature and body.
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines)
              if line.startswith("static inline ") and f" {name}(" in line]
    if len(starts) != 1:
        raise ValueError(f"C helper boundary is not unique: {name}")
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == "}\n"), None)
    if end is None:
        raise ValueError(f"C helper has no closing boundary: {name}")
    value = "".join(lines[start:end + 1])
    if value.count("{") != 1 or value.count("}") != 1:
        raise ValueError(f"C helper shape changed: {name}")
    return value


def components(sources: dict[str, str]) -> dict[str, str]:
    packet = exact_between(sources[PACKET], "final class FFmpegPacket:",
                           "/// Retains one bounded compressed-video GOP")
    rational = exact_between(sources[TIME], "struct FFmpegRational:", "enum MediaTime {")
    seconds_marker = "    static func seconds(_ timestamp: Int64, timeBase: FFmpegRational) -> Double {"
    if sources[TIME].count(seconds_marker) != 1 or not sources[TIME].endswith("    }\n}\n"):
        raise ValueError("MediaTime.seconds extraction boundary changed")
    # The complete seconds method is copied exactly; only its enum wrapper is
    # generated. CMTime-dependent siblings are outside this component.
    seconds = sources[TIME][sources[TIME].index(seconds_marker):-2]
    parsers = exact_between(sources[PARSER], "enum PGSSubtitlePacket {",
                            "struct NativeBitmapSubtitleRegion:")
    if not packet.rstrip().endswith("}") or not rational.rstrip().endswith("}"):
        raise ValueError("Incomplete packet/rational declaration")
    if parsers.count("enum PGSSubtitlePacket {") != 1 or parsers.count("enum DVBSubtitlePacket {") != 1:
        raise ValueError("Both complete acquisition parsers are required")
    header = (
        "#include <libavcodec/avcodec.h>\n"
        "#include <libavcodec/packet.h>\n"
        "#include <libavutil/avutil.h>\n"
        "#include <libavutil/error.h>\n\n"
        + "\n".join(c_helper(sources[SHIM], name) for name in C_HELPERS)
    )
    generated = {
        "FFmpegPacket.swift": "import CFFmpeg\nimport Foundation\n\n" + packet,
        "MediaTime.swift": "import CFFmpeg\nimport Foundation\n\n" + rational
                          + "enum MediaTime {\n" + seconds + "}\n",
        "FFmpegError.swift": sources[ERROR],
        "AcquisitionParsers.swift": "import CFFmpeg\nimport Foundation\n\n" + parsers,
        "CFFmpeg/include/component.h": header,
        "CFFmpeg/module.modulemap": (
            'module CFFmpeg [system] {\n    header "include/component.h"\n'
            '    link "avcodec"\n    link "avutil"\n    export *\n}\n'
        ),
    }
    if ADAPTER in sources:
        adapter = sources[ADAPTER]
        if adapter.count("extension PGSSubtitlePacket {") != 1 or adapter.count("extension DVBSubtitlePacket {") != 1:
            raise ValueError("Candidate packet adapter must extend both acquisition parsers")
        generated["SubtitleAcquisitionPacket.swift"] = adapter
    return generated


class Runner:
    def __init__(self, args):
        if os.environ.get("LD_PRELOAD") or os.environ.get("DYLD_INSERT_LIBRARIES"):
            raise ValueError("Run without inherited LD_PRELOAD or DYLD_INSERT_LIBRARIES; timing must be uninstrumented")
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir()
        (self.output / "tmp").mkdir()
        self.env = os.environ.copy()
        self.env["TMPDIR"] = str(self.output / "tmp")
        self.commands = []
        # Preserve the swiftc symlink name: Swift's unified driver selects its
        # mode from argv[0], so resolving it to swift-driver changes behavior.
        self.swiftc = (shutil.which(args.swiftc) or str(Path(args.swiftc).absolute())) if args.swiftc else shutil.which("swiftc")
        self.prefix = args.ffmpeg_prefix.resolve() if args.ffmpeg_prefix else None
        self.receipt = {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE,
            "mode": "exact-production-declaration-component-with-real-ffmpeg",
            "exclusions": ["native application", "demuxer execution", "CoreMedia methods",
                           "bitmap timeline/rendering", "VideoToolbox C helpers"],
            "platform": platform.platform(), "machine": platform.machine(),
            "python": platform.python_version(), "cpu_count": os.cpu_count(),
            "sources": {}, "extracted_sources": {}, "binaries": {},
            "tmpdir": self.env["TMPDIR"],
        }

    def command(self, argv, *, extra_env: dict[str, str] | None = None) -> str:
        argv = [str(value) for value in argv]
        number = len(self.commands)
        start = time.monotonic()
        environment = self.env.copy()
        environment.update(extra_env or {})
        result = subprocess.run(argv, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        stdout_path = self.output / "logs" / f"{number:04d}.stdout"
        stderr_path = self.output / "logs" / f"{number:04d}.stderr"
        stdout_path.write_bytes(result.stdout)
        stderr_path.write_bytes(result.stderr)
        self.commands.append({
            "argv": argv, "returncode": result.returncode,
            "environment_overrides": {"TMPDIR": self.env["TMPDIR"], **(extra_env or {})},
            "elapsed_seconds": time.monotonic() - start,
            "stdout": str(stdout_path.relative_to(self.output)),
            "stderr": str(stderr_path.relative_to(self.output)),
            "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr),
        })
        write_json(self.output / "commands.json", self.commands)
        if result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}): {argv}\n"
                + result.stdout.decode("utf-8", errors="replace")[-4000:]
                + result.stderr.decode("utf-8", errors="replace")[-8000:]
            )
        return result.stdout.decode("utf-8")

    def source(self, path: str, variant: str) -> str:
        value = ((ROOT / path).read_bytes() if variant == "candidate" else
                 self.command(["git", "show", f"{BASELINE}:{path}"]).encode("utf-8"))
        destination = self.output / "full-sources" / variant / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(value)
        self.receipt["sources"][f"{variant}:{path}"] = sha(value)
        return value.decode("utf-8")

    def ffmpeg_flags(self) -> list[str]:
        if self.prefix is None:
            return []
        includes = [self.prefix / "include"]
        includes.extend(path.parent.parent for path in sorted(
            (self.prefix / "include").glob("*/libavcodec/packet.h")))
        libraries = [self.prefix / "lib"]
        libraries.extend(path.parent for path in sorted(
            (self.prefix / "lib").glob("*/libavcodec.so")))
        includes = list(dict.fromkeys(includes))
        libraries = list(dict.fromkeys(libraries))
        if not any((path / "libavcodec/packet.h").is_file() for path in includes):
            raise ValueError(f"No FFmpeg packet header found under {self.prefix}")
        self.receipt["ffmpeg_prefix"] = str(self.prefix)
        self.receipt["ffmpeg_include_dirs"] = [str(p) for p in includes]
        self.receipt["ffmpeg_library_dirs"] = [str(p) for p in libraries]
        self.receipt["ffmpeg_headers"] = {
            str(path.relative_to(self.prefix)): sha(path.read_bytes())
            for directory in includes for component in ("libavcodec", "libavutil")
            for path in sorted((directory / component).glob("*.h"))
        }
        resolved = {}
        for directory in libraries:
            for pattern in ("libavcodec*.so*", "libavutil*.so*", "libavcodec*.dylib", "libavutil*.dylib"):
                for path in sorted(directory.glob(pattern)):
                    if path.is_file():
                        real = path.resolve()
                        resolved[str(real)] = sha(real.read_bytes())
        self.receipt["ffmpeg_libraries"] = resolved
        flags = []
        for directory in includes:
            flags += ["-Xcc", "-I" + str(directory)]
        for directory in libraries:
            flags += ["-L", str(directory), "-Xlinker", "-rpath", "-Xlinker", str(directory)]
        return flags

    def prepare(self) -> None:
        if not self.swiftc:
            raise ValueError("swiftc is unavailable; supply --swiftc")
        self.receipt["compiler"] = self.command([self.swiftc, "--version"]).strip()
        self.receipt["candidate_revision"] = self.command(["git", "rev-parse", "HEAD"]).strip()
        self.receipt["worktree_status"] = self.command(["git", "status", "--short"])
        self.command(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"])
        if platform.system() == "Darwin":
            self.receipt["hardware"] = self.command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        elif Path("/proc/cpuinfo").is_file():
            self.receipt["hardware"] = next(
                (line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                 if line.startswith("model name")), "unknown")
        all_sources = {variant: {path: self.source(path, variant)
                                for path in (PARSER, DEMUXER, *SHARED)} for variant in VARIANTS}
        if self.command(["git", "ls-tree", "--name-only", BASELINE, "--", ADAPTER]).strip():
            raise ValueError("Pinned baseline unexpectedly contains the candidate packet adapter")
        all_sources["candidate"][ADAPTER] = self.source(ADAPTER, "candidate")
        self.receipt["baseline_absent_sources"] = [ADAPTER]
        for path in SHARED:
            if all_sources["baseline"][path] != all_sources["candidate"][path]:
                raise ValueError(f"Shared production dependency changed: {path}")
        for variant in VARIANTS:
            callsite = exact_between(all_sources[variant][DEMUXER], "    func activeSubtitlePackets(",
                                     "    /// AVIO retains AVERROR_EXIT")
            if variant == "baseline":
                required = ("packet.data.map", "PGSSubtitlePacket.isAcquisition(data)",
                            "DVBSubtitlePacket.isAcquisition(data, compositionPageID: compositionPageID)")
            else:
                required = ("PGSSubtitlePacket.isAcquisition(packet)",
                            "DVBSubtitlePacket.isAcquisition(packet, compositionPageID: compositionPageID)")
                if "packet.data" in callsite:
                    raise ValueError("Candidate demuxer still copies packet data for acquisition")
            if any(value not in callsite for value in required):
                raise ValueError(f"{variant} acquisition call site does not match the driver adapter")
        driver = self.output / "sources" / "Driver.swift"
        driver.parent.mkdir(parents=True, exist_ok=True)
        driver.write_bytes((HERE / "Driver.swift").read_bytes())
        self.receipt["driver_sha256"] = sha(driver.read_bytes())
        self.receipt["runner_sha256"] = sha(Path(__file__).read_bytes())
        shutil.copyfile(__file__, self.output / "runner.snapshot.py")
        flags = ["-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                 "-module-cache-path", str(self.output / "module-cache"), *self.ffmpeg_flags()]
        if platform.system() == "Darwin":
            sdk = self.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
            flags += ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
            self.receipt["sdk"] = sdk
        self.receipt["common_flags"] = flags
        for variant in VARIANTS:
            generated = components(all_sources[variant])
            source_dir = self.output / "sources" / variant
            for relative, value in generated.items():
                destination = source_dir / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(value)
                self.receipt["extracted_sources"][f"{variant}:{relative}"] = sha(value.encode())
            swift_paths = [source_dir / path for path in generated if path.endswith(".swift")]
            conditional = ["-D", "BASELINE"] if variant == "baseline" else []
            for configuration in CONFIGURATIONS:
                directory = self.output / variant / configuration
                directory.mkdir(parents=True)
                optimization = ["-O", "-whole-module-optimization"] if configuration == "release" else ["-Onone"]
                binary = directory / "benchmark"
                print(f"Building {variant}/{configuration} with real FFmpeg", flush=True)
                self.command([self.swiftc, *flags, *optimization, *conditional,
                              "-I", source_dir / "CFFmpeg", *swift_paths, driver, "-o", binary])
                self.receipt["binaries"][f"{variant}:{configuration}"] = sha(binary.read_bytes())
        inspector = "otool" if platform.system() == "Darwin" else "ldd"
        if shutil.which(inspector):
            arguments = [inspector, "-L"] if inspector == "otool" else [inspector]
            self.receipt["linked_dependencies"] = self.command(
                [*arguments, self.output / "candidate/release/benchmark"])
        if self.args.allocations:
            compiler = shutil.which("cc")
            if not compiler:
                raise ValueError("cc is required for the optional Linux allocation meter")
            meter_source = self.output / "sources/instrumentation/allocmeter.c"
            meter_source.parent.mkdir(parents=True)
            meter_source.write_bytes(ALLOCATION_METER.read_bytes())
            self.meter = self.output / "liballocmeter.so"
            self.command([compiler, "-std=c11", "-shared", "-fPIC", "-O2", meter_source, "-o", self.meter])
            self.receipt["allocation_meter"] = {
                "source": str(ALLOCATION_METER.relative_to(ROOT)),
                "source_sha256": sha(meter_source.read_bytes()),
                "binary_sha256": sha(self.meter.read_bytes()),
                "compiler": self.command([compiler, "--version"]).strip(),
                "metric": "successful malloc/calloc/realloc requests and cumulative requested bytes",
                "excludes": ["frees", "live or peak heap", "RSS", "GPU memory", "macOS physical footprint"],
            }
        write_json(self.output / "build-receipt.json", self.receipt)

    def invoke(self, variant: str, *args, configuration: str = "release"):
        return json.loads(self.command([self.output / variant / configuration / "benchmark", *args]))

    def verify(self) -> None:
        traces = {}
        for variant in VARIANTS:
            for configuration in CONFIGURATIONS:
                trace = self.invoke(variant, "verify", configuration=configuration)
                write_json(self.output / f"{variant}-{configuration}-trace.json", trace)
                traces[f"{variant}:{configuration}"] = trace
        reference = traces["baseline:debug"]
        if any(trace != reference for trace in traces.values()):
            raise ValueError("Complete acquisition traces differ across baseline/candidate or debug/release")
        cases = reference["cases"]
        if not cases or len({case["name"] for case in cases}) != len(cases):
            raise ValueError("Verification cases must be nonempty and uniquely named")
        for key in ("pgs", "dvbAny", "dvbSelected"):
            if not any(case[key] is True for case in cases) or not any(case[key] is False for case in cases):
                raise ValueError(f"Verification lacks both true and false outcomes for {key}")
        self.receipt["runtime_library_versions"] = {
            key: reference[key] for key in ("ffmpegVersion", "avcodecVersion", "avutilVersion") if key in reference
        }
        write_json(self.output / "parity.json", {
            "equal": True, "configurations": list(traces), "cases_per_configuration": len(cases),
            "trace_sha256": sha(json.dumps(reference, sort_keys=True).encode()),
        })
        print(f"Complete trace parity: {len(cases)} cases in all four builds", flush=True)

    @staticmethod
    def validate_receipt(row, variant: str, case: str, iterations: int) -> None:
        if row["workload"] != case or row["iterations"] != iterations or iterations % 16:
            raise ValueError("Measurement workload or iteration count mismatch")
        if len(row["payloadBytes"]) != 16 or any(value < 0 for value in row["payloadBytes"]):
            raise ValueError("Workloads must rotate sixteen packet payloads")
        expected = (row["cycleChecksum"] * (iterations // 16)) & UINT64_MASK
        if row["checksum"] != expected:
            raise ValueError(f"Checksum does not match complete repeated cycles: {variant}/{case}")

    def measurement(self, variant: str, case: str, iterations: int):
        row = self.invoke(variant, "measure", case, str(iterations))
        self.validate_receipt(row, variant, case, iterations)
        if row["elapsedNanoseconds"] <= 0 or row["cpuNanoseconds"] <= 0:
            raise ValueError("Nonpositive wall or process CPU duration")
        return row

    def calibrate(self, variant: str, case: str):
        iterations, pilots = 4096, []
        for _ in range(8):
            row = self.measurement(variant, case, iterations)
            pilots.append(row)
            measured = min(row["elapsedNanoseconds"], row["cpuNanoseconds"])
            if measured >= self.args.target_ms * 1_000_000:
                return {"iterations": iterations, "pilots": pilots}
            requested = math.ceil(iterations * self.args.target_ms * 1_000_000 * 1.25 / measured)
            iterations = max(iterations + 16, math.ceil(requested / 16) * 16)
            if iterations > 100_000_000:
                raise ValueError("Calibration exceeds 100 million calls; inspect optimizer and timers")
        raise ValueError(f"Could not calibrate {variant}/{case}")

    def measure(self) -> None:
        summaries, calibration, too_short = [], {}, []
        for case in self.args.cases:
            calibration[case] = {variant: self.calibrate(variant, case) for variant in VARIANTS}
            write_json(self.output / "calibration.json", calibration)
            pairs = []
            for pair in range(self.args.pairs):
                order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                values = {}
                for variant in order:
                    row = self.measurement(variant, case, calibration[case][variant]["iterations"])
                    row.update({"variant": variant, "pair": pair, "order": list(order)})
                    values[variant] = row
                    with (self.output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                for field in ("cycleChecksum", "payloadBytes"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise ValueError(f"Timed fixture/output mismatch: {case}/{pair}/{field}")
                pairs.append(values)
            summary = {
                "workload": case, "pairs": self.args.pairs,
                "iterations": {v: calibration[case][v]["iterations"] for v in VARIANTS},
                "payload_bytes": pairs[0]["baseline"]["payloadBytes"],
                "minimum_required_ms": self.args.minimum_ms,
                "observations_under_minimum": [],
            }
            for metric, field in (("wall", "elapsedNanoseconds"), ("cpu", "cpuNanoseconds")):
                normalized = {v: [p[v][field] / p[v]["iterations"] for p in pairs] for v in VARIANTS}
                old, new = (statistics.median(normalized[v]) for v in VARIANTS)
                summary[metric] = {
                    "baseline_ns_per_packet": old, "candidate_ns_per_packet": new,
                    "change_percent": (new / old - 1) * 100,
                    "paired_ratios": [p["candidate"][field] / p["candidate"]["iterations"]
                                      / (p["baseline"][field] / p["baseline"]["iterations"]) for p in pairs],
                    "ranges_ns_per_packet": {v: [min(normalized[v]), max(normalized[v])] for v in VARIANTS},
                    "minimum_observed_ms": {v: min(p[v][field] for p in pairs) / 1_000_000 for v in VARIANTS},
                }
                summary["observations_under_minimum"].extend(
                    {"variant": v, "pair": p[v]["pair"], "metric": metric,
                     "observed_ms": p[v][field] / 1_000_000}
                    for p in pairs for v in VARIANTS if p[v][field] < self.args.minimum_ms * 1_000_000)
            summaries.append(summary)
            too_short.extend(summary["observations_under_minimum"])
            write_json(self.output / "summary.json", summaries)
            wall = summary["wall"]
            print(f"{case}: {wall['baseline_ns_per_packet']:.1f} -> {wall['candidate_ns_per_packet']:.1f} ns/packet "
                  f"({wall['change_percent']:+.1f}% wall, {summary['cpu']['change_percent']:+.1f}% CPU)", flush=True)
        if too_short:
            raise ValueError("At least one observation is below the duration floor; retain this cohort and rerun with a higher target")

    def measure_allocations(self) -> None:
        # The interposer is loaded only in these separate processes, never in a
        # timing/calibration process or the Python runner. Counts describe
        # allocation traffic, not retained memory or a whole-player footprint.
        summaries = []
        iterations = 4096
        for case in self.args.cases:
            pairs = []
            for repeat in range(3):
                order = VARIANTS if repeat % 2 == 0 else VARIANTS[::-1]
                values = {}
                for variant in order:
                    row = json.loads(self.command([
                        self.output / variant / "release/benchmark", "allocations", case, str(iterations)
                    ], extra_env={"LD_PRELOAD": str(self.meter)}))
                    self.validate_receipt(row, variant, case, iterations)
                    for field in ("allocationRequests", "requestedBytes"):
                        if not isinstance(row[field], int) or row[field] < 0:
                            raise ValueError(f"Invalid allocation counter: {variant}/{case}/{field}")
                    row.update({"variant": variant, "repeat": repeat, "order": list(order)})
                    values[variant] = row
                    with (self.output / "allocation-measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                for field in ("cycleChecksum", "payloadBytes"):
                    if values["baseline"][field] != values["candidate"][field]:
                        raise ValueError(f"Allocation fixture/output mismatch: {case}/{repeat}/{field}")
                pairs.append(values)
            summary = {
                "workload": case, "observations_per_variant": 3, "iterations_per_observation": iterations,
                "payload_bytes": pairs[0]["baseline"]["payloadBytes"],
            }
            for field in ("allocationRequests", "requestedBytes"):
                samples = {v: [p[v][field] for p in pairs] for v in VARIANTS}
                old, new = (statistics.median(samples[v]) for v in VARIANTS)
                summary[field] = {
                    "baseline_median": old, "candidate_median": new,
                    "baseline_per_packet": old / iterations, "candidate_per_packet": new / iterations,
                    "change_percent": (new / old - 1) * 100 if old else None,
                    "ranges": {v: [min(samples[v]), max(samples[v])] for v in VARIANTS},
                }
            summaries.append(summary)
            write_json(self.output / "allocation-summary.json", summaries)
            requested = summary["requestedBytes"]
            print(f"{case}: allocation requests {summary['allocationRequests']['baseline_median']} -> "
                  f"{summary['allocationRequests']['candidate_median']}; requested bytes "
                  f"{requested['baseline_median']} -> {requested['candidate_median']} "
                  f"per {iterations} checks", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc")
    parser.add_argument("--ffmpeg-prefix", type=Path)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--allocations", action="store_true",
                        help="Also measure Linux/glibc allocation requests in separate preloaded processes")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--minimum-ms", type=float, default=50)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2:
        parser.error("Use an even number of at least six alternating process pairs")
    if not math.isfinite(args.minimum_ms) or not math.isfinite(args.target_ms) or args.minimum_ms < 50 or args.target_ms < args.minimum_ms:
        parser.error("Target must be finite and at least the minimum, and minimum must be at least 50 ms")
    if len(set(args.cases)) != len(args.cases):
        parser.error("Duplicate workloads are not allowed")
    if args.allocations and (platform.system() != "Linux" or platform.libc_ver()[0] != "glibc"):
        parser.error("--allocations requires Linux/glibc")
    runner = Runner(args)
    try:
        runner.prepare()
        runner.verify()
        if not args.tests_only:
            runner.measure()
        if args.allocations:
            runner.measure_allocations()
        write_json(runner.output / "completion.json", {
            "complete": True, "tests_only": args.tests_only, "pairs": args.pairs,
            "minimum_observation_duration_met": not args.tests_only, "minimum_ms": args.minimum_ms,
            "allocation_measurements_completed": args.allocations,
        })
    except Exception as error:
        write_json(runner.output / "completion.json", {
            "complete": False, "error": str(error), "traceback": traceback.format_exc(),
        })
        raise
    finally:
        write_json(runner.output / "commands.json", runner.commands)
        write_json(runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()
