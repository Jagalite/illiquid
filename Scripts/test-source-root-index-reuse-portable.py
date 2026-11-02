#!/usr/bin/env python3
"""Verify source-root index reuse on Linux; never run performance measurements."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCHMARK = ROOT / "Benchmarks/SourceRootIndexReuse"
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ADAPTED_PATHS = {
    "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
    "Sources/IlliquidApp/Driver.swift",
    "Sources/CProbe/Probe.c",
}
PRODUCTION_DIFFERENCES = {
    "Sources/IlliquidApp/App/SourceRootIndex.swift",
    "Sources/IlliquidApp/Owner.swift",
}

LIFECYCLE_SHIM = """\
// Portable correctness verification only. Production signposts are disabled
// for the CLI bundle; this boundary removes the unavailable os.signpost module.
// This file is never used for performance or memory measurement.
public enum LifecyclePerformance {
    public static let isEnabled = false
    public static func begin(_ phase: String) -> UInt64 { 0 }
    public static func end(_ phase: String, since start: UInt64) {}
    public static func mark(_ phase: String) {}
}
"""

PROBE_SHIM = """\
/* Portable correctness verification only. No timing or memory values exist.
 * Accidental measurement aborts instead of returning misleading zero metrics.
 */
#include "Probe.h"
#include <errno.h>
#include <stdlib.h>

uint64_t probe_cpu_ns(void) { abort(); }
uint64_t probe_heap_in_use(void) { abort(); }
uint64_t probe_peak_rss_bytes(void) { abort(); }
int probe_start_sampling(void) { return ENOTSUP; }
void probe_stop_sampling(void) { abort(); }
uint64_t probe_sampled_peak_in_use(void) { abort(); }
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def inventory(directory: Path) -> dict:
    return {
        str(path.relative_to(directory)): {
            "sha256": digest(path.read_bytes()),
            "bytes": path.stat().st_size,
        }
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


def adapt(package: Path) -> list[dict]:
    changes = []

    def replace(relative: str, replacement: bytes, reason: str) -> None:
        path = package / relative
        original = path.read_bytes()
        path.write_bytes(replacement)
        changes.append({
            "path": relative,
            "before_sha256": digest(original),
            "after_sha256": digest(replacement),
            "reason": reason,
        })

    replace(
        "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
        LIFECYCLE_SHIM.encode(),
        "Disable only the unavailable os.signpost boundary. Production CLI "
        "signposts are already disabled; this does not qualify native logging.",
    )
    driver_path = "Sources/IlliquidApp/Driver.swift"
    driver = (package / driver_path).read_text()
    portable_driver, count = re.subn(
        r"(?m)^import Darwin$", "import Glibc", driver
    )
    if count != 1:
        raise RuntimeError("Expected exactly one standalone Darwin import")
    replace(
        driver_path,
        portable_driver.encode(),
        "Use Glibc's exit(1) instead of Darwin's exit(1); all verification "
        "and snapshot-comparison code remains unchanged.",
    )
    replace(
        "Sources/CProbe/Probe.c",
        PROBE_SHIM.encode(),
        "Native timing and memory probes are unavailable. Numeric access "
        "aborts, sampling start returns ENOTSUP, and only verify mode runs.",
    )
    return changes


class Commands:
    def __init__(self, output: Path) -> None:
        self.output = output
        self.count = 0
        self.env = os.environ.copy()
        cache = str(output / "module-cache")
        self.env.update({
            "CLANG_MODULE_CACHE_PATH": cache,
            "SWIFT_MODULECACHE_PATH": cache,
            "SWIFTPM_MODULECACHE_OVERRIDE": cache,
            "TERM": "dumb",
            "NO_COLOR": "1",
        })
        (output / "logs").mkdir()

    def run(
        self,
        arguments: list,
        label: str,
        *,
        allow_failure: bool = False,
        timeout: int = 900,
    ) -> tuple[dict, str]:
        self.count += 1
        command = [str(argument) for argument in arguments]
        started = time.monotonic()
        timed_out = False
        try:
            process = subprocess.run(
                command, cwd=ROOT, env=self.env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=timeout,
            )
            status, stdout = process.returncode, process.stdout
        except subprocess.TimeoutExpired as error:
            timed_out = True
            status = 124
            stdout = error.stdout or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            stdout += "\nPortable verification command timed out.\n"
        relative_log = f"logs/{self.count:03d}-{label}.log"
        log = self.output / relative_log
        log.write_text(stdout)
        receipt = {
            "command": command,
            "returncode": status,
            "timed_out": timed_out,
            "seconds": time.monotonic() - started,
            "log": relative_log,
            "log_sha256": digest(log.read_bytes()),
        }
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(receipt, sort_keys=True) + "\n")
        if status != 0 and not allow_failure:
            raise RuntimeError(
                f"{label} failed with status {status}; see {relative_log}\n"
                + stdout[-4000:]
            )
        return receipt, stdout


def swift_arguments(
    swift: str, operation: str, package: Path, configuration: str, output: Path
) -> list:
    return [
        swift, operation, "--package-path", package,
        "-c", configuration, "--jobs", "2",
        "--cache-path", output / "swiftpm-cache",
        "--config-path", output / "swiftpm-config",
        "--security-path", output / "swiftpm-security",
        "-Xswiftc", "-enable-testing", "-Xswiftc", "-warnings-as-errors",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("This adaptation is Linux-only; use the native runner on macOS")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Use a new, empty output directory")

    result = {
        "status": "running",
        "scope": "portable semantic verification only",
        "measurements_executed": False,
        "native_qualification": False,
        "output_directory": str(output),
    }
    manifest = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "script_sha256": digest(Path(__file__).read_bytes()),
        "harness_hashes": {
            str(path.relative_to(ROOT)): digest(path.read_bytes())
            for path in sorted(BENCHMARK.rglob("*"))
            if path.is_file() and path.suffix in {".py", ".swift", ".c", ".h"}
        },
        "variants": {},
    }
    commands = Commands(output)
    builds = []
    tests = []
    verifications = {}
    negative_control = None
    exit_status = 1
    try:
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        if kyoto.is_file():
            raise RuntimeError(
                "Kyoto is available; submit this verification through the "
                "shared queue before compiling."
            )
        print(
            "Kyoto is unavailable on this Linux runner; compiling serially "
            "in an isolated checkout. This is correctness verification only.",
            flush=True,
        )
        _, compiler = commands.run([args.swift, "--version"], "swift-version")
        version = re.search(r"\bSwift version (\d+)\.(\d+)", compiler)
        if not version or tuple(map(int, version.groups())) < (6, 1):
            raise RuntimeError("Swift 6.1 or newer is required")
        manifest["compiler"] = compiler.strip()
        _, baseline = commands.run(
            ["git", "rev-parse", "--verify", f"{args.baseline}^{{commit}}"],
            "baseline-revision",
        )
        baseline = baseline.strip()
        _, candidate_head = commands.run(
            ["git", "rev-parse", "HEAD"], "candidate-revision"
        )
        manifest.update(
            baseline_commit=baseline,
            candidate_head=candidate_head.strip(),
            candidate_sources="current worktree",
        )
        specification = importlib.util.spec_from_file_location(
            "illiquid_root_index_reuse_stage", BENCHMARK / "stage.py"
        )
        if specification is None or specification.loader is None:
            raise RuntimeError("Cannot load the existing benchmark staging helper")
        staging = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = staging
        specification.loader.exec_module(staging)

        packages = {}
        for variant in ("baseline", "candidate"):
            package = output / "packages" / variant
            revision = baseline if variant == "baseline" else None
            original_receipts = staging.stage(ROOT, package, revision)
            before = inventory(package)
            adaptations = adapt(package)
            after = inventory(package)
            if before.keys() != after.keys():
                raise RuntimeError("Platform adaptation added or removed staged files")
            changed = {path for path in before if before[path] != after[path]}
            if changed != ADAPTED_PATHS:
                raise RuntimeError(f"Unexpected platform adaptations: {sorted(changed)}")
            manifest["variants"][variant] = {
                "native_staging_receipts_before_adaptation": original_receipts,
                "native_staging_receipts_sha256": digest(
                    json.dumps(original_receipts, sort_keys=True).encode()
                ),
                "files_before_adaptation": before,
                "files_after_adaptation": after,
                "platform_adaptations": adaptations,
            }
            packages[variant] = package
            save(output / "source-manifest.json", manifest)

        baseline_files = manifest["variants"]["baseline"]["files_before_adaptation"]
        candidate_files = manifest["variants"]["candidate"]["files_before_adaptation"]
        source_differences = {
            path for path in baseline_files.keys() & candidate_files.keys()
            if path.startswith("Sources/")
            and baseline_files[path] != candidate_files[path]
        }
        if source_differences - PRODUCTION_DIFFERENCES:
            raise RuntimeError(
                "Unexpected baseline/candidate source differences: "
                + repr(sorted(source_differences - PRODUCTION_DIFFERENCES))
            )
        manifest["production_source_differences"] = sorted(source_differences)
        save(output / "source-manifest.json", manifest)

        binaries = {}
        for variant in ("baseline", "candidate"):
            package = packages[variant]
            for configuration in ("debug", "release"):
                print(f"Compile and verify {variant} {configuration}", flush=True)
                arguments = swift_arguments(
                    args.swift, "build", package, configuration, output
                )
                build, _ = commands.run(
                    [*arguments, "--product", "RootIndexBenchmark"],
                    f"build-{variant}-{configuration}",
                )
                _, location = commands.run(
                    [args.swift, "build", "--package-path", package,
                     "-c", configuration, "--show-bin-path"],
                    f"bin-path-{variant}-{configuration}",
                )
                binary = Path(location.strip()) / "RootIndexBenchmark"
                build.update(
                    variant=variant,
                    configuration=configuration,
                    binary_sha256=digest(binary.read_bytes()),
                )
                builds.append(build)
                verification_command, stdout = commands.run(
                    [binary, "verify", str(variant == "candidate").lower()],
                    f"verify-{variant}-{configuration}",
                )
                verification = json.loads(stdout)
                if (
                    not isinstance(verification.get("checks"), int)
                    or verification["checks"] < 15
                    or verification.get("observation_delivered") is not True
                    or "receipts" not in verification
                ):
                    raise RuntimeError("Expected owner verification cases did not execute")
                name = f"{variant}-{configuration}"
                verifications[name] = {
                    "command": verification_command,
                    "result": verification,
                }
                save(output / "verification.json", verifications)
                if configuration == "release":
                    binaries[variant] = binary

                if variant == "candidate":
                    test, stdout = commands.run(
                        [*swift_arguments(args.swift, "test", package,
                                          configuration, output), "--no-parallel"],
                        f"tests-{configuration}",
                    )
                    counts = re.findall(r"Test run with (\d+) tests?\b", stdout)
                    if not counts or int(counts[-1]) != 8:
                        raise RuntimeError("Expected all eight regression tests to execute")
                    test.update(configuration=configuration, test_count=int(counts[-1]))
                    tests.append(test)

        expected = verifications["baseline-release"]["result"]["receipts"]
        for name, verification in verifications.items():
            if verification["result"]["receipts"] != expected:
                raise RuntimeError(f"Full semantic receipts differ for {name}")
        negative_control, stdout = commands.run(
            [binaries["baseline"], "verify", "true"],
            "baseline-negative-control",
            allow_failure=True,
        )
        if (
            negative_control["returncode"] != 1
            or "ready visibility edit had unexpected invalidation behavior" not in stdout
        ):
            raise RuntimeError(
                "Baseline negative control did not reach the intended runtime assertion"
            )
        negative_control["intended_runtime_assertion_observed"] = True
        result.update(
            status="passed",
            full_receipts_equal=True,
            verification_checks={
                name: value["result"]["checks"]
                for name, value in verifications.items()
            },
            candidate_tests={test["configuration"]: test["test_count"] for test in tests},
            baseline_negative_control_passed=True,
        )
        exit_status = 0
    except Exception as error:
        result.update(status="failed", error=str(error))
    finally:
        save(output / "source-manifest.json", manifest)
        save(output / "builds.json", builds)
        save(output / "tests.json", tests)
        save(output / "verification.json", verifications)
        save(output / "negative-control.json", negative_control)
        result["commands_recorded"] = commands.count
        save(output / "result.json", result)
        print(
            "SOURCE_ROOT_INDEX_PORTABLE_RESULT="
            + json.dumps(result, sort_keys=True, separators=(",", ":")),
            flush=True,
        )
        print(f"Portable verification artifacts: {output}", flush=True)
    return exit_status


if __name__ == "__main__":
    raise SystemExit(main())
