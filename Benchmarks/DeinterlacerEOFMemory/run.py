#!/usr/bin/env python3
"""Compare complete production deinterlacer sources using real FFmpeg filters.

Run from an SDK-equipped macOS host or use build-linux-ffmpeg.sh first on Linux.
This component study reports the driver's explicit ownership measurements; it
does not measure whole-player memory, hardware transfer, or perceptual output.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
SOURCE = "Sources/IlliquidNativePlayback/Media/VideoDeinterlacer.swift"
ERROR = "Sources/IlliquidNativePlayback/Media/FFmpegError.swift"
SHIM = "Sources/CFFmpeg/include/ffmpeg_shim.h"
MODULE = "Sources/CFFmpeg/module.modulemap"
TEST = "Tests/IlliquidNativePlaybackTests/VideoDeinterlacerLifetimeTests.swift"
EXTRACTIONS = [
    ("Sources/IlliquidNativePlayback/Media/MediaTime.swift", "struct FFmpegRational:"),
    ("Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift", "struct PresentationError:"),
    ("Sources/IlliquidNativePlayback/Media/VideoDecoder.swift", "enum SoftwarePixelBufferPoolError:"),
]
C_HELPERS = ["illiquid_averror_eagain", "illiquid_averror_eof", "illiquid_averror_exit",
             "illiquid_averror_invaliddata", "illiquid_nopts_value",
             "illiquid_frame_pixel_format", "illiquid_frame_best_effort_timestamp"]
CASES = ["empty", "progressive", "one_tff", "sd_tff", "hd_tff", "hd_bff",
         "uhd10_tff", "mixed", "format_change", "held_output"]
VARIANTS = ("baseline", "candidate")
CONFIGURATIONS = {"debug": "-Onone", "release": "-O"}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(text: str, marker: str) -> str:
    """Extract one unchanged declaration; fail if its structure becomes unclear."""
    if text.count(marker) != 1:
        raise ValueError(f"Expected one declaration: {marker}")
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    for index in range(opening + 1, len(text)):
        depth += (text[index] == "{") - (text[index] == "}")
        if depth == 0:
            return text[start:index + 1] + "\n"
    raise ValueError(f"Unbalanced declaration: {marker}")


def c_function(text: str, name: str) -> str:
    match = re.search(r"(?m)^static inline [^\n]*\b" + re.escape(name) + r"\(", text)
    if match is None:
        raise ValueError(f"Missing C helper: {name}")
    return declaration(text, text[match.start():text.index("(", match.start()) + 1])


def files_equal(a: Path, b: Path) -> bool:
    if a.stat().st_size != b.stat().st_size:
        return False
    with a.open("rb") as left, b.open("rb") as right:
        while block := left.read(1024 * 1024):
            if block != right.read(len(block)):
                return False
    return True


class Study:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output directory must be new or empty")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands = []
        self.linux = platform.system() == "Linux"
        if not self.linux and platform.system() != "Darwin":
            raise ValueError("Only Linux and macOS are supported")
        self.environment = os.environ.copy()
        for key in ("SWIFT_MODULECACHE_PATH", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
            self.environment[key] = str(self.output / "module-cache")
        self.swiftc = args.swiftc or shutil.which("swiftc") or "swiftc"
        self.swift = args.swift or str(Path(self.swiftc).with_name("swift"))
        self.receipt = {
            "schema_version": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_revision": BASELINE, "platform": platform.platform(),
            "machine": platform.machine(), "pairs": args.pairs, "cases": args.cases,
            "environment": {"python": platform.python_version(), "processor": platform.processor(),
                            "logical_cpu_count": os.cpu_count(),
                            "developer_dir": self.environment.get("DEVELOPER_DIR")},
            "source_hashes": {}, "staged_hashes": {}, "binaries": {},
            "observations": [], "comparisons": [], "tests": [], "complete": False,
            "linux_adaptation": ("Remove only import CoreVideo; provide a nil VideoToolbox "
                "guard and CVReturn alias. No filter, frame, or ownership API is mocked.") if self.linux else None,
        }
        self.inputs = {}
        self.binaries = {}
        self.canonical = {}
        self.sources = {}
        self.cc_flags, self.link_flags = self.sdk_flags()

    def save(self):
        write_json(self.output / "receipt.json", self.receipt)
        write_json(self.output / "commands.json", self.commands)

    def command(self, argv, name, *, check=True, cwd=None):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=cwd or ROOT, env=self.environment,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = self.output / "logs" / (name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_bytes(result.stdout)
        self.commands.append({"argv": argv, "cwd": str(cwd or ROOT),
                              "returncode": result.returncode,
                              "elapsed_seconds": time.monotonic() - started,
                              "log": str(log.relative_to(self.output)), "log_sha256": sha(result.stdout)})
        self.save()
        if check and result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n" + result.stdout.decode(errors="replace")[-8000:])
        return result

    def stage(self, relative, data):
        data = data.encode() if isinstance(data, str) else data
        path = self.output / "sources" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.receipt["staged_hashes"][str(path.relative_to(self.output))] = sha(data)
        return path

    def sdk_flags(self):
        prefix = self.args.sdk_prefix
        if self.linux:
            prefix = (prefix or Path("/tmp/illiquid-deinterlacer-memory-sdk")).resolve()
            if not (prefix / "include/libavfilter/avfilter.h").is_file():
                raise ValueError("Pinned Linux SDK is missing; run build-linux-ffmpeg.sh first")
            cc = ["-I" + str(prefix / "include")]
            links = ["-L" + str(prefix / "lib"), "-lavfilter", "-lswscale", "-lavutil", "-lm", "-lpthread", "-latomic", "-ldl"]
            self.receipt["sdk"] = {"prefix": str(prefix), "libraries": {
                path.name: file_sha(path) for path in sorted((prefix / "lib").glob("*.a"))}}
            for name in ("source-receipt.json", "build-receipt.json"):
                if (prefix / name).is_file():
                    self.receipt["sdk"][name] = json.loads((prefix / name).read_text())
            return cc, links
        if prefix:
            prefix = prefix.resolve()
            self.environment["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig") + os.pathsep + self.environment.get("PKG_CONFIG_PATH", "")
        packages = ["libavformat", "libavfilter", "libavcodec", "libavutil", "libswresample", "libswscale"]
        versions = self.command(["pkg-config", "--modversion", *packages], "pkg-config-versions").stdout.decode().splitlines()
        self.receipt["sdk"] = {"packages": dict(zip(packages, versions))}
        expected = {"libavformat": "62.12.102", "libavfilter": "11.14.102",
                    "libavcodec": "62.28.102", "libavutil": "60.26.102",
                    "libswresample": "6.3.102", "libswscale": "9.5.102"}
        if self.receipt["sdk"]["packages"] != expected:
            raise ValueError("Native component qualification requires pinned FFmpeg 8.1.2")
        cc = shlex.split(self.command(["pkg-config", "--cflags", *packages], "pkg-config-cflags").stdout.decode())
        links = shlex.split(self.command(["pkg-config", "--libs", *packages], "pkg-config-libs").stdout.decode())
        return cc, links

    def prepare(self):
        manifest = json.loads((HERE / "baseline/manifest.json").read_text())
        if manifest["revision"] != BASELINE:
            raise ValueError("Frozen baseline revision changed")
        frozen = (HERE / "baseline/VideoDeinterlacer.swift").read_bytes()
        if sha(frozen) != manifest["source_sha256"][SOURCE]:
            raise ValueError("Frozen baseline differs from its recorded source hash")
        for name, expected in manifest["source_sha256"].items():
            if name == SOURCE:
                continue
            data = (ROOT / name).read_bytes()
            if sha(data) != expected:
                raise ValueError(f"Shared support changed; review and requalify: {name}")
            self.inputs[name] = data
        self.inputs["baseline/VideoDeinterlacer.swift"] = frozen
        self.inputs["candidate/VideoDeinterlacer.swift"] = (ROOT / SOURCE).read_bytes()
        self.inputs[TEST] = (ROOT / TEST).read_bytes()
        for name in ("Driver.swift", "LifetimeProbe.h", "LinuxSupport.swift", "run.py", "build-linux-ffmpeg.sh", "baseline/manifest.json"):
            self.inputs["harness/" + name] = (HERE / name).read_bytes()
        for name, data in self.inputs.items():
            self.receipt["source_hashes"][name] = sha(data)
            self.stage("originals/" + name, data)
        support = "import CFFmpeg\nimport Foundation\n" + ("" if self.linux else "import CoreVideo\n") + "\n"
        self.receipt["extractions"] = []
        for name, marker in EXTRACTIONS:
            fragment = declaration(self.inputs[name].decode(), marker)
            support += fragment + "\n"
            self.receipt["extractions"].append({"source": name, "marker": marker, "sha256": sha(fragment.encode())})
        shared = [self.stage("shared/SupportDeclarations.swift", support),
                  self.stage("shared/FFmpegError.swift", self.inputs[ERROR])]
        if self.linux:
            shared.append(self.stage("shared/LinuxSupport.swift", self.inputs["harness/LinuxSupport.swift"]))
            header = ("#include <libavfilter/avfilter.h>\n#include <libavfilter/buffersrc.h>\n"
                      "#include <libavfilter/buffersink.h>\n#include <libavutil/avutil.h>\n"
                      "#include <libavutil/buffer.h>\n#include <libavutil/frame.h>\n"
                      "#include <libavutil/error.h>\n#include <libavutil/hwcontext.h>\n"
                      "#include <libavutil/imgutils.h>\n#include <libavutil/mathematics.h>\n"
                      "#include <libavutil/pixdesc.h>\n#include <libavutil/opt.h>\n"
                      "#include <libavutil/mem.h>\n#include <string.h>\n\n")
            for name in C_HELPERS:
                fragment = c_function(self.inputs[SHIM].decode(), name)
                header += fragment + "\n"
                self.receipt["extractions"].append({"source": SHIM, "marker": name, "sha256": sha(fragment.encode())})
            self.stage("CFFmpeg/include/ffmpeg_shim.h", header)
            module = 'module CFFmpeg [system] {\n header "include/ffmpeg_shim.h"\n export *\n}\n'
        else:
            self.stage("CFFmpeg/include/ffmpeg_shim.h", self.inputs[SHIM])
            module = self.inputs[MODULE]
        self.stage("CFFmpeg/module.modulemap", module)
        self.stage("CDeinterlacerProbe/LifetimeProbe.h", self.inputs["harness/LifetimeProbe.h"])
        self.stage("CDeinterlacerProbe/module.modulemap", 'module CDeinterlacerProbe [system] {\n header "LifetimeProbe.h"\n export *\n}\n')
        self.driver = self.stage("shared/Driver.swift", self.inputs["harness/Driver.swift"])
        for variant in VARIANTS:
            source = self.inputs[variant + "/VideoDeinterlacer.swift"].decode()
            if self.linux:
                if source.count("import CoreVideo\n") != 1:
                    raise ValueError("Review changed CoreVideo import before adapting source")
                source = source.replace("import CoreVideo\n", "")
            self.sources[variant] = [*shared, self.stage(variant + "/VideoDeinterlacer.swift", source)]
        self.receipt["compiler"] = self.command([self.swiftc, "--version"], "swift-version").stdout.decode().strip()
        self.receipt["candidate_revision"] = self.command(["git", "rev-parse", "HEAD"], "git-head").stdout.decode().strip()
        self.receipt["working_tree_status"] = self.command(["git", "status", "--short"], "git-status").stdout.decode()
        self.save()

    def compiler_flags(self):
        flags = ["-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                 "-I", str(self.output / "sources/CFFmpeg"),
                 "-I", str(self.output / "sources/CDeinterlacerProbe"),
                 "-module-cache-path", str(self.output / "module-cache")]
        for flag in self.cc_flags:
            flags += ["-Xcc", flag]
        for flag in self.link_flags:
            flags += ["-Xlinker", flag]
        return flags

    def build(self):
        (self.output / "binaries").mkdir()
        for configuration, optimization in CONFIGURATIONS.items():
            if configuration == "debug" and self.args.skip_debug:
                continue
            for variant in VARIANTS:
                name = f"{configuration}-{variant}"
                binary = self.output / "binaries" / name
                self.command([self.swiftc, optimization, *self.compiler_flags(),
                              *self.sources[variant], self.driver, "-o", binary], "build-" + name)
                self.binaries[configuration, variant] = binary
                self.receipt["binaries"][str(binary.relative_to(self.output))] = file_sha(binary)
        self.save()

    def tests(self):
        if self.args.skip_tests:
            return
        for variant in VARIANTS:
            package = self.output / "tests" / variant
            production = package / "Sources/IlliquidNativePlayback"
            tests = package / "Tests/IlliquidNativePlaybackTests"
            production.mkdir(parents=True)
            tests.mkdir(parents=True)
            shutil.copytree(self.output / "sources/CFFmpeg", package / "Sources/CFFmpeg")
            for source in self.sources[variant]:
                shutil.copy2(source, production / source.name)
            (tests / "VideoDeinterlacerLifetimeTests.swift").write_bytes(self.inputs[TEST])
            (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "DeinterlacerEOFQualification", platforms: [.macOS("26.0")], targets: [
    .systemLibrary(name: "CFFmpeg"),
    .target(name: "IlliquidNativePlayback", dependencies: ["CFFmpeg"]),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["CFFmpeg", "IlliquidNativePlayback"]),
])
''')
            for path in package.rglob("*"):
                if path.is_file():
                    self.receipt["staged_hashes"][str(path.relative_to(self.output))] = file_sha(path)
            for configuration in CONFIGURATIONS:
                common = ["--package-path", package, "--scratch-path", package / ("build-" + configuration),
                          "--cache-path", self.output / "swiftpm-cache", "--config-path", self.output / "swiftpm-config",
                          "--security-path", self.output / "swiftpm-security", "-c", configuration, "--jobs", "2",
                          "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-enable-testing"]
                if self.linux:
                    common += ["--use-integrated-swift-driver"]
                for flag in self.cc_flags:
                    common += ["-Xcc", flag]
                for flag in self.link_flags:
                    common += ["-Xlinker", flag]
                name = f"tests-{configuration}-{variant}"
                # Build errors are never accepted as an expected failing test.
                self.command([self.swift, "build", "--build-tests", *common], name + "-build")
                result = self.command([self.swift, "test", "--skip-build", *common, "--no-parallel",
                                       "--filter", "VideoDeinterlacerLifetimeTests"], name + "-run", check=False)
                log = result.stdout.decode(errors="replace")
                if variant == "candidate":
                    passed = result.returncode == 0 and re.search(r"Test run with \d+ tests? .*passed", log)
                    if not passed:
                        raise RuntimeError(f"Candidate lifetime tests failed; see logs/{name}-run.log")
                else:
                    expected = (result.returncode == 1
                                and re.search(r"Test run with \d+ tests? .*failed", log)
                                and "observers.allSatisfy" in log)
                    if not expected:
                        raise RuntimeError(f"Baseline negative control did not fail as expected; see logs/{name}-run.log")
                self.receipt["tests"].append({"variant": variant, "configuration": configuration,
                                               "returncode": result.returncode,
                                               "expected_failure": variant == "baseline", "qualified": True})
                for path in (package / ("build-" + configuration)).rglob("*"):
                    if path.is_file() and (path.suffix == ".xctest" or ".xctest/Contents/MacOS/" in str(path)):
                        self.receipt["binaries"][str(path.relative_to(self.output))] = file_sha(path)
                self.save()

    def run_pair(self, configuration, case, pair):
        order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
        paths, records = {}, {}
        for index, variant in enumerate(order):
            name = f"{configuration}-{case}-{pair:02d}-{variant}"
            metrics = self.output / "metrics" / (name + ".json")
            payload = self.output / "payloads" / (name + ".bin")
            metrics.parent.mkdir(exist_ok=True)
            payload.parent.mkdir(exist_ok=True)
            self.command([self.binaries[configuration, variant], case, metrics, payload], name)
            value = json.loads(metrics.read_text())
            if not isinstance(value, dict):
                raise ValueError(f"Metrics must be an object: {name}")
            self.validate_metrics(value, variant, case)
            record = {"configuration": configuration, "case": case, "pair": pair,
                      "variant": variant, "position": index, "metrics": value,
                      "metrics_file": str(metrics.relative_to(self.output)), "metrics_sha256": file_sha(metrics),
                      "payload_bytes": payload.stat().st_size, "payload_sha256": file_sha(payload)}
            self.receipt["observations"].append(record)
            paths[variant], records[variant] = payload, record
            self.save()
        if not files_equal(paths["baseline"], paths["candidate"]):
            raise RuntimeError(f"Output bytes differ: {configuration}/{case}/pair {pair}; payloads retained")
        digest = records["baseline"]["payload_sha256"]
        if case in self.canonical and self.canonical[case] != digest:
            raise RuntimeError(f"Output changed between runs/configurations: {case}")
        if case not in self.canonical:
            self.canonical[case] = digest
            compressed = self.output / "payloads" / (case + ".bin.gz")
            with paths["baseline"].open("rb") as source, compressed.open("wb") as destination:
                with gzip.GzipFile(filename="", mode="wb", fileobj=destination, mtime=0) as archive:
                    shutil.copyfileobj(source, archive)
            self.receipt.setdefault("retained_payloads", {})[case] = {
                "path": str(compressed.relative_to(self.output)), "sha256": file_sha(compressed),
                "uncompressed_sha256": digest, "uncompressed_bytes": records["baseline"]["payload_bytes"]}
        for path in paths.values():
            path.unlink()
        self.receipt["comparisons"].append({"configuration": configuration, "case": case,
                                              "pair": pair, "order": list(order), "byte_identical": True})
        self.save()

    @staticmethod
    def validate_metrics(value, variant, case):
        if value["workload"] != case or value["ffmpegVersion"] != "8.1.2":
            raise ValueError("Unexpected workload or FFmpeg version")
        if value["outputCount"] != value["expectedOutputCount"] or not value["heldOutputSurvivedDrain"]:
            raise ValueError("Output cadence or retained-output ownership failed")
        for key in ("afterFeed", "afterDrain", "afterRepeatedDrain", "afterConsumerRelease", "afterReset"):
            snapshot = value[key]
            if any(type(snapshot[field]) is not int or snapshot[field] < 0
                   for field in ("liveBytes", "liveAllocations", "freedAllocations")):
                raise ValueError(f"Invalid allocation counters: {key}")
            if snapshot["liveAllocations"] + snapshot["freedAllocations"] != value["totalInputAllocations"]:
                raise ValueError(f"Allocation conservation failed: {key}")
        if value["afterDrain"] != value["afterRepeatedDrain"]:
            raise ValueError("Repeated drain changed ownership")
        if value["afterReset"]["liveBytes"] or value["afterReset"]["liveAllocations"]:
            raise ValueError("Final reset retained input allocations")
        released = value["afterConsumerRelease"]
        control = case in ("empty", "progressive")
        if variant == "candidate" or control:
            if released["liveBytes"] or released["liveAllocations"]:
                raise ValueError("Expected complete input release after drain and consumer release")
        elif not released["liveBytes"] or not released["liveAllocations"]:
            raise ValueError("Baseline did not reproduce retained temporal input allocations")
        if variant == "candidate" and case != "held_output" and value["afterDrain"]["liveBytes"]:
            raise ValueError("Candidate retained input without a consumer")
        if case == "held_output" and value["afterDrain"]["liveAllocations"] < 1:
            raise ValueError("Consumer-held input was released prematurely")

    def run(self):
        self.prepare()
        self.build()
        self.tests()
        if not self.args.skip_debug:
            for case in self.args.cases:
                self.run_pair("debug", case, 0)
        for case in self.args.cases:
            for pair in range(self.args.pairs):
                self.run_pair("release", case, pair)
        self.receipt["complete"] = True
        self.receipt["finished_utc"] = datetime.now(timezone.utc).isoformat()
        self.save()
        print(json.dumps({"complete": True, "comparisons": len(self.receipt["comparisons"]),
                          "observations": len(self.receipt["observations"]),
                          "output": str(self.output)}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk-prefix", type=Path, help="Linux SDK prefix; optional pkg-config prefix on macOS")
    parser.add_argument("--swiftc")
    parser.add_argument("--swift")
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--skip-debug", action="store_true", help="Skip debug output parity processes (lifetime tests still use both configurations)")
    parser.add_argument("--skip-tests", action="store_true", help="For smoke runs only; no lifetime-test qualification is recorded")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be a positive even number of at least two for balanced AB/BA order")
    if len(set(args.cases)) != len(args.cases):
        parser.error("--cases must not repeat workloads")
    study = Study(args)
    try:
        study.run()
    finally:
        study.save()


if __name__ == "__main__":
    main()
