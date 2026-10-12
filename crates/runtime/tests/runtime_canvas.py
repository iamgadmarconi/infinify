#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real Scene -> Rust client -> v2 helper -> independent SkyLight readback.

The fault peers below speak the same binary v2 protocol and are kept separate
from the owned native fixture evidence.
"""
import ctypes as C
import json
import os
from pathlib import Path
import secrets
import socket
import struct
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
    journal_path=run/'v2-journal.json'
    while time.monotonic()<deadline:
        try:
            journal=json.loads(journal_path.read_text())
            last=journal.get('last_restore') or {}
            if journal.get('state')=='empty' and not journal.get('windows') and (reason is None or last.get('reason')==reason):
                assert last.get('results') and all(result['outcome']=='restored' for result in last['results']), last
                near(screen(),original['screen_rect'])
                return journal
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.025)
    raise AssertionError(('v2 restoration journal did not confirm recovery',reason,(run/'host.log').read_text()))

def recv_exact(stream, count):
    data=bytearray()
    while len(data)<count:
        block=stream.recv(count-len(data))
        if not block:
            return None if not data else bytes(data)
        data.extend(block)
    return bytes(data)

def wire_identity(who):
    return struct.pack('<iIQQ',who['pid'],who['wid'],who['birth_sec'],who['birth_usec'])

def readback_body(who, state, status=0):
    return (wire_identity(who)+struct.pack('<Ii',status,who['owner'])
            +struct.pack('<6d',*state['matrix'])
            +struct.pack('<4d',*state['bounds'])
            +struct.pack('<4d',*state['screen_rect']))

def inspection_refusal_body(who, status):
    # v2 refusal replies contain only identity and status; owner and geometry
    # are required to remain zero so callers cannot mistake them for a readback.
    return wire_identity(who)+struct.pack('<I',status)+bytes(144-28)

class FakeV2Peer(threading.Thread):
    """Minimal binary-v2 peer for protocol faults and false native acknowledgments."""
    def __init__(self, directory, who, state, *, fault=None):
        super().__init__(daemon=True)
        self.directory=directory
        self.who=who
        self.state=state
        self.fault=fault
        self.ready=threading.Event()
        self.requests=[]
        self.error=None
        self.saw_frame=False
        self.frame_matrix=None
        self.inspect_count=0
        self.drifted_readback=False

    def send(self, connection, kind, seq, body, *, wrong_seq=False):
        if wrong_seq:
            seq+=1
        connection.sendall(struct.pack('<IHHQ',len(body),kind|0x8000,0,seq)+body)

    def run(self):
        listener=socket.socket(socket.AF_UNIX)
        try:
            path=self.directory/'v2.sock'
            listener.bind(str(path))
            os.chmod(path,0o600)
            listener.listen(1)
            listener.settimeout(8)
            self.ready.set()
            connection,_=listener.accept()
            with connection:
                connection.settimeout(8)
                last_seq=0
                while True:
                    raw_header=recv_exact(connection,16)
                    if raw_header is None:
                        break
                    if len(raw_header)!=16:
                        raise AssertionError('truncated client protocol header')
                    length,kind,flags,seq=struct.unpack('<IHHQ',raw_header)
                    if flags or length>131072 or seq!=last_seq+1:
                        raise AssertionError(('invalid client protocol header',length,kind,flags,seq,last_seq))
                    body=recv_exact(connection,length)
                    if body is None or len(body)!=length:
                        raise AssertionError('truncated client protocol body')
                    last_seq=seq
                    self.requests.append(kind)
                    if kind==1:  # HELLO
                        if len(body)!=88 or body[:4]!=b'DWv2' or struct.unpack_from('<HH',body,4)!=(2,1) or body[8:72].decode()!=nonce:
                            raise AssertionError('invalid v2 HELLO')
                        if self.fault=='wrong-sequence':
                            self.send(connection,kind,seq,bytes(48),wrong_seq=True)
                            break
                        hello=struct.pack('<7Ii16s',0,2000,1024,131072,22,1,0,os.getpid(),b'token-for-test!!')
                        self.send(connection,kind,seq,hello)
                    elif kind==5:  # PROBE
                        if body:
                            raise AssertionError('PROBE body must be empty')
                        probe=struct.pack('<4Ii3I4Q2I',1,22,0,2000,os.getpid(),0,0,0,0,0,0,0,0,1)+wire_identity(self.who)
                        self.send(connection,kind,seq,probe)
                    elif kind==7:  # INSPECT
                        if body!=wire_identity(self.who):
                            raise AssertionError('INSPECT identity differs from the selected fixture')
                        self.inspect_count+=1
                        if self.fault=='inspect-refusal' and self.inspect_count==1:
                            self.send(connection,kind,seq,inspection_refusal_body(self.who,1))
                        else:
                            state=self.state
                            if self.fault=='drift-before-frame' and self.inspect_count==3:
                                state=dict(self.state)
                                state['matrix']=list(self.state['matrix'])
                                state['bounds']=list(self.state['bounds'])
                                state['screen_rect']=list(self.state['screen_rect'])
                                state['matrix'][4]+=3
                                state['bounds'][0]+=3
                                state['screen_rect'][0]+=3
                                self.drifted_readback=True
                            self.send(connection,kind,seq,readback_body(self.who,state))
                    elif kind==2:  # FRAME
                        if len(body)!=88 or struct.unpack_from('<II',body)!=(1,0):
                            raise AssertionError('expected one well-formed transform frame')
                        self.frame_matrix=struct.unpack_from('<6d',body,32)
                        if all(abs(a-b)<1e-6 for a,b in zip(self.frame_matrix,self.state['matrix'])):
                            raise AssertionError('false-ack frame did not request a changed transform')
                        self.saw_frame=True
                        frame=struct.pack('<IIIIQ',0,1,0,0,1)+b'\0'
                        self.send(connection,kind,seq,frame)
                    elif kind==3:  # HEARTBEAT
                        if body:
                            raise AssertionError('HEARTBEAT body must be empty')
                        self.send(connection,kind,seq,struct.pack('<IIII',0,2000,0,0))
                    elif kind==4:  # RESTORE_ALL
                        if body:
                            raise AssertionError('RESTORE_ALL body must be empty')
                        self.send(connection,kind,seq,struct.pack('<IIII',0,0,1,0))
                    else:
                        raise AssertionError(('unexpected client message',kind))
        except (OSError, AssertionError, UnicodeDecodeError, struct.error) as error:
            self.error=error
        finally:
            self.ready.set()
            listener.close()

def fake_probe_fault(label, fault, expected_error):
    fake=run/label
    fake.mkdir(mode=0o700)
    os.chmod(fake,0o700)
    peer=FakeV2Peer(fake,identity,original,fault=fault)
    peer.start()
    assert peer.ready.wait(timeout=3), 'fake v2 peer did not start'
    result=subprocess.run([str(binary),'probe',str(fake),str(nonce_file)],text=True,capture_output=True,timeout=5)
    peer.join(timeout=4)
    assert not peer.is_alive(), 'fake v2 peer did not observe client shutdown'
    assert peer.error is None, peer.error
    assert result.returncode!=0, result
    reply=json.loads(result.stdout)
    assert not reply['ok'] and expected_error in reply['error'], reply
    assert 2 not in peer.requests, peer.requests
    results.append(dict(test=label,response=reply,requests=peer.requests))

try:
    deadline=time.monotonic()+8
    while not (run/'v2.sock').exists():
        assert host.poll() is None, (run/'host.log').read_text()
        assert time.monotonic()<deadline
        time.sleep(.03)
    # The socket can be ready before AppKit's opening animation has settled.
    # Require stable, coherent original geometry before constructing the Scene;
    # never relax the runtime's matrix/rectangle acknowledgment to hide a race.
    previous=None
    stable_since=None
    deadline=time.monotonic()+3
    while True:
        probe=json.loads(subprocess.check_output([str(binary),'probe',str(run),str(nonce_file)],text=True))
        assert probe['v']==2 and probe['server_pid']==host.pid and len(probe['windows'])==1, probe
        candidate=probe['windows'][0]
        state=candidate['readback']
        a,b,c,d,_,_=state['matrix']
        coherent=(a>0 and d>0 and b==0 and c==0
                  and abs(a*state['screen_rect'][2]-state['bounds'][2])<=1
                  and abs(d*state['screen_rect'][3]-state['bounds'][3])<=1)
        now=time.monotonic()
        if coherent and candidate==previous:
            if stable_since is not None and now-stable_since>=.1:
                break
        else:
            stable_since=now if coherent else None
        previous=candidate
        assert now<deadline, ('fixture original geometry did not settle',candidate)
        time.sleep(.04)
    assert probe['v']==2 and probe['server_pid']==host.pid, probe
    assert len(probe['windows'])==1, probe
    identity=probe['windows'][0]['identity']; original=probe['windows'][0]['readback']
    assert identity['pid']==host.pid and identity['owner']>0, identity
    assert original['readback_ok'], original
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
    results.append(dict(test='explicit verified restore and scene persistence',response=close,journal=restored('explicit')))

    child=start(saved)
    assert command(child,'apply')['ok']
    near(screen(),expected)
    assert command(child,'disconnect')['ok']
    assert child.wait(timeout=4)==0
    results.append(dict(test='connection-loss native restoration',journal=restored('disconnect')))

    child=start(saved); assert command(child,'apply')['ok']
    child.kill();child.wait(timeout=4)
    results.append(dict(test='controller SIGKILL native restoration',journal=restored('disconnect')))

    child=start(saved); assert command(child,'apply')['ok']
    child.stdin.close()
    eof=response(child);assert eof['ok'] and eof['event']=='restored',eof
    assert child.wait(timeout=4)==0
    near(screen(),original['screen_rect'])
    results.append(dict(test='EOF Drop lifecycle restoration',response=eof,journal=restored('explicit')))

    # Unsupported capabilities fail while the persisted desired Scene stays intact.
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

    # A v2 peer claims the frame applied but leaves the transform unchanged.
    # The independent INSPECT readback must reject the no-op before success.
    fake=run/'false-ack';fake.mkdir(mode=0o700);os.chmod(fake,0o700)
    peer=FakeV2Peer(fake,identity,original)
    peer.start();assert peer.ready.wait(timeout=3)
    child=start(saved,fake)
    reply=command(child,'apply');assert not reply['ok'] and 'matrix readback mismatch' in reply['error'],reply
    assert child.wait(timeout=4)!=0
    peer.join(timeout=4);assert not peer.is_alive()
    assert peer.error is None, peer.error
    assert peer.saw_frame and 2 in peer.requests and 7 in peer.requests, peer.requests
    results.append(dict(test='v2 false native no-op acknowledgment rejected after INSPECT',response=reply,requested_matrix=peer.frame_matrix,requests=peer.requests))

    # Native state can drift after enrollment but before the first frame. The
    # controller must reject the changed full readback before sending FRAME.
    fake=run/'drift-before-frame';fake.mkdir(mode=0o700);os.chmod(fake,0o700)
    peer=FakeV2Peer(fake,identity,original,fault='drift-before-frame')
    peer.start();assert peer.ready.wait(timeout=3)
    child=start(saved,fake)
    reply=command(child,'apply');assert not reply['ok'],reply
    assert child.wait(timeout=4)!=0
    peer.join(timeout=4);assert not peer.is_alive()
    assert peer.error is None, peer.error
    assert peer.inspect_count==3 and peer.drifted_readback, (peer.inspect_count,peer.drifted_readback)
    assert not peer.saw_frame and 2 not in peer.requests, peer.requests
    results.append(dict(test='pre-frame native drift rejected before mutation',response=reply,inspect_count=peer.inspect_count,requests=peer.requests))

    fake_probe_fault('bad-v2-sequence','wrong-sequence','invalid helper reply header')
    fake_probe_fault('inspect-refusal','inspect-refusal','helper refused native inspection')

    absent=subprocess.run([str(binary),'probe',str(run/'absent'),str(nonce_file)],text=True,capture_output=True,timeout=4)
    assert absent.returncode!=0 and 'helper' in absent.stdout
    results.append(dict(test='missing v2 helper fails explicitly',response=json.loads(absent.stdout)))
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
