#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real Scene -> Rust socket client -> own NSWindow helper -> independent SkyLight readback.
The false-ack peer tests rejection only and is explicitly separate from native evidence.
"""
import ctypes as C
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time

root = Path.cwd()
build = root / 'target/privileged'
binary = root / 'target/debug/driftwm-runtime'
run = Path(tempfile.mkdtemp(prefix='runtime-', dir='/tmp'))
os.chmod(run, 0o700)
nonce = secrets.token_hex(32)
nonce_file = run / 'nonce'
nonce_file.write_text(nonce)
nonce_file.chmod(0o600)
log = open(run / 'host.log', 'w')
host = subprocess.Popen([str(build/'host'), str(build/'payload-arm64.dylib'), str(run), nonce], stdout=log, stderr=log)
clients = []
results = []

class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]
class Size(C.Structure):
    _fields_ = [('width', C.c_double), ('height', C.c_double)]
class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Size)]
sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetScreenRectForWindow.argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]
sky.SLSGetScreenRectForWindow.restype = C.c_int

def screen():
    r = Rect()
    assert sky.SLSGetScreenRectForWindow(sky.SLSMainConnectionID(), identity['wid'], C.byref(r)) == 0
    return [r.origin.x, r.origin.y, r.size.width, r.size.height]

def near(a, b, tolerance=1):
    assert len(a) == len(b) and all(abs(x-y) <= tolerance for x,y in zip(a,b)), (a,b)

def response(child):
    line = child.stdout.readline()
    assert line, ('runtime ended', child.poll(), child.stderr.read())
    return json.loads(line)

def command(child, op, **fields):
    child.stdin.write(json.dumps(dict(op=op, **fields))+'\n'); child.stdin.flush()
    return response(child)

def start(scene_path=run/'scene.json', directory=run):
    child = subprocess.Popen([str(binary),'session',str(directory),str(nonce_file),str(run/'identity.json'),str(scene_path),'1'], stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    clients.append(child)
    ready=response(child)
    assert ready['ok'], ready
    return child

def restored(reason=None):
    deadline=time.monotonic()+4
    while time.monotonic()<deadline:
        try:
            receipt=json.loads((run/'recovery.json').read_text())
            if receipt.get('restored') and (reason is None or receipt.get('reason')==reason):
                near(receipt['readback']['matrix'],original['matrix'],1e-6)
                near(screen(),original['screen_rect'])
                return receipt
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.025)
    raise AssertionError(('restoration failed',reason,(run/'host.log').read_text()))

try:
    deadline=time.monotonic()+8
    while not (run/'helper.sock').exists():
        assert host.poll() is None, (run/'host.log').read_text()
        assert time.monotonic()<deadline
        time.sleep(.03)
    probe=json.loads(subprocess.check_output([str(binary),'probe',str(run),str(nonce_file)],text=True))
    identity=probe['identity']; original=probe['readback']
    assert identity['pid']==host.pid, identity
    (run/'identity.json').write_text(json.dumps(identity))
    x,y,w,h=original['screen_rect']
    def rect(x,y,w,h): return dict(origin=dict(x=x,y=y),size=dict(width=w,height=h))
    scene=dict(version=1,scene=dict(windows=[dict(id=1,world_rect=rect(x,y,w,h),title='explicit cooperative fixture'),dict(id=2,world_rect=rect(1000000,1000000,100,100),title='persistent offscreen world entry')],outputs=[dict(id=1,camera=dict(x=0,y=0),zoom=1,screen_bounds=rect(0,0,4000,4000))],focused=None,bookmarks={}))
    (run/'scene.json').write_text(json.dumps(scene))
    child=start()
    baseline=command(child,'apply');assert baseline['ok'],baseline
    pan=command(child,'pan',output=1,delta=[20,10]);assert pan['ok']
    assert pan['presented']['revision']==0 and pan['desired_revision']==1,pan
    applied=command(child,'apply');assert applied['ok'],applied
    near(screen(),[x-20,y-10,w,h]);near(screen(),applied['presented']['screen_rect'])
    zoom=command(child,'zoom',output=1,zoom=.5,anchor=[x,y]);assert zoom['ok'],zoom
    applied=command(child,'apply');assert applied['ok'],applied
    expected=[x-10,y-5,w*.5,h*.5]
    near(screen(),expected);near(screen(),applied['presented']['readback']['screen_rect'])
    assert applied['world_windows']==scene['scene']['windows'],applied
    results.append(dict(test='Scene pan and anchored zoom',presented=applied['presented'],independent_screen=screen(),world_windows=applied['world_windows']))
    time.sleep(3.2)  # Helper lease is 2s; idle stdin must not suspend heartbeats.
    heartbeat=command(child,'readback');assert heartbeat['ok'],heartbeat
    near(screen(),expected)
    results.append(dict(test='heartbeat holds real native presentation for 3.2 seconds',readback=heartbeat['readback']))
    saved=run/'saved-scene.json'
    assert command(child,'save',path=str(saved))['ok']
    persisted=json.loads(saved.read_text())
    assert persisted['scene']['windows']==scene['scene']['windows']
    assert persisted['scene']['outputs'][0]['zoom']==.5
    close=command(child,'close');assert close['ok'],close
    assert child.wait(timeout=4)==0
    near(screen(),original['screen_rect'])
    results.append(dict(test='explicit verified restore and scene persistence',response=close))

    child=start(saved)
    assert command(child,'apply')['ok']
    near(screen(),expected)
    assert command(child,'disconnect')['ok']
    assert child.wait(timeout=4)==0
    results.append(dict(test='connection-loss native restoration',receipt=restored('disconnect')))

    child=start(saved); assert command(child,'apply')['ok']
    child.kill();child.wait(timeout=4)
    results.append(dict(test='controller SIGKILL native restoration',receipt=restored('disconnect')))

    child=start(saved); assert command(child,'apply')['ok']
    child.stdin.close()
    eof=response(child);assert eof['ok'] and eof['event']=='restored',eof
    assert child.wait(timeout=4)==0
    near(screen(),original['screen_rect'])
    results.append(dict(test='EOF Drop lifecycle restoration',response=eof))

    # Unsupported native capabilities fail while original scene stays unchanged.
    for name, changed in [('duplicate',json.loads(json.dumps(scene))),('clipping',json.loads(json.dumps(scene))),('offscreen',json.loads(json.dumps(scene)))]:
        if name=='duplicate':
            second=dict(changed['scene']['outputs'][0]);second['id']=2
            changed['scene']['outputs'].append(second)
        elif name=='clipping': changed['scene']['outputs'][0]['screen_bounds']=rect(0,0,x+w/2,4000)
        else: changed['scene']['outputs'][0]['camera']['x']=10000
        path=run/(name+'.json');path.write_text(json.dumps(changed))
        child=start(path)
        reply=command(child,'apply');assert not reply['ok'],reply
        if name=='clipping': assert 'clipping' in reply['error'],reply
        assert child.wait(timeout=4)!=0
        near(screen(),original['screen_rect'])
        assert json.loads(path.read_text())==changed
        results.append(dict(test='reject '+name,response=reply))

    # A same-UID false-ack server models a native setter no-op. Its unchanged
    # readback must never be accepted as an applied scene revision.
    fake=run/'false-ack';fake.mkdir(mode=0o700)
    listener=socket.socket(socket.AF_UNIX);listener.bind(str(fake/'helper.sock'))
    os.chmod(fake/'helper.sock',0o600);listener.listen(1)
    def false_ack():
        s,_=listener.accept()
        with s, s.makefile('rb') as stream:
            for line in stream:
                request=json.loads(line)
                assert request['nonce']==nonce
                reply=dict(v=1,ok=True,identity=identity,readback=original,readback_matches_requested=True,restored=True)
                s.sendall(json.dumps(reply).encode()+b'\n')
        listener.close()
    server=threading.Thread(target=false_ack,daemon=True);server.start()
    child=start(saved,fake)
    reply=command(child,'apply');assert not reply['ok'] and 'matrix readback mismatch' in reply['error'],reply
    assert child.wait(timeout=4)!=0
    server.join(timeout=3);assert not server.is_alive()
    results.append(dict(test='false native no-op acknowledgment rejected (protocol fault injection)',response=reply))
    near(screen(),original['screen_rect'])
    absent=subprocess.run([str(binary),'probe',str(run/'absent'),str(nonce_file)],text=True,capture_output=True,timeout=4)
    assert absent.returncode!=0 and 'helper' in absent.stdout
    results.append(dict(test='missing helper fails explicitly',response=json.loads(absent.stdout)))
    evidence=dict(status='PASS',scope='owned cooperative NSWindow only; no injection or permissions/settings changes',tests=results,limits=['selected single unclipped window only','foreign-window privilege and input not proven','per-output clipping, hiding and duplicate native placements unsupported'])
    (run/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(evidence,indent=2))
    print('Evidence:',run/'evidence.json')
finally:
    for child in clients:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill();child.wait()
    host.terminate()
    try: host.wait(timeout=3)
    except subprocess.TimeoutExpired: host.kill();host.wait()
    log.close()
    nonce_file.unlink(missing_ok=True)
