#!/usr/bin/env python3
"""Run the native tail-lookup experiment as an explicitly adapted Linux component.

The native runner, driver, production files and tests are never edited. Generated
runner/driver files live in a temporary directory; output retains originals,
adapted snapshots, exact transformation receipts and all native-runner evidence.
Use the same CLI arguments as Benchmarks/BitmapSubtitleTailLookup/run.py.
"""
from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NATIVE_HARNESS = ROOT / "Benchmarks/BitmapSubtitleTailLookup"


def main() -> None:
    originals = {
        "native-runner.py": (NATIVE_HARNESS / "run.py").read_bytes(),
        "native-Driver.swift": (NATIVE_HARNESS / "Driver.swift").read_bytes(),
        "portable-adapter.py": Path(__file__).read_bytes(),
    }
    paths = {
        "native-runner.py": NATIVE_HARNESS / "run.py",
        "native-Driver.swift": NATIVE_HARNESS / "Driver.swift",
        "portable-adapter.py": Path(__file__).resolve(),
    }
    runner = originals["native-runner.py"].decode("utf-8")
    driver = originals["native-Driver.swift"].decode("utf-8")
    transformations = []

    def change(text: str, before: str, after: str, label: str,
               count: int = 1, target: str = "runner") -> str:
        actual = text.count(before)
        if actual != count:
            raise RuntimeError(f"{target}/{label}: expected {count} matches, found {actual}")
        transformations.append({"target": target, "label": label, "matches": count,
                                "before": before, "after": after})
        return text.replace(before, after)

    runner = change(runner, "Compare exact bitmap-subtitle lookup sources on native macOS.",
                    "Compare adapted bitmap-subtitle lookup sources on Linux.", "description")
    runner = change(runner, "ROOT = HERE.parents[1]", f"ROOT = Path({str(ROOT)!r})", "repository routing")
    runner = change(runner, "str(path.relative_to(ROOT))", "str(path)",
                    "absolute generated-input receipts", count=3)
    runner = change(runner, '    platforms: [.macOS("26.0")],\n', "", "portable test manifest")
    runner = change(runner, '"libIlliquidNativePlayback.dylib"', '"libIlliquidNativePlayback.so"',
                    "Linux library suffix")
    runner = change(runner, '''    flags = ["-swift-version", "6", "-O", "-warnings-as-errors",
             "-target", f"{platform.machine()}-apple-macos26.0",
             "-sdk", manifest["sdk_path"], "-module-cache-path", output / "build/module-cache"]''',
                    '''    flags = ["-swift-version", "6", "-O", "-warnings-as-errors",
             "-module-cache-path", output / "build/module-cache"]''', "host Linux compiler flags")
    runner = change(runner, 'platform.system() != "Darwin"', 'platform.system() != "Linux"',
                    "host requirement")
    runner = change(runner,
                    'parser.error("This native component experiment requires macOS CoreGraphics")',
                    'parser.error("This adapted component experiment requires Linux Foundation")',
                    "host requirement message")
    runner = change(runner,
                    'manifest["tools"]["swift"]["path"], "test", "--package-path", package',
                    'manifest["tools"]["swift"]["path"], "test", "--use-integrated-swift-driver", '
                    '"--package-path", package', "integrated Linux test driver")
    runner = change(runner,
                    '"-Xswiftc", "-warnings-as-errors"], output, timeout=600, combined=True)',
                    '"-Xswiftc", "-warnings-as-errors", "-Xlinker", "--export-dynamic"], '
                    'output, timeout=600, combined=True)', "Linux test symbol export")
    runner = change(runner, '''        manifest["developer_dir"] = os.environ.get("DEVELOPER_DIR")
        manifest["sw_vers"] = run(["sw_vers"], output).strip()
        manifest["hardware"] = run(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip()
        manifest["sdk_path"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], output).strip()
        manifest["sdk_version"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], output).strip()
        for name in ["swiftc", "swift", "swift-frontend"]:
            path = Path(run(["xcrun", "--find", name], output).strip())
''', '''        manifest["host_kernel"] = run(["uname", "-a"], output).strip()
        manifest["os_release"] = Path("/etc/os-release").read_text()
        cpuinfo = Path("/proc/cpuinfo")
        manifest["hardware"] = {
            "machine": platform.machine(), "logical_cpus": os.cpu_count(),
            "cpu_models": sorted({line.partition(":")[2].strip()
                for line in cpuinfo.read_text().splitlines() if line.startswith("model name")})
                if cpuinfo.is_file() else [],
        }
        for name in ["swiftc", "swift", "swift-frontend"]:
            located = shutil.which(name)
            if located is None:
                raise RuntimeError(f"Required Swift tool is unavailable: {name}")
            path = Path(located)
''', "Linux host and toolchain metadata")
    driver = change(driver, "import CoreGraphics\n", "", "Foundation geometry import",
                    target="driver")
    driver = change(driver, "import Darwin\n", "import Glibc\n", "Linux process CPU clock import",
                    target="driver")

    with tempfile.TemporaryDirectory(prefix="illiquid-bitmap-tail-portable-") as temporary:
        staging = Path(temporary)
        (staging / "run.py").write_text(runner, encoding="utf-8")
        (staging / "Driver.swift").write_text(driver, encoding="utf-8")
        specification = importlib.util.spec_from_file_location("bitmap_tail_portable_runner", staging / "run.py")
        if specification is None or specification.loader is None:
            raise RuntimeError("Cannot load the generated portable runner")
        module = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = module
        specification.loader.exec_module(module)
        native_prepare = module.prepare

        def prepare(output: Path, manifest: dict) -> None:
            native_prepare(output, manifest)
            hashes = manifest["snapshot_sha256"]
            source_changes = {}
            for variant in module.VARIANTS:
                source_changes[variant] = {}
                for name in module.SOURCE_NAMES:
                    path = output / "sources" / variant / name
                    original = path.read_bytes()
                    expected = 0 if name == "SubtitleMemoryBudget.swift" else 1
                    if original.count(b"import CoreGraphics\n") != expected:
                        raise RuntimeError(f"Unexpected CoreGraphics import boundary: {variant}/{name}")
                    adapted = original.replace(b"import CoreGraphics\n", b"")
                    original_path = output / "originals" / variant / name
                    module.snapshot(original_path, original, output, hashes)
                    module.snapshot(path, adapted, output, hashes)
                    source_changes[variant][name] = {
                        "original_snapshot": str(original_path.relative_to(output)),
                        "adapted_snapshot": str(path.relative_to(output)),
                        "original_bytes": len(original), "adapted_bytes": len(adapted),
                        "original_sha256": module.digest(original), "adapted_sha256": module.digest(adapted),
                        "transformation": "remove exact CoreGraphics import" if expected else "none",
                        "import_removals": expected,
                    }
            module.require_lookup_only_change(
                (output / "sources/baseline/BitmapSubtitleTimeline.swift").read_bytes(),
                (output / "sources/candidate/BitmapSubtitleTimeline.swift").read_bytes()
            )
            original_receipts = {}
            for name, data in originals.items():
                module.snapshot(output / "originals/harness" / name, data, output, hashes)
                manifest["worktree_input_sha256"][str(paths[name])] = module.digest(data)
                original_receipts[name] = {"path": str(paths[name]), "bytes": len(data),
                                           "sha256": module.digest(data)}
            original_runner = originals["native-runner.py"].decode("utf-8")
            marker = "    package = b'''"
            if original_runner.count(marker) != 1:
                raise RuntimeError("Native generated-package boundary changed")
            original_package = original_runner.split(marker, 1)[1].split("'''", 1)[0].encode("utf-8")
            module.snapshot(output / "originals/harness/Tests.Package.swift",
                            original_package, output, hashes)
            tests = {}
            for name in module.TESTS:
                original = (ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes()
                compiled = (output / "tests" / name).read_bytes()
                if compiled != original:
                    raise RuntimeError(f"Portable adapter changed a regression test: {name}")
                tests[name] = {"original_sha256": module.digest(original),
                               "adapted_sha256": module.digest(compiled),
                               "original_bytes": len(original), "adapted_bytes": len(compiled),
                               "transformation": "none"}
            manifest["compiled_source_sha256"] = {
                variant: {name: row["adapted_sha256"] for name, row in rows.items()}
                for variant, rows in source_changes.items()
            }
            manifest["portable_adapter"] = {
                "qualification": "Adapted Linux component; real Linux Foundation CGRect/Data/NSLock. "
                                 "No model stubs. No native macOS or whole-player performance claim.",
                "original_files": original_receipts,
                "adapted_runner": {"bytes": len(runner.encode()), "sha256": module.digest(runner.encode()),
                                   "snapshot": "harness/run.py"},
                "adapted_driver": {"bytes": len(driver.encode()), "sha256": module.digest(driver.encode()),
                                   "snapshot": "harness/Driver.swift"},
                "text_transformations": transformations, "source_adaptations": source_changes,
                "tests": tests,
                "test_manifest": {"original_sha256": module.digest(original_package),
                                  "adapted_sha256": module.file_digest(output / "harness/Tests.Package.swift"),
                                  "transformation": "remove macOS platform declaration"},
                "execution": "Generated runner with this adapter's prepare wrapper; all generated inputs "
                             "and original harness/adapter files participate in final immutability checks.",
            }
            manifest["extraction"] = "Complete production timeline/budget and exact ASSRenderedRegion "
            manifest["extraction"] += "declaration; only CoreGraphics imports removed from staged sources."
            manifest["scope"] = "Adapted Linux component lookup, including identical query-loop/result "
            manifest["scope"] += "consumption; not macOS, decoder, prune, renderer or whole-player frame time."

        module.prepare = prepare
        module.main()


if __name__ == "__main__":
    main()
