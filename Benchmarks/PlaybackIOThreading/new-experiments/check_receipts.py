#!/usr/bin/env python3
"""Validate completed experiment identities, order, provenance and output contracts.
No speed threshold: negative controls and semantic differences remain in evidence.
"""
from pathlib import Path
from collections import Counter, defaultdict
import argparse, hashlib, json

p = argparse.ArgumentParser()
p.add_argument('--work', type=Path, required=True)
p.add_argument('--evidence', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
w = a.work.resolve()
e = a.evidence.resolve() if a.evidence else w/'evidence'
checks = 0

def require(ok, description):
    global checks
    checks += 1
    if not ok:
        raise AssertionError(description)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines()]

io = jsonl(e/'io-final/rows.jsonl')
dec = jsonl(e/'decode-modes-final/rows.jsonl')
audio = json.loads((e/'audio-seek-verification.json').read_text())
require(len(io) == 428, '428 I/O processes')
require(Counter(r['cohort'] for r in io) == dict(semantic=144, **{'buffer-parity':66,'native-timing':110,'buffer-timing':90,'injected-latency':18}), 'I/O cohort counts')
require([r['sequence'] for r in io] == list(range(1,len(io)+1)), 'I/O sequence is complete')
require(all(r['returncode'] == 0 and r['result']['ffmpeg'] == '8.1.2' for r in io), 'All I/O runs succeed with FFmpeg 8.1.2')
keys = [tuple(r[k] for k in ['cohort','file','role','mode','buffer','phase','target','round','delay']) for r in io]
require(len(keys) == len(set(keys)), 'Unique I/O identities')
# Inspect ACTUAL emitted process order, not only scheduling code.
groups = defaultdict(list)
for r in io:
    if not r['verify']:
        key = tuple(r[k] for k in ['cohort','file','role','buffer','round','delay'])
        groups[key].append(r['mode'])
for key, modes in groups.items():
    require(modes == (['all','selected'] if key[-2] % 2 == 0 else ['selected','all']), f'Actual AB/BA order: {key}')
sem = {tuple(r[k] for k in ['file','role','phase','target','mode']):r['result'] for r in io if r['cohort']=='semantic'}
for key, result in sem.items():
    base = sem[(*key[:-1], 'all')]
    require(result['metadata_md5'] == base['metadata_md5'], f'Metadata receipt {key}')
    if key[2] == 'scan':
        require(result['packet_md5'] == base['packet_md5'] and result['selected_packets']==base['selected_packets'], f'Full scan selected packets {key}')
for r in io:
    if r['cohort'] == 'buffer-parity':
        base = sem[(r['file'], r['role'], 'scan', 0, r['mode'])]
        require(all(base[k] == r['result'][k] for k in ['packet_md5','metadata_md5','selected_packets','first_us','last_us']), f'Buffer parity {r["sequence"]}')
comp = json.loads((e/'io-final/semantic-comparison.json').read_text())
require(len(comp)==96, '96 semantic baseline comparisons')
differences = [r for r in comp if not r['packet_receipt_equal']]
# Retain these findings. They are NOT a passing production discard policy.
require(len(differences)==18, '18 recorded seek/frontier differences are preserved')
require(len(dec)==60 and sum(not r['verify'] for r in dec)==54, '54 decode timings + 6 verifications')
require([r['sequence'] for r in dec]==list(range(1,len(dec)+1)), 'Decoder sequence complete')
require(all(r['exit']==0 for r in dec), 'All decode runs completed')
require(len(set((r['fixture'],r['round'],r['verify'],r['delay_us'],r['threads'],r['strategy']) for r in dec))==len(dec), 'Unique decoder identities')
order = [('1','default'),('4','frame'),('4','slice')]
dgroups = defaultdict(list)
for r in dec:
    dgroups[(r['fixture'],r['verify'],r['delay_us'],r['round'])].append((r['threads'],r['strategy']))
    result = r['result']
    require(result['configured_threads'] == int(r['threads']), 'Actual thread count')
    require(result['active_thread_type'] == {'default':0,'frame':1,'slice':2}[r['strategy']], 'Actual threading mode')
    require([phase['kept'] for phase in result['phases']] == [180,5,5], 'Complete decoded output')
    require(all(phase['corrupt']==0 for phase in result['phases']), 'No reported corrupt frames')
for key, actual in dgroups.items():
    _, verify, delay, rnd = key
    expected = order[rnd%3:]+order[:rnd%3]
    if not verify and delay==0 and rnd%2:
        expected = expected[::-1]
    require(actual==expected, f'Actual decoder order {key}')
for fixture in ['h264-slices-1.mp4','h264-slices-4.mp4']:
    counts = Counter()
    for key, actual in dgroups.items():
        if key[0]==fixture and key[1] is False and key[2]==0:
            counts.update((mode,pos) for pos,mode in enumerate(actual))
    require(len(counts)==9 and set(counts.values())=={2}, 'Unpaced settings occupy every position twice')
v = json.loads((e/'decode-modes-final/verification.json').read_text())
require(len(v)==6 and all(r['all_phase_receipts_equal'] for r in v), 'Separate pixel/timestamp verification matches')
require(len(audio['rows'])==36 and all(r['exit']==0 for r in audio['rows']), '36 AAC verification runs')
require(len(audio['comparisons'])==24, '24 AAC baseline comparisons')
require(all(r['counts_equal'] and r['first_sample_equal'] for r in audio['comparisons']), 'AAC window counts/timestamps match')
require(sum(not r['early_equal'] for r in audio['comparisons'])==10 and sum(not r['late_equal'] for r in audio['comparisons'])==6, 'AAC hash differences retained')
# Verify published source measurements against the delivered probes.
im = json.loads((e/'io-final/manifest.json').read_text())
dm = json.loads((e/'decode-modes-final/manifest.json').read_text())
require(sha(w/'new-experiments/io_probe.c')==im['source_sha256'], 'I/O source hash')
require(sha(w/'new-experiments/decode_modes.c')==dm['source'], 'Decode source hash')
require(sha(w/'new-experiments/DecoderFactory.h')==dm['factory'], 'Factory source hash')
# Fixtures/binaries are optional in a source-only delivery; check when present.
for name, expected in {**im['fixture_sha256'], **dm['fixtures']}.items():
    path = w/'fixtures'/name
    if path.exists():
        require(sha(path)==expected, f'Fixture {name}')
for path, expected in [(w/'new-experiments/io-probe',im['probe_sha256']), (w/'new-experiments/decode-modes',dm['probe'])]:
    if path.exists():
        require(sha(path)==expected, f'Measured binary {path.name}')
result = dict(status='passed',checks=checks,io_timing_processes=218,decoder_timing_processes=54,
              total_new_timing_processes=272,io_verification_processes=210,decoder_verification_processes=6,
              aac_verification_processes=36,total_primary_verification_processes=252,
              io_packet_differences=18,aac_early_differences=10,aac_late_differences=6,
              native_macOS_qualification=False,subagents_used=False,
              meaning='Receipt integrity and selected-output comparisons; known semantic differences explicitly retained, NOT accepted production stream-filtering correctness.')
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(result,indent=2))
print(json.dumps(result))
