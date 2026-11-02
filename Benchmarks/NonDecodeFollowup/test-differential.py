#!/usr/bin/env python3
"""10,000 mixed store operations; compare 200 actual reload-state receipts."""
import argparse,hashlib,json,pathlib,subprocess
H=pathlib.Path(__file__).resolve().parent;R=H.parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
if any(a.output.iterdir()):p.error('output must be empty')
def run(cmd):
 c=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=120)
 with (a.output/'commands.jsonl').open('a') as f:f.write(json.dumps({'command':list(map(str,cmd)),'returncode':c.returncode,'stdout':c.stdout,'stderr':c.stderr})+'\n')
 if c.returncode:raise RuntimeError(c.stderr)
 return c.stdout
preferences=R/'Sources/IlliquidCore/Persistence/PlaybackPreferences.swift'
manifest={'shared_current_preferences':{'path':str(preferences.relative_to(R)),'origin':'current_worktree','sha256':hashlib.sha256(preferences.read_bytes()).hexdigest()},'source_sha256':{}}
results={}
for v in ['baseline','candidate']:
 source=H/'fixtures' if v=='baseline' else R/'Sources/IlliquidCore/Persistence'
 inputs=[source/'CoalescingPersistenceWriter.swift',source/'PlaybackPersistenceStore.swift',preferences,R/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',H/'StoreDifferential.swift']
 inputs += [x for x in sorted((H/'fixtures').glob('*.swift')) if x.name not in ['CoalescingPersistenceWriter.swift','PlaybackPersistenceStore.swift','PlaybackPreferences.swift','PreviewCacheV1.swift','NativeThumbnailDiskCache.swift']]
 manifest['source_sha256'][v]={str(path.relative_to(R)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 run(['swiftc','-O','-swift-version','6','-warnings-as-errors',*inputs,'-o',a.output/v])
 results[v]=run([a.output/v]);(a.output/(v+'.jsonl')).write_text(results[v])
assert len(results['baseline'].splitlines())==200
assert results['baseline']==results['candidate'],'effective persisted states differ'
(a.output/'result.json').write_text(json.dumps({'operations_per_variant':10000,'equal_reload_receipts':200,'effective_state_sha256':hashlib.sha256(results['candidate'].encode()).hexdigest(),'embedded_history_preferences':'replaced by authoritative reloaded preferences for comparison'},indent=2))
print('200 reload receipts match after 10,000 mixed operations per variant.')
