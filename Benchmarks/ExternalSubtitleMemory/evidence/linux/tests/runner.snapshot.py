import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path('/workspace/scratch/94f997e8d947/illiquid')
output = Path('/tmp/illiquid-subtitle-test-evidence')
output.mkdir(exist_ok=True)
source_path = Path('Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift')
baseline = subprocess.check_output(['git', 'show', 'af1c1ad:' + str(source_path)], cwd=root)
env = dict(os.environ)
env['PATH'] = '/tmp/illiquid-swift-toolchain/usr/bin:' + env['PATH']
env['LD_LIBRARY_PATH'] = '/tmp/illiquid-swift-deps/usr/lib/x86_64-linux-gnu'
env['CLANG_MODULE_CACHE_PATH'] = '/tmp/illiquid-swift-cache/clang'
env['SWIFTPM_MODULECACHE_OVERRIDE'] = '/tmp/illiquid-swift-cache/modules'
records = []
for variant in ('baseline', 'candidate'):
    staging = output / variant
    (staging / source_path.parent).mkdir(parents=True, exist_ok=True)
    source = baseline if variant == 'baseline' else (root / source_path).read_bytes()
    (staging / source_path).write_bytes(source)
    for path in [Path('Scripts/test-external-subtitle-regressions.sh'),
                 Path('Tests/IlliquidNativePlaybackTests/ExternalTextSubtitleConverterTests.swift'),
                 Path('Tests/IlliquidNativePlaybackTests/ExternalSubtitleEscapingTests.swift')]:
        (staging / path.parent).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / path, staging / path)
    for mode in ('debug', 'release'):
        command = ['bash', str(staging / 'Scripts/test-external-subtitle-regressions.sh'),
                   '-c', mode, '--jobs', '2', '-Xswiftc', '-warnings-as-errors',
                   '--cache-path', '/tmp/illiquid-swift-cache/packages',
                   '--config-path', '/tmp/illiquid-swift-cache/config',
                   '--security-path', '/tmp/illiquid-swift-cache/security']
        log = output / f'{variant}-{mode}.log'
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT)
        record = {'variant': variant, 'mode': mode, 'returncode': result.returncode,
                  'source_sha256': hashlib.sha256(source).hexdigest(), 'command': command,
                  'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()}
        records.append(record)
        (output / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
        summary = [line for line in log.read_text().splitlines() if 'Test run with' in line]
        print(variant, mode, result.returncode, summary, flush=True)
        if result.returncode:
            print(log.read_text()[-8000:], flush=True)
            raise SystemExit(result.returncode)
