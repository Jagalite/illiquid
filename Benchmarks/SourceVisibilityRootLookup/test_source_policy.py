import importlib.util,sys,json,argparse,tempfile
from pathlib import Path
sys.dont_write_bytecode=True
temporary = tempfile.TemporaryDirectory(prefix='root-lookup-policy-')
out = Path(temporary.name)
root = Path(__file__).resolve().parents[2]
path = root/'Benchmarks/SourceVisibilityRootLookup/run.py'
spec=importlib.util.spec_from_file_location('lookup',path); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
checks=[]
def reject(name,fn):
 try:fn()
 except (RuntimeError,ValueError):checks.append(name);return
 raise AssertionError(name)
matcher=(m.HERE/'baseline/SourceVisibilityMatcher.swift').read_bytes(); prod={'Sources/IlliquidApp/SourceBrowserFilter.swift':(root/'Sources/IlliquidApp/UI/SourceBrowserFilter.swift').read_bytes()}
assert m.reference_adapter(False,{},b'')==b''; checks.append('historical adapter absent')
assert m.reference_adapter(True,prod,matcher)==m.REFERENCE_ADAPTER
reject('matcher drift',lambda:m.reference_adapter(True,prod,matcher+b' '))
reject('filter drift',lambda:m.reference_adapter(True,{k:v+b' ' for k,v in prod.items()},matcher))
old=m.REFERENCE_ADAPTER;m.REFERENCE_ADAPTER=b'candidate substitution';reject('adapter substitution',lambda:m.reference_adapter(True,prod,matcher));m.REFERENCE_ADAPTER=old
args=argparse.Namespace(output=out/'policy-staging',current_source_correctness=True)
args.output.mkdir();r=m.Runner(args);r.prepare_sources();checks.append('full pinned extraction and staging')
reject('sample timing forbidden',lambda:r.sample('baseline','unused',1));reject('measurement forbidden',lambda:r.measure([]))
b=r.build/'baseline'/m.SIDEBAR_SNAPSHOT;c=r.build/'candidate'/m.SIDEBAR_SNAPSHOT
assert b.read_bytes().endswith(old);assert old not in c.read_bytes()
for rel in r.staged['baseline']:
 if rel!=m.SIDEBAR_SNAPSHOT:assert (r.build/'baseline'/rel).read_bytes()==(r.build/'candidate'/rel).read_bytes()
checks.append('all nonfocal staged bytes symmetric')
r.verify_sources();checks.append('staged provenance verified')
(out/'policy-results.json').write_text(json.dumps(checks,indent=2)+'\n');print(checks)
