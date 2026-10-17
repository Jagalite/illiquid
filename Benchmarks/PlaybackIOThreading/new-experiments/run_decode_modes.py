#!/usr/bin/env python3
"""Measure decoder threading structure and input-pacing sensitivity. Not a renderer benchmark."""
from pathlib import Path
import argparse,subprocess,json,hashlib,time,platform,statistics
from collections import defaultdict
p=argparse.ArgumentParser();p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();w=a.work.resolve();o=a.output.resolve();o.mkdir(parents=True,exist_ok=False)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=['h264-slices-1.mp4','h264-slices-4.mp4'];variants=[('1','default'),('4','frame'),('4','slice')]
(o/'manifest.json').write_text(json.dumps({'probe':sha(w/'new-experiments/decode-modes'),'source':sha(w/'new-experiments/decode_modes.c'),'factory':sha(w/'new-experiments/DecoderFactory.h'),'fixtures':{x:sha(w/'fixtures'/x) for x in files},'platform':platform.platform(),'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'scope':'Selected libavformat/libavcodec software pipeline; no audio, conversion, output queue or renderer. Optional video packet availability at 16,667 us intervals is synthetic, measured relative to each phase start; decode may fall behind and catch up.'},indent=2))
seq=0
for verify,delay,repeats in [(True,0,1),(False,0,6),(False,16667,3)]:
 for rnd in range(repeats):
  order=variants[rnd%3:]+variants[:rnd%3]
  if repeats==6 and rnd%2:order=order[::-1]
  for fixture in files:
   for count,strategy in order:
    seq+=1;cmd=[str(w/'new-experiments/decode-modes'),str(w/'fixtures'/fixture),count,'verify' if verify else 'timing',strategy,str(delay)]
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=40)
    row={'sequence':seq,'fixture':fixture,'round':rnd,'verify':verify,'delay_us':delay,'threads':count,'strategy':strategy,'command':cmd,'exit':r.returncode,'stderr':r.stderr}
    if not r.returncode:row['result']=json.loads(r.stdout)
    else:row['stdout']=r.stdout
    with(o/'rows.jsonl').open('a') as h:h.write(json.dumps(row)+'\n')
    if r.returncode:raise RuntimeError(r.stderr)
  print('Completed cohort',verify,delay,'round',rnd,flush=True)
rows=[json.loads(x) for x in(o/'rows.jsonl').read_text().splitlines()];groups=defaultdict(list)
for r in rows:
 if not r['verify']:groups[(r['fixture'],r['delay_us'],r['threads'],r['strategy'])].append(r['result'])
summary={}
for k,rs in groups.items():
 result={'samples':len(rs),'active_thread_types':sorted(set(r['active_thread_type'] for r in rs))}
 for name in ['peak_rss_after_kib','decoder_open_ns']:
  vs=[r[name] for r in rs];result[name]={'median':statistics.median(vs),'min':min(vs),'max':max(vs)}
 result['phases']={}
 for j in range(3):
  result['phases'][rs[0]['phases'][j]['name']]={}
  for name in ['wall_ns','cpu_ns','first_ns','target_ns','packets_to_first','kept','decoded','corrupt','first_pts_us','target_pts_us']:
   vs=[r['phases'][j][name] for r in rs];result['phases'][rs[0]['phases'][j]['name']][name]={'median':statistics.median(vs),'min':min(vs),'max':max(vs)}
 summary['|'.join(map(str,k))]=result
(o/'summary.json').write_text(json.dumps(summary,indent=2))
comparisons=[]
for f in files:
 rs=[r for r in rows if r['fixture']==f and r['verify']];b=next(r['result'] for r in rs if r['threads']=='1')
 for r in rs:
  v=r['result'];same=all(tuple(x[z] for z in ['md5','kept','target_pts_us','last_pts_us'])==tuple(y[z] for z in ['md5','kept','target_pts_us','last_pts_us']) for x,y in zip(b['phases'],v['phases']))
  comparisons.append({'fixture':f,'threads':r['threads'],'strategy':r['strategy'],'all_phase_receipts_equal':same,'full_frames':v['phases'][0]['kept']})
(o/'verification.json').write_text(json.dumps(comparisons,indent=2));assert all(x['all_phase_receipts_equal'] and x['full_frames']==180 for x in comparisons)
print('Done',len(rows),'rows',flush=True)
