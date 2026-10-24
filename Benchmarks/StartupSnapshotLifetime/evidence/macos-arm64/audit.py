#!/usr/bin/env python3
"""Independent checks of the native startup-snapshot evidence receipt."""
from pathlib import Path
import hashlib, json, math, re, statistics, sys

EVIDENCE = Path(sys.argv[1])
REPO = Path(sys.argv[2])
EXPECTED_SHA = "160b6f4c0ba77fbbabf2c40b08dfa02cba1bdd1d"
EXPECTED_RUN = "40101057617"
def read(name):
    return json.loads((EVIDENCE / name).read_text())
def lines(name):
    return [json.loads(line) for line in (EVIDENCE / name).read_text().splitlines() if line]
def sha(data):
    return hashlib.sha256(data).hexdigest()
def require(ok, message):
    if not ok:
        raise AssertionError(message)

manifest = read("manifest.json")
run = read("github-run.json")
rows = lines("observations.jsonl")
verification = read("verification.json")
summary = read("summary.json")
commands = lines("commands.jsonl")
source_receipts = read("source-receipts.json")
build_receipts = read("build-receipts.json")
tests = read("tests.json")
require(run["sha"] == EXPECTED_SHA and run["id"] == EXPECTED_RUN, "wrong CI commit/run")
require(run["event"] == "push", "not the full research push cohort")
require(manifest["candidate_head"] == EXPECTED_SHA, "candidate SHA drift")
require(manifest["environment"]["machine"] == "arm64", "not native Apple arm64")
require("macOS" in manifest["environment"]["platform"] or "Darwin" in manifest["environment"]["platform"], "wrong platform")
require(manifest["method"]["tests_only"] is False, "tests-only evidence")
require(all(command["returncode"] == 0 for command in commands), "failed recorded command")

source_hashes = {}
for path, expected in manifest["inputs"].items():
    actual = sha((REPO / path).read_bytes())
    require(actual == expected, f"source mismatch: {path}")
    source_hashes[path] = actual

frozen = manifest["baseline"]
support = frozen["support_extraction"]
app = (REPO / "Sources/IlliquidApp/App/AppModel.swift").read_text()
require(app.count(support["start"]) == 1 and app.count(support["end_exclusive"]) == 1, "extraction ambiguity")
model = (support["prelude"] + app[app.index(support["start"]):app.index(support["end_exclusive"])]).encode()
require(sha(model) == support["sha256"], "model extraction mismatch")

shared = {
    "Sources/IlliquidApp/SourceStartupSnapshot.swift": "Sources/IlliquidApp/App/SourceStartupSnapshot.swift",
    "Sources/IlliquidCore/NormalizedFileURL.swift": "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/StartupSnapshotProbe/Driver.swift": "Benchmarks/StartupSnapshotLifetime/Driver.swift",
    "Sources/CStartupHeap/heap.c": "Benchmarks/StartupSnapshotLifetime/CStartupHeap/heap.c",
    "Sources/CStartupHeap/include/heap.h": "Benchmarks/StartupSnapshotLifetime/CStartupHeap/include/heap.h",
    "Tests/IlliquidAppTests/SourceStartupSnapshotTests.swift": "Tests/IlliquidAppTests/SourceStartupSnapshotTests.swift",
}
for variant in ("baseline", "candidate"):
    expected_files = dict(shared)
    expected_files["Sources/IlliquidApp/ReadOnlyStartupLoader.swift"] = (
        "Benchmarks/StartupSnapshotLifetime/baseline/ReadOnlyStartupLoader.swift" if variant == "baseline"
        else "Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift")
    expected_files["Tests/IlliquidAppTests/ReadOnlyStartupLoaderTests.swift"] = (
        "Benchmarks/StartupSnapshotLifetime/baseline/ReadOnlyStartupLoaderTests.swift" if variant == "baseline"
        else "Tests/IlliquidAppTests/ReadOnlyStartupLoaderTests.swift")
    for staged, original in expected_files.items():
        require(source_receipts[variant][staged] == sha((REPO / original).read_bytes()), f"staged source mismatch {variant}/{staged}")
    require(source_receipts[variant]["Sources/IlliquidApp/SourceModels.swift"] == sha(model), "staged model mismatch")
    define = ', swiftSettings: [.define("BASELINE")]' if variant == "baseline" else ""
    package = f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "StartupSnapshotLifetime", platforms: [.macOS("26.0")],
    products: [.executable(name: "StartupSnapshotProbe", targets: ["StartupSnapshotProbe"])],
    targets: [
        .target(name: "CStartupHeap", publicHeadersPath: "include"),
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "StartupSnapshotProbe", dependencies: ["IlliquidApp", "IlliquidCore", "CStartupHeap"]{define}),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"])
    ], swiftLanguageModes: [.v6])
'''.encode()
    require(source_receipts[variant]["Package.swift"] == sha(package), "staged build manifest mismatch")
    require(set(source_receipts[variant]) == set(expected_files) | {"Sources/IlliquidApp/SourceModels.swift", "Package.swift"}, "unverified extra staged source")
    require(re.fullmatch(r"[0-9a-f]{64}", build_receipts[variant]["sha256"]) is not None, "binary receipt malformed")
    for configuration in ("debug", "release"):
        receipt = tests[variant][configuration]
        require(receipt["passed"] is True, "test receipt failed")
        expected_count = 5 if variant == "baseline" else 10
        require(receipt["tests"] == expected_count, "unexpected test count")
        matches = [c for c in commands if c["log"].endswith(f"{variant}-{configuration}-tests.log")]
        require(len(matches) == 1, "test command missing/duplicated")
        log = (EVIDENCE / matches[0]["log"]).read_text()
        completed = re.findall(r"Test run with (\d+) tests? .*passed", log)
        require(completed and int(completed[-1]) == expected_count, "test log does not confirm receipt")
        require("-warnings-as-errors" in matches[0]["arguments"], "warnings-as-errors missing")

pairs = manifest["method"]["pairs"]
sizes = manifest["method"]["sizes"]
scenarios = manifest["method"]["scenarios"]
require(pairs == 6 and sizes == [1, 32, 1000, 10000, 100000], "cohort differs from planned six-pair five-size run")
workloads = [(s, n) for n in sizes for s in scenarios]
expected = []
for pair in range(pairs):
    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
    for scenario, count in workloads[pair % len(workloads):] + workloads[:pair % len(workloads)]:
        for variant in order:
            expected.append((pair, scenario, count, variant, order))
require(len(rows) == len(expected) == 300, "incomplete or extra cohort")
index = {}
for sequence, (row, exp) in enumerate(zip(rows, expected)):
    pair, scenario, count, variant, order = exp
    require((row["pair"], row["scenario"], row["count"], row["variant"], row["order"]) == exp, "pair/order/workload drift")
    require(row["saved_explicit_item_count"] == count, "driver input count mismatch")
    require(row["sequence"] == sequence, "observation sequence drift")
    require(row["allocator_metric"] == "malloc_zone_statistics(NULL).size_in_use", "allocator metric drift")
    require(row["retained_allocator_delta_bytes"] == row["allocator_after_mutation_bytes"] - row["allocator_before_load_bytes"], "primary delta arithmetic error")
    require(row["handoff_allocator_delta_bytes"] == row["allocator_after_handoff_bytes"] - row["allocator_before_load_bytes"], "handoff delta arithmetic error")
    require(row["model_release_allocator_delta_bytes"] == row["allocator_after_model_release_bytes"] - row["allocator_before_load_bytes"], "model-release delta arithmetic error")
    require(row["cleanup_allocator_delta_bytes"] == row["allocator_after_cleanup_bytes"] - row["allocator_before_load_bytes"], "cleanup delta arithmetic error")
    require(row["state_output_written"] is True and row["state_bytes"] > 0, "missing actual model output")
    measured_commands = [c for c in commands if c["log"].endswith(f"pair-{pair:02d}-{scenario}-{count}-{variant}.log")]
    require(len(measured_commands) == 1, "missing/duplicate probe command")
    command = measured_commands[0]
    require(command["arguments"][0].endswith(build_receipts[variant]["path"]), "wrong variant executable")
    require(command["arguments"][1:3] == [scenario, str(count)], "wrong executable inputs")
    raw_measurement = json.loads((EVIDENCE / command["log"]).read_text())
    for field, value in raw_measurement.items():
        require(row[field] == value, f"raw measurement mismatch {field}")
    index[pair, scenario, count, variant] = row

require(len(verification) == 150, "verification count mismatch")

# Reconstruct the semantic result independently in Python. These fixtures use
# only already-normalized ASCII paths, so no Foundation URL transformation is
# required to derive the expected saved-source values.
def expected_state(scenario, count):
    tabs = []
    tab_count = min(count, 4)
    for t in range(tab_count):
        items, hidden, shown = [], [], []
        for n in range(count * t // tab_count, count * (t + 1) // tab_count):
            path = f"/benchmark/library/series-{n // 24}/season-{n // 12 % 2 + 1}/episode-{n}.mkv"
            items.append({"kind": "file", "path": path})
            if n % 8 == 0:
                hidden.append(path)
            if n % 8 == 1:
                shown.append(path)
        tabs.append({"id": f"restored-tab-{t}", "items": items, "visibility": {
            "viewMode": "filesOnly", "showsHiddenItems": t % 2 == 0,
            "manuallyHiddenPaths": sorted(hidden), "alwaysShownPaths": sorted(shown),
            "regexRules": [{"id": f"restored-rule-{t}", "pattern": rf"^bonus-{t}-.*\.mkv$",
                            "colorIndex": t % 6, "isEnabled": True}],
        }})
    selected = tabs[-1]["id"] if tabs else None
    if scenario == "append-item":
        if not tabs:
            tabs.append({"id": "new-tab", "items": []})
        tabs[0]["items"].append({"kind": "file", "path": "/benchmark/library/added-after-startup.mkv"})
    elif scenario == "remove-half":
        del tabs[len(tabs) - (len(tabs) + 1) // 2:]
    elif scenario == "remove-all":
        tabs = []
    elif scenario == "replace-visibility":
        for tab in tabs:
            del tab["visibility"]
    elif scenario != "unchanged":
        raise AssertionError("unknown scenario")
    if not any(tab["id"] == selected for tab in tabs):
        selected = tabs[0]["id"] if tabs else None
    return {"tabs": tabs, "selectedID": selected}

class FNV:
    MASK = (1 << 64) - 1
    def __init__(self):
        self.value = 14_695_981_039_346_656_037
    def byte(self, b):
        self.value = ((self.value ^ b) * 1_099_511_628_211) & self.MASK
    def integer(self, n):
        for shift in range(0, 64, 8):
            self.byte((n >> shift) & 255)
    def string(self, s):
        for b in s.encode("utf-8"):
            self.byte(b)
        self.byte(255)
    def strings(self, strings):
        total, xor = 0, 0
        for s in strings:
            d = FNV()
            d.string(s)
            total = (total + d.value) & self.MASK
            xor ^= d.value
        self.integer(len(strings))
        self.integer(total)
        self.integer(xor)

def expected_checks(state):
    checks = {"tab_count": len(state["tabs"]), "item_count": 0,
              "hidden_path_count": 0, "shown_path_count": 0, "regex_rule_count": 0}
    d = FNV()
    d.integer(len(state["tabs"]))
    for tab in state["tabs"]:
        d.string(tab["id"])
        d.integer(len(tab["items"]))
        checks["item_count"] += len(tab["items"])
        for item in tab["items"]:
            d.string(item["kind"])
            d.string(item["path"])
        if "visibility" in tab:
            v = tab["visibility"]
            d.byte(1)
            d.string(v["viewMode"])
            d.byte(1 if v["showsHiddenItems"] else 0)
            d.strings(v["manuallyHiddenPaths"])
            d.strings(v["alwaysShownPaths"])
            checks["hidden_path_count"] += len(v["manuallyHiddenPaths"])
            checks["shown_path_count"] += len(v["alwaysShownPaths"])
            checks["regex_rule_count"] += len(v["regexRules"])
            d.integer(len(v["regexRules"]))
            for rule in v["regexRules"]:
                d.string(rule["id"])
                d.string(rule["pattern"])
                d.integer(rule["colorIndex"])
                d.byte(1 if rule["isEnabled"] else 0)
        else:
            d.byte(0)
    if state["selectedID"] is not None:
        d.byte(1)
        d.string(state["selectedID"])
    else:
        d.byte(0)
    checks["checksum"] = d.value
    return checks

semantic = {}
for scenario, count in workloads:
    state = expected_state(scenario, count)
    payload = json.dumps(state, separators=(",", ":"), sort_keys=True, ensure_ascii=False).encode("utf-8")
    semantic[scenario, count] = {"scenario": scenario, "count": count, "state_sha256": sha(payload),
                                 "state_bytes": len(payload), "checks": expected_checks(state)}
for v in verification:
    a = index[v["pair"], v["scenario"], v["count"], "baseline"]
    b = index[v["pair"], v["scenario"], v["count"], "candidate"]
    require(v["byte_equal"] is True, "state byte parity failed")
    for field in ("checks", "state_sha256", "state_bytes"):
        require(a[field] == b[field] == v[field], f"paired state receipt mismatch {field}")
        require(v[field] == semantic[v["scenario"], v["count"]][field],
                f"independent expected-state mismatch: {v['scenario']}/{v['count']}/{field}")

def equal_number(actual, expected):
    if expected is None:
        return actual is None
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(equal_number(a, b) for a, b in zip(actual, expected))
    if isinstance(expected, int):
        return actual == expected
    return isinstance(actual, (int, float)) and math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9)

require(summary["pairs"] == 6 and summary["processes"] == 300 and summary["all_state_pairs_byte_equal"] is True, "summary header mismatch")
require(len(summary["results"]) == len(workloads), "summary workload count mismatch")
summary_rows = []
for result in summary["results"]:
    scenario, count = result["scenario"], result["saved_item_count"]
    require(result["pairs"] == pairs, "summary pair count mismatch")
    for metric, received in result["metrics"].items():
        baseline = [index[p, scenario, count, "baseline"][metric] for p in range(pairs)]
        candidate = [index[p, scenario, count, "candidate"][metric] for p in range(pairs)]
        differences = [a - b for a, b in zip(baseline, candidate)]
        reductions = [100 * (a - b) / a for a, b in zip(baseline, candidate) if a > 0]
        calculated = {
            "baseline_median": statistics.median(baseline),
            "candidate_median": statistics.median(candidate),
            "paired_median_saved": statistics.median(differences),
            "paired_median_reduction_percent": statistics.median(reductions) if len(reductions) == pairs else None,
            "paired_saved_range": [min(differences), max(differences)],
            "pairs_lower": sum(b < a for a, b in zip(baseline, candidate)),
        }
        require(set(received) == set(calculated), f"summary metric schema mismatch {metric}")
        for field, expected_value in calculated.items():
            require(equal_number(received[field], expected_value), f"summary arithmetic error {count}/{scenario}/{metric}/{field}")
    summary_rows.append({"count": count, "scenario": scenario, **result["metrics"]["retained_allocator_delta_bytes"]})

report = {
    "status": "passed", "github_run": run, "observations": len(rows), "paired_states": len(verification),
    "balanced_order_per_workload": "three AB, three BA; rotated workload order", "native_environment": manifest["environment"],
    "source_hash_count": len(source_hashes), "staged_source_receipts_checked": True,
    "staged_source_count": sum(len(v) for v in source_receipts.values()),
    "raw_probe_logs_and_executable_variants_verified": len(rows),
    "binary_receipt_note": "Both release binary SHA-256 receipts are present. CI runner verifies unchanged binaries at experiment completion; binary files are not in the uploaded evidence, so this audit does not independently rehash them.",
    "state_parity_note": "All recorded full-state comparisons, lengths and checksums agree with an independently reconstructed Python state for every scenario/count. Temporary model JSON files were deleted by the runner after byte equality.",
    "semantic_state_workloads_reconstructed": len(semantic),
    "tests": tests, "summary_recalculated_independently": True, "primary_results": summary_rows,
}
(EVIDENCE / "independent-expected-states.json").write_text(json.dumps(list(semantic.values()), indent=2, sort_keys=True) + "\n")
(EVIDENCE / "independent-audit.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, indent=2, sort_keys=True))
