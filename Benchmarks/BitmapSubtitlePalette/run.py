#!/usr/bin/env python3
"""Verify and measure the production bitmap subtitle palette conversion.

Requires Python 3.10+, a C11 compiler, and the repository's pinned native SDK.
Only SDK headers are extracted; no FFmpeg libraries are loaded or installed.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import statistics
import subprocess
import tarfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = "Sources/CFFmpeg/include/ffmpeg_shim.h"
BASELINES = {
    "scalar": {
        "file": "Baseline.h",
        "revision": "68274d1b09dcc866296321a5a8858efc297c4f19",
        "source_blob": "10a3f9d1a2c5604a2eaaa8299a727ce5d2552bcc",
        "sha256": "4f4e115e23be67dbdbbaf3390af4862969c13c2fdff628f5e364b808e35c81b0",
    },
    "checked-palette": {
        "file": "CheckedPaletteBaseline.h",
        "revision": "ea2ff568237e2667f7b1aeee67b11a44ebe95b72",
        "source_blob": "7f980fcf6a8ba1612259d555fb71994da5148d27",
        "sha256": "312c80c905a5cdd6d9f2a262821221e83dc8564360b7e78a26916429c51c9775",
    },
}
FUNCTION = "illiquid_subtitle_rect_copy_bgra"
COMMON_FLAGS = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-fno-lto"]
MAX_ITERATIONS = 99_999_992  # Complete eight-fixture cycles, below the harness cap.


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def extract_function(source: str) -> str:
    # This helper contains no top-level closing brace other than its own.
    # Keep the complete declaration verbatim, including its scalar fallback.
    marker = f"static inline int {FUNCTION}("
    if source.count(marker) != 1:
        raise ValueError("Expected exactly one bitmap palette helper")
    start = source.index(marker)
    end = source.index("\n}\n", start) + 3
    return source[start:end]


def positive_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return value


def paired_count(text: str) -> int:
    value = int(text)
    if value < 2 or value % 2:
        raise argparse.ArgumentTypeError("must be a positive even number, at least 2")
    return value


class Experiment:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.baseline = BASELINES[args.baseline]
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        compiler = shutil.which(args.cc)
        if compiler is None:
            raise ValueError(f"C compiler not found: {args.cc}")
        self.cc = compiler
        self.commands: list[dict] = []
        self.env = os.environ.copy()
        self.sources = self.output / "sources"
        self.sources.mkdir()
        self.report = {
            "schema_version": 1,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(),
            "architecture": platform.machine(),
            "compiler": self.command([self.cc, "--version"]).strip(),
            "baseline": args.baseline,
            "baseline_revision": self.baseline["revision"],
            "baseline_source_blob": self.baseline["source_blob"],
            "candidate_source_kind": "working_tree",
            "candidate_route": "complete_shim" if platform.system() == "Darwin" else "verbatim_helper",
            "common_compiler_flags": COMMON_FLAGS,
            "release_flags": ["-O3"],
            "pairs": args.pairs,
            "target_ms_per_baseline_sample": args.target_ms,
            "source_sha256": {},
            "verification": {},
            "calibration": [],
            "measurements": [],
            "summary": [],
        }
        self.prepare_sources()

    def command(self, argv: list[str], *, env: dict | None = None,
                allow_failure: bool = False) -> str:
        start = time.monotonic()
        process = subprocess.run(argv, cwd=ROOT, env=env or self.env, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        receipt = {
            "argv": argv, "elapsed_seconds": time.monotonic() - start,
            "returncode": process.returncode,
            "stdout_sha256": digest(process.stdout.encode()),
            "stderr": process.stderr,
        }
        if process.returncode:
            receipt["stdout"] = process.stdout
        self.commands.append(receipt)
        if process.returncode and not allow_failure:
            raise RuntimeError(f"Command failed ({process.returncode}): {argv!r}\n"
                               f"{process.stdout[-4000:]}\n{process.stderr[-8000:]}")
        return process.stdout

    def prepare_sources(self) -> None:
        baseline = (HERE / self.baseline["file"]).read_bytes()
        if digest(baseline) != self.baseline["sha256"]:
            raise ValueError("The frozen baseline helper has changed")
        candidate = (ROOT / SOURCE).read_bytes()
        helper = extract_function(candidate.decode()).encode()
        inputs = {
            SOURCE: candidate,
            f"Benchmarks/BitmapSubtitlePalette/{self.baseline['file']}": baseline,
            "Benchmarks/BitmapSubtitlePalette/Harness.c": (HERE / "Harness.c").read_bytes(),
            "Benchmarks/BitmapSubtitlePalette/run.py": Path(__file__).read_bytes(),
        }
        self.report["source_sha256"] = {name: digest(data) for name, data in inputs.items()}
        self.report["candidate_helper_sha256"] = digest(helper)
        (self.sources / "Baseline.h").write_bytes(baseline)
        (self.sources / "candidate-helper.h").write_bytes(helper)
        (self.sources / "ffmpeg_shim.h").write_bytes(candidate)
        (self.sources / "Harness.c").write_bytes(inputs["Benchmarks/BitmapSubtitlePalette/Harness.c"])
        (self.sources / "run.snapshot.py").write_bytes(inputs["Benchmarks/BitmapSubtitlePalette/run.py"])
        # Some sandbox launchers remove sanitizer environment variables. Set
        # defaults in a test-only translation unit so unsupported leak scanning
        # cannot abort otherwise valid address/UB checks at process teardown.
        (self.sources / "SanitizerOptions.c").write_text(
            'const char *__asan_default_options(void) {\n'
            '    return "detect_leaks=0:halt_on_error=1";\n}\n'
            'const char *__ubsan_default_options(void) {\n'
            '    return "halt_on_error=1:print_stacktrace=0";\n}\n')

        common = "#include <stdint.h>\n#include <string.h>\n#include <libavcodec/avcodec.h>\n#include <libavutil/error.h>\n"
        for variant in ("baseline", "candidate"):
            header = "Baseline.h" if variant == "baseline" else (
                "ffmpeg_shim.h" if platform.system() == "Darwin" else "candidate-helper.h")
            wrapper = common + f'#include "{header}"\n' + (
                f"int {variant}_convert(const AVSubtitleRect *rect, uint8_t *output, size_t size) {{\n"
                f"    return {FUNCTION}(rect, output, size);\n}}\n")
            (self.sources / f"{variant}.c").write_text(wrapper)

        metadata_path = ROOT / "BuildInputs/native-sdk.json"
        metadata = json.loads(metadata_path.read_text())
        prefix = metadata["kegs"]["ffmpeg"] + "/include/"
        expected = {entry["path"]: entry["sha256"] for entry in metadata["files"]
                    if entry["path"].startswith(prefix) and "sha256" in entry}
        self.include = self.output / "include"
        extracted: dict[str, str] = {}

        def relative_header(name: str) -> PurePosixPath:
            relative = PurePosixPath(name[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(f"Unexpected SDK header path: {name}")
            return relative

        def copy_header(name: str, data: bytes) -> None:
            if name not in expected or name in extracted:
                raise ValueError(f"Unexpected or duplicate SDK header: {name}")
            if digest(data) != expected[name]:
                raise ValueError(f"SDK header hash mismatch: {name}")
            target = self.include.joinpath(*relative_header(name).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            extracted[name] = digest(data)

        archive_sha = None
        if self.args.sdk_headers is not None:
            # Copy only manifest-listed, hash-verified headers into the isolated
            # include directory; unverified extra input files cannot affect builds.
            for name in expected:
                path = self.args.sdk_headers.joinpath(*relative_header(name).parts)
                copy_header(name, path.read_bytes())
        else:
            archive_path = ROOT / "BuildInputs" / metadata["archive"]
            archive_sha = file_digest(archive_path)
            if archive_sha != metadata["sha256"]:
                raise ValueError("Pinned native SDK archive hash mismatch")
            with tarfile.open(archive_path) as archive:
                for member in archive:
                    if not member.name.startswith(prefix) or member.isdir():
                        continue
                    if not member.isfile():
                        raise ValueError(f"Unexpected SDK header member: {member.name}")
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ValueError(f"Missing SDK header data: {member.name}")
                    copy_header(member.name, stream.read())
        if extracted != expected:
            raise ValueError("Pinned FFmpeg header inventory mismatch")
        self.report["sdk"] = {
            "header_source": "preextracted" if self.args.sdk_headers is not None else "archive",
            "archive_sha256": archive_sha,
            "expected_archive_sha256": metadata["sha256"],
            "manifest_sha256": file_digest(metadata_path),
            "header_count": len(extracted),
            "header_inventory_sha256": digest(json.dumps(extracted, sort_keys=True).encode()),
            "libraries_loaded": False,
        }

    def build(self, configuration: str, flags: list[str]) -> Path:
        directory = self.output / configuration
        directory.mkdir()
        objects = []
        # Separate translation units and no LTO prevent callers from specializing
        # conversion away using known fixture dimensions, palettes or repetitions.
        names = ["baseline", "candidate", "Harness"]
        if configuration == "sanitized":
            names.append("SanitizerOptions")
        for name in names:
            target = directory / f"{name}.o"
            self.command([self.cc, *COMMON_FLAGS, *flags, "-I", str(self.include),
                          "-c", str(self.sources / f"{name}.c"), "-o", str(target)])
            objects.append(str(target))
        executable = directory / "palette-benchmark"
        self.command([self.cc, *COMMON_FLAGS, *flags, *objects, "-o", str(executable)])
        return executable

    def check_sanitizer_control(self, env: dict) -> None:
        probe = self.sources / "SanitizerControl.c"
        probe.write_text(
            '#include <stdint.h>\n#include <stdlib.h>\n'
            'int main(void) {\n'
            '    volatile size_t index = 16;\n'
            '    volatile uint8_t *bytes = malloc(8);\n'
            '    if (!bytes) return 2;\n'
            '    bytes[index] = 42;\n'
            '    free((void *)bytes);\n'
            '    return 0;\n}\n')
        executable = self.output / "sanitized" / "address-negative-control"
        self.command([self.cc, *COMMON_FLAGS, "-O1", "-g", "-fsanitize=address",
                      "-fno-sanitize-recover=all", str(probe),
                      str(self.sources / "SanitizerOptions.c"), "-o", str(executable)])
        self.command([str(executable)], env=env, allow_failure=True)
        result = self.commands[-1]
        if result["returncode"] == 0 or "AddressSanitizer: heap-buffer-overflow" not in result["stderr"]:
            raise ValueError("ASan did not reject the deliberate heap bounds violation")
        self.report["sanitizer_negative_control"] = {
            "status": "passed", "expected_failure_exit_code": result["returncode"],
            "detected": "heap-buffer-overflow", "source_sha256": file_digest(probe)}

    def verify(self, executable: Path, configuration: str, env: dict | None = None) -> None:
        result = json.loads(self.command([str(executable), "verify"], env=env))
        if result.get("status") != "passed":
            raise ValueError(f"Verification did not pass: {result}")
        self.report["verification"][configuration] = result
        self.save()
        print(f"{configuration}: {json.dumps(result, sort_keys=True)}", flush=True)

    def measure(self, executable: Path, variant: str, case: str, iterations: int) -> dict:
        row = json.loads(self.command([str(executable), "measure", variant, case, str(iterations)]))
        if (row["variant"], row["case"], row["iterations"]) != (variant, case, iterations):
            raise ValueError("Measurement identity mismatch")
        for key in ("wall_ns", "cpu_ns"):
            if row[key] <= 0:
                raise ValueError(f"Nonpositive measurement: {key}")
        return row

    def run(self) -> None:
        debug = self.build("debug", ["-O0", "-g"])
        self.verify(debug, "debug")
        release = self.build("release", ["-O3"])
        self.verify(release, "release")
        sanitized = self.build("sanitized", ["-O1", "-g", "-fno-omit-frame-pointer",
                                              "-fsanitize=address,undefined",
                                              "-fno-sanitize-recover=all"])
        sanitizer_env = self.env | {
            # LeakSanitizer requires /proc task enumeration unavailable in the
            # sandbox. Address bounds and undefined-behavior checks remain on.
            "ASAN_OPTIONS": "detect_leaks=0:halt_on_error=1",
            "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=0",
        }
        self.report["sanitizer_environment"] = {
            key: sanitizer_env[key] for key in ("ASAN_OPTIONS", "UBSAN_OPTIONS")}
        self.verify(sanitized, "address_and_undefined_behavior", sanitizer_env)
        self.check_sanitizer_control(sanitizer_env)
        cases = json.loads(self.command([str(release), "list"]))
        if len({case["name"] for case in cases}) != len(cases):
            raise ValueError("Duplicate benchmark case names")
        self.report["cases"] = cases
        if self.args.verify_only:
            self.save()
            return

        for case in cases:
            name = case["name"]
            # Calibrate to reduce clock granularity effects on tiny controls.
            # Identical iteration counts are then held for each A/B pair.
            count = 8
            while True:
                sample = self.measure(release, "baseline", name, count)
                self.report["calibration"].append(sample)
                if sample["wall_ns"] >= 5_000_000 or count >= MAX_ITERATIONS:
                    break
                count = min(MAX_ITERATIONS, count * 10)
            iterations = min(MAX_ITERATIONS, max(8, math.ceil(
                count * self.args.target_ms * 1_000_000 / sample["wall_ns"] / 8) * 8))
            paired = []
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                pair_rows = {}
                for position, variant in enumerate(order):
                    row = self.measure(release, variant, name, iterations)
                    row.update(pair=pair, process_position=position)
                    pair_rows[variant] = row
                    self.report["measurements"].append(row)
                before, after = pair_rows["baseline"], pair_rows["candidate"]
                if before["checksum"] != after["checksum"] or before["receipt"] != after["receipt"]:
                    raise ValueError(f"Timed output mismatch for {name}, pair {pair}")
                paired.append(pair_rows)
                self.save()
            summary = {"case": name, "iterations": iterations}
            for clock in ("wall", "cpu"):
                field = f"{clock}_ns"
                for variant in ("baseline", "candidate"):
                    values = [pair[variant][field] / iterations for pair in paired]
                    summary[f"{variant}_{clock}_ns_median"] = statistics.median(values)
                    summary[f"{variant}_{clock}_ns_range"] = [min(values), max(values)]
                ratios = [pair["candidate"][field] / pair["baseline"][field] for pair in paired]
                ratio = statistics.median(ratios)
                summary[f"{clock}_median_paired_ratio"] = ratio
                summary[f"{clock}_reduction_percent"] = 100 * (1 - ratio)
            self.report["summary"].append(summary)
            self.save()
            print(json.dumps(summary, sort_keys=True), flush=True)

    def save(self) -> None:
        self.report["commands"] = self.commands
        write_json(self.output / "results.json", self.report)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new directory for immutable run evidence")
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--baseline", choices=BASELINES, default="scalar",
                        help="frozen implementation to compare with the working tree")
    parser.add_argument("--sdk-headers", type=Path,
                        help="pre-extracted FFmpeg include directory; all pinned hashes are checked")
    parser.add_argument("--pairs", type=paired_count, default=8)
    parser.add_argument("--target-ms", type=positive_float, default=80)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    experiment = Experiment(args)
    try:
        experiment.run()
    finally:
        experiment.save()


if __name__ == "__main__":
    main()
