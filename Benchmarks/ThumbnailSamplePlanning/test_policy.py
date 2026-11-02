#!/usr/bin/env python3
"""Noncompiling runner policy checks; all campaign commands are intercepted."""
import ast
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location("runner_policy_subject", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
HISTORICAL = ROOT / "Benchmarks/ThumbnailSamplePrefix/baseline/ThumbnailPolicy.swift"
SIGNATURE = "    public static func samples(duration: Double, focus: Double, count: Int) -> [Double] {"


def method(source):
    start = source.index(SIGNATURE)
    return source[start:source.index("\n    }", start) + len("\n    }")]


class RunnerPolicyTests(unittest.TestCase):
    def test_oracle_exact_and_fail_closed(self):
        historic = HISTORICAL.read_text()
        self.assertEqual(hashlib.sha256(HISTORICAL.read_bytes()).hexdigest(),
                         "1c68b9d4819cc9e9d4a8f3dfe2e6e723e69dd0330e7fa63e389eb76c107986d3")
        candidate = historic.replace(method(historic), SIGNATURE + "\n        return [999]\n    }")
        result = runner.frozen_sample_arm(candidate, historic)
        self.assertEqual(method(result), method(historic))
        self.assertNotEqual(method(result), method(candidate))
        for invalid in [candidate + candidate, candidate.replace("samples(duration:", "changed(duration:"),
                        candidate.replace("return [999]", "if true { return [999]")]:
            with self.assertRaises(RuntimeError):
                runner.frozen_sample_arm(invalid, historic)
        with self.assertRaises(RuntimeError):
            runner.frozen_sample_arm(candidate, historic + historic)

    def test_current_timings_rejected(self):
        for mode in ("all", "benchmark"):
            with self.assertRaises(RuntimeError):
                runner.validate_mode(SimpleNamespace(current_support=True, mode=mode))
        runner.validate_mode(SimpleNamespace(current_support=True, mode="tests"))
        subject = object.__new__(runner.Campaign)
        subject.args = SimpleNamespace(current_support=True)
        with self.assertRaises(RuntimeError):
            subject.measure()

    def test_identical_support_snapshot_and_strict_historical_guard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / runner.SOURCE
            source.parent.mkdir(parents=True)
            source.write_text(HISTORICAL.read_text())
            for name in runner.SUPPORT:
                (source.parent / name).write_text("CURRENT " + name)
            for name in runner.TESTS:
                target = root / "Tests/IlliquidCoreTests" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("TEST " + name)
            def campaign(current):
                subject = object.__new__(runner.Campaign)
                subject.args = SimpleNamespace(current_support=current, mode="tests", pairs=8, target_ms=80)
                subject.output = root / ("current" if current else "historical")
                subject.output.mkdir()
                subject.swiftc = "INTERCEPTED"
                subject.packages = {}
                subject.binaries = {}
                def command(args, log=None):
                    if args[:2] == ["git", "show"]:
                        return HISTORICAL.read_text() if args[2].endswith(runner.SOURCE) else "HISTORICAL"
                    return "intercepted"
                subject.command = command
                return subject
            with patch.object(runner, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                subject = campaign(True)
                subject.prepare()
                for name in runner.SUPPORT:
                    staged = [(p / "Sources/IlliquidCore" / name).read_text()
                              for p in subject.packages.values()]
                    self.assertEqual(staged, ["CURRENT " + name] * 2)
                for package in subject.packages.values():
                    self.assertEqual(sorted(p.name for p in (package / "Tests/IlliquidCoreTests").iterdir()),
                                     sorted(runner.TESTS))
                with self.assertRaisesRegex(RuntimeError, "support source changed"):
                    campaign(False).prepare()

    def test_all_workloads_and_suites_retained(self):
        self.assertEqual(runner.CASES, ["storyboard-movie", "storyboard-clip", "background-balanced",
                         "background-economical", "background-extensive", "subsecond", "short-clip",
                         "full-budget-control", "one-sample", "invalid-control"])
        self.assertEqual(runner.TESTS, ["ThumbnailPolicyTests.swift", "ThumbnailSchedulingPolicyRegressionTests.swift",
                         "ThumbnailSamplePlanningTests.swift", "ThumbnailSamplePrefixTests.swift",
                         "ThumbnailSamplePlanningAlternativeTests.swift"])
        original = (HERE / "Harness.swift").read_text()
        regression = (HERE / "RegressionHarness.swift").read_text()
        start = "    private static func inputs"
        self.assertEqual(original[original.index(start):original.index("    private static func processCPUNanoseconds")],
                         regression[regression.index(start):regression.index("    private static func fail")])
        self.assertNotIn("Nanoseconds", regression)
        self.assertIn("$0.bitPattern", regression)

    def test_manual_routing(self):
        for suffix in ("", "-portable"):
            workflow = (ROOT / f".github/workflows/thumbnail-sample-planning{suffix}.yml").read_text()
            self.assertIn('if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]; then', workflow)
            manual, automatic = workflow.split('if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]; then', 1)[1].split('else', 1)
            self.assertIn("--pairs 8 --target-ms 80", manual)
            self.assertNotIn("--current-support", manual)
            self.assertIn("--current-support --mode tests", automatic)
            self.assertIn("python3 -B Benchmarks/ThumbnailSamplePlanning/test_policy.py", workflow)


if __name__ == "__main__":
    unittest.main()
