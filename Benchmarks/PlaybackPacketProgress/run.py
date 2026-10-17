#!/usr/bin/env python3
"""Exclusive, counter-free AB/BA timing plus separate allocation and output checks."""
import argparse, collections, hashlib, json, os, pathlib, platform, statistics, subprocess, time
CASES=[('normal.mp4','subtitle','full'),('normal.mkv','subtitle','full'),('normal.ts','audio','full'),('normal.mp4','audio','full'),('normal.mkv','audio','full')]
CASES += [(f,'subtitle',m) for m in ['horizon','resume'] for f in ['sparse.mkv','sparse.mp4','audio-gap.mkv','video-gap.mkv']]
CASES += [(f,'all','full') for f in ['normal.mp4','normal.mkv','normal.ts']]
EQUAL=['events','kept','selectedBytes','readBytes','terminal','boundaries','generationOK']

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=pathlib.Path,required=True);p.add_argument('--fixtures',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--repeats',type=int,default=7);a=p.parse_args()
 assert a.repeats>=3
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);(out/'verify').mkdir()
 rows=[];verification=[];commands=[];checks=0
 def run(v,mode,case,route,repeat=0):
  binary=a.build/(v+'-'+mode);cmd=list(map(str,[binary,a.fixtures/case[0],case[1],case[2],route,'73']))
  started=time.time();r=subprocess.run(cmd,text=True,capture_output=True,timeout=45)
  commands.append(dict(command=cmd,start=started,end=time.time(),exit=r.returncode,stderr=r.stderr))
  (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
  if r.returncode:raise RuntimeError('probe failed '+str(cmd)+r.stderr[-2000:])
  data=json.loads(r.stdout);data.update(variant=v,experiment=mode,repeat=repeat,case='|'.join(case),ordinal=len(rows))
  if mode in ['timing','allocations']:
   rows.append(data)
   with (out/'observations.jsonl').open('a') as f:f.write(json.dumps(data,sort_keys=True)+'\n')
  return data
 refs={}
 for route in ['direct','executor']:
  for n,case in enumerate(CASES):
   pair=[]
   for v in ['baseline','candidate']:
    d=run(v,'verify',case,route)
    path=out/'verify'/f'{route}-{n:02}-{v}.json';path.write_text(json.dumps(d,separators=(',',':'))+'\n')
    refs[route,tuple(case),v]=d;pair.append(d)
   for field in EQUAL+['packets','eventSequence','repeatedEOF']:
    checks+=1
    assert pair[0].get(field)==pair[1].get(field),(route,case,field)
   assert pair[1]['generationOK']
   if case[2]=='resume':
    full=run('candidate','verify',(case[0],case[1],'full'),route)
    (out/'verify'/f'{route}-{n:02}-full-reference.json').write_text(json.dumps(full,separators=(',',':'))+'\n')
    assert full['packets']==pair[1]['packets'];checks+=1
   verification.append({'route':route,'case':case,'events':pair[0]['events'],'kept':pair[0]['kept'],'boundaries':pair[0]['boundaries'],'identical':True})
 # Timings alternate actual process order, never merely label AB/BA afterward.
 for route in ['direct','executor']:
  for case in CASES:
   for repeat in range(a.repeats):
    order=['baseline','candidate'] if repeat%2==0 else ['candidate','baseline']
    for v in order:
     d=run(v,'timing',case,route,repeat);ref=refs[route,tuple(case),v]
     for field in EQUAL:assert d[field]==ref[field],(case,field)
     assert 'packets' not in d and 'allocationRequests' not in d
 for route in ['direct','executor']:
  for case in [CASES[0],CASES[1],('sparse.mkv','subtitle','horizon'),('normal.mkv','all','full')]:
   for repeat in range(3):
    for v in (['baseline','candidate'] if repeat%2==0 else ['candidate','baseline']):
     d=run(v,'allocations',case,route,repeat)
     for field in EQUAL:assert d[field]==refs[route,tuple(case),v][field]
 groups=collections.defaultdict(list)
 for d in rows:groups[d['experiment'],d['route'],d['case'],d['variant']].append(d)
 summary=[]
 for (mode,route,case,v),ds in groups.items():
  entry=dict(experiment=mode,route=route,case=case,variant=v,samples=len(ds))
  for field in ['elapsedNS','cpuSeconds','readBytes','events','kept','progress','allocationRequests','allocationBytes']:
   vals=[x[field] for x in ds if field in x]
   if vals:entry[field]={'median':statistics.median(vals),'min':min(vals),'max':max(vals)}
  summary.append(entry)
 (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 (out/'verification.json').write_text(json.dumps({'checks':checks,'cases':verification},indent=2)+'\n')
 sources={str(f):sha(f) for f in a.build.glob('*.swift')}
 env=dict(platform=platform.platform(),cpu=open('/proc/cpuinfo').read().split('model name')[1].split('\n')[0] if pathlib.Path('/proc/cpuinfo').exists() else platform.processor(),affinity=len(os.sched_getaffinity(0)),cpu_max=pathlib.Path('/sys/fs/cgroup/cpu.max').read_text(),baseline='PR #5 at 3c7b84c425cf15cdbaccfd2b4829f3181130963f',repeats=a.repeats,timing_count=sum(d['experiment']=='timing' for d in rows),allocations_count=sum(d['experiment']=='allocations' for d in rows),verification_processes=len(commands)-len(rows),sources=sources,binaries={f.name:sha(f) for f in a.build.iterdir() if f.is_file() and f.name.endswith(('-timing','-verify','-allocations'))},fixtures={f.name:sha(f) for f in a.fixtures.iterdir() if f.suffix in ['.mp4','.mkv','.ts']},driver_sha256=sha(pathlib.Path(__file__)))
 (out/'manifest.json').write_text(json.dumps(env,indent=2)+'\n')
 print(json.dumps({k:env[k] for k in ['timing_count','allocations_count','verification_processes']}))
if __name__=='__main__':main()
