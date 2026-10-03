#!/usr/bin/env python3
"""Create a source-only Homebrew tap using this package's verified local inputs.
Does not install, link, upgrade, or remove any package.
"""
import argparse,hashlib,json,re,shutil
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);p.add_argument('--base-url',default='http://127.0.0.1:8765');a=p.parse_args()
r=Path(__file__).resolve().parent;out=a.output.resolve()
if out.exists():raise SystemExit('Output must not exist')
m=json.loads((r/'source-manifest.json').read_text());records=m['records'];main={v['component']:v for v in records if not v.get('kind')};out.mkdir(parents=True);(out/'Formula').mkdir();(out/'Patches/glib').mkdir(parents=True)
for v in records:
 if v['status']=='downloaded' and hashlib.sha256((r/v['archive']).read_bytes()).hexdigest()!=v['sha256']:raise SystemExit('Checksum mismatch: '+v['archive'])
shutil.copyfile(r/'recipes/LICENSE.txt',out/'LICENSE.txt');shutil.copyfile(r/'patches/glib/hardcoded-paths.diff',out/'Patches/glib/hardcoded-paths.diff')
for name,v in main.items():
 text=(r/v['recipe']).read_text()
 if hashlib.sha256(text.encode()).hexdigest()!=v['recipe_sha256']:raise SystemExit('Recipe mismatch: '+name)
 url=a.base_url.rstrip('/')+'/'+v['archive']
 if name=='x264':
  text=re.sub(r'^  url .*?\n      revision: .*?\n',f'  url "{url}"\n  sha256 "{v["sha256"]}"\n',text,count=1,flags=re.M)
 else:
  text=re.sub(r'^  url "[^\"]+"',f'  url "{url}"',text,count=1,flags=re.M)
  text=re.sub(r'^  sha256 "[a-f0-9]+"',f'  sha256 "{v["sha256"]}"',text,count=1,flags=re.M)
 # Mirrors must not bypass the packaged source inputs.
 text=re.sub(r'^  mirror .*\n','',text,flags=re.M)
 for extra in records:
  if extra['component']!=name or extra.get('kind') not in ('resource','patch') or extra['status']!='downloaded':continue
  if extra['source_url'].startswith('https://raw.githubusercontent.com/Homebrew/'):continue
  text=text.replace(extra['source_url'],a.base_url.rstrip('/')+'/'+extra['archive'])
 # Pin every distributed runtime component to this tap. Other libraries and
 # general build tools remain external prerequisites documented in README.
 for dep in main:
  text=text.replace(f'depends_on "{dep}"',f'depends_on "jagalite/illiquid-source/{dep}"')
  text=text.replace(f'Formula["{dep}"]',f'Formula["jagalite/illiquid-source/{dep}"]')
  text=text.replace(f'formula_opt_prefix("{dep}")',f'formula_opt_prefix("jagalite/illiquid-source/{dep}")')
 if name=='harfbuzz':text=text.replace('      -Dtests=disabled','      -Dtests=disabled\n      -Ddocs=disabled',1)
 if name=='graphite2':text=text.replace('args = %W[', 'args = %W[\n      -DBUILD_TESTING=OFF',1)
 if name=='libpng':text=text.replace('    system "make", "test"\n','')
 (out/'Formula'/f'{name}.rb').write_text(text)
print(f'Prepared {len(main)} pinned recipes in {out}')
