#!/usr/bin/env python3
"""Build isolated Linux probes from exact research sources into a NEW workspace."""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess

p = argparse.ArgumentParser()
p.add_argument('--prefix', type=Path, required=True, help='FFmpeg 8.1.2 static build prefix')
p.add_argument('--output', type=Path, required=True, help='New probe workspace')
a = p.parse_args()
if platform.system() != 'Linux':
    p.error('These probes use Linux process accounting; use a Linux laboratory, not the native app build.')
prefix, out = a.prefix.resolve(), a.output.resolve()
if not (prefix/'include/libavformat/avformat.h').is_file():
    p.error('Missing libavformat headers in --prefix')
out.mkdir(parents=True, exist_ok=False)
src = out/'new-experiments'
shutil.copytree(Path(__file__).resolve().parent/'new-experiments', src)
(out/'evidence').mkdir()
commands = []
for name, executable in [('io_probe.c','io-probe'),('decode_modes.c','decode-modes'),('audio_seek_probe.c','audio-seek-probe')]:
    cmd = ['clang','-O2','-std=c11','-Wall','-Wextra','-Werror',f'-I{prefix}/include',
           str(src/name), f'-L{prefix}/lib','-lavformat','-lavcodec','-lavutil','-lm','-pthread','-o',str(src/executable)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    commands.append(dict(command=cmd, exit=r.returncode, stdout=r.stdout, stderr=r.stderr))
    (out/'evidence/build.json').write_text(json.dumps(commands, indent=2))
    if r.returncode:
        raise RuntimeError(r.stderr)
(out/'evidence/build-hashes.json').write_text(json.dumps({path.name:hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(src.iterdir()) if path.is_file()}, indent=2))
print(f'Built three isolated probes in {out}')
