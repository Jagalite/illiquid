"""Noncompiling controls for source selection and timing prohibition."""
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import run

class Policy(unittest.TestCase):
    def runner(self, regression):
        runner = object.__new__(run.Runner)
        runner.args = SimpleNamespace(current_source_regression=regression)
        runner.command = lambda argv: tuple(argv)
        return runner

    def test_pinned_oracle_and_shared_current_support(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(run, 'ROOT', Path(tmp)):
            for path in [*run.CORE, run.PLAYER]:
                target = Path(tmp) / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('current:' + path)
            runner = self.runner(True)
            self.assertEqual(runner.source('baseline', run.PLAYER),
                             ('git', 'show', f'{run.BASELINE}:{run.PLAYER}'))
            self.assertEqual(runner.source('candidate', run.PLAYER), 'current:' + run.PLAYER)
            for path in run.CORE:
                self.assertEqual(runner.source('baseline', path), runner.source('candidate', path))
                self.assertEqual(self.runner(False).source('baseline', path),
                                 ('git', 'show', f'{run.BASELINE}:{path}'))

    def test_timing_cannot_reach_binary_or_calibration(self):
        runner = self.runner(True)
        with self.assertRaisesRegex(RuntimeError, 'Timing forbidden'):
            runner.measure()
        with self.assertRaisesRegex(RuntimeError, 'Timing forbidden'):
            runner.invoke('candidate', 'release', (1000, 'last'), 1)
        self.runner(False).require_timing()

    def test_exact_workloads(self):
        self.assertEqual(run.CASES, [(0,'missing'), (1,'first'), (1,'missing'),
            (32,'first'), (32,'last'), (32,'missing'), (1000,'first'),
            (1000,'middle'), (1000,'last'), (1000,'missing'), (10000,'first'),
            (10000,'last'), (10000,'missing'), (1000,'remote'), (1000,'invalid')])
        self.assertEqual(run.BASELINE, 'ea2ff568237e2667f7b1aeee67b11a44ebe95b72')

if __name__ == '__main__':
    unittest.main()
