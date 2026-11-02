#!/usr/bin/env python3
"""Run the unchanged conversion driver against previously built exact modules.

This measures warm complete conversion throughput, not fresh-conversion RSS.
Module compilation is not repeated; source/module/library hashes tie this run to
its original gated fresh-process measurement cohort.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
OUTPUT = Path(__file__).resolve().parent
RESEARCH = OUTPUT.parents[1]
ROOT = RESEARCH / "illiquid"
MODULES = OUTPUT.parent / "gated-measurement"
COMPILER = Path("/workspace/scratch/494ddb3d3326/swift-toolchain/usr/bin/swiftc")
DRIVER = ROOT / "Benchmarks/ExternalSubtitleConversion/Driver.swift"
RUNNER = ROOT / "Benchmarks/ExternalSubtitleConversion/run.py"
os.environ["TMPDIR"] = str(RESEARCH / "tmp")
os.environ["XDG_CACHE_HOME"] = str(RESEARCH / "cache")
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
for name in ("tmp", "cache"):
    (RESEARCH / name).mkdir(exist_ok=True)

def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

spec = importlib.util.spec_from_file_location("subtitle_conversion_runner", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
shutil.copyfile(RUNNER, OUTPUT / "runner.snapshot.py")
shutil.copyfile(DRIVER, OUTPUT / "Driver.swift")
original_manifest = json.loads((MODULES / "manifest.json").read_text())
flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
         "-module-cache-path", str(OUTPUT / "module-cache")]
manifest = {
    "created_utc": datetime.now(timezone.utc).isoformat(),
    "scope": "Warm complete conversion throughput with exact differential parity; not RSS",
    "platform": platform.platform(), "machine": platform.machine(),
    "compiler_path": str(COMPILER), "compiler_sha256": digest(COMPILER),
    "compiler": runner.command([str(COMPILER), "--version"], OUTPUT / "compiler.log", OUTPUT).strip(),
    "driver_sha256": digest(DRIVER), "runner_sha256": digest(RUNNER),
    "adapter_sha256": digest(__file__), "flags": flags,
    "module_build_manifest": original_manifest,
    "module_build_manifest_sha256": digest(MODULES / "manifest.json"),
    "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
    "variants": {},
}
binaries = {}
for variant in ("baseline", "candidate"):
    folder = OUTPUT / variant
    folder.mkdir()
    module_folder = MODULES / variant
    source = module_folder / "ExternalTextSubtitleConverter.swift"
    library = module_folder / "libIlliquidNativePlayback.so"
    module = module_folder / "IlliquidNativePlayback.swiftmodule"
    expected = original_manifest["variants"][variant]
    for path, key in ((source, "source_sha256"), (library, "library_sha256"), (module, "module_sha256")):
        if digest(path) != expected[key]:
            raise ValueError(f"Previously built {variant} {key} differs from its manifest")
    shutil.copyfile(source, folder / source.name)
    binary = folder / "converter-common-control"
    command = [str(COMPILER), *flags, "-parse-as-library", "-I", str(module_folder), "-L", str(module_folder),
               "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", str(module_folder),
               str(OUTPUT / "Driver.swift"), "-o", str(binary)]
    runner.command(command, folder / "build-driver.log", OUTPUT)
    manifest["variants"][variant] = {
        "source_sha256": digest(source), "library_sha256": digest(library),
        "module_sha256": digest(module), "binary_sha256": digest(binary),
        "module_folder": str(module_folder), "driver_command": command,
    }
    binaries[variant] = binary
runner.write_json(OUTPUT / "manifest.json", manifest)
verified = runner.verify(binaries, OUTPUT)
args = argparse.Namespace(case=["vtt-2000-plain", "vtt-10000-plain", "vtt-2000-multilingual", "srt-2000-plain"],
                          rounds=8, target_ms=200.0)
runner.benchmark(args, OUTPUT, binaries, verified)
