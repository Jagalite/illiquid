#!/usr/bin/env python3
"""Progress-table storage experiment, NOT an Illiquid persistence implementation.
Uses Python's SQLite adapter (native SQLite underneath), WAL/FULL, explicit
transactions, a bounded cache and no full-history hydration. No Cocoa store,
version archives, migration, preference precedence, or app integration is provided.
Every fixture is isolated under an owned temporary directory. No app data touched.
"""
from __future__ import annotations
import argparse, json, os, platform, random, select, signal, sqlite3, statistics, subprocess, sys, tempfile, time
from pathlib import Path

UPSERT='''INSERT INTO progress(path,position,duration,completed) VALUES(?,?,?,?)
ON CONFLICT(path) DO UPDATE SET position=excluded.position,duration=excluded.duration,
completed=MAX(progress.completed,excluded.completed)
WHERE progress.position IS NOT excluded.position OR progress.duration IS NOT excluded.duration
OR progress.completed < excluded.completed'''

def connect(path: Path) -> sqlite3.Connection:
    db=sqlite3.connect(path,timeout=0.1,isolation_level=None)
    assert db.execute('PRAGMA journal_mode=WAL').fetchone()[0]=='wal'
    db.execute('PRAGMA synchronous=FULL')
    db.execute('PRAGMA cache_size=-2048') # nominal 2 MiB page cache, not total process memory
    db.execute('PRAGMA wal_autocheckpoint=1000')
    assert db.execute('PRAGMA synchronous').fetchone()[0]==2
    return db

def schema(db: sqlite3.Connection) -> None:
    db.execute('''CREATE TABLE progress(path TEXT PRIMARY KEY NOT NULL,
      position REAL,duration REAL NOT NULL CHECK(duration>0),
      completed INTEGER NOT NULL CHECK(completed IN(0,1))) WITHOUT ROWID''')

def update(db: sqlite3.Connection,path: str,position: float,duration: float) -> None:
    completed=int(position/duration>0.9)
    db.execute(UPSERT,(path,None if completed else position,duration,completed))

def seed(path: Path,count: int) -> None:
    db=connect(path)
    try:
        schema(db);db.execute('BEGIN IMMEDIATE')
        db.executemany('INSERT INTO progress VALUES(?,?,?,0)',((f'/synthetic/library/episode-{i}.mkv',float(i%400),3600.) for i in range(count)))
        db.execute('COMMIT');db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    finally:db.close()

def size(path: Path) -> int:
    try:return path.stat().st_size
    except FileNotFoundError:return 0

def benchmark(count: int,mode: str) -> dict:
    with tempfile.TemporaryDirectory(prefix='illiquid-sqlite-research-') as raw:
        path=Path(raw)/'history.sqlite';seed(path,count)
        opened=time.perf_counter_ns();db=connect(path)
        key='/synthetic/library/episode-0.mkv'
        assert db.execute('SELECT position FROM progress WHERE path=?',(key,)).fetchone()==(0.,)
        open_read_ns=time.perf_counter_ns()-opened
        updates=100 if mode=='batched' else 5
        per_commit=[];before_changes=db.total_changes
        start=time.perf_counter_ns()
        if mode=='batched': db.execute('BEGIN IMMEDIATE')
        for i in range(updates):
            if mode!='batched': db.execute('BEGIN IMMEDIATE')
            update(db,key,float(i+12),3600.)
            if mode!='batched':
                t=time.perf_counter_ns();db.execute('COMMIT');per_commit.append(time.perf_counter_ns()-t)
        if mode=='batched':
            t=time.perf_counter_ns();db.execute('COMMIT');per_commit.append(time.perf_counter_ns()-t)
        operation_ns=time.perf_counter_ns()-start
        wal_bytes=size(Path(str(path)+'-wal'))
        assert db.execute('SELECT position,duration,completed FROM progress WHERE path=?',(key,)).fetchone()==(float(updates+11),3600.,0)
        assert db.execute('SELECT count(*) FROM progress').fetchone()[0]==count
        assert db.execute('PRAGMA integrity_check').fetchone()==('ok',)
        changed=db.total_changes-before_changes
        # Count no-op SQL effects separately, outside timed changed updates.
        no_op_wal_before=wal_bytes;db.execute('BEGIN IMMEDIATE');before=db.total_changes
        update(db,key,float(updates+11),3600.);db.execute('COMMIT')
        no_op_changes=db.total_changes-before
        no_op_wal_growth=size(Path(str(path)+'-wal'))-no_op_wal_before
        db.close()
        # Reopen verifies logical persistence, not a physical power-loss test.
        db=connect(path);assert db.execute('SELECT position FROM progress WHERE path=?',(key,)).fetchone()==(float(updates+11),);db.close()
        return dict(count=count,mode=mode,updates=updates,commits=len(per_commit),operation_ns=operation_ns,
          commit_ns=per_commit,open_and_single_read_ns=open_read_ns,wal_file_bytes=wal_bytes,
          database_bytes=size(path),updated_rows=changed,no_op_changed_rows=no_op_changes,
          no_op_wal_file_growth=no_op_wal_growth,sqlite_version=sqlite3.sqlite_version,
          synchronous='FULL',journal='WAL',adapter='Python sqlite3; not production Swift store')

def worker(path: Path,commit: bool) -> None:
    db=connect(path);db.execute('BEGIN IMMEDIATE');update(db,'/synthetic/library/episode-0.mkv',777.,3600.)
    if commit:db.execute('COMMIT')
    print('ready',flush=True)
    # Only the parent kills this owned child; never terminates other processes.
    time.sleep(60)
    db.close()

def tests() -> dict:
    checks=0;randomizer=random.Random(310)
    with tempfile.TemporaryDirectory(prefix='illiquid-sqlite-tests-') as raw:
        root=Path(raw);path=root/'history.sqlite';seed(path,1)
        db=connect(path);oracle={f'/synthetic/library/episode-0.mkv':(0.,3600.,0)}
        for batch in range(100):
            db.execute('BEGIN IMMEDIATE')
            for _ in range(100):
                key=f'/synthetic/library/episode-{randomizer.randrange(50)}.mkv'
                pos=float(randomizer.randrange(120));duration=100.
                old=oracle.get(key,(None,duration,0));completed=int(pos/duration>0.9)
                update(db,key,pos,duration);oracle[key]=(None if completed else pos,duration,max(old[2],completed))
            db.execute('COMMIT')
            actual={row[0]:tuple(row[1:]) for row in db.execute('SELECT path,position,duration,completed FROM progress')}
            assert actual==oracle;checks+=1
        before=list(db.execute('SELECT * FROM progress ORDER BY path'))
        db.execute('BEGIN IMMEDIATE');update(db,'/new',50.,100.);db.execute('ROLLBACK')
        assert before==list(db.execute('SELECT * FROM progress ORDER BY path'));checks+=1
        # Concurrent reader snapshot does not observe uncommitted changes.
        reader=connect(path);db.execute('BEGIN IMMEDIATE');update(db,'/new',50.,100.)
        assert reader.execute('SELECT position FROM progress WHERE path=?',('/new',)).fetchone() is None;checks+=1
        db.execute('COMMIT');assert reader.execute('SELECT position FROM progress WHERE path=?',('/new',)).fetchone()==(50.,);checks+=1
        reader.close();db.close()
        crash_cases=[]
        for commit in [False,True]:
            for attempt in range(5):
                crash=root/f'crash-{commit}-{attempt}.sqlite';seed(crash,1)
                child=subprocess.Popen([sys.executable,__file__,'worker',str(crash),str(int(commit))],stdout=subprocess.PIPE,text=True)
                try:
                    ready,_,_=select.select([child.stdout],[],[],10)
                    assert ready and child.stdout.readline().strip()=='ready'
                    child.kill();child.wait(timeout=10)
                    loaded=connect(crash);position=loaded.execute('SELECT position FROM progress').fetchone()[0]
                    assert position==(777. if commit else 0.)
                    assert loaded.execute('PRAGMA integrity_check').fetchone()==('ok',)
                    loaded.close();checks+=2
                    crash_cases.append(dict(commit=commit,attempt=attempt,recovered_position=position,integrity='ok'))
                finally:
                    if child.poll() is None:child.kill();child.wait(timeout=10)
        return dict(checks=checks,mixed_updates=10000,matching_receipts=100,
            process_kill_cases=crash_cases,power_loss_test=False,feature_complete=False)

def main():
    if len(sys.argv)>1 and sys.argv[1]=='worker':worker(Path(sys.argv[2]),bool(int(sys.argv[3])));return
    if len(sys.argv)>1 and sys.argv[1]=='case':print(json.dumps(benchmark(int(sys.argv[2]),sys.argv[3])));return
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--repeats',type=int,default=3)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    if any(a.output.iterdir()):p.error('output must be empty')
    (a.output/'tests.json').write_text(json.dumps(tests(),indent=2))
    (a.output/'manifest.json').write_text(json.dumps(dict(platform=platform.platform(),python=sys.version,sqlite=sqlite3.sqlite_version,
        note='Isolated progress-table feasibility experiment. Not a controlled Swift-JSON head-to-head.',source_sha256=__import__('hashlib').sha256(Path(__file__).read_bytes()).hexdigest()),indent=2))
    rows=[]
    for rep in range(a.repeats):
        counts=[1000,10000,100000] if rep%2==0 else [100000,10000,1000]
        for count in counts:
            for mode in ['batched','flushed']:
                cmd=[sys.executable,__file__,'case',str(count),mode]
                result=subprocess.run(cmd,text=True,capture_output=True,timeout=90)
                with (a.output/'commands.jsonl').open('a') as f:f.write(json.dumps(dict(command=cmd,returncode=result.returncode,stdout=result.stdout,stderr=result.stderr))+'\n')
                if result.returncode:raise RuntimeError(result.stderr)
                row=json.loads(result.stdout);row['repeat']=rep;rows.append(row)
                with (a.output/'measurements.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
    summary=[]
    for count in [1000,10000,100000]:
        for mode in ['batched','flushed']:
            group=[r for r in rows if r['count']==count and r['mode']==mode];d=dict(count=count,mode=mode,samples=len(group))
            for key in ['operation_ns','wal_file_bytes','database_bytes','open_and_single_read_ns']:
                vals=[r[key] for r in group];d[key]=dict(median=statistics.median(vals),min=min(vals),max=max(vals))
            summary.append(d)
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
if __name__=='__main__':main()
