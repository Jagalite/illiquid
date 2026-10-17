#!/usr/bin/env python3
"""Serial, paired I/O experiments. Synthetic fixtures only; output directory must be new."""
import argparse,hashlib,json,platform,subprocess,time,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();w=a.work.resolve();o=a.output.resolve();o.mkdir(parents=True,exist_ok=False)
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
manifest={'platform':platform.platform(),'probe_sha256':sha(w/'new-experiments/io-probe'),'source_sha256':sha(w/'new-experiments/io_probe.c'),'fixture_sha256':{f.name:sha(f) for f in (w/'fixtures').glob('multiplex.*')},'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'protocol':'serial fresh processes; AB/BA alternation; no outlier removal; native file AVIO and counted custom-AVIO cohorts separate'}
(o/'manifest.json').write_text(json.dumps(manifest,indent=2))
seq=0

def run(cohort,ext,role,mode,buf,phase='scan',target=0,verify=False,delay=0,round=0):
 global seq
 cmd=[str(w/'new-experiments/io-probe'),str(w/f'fixtures/multiplex.{ext}'),role,mode,str(buf),phase,str(target),'verify' if verify else 'timing',str(delay)]
 seq+=1;r=subprocess.run(cmd,capture_output=True,text=True,timeout=45)
 entry={'sequence':seq,'cohort':cohort,'file':ext,'role':role,'mode':mode,'buffer':buf,'phase':phase,'target':target,'verify':verify,'delay':delay,'round':round,'command':cmd,'returncode':r.returncode,'stderr':r.stderr}
 if r.returncode==0:entry['result']=json.loads(r.stdout)
 else:entry['stdout']=r.stdout
 with (o/'rows.jsonl').open('a') as h:h.write(json.dumps(entry)+'\n')
 if r.returncode:raise RuntimeError(f'Probe failed: {cmd}: {r.stderr}')
 return entry

# Verify semantics independently before primary timing; preserve differences, never discard them.
roles={x:['video','audio0','audio1']+([] if x=='ts' else ['subtitle']) for x in ['mp4','mkv','ts']}
verification=[]
for ext,rs in roles.items():
 for role in rs:
  for phase,target in [('scan',0),('frontier',30),('global',5),('global',47)]+([('stream',5),('stream',47)] if role=='subtitle' else []):
   for mode in ['all','selected','read-only']:
    verification.append(run('semantic',ext,role,mode,0,phase,target,True))
  for buf in [4096,32768,262144]:
   for mode in ['all','selected']:
    verification.append(run('buffer-parity',ext,role,mode,buf,verify=True))
print('Semantic cohorts complete',flush=True)

for round in range(5):
 for ext,rs in roles.items():
  for role in rs:
   for mode in (['all','selected'] if round%2==0 else ['selected','all']):
    run('native-timing',ext,role,mode,0,round=round)
 print('Native timing round',round,'complete',flush=True)

for round in range(3):
 for ext in ['mp4','mkv','ts']:
  for role in ['audio0']+([] if ext=='ts' else ['subtitle']):
   sizes=[4096,32768,262144];sizes=sizes[round:]+sizes[:round]
   for buf in sizes:
    for mode in (['all','selected'] if round%2==0 else ['selected','all']):
     run('buffer-timing',ext,role,mode,buf,round=round)
 print('Buffer round',round,'complete',flush=True)

# Synthetic callback service latency, not a storage-hardware benchmark.
for round in range(3):
 for ext,role in [('mp4','subtitle'),('mkv','subtitle'),('mp4','audio0')]:
  for mode in (['all','selected'] if round%2==0 else ['selected','all']):
   run('injected-latency',ext,role,mode,32768,delay=500,round=round)

rows=[json.loads(l) for l in (o/'rows.jsonl').read_text().splitlines()]
from collections import defaultdict
groups=defaultdict(list)
for row in rows:
 if row['verify']:continue
 key='|'.join(str(row[k]) for k in ['cohort','file','role','mode','buffer','phase','target','delay']);groups[key].append(row['result'])
summary={}
for k,rs in groups.items():
 m={'samples':len(rs)}
 for name in ['open_ns','probe_ns','read_ns','read_cpu_ns','through_read_ns','returned_packets','selected_packets','selected_payload_bytes']:
  vs=[r[name] for r in rs];m[name]={'median':statistics.median(vs),'min':min(vs),'max':max(vs)}
 for name in ['avio_bytes','callback_reads','callback_bytes','seek_moves']:
  vs=[r['read_io'][name] for r in rs];m['read_'+name]={'median':statistics.median(vs),'min':min(vs),'max':max(vs)}
 summary[k]=m
(o/'summary.json').write_text(json.dumps(summary,indent=2))
# Pair consistency. Exact-target correctness is not implied by pair equality.
by={(r['file'],r['role'],r['phase'],r['target'],r['mode']):r['result'] for r in rows if r['cohort']=='semantic'}
checks=[]
for (ext,role,phase,target,mode),v in by.items():
 if mode=='all':continue
 b=by[(ext,role,phase,target,'all')]
 checks.append({'file':ext,'role':role,'phase':phase,'target':target,'mode':mode,'metadata_equal':v['metadata_md5']==b['metadata_md5'],'selected_packets_equal':v['selected_packets']==b['selected_packets'],'packet_receipt_equal':v['packet_md5']==b['packet_md5'],'baseline_first_us':b['first_us'],'candidate_first_us':v['first_us'],'baseline_frontier_us':b['frontier_cross_us'],'candidate_frontier_us':v['frontier_cross_us'],'baseline_bytes':b['read_io']['avio_bytes'],'candidate_bytes':v['read_io']['avio_bytes']})
(o/'semantic-comparison.json').write_text(json.dumps(checks,indent=2))
print('Finished',len(rows),'rows;',sum(not r['verify'] for r in rows),'timing;',sum(r['verify'] for r in rows),'verification',flush=True)
