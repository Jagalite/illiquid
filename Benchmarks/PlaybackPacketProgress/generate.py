#!/usr/bin/env python3
"""Generate only disposable fixtures into a new directory; preserve timestamp gaps."""
import argparse,hashlib,json,subprocess
from pathlib import Path

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();root=a.output.resolve();root.mkdir(parents=True,exist_ok=False)
 (root/'sparse.srt').write_text('1\n00:00:45,000 --> 00:00:47,000\nFirst future subtitle\n\n2\n00:00:52,000 --> 00:00:54,000\nSecond future subtitle\n')
 (root/'normal.srt').write_text('1\n00:00:00,500 --> 00:00:04,500\nFirst cue\n\n2\n00:00:05,000 --> 00:00:06,000\nSecond cue\n\n3\n00:00:07,500 --> 00:00:09,500\nThird cue\n\n4\n00:00:10,000 --> 00:00:11,800\nFinal cue\n')
 receipts=[]
 def run(name,args):
  cmd=['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-filter_threads','1']+args+[str(root/name)]
  r=subprocess.run(cmd,text=True,capture_output=True,timeout=180);row={'file':name,'command':cmd,'exit':r.returncode,'stderr':r.stderr};receipts.append(row)
  if not r.returncode:
   path=root/name;row.update(bytes=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
  (root/'manifest.json').write_text(json.dumps(receipts,indent=2)+'\n')
  if r.returncode:raise RuntimeError(r.stderr)
 def inputs(size,length,subs):return ['-f','lavfi','-i',f'testsrc2=size={size}:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-i',str(root/subs),'-t',str(length),'-map','0:v','-map','1:a','-map','2:s']
 enc=['-c:v','libx264','-preset','veryfast','-crf','23','-g','90','-keyint_min','90','-sc_threshold','0','-bf','3','-threads','2','-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-ac','2']
 run('normal.mp4',inputs('1280x720',12,'normal.srt')+enc+['-c:s','mov_text','-movflags','+faststart'])
 run('normal.mkv',['-i',str(root/'normal.mp4'),'-map','0','-c','copy','-c:s','ass'])
 run('normal.ts',['-i',str(root/'normal.mp4'),'-map','0:v','-map','0:a','-c','copy'])
 run('sparse.mkv',inputs('320x180',60,'sparse.srt')+enc+['-c:s','ass'])
 run('sparse.mp4',['-i',str(root/'sparse.mkv'),'-map','0','-c','copy','-c:s','mov_text','-movflags','+faststart'])
 run('audio-gap.mkv',inputs('320x180',60,'sparse.srt')+['-af',"aselect=not(between(t\\,20\\,50))"]+enc+['-c:s','ass'])
 run('video-gap.mkv',inputs('320x180',60,'sparse.srt')+['-vf',"select=not(between(t\\,20\\,50))",'-fps_mode:v','vfr']+enc+['-c:s','ass'])
 print(json.dumps({'fixtures':len(receipts),'directory':str(root)}))
if __name__=='__main__':main()
