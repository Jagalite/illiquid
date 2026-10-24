#!/usr/bin/env python3
"""Compare the exact static AppModel startup block in fresh component processes."""
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
MODEL = "Sources/IlliquidApp/App/AppModel.swift"
LOADER = "Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift"
URLS = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
PROBE = ROOT / "Benchmarks/RuntimeLeaseHistory/CLeaseHeap"

INSTANCE_STUB = """
    static var modelInitializations = 0
    let player: PlaybackController
    var sourceTabs: [SourceTab]
    var startupOpenDeliveries = 0
    struct PictureInPictureState { let isActive = false }
    struct State { let pictureInPicture = PictureInPictureState() }
    let state = State()
    init(player: PlaybackController, sources: SourceStartupSnapshot) {
        Self.modelInitializations += 1
        self.player = player
        sourceTabs = sources.tabs
    }
    func handleOpenURLs(_ urls: [URL]) { startupOpenDeliveries += urls.count }
    func reopenPlayerWindow() {}
    func shutdown() async {}
}
"""


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def bounded(source: bytes, start: bytes, end: bytes) -> bytes:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Production extraction boundary changed: {start!r} / {end!r}")
    first, last = source.index(start), source.index(end)
    if first >= last:
        raise ValueError("Production extraction boundaries reversed")
    return source[first:last]


def extracted(model: bytes) -> tuple[bytes, bytes]:
    startup = bounded(model, b"\n    private static var sharedInstance: AppModel?\n",
                      b"\n    let player: PlaybackController\n")
    types = bounded(model, b"struct SourceTabItem:", b"enum SourceTabItems {")
    return startup, types


def execute(argv: list[str | Path], output: Path, *, timeout: int = 180) -> str:
    command = [str(x) for x in argv]
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    env["SWIFT_MODULECACHE_PATH"] = str(output / "module-cache")
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=timeout)
    receipt = {
        "command": command, "exit_code": result.returncode,
        "elapsed_seconds": time.monotonic() - started,
        "stdout": result.stdout.decode(), "stderr": result.stderr.decode(),
    }
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps(receipt) + "\n")
    if result.returncode:
        raise RuntimeError(json.dumps(receipt, indent=2))
    return result.stdout.decode()


def source_at(ref: str | None, relative: str) -> bytes:
    if ref is None:
        return (ROOT / relative).read_bytes()
    return subprocess.check_output(["git", "show", f"{ref}:{relative}"], cwd=ROOT)


def prepare(args: argparse.Namespace) -> dict:
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Use a new empty output directory")
    baseline = subprocess.check_output(
        ["git", "rev-parse", f"{args.baseline}^{{commit}}"], cwd=ROOT, text=True).strip()
    manifest = {
        "baseline_commit": baseline,
        "candidate_head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "candidate_is_worktree_source": True,
        "platform": platform.platform(), "machine": platform.machine(),
        "python": platform.python_version(),
        "compiler": execute([args.swiftc, "--version"], args.output).strip(),
        "configuration": args.configuration,
        "pairs": args.pairs, "source_counts": args.counts,
        "runner_sha256": sha(Path(__file__).read_bytes()),
        "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
        "source_sha256": {}, "extracted_sha256": {}, "prepared_sha256": {},
        "scope": "exact static startup block and loader; fixture preference read and native graph stubs",
        "allocator_scope": "component-process allocator live bytes, including runtime allocations; not RSS",
        "ordering": "alternating AB/BA per count, fresh sequential processes",
    }
    snapshots = {}
    for variant, ref in [("baseline", baseline), ("candidate", None)]:
        production = {path: source_at(ref, path) for path in [MODEL, LOADER, URLS]}
        startup, types = extracted(production[MODEL])
        manifest["source_sha256"][variant] = {p: sha(v) for p, v in production.items()}
        manifest["extracted_sha256"][variant] = {"startup_block": sha(startup), "value_types": sha(types)}
        snapshots[variant] = production
        generated = {
            "AppModel.swift": b"import Foundation\n@MainActor\nfinal class AppModel {\n" + startup + INSTANCE_STUB.encode(),
            "SourceTypes.swift": b"import Foundation\n" + types,
            "ReadOnlyStartupLoader.swift": production[LOADER],
            "NormalizedFileURL.swift": production[URLS],
            "Harness.swift": (HERE / "Harness.swift").read_bytes(),
        }
        for name, raw in generated.items():
            path = args.output / variant / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
            manifest["prepared_sha256"][str(path.relative_to(args.output))] = sha(raw)
        # Keep the complete input source too; extraction can be independently audited.
        for relative, raw in production.items():
            path = args.output / "input" / variant / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
    for path in [LOADER, URLS]:
        if snapshots["baseline"][path] != snapshots["candidate"][path]:
            raise ValueError(f"Dependency differs between variants: {path}")
    if manifest["extracted_sha256"]["baseline"]["value_types"] != manifest["extracted_sha256"]["candidate"]["value_types"]:
        raise ValueError("Source value types differ between variants")
    for name in ["heap.c", "include/CLeaseHeap.h"]:
        raw = (PROBE / name).read_bytes()
        path = args.output / "CLeaseHeap" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        manifest["prepared_sha256"][str(path.relative_to(args.output))] = sha(raw)
    (args.output / "CLeaseHeap/module.modulemap").write_text(
        'module CLeaseHeap { header "include/CLeaseHeap.h" export * }\n')
    write_json(args.output / "manifest.json", manifest)
    return manifest


def compile_variants(args: argparse.Namespace, manifest: dict) -> dict[str, Path]:
    object_path = args.output / "heap.o"
    execute([args.clang, "-O2", "-I", args.output / "CLeaseHeap/include", "-c",
             args.output / "CLeaseHeap/heap.c", "-o", object_path], args.output)
    binaries = {}
    for variant in ["baseline", "candidate"]:
        binary = args.output / variant / "StartupSnapshotLifetime"
        flags = ["-O", "-whole-module-optimization"] if args.configuration == "release" else ["-Onone", "-g"]
        target = ["-target", f"{platform.machine()}-apple-macos26.0"] if platform.system() == "Darwin" else []
        execute([args.swiftc, "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                 *flags, *target, "-module-name", "StartupSnapshotLifetime", "-I", args.output / "CLeaseHeap",
                 "-module-cache-path", args.output / "module-cache",
                 *sorted((args.output / variant).glob("*.swift")), object_path, "-o", binary], args.output)
        binaries[variant] = binary
    manifest["binary_sha256"] = {variant: sha(path.read_bytes()) for variant, path in binaries.items()}
    write_json(args.output / "manifest.json", manifest)
    return binaries


def summarize(records: list[dict]) -> list[dict]:
    stages = {
        "publication": "allocatorAfterPublication", "first_edit": "allocatorAfterFirstEdit",
        "source_removal": "allocatorAfterSourceRemoval", "shutdown": "allocatorAfterShutdown",
    }
    summary = []
    for count in sorted({r["sourceCount"] for r in records}):
        group = [r for r in records if r["sourceCount"] == count]
        row = {"source_count": count, "source_path_utf8_bytes": group[0]["sourcePathUTF8Bytes"],
               "source_item_stride": group[0]["sourceItemStride"], "variants": {}}
        for variant in ["baseline", "candidate"]:
            data = [r for r in group if r["variant"] == variant]
            stats = {"observations": len(data), "items_buffer_reused_count": sum(r["itemsBufferReusedForFirstEdit"] for r in data),
                     "outer_buffer_reused_count": sum(r["outerBufferReusedForFirstEdit"] for r in data)}
            for name, field in stages.items():
                values = [r[field] - r["allocatorBeforeFixture"] for r in data]
                stats[f"{name}_retained_delta_bytes"] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
            edit_deltas = [r["allocatorAfterFirstEdit"] - r["allocatorAfterPublication"] for r in data]
            stats["first_edit_additional_live_bytes"] = {"median": statistics.median(edit_deltas), "min": min(edit_deltas), "max": max(edit_deltas)}
            row["variants"][variant] = stats
        differences = []
        for pair in sorted({r["pair"] for r in group}):
            b = next(r for r in group if r["pair"] == pair and r["variant"] == "baseline")
            c = next(r for r in group if r["pair"] == pair and r["variant"] == "candidate")
            differences.append((b["allocatorAfterSourceRemoval"] - b["allocatorBeforeFixture"])
                               - (c["allocatorAfterSourceRemoval"] - c["allocatorBeforeFixture"]))
        row["paired_source_removal_live_byte_reduction"] = {
            "median": statistics.median(differences), "min": min(differences), "max": max(differences)}
        summary.append(row)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--clang", default=shutil.which("clang") or shutil.which("cc"))
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--counts", nargs="+", type=int, default=[1000, 100000])
    parser.add_argument("--validate-inputs", action="store_true")
    args = parser.parse_args()
    args.output = args.output.resolve()
    if not args.swiftc or not args.clang:
        parser.error("Swift/C compiler unavailable; set --swiftc and --clang")
    if args.pairs < 1 or any(x < 1 for x in args.counts) or len(set(args.counts)) != len(args.counts):
        parser.error("Use positive pair/count values and unique source counts")
    manifest = prepare(args)
    if args.validate_inputs:
        print(json.dumps({"validated": True, "manifest": str(args.output / "manifest.json")}))
        return
    binaries = compile_variants(args, manifest)
    records = []
    parity_fields = ["sourceCount", "sourcePathUTF8Bytes", "sourceItemStride", "beforeEditDigest", "afterEditDigest",
                     "readCalls", "modelInitializations", "startupOpenDeliveries",
                     "lateCallerUsesSharedModel", "loadAfterShutdownIsNil", "allocatorMetric"]
    for count in args.counts:
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            current = []
            for position, variant in enumerate(order):
                result = json.loads(execute([binaries[variant], str(count)], args.output))
                result.update(variant=variant, pair=pair, order=position)
                records.append(result)
                current.append(result)
                with (args.output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(result, sort_keys=True) + "\n")
            if any(current[0][key] != current[1][key] for key in parity_fields):
                raise AssertionError(f"Baseline/candidate semantic receipts differ: {count}/{pair}")
    summary = summarize(records)
    write_json(args.output / "summary.json", summary)
    write_json(args.output / "completion.json", {"complete": True, "observations": len(records),
        "matched_pairs": len(records) // 2, "parity_fields": parity_fields})
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
