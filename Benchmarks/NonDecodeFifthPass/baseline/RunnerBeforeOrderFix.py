#!/usr/bin/env python3
"""Reproduce paired state-publication experiments. No media, GUI, or network work."""
import argparse, collections, hashlib, json, pathlib, platform, statistics, sys, time
from build import build, run, ROOT, HERE
CASES=[('position',128,20_000),('scalar_same',128,20_000),('scalar_changed',128,20_000),
       ('chapters_same',128,10_000),('chapter_index',128,10_000),('chapters_changed',128,5_000),
       ('chapters_changed',10_000,400),('tracks_same',8,10_000),('tracks_changed',8,5_000),('tracks_same',128,10_000),('tracks_changed',128,5_000),
       ('devices_changed',128,5_000),('adjustment_same',128,10_000),('adjustment_changed',128,10_000),
       ('diagnostic',128,5_000),('diagnostic_disconnected',128,5_000)]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--output',type=pathlib.Path,required=True)
 p.add_argument('--repeats',type=int,default=7)
 p.add_argument('--variants',nargs='+',choices=['v4','batch','guarded','batched','v5'],default=['v4','batch','v5'])
 p.add_argument('--workloads',nargs='+',choices=sorted({v[0] for v in CASES}))
 p.add_argument('--tests-only',action='store_true')
 p.add_argument('--configuration',choices=['debug','release'],default='release')
 p.add_argument('--allocations',action='store_true')
 args=p.parse_args()
 if not 1<=args.repeats<=50:p.error('repeats must be 1...50')
 out=args.output.resolve()
 if out.exists() and any(out.iterdir()):p.error('output must be new or empty; evidence is never overwritten')
 out.mkdir(parents=True,exist_ok=True)
 if args.tests_only:
  exe=build(out/'v5','v5',args.configuration,differential=True)
  for mode in ['tests','differential','diagnose']:
   result=run([exe,mode],out)
   (out/(mode+'.json')).write_text(result)
   obj=json.loads(result);obj.pop('receipts',None)
   print(mode,obj,flush=True)
  return
 if args.configuration!='release':p.error('timing requires release; debug is for tests')
 variants=list(dict.fromkeys(args.variants));exes={}
 for variant in variants:
  print('Build',variant,flush=True)
  exes[variant]=build(out/variant,variant,'release',args.allocations)
  result=run([exes[variant],'diagnose'],out)
  (out/(variant+'-diagnose.json')).write_text(result)
 env={'platform':platform.platform(),'python':sys.version,'repeats':args.repeats,'variants':variants,
      'allocation_meter':args.allocations,'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
      'cpu_info':pathlib.Path('/proc/cpuinfo').read_text() if pathlib.Path('/proc/cpuinfo').exists() else '',
      'source_hashes':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [HERE/'build.py',HERE/'run.py',HERE/'StateHarness.swift',ROOT/'Sources/IlliquidCore/Player/PlaybackState.swift']}}
 (out/'environment.json').write_text(json.dumps(env,indent=2)+'\n')
 cases=[case for case in CASES if not args.workloads or case[0] in args.workloads]
 rows=[];expected={}
 for case in cases:
  name,size,iterations=case
  for repeat in range(args.repeats):
   order=variants[repeat%len(variants):]+variants[:repeat%len(variants)]
   if repeat%2:order=list(reversed(order))
   for variant in order:
    raw=run([exes[variant],'bench',name,size,iterations],out,timeout=120)
    row=json.loads(raw);row.update(variant=variant,repeat=repeat)
    key=(name,size)
    if key in expected and row['final']!=expected[key]:raise RuntimeError(f'Final state differs: {case}, {variant}')
    expected[key]=row['final']
    if row['instrumentation_enabled']:raise RuntimeError('instrumentation must be disabled for timing')
    rows.append(row)
    with (out/'measurements.jsonl').open('a') as f:f.write(json.dumps(row,sort_keys=True)+'\n')
  med={v:round(statistics.median(x['elapsed_ns']/x['iterations'] for x in rows if x['workload']==name and x['size']==size and x['variant']==v),2) for v in variants}
  print(name,size,'ns/event',med,flush=True)
 groups=collections.defaultdict(list)
 for row in rows:groups[(row['workload'],row['size'],row['variant'])].append(row)
 summary=[]
 for (name,size,variant),values in sorted(groups.items()):
  obj={'workload':name,'size':size,'variant':variant,'samples':len(values),'iterations':values[0]['iterations']}
  metrics=['elapsed_ns','cpu_ns','callbacks']+(['allocation_requests','allocation_requested_bytes'] if args.allocations else [])
  for metric in metrics:
   vs=[x[metric] for x in values];obj[metric]={'median':statistics.median(vs),'min':min(vs),'max':max(vs)}
  obj['ns_per_event']=obj['elapsed_ns']['median']/obj['iterations']
  summary.append(obj)
 (out/'summary.json').write_text(json.dumps({'observations':len(rows),'groups':summary},indent=2)+'\n')
 print('Completed',len(rows),'observations',flush=True)
if __name__=='__main__':main()
