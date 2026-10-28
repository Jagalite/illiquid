#!/usr/bin/env python3
"""Compare V2 to V3 actual persistence paths. No installed app/user data touched."""
import argparse, hashlib, json, platform, statistics, subprocess, time
from pathlib import Path
H=Path(__file__).resolve().parent; R=H.parent.parent

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--output',type=Path,required=True);p.add_argument('--counts',default='1000,10000,100000')
 p.add_argument('--repeats',type=int,default=5);p.add_argument('--allocations',action='store_true');p.add_argument('--build-only',action='store_true')
 p.add_argument('--modes',default='repeat-burst,repeat-flushed,repeat-blocked,changed-blocked,changed-flushed')
 p.add_argument('--resume',action='store_true');p.add_argument('--max-observations',type=int)
 a=p.parse_args();counts=[int(x) for x in a.counts.split(',')];modes=a.modes.split(',')
 if min(counts)<1 or a.repeats<1:p.error('positive counts/repeats required')
 if a.allocations and (platform.system()!='Linux' or any(x.endswith('flushed') for x in modes)):p.error('allocation runs require Linux and non-flushed modes')
 a.output.mkdir(parents=True,exist_ok=True)
 if any(a.output.iterdir()) and not a.resume:p.error('output must be empty')
 build=a.output/'build';build.mkdir(exist_ok=a.resume)
 def run(cmd):
  cmd=list(map(str,cmd)); t=time.time();c=subprocess.run(cmd,text=True,capture_output=True,timeout=120)
  with (a.output/'commands.jsonl').open('a') as f:f.write(json.dumps(dict(command=cmd,returncode=c.returncode,stdout=c.stdout,stderr=c.stderr,wall_seconds=time.time()-t))+'\n')
  if c.returncode:raise RuntimeError(c.stderr or c.stdout)
  return c.stdout
 extra=[]
 if a.allocations:
  if not a.resume:run(['clang','-O2','-c',R/'Benchmarks/NonDecodePerformance/allocmeter.c','-o',build/'meter.o'])
  extra=['-D','ALLOCATION_METER',build/'meter.o']
 support=[x for x in sorted((R/'Benchmarks/NonDecodeFollowup/fixtures').glob('*.swift')) if x.name not in ['PlaybackPersistenceStore.swift','CoalescingPersistenceWriter.swift','PreviewCacheV1.swift','NativeThumbnailDiskCache.swift']]
 shared=[*support,R/'Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift',R/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',H/'HistoryHarness.swift']
 candidate_support=[R/'Sources/IlliquidCore/Persistence/PlaybackPreferences.swift' if x.name == 'PlaybackPreferences.swift' else x for x in shared]
 sources={'v2':H/'baseline/PlaybackPersistenceStoreV2.swift','v3':R/'Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift'}
 flags=['-O','-swift-version','6','-warnings-as-errors']
 manifest={'compiler':run(['swiftc','--version']),'platform':platform.platform(),'flags':flags,'allocation_instrumented':a.allocations,'source_sha256':{str(x.relative_to(R)):hashlib.sha256(x.read_bytes()).hexdigest() for x in [*shared,*candidate_support,*sources.values()]}}
 if a.resume:
  previous=json.loads((a.output/'manifest.json').read_text())
  if previous['source_sha256']!=manifest['source_sha256']:p.error('source changes prevent resuming')
 else:
  for v,s in sources.items():run(['swiftc',*flags,*extra,*(candidate_support if v=='v3' else shared),s,'-o',build/v])
 manifest['binaries_sha256']={v:hashlib.sha256((build/v).read_bytes()).hexdigest() for v in sources}
 if a.resume and previous['binaries_sha256']!=manifest['binaries_sha256']:p.error('binary hashes differ')
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
 if a.build_only:return
 results=a.output/'measurements.jsonl'
 rows=[json.loads(x) for x in results.read_text().splitlines()] if a.resume and results.exists() else []
 completed={(x['count'],x['mode'],x['repeat'],x['variant']) for x in rows}; new_count=0
 for n in counts:
  for mode in modes:
   updates=5 if mode.endswith('flushed') else 100
   for repeat in range(a.repeats):
    for v in (['v2','v3'] if repeat%2==0 else ['v3','v2']):
     if (n,mode,repeat,v) in completed:continue
     if a.max_observations is not None and new_count>=a.max_observations:
      print(f'Checkpointed {len(rows)} observations; resume with unchanged sources.',flush=True);return
     new_count+=1
     row=json.loads(run([build/v,n,updates,mode]));row.update(variant=v,repeat=repeat)
     rows.append(row)
     with results.open('a') as f:f.write(json.dumps(row)+'\n')
     print(f'{n} {mode} round {repeat+1}/{a.repeats} {v}',flush=True)
 summary=[]
 for n in counts:
  for mode in modes:
   for v in sources:
    group=[r for r in rows if r['count']==n and r['mode']==mode and r['variant']==v]
    if len(group)!=a.repeats:raise RuntimeError('Incomplete group; no summary produced')
    d=dict(count=n,mode=mode,variant=v,samples=len(group))
    for k in ['mutation_total_ns','operation_ns','flush_ns','writes','set_payload_bytes','allocation_requests','allocation_request_bytes']:
     if k in group[0]:
      values=[r[k] for r in group];d[k]=dict(median=statistics.median(values),min=min(values),max=max(values))
    summary.append(d)
 (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
if __name__=='__main__': main()
