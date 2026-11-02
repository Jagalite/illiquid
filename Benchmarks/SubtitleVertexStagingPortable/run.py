#!/usr/bin/env python3
"""Portable CPU proxy for subtitle vertex staging; this does not exercise Metal."""
from __future__ import annotations

import os
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NATIVE = ROOT / "Benchmarks/SubtitleVertexStaging"
SHIM = HERE / "MetalCPUProxy.swift"
WORKFLOW = ROOT / ".github/workflows/subtitle-vertex-staging-portable.yml"
NATIVE_RUNNER = NATIVE / "run.py"


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise RuntimeError(f"Expected exactly one native-runner anchor: {before!r}")
    return source.replace(before, after, 1)


# Reuse the complete paired protocol and validation. Only host eligibility,
# hardware reporting and the platform's library suffix change in this runner.
native_source = NATIVE_RUNNER.read_text()
adapted_runner = replace_once(native_source, 'if sys.platform != "darwin" or',
                              'if sys.platform != "linux" or')
adapted_runner = replace_once(
    adapted_runner,
    'parser.error("Requires macOS, an even pair count >= 2, and a positive target duration")',
    'parser.error("Requires Linux, an even pair count >= 2, and a positive target duration")',
)
adapted_runner = replace_once(
    adapted_runner,
    '"hardware": command(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip(),',
    '"hardware": command(["uname", "-a"], output).strip(),',
)
adapted_runner = replace_once(adapted_runner, 'path.suffix == ".dylib"', 'path.suffix == ".so"')
native = types.ModuleType("subtitle_vertex_staging_shared")
native.__file__ = str(NATIVE_RUNNER)
exec(compile(adapted_runner, str(NATIVE_RUNNER), "exec"), native.__dict__)
native.__doc__ = __doc__


def portable_imports(source: str) -> str:
    removed = {"import CoreGraphics", "import Metal", "import QuartzCore", "import Synchronization"}
    lines = [line for line in source.splitlines() if line not in removed]
    if "import Foundation" not in lines:
        lines.insert(0, "import Foundation")
    return "\n".join(lines) + "\n"


driver_source = portable_imports((NATIVE / "Harness.swift").read_text())
original_write_json = native.write_json


def write_json(path: Path, value: object) -> None:
    if path.name == "manifest.json":
        value = dict(value)
        value["qualification_scope"] = "portable CPU proxy; no native Metal or GPU qualification"
        value["sources"] = dict(value["sources"])
        value["sources"].update({
            str(path.relative_to(ROOT)): native.digest(path.read_bytes())
            for path in (Path(__file__).resolve(), SHIM, WORKFLOW)
        })
        value["portable_transform"] = {
            "shared_runner_original_sha256": native.digest(native_source),
            "shared_runner_adapted_sha256": native.digest(adapted_runner),
            "driver_original_sha256": native.digest((NATIVE / "Harness.swift").read_bytes()),
            "driver_portable_sha256": native.digest(driver_source),
            "swift_changes": "Remove CoreGraphics/Metal/QuartzCore/Synchronization imports; "
                             "supply Foundation where needed. All production method bodies, "
                             "writer statements, tests and benchmark driver statements are unchanged.",
            "runner_changes": "Linux eligibility, uname hardware record, .so suffix; "
                              "portable source/build/test adapters and truthful manifest labels.",
            "address_sanitizer_scope": "Address/bounds checks; ASAN_OPTIONS detect_leaks=0. "
                                       "LeakSanitizer is not qualification of this proxy.",
        }
        value["extraction"] = (
            "Exact native-runner extraction of original Vertex/FrameResources/makeVertices/"
            "uploadVertices, or candidate FrameResources/uploadVertices plus the complete writer. "
            "Import-only Swift transformations. Metal-named stand-ins use aligned raw memory and "
            "plain Swift texture dimensions. No Metal API, GPU, encoder or shader is exercised."
        )
        value["method"] = (
            "Portable CPU proxy, separate optimized Swift modules, raw-memory buffer reuse. "
            "Native paired protocol and driver preserved: warm capacity, same-iteration fresh-process "
            "AB/BA pairs, complete field/Float-bit receipts and consumed checksums, no discarded "
            "samples or control subtraction. Proxy timings do not predict native Metal performance."
        )
    original_write_json(path, value)


def prepare_sources(variant: str, destination: Path, output: Path) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    baseline = (NATIVE / "baseline/MetalASSSubtitleCompositor.swift").read_text()
    candidate = native.COMPOSITOR.read_text()
    if native.shared_types(baseline) != native.shared_types(candidate):
        raise RuntimeError("Shared renderer types differ from the frozen baseline")
    source = baseline if variant == "baseline" else candidate
    files = {
        "Types.swift": portable_imports(native.shared_types(source)),
        "Adapter.swift": portable_imports(native.adapter(source, variant)),
        "MetalCPUProxy.swift": SHIM.read_text(),
    }
    if variant == "candidate":
        files["ASSSubtitleVertexWriter.swift"] = portable_imports(native.WRITER.read_text())
    paths = []
    for name, content in files.items():
        path = destination / name
        path.write_text(content)
        paths.append(path)
    native.write_json(output / f"{destination.parent.name}-sources.json",
                      {name: {"sha256": native.digest(content), "content": content}
                       for name, content in files.items()})
    return paths


def build(variant: str, configuration: str, output: Path) -> Path:
    destination = output / "build" / f"{variant}-{configuration}"
    destination.mkdir(parents=True, exist_ok=True)
    sources = prepare_sources(variant, destination / "sources", output)
    driver = destination / "Harness.swift"
    driver.write_text(driver_source)
    native.write_json(output / "portable-driver-source.json",
                      {"sha256": native.digest(driver_source), "content": driver_source})
    flags = ["-swift-version", "6", "-warnings-as-errors",
             "-O" if configuration == "release" else "-Onone"]
    if configuration == "release":
        flags.append("-whole-module-optimization")
    library = destination / "libIlliquidNativePlayback.so"
    native.command(["swiftc", *flags, "-enable-testing", "-emit-library", "-emit-module",
                    "-module-name", "IlliquidNativePlayback", "-emit-module-path",
                    destination / "IlliquidNativePlayback.swiftmodule", *sources, "-o", library], output)
    executable = destination / "benchmark"
    native.command(["swiftc", *flags, "-parse-as-library", "-I", destination, "-L", destination,
                    "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", destination,
                    driver, "-o", executable], output)
    return executable


def unit_tests(output: Path) -> None:
    package = output / "build/writer-tests"
    source = package / "Sources/IlliquidNativePlayback"
    tests = package / "Tests/IlliquidNativePlaybackTests"
    source.mkdir(parents=True)
    tests.mkdir(parents=True)
    files = {
        "Types.swift": portable_imports(native.shared_types(native.COMPOSITOR.read_text())),
        native.WRITER.name: portable_imports(native.WRITER.read_text()),
        "MetalCPUProxy.swift": SHIM.read_text(),
    }
    for name, content in files.items():
        (source / name).write_text(content)
    portable_tests = portable_imports(native.TEST.read_text())
    (tests / native.TEST.name).write_text(portable_tests)
    native.write_json(output / "portable-unit-test-sources.json", {
        **{name: {"sha256": native.digest(content), "content": content}
           for name, content in files.items()},
        native.TEST.name: {"sha256": native.digest(portable_tests), "content": portable_tests},
    })
    (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleVertexStagingPortableTests",
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ])
""")
    for configuration in ("debug", "release"):
        log = native.command(["swift", "test", "--package-path", package, "--jobs", "2",
                              "--no-parallel", "-c", configuration,
                              "-Xswiftc", "-warnings-as-errors"], output, timeout=600)
        (output / f"writer-{configuration}-tests.log").write_text(log)
    # Swift Testing/runtime lifetime allocations are outside this writer's
    # address-safety check. Disable only leak detection, not ASan memory checks.
    previous = os.environ.get("ASAN_OPTIONS")
    options = [part for part in (previous or "").split(":")
               if part and not part.startswith("detect_leaks=")]
    os.environ["ASAN_OPTIONS"] = ":".join(options + ["detect_leaks=0"])
    try:
        log = native.command(["swift", "test", "--package-path", package, "--jobs", "2",
                              "--no-parallel", "--sanitize", "address"], output, timeout=600)
        (output / "writer-address-sanitizer-tests.log").write_text(log)
    finally:
        if previous is None:
            os.environ.pop("ASAN_OPTIONS", None)
        else:
            os.environ["ASAN_OPTIONS"] = previous


native.write_json = write_json
native.prepare_sources = prepare_sources
native.build = build
native.unit_tests = unit_tests

if __name__ == "__main__":
    native.main()
