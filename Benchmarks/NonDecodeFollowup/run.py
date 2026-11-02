#!/usr/bin/env python3
"""Compile exact Swift persistence paths, retain receipts, alternate A/B order.
No app launch; no network; no installed user data. New output directory required.
"""
import argparse, hashlib, json, platform, statistics, subprocess, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FLAGS = ["-O", "-swift-version", "6", "-warnings-as-errors"]
EXPECTED = {
 "CoalescingPersistenceWriter.swift":"8dfd3bb5ea050057068fcff576f446bfdfd992d1",
 "PlaybackPersistenceStore.swift":"a05aa65776b753acf9ecac8640f5eb98c1a6e0cd",
 "PlaybackPreferences.swift":"334c606fa80c54cc55ee2d56b1e74eca2faab49b",
 "MediaPlaybackSettings.swift":"6d510af3716ccc8482179a1fbd0a7e07d0a220f0",
 "MediaContentVersion.swift":"8db30c6aa0b412b8b8f9dfcbd045d9733ee52a11",
 "PlaybackRestoreTarget.swift":"dc68c1115d8e0d63e8495e3e2eef2fe4325e0537",
 "NormalizedFileURL.swift":"ee5bb383869da68ec1f2cd842ae766603f7ef419",
 "MediaTrack.swift":"d6ecdb2d96f197a0d19fa8b784a49f2bc8519905",
 "TrackSelectionPreferences.swift":"a915f20eea5f4b5331f5440ad2e181164030a5a0",
 "SubtitleFallbackEncoding.swift":"6129fc1ad207e8bd096451b5b416db079712b9c3",
}

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--output',type=Path,required=True)
 p.add_argument('--phase',choices=['writer','store'],default='store')
 p.add_argument('--repeats',type=int,default=7)
 p.add_argument('--counts',default='1000,10000,100000')
 p.add_argument('--allocations',action='store_true')
 p.add_argument('--updates',type=int,default=100)
 p.add_argument('--build-only',action='store_true')
 a=p.parse_args()
 if a.repeats<1 or a.updates<1: p.error('positive repeats/updates required')
 if a.allocations and (a.phase!='writer' or platform.system()!='Linux'): p.error('allocations require Linux/glibc and --phase writer')
 counts=[int(x) for x in a.counts.split(',')]
 if any(x<1 for x in counts): p.error('counts must be positive')
 a.output.mkdir(parents=True,exist_ok=True)
 if any(a.output.iterdir()): p.error('output must be empty')
 build=a.output/'build';build.mkdir()
 def run(cmd,timeout=120):
  started=time.time();c=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=timeout)
  with (a.output/'commands.jsonl').open('a') as f: f.write(json.dumps({'command':list(map(str,cmd)),'returncode':c.returncode,'stdout':c.stdout,'stderr':c.stderr,'wall_seconds':time.time()-started})+'\n')
  if c.returncode: raise RuntimeError(c.stderr)
  return c.stdout
 for name,sha in EXPECTED.items():
  data=(HERE/'fixtures'/name).read_bytes()
  actual=hashlib.sha1(f'blob {len(data)}\0'.encode()+data).hexdigest()
  if actual!=sha: raise RuntimeError(f'Baseline source mismatch: {name}')
 preferences=ROOT/'Sources/IlliquidCore/Persistence/PlaybackPreferences.swift'
 manifest={'platform':platform.platform(),'compiler':run(['swiftc','--version']),'flags':FLAGS,'phase':a.phase,'allocations':a.allocations,'baseline_git_blobs':{name:blob for name,blob in EXPECTED.items() if name!='PlaybackPreferences.swift'},'verified_uncompiled_fixture_git_blobs':{'PlaybackPreferences.swift':EXPECTED['PlaybackPreferences.swift']},'source_sha256':{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in [*HERE.glob('*.swift'),*HERE.glob('fixtures/*.swift'),ROOT/'Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift',ROOT/'Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift',ROOT/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',preferences]},'compiled_source_paths':{}}
 if a.phase=='store':manifest['shared_current_preferences']={'path':str(preferences.relative_to(ROOT)),'origin':'current_worktree','sha256':hashlib.sha256(preferences.read_bytes()).hexdigest()}
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
 alloc=[]
 if a.allocations:
  run(['clang','-O2','-c',ROOT/'Benchmarks/NonDecodePerformance/allocmeter.c','-o',build/'allocmeter.o'])
  alloc=['-D','ALLOCATION_METER',build/'allocmeter.o']
 for variant in ['baseline','candidate']:
  source=HERE/'fixtures' if variant=='baseline' else ROOT/'Sources/IlliquidCore/Persistence'
  inputs=[source/'CoalescingPersistenceWriter.swift']
  if a.phase=='store':
   # Use the same current preference validators in both store variants. The
   # frozen fixture remains verified above, but is not a compiled input.
   inputs += [source/'PlaybackPersistenceStore.swift',preferences,ROOT/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift']
   inputs += [x for x in sorted((HERE/'fixtures').glob('*.swift')) if x.name not in ['CoalescingPersistenceWriter.swift','PlaybackPersistenceStore.swift','PlaybackPreferences.swift','PreviewCacheV1.swift','NativeThumbnailDiskCache.swift']]
  inputs += [HERE/('WriterHarness.swift' if a.phase=='writer' else 'StoreHarness.swift')]
  defines=['-D','CANDIDATE'] if variant=='candidate' else []
  manifest['compiled_source_paths'][variant]=[str(path.relative_to(ROOT)) for path in inputs]
  (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
  run(['swiftc',*FLAGS,*defines,*alloc,*inputs,'-o',build/variant])
 manifest['binary_sha256']={v:hashlib.sha256((build/v).read_bytes()).hexdigest() for v in ['baseline','candidate']}
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
 if a.build_only: return
 rows=[]
 modes=['pending','blocked'] if a.phase=='writer' else ['burst','blocked','flushed']
 for count in counts:
  for mode in modes:
   for repeat in range(a.repeats):
    for variant in (['baseline','candidate'] if repeat%2==0 else ['candidate','baseline']):
     n=min(a.updates,5) if mode=='flushed' else a.updates
     d=json.loads(run([build/variant,count,n,mode]))
     d.update(variant=variant,repeat=repeat,phase=a.phase,allocation_instrumented=a.allocations)
     rows.append(d)
     with (a.output/'measurements.jsonl').open('a') as f: f.write(json.dumps(d)+'\n')
    print(f'{a.phase}: {count} {mode} round {repeat+1}/{a.repeats}',flush=True)
 grouped={}
 for d in rows: grouped.setdefault((d['count'],d['mode'],d['variant']),[]).append(d)
 summary=[]
 for (count,mode,v),group in grouped.items():
  record={'count':count,'mode':mode,'variant':v,'samples':len(group)}
  keys=['mutation_total_ns','flush_ns','operation_ns','writes','load_ns','set_payload_bytes','snapshot_captures','encoded_bytes','encode_ns','allocation_requests','allocation_request_bytes']
  for k in keys:
   if all(k in d for d in group):
    vals=[d[k] for d in group];record[k]={'median':statistics.median(vals),'min':min(vals),'max':max(vals)}
  record['median_individual_mutation_ns']=statistics.median([statistics.median(d['mutation_ns']) for d in group])
  record['max_individual_mutation_ns']=max(max(d['mutation_ns']) for d in group)
  summary.append(record)
 (a.output/'summary.json').write_text(json.dumps(summary,indent=2))

if __name__=='__main__': main()
