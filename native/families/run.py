#!/usr/bin/env python3
"""Bounded own-fixture end-to-end proof, lifecycle checks and byte-bound evidence."""
import hashlib
import json
import os
import pathlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from verify_normalized import verify

base=pathlib.Path(sys.argv[1]).resolve();base.mkdir(parents=True,exist_ok=True)
run=pathlib.Path(tempfile.mkdtemp(prefix='run-',dir=base))
binary=pathlib.Path('target/native-families/native-families').resolve()
inputs=[pathlib.Path(p) for p in ('native/families/families.m','native/families/window-server-family.h','native/families/owned-window-geometry.h','native/families/YABAI-NOTICE.txt','native/families/verify.py','native/families/verify_normalized.py','native/families/run.py','scripts/build-families.sh','tests/e2e/native-families.sh')]+[binary]
report={'passed':False,'implementation_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'checks':[]}
report['base_commit']=subprocess.run(['git','rev-parse','HEAD'],check=True,capture_output=True,text=True).stdout.strip()
for source_file in inputs[:-1]:
    snapshot=run/'implementation'/source_file
    snapshot.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(source_file,snapshot)
children=[]
lifecycle_only='--lifecycle-only' in sys.argv[2:]
def gone(pid):
    try:os.kill(pid,0);return False
    except ProcessLookupError:return True

def launch(name):
    folder=run/name;folder.mkdir()
    p=subprocess.Popen([str(binary),'--probe',str(folder)]);children.append(p)
    return folder,p

def ready(folder,p):
    end=time.monotonic()+5
    while time.monotonic()<end:
        f=folder/'source.json'
        if f.exists():return json.loads(f.read_text())
        assert p.poll() is None, 'host exited before source readiness'
        time.sleep(.02)
    raise AssertionError('source readiness deadline')

def redact(obj):
    if isinstance(obj,dict):return {k:redact(v) for k,v in obj.items() if k!='nonce'}
    if isinstance(obj,list):return [redact(v) for v in obj]
    return obj

try:
    assert subprocess.run([str(binary)],capture_output=True,timeout=3).returncode==0
    if not lifecycle_only:
        folder,p=launch('proof')
        assert p.wait(timeout=55)==0, json.loads((folder/'receipt.json').read_text()).get('failure')
        proof_folder=folder
    for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGKILL):
        folder,p=launch(sig.name);state=ready(folder,p);p.send_signal(sig);p.wait(timeout=8)
        deadline=time.monotonic()+6
        while time.monotonic()<deadline and not gone(state['pid']):time.sleep(.03)
        assert gone(state['pid']), ('orphan source',state['pid'])
        if sig==signal.SIGKILL:
            assert json.loads((folder/'source-exit.json').read_text())['reason']=='parent_exit'
        else:
            assert json.loads((folder/'receipt.json').read_text())['source_reaped']
    folder=run/'deadline';folder.mkdir()
    p=subprocess.Popen([str(binary),'--source',str(folder),'deadline-fixture','1']);children.append(p)
    assert p.wait(timeout=5)==0
    assert json.loads((folder/'source-exit.json').read_text())['reason']=='deadline'
    report['checks'].append('source deadline, SIGTERM/SIGINT cleanup and host-SIGKILL parent-death self-exit')
    if not lifecycle_only:
        report['proof']=verify(proof_folder)
        report['checks'].append('actual metadata-normalized root-family pixels: two root streams, no child stream/double count, native sizes/offsets, two transforms, clipping, live changes and destruction')
    else:
        report['scope']='lifecycle-only; no capture capability assertion'
    report['passed']=True
except BaseException as error:
    report['failure']=str(error)
    raise
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=4)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
    # Only redact after hosts are reaped AND every enrolled source has exited.
    for statefile in run.rglob('source.json'):
        pid=json.loads(statefile.read_text())['pid'];deadline=time.monotonic()+6
        while time.monotonic()<deadline and not gone(pid):time.sleep(.03)
        if not gone(pid):raise RuntimeError('source still alive; refusing export sanitation')
    for file in run.rglob('*.json'):
        file.write_text(json.dumps(redact(json.loads(file.read_text())),indent=2)+'\n')
    report['evidence_sha256']={str(p.relative_to(run)):hashlib.sha256(p.read_bytes()).hexdigest() for p in run.rglob('*') if p.is_file()}
    (run/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'directory':str(run),**{k:v for k,v in report.items() if k not in ('implementation_sha256','evidence_sha256')}},indent=2))
