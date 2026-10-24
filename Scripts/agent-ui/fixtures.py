#!/usr/bin/env python3
"""Generate small owned media fixtures for macOS agent UI scenarios."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import wave


def generate(output, audio_only=False):
    output = Path(output).resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError('Output must be absent or empty; existing evidence is never overwritten')
    output.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output / 'tone.wav'), 'wb') as stream:
        stream.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
        samples = (int(2500 * math.sin(2 * math.pi * 440 * i / 24000)) for i in range(24000 * 12))
        stream.writeframes(b''.join(struct.pack('<h', x) for x in samples))
    (output / 'captions.srt').write_text(
        '1\n00:00:00,500 --> 00:00:04,000\nAgent UI fixture one\n\n'
        '2\n00:00:05,000 --> 00:00:10,000\nAgent UI fixture two\n', encoding='utf-8')
    commands = []
    if not audio_only:
        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            raise ValueError('ffmpeg is required for video; use the native SDK environment or --audio-only')
        command = [ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
                   '-i', 'testsrc2=size=640x360:rate=30', '-i', str(output / 'tone.wav'),
                   '-t', '12', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
                   '-c:a', 'aac', '-movflags', '+faststart', str(output / 'video.mp4')]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        commands.append({'argv': command, 'returncode': result.returncode})
        (output / 'generation.log').write_text(result.stderr, encoding='utf-8')
        if result.returncode:
            raise ValueError('Video generation failed; inspect generation.log (native runtime library setup may be required)')
        playlist = output / 'playlist'
        playlist.mkdir()
        for name in ('Episode 01.mp4', 'Episode 02.mp4'):
            shutil.copy2(output / 'video.mp4', playlist / name)
    files = {str(p.relative_to(output)): {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                                        'bytes': p.stat().st_size}
             for p in sorted(output.rglob('*')) if p.is_file()}
    manifest = {'schema_version': 1, 'duration_seconds': 12, 'audio_only': audio_only,
                'files': files, 'commands': commands,
                'note': 'Generated test content. Compare recorded hashes, not presumed cross-toolchain bit equality.'}
    (output / 'fixtures.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return {'directory': str(output), 'manifest': str(output / 'fixtures.json'),
            'media': str(output / ('tone.wav' if audio_only else 'video.mp4'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--audio-only', action='store_true')
    args = parser.parse_args()
    try:
        data = generate(args.output, args.audio_only)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'schema_version': 1, 'status': 'error', 'data': {}, 'error': str(error)}))
        return 1
    print(json.dumps({'schema_version': 1, 'status': 'ok', 'data': data}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
