#!/usr/bin/env python3
"""Noncompiling policy regressions using a disposable Git history."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('check-thumbnail-whitespace.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class Boundaries(unittest.TestCase):
    def test_event_boundaries(self):
        original = os.getcwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                g = policy.git
                g('init', '-b', 'main')
                g('config', 'user.email', 'policy@example.invalid')
                g('config', 'user.name', 'Policy test')
                def save(name, content):
                    Path(name).write_text(content)
                    g('add', name)
                    g('commit', '-m', name)
                    return g('rev-parse', 'HEAD')
                root = save('root', 'root\n')
                g('checkout', '-b', 'topic')
                head = save('feature', 'clean\n')
                g('checkout', 'main')
                base = save('historical.log', 'historical trailing space \n')
                g('update-ref', 'refs/remotes/origin/main', base)
                g('merge', '--no-ff', 'topic', '-m', 'synthetic merge')
                synthetic = g('rev-parse', 'HEAD')
                event = {'pull_request': {'base': {'sha': base}, 'head': {'sha': head}},
                         'repository': {'default_branch': 'main'}, 'after': head}
                for kind in ('pull_request', 'push', 'workflow_dispatch'):
                    with self.subTest(event=kind):
                        left, right = policy.boundary(kind, event, head)
                        self.assertEqual((left, right), (root, head))
                        g('diff', '--check', left, right)
                self.assertNotEqual(subprocess.run(['git', 'diff', '--check', root, synthetic], capture_output=True).returncode, 0)
                g('checkout', 'topic')
                bad = save('bad', 'new whitespace \n')
                event['after'] = bad
                event['pull_request']['head']['sha'] = bad
                for kind in ('pull_request', 'push', 'workflow_dispatch'):
                    left, right = policy.boundary(kind, event, bad)
                    self.assertNotEqual(subprocess.run(['git', 'diff', '--check', left, right], capture_output=True).returncode, 0)
                with self.assertRaises(ValueError):
                    policy.boundary('schedule', event, head)
                with self.assertRaises(ValueError):
                    policy.boundary('workflow_dispatch', event, base)
            finally:
                os.chdir(original)


if __name__ == '__main__':
    unittest.main()
