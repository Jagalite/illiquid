#!/usr/bin/env python3
"""Python/Git-only CI base selection tests; no product compilation."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("whitespace", Path(__file__).with_name("check-ci-whitespace.py"))
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class WhitespaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.temp.name)
        checker.git("init", "--initial-branch=main")
        checker.git("config", "user.email", "test@example.invalid")
        checker.git("config", "user.name", "Whitespace test")
        self.root = self.save("original.txt", "original\n")
        # Preserve unrelated historical whitespace on main; it must not fail a PR.
        self.main = self.save("historical.log", "preserved evidence  \n")
        checker.git("update-ref", "refs/remotes/origin/main", self.main)
        checker.git("switch", "-c", "topic")
        self.head = self.save("changed.txt", "valid\n")
        self.repository = {"default_branch": "main"}

    def tearDown(self):
        os.chdir(self.previous)
        self.temp.cleanup()

    def save(self, name, content):
        Path(name).write_text(content)
        checker.git("add", name)
        checker.git("commit", "-m", "fixture", "--no-verify")
        return checker.commit("HEAD")

    def result(self, receipt):
        return subprocess.run(receipt["command"], capture_output=True).returncode

    def pr(self, head):
        return {"pull_request": {"base": {"sha": self.main}, "head": {"sha": head}}}

    def test_pr_excludes_history_but_checks_modified_evidence(self):
        receipt = checker.comparison("pull_request", self.pr(self.head))
        self.assertEqual(receipt["comparison_base"], self.main)
        self.assertEqual(self.result(receipt), 0)
        bad = self.save("historical.log", "preserved evidence  \nnew whitespace  \n")
        self.assertNotEqual(self.result(checker.comparison("pull_request", self.pr(bad))), 0)

    def test_pr_uses_event_head_even_when_checkout_is_merge_commit(self):
        checker.git("switch", "main")
        self.save("main-only.log", "unrelated new whitespace  \n")
        checker.git("merge", "--no-edit", "topic")
        receipt = checker.comparison("pull_request", self.pr(self.head))
        self.assertNotEqual(receipt["checkout_head"], receipt["head"])
        self.assertEqual(receipt["head"], self.head)
        self.assertEqual(self.result(receipt), 0)

    def test_push_new_branch_and_manual_resolve_default_branch(self):
        for name in ("push", "workflow_dispatch"):
            receipt = checker.comparison(name, {"repository": self.repository,
                                                "after": self.head, "before": "0" * 40})
            self.assertEqual(receipt["comparison_base"], self.main)
            self.assertEqual(self.result(receipt), 0)

    def test_default_branch_push_checks_before_and_manual_checks_parent(self):
        checker.git("update-ref", "refs/remotes/origin/main", self.head)
        for name, policy in (("push", "push-before"), ("workflow_dispatch", "head-parent")):
            receipt = checker.comparison(name, {"repository": self.repository,
                                                "after": self.head, "before": self.main})
            self.assertEqual(receipt["policy"], policy)
            self.assertEqual(receipt["comparison_base"], self.main)

    def test_explicit_base_and_missing_ref(self):
        self.assertEqual(self.result(checker.comparison("local", {}, self.main)), 0)
        with self.assertRaises(subprocess.CalledProcessError):
            checker.comparison("local", {}, "missing-ref")
        with self.assertRaises(ValueError):
            checker.comparison("local", {})


if __name__ == "__main__":
    unittest.main()
