#!/usr/bin/env python3
"""Serial native qualification of the reviewed October 24 PR integration.

Submit this script through Kyoto when available. It writes fresh receipts and
uses synthetic media without launching the product UI.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
FILTER = '|'.join([
    'PlaylistDeduplication', 'PlaylistSessionRecord', 'ReadOnlyStartupLoader',
    'SourceStartupSnapshot', 'PlaybackCoordinatorTests', 'AudioDelay',
    'AudioResamplerDrain', 'MultichannelAudio', 'VideoDeinterlacer',
    'DeinterlacerEOFMemory', 'SourceMediaPresence', 'ExternalSubtitle',
    'AuxiliaryFont', 'FontAttachmentAdmission', 'NativePlaybackFoundation',
    'InputReadFailure', 'MediaSectionGroupingMemory', 'SourceMediaOrganization',
    'SourceBrowserFilter', 'SourceBrowserSearch', 'SourceTreeVisibility',
    'SourceEmptyFolderVisibility', 'SourceVisibilityStorage', 'SubtitleStagingReuse',
    'MetalASSSubtitleCompositor', 'PiPSubtitlePipeline', 'PiPSubtitleUploadReuse',
    'NativeOperationWorkLifetime', 'NativeAuthority', 'NativeOperation',
    'PlanarOwnership', 'MediaSidecar', 'PlexMatch', 'ThumbnailImageLifetime',
    'ThumbnailDisk', 'NativeThumbnailCache', 'StandardCompletionContract',
    'EffectCompletion', 'VideoScratchFrameLifetime', 'VideoTimestampDiscovery',
])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--swift', default='swift')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    commands = []

    def run(name, command):
        command = list(map(str, command))
        started = time.time()
        print('RUN', name, json.dumps(command), flush=True)
        with (output / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                    stderr=subprocess.STDOUT)
        commands.append({'name': name, 'command': command, 'started': started,
                         'finished': time.time(), 'returncode': result.returncode})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if result.returncode:
            raise SystemExit(f'{name} failed ({result.returncode}); see {output / (name + ".log")}')

    (output / 'head.txt').write_text(subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True))
    run('native-fixtures', ['zsh', 'Scripts/generate-native-fixtures.sh', output / 'native-fixtures'])
    run('frame-fixtures', ['python3', 'Benchmarks/FrameStepTimestamps/generate-fixtures.py',
                           '--output', output / 'frame-fixtures'])
    run('font-fixtures', ['python3', 'Benchmarks/AuxiliaryFontAttachments/generate-fixtures.py',
                          '--output', output / 'font-fixtures'])
    env.update({
        'ILLIQUID_NATIVE_FIXTURE_DIR': str(output / 'native-fixtures'),
        'ILLIQUID_FRAME_STEP_FIXTURE_DIR': str(output / 'frame-fixtures'),
        'ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE': str(output / 'font-fixtures/attachment-admission.mkv'),
        'ILLIQUID_AUXILIARY_FONT_PLAYBACK_FIXTURE': str(output / 'font-fixtures/embedded-ass-font.mkv'),
    })
    run('native-tests', [args.swift, 'test', '--force-resolved-versions', '-c', 'release',
                         '--jobs', '2', '--no-parallel', '--filter', FILTER])
    run('planar-history', ['python3', 'Benchmarks/PlanarHistoryMemory/run.py',
                           '--output', output / 'planar-history', '--pairs', '6'])
    run('thumbnail-read', ['python3', 'Benchmarks/ThumbnailReadAllocation/run.py',
                           '--output', output / 'thumbnail-read', '--pairs', '8'])
    (output / 'completion.json').write_text(json.dumps({
        'status': 'passed', 'commands': len(commands), 'ui_qualified': False}, indent=2) + '\n')
    print('PASSED', output, flush=True)


if __name__ == '__main__':
    main()
