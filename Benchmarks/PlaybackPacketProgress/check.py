#!/usr/bin/env python3
"""Validate complete receipts, not a speedup threshold. Use --self-test for tampering checks."""
import argparse, copy, hashlib, json, pathlib, statistics
from run import CASES, EQUAL

def require(ok, message):
    if not ok: raise ValueError(message)

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def validate(directory, rows=None, commands=None):
    d=directory
    rows=rows if rows is not None else [json.loads(l) for l in (d/'observations.jsonl').read_text().splitlines()]
    commands=commands if commands is not None else json.loads((d/'commands.json').read_text())
    manifest=json.loads((d/'manifest.json').read_text()); n=manifest['repeats']
    require(n>=3, 'insufficient repetitions')
    expected=[]
    for route in ['direct','executor']:
        for case in CASES:
            for r in range(n):
                for v in (['baseline','candidate'] if r%2==0 else ['candidate','baseline']):
                    expected.append(('timing',route,'|'.join(case),r,v))
    for route in ['direct','executor']:
        for case in [CASES[0],CASES[1],('sparse.mkv','subtitle','horizon'),('normal.mkv','all','full')]:
            for r in range(3):
                for v in (['baseline','candidate'] if r%2==0 else ['candidate','baseline']):
                    expected.append(('allocations',route,'|'.join(case),r,v))
    require(len(rows)==len(expected),'row count')
    actual=[(x['experiment'],x['route'],x['case'],x['repeat'],x['variant']) for x in rows]
    require(actual==expected,'row identities/order')
    require([x['ordinal'] for x in rows]==list(range(len(rows))),'ordinal sequence')
    require(all(c['exit']==0 for c in commands),'failed process')
    require(all(a['end']<=b['start'] for a,b in zip(commands,commands[1:])),'overlapping processes')
    measured=[c for c in commands if pathlib.Path(c['command'][0]).name.endswith(('-timing','-allocations'))]
    require(len(measured)==len(rows),'command count')
    checks=0; references={}
    for route in ['direct','executor']:
        for i,case in enumerate(CASES):
            a=json.loads((d/'verify'/f'{route}-{i:02}-baseline.json').read_text())
            b=json.loads((d/'verify'/f'{route}-{i:02}-candidate.json').read_text())
            for f in EQUAL+['eventSequence','packets','repeatedEOF']:
                require(a.get(f)==b.get(f),f'parity: {route} {case} {f}'); checks+=1
            require(b['generationOK'],'generation mismatch')
            require(len(b['eventSequence'])==b['events'],'missing progress events')
            require(len(b['packets'])==b['kept'],'missing packet receipts')
            if case[2]=='resume':
                full=json.loads((d/'verify'/f'{route}-{i:02}-full-reference.json').read_text())
                require(full['packets']==b['packets'],'resume duplicated/lost selected packet'); checks+=1
            for v,x in [('baseline',a),('candidate',b)]: references[route,'|'.join(case),v]=x
    for x,c in zip(rows,measured):
        cmd=c['command']; expected_binary=x['variant']+'-'+x['experiment']
        require(pathlib.Path(cmd[0]).name==expected_binary,'actual executable order')
        require((pathlib.Path(cmd[1]).name,cmd[2],cmd[3])==tuple(x['case'].split('|')) and cmd[4]==x['route'] and cmd[5]=='73','actual command scope')
        ref=references[x['route'],x['case'],x['variant']]
        for f in EQUAL: require(x[f]==ref[f],'timing result differs from verified '+f); checks+=1
        require('packets' not in x and 'eventSequence' not in x,'hashing/receipts inside timed binary')
        if x['experiment']=='timing': require('allocationRequests' not in x,'meter inside timing')
        require(x['elapsedNS']>=0 and x['cpuSeconds']>=0,'invalid time')
    require(manifest['timing_count']==64*n and manifest['allocations_count']==48 and manifest['verification_processes']==72,'manifest counts')
    # Independent summaries are recomputed from raw observations, never accepted on trust.
    for s in json.loads((d/'summary.json').read_text()):
        group=[x for x in rows if all(x[k]==s[k] for k in ['experiment','route','case','variant'])]
        require(len(group)==s['samples'],'summary count')
        for key,value in s.items():
            if isinstance(value,dict) and 'median' in value:
                values=[x[key] for x in group]
                require(value==dict(median=statistics.median(values),min=min(values),max=max(values)),'summary '+key)
    return dict(timing=64*n,allocations=48,verification_processes=72,comparisons=checks,actual_AB_BA_order=True)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=pathlib.Path,required=True);p.add_argument('--build',type=pathlib.Path);p.add_argument('--self-test',action='store_true');a=p.parse_args()
    result=validate(a.evidence)
    m=json.loads((a.evidence/'manifest.json').read_text())
    require(sha(pathlib.Path(__file__).with_name('run.py'))==m['driver_sha256'],'measurement driver changed')
    if a.build:
        for name,value in m['binaries'].items(): require(sha(a.build/name)==value,'binary changed '+name)
        for path,value in m['sources'].items():
            # Regression-only coverage was extended after timing; it is not linked into timed binaries.
            if pathlib.Path(path).name!='Regression.swift': require(sha(a.build/pathlib.Path(path).name)==value,'timed source changed '+path)
        result['timed_build_hashes_checked']=True
    if a.self_test:
        rows=[json.loads(l) for l in (a.evidence/'observations.jsonl').read_text().splitlines()]; commands=json.loads((a.evidence/'commands.json').read_text())
        bad=[]
        x=copy.deepcopy(rows);x.pop();bad.append(('missing',x,None))
        x=copy.deepcopy(rows);x[1]=x[0];bad.append(('duplicate',x,None))
        x=copy.deepcopy(rows);x[0],x[1]=x[1],x[0];bad.append(('order',x,None))
        x=copy.deepcopy(rows);x[0]['kept']+=1;bad.append(('lost_packet',x,None))
        x=copy.deepcopy(rows);x[0]['packets']=[];bad.append(('hashing_in_timing',x,None))
        c=copy.deepcopy(commands);c[-1]['command'][0]='wrong-binary-allocations';bad.append(('command_order',None,c))
        rejected=[]
        for name,r,c in bad:
            try: validate(a.evidence,r,c)
            except (ValueError,KeyError): rejected.append(name)
            else: raise ValueError('accepted damaged evidence '+name)
        result['rejected_tampered_receipts']=rejected
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
