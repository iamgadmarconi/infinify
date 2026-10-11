#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Protocol v2 against the cooperative host's own windows. Never loads into Dock or
touches a window of another application. What a window does is read from this
process: the window server's screen rectangle and CGWindowList alpha, and the
journal from disk. Counters and per-record statuses are the helper's own word and
are named as such where they are used."""
import ctypes as C
import json
import math
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

BUILD = Path('target/privileged')
HEADER = struct.Struct('<IHHQ')
RECORD = struct.Struct('<iIQQ6dfI')
IDENTITY = struct.Struct('<iIQQ')
HELLO, FRAME, HEARTBEAT, RESTORE_ALL, PROBE, REPLY = 1, 2, 3, 4, 5, 0x8000
APPLIED, SCOPE, IDENTITY_MISMATCH, JOURNAL, BUSY_V1 = 0, 1, 2, 6, 9
OLD_PACKET_LIMIT = 4096
results = []
hosts = []

class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]
class Size(C.Structure):
    _fields_ = [('width', C.c_double), ('height', C.c_double)]
class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Size)]
class Transform(C.Structure):
    _fields_ = [(name, C.c_double) for name in ('a', 'b', 'c', 'd', 'tx', 'ty')]
sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetScreenRectForWindow.argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]
sky.SLSGetScreenRectForWindow.restype = C.c_int
sky.SLSGetWindowTransform.argtypes = [C.c_int, C.c_uint32, C.POINTER(Transform)]
sky.SLSGetWindowTransform.restype = C.c_int
cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGWindowListCopyWindowInfo.argtypes = [C.c_uint32, C.c_uint32]; cg.CGWindowListCopyWindowInfo.restype = C.c_void_p
cf.CFArrayGetCount.argtypes = [C.c_void_p]; cf.CFArrayGetCount.restype = C.c_long
cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]; cf.CFArrayGetValueAtIndex.restype = C.c_void_p
cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]; cf.CFDictionaryGetValue.restype = C.c_void_p
cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]; cf.CFNumberGetValue.restype = C.c_bool
cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]; cf.CFStringCreateWithCString.restype = C.c_void_p
cf.CFRelease.argtypes = [C.c_void_p]
K_NUMBER = cf.CFStringCreateWithCString(None, b'kCGWindowNumber', 0x08000100)
K_ALPHA = cf.CFStringCreateWithCString(None, b'kCGWindowAlpha', 0x08000100)

def screen(wid):
    """The window server's screen rectangle, asked from this process."""
    rect = Rect()
    status = sky.SLSGetScreenRectForWindow(sky.SLSMainConnectionID(), wid, C.byref(rect))
    assert status == 0, (wid, status)
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]

def alpha(wid):
    """kCGWindowAlpha from CGWindowListCopyWindowInfo, asked from this process."""
    rows = cg.CGWindowListCopyWindowInfo(1 << 3, wid)  # kCGWindowListOptionIncludingWindow
    assert rows, wid
    try:
        for i in range(cf.CFArrayGetCount(rows)):
            row = cf.CFArrayGetValueAtIndex(rows, i)
            number = C.c_longlong(0)
            cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_NUMBER), 4, C.byref(number))
            if number.value == wid:
                value = C.c_double(-1)
                cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_ALPHA), 13, C.byref(value))
                return value.value
    finally:
        cf.CFRelease(rows)
    raise AssertionError(f'window {wid} not listed')

def transform(wid):
    """The actual transform, read over this test's independent server connection."""
    value = Transform()
    assert sky.SLSGetWindowTransform(sky.SLSMainConnectionID(), wid, C.byref(value)) == 0
    return [getattr(value, name) for name, _ in Transform._fields_]

def near(seen, target, tolerance=1.0):
    # The window server reports the smallest whole-point rectangle that contains
    # the drawn one, so a fractional target is compared after the same widening.
    left, top = math.floor(target[0]), math.floor(target[1])
    whole = [left, top, math.ceil(target[0] + target[2]) - left, math.ceil(target[1] + target[3]) - top]
    return all(abs(x - y) <= tolerance for x, y in zip(seen, whole))

def all_near(wids, expected):
    return all(near(screen(w), e) for w, e in zip(wids, expected))

def wait_rects(wids, expected, timeout):
    """Seconds until every window is at its expected rectangle; fails after timeout."""
    start = time.monotonic()
    while not all_near(wids, expected):
        assert time.monotonic() - start < timeout, ('not reached', [screen(w) for w in wids], expected)
        time.sleep(.01)
    return time.monotonic() - start

class Host:
    def __init__(self, *flags, run=None, nonce=None, allow=None, ready='v2.sock'):
        self.run = run or Path(tempfile.mkdtemp(prefix='v2-', dir=BUILD)).resolve().relative_to(Path.cwd())
        os.chmod(self.run, 0o700)
        self.nonce = nonce or secrets.token_hex(32)
        self.log = open(self.run / 'host.log', 'a')
        extra = []
        if allow is not None:
            (self.run / 'allowlist.json').write_text(json.dumps(allow))
            extra = [str(self.run / 'allowlist.json')]
        self.child = subprocess.Popen([str(BUILD / 'host'), str((BUILD / 'payload-arm64.dylib').resolve()), str(self.run), self.nonce, *extra, *flags], stdout=self.log, stderr=self.log)
        hosts.append(self)
        deadline = time.monotonic() + 8
        while not (self.run / ready).exists():
            assert self.child.poll() is None, self.text()
            assert time.monotonic() < deadline, ready + ' not ready: ' + self.text()
            time.sleep(.04)
        assert ((self.run / ready).stat().st_mode & 0o777) == 0o600
    def text(self):
        return (self.run / 'host.log').read_text()
    def journal(self):
        return json.loads((self.run / 'v2-journal.json').read_text())
    def wait_journal(self, state, timeout=4):
        deadline = time.monotonic() + timeout
        while True:
            try:
                journal = self.journal()
                if journal['state'] == state:
                    return journal
            except (FileNotFoundError, json.JSONDecodeError):
                journal = None
            assert time.monotonic() < deadline, journal
            time.sleep(.02)
    def stop(self):
        if self.child.poll() is None:
            # Only ever a host this test started. A stopped one must run to be ended.
            self.child.send_signal(signal.SIGCONT)
            self.child.terminate()
            try: self.child.wait(timeout=3)
            except subprocess.TimeoutExpired: self.child.kill(); self.child.wait()
        self.log.close()

class Conn:
    def __init__(self, host, role=1, token=bytes(16), nonce=None, magic=b'DWv2', version=2):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(5)
        self.s.connect(str(host.run / 'v2.sock'))
        self.seq = 0
        body = struct.pack('<4sHH64s16s', magic, version, role, (nonce or host.nonce).encode(), token)
        self.send(HELLO, body)
        kind, _, reply = self.recv()
        assert kind == HELLO
        (self.status, self.lease_ms, self.max_records, self.max_body, self.caps, self.scope, self.queue, self.server_pid, self.token) = struct.unpack('<7Ii16s', reply)
    def packet(self, kind, body=b''):
        self.seq += 1
        return HEADER.pack(len(body), kind, 0, self.seq) + body
    def send(self, kind, body=b''):
        self.s.sendall(self.packet(kind, body))
        return self.seq
    def read(self, count):
        data = b''
        while len(data) < count:
            part = self.s.recv(count - len(data))
            if not part:
                raise EOFError
            data += part
        return data
    def recv(self):
        length, kind, flags, seq = HEADER.unpack(self.read(HEADER.size))
        assert kind & REPLY and not flags, (kind, flags)
        return kind & ~REPLY, seq, self.read(length)
    def frame_reply(self, want):
        kind, seq, body = self.recv()
        assert kind == FRAME and seq == want, (kind, seq, want)
        disposition, count, superseded, _, applied_total = struct.unpack('<4IQ', body[:24])
        return dict(disposition=disposition, superseded=superseded, frames_applied=applied_total, status=list(body[24:24 + count]))
    def frame(self, records):
        """One frame, answered: the per-record statuses."""
        want = self.send(FRAME, struct.pack('<II', len(records), 0) + b''.join(records))
        reply = self.frame_reply(want)
        assert reply['disposition'] == 0, reply
        return reply['status']
    def heartbeat(self):
        want = self.send(HEARTBEAT)
        kind, seq, body = self.recv()
        assert kind == HEARTBEAT and seq == want
        return dict(zip(('status', 'lease_ms', 'held', 'restoring'), struct.unpack('<4I', body)))
    def probe(self):
        want = self.send(PROBE)
        kind, seq, body = self.recv()
        assert kind == PROBE and seq == want
        names = ('scope', 'caps', 'queue', 'lease_ms', 'server_pid', 'held', 'restoring', 'reserved', 'frames_received', 'frames_applied', 'frames_superseded', 'journal_writes', 'table_count', 'fixture_count')
        value = dict(zip(names, struct.unpack('<4Ii3I4Q2I', body[:72])))
        value['table'] = []
        offset = 72
        for _ in range(value['table_count']):
            pid, wid, sec, usec, state, a = struct.unpack('<iIQQIf', body[offset:offset + 32])
            numbers = struct.unpack('<10d', body[offset + 32:offset + 112])
            value['table'].append(dict(pid=pid, wid=wid, birth_sec=sec, birth_usec=usec, state=state, alpha=a, transform=list(numbers[:6]), screen_rect=list(numbers[6:])))
            offset += 112
        value['fixtures'] = [IDENTITY.unpack(body[offset + 24 * i:offset + 24 * i + 24]) for i in range(value['fixture_count'])]
        assert offset + 24 * value['fixture_count'] == len(body)
        return value
    def restore_all(self):
        want = self.send(RESTORE_ALL)
        kind, seq, body = self.recv()
        assert kind == RESTORE_ALL and seq == want, (kind, seq, want)
        count, pending, persisted, _ = struct.unpack('<4I', body[:16])
        rows = [struct.unpack('<iIQQIi', body[16 + 32 * i:48 + 32 * i]) for i in range(count)]
        return dict(count=count, pending=pending, journal_persisted=persisted, outcomes=[r[4] for r in rows], set_status=[r[5] for r in rows], wids=[r[1] for r in rows])
    def close(self):
        self.s.close()

def read_json(client, timeout):
    """One line from a v2client, or a failure: never a wait without end."""
    ready, _, _ = select.select([client.stdout], [], [], timeout)
    assert ready, f'v2client printed nothing within {timeout} s'
    return json.loads(client.stdout.readline())

class Stopped:
    """The host stopped for the length of a with block. A stopped host cannot run its
    own watchdog, so a guard process resumes it if this test is killed meanwhile."""
    def __init__(self, host):
        self.host = host
    def __enter__(self):
        self.guard = subprocess.Popen(['/bin/sh', '-c', f'sleep 15; kill -CONT {self.host.child.pid}'], start_new_session=True)
        self.host.child.send_signal(signal.SIGSTOP)
    def __exit__(self, *failure):
        self.host.child.send_signal(signal.SIGCONT)
        try: os.killpg(self.guard.pid, signal.SIGKILL)
        except ProcessLookupError: pass  # it has already done its work
        self.guard.wait()

def record(who, target, original, a=None):
    """Draw the window (native size original[2:]) at the screen rectangle target."""
    w, h = original[2], original[3]
    sx, sy, sw, sh = target
    return RECORD.pack(*who, w / sw, 0.0, 0.0, h / sh, -sx * w / sw, -sy * h / sh, a if a is not None else 0.0, 1 if a is not None else 0)

def half(original, dx, dy=0.0):
    return [original[0] + dx, original[1] + dy, original[2] / 2, original[3] / 2]

def v1(host, op, **fields):
    s = socket.socket(socket.AF_UNIX); s.settimeout(4); s.connect(str(host.run / 'helper.sock'))
    s.sendall(json.dumps(dict(v=1, nonce=host.nonce, op=op, **fields)).encode() + b'\n')
    data = b''
    while not data.endswith(b'\n'):
        part = s.recv(4096)
        if not part: break
        data += part
    return s, json.loads(data)

def setup(host):
    """A control session, the host's eight windows and what they look like untouched."""
    c = Conn(host)
    assert c.status == 0, c.status
    probe = c.probe()
    who = probe['fixtures']
    assert len(who) == 8 and all(w[0] == host.child.pid for w in who), probe
    wids = [w[1] for w in who]
    return c, probe, who, wids, [screen(w) for w in wids]

def frames_group():
    host = Host('--windows', '8')
    c, probe, who, wids, original = setup(host)
    assert c.queue == 0 and c.scope == 1 and c.lease_ms == 2000, vars(c)
    assert probe['table_count'] == 0 and probe['journal_writes'] == 0 and not (host.run / 'v2-journal.json').exists()
    alpha0 = [alpha(w) for w in wids]
    can_alpha = bool(c.caps & 1)

    # Who may speak: wrong nonce, wrong version, a second controller, a heartbeat
    # connection without the session's token.
    refused = dict(wrong_nonce=Conn(host, nonce='0' * 64).status, wrong_version=Conn(host, version=3).status, second_controller=Conn(host).status, heartbeat_wrong_token=Conn(host, role=2, token=b'x' * 16).status)
    assert refused == dict(wrong_nonce=1, wrong_version=2, second_controller=3, heartbeat_wrong_token=4), refused
    results.append(dict(test='hello refusals', status=refused))

    # 1. One frame, eight windows, two of them with alpha.
    target = [half(o, 20 + 5 * i, 10) for i, o in enumerate(original)]
    status = c.frame([record(who[i], target[i], original[i], .5 if can_alpha and i < 2 else None) for i in range(8)])
    assert status == [APPLIED] * 8, status
    seen = [screen(w) for w in wids]
    assert all(near(s, t) for s, t in zip(seen, target)), (seen, target)
    alpha1 = [alpha(w) for w in wids]
    if can_alpha:
        assert all(abs(a - .5) < 1e-6 for a in alpha1[:2]) and alpha1[2:] == alpha0[2:], (alpha0, alpha1)
    journal = host.journal()
    stat1 = (host.run / 'v2-journal.json').stat()
    assert journal['state'] == 'holding' and journal['generation'] == 1 and sorted(w['wid'] for w in journal['windows']) == sorted(wids), journal
    assert all(w['pid'] == host.child.pid and w['state'] == 'held' for w in journal['windows'])
    results.append(dict(test='frame of eight', original=original, target=target, screen_rect=seen, alpha_capability=can_alpha, alpha_before=alpha0, alpha_after=alpha1, journal_generation=journal['generation']))

    # 2. A second frame, with values no 32-bit float holds exactly.
    target = [[o[0] + 10.3 + 7.1 * i, o[1] + 3.7, o[2] / 1.7, o[3] / 1.3] for i, o in enumerate(original)]
    status = c.frame([record(who[i], target[i], original[i]) for i in range(8)])
    assert status == [APPLIED] * 8, status
    seen = [screen(w) for w in wids]
    assert all(near(s, t) for s, t in zip(seen, target)), (seen, target)
    results.append(dict(test='second frame, non-dyadic', target=target, screen_rect=seen))

    # 3. Two bad records among six good: a window that does not exist and a wrong
    # process birth. They fail alone; the session lives. In this scope a number that
    # is not one of the host's windows is refused as out of scope before any lookup,
    # so only the wrong birth reaches the identity check against the window server.
    target = [half(o, 40 + 5 * i) for i, o in enumerate(original)]
    good = [record(who[i], target[i], original[i]) for i in range(8)]
    before = [screen(w) for w in wids]
    missing = (who[6][0], 0x7ffffff0, who[6][2], who[6][3])
    wrong_birth = (who[7][0], who[7][1], who[7][2] - 1, who[7][3])
    status = c.frame(good[:6] + [record(missing, target[6], original[6]), record(wrong_birth, target[7], original[7])])
    assert status[:6] == [APPLIED] * 6 and status[6] == SCOPE and status[7] == IDENTITY_MISMATCH, status
    seen = [screen(w) for w in wids]
    assert all(near(seen[i], target[i]) for i in range(6)) and seen[6:] == before[6:], (seen, target, before)
    assert c.probe()['table_count'] == 8 and c.frame(good) == [APPLIED] * 8 and all_near(wids, target)
    results.append(dict(test='bad records fail alone', status=status, screen_rect=seen, untouched=before[6:]))

    # 4. A frame larger than v1's packet limit: 60 records out of scope, 8 good.
    target = [half(o, 60 + 5 * i) for i, o in enumerate(original)]
    outside = [record((os.getpid(), 100 + i, 0, 0), target[0], original[0]) for i in range(60)]
    records = outside[:30] + [record(who[i], target[i], original[i]) for i in range(8)] + outside[30:]
    size = HEADER.size + 8 + sum(map(len, records))
    assert size > OLD_PACKET_LIMIT
    status = c.frame(records)
    assert status == [SCOPE] * 30 + [APPLIED] * 8 + [SCOPE] * 30, status
    assert all_near(wids, target)
    results.append(dict(test='frame over the old packet limit', bytes=size, records=len(records), applied=status.count(APPLIED), refused=status.count(SCOPE)))

    # 5. A burst written faster than it can be applied. The windows end at the last
    # frame's rectangles (seen from here); that fewer frames were applied than sent
    # is the helper's count, from its replies and from its probe counters. Every
    # frame draws a rectangle no other frame of the burst draws, three points from
    # its neighbours, and the comparison allows nothing: the frame before the last,
    # or any other, would not pass for the last.
    burst = 2000
    before = c.probe()
    packets, last = [], None
    for n in range(burst):
        previous = last
        last = [half(o, 80 + 3 * (n % 97), 5 + 3 * (n // 97)) for o in original]
        packets.append(c.packet(FRAME, struct.pack('<II', 8, 0) + b''.join(record(who[i], last[i], original[i]) for i in range(8))))
    final_seq = c.seq
    writer = threading.Thread(target=lambda: c.s.sendall(b''.join(packets)))
    writer.start()
    replies = []
    while not replies or replies[-1][0] != final_seq:
        kind, seq, body = c.recv()
        assert kind == FRAME and (not replies or seq > replies[-1][0]), (kind, seq)
        disposition, count, superseded = struct.unpack('<3I', body[:12])
        assert disposition == 0 and list(body[24:24 + count]) == [APPLIED] * 8, (seq, disposition, list(body[24:]))
        replies.append((seq, superseded))
    writer.join()
    seen = [screen(w) for w in wids]
    assert all(near(s, t, 0) for s, t in zip(seen, last)), (seen, last)
    assert not any(near(s, t, 0) for s, t in zip(seen, previous)), (seen, previous)
    after = c.probe()
    counted = {k: after[k] - before[k] for k in ('frames_received', 'frames_applied', 'frames_superseded')}
    answered = dict(applied=len(replies), superseded=sum(r[1] for r in replies))
    assert counted == dict(frames_received=burst, frames_applied=answered['applied'], frames_superseded=answered['superseded']), (counted, answered)
    assert answered['applied'] + answered['superseded'] == burst and answered['applied'] < burst, answered
    results.append(dict(test='burst: newest frame wins', frames=burst, final_target=last, screen_rect=seen, helper_replies=answered, helper_counters=counted))

    # 6. The journal was written when the windows were first touched and at no frame
    # since: same file, same generation, one write counted.
    stat2 = (host.run / 'v2-journal.json').stat()
    assert (stat2.st_ino, stat2.st_mtime_ns) == (stat1.st_ino, stat1.st_mtime_ns) and host.journal()['generation'] == 1 and after['journal_writes'] == 1, (stat1, stat2, after)
    frames_so_far = after['frames_applied']
    # ...and once more when a window's alpha is first changed, not at later changes.
    alpha_writes = None
    if can_alpha:
        assert c.frame([record(who[2], last[2], original[2], .7)]) == [APPLIED] and abs(alpha(wids[2]) - .7) < 1e-6
        assert c.frame([record(who[2], last[2], original[2], .6)]) == [APPLIED] and abs(alpha(wids[2]) - .6) < 1e-6
        alpha_writes = c.probe()['journal_writes']
        assert alpha_writes == 2 and host.journal()['generation'] == 2
    results.append(dict(test='journal at first touch only', frames_applied=frames_so_far, journal_writes_after_frames=1, journal_writes_after_first_alpha_of_a_third_window=alpha_writes))

    # v1 cannot take a window while v2 holds any.
    s, probe1 = v1(host, 'probe'); s.close()
    s, refused = v1(host, 'enroll', identity=probe1['identity']); s.close()
    assert not refused['ok'] and refused['error'] == 'protocol v2 holds windows', refused

    # 7. Restore-all: everything back, table empty, journal says so.
    generation = host.journal()['generation']
    restored = c.restore_all()
    assert restored['count'] == 8 and restored['pending'] == 0 and restored['outcomes'] == [0] * 8 and restored['journal_persisted'] == 1, restored
    seen = [screen(w) for w in wids]
    assert seen == original and [alpha(w) for w in wids] == alpha0, (seen, original)
    probe = c.probe()
    journal = host.journal()
    assert probe['table_count'] == 0 and probe['held'] == 0 and journal['state'] == 'empty' and journal['windows'] == [] and journal['generation'] == generation + 1, (probe, journal)
    assert journal['last_restore']['reason'] == 'explicit' and [r['outcome'] for r in journal['last_restore']['results']] == ['restored'] * 8
    results.append(dict(test='restore-all', reply=restored, screen_rect=seen, journal_state=journal['state'], journal_generation=journal['generation']))

    # With v2 holding nothing v1 works as before, and while v1 holds its window v2
    # is refused per record.
    s, enrolled = v1(host, 'enroll', identity=probe1['identity'])
    assert enrolled['ok'], enrolled
    s.sendall(json.dumps(dict(v=1, nonce=host.nonce, op='transform', identity=probe1['identity'], matrix=[2, 0, 0, 2, 0, 0])).encode() + b'\n')
    assert json.loads(s.recv(4096))['ok']
    status = c.frame([record(who[i], target[i], original[i]) for i in range(8)])
    assert status == [BUSY_V1] * 8, status
    s.close()
    wait_rects(wids, original, 2)
    results.append(dict(test='one protocol holds windows at a time', v1_enroll_while_v2_holds=refused, v2_frame_while_v1_holds=status))

    # 8. The session goes on after restore-all; closing the connection without
    # asking restores everything.
    target = [half(o, 30) for o in original]
    deadline = time.monotonic() + 2
    while True:
        status = c.frame([record(who[i], target[i], original[i], .5 if can_alpha and i == 0 else None) for i in range(8)])
        if status == [APPLIED] * 8 or time.monotonic() > deadline: break
        time.sleep(.05)  # v1's own disconnect restore releases its claim a moment later
    assert status == [APPLIED] * 8 and all_near(wids, target), status
    assert host.journal()['state'] == 'holding'
    c.close()
    took = wait_rects(wids, original, 1)
    assert [alpha(w) for w in wids] == alpha0
    journal = host.wait_journal('empty')
    assert journal['last_restore']['reason'] == 'disconnect' and [r['outcome'] for r in journal['last_restore']['results']] == ['restored'] * 8, journal
    results.append(dict(test='connection closed without restore-all', restored_after_s=round(took, 3), journal_reason=journal['last_restore']['reason']))

    # A malformed message ends the session, and that too restores everything.
    c = Conn(host)
    assert c.frame([record(who[i], target[i], original[i]) for i in range(8)]) == [APPLIED] * 8
    c.s.sendall(HEADER.pack(0, 99, 0, c.seq + 1))
    took = wait_rects(wids, original, 1)
    try: assert c.s.recv(64) == b''
    except ConnectionResetError: pass
    c.close()
    results.append(dict(test='protocol error restores', restored_after_s=round(took, 3)))
    host.stop()

def lease_group():
    host = Host('--windows', '8')
    c, _, who, wids, original = setup(host)
    lease = c.lease_ms / 1000

    # 9. Only heartbeats, on the second connection, for three leases: the windows
    # stay. Then nothing at all: they are back within the lease plus a margin.
    target = [half(o, 50, 20) for o in original]
    assert c.frame([record(who[i], target[i], original[i]) for i in range(8)]) == [APPLIED] * 8
    beat = Conn(host, role=2, token=c.token)
    assert beat.status == 0
    start = time.monotonic(); samples = 0; beats = 0
    while time.monotonic() - start < 3 * lease:
        reply = beat.heartbeat(); beats += 1
        assert reply['status'] == 0 and reply['held'] == 8, reply
        time.sleep(.25)
        if beats % 2 == 0:
            assert all_near(wids, target), (time.monotonic() - start, [screen(w) for w in wids])
            samples += 1
    stopped = time.monotonic()
    took = wait_rects(wids, original, lease + 1)
    assert took > lease - .5, took  # the lease, not something sooner, let go of them
    try: assert c.s.recv(64) == b''
    except ConnectionResetError: pass
    journal = host.wait_journal('empty')
    assert journal['last_restore']['reason'] == 'lease expired', journal
    results.append(dict(test='heartbeat connection alone keeps the lease', held_for_s=round(stopped - start, 2), heartbeats=beats, samples_in_place=samples, restored_s_after_last_heartbeat=round(took, 3), lease_s=lease, journal_reason='lease expired'))
    c.close(); beat.close()

    # 10. The client library holding the windows with its heartbeat thread, then
    # killed outright: the windows are back at once, not a lease later.
    lines = ''.join(f'{w[0]} {w[1]} {w[2]} {w[3]} {o[0]} {o[1]} {o[2]} {o[3]}\n' for w, o in zip(who, original)) + 'go\n'
    client = subprocess.Popen([str(BUILD / 'v2client'), 'hold', str(host.run), host.nonce, '70'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    client.stdin.write(lines); client.stdin.flush()
    held = read_json(client, 10)
    target = [half(o, 70) for o in original]
    assert held['held'] and held['records_applied'] == 8 and all_near(wids, target), held
    time.sleep(1.5 * lease)
    assert client.poll() is None and all_near(wids, target)
    client.kill()
    took = wait_rects(wids, original, 1)
    client.wait()
    host.wait_journal('empty')
    results.append(dict(test='client killed with SIGKILL', held_past_lease_s=1.5 * lease, restored_after_s=round(took, 3)))

    # A journal that cannot be written: no window is changed without its record on
    # disk, and a restore that could not be recorded is recorded by a retry.
    c = Conn(host)
    assert c.status == 0, c.status
    obstruction = host.run / 'v2-journal.next'
    obstruction.mkdir(mode=0o700)
    status = c.frame([record(who[i], target[i], original[i]) for i in range(8)])
    assert status == [JOURNAL] * 8 and [screen(w) for w in wids] == original, status
    obstruction.rmdir()
    assert c.frame([record(who[i], target[i], original[i]) for i in range(8)]) == [APPLIED] * 8 and all_near(wids, target)
    obstruction.mkdir(mode=0o700)
    restored = c.restore_all()
    assert restored['outcomes'] == [0] * 8 and restored['journal_persisted'] == 0 and [screen(w) for w in wids] == original, restored
    assert host.journal()['state'] == 'holding'
    obstruction.rmdir()
    host.wait_journal('empty')
    results.append(dict(test='journal obstruction', frame_status_while_obstructed=status, restore_reply_while_obstructed=restored, journal_after_retry=host.journal()['state']))
    c.close()
    host.stop()

def bench_group():
    host = Host('--windows', '8')
    c, _, who, wids, original = setup(host)
    c.close()
    lines = ''.join(f'{w[0]} {w[1]} {w[2]} {w[3]} {o[0]} {o[1]} {o[2]} {o[3]}\n' for w, o in zip(who, original)) + 'go\n'

    # 11. The client library at 120 frames a second, eight records, five seconds.
    client = subprocess.Popen([str(BUILD / 'v2client'), 'bench', str(host.run), host.nonce, '120', '5'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    client.stdin.write(lines); client.stdin.flush()
    bench = read_json(client, 20)
    # No two frames of the run draw the same rectangle; nothing is allowed for.
    assert (bench['last_offset'], bench['last_down']) == (199.0, 2.0), bench
    target = [half(o, bench['last_offset'], bench['last_down']) for o in original]
    seen = [screen(w) for w in wids]
    assert all(near(s, t, 0) for s, t in zip(seen, target)), (seen, target, bench)
    assert not bench['lost'] and bench['submitted'] == 600 and bench['records_failed'] == 0 and bench['last_applied_seq'] == bench['last_seq'], bench
    assert bench['applied'] + bench['superseded'] + bench['discarded'] + bench['dropped_local'] == bench['submitted'], bench
    assert bench['send_call_worst_us'] < 5000 and bench['probe'] == 0 and bench['probe_table'] == 8, bench
    client.stdin.write('restore\n'); client.stdin.flush()
    restored = read_json(client, 10)
    assert restored == dict(restore_all=0, count=8, pending=0, restored=8), restored
    assert [screen(w) for w in wids] == original
    assert client.wait(timeout=5) == 0
    results.append(dict(test='client library, 120 Hz, 8 records, 5 s', bench=bench, final_target=target, screen_rect=seen, restore_all=restored))

    # 12. The helper's process stopped under a running sender: no send call waits
    # (the client's own timing), the loss is reported within the lease (the
    # client's own report), and the helper restores when it runs again.
    client = subprocess.Popen([str(BUILD / 'v2client'), 'bench', str(host.run), host.nonce, '120', '6'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    client.stdin.write(lines); client.stdin.flush()
    time.sleep(1.5)
    moved = [screen(w) for w in wids] != original
    stopped_at = time.time()
    with Stopped(host):
        stall = read_json(client, 10)
        frozen = [screen(w) for w in wids]
    after_loss = stall['lost_at_unix_ms'] / 1000 - stopped_at
    assert moved and stall['lost'] and 0 < after_loss < 2.0 + 1, (stall, after_loss)
    assert stall['send_call_worst_us'] < 5000 and stall['refused_after_loss'] > 0, stall
    took = wait_rects(wids, original, 2)
    client.stdin.close(); client.wait(timeout=5)

    # The same with no frames in flight: only the heartbeat thread can notice, and
    # it reports the helper lost once a whole lease has gone unanswered.
    client = subprocess.Popen([str(BUILD / 'v2client'), 'hold', str(host.run), host.nonce, '45'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    client.stdin.write(lines); client.stdin.flush()
    assert read_json(client, 10)['held'] and all_near(wids, [half(o, 45) for o in original])
    stopped_at = time.time()
    with Stopped(host):
        silent = read_json(client, 10)
    silent_after = silent['lost_at_unix_ms'] / 1000 - stopped_at
    assert silent['lost'] and silent['lost_reason'] == 3 and 2.0 - .6 < silent_after < 2.0 + 1, (silent, silent_after)
    silent_took = wait_rects(wids, original, 2)
    assert client.wait(timeout=5) == 3
    results.append(dict(test='helper stopped under an idle holder', client=silent, loss_reported_s_after_stop=round(silent_after, 3), restored_s_after_resume=round(silent_took, 3)))
    results.append(dict(test='helper stopped under a 120 Hz sender', bench=stall, loss_reported_s_after_stop=round(after_loss, 3), windows_while_stopped=frozen, restored_s_after_resume=round(took, 3)))
    host.stop()

def crash_group():
    # 13. The helper's process killed while holding eight windows; a new one on the
    # same runtime reads the journal, finds none of the recorded windows (they died
    # with the process) and says so. Only this "gone" path can be made cooperatively.
    host = Host('--windows', '8')
    c, _, who, wids, original = setup(host)
    target = [half(o, 25) for o in original]
    assert c.frame([record(who[i], target[i], original[i]) for i in range(8)]) == [APPLIED] * 8
    before = host.journal()
    assert before['state'] == 'holding' and len(before['windows']) == 8
    host.child.kill(); host.child.wait(); host.log.close(); c.close()
    for name in ('helper.sock', 'v2.sock'):
        (host.run / name).unlink()
    # As if it had died while staging a journal write: the leftover must not stop
    # the next instance from writing its own.
    (host.run / 'v2-journal.next').write_text('{"v":2,"state":"hol')
    second = Host('--windows', '8', run=host.run, nonce=host.nonce)
    after = second.journal()
    assert after['state'] == 'empty' and after['windows'] == [] and after['server_pid'] == second.child.pid and after['generation'] == before['generation'] + 1, after
    assert after['last_restore']['reason'] == 'startup recovery' and [r['outcome'] for r in after['last_restore']['results']] == ['gone'] * 8, after
    assert not (host.run / 'v2-journal.next').exists()
    c, probe, who2, wids2, original2 = setup(second)
    assert probe['table_count'] == 0 and not set(wids) & set(wids2)
    assert c.frame([record(who2[0], half(original2[0], 10), original2[0])]) == [APPLIED]
    assert c.restore_all()['outcomes'] == [0] and screen(wids2[0]) == original2[0]
    results.append(dict(test='helper killed holding windows; journal read at next start', journal_before=dict(state=before['state'], windows=len(before['windows'])), journal_after=dict(state=after['state'], last_restore=after['last_restore'])))
    c.close(); second.stop()

def no_v2_group():
    # A helper whose protocol v2 did not start (here: a journal it cannot read)
    # still serves v1, and the client library says which of the two it found.
    run = Path(tempfile.mkdtemp(prefix='v2-', dir=BUILD)).resolve().relative_to(Path.cwd())
    (run / 'v2-journal.json').write_text('not a journal')
    host = Host('--windows', '8', run=run, ready='helper.sock')
    s, probe1 = v1(host, 'probe'); s.close()
    assert probe1['ok'] and not (run / 'v2.sock').exists() and 'protocol v2 not started' in host.text(), (probe1, host.text())
    client = subprocess.run([str(BUILD / 'v2client'), 'hold', str(run), host.nonce, '0'], input='go\n', capture_output=True, text=True, timeout=10)
    assert client.returncode == 1 and client.stderr.strip() == 'open failed: -5', (client.returncode, client.stderr)
    # A usage error is a usage error, whatever flags came before it.
    bad = subprocess.run([str(BUILD / 'host'), str((BUILD / 'payload-arm64.dylib').resolve()), str(run), host.nonce, '--windows', '8', '--v2-queue', 'bogus'], capture_output=True, text=True, timeout=10)
    assert bad.returncode == 2 and bad.stderr.startswith('usage:'), (bad.returncode, bad.stderr)
    results.append(dict(test='v2 not started is told apart from no helper', v1_probe_ok=probe1['ok'], dw_client_open=-5, host_with_invalid_v2_queue_exit=bad.returncode))
    host.stop()

def main_queue_group():
    # 14. The same calls on the main queue, the switch the README describes.
    host = Host('--windows', '8', '--v2-queue', 'main')
    c, _, who, wids, original = setup(host)
    assert c.queue == 1, c.queue
    target = [half(o, 35, 15) for o in original]
    assert c.frame([record(who[i], target[i], original[i]) for i in range(8)]) == [APPLIED] * 8 and all_near(wids, target)
    restored = c.restore_all()
    assert restored['outcomes'] == [0] * 8 and [screen(w) for w in wids] == original, restored
    results.append(dict(test='v2 on the main queue', queue=c.queue, restore_all=restored))
    c.close(); host.stop()

def allowlist_group():
    # Scope: a host allowed only some other process refuses its own windows.
    host = Host('--windows', '8', allow=[dict(pid=os.getpid(), birth_sec=1, birth_usec=0)])
    c, _, who, wids, original = setup(host)
    status = c.frame([record(who[i], half(original[i], 30), original[i]) for i in range(8)])
    assert status == [SCOPE] * 8 and [screen(w) for w in wids] == original, status
    assert c.probe()['table_count'] == 0 and not (host.run / 'v2-journal.json').exists()
    results.append(dict(test='allowlist scope refuses every record', status=status))
    c.close(); host.stop()

def release_window_group():
    """One bounded native lifecycle case; select with --release-window."""
    host = Host('--windows', '8')
    c, _, who, wids, original = setup(host)
    try:
        assert c.caps & 2, 'helper did not negotiate per-window restoration'
        matrices0, alpha0 = [transform(w) for w in wids], [alpha(w) for w in wids]
        target = [half(o, 45 + i * 3, 12) for i, o in enumerate(original)]
        assert c.frame([record(who[i], target[i], original[i], .5 if c.caps & 1 else None) for i in range(8)]) == [APPLIED] * 8
        wait_rects(wids, target, 1)
        placed, alpha1 = [transform(w) for w in wids], [alpha(w) for w in wids]
        release = RECORD.pack(*who[0], *([0.0] * 6), 0.0, 2)
        malformed = RECORD.pack(*who[0], *([0.0] * 6), 0.0, 3)
        outside = RECORD.pack(os.getpid(), wids[0], 0, 0, *([0.0] * 6), 0.0, 2)
        assert c.frame([malformed, outside]) == [11, SCOPE]
        assert [transform(w) for w in wids] == placed and [alpha(w) for w in wids] == alpha1
        assert c.frame([release]) == [APPLIED]
        assert transform(wids[0]) == matrices0[0] and alpha(wids[0]) == alpha0[0]
        assert [transform(w) for w in wids[1:]] == placed[1:] and [alpha(w) for w in wids[1:]] == alpha1[1:]
        journal = host.journal()
        assert len(journal['windows']) == 7 and wids[0] not in [w['wid'] for w in journal['windows']]
        assert c.frame([release]) == [APPLIED]  # idempotent, including its journal
        assert c.frame([record(who[0], target[0], original[0], .7 if c.caps & 1 else None)]) == [APPLIED]
        assert c.frame([record(who[0], target[0], original[0]), release]) == [8, APPLIED]
        assert transform(wids[0]) == matrices0[0] and alpha(wids[0]) == alpha0[0]
        restored = c.restore_all()
        assert restored['count'] == 7 and restored['pending'] == 0
        assert [transform(w) for w in wids] == matrices0 and [alpha(w) for w in wids] == alpha0
        results.append(dict(test='per-window release, scope, conflicting frame, rebind and exact restoration', restored_window=wids[0], other_windows_unchanged=7, original_transform=matrices0[0], original_alpha=alpha0[0]))
    finally:
        c.close(); host.stop()

def enrollment_group():
    """Read-only binary scope audit through the actual C client; no frame sent."""
    host = Host('--windows', '8')
    c, _, who, wids, original = setup(host)
    try:
        matrices0, alpha0 = [transform(w) for w in wids], [alpha(w) for w in wids]
        assert c.caps & 4, 'helper did not negotiate its process scope audit'
        c.close()
        reply = subprocess.run([str(BUILD / 'v2client'), 'enrollment', str(host.run), host.nonce], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6, check=True)
        audit = json.loads(reply.stdout)
        assert audit == dict(scope=1, server_pid=host.child.pid, processes=[dict(pid=who[0][0], birth_sec=who[0][2], birth_usec=who[0][3])]), audit
        assert [screen(w) for w in wids] == original and [transform(w) for w in wids] == matrices0 and [alpha(w) for w in wids] == alpha0
        assert not (host.run / 'v2-journal.json').exists(), 'read-only audit journalled a mutation'
        results.append(dict(test='negotiated process audit through C client, no frame or mutation', audit=audit, independent_windows_unchanged=8))
    finally:
        c.close(); host.stop()

def main():
    # Ended from outside, the test still resumes and ends every host it started.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        if sys.argv[1:] not in ([], ['--release-window'], ['--enrollment']):
            raise SystemExit('usage: fixture_v2_test.py [--release-window | --enrollment]')
        groups = (enrollment_group,) if sys.argv[1:] == ['--enrollment'] else (release_window_group,) if sys.argv[1:] else (frames_group, lease_group, bench_group, crash_group, no_v2_group, main_queue_group, allowlist_group, release_window_group, enrollment_group)
        for group in groups:
            group()
        evidence = dict(status='PASS', tests=results, scope='only the cooperative host\'s own windows; screen rectangles, alpha and journal observed from the test process; no Dock, no foreign window, no other user')
        print(json.dumps(evidence, indent=2))
        print(f'PASS: protocol v2, {len(results)} cases')
    finally:
        # Every window touched belongs to a host started here; ending it removes them.
        for host in hosts:
            host.stop()

if __name__ == '__main__':
    main()
