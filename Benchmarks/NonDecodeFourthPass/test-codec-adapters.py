#!/usr/bin/env python3
"""Static adapter regressions. No Swift compiler or generated binary is executed."""
import pathlib
import platform
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD_PATH = ROOT / 'Benchmarks/NonDecodeFourthPass/build.py'
BUILD = runpy.run_path(str(BUILD_PATH))
CURRENT = ROOT / 'Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift'
IMPORTS = ('CoreGraphics', 'CryptoKit', 'IlliquidCore', 'ImageIO', 'UniformTypeIdentifiers')
VARIANTS = {
    'preview/baseline': ROOT / 'Benchmarks/NonDecodeFollowup/fixtures/NativeThumbnailDiskCache.swift',
    'preview/candidate': CURRENT,
    'inventory/v2': ROOT / 'Benchmarks/NonDecodeThirdPass/baseline/NativeThumbnailDiskCacheV2.swift',
    'inventory/v3': CURRENT,
    'physical/v3': ROOT / 'Benchmarks/NonDecodeFourthPass/baseline/NativeThumbnailDiskCacheV3.swift',
    'physical/accounting': ROOT / 'Benchmarks/NonDecodeFourthPass/baseline/NativeThumbnailDiskCacheAccounting.swift',
    'physical/v4': CURRENT,
}


def function_span(source, name):
    """Independent extraction for assertions on the checked-in Swift layout."""
    matches = list(re.finditer(r'^    [^\n]*\bfunc ' + name + r'\(', source, re.MULTILINE))
    if len(matches) != 1:
        raise AssertionError(f'Expected one {name}, got {len(matches)}')
    start = matches[0].start()
    body = source.index('\n', start) + 1
    end = source.index('\n    }', body) + len('\n    }')
    return start, body, end


def function_text(source, name):
    start, _, end = function_span(source, name)
    return source[start:end]


def without_codecs(source):
    """Mask only permitted codec edits, exposing any change to surrounding code."""
    has_decoder = bool(re.search(r'\bfunc readImage\(', source))
    for name in (('readImage', 'encode') if has_decoder else ('encode',)):
        _, body, end = function_span(source, name)
        source = source[:body] + '<codec>\n    }' + source[end:]
    if not has_decoder:
        original_guard = '        guard let source = CGImageSourceCreateWithURL'
        adapted_guard = '        // TEST CODEC ADAPTER: historical fixtures'
        start = source.index(original_guard if original_guard in source else adapted_guard)
        end = source.index('        else { removeDisk(digest); return nil }', start)
        source = source[:start] + '<codec>\n' + source[end:]
    return source


class CodecAdapterTests(unittest.TestCase):
    def assert_preserves_source(self, original, generated, current):
        # This compares all non-codec bytes, including every accounting helper,
        # the asynchronous encoder property and current insertion size checks.
        self.assertEqual(without_codecs(original), without_codecs(generated))
        self.assertNotIn('CGImageSource', generated)
        self.assertNotIn('CGImageDestination', generated)
        self.assertIn('image.width <= key.width, image.height <= key.height', generated)
        if current:
            self.assertEqual(function_text(original, 'image'), function_text(generated, 'image'))
            self.assertEqual(function_text(original, 'readEncodedImage'),
                             function_text(generated, 'readEncodedImage'))
            self.assertIn('guard let data = readEncodedImage(at: url),',
                          function_text(generated, 'readImage'))
            self.assertNotIn('Data(contentsOf:', function_text(generated, 'readImage'))
            self.assertIn('static let maximumEncodedImageBytes = 16 * 1024 * 1024', generated)
            self.assertIn('let initialByteCount = try handle.seekToEnd()', generated)
            self.assertIn('guard initialByteCount <= UInt64(maximumEncodedImageBytes)', generated)
            self.assertIn('var data = Data()', generated)
            self.assertIn('if initialByteCount > 64 * 1024 {', generated)
            self.assertIn('data.reserveCapacity(Int(initialByteCount))', generated)
            self.assertIn('while data.count <= maximumEncodedImageBytes', generated)
            self.assertIn('min(64 * 1024, maximumEncodedImageBytes + 1 - data.count)', generated)
        else:
            self.assertIn('try? Data(contentsOf:', generated)
            self.assertNotIn('readEncodedImage', generated)
            self.assertNotIn('maximumEncodedImageBytes', generated)

    def test_all_entrypoints_generate_every_variant(self):
        commands = []
        with tempfile.TemporaryDirectory(prefix='.codec-adapter-tests-', dir=ROOT) as temporary:
            output = pathlib.Path(temporary)

            def fake_run(command, **kwargs):
                command = list(map(str, command))
                commands.append(command)
                if command == ['swiftc', '--version']:
                    stdout = 'MOCK: no Swift compiler executed\n'
                elif command[0] == 'swiftc' and '-o' in command:
                    binary = pathlib.Path(command[command.index('-o') + 1])
                    self.assertTrue(binary.is_relative_to(output))
                    binary.write_bytes(b'MOCK: not an executable\n')
                    stdout = ''
                else:
                    # Preview's CLI always asks its binary for tests. Stub that
                    # result too; this suite makes no Swift correctness claim.
                    self.assertEqual(command[1:], ['tests'])
                    self.assertEqual(pathlib.Path(command[0]).name, 'preview')
                    self.assertTrue(pathlib.Path(command[0]).is_relative_to(output))
                    stdout = '{}'
                return subprocess.CompletedProcess(command, 0, stdout, '')

            with mock.patch.object(subprocess, 'run', side_effect=fake_run), \
                    mock.patch.object(platform, 'platform', return_value='mock-platform'):
                for script, directory, flag in (
                    ('NonDecodeFollowup/run-preview.py', 'preview', '--tests-only'),
                    ('NonDecodeThirdPass/run-inventory.py', 'inventory', '--build-only'),
                ):
                    filename = ROOT / 'Benchmarks' / script
                    with mock.patch.object(sys, 'argv', [str(filename), '--output', str(output / directory), flag]):
                        runpy.run_path(str(filename), run_name='__main__')
                BUILD['build'](output / 'physical')

            for variant, source_path in VARIANTS.items():
                with self.subTest(variant=variant):
                    source = source_path.read_text()
                    for name in IMPORTS:
                        source = source.replace('import ' + name + '\n', '')
                    generated = (output / variant / 'Disk.swift').read_text()
                    # The runners append their inspection-only extension.
                    generated = generated.split('\nextension NativeThumbnailDiskCache {', 1)[0]
                    self.assert_preserves_source(source.rstrip(), generated.rstrip(), source_path == CURRENT)
            self.assertEqual(sum(command[0] == 'swiftc' and '-o' in command for command in commands), 7)

    def test_current_decoder_access_levels_preserve_all_other_code(self):
        original = CURRENT.read_text()
        declaration = '    nonisolated static func readImage('
        for access in ('', 'private ', 'internal '):
            with self.subTest(access=access):
                source = original.replace(declaration, '    ' + access + 'nonisolated static func readImage(')
                adapted = BUILD['adapt_disk_codecs'](source, CURRENT)
                self.assert_preserves_source(source, adapted, current=True)

    def test_missing_or_ambiguous_functions_fail_closed(self):
        source = CURRENT.read_text()
        for name in ('image', 'readImage', 'readEncodedImage', 'encode'):
            block = function_text(source, name)
            for mutation in ('missing', 'duplicate'):
                with self.subTest(function=name, mutation=mutation):
                    changed = source.replace(block, '') if mutation == 'missing' else source + '\n' + block
                    with self.assertRaises(ValueError):
                        BUILD['adapt_disk_codecs'](changed, CURRENT)
        # One private and one internal decoder used to pass a first-marker check.
        private = function_text(source, 'readImage').replace('    nonisolated', '    private nonisolated', 1)
        with self.assertRaisesRegex(ValueError, 'unambiguous readImage'):
            BUILD['adapt_disk_codecs'](source + '\n' + private, CURRENT)

    def test_missing_closing_brace_cannot_consume_an_adjacent_helper(self):
        source = CURRENT.read_text()
        for name in ('readImage', 'readEncodedImage', 'encode'):
            with self.subTest(function=name):
                block = function_text(source, name)
                changed = source.replace(block, block.removesuffix('    }'))
                with self.assertRaisesRegex(ValueError, 'unambiguous ' + name):
                    BUILD['adapt_disk_codecs'](changed, CURRENT)

    def test_legacy_fallback_requires_known_path_and_exact_fixture(self):
        for relative in BUILD['LEGACY_DISK_FIXTURES']:
            fixture = ROOT / relative
            source = fixture.read_text()
            for source_path, content in (
                (fixture, source + '\n'),
                (fixture, CURRENT.read_text()),
                (CURRENT, source),
                (ROOT / 'unknown-disk-source.swift', source),
            ):
                with self.subTest(fixture=relative, source_path=str(source_path)):
                    with self.assertRaises(ValueError):
                        BUILD['adapt_disk_codecs'](content, source_path)

    def test_unknown_build_variant_is_rejected_before_compiler_invocation(self):
        with mock.patch.object(subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'Unknown disk source variant'):
                BUILD['build'](ROOT / 'unused-adapter-output', variants=('unknown',))
            command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
