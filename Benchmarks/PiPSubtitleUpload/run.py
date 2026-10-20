#!/usr/bin/env python3
"""Compare exact PiP upload source on native Metal; no player or media is opened."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
COMPOSITOR = Path("Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift")
HELPER = Path("Sources/IlliquidNativePlayback/Presentation/PiPSubtitleUploadCache.swift")
TYPES = Path("Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift")
SHADER = Path("Sources/IlliquidNativePlayback/Resources/NativePlaybackShaders.metal")
DECLARATIONS = ("SubtitleCompositionStrategy", "ASSAtlasQuad", "ASSCompositionMetrics", "ASSPreparedSubtitleFrame")
WORKLOADS = [f"r8-{size}-{mode}" for size in ("64k", "1m", "4m") for mode in ("static", "changing")]
WORKLOADS += [f"bgra-1m-{mode}" for mode in ("static", "changing")]
MODULE = "PiPSubtitleUploadQualification"


def sha(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def block(source: str, anchor: str) -> str:
    """Extract one known balanced Swift declaration, retaining original bytes."""
    if source.count(anchor) != 1:
        raise ValueError(f"Expected exactly one source anchor: {anchor!r}")
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 1
    for offset in range(opening + 1, len(source)):
        depth += (source[offset] == "{") - (source[offset] == "}")
        if depth == 0:
            return source[start:offset + 1]
    raise ValueError(f"Unterminated source declaration: {anchor}")


def baseline_adapter(source: str) -> tuple[str, dict]:
    method = block(source, "    private func encodeSubtitles(")
    start = "        let textureWidth = Int(frame.textureSize.width)\n"
    end = "        let subtitlePass = MTLRenderPassDescriptor()\n"
    if method.count(start) != 1 or method.count(end) != 1:
        raise ValueError("Original upload extraction boundary changed")
    upload = method[method.index(start):method.index(end)]
    vertices = block(source, "    private func subtitleVertices(")
    vertex = block(source, "    private struct SubtitleVertex {")
    fields = """    private let device: any MTLDevice
    private var subtitleTexture: (any MTLTexture)?
    private var subtitleVertexBuffer: (any MTLBuffer)?
    private var subtitleVertexCapacity = 0
"""
    for line in fields.splitlines():
        if line not in source:
            raise ValueError(f"Baseline resource field changed: {line}")
    adapter = """import Foundation
import Metal

final class PiPSubtitleUploadCache {
    struct Upload {
        let texture: any MTLTexture
        let vertexBuffer: any MTLBuffer
        let vertexCount: Int
        let didUpload: Bool
        let textureUploadBytes: Int
        let vertexUploadBytes: Int
    }
""" + vertex + "\n" + fields + """
    init(device: any MTLDevice) { self.device = device }
    func invalidate() {}
    func retireSource() {
        subtitleTexture = nil
        subtitleVertexBuffer = nil
        subtitleVertexCapacity = 0
    }

    func resources(for frame: ASSPreparedSubtitleFrame) throws -> Upload {
        var result: Upload?
        // The immediately invoked Void closure preserves the original empty-
        // frame return verbatim. It adds no replacement upload implementation.
        try { () throws -> Void in
""" + upload + """        result = Upload(
            texture: subtitleTexture, vertexBuffer: subtitleVertexBuffer,
            vertexCount: vertices.count, didUpload: true,
            textureUploadBytes: textureWidth * textureHeight * (pixelFormat == .bgra8Unorm ? 4 : 1),
            vertexUploadBytes: requiredBytes
        )
        }()
        guard let result else { throw PiPSubtitleCompositorError.textureCreation }
        return result
    }

""" + vertices + "\n}\n"
    if upload not in adapter or vertices not in adapter or vertex not in adapter:
        raise ValueError("Baseline adapter changed extracted source bytes")
    return adapter, {
        "upload_block_sha256": sha(upload), "subtitle_vertices_sha256": sha(vertices),
        "vertex_declaration_sha256": sha(vertex),
        "adaptation": "Original Void upload block is inside an immediately invoked throwing closure; returned resources/counters are appended. Baseline invalidation is a no-op because the original always uploads.",
    }


class Run:
    def __init__(self, output: Path):
        self.output = output
        self.sequence = 0

    def command(self, args: list[str | Path], *, timeout: int = 240) -> str:
        command = [str(value) for value in args]
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"ordinal": self.sequence, "command": command,
                                  "elapsed_seconds": time.monotonic() - started,
                                  "returncode": result.returncode, "stdout": result.stdout,
                                  "stderr": result.stderr}, sort_keys=True) + "\n")
        self.sequence += 1
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n{result.stderr[-8000:]}")
        return result.stdout

    def prepare(self, *, compile_binaries: bool = True) -> tuple[dict[str, Path], Path, dict]:
        baseline_source = self.command(["git", "show", f"{BASELINE}:{COMPOSITOR}"])
        old_types = self.command(["git", "show", f"{BASELINE}:{TYPES}"])
        current_types = (ROOT / TYPES).read_text()
        declarations = []
        hashes = {}
        for name in DECLARATIONS:
            anchor = ("enum " if name == "SubtitleCompositionStrategy" else "struct ") + name + ":"
            old = block(old_types, anchor)
            current = block(current_types, anchor)
            if old != current:
                raise ValueError(f"Shared type changed since pinned baseline: {name}")
            declarations.append(current)
            hashes[name] = sha(current)
        shared = "import CoreGraphics\nimport Foundation\nimport Metal\n\n" + "\n\n".join(declarations) + "\n"
        errors = "enum PiPSubtitleCompositorError: Error { case textureCreation, commandEncoding }\n"
        candidate = (ROOT / HELPER).read_bytes()
        baseline, extraction = baseline_adapter(baseline_source)
        shader_source = (ROOT / SHADER).read_text()
        old_shader = self.command(["git", "show", f"{BASELINE}:{SHADER}"])
        begin, end = "struct PiPSubtitleVertex {", "// HDR PiP works in display-linear RGB"
        if shader_source.count(begin) != 1 or shader_source.count(end) != 1:
            raise ValueError("Subtitle shader extraction anchors changed")
        shader = shader_source[shader_source.index(begin):shader_source.index(end)]
        old_excerpt = old_shader[old_shader.index(begin):old_shader.index(end)]
        if shader != old_excerpt:
            raise ValueError("PiP subtitle shaders changed since baseline")
        shader_path = self.output / "PiPSubtitleShaders.metal"
        shader_path.write_text("#include <metal_stdlib>\nusing namespace metal;\n\n" + shader)
        binaries = {}
        receipt = {
            "baseline_revision": BASELINE, "baseline_source_sha256": sha(baseline_source),
            "candidate_helper_sha256": sha(candidate), "shared_declarations": hashes,
            "shared_types_sha256": sha(shared), "baseline_extraction": extraction,
            "shader_excerpt_sha256": sha(shader), "shader_generated_sha256": sha(shader_path.read_bytes()),
            "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
            "runner_sha256": sha(Path(__file__).read_bytes()), "builds": {},
        }
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
                 "-target", f"{platform.machine()}-apple-macosx26.0", "-module-cache-path", str(self.output / "module-cache")]
        for variant, source in (("baseline", baseline.encode()), ("candidate", candidate)):
            directory = self.output / variant
            directory.mkdir()
            (directory / "PiPSubtitleUploadCache.swift").write_bytes(source)
            (directory / "SharedTypes.swift").write_text(shared)
            (directory / "Errors.swift").write_text(errors)
            (directory / "Variant.swift").write_text(f'let benchmarkVariant = "{variant}"\n')
            if not compile_binaries:
                receipt["builds"][variant] = {"compiled": False, "upload_source_sha256": sha(source)}
                continue
            library = directory / f"lib{MODULE}.dylib"
            module_command = ["xcrun", "swiftc", *flags, "-emit-library", "-emit-module", "-enable-testing",
                              "-module-name", MODULE, "-emit-module-path", directory / f"{MODULE}.swiftmodule",
                              directory / "PiPSubtitleUploadCache.swift", directory / "SharedTypes.swift",
                              directory / "Errors.swift", "-o", library]
            self.command(module_command)
            binary = directory / "pip-subtitle-upload"
            driver_command = ["xcrun", "swiftc", *flags, "-parse-as-library", "-I", directory, "-L", directory,
                              f"-l{MODULE}", "-Xlinker", "-rpath", "-Xlinker", directory,
                              HERE / "Harness.swift", directory / "Variant.swift", "-o", binary]
            self.command(driver_command)
            binaries[variant] = binary
            receipt["builds"][variant] = {
                "module_command": [str(value) for value in module_command],
                "driver_command": [str(value) for value in driver_command],
                "upload_source_sha256": sha(source), "library_sha256": sha(library.read_bytes()),
                "binary_sha256": sha(binary.read_bytes()),
            }
        write_json(self.output / "source-receipt.json", receipt)
        return binaries, shader_path, receipt


def validate_measurement(row: dict, variant: str, workload: str, count: int) -> None:
    if row.get("variant") != variant or row.get("workload") != workload or row.get("iterations") != count:
        raise ValueError("Measurement identity differs")
    for key in ("cpu_ns", "wall_ns"):
        if type(row.get(key)) is not int or row[key] <= 0:
            raise ValueError(f"Invalid timing field: {key}")
    expected_uploads = count if variant == "baseline" or workload.endswith("changing") else 0
    if row["uploads"] != expected_uploads or row["texture_upload_bytes"] != expected_uploads * row["atlas_bytes"]:
        raise ValueError("Measured upload counters differ")
    if row["timed_draw_calls"] != 0:
        raise ValueError("Drawing unexpectedly entered upload timing")


def summarize(rows: list[dict]) -> list[dict]:
    summaries = []
    for workload in WORKLOADS:
        selected = [row for row in rows if row["workload"] == workload]
        entry = {"workload": workload, "variants": {}, "paired_ratios": {}}
        for variant in ("baseline", "candidate"):
            samples = [row for row in selected if row["variant"] == variant]
            value = {"samples": len(samples), "iterations_per_process": samples[0]["iterations"]}
            for metric in ("cpu_ns", "wall_ns"):
                values = [row[metric] / row["iterations"] for row in samples]
                value[metric + "_per_call"] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
            value["uploads_per_call"] = samples[0]["uploads"] / samples[0]["iterations"]
            value["texture_upload_bytes_per_call"] = samples[0]["texture_upload_bytes"] / samples[0]["iterations"]
            entry["variants"][variant] = value
        for metric in ("cpu_ns", "wall_ns"):
            ratios = []
            for round_index in sorted({row["round"] for row in selected}):
                pair = {row["variant"]: row for row in selected if row["round"] == round_index}
                a, b = pair["baseline"], pair["candidate"]
                for key in ("active_pixels_sha256", "vertex_bytes_sha256", "vertex_count", "atlas_bytes"):
                    if a[key] != b[key]:
                        raise ValueError(f"Timed output differs: {workload} / {key}")
                ratios.append((b[metric] / b["iterations"]) / (a[metric] / a["iterations"]))
            before = entry["variants"]["baseline"][metric + "_per_call"]["median"]
            after = entry["variants"]["candidate"][metric + "_per_call"]["median"]
            entry[metric + "_change_percent"] = 100 * (after / before - 1)
            entry["paired_ratios"][metric] = ratios
        summaries.append(entry)
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=7, help="AB+BA pairs per workload (two observations per variant per pair)")
    parser.add_argument("--target-ms", type=float, default=80)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--prepare-only", action="store_true", help="extract and hash sources without compiling or claiming native validation")
    args = parser.parse_args()
    if platform.system() != "Darwin" and not args.prepare_only:
        parser.error("Native macOS Metal is required; no Linux emulation or accepted Linux timing")
    if not 1 <= args.pairs <= 20 or not 10 <= args.target_ms <= 500:
        parser.error("pairs must be 1...20 and target-ms must be 10...500")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be new or empty; previous evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    run = Run(output)
    if args.prepare_only:
        run.prepare(compile_binaries=False)
        print(f"Prepared exact baseline/candidate sources: {output}; native build and validation not run")
        return
    environment = {
        "platform": platform.platform(), "architecture": platform.machine(),
        "compiler": run.command(["xcrun", "swiftc", "--version"]),
        "xcode": run.command(["xcodebuild", "-version"]),
        "hardware": run.command(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"]),
        "head": run.command(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree_status": run.command(["git", "status", "--short"]),
        "pairs": args.pairs, "target_ms": args.target_ms, "workloads": WORKLOADS,
        "iteration_policy": "Fixed independently per variant/workload after CPU-time calibration, always even; results normalized by calls. Calibration excluded.",
        "scope": "Exact native Metal upload-resource component calls with counters. Static captions primed outside timing; changed captions invalidate each call. No timed GPU draw, video decode, GUI, app memory, or energy measurement.",
    }
    write_json(output / "environment.json", environment)
    binaries, shader, receipt = run.prepare()
    verification = {}
    for variant, binary in binaries.items():
        verification[variant] = json.loads(run.command([binary, "verify", shader]))
        write_json(output / f"verification-{variant}.json", verification[variant])
    if verification["baseline"]["semantic"] != verification["candidate"]["semantic"]:
        raise ValueError("Baseline/candidate resource bytes or rendered pixels differ; inspect verification files")
    if verification["baseline"]["device"] != verification["candidate"]["device"]:
        raise ValueError("Metal device changed between variants")
    write_json(output / "verification.json", {
        "exact_texture_vertex_and_render_equality": True,
        "steps": verification["candidate"]["steps"],
        "rendered_draw_calls_per_variant": verification["candidate"]["rendered_draw_calls"],
        "device": verification["candidate"]["device"],
    })
    print(f"Verified {verification['candidate']['steps']} transitions and exact native rendered output", flush=True)
    if args.verify_only:
        return
    counts = {}
    calibration = []
    for workload in WORKLOADS:
        counts[workload] = {}
        for variant, binary in binaries.items():
            count = 128
            for attempt in range(4):
                row = json.loads(run.command([binary, "benchmark", workload, count]))
                validate_measurement(row, variant, workload, count)
                row.update(attempt=attempt)
                calibration.append(row)
                write_json(output / "calibration.json", calibration)
                if row["cpu_ns"] >= args.target_ms * 1_000_000 * 0.8 or count == 20_000_000:
                    break
                requested = math.ceil(count * args.target_ms * 1_000_000 / row["cpu_ns"])
                count = min(20_000_000, max(count * 2, requested + requested % 2))
            counts[workload][variant] = count
    write_json(output / "iteration-counts.json", counts)
    rows = []
    for round_index in range(args.pairs * 2):
        # Rotate workload order and balance variant order separately for every workload.
        rotation = round_index % len(WORKLOADS)
        for workload in WORKLOADS[rotation:] + WORKLOADS[:rotation]:
            order = ("baseline", "candidate") if round_index % 2 == 0 else ("candidate", "baseline")
            for position, variant in enumerate(order):
                count = counts[workload][variant]
                row = json.loads(run.command([binaries[variant], "benchmark", workload, count]))
                validate_measurement(row, variant, workload, count)
                if row["device"] != verification["candidate"]["device"]:
                    raise ValueError("Metal device changed during timings")
                row.update(round=round_index, order=position, ordinal=len(rows))
                rows.append(row)
                with (output / "measurements.jsonl").open("a") as log:
                    log.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Completed native timing round {round_index + 1}/{args.pairs * 2}", flush=True)
    expected_rows = len(WORKLOADS) * args.pairs * 4
    if len(rows) != expected_rows or len({(r["round"], r["workload"], r["variant"]) for r in rows}) != expected_rows:
        raise ValueError("Incomplete or duplicate measurement cohort")
    for row in rows:
        expected = ("baseline", "candidate") if row["round"] % 2 == 0 else ("candidate", "baseline")
        if row["variant"] != expected[row["order"]]:
            raise ValueError("Unbalanced measurement order")
    if sha((ROOT / HELPER).read_bytes()) != receipt["candidate_helper_sha256"] or sha((HERE / "Harness.swift").read_bytes()) != receipt["harness_sha256"]:
        raise ValueError("Candidate or harness changed during the native run")
    summary = summarize(rows)
    write_json(output / "summary.json", summary)
    write_json(output / "validation.json", {"completed": True, "rows": len(rows), "balanced_order": True,
                                            "resource_and_render_equality": True,
                                            "minimum_process_cpu_ms": min(r["cpu_ns"] for r in rows) / 1_000_000})
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
