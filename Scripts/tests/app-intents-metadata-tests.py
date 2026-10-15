import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('intent_metadata', Path(__file__).resolve().parents[1] / 'app-intents-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)

class AppIntentsMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_prepare_removes_stale_constants(self):
        constants = self.root / 'IlliquidApp.swiftconstvalues'
        constants.write_text('old')
        metadata.prepare(self.root)
        self.assertFalse(constants.exists())
        self.assertIn('AppIntent', json.loads((self.root / 'protocols.json').read_text()))

    def test_compiler_metadata_requires_all_action_types(self):
        constants = self.root / 'IlliquidApp.swiftconstvalues'
        constants.write_text(json.dumps([{'typeName': 'IlliquidApp.' + name} for name in metadata.INTENTS]))
        metadata.validate_constants(constants)
        constants.write_text(json.dumps([{'typeName': 'Unrelated'}]))
        with self.assertRaisesRegex(ValueError, 'missing actions'):
            metadata.validate_constants(constants)

    def test_missing_or_empty_metadata_is_not_success(self):
        with self.assertRaisesRegex(ValueError, 'missing'):
            metadata.validate_resources(self.root)
        directory = self.root / 'Metadata.appintents'
        directory.mkdir()
        (directory / 'extract.actionsdata').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'missing actions'):
            metadata.validate_resources(self.root)

    def test_generated_catalog_requires_each_action(self):
        directory = self.root / 'Metadata.appintents'
        directory.mkdir()
        path = directory / 'extract.actionsdata'
        path.write_text(json.dumps({'actions': [{'identifier': 'IlliquidApp.' + name} for name in metadata.INTENTS]}))
        result = metadata.validate_resources(self.root)
        self.assertEqual(result['actions'], sorted(metadata.INTENTS))
        self.assertEqual(result['files'], ['Metadata.appintents/extract.actionsdata'])

    @unittest.skipUnless(shutil.which('swift'), 'Swift compiler unavailable')
    def test_manifest_reloads_environment_when_rebuilding_constants(self):
        """Regression for packaging's absent .swiftconstvalues after SwiftPM caching.

        Keep the build scratch directory fixed, change only the environment
        output directory, and require both compiler artifacts. The production
        packaging command must likewise opt out of manifest caching.
        """
        repository = Path(__file__).resolve().parents[2]
        build_script = (repository / 'Scripts/build-illiquid-app.sh').read_text()
        self.assertIn('--manifest-cache none', build_script)
        self.assertIn('ILLIQUID_INTENTS_BUILD_DIRECTORY', build_script)

        fixture = self.root / 'Package'
        sources = fixture / 'Sources' / 'Demo'
        sources.mkdir(parents=True)
        (fixture / 'Package.swift').write_text('''// swift-tools-version: 6.1
import Foundation
import PackageDescription
let settings: [SwiftSetting] = ProcessInfo.processInfo.environment["INTENTS_COMPILE_DIR"].map { path in
    [.unsafeFlags(["-Xfrontend", "-const-gather-protocols-file", "-Xfrontend",
                   path + "/protocols.json", "-Xfrontend", "-emit-const-values-path",
                   "-Xfrontend", path + "/Demo.swiftconstvalues"],
                  .when(configuration: .release))]
} ?? []
let package = Package(name: "Demo", targets: [
    .executableTarget(name: "Demo", swiftSettings: settings)
])
''', encoding='utf-8')
        (sources / 'main.swift').write_text(
            'protocol IntentMarker {}\n'
            'struct CapturedAction: IntentMarker { static let title = "present" }\n'
            'print(CapturedAction.title)\n', encoding='utf-8')

        for round_number in (1, 2):
            output = self.root / f'compile output {round_number}'
            output.mkdir()
            (output / 'protocols.json').write_text('["IntentMarker"]')
            environment = dict(os.environ, INTENTS_COMPILE_DIR=str(output))
            command = ["swift", "build", "--package-path", str(fixture),
                       "--scratch-path", str(self.root / 'scratch'),
                       "--configuration", "release", "--manifest-cache", "none"]
            process = subprocess.run(command, env=environment, capture_output=True,
                                     text=True, timeout=120)
            self.assertEqual(process.returncode, 0, process.stderr[-3000:])
            constants = output / 'Demo.swiftconstvalues'
            self.assertTrue(constants.is_file(), f'Round {round_number}: no compiler constants')
            self.assertIn('CapturedAction', constants.read_text())

    def test_symlink_catalog_is_rejected(self):
        directory = self.root / 'Metadata.appintents'
        directory.mkdir()
        external = self.root / 'external'
        external.write_text(json.dumps(sorted(metadata.INTENTS)))
        (directory / 'extract.actionsdata').symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'Invalid'):
            metadata.validate_resources(self.root)

if __name__ == '__main__':
    unittest.main()
