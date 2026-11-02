#!/usr/bin/env python3
"""Noncompiling policy controls: execute the runner with intercepted tools."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('palette_runner', HERE / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PolicyTests(unittest.TestCase):
    def test_timing_and_partial_requests_rejected_before_io(self):
        for extra in ([], ['--receipts-only', '--cases', 'one'],
                      ['--tests-only', '--kernels', 'hit'],
                      ['--receipts-only', '--cpu', '0'],
                      ['--tests-only', '--receipts-only']):
            with self.subTest(extra=extra), patch.object(sys, 'argv', [
                'run.py', '--output', '/unused', '--current-support-regression-only', *extra
            ]), patch.object(Path, 'mkdir', side_effect=AssertionError('unexpected IO')):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    runner.main()
                self.assertEqual(error.exception.code, 2)

    def test_support_policy_and_snapshot(self):
        # Execute the exact source capture block, stopping before any compiler.
        source = (HERE / 'run.py').read_text()
        block = source[source.index('        support_metadata = {}'):source.index('        shutil.copyfile(baseline_path')]
        import textwrap
        from types import SimpleNamespace
        for mode, current, succeeds in ((False, 'historic', True),
                                        (False, 'changed', False), (True, 'changed', True)):
            with self.subTest(mode=mode, current=current), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'input.swift').write_text(current)
                snapshot = root / 'sources'
                snapshot.mkdir()
                env = dict(vars(runner), ROOT=root, SUPPORT={'support.swift': Path('input.swift')},
                           sources=snapshot, baseline_metadata={'commit': 'pinned'},
                           args=SimpleNamespace(current_support_regression_only=mode),
                           run=lambda command: 'historic')
                if not succeeds:
                    with self.assertRaisesRegex(RuntimeError, 'Common support changed'):
                        exec(textwrap.dedent(block), env)
                    continue
                exec(textwrap.dedent(block), env)
                (root / 'input.swift').write_text('later mutation')
                self.assertEqual((snapshot / 'support.swift').read_text(), current)
                record = env['support_metadata']['support.swift']
                self.assertEqual(record['sha256'], runner.digest_bytes(current.encode()))
                self.assertEqual(record['historical_sha256'], runner.digest_bytes(b'historic'))
                self.assertEqual(record['matches_baseline'], current == 'historic')
                self.assertEqual(record['used_by'], ['baseline', 'candidate'])

    def test_boundary_negative_controls(self):
        source = 'prefix' + runner.PALETTE_START + 'body' + runner.PALETTE_END + 'suffix'
        self.assertEqual(runner.unchanged_theme_support(source),
                         runner.unchanged_theme_support(source.replace('body', 'candidate')))
        self.assertNotEqual(runner.unchanged_theme_support(source),
                            runner.unchanged_theme_support(source.replace('prefix', 'drift')))
        for invalid in (source.replace(runner.PALETTE_START, ''), source + runner.PALETTE_START):
            with self.assertRaises(ValueError):
                runner.unchanged_theme_support(invalid)

    def test_frozen_baseline_guard_precedes_compiler(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'baseline').mkdir()
            (root / 'baseline/manifest.json').write_text(json.dumps({'sha256': 'wrong'}))
            (root / 'baseline/PlayerTheme.swift').write_text('tampered')
            with patch.object(runner, 'HERE', root), patch.object(sys, 'argv', [
                'run.py', '--output', str(root / 'out'), '--tests-only',
                '--current-support-regression-only'
            ]), patch.object(runner.subprocess, 'run', side_effect=AssertionError('compiler invoked')):
                with self.assertRaisesRegex(RuntimeError, 'Frozen PlayerTheme baseline'):
                    runner.main()


if __name__ == '__main__':
    unittest.main()
