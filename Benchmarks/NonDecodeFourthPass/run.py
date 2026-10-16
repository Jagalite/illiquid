#!/usr/bin/env python3
"""Serial, paired fresh-process disk tests/timings. All images are explicit adapters.
Build normally once; --skip-build permits separate build/measurement invocations.
"""
import argparse,hashlib,json,pathlib,statistics
from build import build,run

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--build-root',type=pathlib.Path,required=True)
    p.add_argument('--skip-build',action='store_true');p.add_argument('--tests-only',action='store_true');p.add_argument('--resume',action='store_true')
    p.add_argument('--repeats',type=int,default=5);p.add_argument('--variants',default='v3,accounting,v4')
    p.add_argument('--cases',default='first-fg:0:1,first-fg:1000:1,first-fg:8190:1,first-bg:8190:1,miss:0:1,miss:1000:1,miss:8190:1,inventory:0:1,inventory:1000:1,inventory:8191:1,background:8190:1,warm:8190:100,series:8191:32,series:8191:512,churn:8192:32')
    p.add_argument('--allocations',action='store_true')
    a=p.parse_args();variants=a.variants.split(',')
    if a.repeats<1:p.error('repeats must be positive')
    a.output.mkdir(parents=True,exist_ok=True)
    if any(a.output.iterdir()) and not a.resume:p.error('output must be new/empty without --resume')
    if not a.skip_build:build(a.build_root,variants=variants,allocations=a.allocations)
    manifest=json.loads((a.build_root/'manifest.json').read_text())
    for v in variants:
        if hashlib.sha256((a.build_root/v/'disk').read_bytes()).hexdigest()!=manifest['variants'][v]['binary_sha256']:p.error('binary changed since manifest')
    mf=a.output/'build-manifest.json'
    if mf.exists() and json.loads(mf.read_text())!=manifest:p.error('manifest changed during resumption')
    mf.write_text(json.dumps(manifest,indent=2));log=a.output/'commands.jsonl'
    if a.tests_only:
        tests={v:[json.loads(x) for x in run([a.build_root/v/'disk','tests'],log).splitlines()] for v in variants}
        (a.output/'tests.json').write_text(json.dumps(tests,indent=2));print(json.dumps(tests,indent=2));return
    path=a.output/'measurements.jsonl';rows=[json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
    identities={(r['mode'],r['count'],r['iterations'],r['variant'],r['repeat']) for r in rows}
    for case in a.cases.split(','):
        mode,n,it=case.split(':');n,it=int(n),int(it)
        for rep in range(a.repeats):
            for v in (variants if rep%2==0 else variants[::-1]):
                identity=(mode,n,it,v,rep)
                if identity in identities:continue
                row=json.loads(run([a.build_root/v/'disk',mode,n,it],log))
                row.update(variant=v,repeat=rep);rows.append(row);identities.add(identity)
                with path.open('a') as f:f.write(json.dumps(row)+'\n')
            print(case,rep+1,a.repeats,flush=True)
    summary=[]
    for key in sorted({(r['mode'],r['count'],r['iterations'],r['variant']) for r in rows}):
        group=[r for r in rows if (r['mode'],r['count'],r['iterations'],r['variant'])==key]
        item=dict(zip(['mode','count','iterations','variant'],key));item['samples']=len(group)
        for metric in ['elapsed_ns','usage_after_ns','read_plus_usage_ns','allocation_requests','allocation_request_bytes']:
            if metric in group[0]:
                values=[r[metric] for r in group];item[metric]={'median':statistics.median(values),'min':min(values),'max':max(values)}
        summary.append(item)
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2))

if __name__=='__main__':main()
