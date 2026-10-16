#!/usr/bin/env python3
"""Verify decoded AAC windows after seeking; differences are evidence, not hidden failures."""
import argparse, hashlib, json, subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--work', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
w, out = a.work.resolve(), a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
rows = []
for ext in ['mp4', 'mkv', 'ts']:
    for ordinal in [0, 1]:
        for target in [5, 47]:
            for mode in ['all', 'selected', 'read-only']:
                cmd = [str(w/'new-experiments/audio-seek-probe'),
                       str(w/f'fixtures/multiplex.{ext}'), str(ordinal), mode, str(target)]
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                row = dict(ext=ext, ordinal=ordinal, target=target, mode=mode,
                           command=cmd, exit=r.returncode, stderr=r.stderr)
                if r.returncode == 0:
                    row['result'] = json.loads(r.stdout)
                else:
                    row['stdout'] = r.stdout
                rows.append(row)
                (out/'partial.json').write_text(json.dumps(rows, indent=2))
                if r.returncode:
                    raise RuntimeError(f'{cmd}: {r.stderr}')
comparisons = []
for row in rows:
    if row['mode'] == 'all':
        continue
    base = next(x for x in rows if all(x[k] == row[k] for k in ['ext','ordinal','target'])
                and x['mode'] == 'all')['result']
    current = row['result']
    comparisons.append({**{k: row[k] for k in ['ext','ordinal','target','mode']},
        'early_equal': current['early_md5'] == base['early_md5'],
        'late_equal': current['late_md5'] == base['late_md5'],
        'counts_equal': all(current[k] == base[k] for k in ['early_samples','late_samples']),
        'first_sample_equal': current['first_sample_us'] == base['first_sample_us']})
(out/'audio-seek-verification.json').write_text(json.dumps(dict(rows=rows, comparisons=comparisons), indent=2))
(out/'manifest.json').write_text(json.dumps({str(path.name): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in [w/'new-experiments/audio_seek_probe.c', w/'new-experiments/audio-seek-probe',
                 *[w/f'fixtures/multiplex.{ext}' for ext in ['mp4','mkv','ts']]]}, indent=2))
(out/'partial.json').unlink()
print(json.dumps(dict(processes=len(rows), comparisons=len(comparisons),
                     early_differences=sum(not x['early_equal'] for x in comparisons),
                     late_differences=sum(not x['late_equal'] for x in comparisons))))
