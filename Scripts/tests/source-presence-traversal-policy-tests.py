#!/usr/bin/env python3
"""Noncompiling controls for source policy and complete correctness execution."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('traversal', ROOT / 'Benchmarks/SourcePresenceTraversal/run.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / 'output'
        self.output.mkdir()
        self.here = self.root / 'Benchmarks/SourcePresenceTraversal'
        self.here.mkdir(parents=True)
        (self.here / 'Harness.swift').write_text('fixture harness')
        self.before = {p: b'unchanged' for p in m.CORE + m.APP}
        self.before[m.IDENTITY] = b'enum SourceTreeIdentity {\n}\nstruct SourcesSidebarExpansionSnapshot:'
        self.after = dict(self.before)
        self.after[m.SCANNER] = b'candidate scanner'
        self.support = m.CORE[0]
        self.after[self.support] = b'reviewed current support'
        for p, data in self.after.items():
            path = self.root / p
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for name in m.TESTS:
            path = self.root / 'Tests/IlliquidAppTests' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture test')
        for name, value in [('ROOT', self.root), ('HERE', self.here),
                            ('REGRESSION_SUPPORT', {self.support: m.digest(self.after[self.support])})]:
            p = patch.object(m, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.args = argparse.Namespace(output=self.output, regression_only=True,
            tests_only=False, skip_tests=False, swift='swift', cases=m.CASES, pairs=8, target_ms=250)
        before, output = self.before, self.output
        class FakeRunner:
            env = {}
            calls = []
            mismatch = False
            zero_tests = False
            def baseline(self, relative):
                return before[relative]
            def swift(self, variant, operation, configuration):
                return [variant, operation, configuration]
            def measure(self, *args):
                raise AssertionError('Correctness mode attempted measurement')
            def run(self, argv, label, **kwargs):
                self.calls.append(label)
                if label == 'baseline-revision': return m.BASELINE
                if label.endswith('-tests'):
                    return 'Test run with 0 tests passed' if self.zero_tests else 'Test run with 24 tests passed'
                if label.endswith('-binary-directory'):
                    directory = output / label
                    directory.mkdir()
                    (directory / m.PRODUCT).write_bytes(b'executable fixture')
                    return str(directory)
                if label.endswith('-verify-before'):
                    return json.dumps({'allIndependentWorkloads': m.CASES,
                        'oracle': 'bad' if self.mismatch and label.startswith('candidate-debug') else 'ok'})
                return ''
        self.runner = FakeRunner()
        self.runner.args = self.args
        self.runner.output = self.output

    def test_regression_shares_only_pinned_support_and_freezes_scanner(self):
        records = m.stage(self.runner)
        self.assertEqual((self.output / 'packages/baseline/Sources/IlliquidApp/SourceMediaPresenceScanner.swift').read_bytes(), self.before[m.SCANNER])
        for variant in ('baseline', 'candidate'):
            self.assertEqual(records[variant]['productionFiles'][self.support], m.digest(self.after[self.support]))
            self.assertEqual(records[variant]['historicalProductionFiles'][self.support], m.digest(self.before[self.support]))

    def test_strict_mode_rejects_support_drift(self):
        self.args.regression_only = False
        with self.assertRaisesRegex(RuntimeError, 'Non-scanner dependency'):
            m.stage(self.runner)

    def test_strict_historical_support_still_accepted(self):
        self.args.regression_only = False
        (self.root / self.support).write_bytes(self.before[self.support])
        m.stage(self.runner)

    def test_source_mutation_during_verification_rejected(self):
        original = self.runner.run
        def mutate(argv, label, **kwargs):
            result = original(argv, label, **kwargs)
            if label == 'candidate-release-verify-before':
                (self.output / 'packages/baseline/Sources/IlliquidCore/MediaFileSupport.swift').write_bytes(b'tampered')
            return result
        self.runner.run = mutate
        with self.assertRaisesRegex(RuntimeError, 'Staged source changed'):
            m.experiment(self.args, self.runner)

    def test_unreviewed_support_rejected(self):
        (self.root / self.support).write_bytes(b'unknown change')
        with self.assertRaisesRegex(RuntimeError, 'Unreviewed regression support'):
            m.stage(self.runner)

    def test_unrelated_dependency_rejected(self):
        (self.root / m.CORE[1]).write_bytes(b'unknown change')
        with self.assertRaisesRegex(RuntimeError, 'Non-scanner dependency'):
            m.stage(self.runner)

    def test_identity_drift_rejected(self):
        (self.root / m.IDENTITY).write_bytes(b'enum SourceTreeIdentity {\n changed\n}\nstruct SourcesSidebarExpansionSnapshot:')
        with self.assertRaisesRegex(RuntimeError, 'SourceTreeIdentity differs'):
            m.stage(self.runner)

    def test_complete_correctness_before_return_without_timing(self):
        m.experiment(self.args, self.runner)
        for variant in ('baseline', 'candidate'):
            for config in ('debug', 'release'):
                self.assertIn(f'{variant}-{config}-tests', self.runner.calls)
                self.assertIn(f'{variant}-{config}-verify-before', self.runner.calls)
        completion = json.loads((self.output / 'completion.json').read_text())
        self.assertFalse(completion['nativeQualificationSuccess'])
        self.assertFalse(completion['measurements'])
        self.assertFalse((self.output / 'summary.json').exists())

    def test_parity_failure_cannot_report_success(self):
        self.runner.mismatch = True
        with self.assertRaisesRegex(RuntimeError, 'traversal receipts differ'):
            m.experiment(self.args, self.runner)
        self.assertFalse((self.output / 'completion.json').exists())

    def test_zero_executed_tests_rejected(self):
        self.runner.zero_tests = True
        with self.assertRaisesRegex(RuntimeError, 'No positive test completion'):
            m.experiment(self.args, self.runner)

    def test_cli_rejects_skips_and_subsets_before_swift(self):
        for extra in (['--skip-tests'], ['--cases', m.CASES[0]]):
            with patch('sys.argv', ['run.py', '--output', str(self.output), '--regression-only', *extra]), patch.object(m.shutil, 'which') as which:
                with self.assertRaises(SystemExit) as error:
                    m.main()
                self.assertEqual(error.exception.code, 2)
                which.assert_not_called()


if __name__ == '__main__':
    unittest.main()
