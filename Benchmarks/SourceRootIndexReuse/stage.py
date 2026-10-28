"""Stage exact production sources and the real observed property for native research."""
from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

CORE = (
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/LifecyclePerformance.swift",
)
INDEX = "Sources/IlliquidApp/App/SourceRootIndex.swift"
APP = "Sources/IlliquidApp/App/AppModel.swift"
TEST = "Tests/IlliquidAppTests/SourceRootIndexReuseTests.swift"
MODEL_START = "\nenum SourceFolderLibrary {\n"
MODEL_END = "\nenum SourceTabStore {\n"
PROPERTY_START = "    private(set) var sourceTabs: [SourceTab] {\n"
PROPERTY_END = "    private(set) var activeSourceTabID:"
OWNER_PREFIX = """import Foundation
import Observation
import IlliquidCore

// The observed property and store declaration below come verbatim from AppModel.
// This host excludes preference persistence, UI rendering, and user-activity work.
@Observable @MainActor
final class SourceRootIndexBenchmarkOwner {
"""
OWNER_SUFFIX = """
    init(tabs: [SourceTab]) {
        sourceTabs = tabs
        sourceRootIndex.replace(tabs: sourceTabs)
    }

    var isReady: Bool { sourceRootIndex.isReady }
    var snapshot: SourceRootIndex { sourceRootIndex.snapshot }
    func waitUntilReady() async { await sourceRootIndex.waitUntilReady() }

    func setVisibility(_ value: SourceVisibilityConfiguration?, at index: Int) {
        sourceTabs[index].visibility = value
    }
    func setItems(_ items: [SourceTabItem], at index: Int) {
        sourceTabs[index].items = items
    }
    func replaceTabs(_ tabs: [SourceTab]) { sourceTabs = tabs }
    func removeLastItem(at index: Int) {
        guard let item = sourceTabs[index].items.last else { return }
        // Match AppModel.removeSourceItem's actual in-place removal expression.
        sourceTabs[index].items.removeAll { $0 == item }
    }
}
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"Production extraction marker changed: {start!r}, {end!r}")
    return source[source.index(start):source.index(end, source.index(start) + len(start))]


def stage(root: Path, package: Path, revision: str | None) -> dict:
    if package.exists():
        raise RuntimeError(f"Refusing to overwrite staged package: {package}")
    package.mkdir(parents=True)
    here = root / "Benchmarks/SourceRootIndexReuse"
    receipts = {}

    def read(path: str) -> bytes:
        return (root / path).read_bytes() if revision is None else subprocess.check_output(
            ["git", "-C", str(root), "show", f"{revision}:{path}"])

    def write(path: str, data: bytes) -> None:
        destination = package / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)

    for path in (*CORE, INDEX):
        data = read(path)
        write(path, data)
        receipts[path] = {"revision": revision, "sha256": digest(data),
                          "compiled_sha256": digest(data), "transformation": "none"}

    app_data = read(APP)
    app = app_data.decode()
    models = extract(app, MODEL_START, MODEL_END)
    properties = extract(app, PROPERTY_START, PROPERTY_END)
    for marker in (
        "enum SourceFolderLibrary {", "struct SourceTabItem:", "struct SourceTab:",
        "enum SourceVisibilityViewMode:", "struct SourceVisibilityRegexRule:",
        "struct SourceVisibilityConfiguration:", "enum SourceVisibilityPath {",
        "enum SourceTabItems {",
    ):
        if models.count(marker) != 1:
            raise RuntimeError(f"Production model declaration changed: {marker}")
    if properties.count("    private let sourceRootIndex = SourceRootIndexStore()\n") != 1:
        raise RuntimeError("Production store declaration changed")
    if "\n        sourceRootIndex.replace(tabs: sourceTabs)\n" not in app:
        raise RuntimeError("Explicit initial indexing changed")
    if "sourceTabs[tabIndex].items.removeAll { $0 == item }" not in app:
        raise RuntimeError("Production removal expression changed")
    write("Sources/IlliquidApp/Models.swift", ("import Foundation\nimport IlliquidCore\n" + models).encode())
    write("Sources/IlliquidApp/Owner.swift", (OWNER_PREFIX + properties + OWNER_SUFFIX).encode())
    receipts[APP] = {"revision": revision, "sha256": digest(app_data),
                     "model_slice_sha256": digest(models.encode()),
                     "observer_slice_sha256": digest(properties.encode()),
                     "transformation": "verbatim models and observed property in benchmark host"}

    for source, destination in (
        (here / "Driver.swift", "Sources/IlliquidApp/Driver.swift"),
        (here / "CProbe/Probe.c", "Sources/CProbe/Probe.c"),
        (here / "CProbe/include/Probe.h", "Sources/CProbe/include/Probe.h"),
    ):
        data = source.read_bytes()
        write(destination, data)
        receipts[str(source.relative_to(root))] = {"sha256": digest(data), "transformation": "none"}

    tests = ""
    if revision is None:
        data = (root / TEST).read_bytes()
        write("Tests/IlliquidAppTests/SourceRootIndexReuseTests.swift", data)
        receipts[TEST] = {"sha256": digest(data), "transformation": "none"}
        tests = ',\n        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"])'
    manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceRootIndexReuseQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "RootIndexBenchmark", targets: ["IlliquidApp"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "CProbe"),
        .executableTarget(name: "IlliquidApp", dependencies: ["IlliquidCore", "CProbe"])""" + tests + """
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
"""
    write("Package.swift", manifest.encode())
    receipts["compiled_sources"] = {
        str(path.relative_to(package)): digest(path.read_bytes())
        for path in sorted((package / "Sources").rglob("*")) if path.is_file()
    }
    receipts["manifest_sha256"] = digest(manifest.encode())
    write("source-receipts.json", (json.dumps(receipts, indent=2) + "\n").encode())
    return receipts
