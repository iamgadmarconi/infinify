#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Actual socket/NSWindow/SkyLight path. Never loads into Dock or other apps."""
import ctypes as C
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time

BUILD = Path('target/privileged')
run = Path(tempfile.mkdtemp(prefix='fixture-', dir=BUILD)).resolve().relative_to(Path.cwd())
os.chmod(run, 0o700)
nonce = secrets.token_hex(32)
log = open(run / 'host.log', 'w')
child = subprocess.Popen([str(BUILD/'host'), str((BUILD/'payload-arm64.dylib').resolve()), str(run), nonce], stdout=log, stderr=log)
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

def screen(wid):
    rect = Rect()
    status = sky.SLSGetScreenRectForWindow(sky.SLSMainConnectionID(), wid, C.byref(rect))
    assert status == 0, status
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]

def connect():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(4)
    s.connect(str(run/'helper.sock'))
    return s

def request(s, op, **fields):
    packet = dict(v=1, nonce=nonce, op=op, **fields)
    return raw(s, json.dumps(packet).encode()+b'\n')

def raw(s, packet):
    s.sendall(packet)
    data = b''
    while not data.endswith(b'\n'):
        part=s.recv(4096)
        if not part:
            break
        data += part
    return json.loads(data) if data else None

def receipt(reason):
    deadline=time.monotonic()+4
    while time.monotonic()<deadline:
        try:
            data=json.loads((run/'recovery.json').read_text())
            if data.get('reason')==reason and data.get('restored'):
                assert data['readback']['matrix']==original
                results.append(dict(test=reason,receipt=data))
                return data
        except (FileNotFoundError,json.JSONDecodeError):
            pass
        time.sleep(.03)
    raise AssertionError((reason,(run/'host.log').read_text()))

def transform(s, scale):
    value=request(s,'transform', identity=identity, matrix=[scale,0,0,scale,0,0])
    assert value['ok'] and value['readback_matches_requested'],value
    return value

try:
    deadline=time.monotonic()+8
    while not (run/'helper.sock').exists():
        assert child.poll() is None,(run/'host.log').read_text()
        assert time.monotonic()<deadline,'fixture socket not ready'
        time.sleep(.04)
    assert (run.stat().st_mode&0o777)==0o700
    assert ((run/'helper.sock').stat().st_mode&0o777)==0o600
    s=connect()
    probe=request(s,'probe');assert probe['ok'],probe
    identity=probe['identity'];original=probe['readback']['matrix']
    before=screen(identity['wid'])
    assert identity['pid']==child.pid
    enrolled=request(s,'enroll',identity=identity);assert enrolled['ok'],enrolled
    first=transform(s,1.5)
    after=screen(identity['wid'])
    assert after==first['readback']['screen_rect'],(after,first)
    assert abs(after[2]-before[2]/1.5)<2 and abs(after[3]-before[3]/1.5)<2,(before,after)
    second=transform(s,2)
    results.append(dict(test='independent_parent_screen_rect',before=before,after=after,transform=first,second_transform=second))
    assert request(s,'heartbeat')['ok']
    s.close()
    receipt('disconnect')
    assert screen(identity['wid'])==before

    # Idle authenticated connection expires even when a partial packet arrives.
    s=connect();transform(s,1.5);s.sendall(b'{"v":')
    receipt('lease expired');assert s.recv(1024)==b'';s.close()
    assert screen(identity['wid'])==before

    # Explicit restore reports native readback, then clean disconnect is harmless.
    s=connect();transform(s,1.5)
    restored=request(s,'restore');assert restored['ok'] and restored['restored'],restored
    assert restored['readback']['matrix']==original
    s.close();results.append(dict(test='explicit restore',response=restored))

    # Controlled filesystem fault in our fixture runtime: obstruct the exclusive
    # journal staging name after mutation, so native restore succeeds but persist
    # fails. This is real filesystem I/O failure, not a production fault hook.
    s=connect();transform(s,1.5)
    obstruction=run/'recovery.next';obstruction.mkdir(mode=0o700)
    failed=request(s,'restore');s.close()
    assert not failed['ok'] and failed['restored'] and not failed['recovery_persisted'],failed
    assert screen(identity['wid'])==before
    assert json.loads((run/'recovery.json').read_text())['state']=='pending'
    s=connect();retry_blocked=request(s,'restore');s.close()
    assert not retry_blocked['ok'] and not retry_blocked['recovery_persisted'],retry_blocked
    s=connect();mutation_blocked=request(s,'transform',identity=identity,matrix=[2,0,0,2,0,0])
    assert s.recv(1)==b''  # Wait until rejection cleanup finished with obstruction in place.
    s.close()
    assert not mutation_blocked['ok'] and 'recovery unresolved' in mutation_blocked['error'],mutation_blocked
    obstruction.rmdir()
    s=connect();retried=request(s,'restore');s.close()
    assert retried['ok'] and retried['restored'] and retried['recovery_persisted'],retried
    durable=json.loads((run/'recovery.json').read_text())
    assert durable['restored'] and durable['readback']['matrix']==original,durable
    s=connect();transform(s,1.5);assert request(s,'restore')['ok'];s.close()
    results.append(dict(test='fixture journal obstruction and explicit retry',failed=failed,retry_while_obstructed=retry_blocked,mutation_blocked=mutation_blocked,retried=retried,durable_receipt=durable))

    # With no controller connected, automatic retries must continue while the
    # same controlled persistence fault remains and finish after it is removed.
    s=connect();transform(s,1.5)
    obstruction.mkdir(mode=0o700)
    previous_log_size=(run/'host.log').stat().st_size
    s.close()
    deadline=time.monotonic()+3
    while True:
        new_log=(run/'host.log').read_text()[previous_log_size:]
        retries=[json.loads(line.split(' ',1)[1]) for line in new_log.splitlines() if line.startswith('RECOVERY_RETRY ')]
        if len(retries)>=2:
            break
        assert time.monotonic()<deadline,new_log
        time.sleep(.03)
    assert all(not r['ok'] and not r['recovery_persisted'] for r in retries),retries
    assert screen(identity['wid'])==before
    assert json.loads((run/'recovery.json').read_text())['state']=='pending'
    obstruction.rmdir()
    automatic=receipt('automatic retry')
    assert automatic['ok'] and screen(identity['wid'])==before
    # Durable recovery has cleared the mutation block, without requiring a new
    # request to trigger restoration or receipt completion.
    s=connect();transform(s,1.5);assert request(s,'restore')['ok'];s.close()
    results.append(dict(test='fixture journal obstruction and autonomous recovery',failed_retries=retries,durable_receipt=automatic))

    bad=[('wrong nonce',dict(v=1,nonce='0'*64,op='probe')),
         ('unsupported version',dict(v=2,nonce=nonce,op='probe')),
         ('singular matrix',dict(v=1,nonce=nonce,op='transform',identity=identity,matrix=[0,0,0,0,0,0])),
         ('wrong birth',dict(v=1,nonce=nonce,op='transform',identity=dict(identity,birth_sec=0),matrix=[2,0,0,2,0,0])),
         ('out of scope enrollment',dict(v=1,nonce=nonce,op='enroll',identity=dict(identity,pid=os.getpid()))),
         ('boolean matrix',dict(v=1,nonce=nonce,op='transform',identity=identity,matrix=[True,0,0,1,0,0])),
         ('unknown field',dict(v=1,nonce=nonce,op='probe',extra=1)),
         ('unknown operation',dict(v=1,nonce=nonce,op='arbitrary-packet')),
         ('nonfinite number',dict(v=1,nonce=nonce,op='transform',identity=identity,matrix=[float('nan'),0,0,1,0,0]))]
    for name,packet in bad:
        s=connect();reply=raw(s,json.dumps(packet).encode()+b'\n');s.close()
        assert reply and not reply['ok'],(name,reply)
        assert screen(identity['wid'])==before
        results.append(dict(test=name,response=reply))
    for packet in (b'not json\n',b'[]\n',b'null\n'):
        s=connect();reply=raw(s,packet);s.close();assert reply and not reply['ok'],reply
    s=connect();transform(s,1.5)
    s.sendall(b'x'*4097)
    try: assert s.recv(1024)==b''
    except ConnectionResetError: pass
    s.close();receipt('oversize packet')
    assert screen(identity['wid'])==before

    # Real companion client traverses exactly the same authenticated socket.
    client=subprocess.run([str(BUILD/'client'),str(run),nonce],input='{"op":"probe"}\n',text=True,capture_output=True,timeout=5)
    assert client.returncode==0,client.stderr
    assert json.loads(client.stdout)['ok']
    results.append(dict(test='companion client',response=json.loads(client.stdout)))
    doctor=json.loads(subprocess.check_output([str(BUILD/'doctor')],text=True))
    assert doctor['injection_executed'] is False and doctor['settings_changed'] is False
    evidence=dict(status='PASS',tests=results,doctor=doctor,scope='only spawned NSWindow; independent parent screen-rect observation; no Dock injection',limits=['production injection and foreign windows untested','cross-UID rejection enforced by getpeereid but cannot simulate another UID without privilege','server process death cannot run restoration; durable recovery journal remains'])
    (run/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(evidence,indent=2))
    print(f'PASS: exact fixture logs and receipt: {run}')
finally:
    # Our fixture owns the sole mutated window. Termination removes it on every exit.
    child.terminate()
    try: child.wait(timeout=3)
    except subprocess.TimeoutExpired: child.kill();child.wait()
    log.close()
