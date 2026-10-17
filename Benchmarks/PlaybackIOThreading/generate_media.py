from pathlib import Path
import subprocess, json, hashlib, argparse
p=argparse.ArgumentParser(); p.add_argument('--work',type=Path,required=True); a=p.parse_args()
w=a.work.resolve(); w.mkdir(parents=True,exist_ok=True)
f=w/'fixtures'; f.mkdir(exist_ok=False)
(w/'evidence').mkdir(exist_ok=True)
commands=[]
def run(args):
 cmd=['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-y',*args]
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
 commands.append({'command':cmd,'returncode':r.returncode,'stderr':r.stderr})
 (w/'evidence/fixture-generation.json').write_text(json.dumps(commands,indent=2))
 if r.returncode: raise RuntimeError(r.stderr)
# A short deterministic encoded segment is repeated by stream-copy for I/O tests.
run(['-f','lavfi','-i','testsrc2=size=1280x720:rate=30','-t','4','-c:v','libx264','-threads','2','-preset','veryfast','-b:v','4M','-maxrate','4M','-bufsize','8M','-g','60','-bf','2','-x264-params','scenecut=0:keyint=60:min-keyint=60','-pix_fmt','yuv420p',str(f/'segment.mp4')])
(f/'sparse.srt').write_text('1\n00:00:00,500 --> 00:00:08,000\nA long cue covering the early seek target.\n\n2\n00:00:45,000 --> 00:00:49,000\nA sparse late cue beyond the initial lookahead.\n\n3\n00:00:58,000 --> 00:01:02,000\nThe final cue.\n')
run(['-stream_loop','-1','-i',str(f/'segment.mp4'),'-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-f','lavfi','-i','sine=frequency=660:sample_rate=44100','-i',str(f/'sparse.srt'),'-t','64','-map','0:v:0','-map','1:a:0','-map','2:a:0','-map','3:s:0','-c:v','copy','-c:a','aac','-b:a','96k','-c:s','mov_text','-metadata:s:a:0','language=eng','-metadata:s:a:1','language=jpn','-metadata:s:s:0','language=eng','-movflags','+faststart',str(f/'multiplex.mp4')])
run(['-i',str(f/'multiplex.mp4'),'-map','0','-c','copy','-c:s','srt',str(f/'multiplex.mkv')])
run(['-i',str(f/'multiplex.mp4'),'-map','0:v:0','-map','0:a','-c','copy',str(f/'multiplex.ts')])
# Matched source pixels but separately encoded one-slice/four-slice H.264 clips.
for slices in [1,4]:
 run(['-f','lavfi','-i','testsrc2=size=1920x1080:rate=60','-t','3','-c:v','libx264','-threads','2','-preset','veryfast','-crf','23','-g','120','-bf','2','-x264-params',f'scenecut=0:keyint=120:min-keyint=120:slices={slices}','-pix_fmt','yuv420p',str(f/f'h264-slices-{slices}.mp4')])
manifest={p.name:{'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in f.iterdir() if p.is_file()}
(w/'evidence/fixtures.json').write_text(json.dumps(manifest,indent=2))
print('Fixture generation complete',flush=True)
