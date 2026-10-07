#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("feed", Path(__file__).parents[1] / "generate-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
init_spec = importlib.util.spec_from_file_location("initialize", Path(__file__).parents[1] / "initialize-update-feed.py")
initialize = importlib.util.module_from_spec(init_spec)
init_spec.loader.exec_module(initialize)

class UpdateFeedTests(unittest.TestCase):
    def check(self, xml, build):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(xml)
            feed.check_build_number(path, build)

    def test_empty_feed_accepts_first_build(self):
        self.check('<rss><channel/></rss>', '5')

    def test_checks_all_channels_and_legacy_enclosure_versions(self):
        xml = f'''<rss xmlns:sparkle="{feed.SPARKLE}"><channel>
        <item><sparkle:version>5</sparkle:version></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="7"/></item>
        </channel></rss>'''
        for build in ['4', '5', '7', '0', '2.0']:
            with self.assertRaises(ValueError): self.check(xml, build)
        self.check(xml, '8')

    def test_bad_history_is_not_silently_discarded(self):
        for xml in ['<html/>', '<rss><channel><item/></channel></rss>']:
            with self.assertRaises(ValueError): self.check(xml, '8')

    def test_existing_feed_must_verify_before_initialization_succeeds(self):
        for rejected in [False, True]:
            with self.subTest(rejected=rejected):
                calls = []
                def run(command, **kwargs):
                    calls.append(command)
                    if command[:2] == ['gh', 'api']:
                        return subprocess.CompletedProcess(command, 0, json.dumps({'assets': [{'name': 'appcast.xml'}]}), '')
                    if '--verify' in command and rejected:
                        raise subprocess.CalledProcessError(1, command)
                    return subprocess.CompletedProcess(command, 0)
                with patch.dict(os.environ, SPARKLE_PRIVATE_KEY='test-only', SPARKLE_PUBLIC_KEY='public'), \
                     patch.object(sys, 'argv', ['initialize', '--tools', '/tmp/test-tools']), \
                     patch.object(initialize.subprocess, 'check_output', return_value='public'), \
                     patch.object(initialize.subprocess, 'run', side_effect=run):
                    if rejected:
                        with self.assertRaises(subprocess.CalledProcessError): initialize.main()
                    else:
                        initialize.main()
                self.assertTrue(any('--verify' in command for command in calls))
                self.assertFalse(any(command[:3] in [['gh', 'release', 'create'], ['gh', 'release', 'upload']] for command in calls))

if __name__ == '__main__':
    unittest.main()
