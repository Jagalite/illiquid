"""Non-compiling checks for regression provenance and historical fail-closed gates.

Run with: python3 -B Benchmarks/ManualVisibility/test_source_policy.py
"""
import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("manual_visibility_policy", Path(__file__).with_name("run.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)

SUPPORT = "Sources/IlliquidCore/MediaMetadataHints.swift"
SOURCE = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
OLD = b"struct SourceVisibilityMatcher {\n    let old = true\n}\n"
NEW = b"struct SourceVisibilityMatcher {\n    let current = true\n}\n"
PREFIX = b"import Foundation\n"
SUFFIX = b"\nenum SourceVisibilityProjection {}\n"


def snapshot(matcher, support=b"support", prefix=PREFIX):
    files = {native.FOCAL: prefix + matcher + SUFFIX, SUPPORT: support}
    records = {path: {"repository_path": SOURCE if path == native.FOCAL else path,
                      "snapshot_sha256": native.sha(raw), "source_sha256": native.sha(raw)}
               for path, raw in files.items()}
    return files, records


class SourcePolicyTests(unittest.TestCase):
    def study(self, tests_only):
        study = object.__new__(native.Study)
        study.args = SimpleNamespace(tests_only=tests_only, cases=list(native.CASES))
        study.manifest = {"baseline": native.BASELINE, "boundary": {"timed": True}}
        return study

    def test_regressions_keep_current_support_and_label_adapted_reference(self):
        current = snapshot(NEW, b"landed metadata change", b"current surrounding declarations\n")
        unchanged = copy.deepcopy(current)
        reads = []

        def historical(path):
            reads.append(path)
            return PREFIX + OLD + SUFFIX

        study = self.study(True)
        with patch.object(native.support, "snapshot", return_value=current):
            variants = study.source_variants(historical)
        self.assertEqual(reads, [SOURCE])  # No historical support substitution.
        self.assertEqual(current, unchanged)
        reference, candidate = variants
        self.assertEqual([v[0] for v in variants], ["reference", "candidate"])
        self.assertEqual(reference[1][SUPPORT], candidate[1][SUPPORT])
        self.assertEqual(native.outside_matcher(reference[1][native.FOCAL]),
                         native.outside_matcher(candidate[1][native.FOCAL]))
        self.assertIn(OLD, reference[1][native.FOCAL])
        receipt = reference[2][native.FOCAL]
        self.assertEqual(receipt["snapshot_sha256"], native.sha(reference[1][native.FOCAL]))
        self.assertEqual(receipt["historical_matcher_sha256"], native.sha(OLD))
        self.assertEqual(receipt["current_source"], current[1][native.FOCAL])
        self.assertEqual(study.manifest["mode"], "current-source-regressions")
        self.assertIsNone(study.manifest["baseline"])
        self.assertEqual(study.manifest["pairs"], 0)
        self.assertIsNone(study.manifest["target_ms"])
        self.assertNotIn("boundary", study.manifest)

    def test_regressions_reject_missing_workloads(self):
        study = self.study(True)
        study.args.cases = native.CASES[:-1]
        with self.assertRaisesRegex(ValueError, "every case and negative control"):
            study.source_variants(lambda path: b"unused")

    def test_regressions_cannot_measure(self):
        with self.assertRaisesRegex(ValueError, "cannot produce performance"):
            self.study(True).measure()

    def strict(self, current, baseline):
        study = self.study(False)
        with patch.object(native.support, "snapshot", side_effect=[current, baseline]):
            return study.source_variants(lambda path: b"unused")

    def test_historical_mode_keeps_original_baseline(self):
        baseline = snapshot(OLD)
        variants = self.strict(snapshot(NEW), baseline)
        self.assertEqual(variants[0], ("baseline", *baseline))

    def test_historical_mode_rejects_support_drift(self):
        with self.assertRaisesRegex(ValueError, "Unrelated production source changed"):
            self.strict(snapshot(NEW, b"changed"), snapshot(OLD))

    def test_historical_mode_rejects_outside_matcher_drift(self):
        with self.assertRaisesRegex(ValueError, "outside SourceVisibilityMatcher"):
            self.strict(snapshot(NEW, prefix=b"changed\n"), snapshot(OLD))

    def test_historical_mode_rejects_inventory_drift(self):
        current = snapshot(NEW)
        del current[0][SUPPORT]
        with self.assertRaisesRegex(ValueError, "inventories differ"):
            self.strict(current, snapshot(OLD))

    def test_historical_mode_rejects_no_focal_change(self):
        with self.assertRaisesRegex(ValueError, "No focal production change"):
            self.strict(snapshot(OLD), snapshot(OLD))

    def test_extraction_rejects_missing_duplicate_and_reversed_boundaries(self):
        for raw in [PREFIX, OLD + OLD + SUFFIX, SUFFIX + OLD]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                native.matcher_range(raw)

    def test_reference_diagnostics_keep_all_cases_and_negative_controls(self):
        study = self.study(True)
        study.packages = {"reference": None, "candidate": None}
        study.args.cases = native.CASES
        study.output = Path("unused")
        with patch.object(study, "run_case", return_value={
            "tree_build_count": 1, "visibility_build_count": 5,
        }) as run, patch.object(native, "save"):
            study.verify()
        self.assertEqual(run.call_count, len(native.CASES) * 3 * 2)
        self.assertEqual({call.args[0] for call in run.call_args_list}, {"reference", "candidate"})
        self.assertEqual({call.args[2] for call in run.call_args_list}, set(native.CASES))


if __name__ == "__main__":
    unittest.main()
