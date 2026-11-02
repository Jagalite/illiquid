import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('runner', HERE / 'run.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class Policy(unittest.TestCase):
    def snapshot(self, regression, drift):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ['store.swift', 'support.swift', 'Harness.swift', 'run.py']:
                (root / name).write_bytes(b'current' if name == 'store.swift' or drift else b'historical')
            out = root / 'output'; out.mkdir()
            manifest = {}
            with patch.multiple(r, ROOT=root, HERE=root, STORE='store.swift', SOURCES=['store.swift', 'support.swift'], ENUMS={}), patch.object(r.subprocess, 'check_output', return_value=b'historical'), patch.object(r.subprocess, 'run', return_value=SimpleNamespace(stdout=b'diff')):
                sources = r.snapshot_sources(SimpleNamespace(output=out), manifest, regression)
            self.assertEqual(sources['baseline'][0].read_bytes(), b'historical')
            self.assertEqual(sources['candidate'][0].read_bytes(), b'current')
            self.assertEqual(sources['baseline'][1].read_bytes(), sources['candidate'][1].read_bytes())
            self.assertEqual(manifest['baseline_sources']['store.swift']['origin'], r.BASELINE)
    def test_regression_shares_current_support_not_store(self):
        self.snapshot(True, True)
    def test_strict_rejects_drift(self):
        with self.assertRaisesRegex(RuntimeError, 'dependency changed'):
            self.snapshot(False, True)
    def test_strict_accepts_unchanged_support(self):
        self.snapshot(False, False)
    def enum_snapshot(self, regression=False, neighbor_drift=False, enum_drift=False):
        declaration = b"public enum Example: String {\n    case original\n}\n"
        historical = declaration + b"// historical neighbor\n"
        current = (declaration.replace(b"original", b"changed") if enum_drift else declaration)
        current += b"// changed neighbor\n" if neighbor_drift else b"// historical neighbor\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, data in {"store.swift": b"current store", "owner.swift": current,
                               "Harness.swift": b"harness", "run.py": b"runner"}.items():
                (root / name).write_bytes(data)
            out = root / "output"
            out.mkdir()
            manifest = {}
            def historical_source(args, **kwargs):
                self.assertEqual(args[:2], ["git", "show"])
                self.assertTrue(args[2].startswith(r.BASELINE + ":"))
                return b"historical store" if args[2].endswith(":store.swift") else historical
            with patch.multiple(r, ROOT=root, HERE=root, STORE="store.swift",
                                SOURCES=["store.swift"], ENUMS={"owner.swift": "Example"}), \
                 patch.object(r.subprocess, "check_output", side_effect=historical_source), \
                 patch.object(r.subprocess, "run", return_value=SimpleNamespace(stdout=b"diff")):
                sources = r.snapshot_sources(SimpleNamespace(output=out), manifest, regression)
            self.assertEqual(sources["baseline"][0].read_bytes(), b"historical store")
            self.assertEqual(sources["candidate"][0].read_bytes(), b"current store")
            for key in ["full_sha256", "compiled_sha256"]:
                self.assertEqual(manifest["baseline_sources"]["owner.swift"][key],
                                 manifest["candidate_sources"]["owner.swift"][key])
            return manifest

    def test_strict_rejects_enum_owner_neighbor_drift(self):
        with self.assertRaisesRegex(RuntimeError, r"owner.swift \(full_sha256\)"):
            self.enum_snapshot(neighbor_drift=True)

    def test_strict_rejects_extracted_enum_drift(self):
        with self.assertRaisesRegex(RuntimeError, "dependency changed"):
            self.enum_snapshot(enum_drift=True)

    def test_strict_also_checks_compiled_hash(self):
        # Isolate the compiled-hash guard from the full-source guard.
        with patch.object(r, "sha256", side_effect=[
                "old-store", "old-store", "same-owner", "old-extraction",
                "new-store", "new-store", "same-owner", "new-extraction"]):
            with self.assertRaisesRegex(RuntimeError, r"owner.swift \(compiled_sha256\)"):
                self.enum_snapshot()

    def test_strict_accepts_unchanged_enum_owner_despite_origin_difference(self):
        manifest = self.enum_snapshot()
        self.assertNotEqual(manifest["baseline_sources"]["owner.swift"]["origin"],
                            manifest["candidate_sources"]["owner.swift"]["origin"])

    def test_regression_shares_current_enum_owner_and_preserves_historical_store(self):
        self.enum_snapshot(regression=True, neighbor_drift=True, enum_drift=True)

    def test_workloads(self):
        self.assertEqual(len(r.workloads(False)), 13)
    def test_no_measurement_and_routing(self):
        runner = (HERE / 'run.py').read_text()
        harness = (HERE / 'Harness.swift').read_text()
        workflow = (HERE.parents[1] / '.github/workflows/history-encoding.yml').read_text()
        self.assertIn('if args.quick or args.mode != "all"', runner)
        self.assertIn('if args.regression and "mutation_flush_ns" in row', runner)
        self.assertIn('measure ? DispatchTime.now()', harness)
        self.assertIn('if measure { elapsed.append', harness)
        self.assertIn('if measure { receipt["mutation_flush_ns"]', harness)
        self.assertIn('if test "$GITHUB_EVENT_NAME" = pull_request; then\n            mode+=(--regression)', workflow)

if __name__ == '__main__':
    unittest.main()
