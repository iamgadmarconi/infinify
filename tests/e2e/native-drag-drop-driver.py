#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive and independently verify the owned primary-native drag/drop fixture.

The only events posted here are a bounded mouse pair over this run's two exact
fixture windows and its own canvas panel. AppKit creates the drag session and
delivers the file URL to the registered destination; this driver never calls a
destination callback or opens the file through another application API.
"""
import ctypes as C
import json
import math
import os
from pathlib import Path
import stat
import socket
import struct
import sys
import time
import subprocess

import png_pixels

ROOT = Path(__file__).resolve().parents[2]
HEADER = struct.Struct('<IHHQ')
IDENTITY = struct.Struct('<iIQQ')
HELLO = 1
PROBE = 5
INSPECT = 7
REPLY = 0x8000
NS_DRAG_OPERATION_COPY = 1
NS_DRAGGING_CONTEXT_OUTSIDE_APPLICATION = 0
ROLES = ('source', 'destination')


class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]


class Size(C.Structure):
    _fields_ = [('width', C.c_double), ('height', C.c_double)]


class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Size)]


class Affine(C.Structure):
    _fields_ = [(name, C.c_double) for name in ('a', 'b', 'c', 'd', 'tx', 'ty')]


sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetScreenRectForWindow.argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]
sky.SLSGetScreenRectForWindow.restype = C.c_int
sky.SLSGetWindowBounds.argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]
sky.SLSGetWindowBounds.restype = C.c_int
sky.SLSGetCatenatedWindowTransform.argtypes = [C.c_int, C.c_uint32, C.POINTER(Affine)]
sky.SLSGetCatenatedWindowTransform.restype = C.c_int
sky.SLSGetWindowOwner.argtypes = [C.c_int, C.c_uint32, C.POINTER(C.c_int)]
sky.SLSGetWindowOwner.restype = C.c_int
sky.SLSConnectionGetPID.argtypes = [C.c_int, C.POINTER(C.c_int)]
sky.SLSConnectionGetPID.restype = C.c_int
# yabai dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:82.
# Event eligibility (not geometric containment); verified in the owned clip probe.
sky.SLSFindWindowAndOwner.argtypes = [C.c_int, C.c_int, C.c_int, C.c_int,
    C.POINTER(Point), C.POINTER(Point), C.POINTER(C.c_uint32), C.POINTER(C.c_int)]
sky.SLSFindWindowAndOwner.restype = C.c_int
# Read-only family ABI of native/app/CompositorMode/DWWindowServerFamily.h;
# yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd, extern.h:9,66-72.
sky.SLSCopyAssociatedWindows.argtypes = [C.c_int, C.c_uint32]
sky.SLSCopyAssociatedWindows.restype = C.c_void_p
sky.SLSWindowQueryWindows.argtypes = [C.c_int, C.c_void_p, C.c_int]
sky.SLSWindowQueryWindows.restype = C.c_void_p
sky.SLSWindowQueryResultCopyWindows.argtypes = [C.c_void_p]
sky.SLSWindowQueryResultCopyWindows.restype = C.c_void_p
for name in ('SLSWindowIteratorGetCount', 'SLSWindowIteratorGetParentID', 'SLSWindowIteratorGetWindowID'):
    getattr(sky, name).argtypes = [C.c_void_p]
    getattr(sky, name).restype = C.c_int if name.endswith('Count') else C.c_uint32
sky.SLSWindowIteratorAdvance.argtypes = [C.c_void_p]
sky.SLSWindowIteratorAdvance.restype = C.c_bool


# SDK sys/proc_info.h, PROC_PIDTBSDINFO. Fixed-width native arm64 layout.
class ProcessInfo(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid',
        'svuid', 'svgid', 'reserved')] + [
        ('comm', C.c_char * 16), ('name', C.c_char * 32)] + [
        (name, C.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')] + [
        ('nice', C.c_int32), ('birth_sec', C.c_uint64), ('birth_usec', C.c_uint64)]


libproc = C.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pidinfo.argtypes = [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int]
libproc.proc_pidinfo.restype = C.c_int


def process_birth(pid):
    info = ProcessInfo()
    check(libproc.proc_pidinfo(pid, 3, 0, C.byref(info), C.sizeof(info)) == C.sizeof(info)
          and info.pid == pid and info.uid == os.getuid(), 'fresh same-user process identity', pid)
    return [info.birth_sec, info.birth_usec]


cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGWindowListCopyWindowInfo.argtypes = [C.c_uint32, C.c_uint32]
cg.CGWindowListCopyWindowInfo.restype = C.c_void_p
cg.CGRectMakeWithDictionaryRepresentation.argtypes = [C.c_void_p, C.POINTER(Rect)]
cg.CGRectMakeWithDictionaryRepresentation.restype = C.c_bool
cg.CGEventCreate.argtypes = [C.c_void_p]
cg.CGEventCreate.restype = C.c_void_p
cg.CGEventGetLocation.argtypes = [C.c_void_p]
cg.CGEventGetLocation.restype = Point
cg.CGEventSourceCreate.argtypes = [C.c_int]
cg.CGEventSourceCreate.restype = C.c_void_p
cg.CGEventCreateMouseEvent.argtypes = [C.c_void_p, C.c_uint32, Point, C.c_uint32]
cg.CGEventCreateMouseEvent.restype = C.c_void_p
cg.CGEventSetIntegerValueField.argtypes = [C.c_void_p, C.c_uint32, C.c_longlong]
cg.CGEventPost.argtypes = [C.c_uint32, C.c_void_p]
cg.CGEventPostToPid.argtypes = [C.c_int, C.c_void_p]
cg.CGWarpMouseCursorPosition.argtypes = [Point]
cg.CGWarpMouseCursorPosition.restype = C.c_int
cg.CGPreflightPostEventAccess.restype = C.c_bool
cg.CGPreflightScreenCaptureAccess.restype = C.c_bool
cf.CFArrayGetCount.argtypes = [C.c_void_p]
cf.CFArrayGetCount.restype = C.c_long
cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]
cf.CFArrayGetValueAtIndex.restype = C.c_void_p
cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]
cf.CFDictionaryGetValue.restype = C.c_void_p
cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]
cf.CFNumberGetValue.restype = C.c_bool
cf.CFNumberCreate.argtypes = [C.c_void_p, C.c_long, C.c_void_p]
cf.CFNumberCreate.restype = C.c_void_p
cf.CFArrayCreate.argtypes = [C.c_void_p, C.POINTER(C.c_void_p), C.c_long, C.c_void_p]
cf.CFArrayCreate.restype = C.c_void_p
cf.CFGetTypeID.argtypes = [C.c_void_p]
cf.CFGetTypeID.restype = C.c_ulong
cf.CFArrayGetTypeID.restype = C.c_ulong
cf.CFNumberGetTypeID.restype = C.c_ulong
cf.CFNumberIsFloatType.argtypes = [C.c_void_p]
cf.CFNumberIsFloatType.restype = C.c_bool
cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
cf.CFStringCreateWithCString.restype = C.c_void_p
cf.CFRelease.argtypes = [C.c_void_p]

K_NUMBER = cf.CFStringCreateWithCString(None, b'kCGWindowNumber', 0x08000100)
K_ALPHA = cf.CFStringCreateWithCString(None, b'kCGWindowAlpha', 0x08000100)
K_PID = cf.CFStringCreateWithCString(None, b'kCGWindowOwnerPID', 0x08000100)
K_LAYER = cf.CFStringCreateWithCString(None, b'kCGWindowLayer', 0x08000100)
K_BOUNDS = cf.CFStringCreateWithCString(None, b'kCGWindowBounds', 0x08000100)
K_AX_TRUSTED = C.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices').AXIsProcessTrusted
K_AX_TRUSTED.restype = C.c_bool


def fail(message, observed=None):
    detail = '' if observed is None else f': {observed!r}'
    raise AssertionError(message + detail)


def check(condition, message, observed=None):
    if not condition:
        fail(message, observed)


def point_json(point):
    return [float(point.x), float(point.y)]


def rect_value(value):
    return [value.origin.x, value.origin.y, value.size.width, value.size.height]


def key_number(row, key, ctype):
    value = ctype()
    check(cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, key), 4 if ctype is C.c_longlong else 13, C.byref(value)), 'window-list numeric field exists')
    return value.value


def window_rows(option=1):
    rows = cg.CGWindowListCopyWindowInfo(option, 0)
    if not rows:
        return []
    result = []
    try:
        for index in range(cf.CFArrayGetCount(rows)):
            row = cf.CFArrayGetValueAtIndex(rows, index)
            bounds = Rect()
            check(cg.CGRectMakeWithDictionaryRepresentation(cf.CFDictionaryGetValue(row, K_BOUNDS), C.byref(bounds)), 'window-list bounds parse')
            result.append({
                'wid': key_number(row, K_NUMBER, C.c_longlong),
                'pid': key_number(row, K_PID, C.c_longlong),
                'layer': key_number(row, K_LAYER, C.c_longlong),
                'alpha': key_number(row, K_ALPHA, C.c_double),
                'screen_rect': rect_value(bounds),
            })
    finally:
        cf.CFRelease(rows)
    return result


def independent_snapshot(wid):
    connection = sky.SLSMainConnectionID()
    transform = Affine()
    bounds = Rect()
    screen = Rect()
    check(sky.SLSGetCatenatedWindowTransform(connection, wid, C.byref(transform)) == 0, f'WindowServer transform read for {wid}')
    check(sky.SLSGetWindowBounds(connection, wid, C.byref(bounds)) == 0, f'WindowServer own bounds read for {wid}')
    check(sky.SLSGetScreenRectForWindow(connection, wid, C.byref(screen)) == 0, f'WindowServer screen rect read for {wid}')
    row = next((row for row in window_rows(0) if row['wid'] == wid), None)
    check(row is not None, f'window {wid} is independently listed')
    owner, pid = C.c_int(), C.c_int()
    check(sky.SLSGetWindowOwner(connection, wid, C.byref(owner)) == 0
          and sky.SLSConnectionGetPID(owner.value, C.byref(pid)) == 0
          and pid.value == row['pid'], 'independent native owner and PID agree', wid)
    return {
        'owner': owner.value, 'identity': [pid.value, wid, *process_birth(pid.value)],
        'transform': [getattr(transform, name) for name, _ in Affine._fields_],
        'bounds': rect_value(bounds),
        'screen_rect': rect_value(screen),
        'alpha': row['alpha'],
    }


class V2ReadOnly:
    """Read-only protocol-v2 PROBE/INSPECT client, closed before Infinify connects."""
    def __init__(self, runtime, nonce):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(3)
        self.sock.connect(str(Path(runtime) / 'v2.sock'))
        self.seq = 0
        body = struct.pack('<4sHH64s16s', b'DWv2', 2, 1, nonce.encode().ljust(64, b'\0'), bytes(16))
        kind, seq, reply = self.request(HELLO, body)
        check((kind, seq, len(reply)) == (HELLO, 1, 48), 'protocol-v2 read-only hello')
        (status, self.lease_ms, self.max_records, self.max_body, self.caps,
         self.scope, self.queue, self.server_pid, self.token) = struct.unpack('<7Ii16s', reply)
        check(status == 0 and self.scope == 1 and self.caps & 16, 'cooperative INSPECT-capable helper hello accepted', status)

    def read_exact(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise EOFError('protocol-v2 helper closed its read-only connection')
            data.extend(chunk)
        return bytes(data)

    def request(self, kind, body=b''):
        self.seq += 1
        self.sock.sendall(HEADER.pack(len(body), kind, 0, self.seq) + body)
        length, reply_type, flags, seq = HEADER.unpack(self.read_exact(HEADER.size))
        check(flags == 0 and reply_type == (kind | REPLY) and seq == self.seq and length <= 131072,
              'protocol-v2 reply type, flags, sequence and size', (length, reply_type, flags, seq, self.seq))
        return kind, seq, self.read_exact(length)

    def probe(self):
        _, _, body = self.request(PROBE)
        check(len(body) >= 72, 'protocol-v2 probe minimum size', len(body))
        names = ('scope', 'caps', 'queue', 'lease_ms', 'server_pid', 'held', 'restoring', 'journal_pending',
                 'frames_received', 'frames_applied', 'frames_superseded', 'journal_writes', 'table_count', 'fixture_count')
        result = dict(zip(names, struct.unpack('<4Ii3I4Q2I', body[:72])))
        offset = 72
        result['table'] = []
        for _ in range(result['table_count']):
            check(offset + 112 <= len(body), 'protocol-v2 probe table is bounded')
            pid, wid, sec, usec, state, alpha = struct.unpack('<iIQQIf', body[offset:offset + 32])
            numbers = struct.unpack('<10d', body[offset + 32:offset + 112])
            result['table'].append({'pid': pid, 'wid': wid, 'birth_sec': sec, 'birth_usec': usec, 'state': state,
                                    'alpha': alpha, 'transform': list(numbers[:6]), 'screen_rect': list(numbers[6:])})
            offset += 112
        check(offset + 24 * result['fixture_count'] == len(body), 'protocol-v2 probe identity count matches frame length')
        result['fixtures'] = [IDENTITY.unpack(body[offset + 24 * n:offset + 24 * (n + 1)]) for n in range(result['fixture_count'])]
        return result

    def inspect(self, identity):
        _, _, body = self.request(INSPECT, IDENTITY.pack(*identity))
        check(len(body) == 144 and IDENTITY.unpack(body[:24]) == identity, 'protocol-v2 inspect returns the exact fresh identity')
        status, owner = struct.unpack('<Ii', body[24:32])
        values = struct.unpack('<14d', body[32:])
        check(all(math.isfinite(value) for value in values), 'INSPECT geometry is finite')
        return {'status': status, 'owner': owner, 'transform': list(values[:6]), 'bounds': list(values[6:10]), 'screen_rect': list(values[10:])}

    def close(self):
        self.sock.close()


def identities(runtime, nonce, host_pid, wid):
    connection = V2ReadOnly(runtime, nonce)
    try:
        probe = connection.probe()
        check(probe['server_pid'] == host_pid and probe['scope'] == 1 and probe['journal_pending'] == 0
              and probe['held'] == 0 and probe['restoring'] == 0 and probe['table_count'] == 0,
              'helper is a cooperative fresh host with no pending restoration', probe)
        fixtures = [tuple(value) for value in probe['fixtures']]
        check(len(fixtures) == 1 and fixtures[0][0] == host_pid and fixtures[0][1] == wid,
              'helper allowlist is exactly this role’s owned window', fixtures)
        observed = {}
        for identity in fixtures:
            inspection = connection.inspect(identity)
            independent = independent_snapshot(identity[1])
            check(inspection['status'] == 0 and inspection['owner'] == independent['owner']
                  and list(identity) == independent['identity'],
                  'INSPECT confirms exact fixture owner and identity', (identity, inspection))
            observed[identity[1]] = {'identity': list(identity), 'inspection': inspection, 'independent': independent}
        return probe, observed
    finally:
        connection.close()


def read_ready(evidence, role, host_pid):
    lines = (Path(evidence) / role / 'host.log').read_text().splitlines()
    ready = [line.split() for line in lines if line.startswith('READY ')]
    check(len(ready) == 1 and len(ready[0]) == 4, 'role host reports exactly one owned window ID', lines)
    _, reported_role, pid, wid = ready[0]
    check(reported_role == role and int(pid) == host_pid and int(wid) > 0,
          'fixture READY role, process and window ID are fresh', ready[0])
    return int(wid)


def preflight(replica=False):
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        print('NOT RUN: this focused native fixture requires Apple Silicon macOS; no fixture was started.')
        return 3
    if not K_AX_TRUSTED():
        print('NOT RUN: existing Accessibility trust is required for the input-preserving event tap; no permission was requested.')
        return 3
    if not cg.CGPreflightPostEventAccess():
        print('NOT RUN: existing event-post access is required for the bounded fixture mouse pair; no permission was requested.')
        return 3
    if replica and not cg.CGPreflightScreenCaptureAccess():
        print('NOT RUN: replica validation needs existing Screen Recording access; no permission was requested.')
        return 3
    return 0


def native_parent(wid):
    value = C.c_longlong(wid)
    number = cf.CFNumberCreate(None, 4, C.byref(value))
    check(bool(number), 'native parent query number allocation')
    elements = (C.c_void_p * 1)(number)
    ids = cf.CFArrayCreate(None, elements, 1, None)
    query = iterator = None
    try:
        check(bool(ids), 'native parent query array allocation')
        query = sky.SLSWindowQueryWindows(sky.SLSMainConnectionID(), ids, 1)
        check(bool(query), 'native parent query exists', wid)
        iterator = sky.SLSWindowQueryResultCopyWindows(query)
        check(bool(iterator) and sky.SLSWindowIteratorGetCount(iterator) == 1
              and sky.SLSWindowIteratorAdvance(iterator), 'native parent iterator has one exact result', wid)
        actual = sky.SLSWindowIteratorGetWindowID(iterator)
        parent = sky.SLSWindowIteratorGetParentID(iterator)
        check(actual == wid and not sky.SLSWindowIteratorAdvance(iterator), 'native parent iterator WID is exact', wid)
        return parent
    finally:
        for item in (iterator, query, ids, number):
            if item:
                cf.CFRelease(item)


def native_family(wid, expected):
    before = independent_snapshot(wid)
    check(before['identity'] == expected['identity'] and before['owner'] == expected['owner'], 'fresh exact family root')
    raw = sky.SLSCopyAssociatedWindows(sky.SLSMainConnectionID(), wid)
    check(bool(raw), 'native associated-window list exists', wid)
    try:
        check(cf.CFGetTypeID(raw) == cf.CFArrayGetTypeID(), 'native association getter returned a real array')
        count = cf.CFArrayGetCount(raw)
        check(0 <= count <= 64, 'native family list is bounded', count)
        ids = [wid]
        for index in range(count):
            field = cf.CFArrayGetValueAtIndex(raw, index)
            check(bool(field) and cf.CFGetTypeID(field) == cf.CFNumberGetTypeID() and not cf.CFNumberIsFloatType(field),
                  'native family WID has exact integer CFNumber type')
            number = C.c_longlong()
            check(cf.CFNumberGetValue(field, 4, C.byref(number)), 'native family WID parses')
            check(0 < number.value <= 0xffffffff and (number.value == wid or number.value not in ids), 'native family IDs are unique', number.value)
            if number.value != wid:
                ids.append(number.value)
    finally:
        cf.CFRelease(raw)
    members = {}
    for member in ids:
        seen = independent_snapshot(member)
        check(seen['identity'][0] == before['identity'][0] and seen['identity'][2:] == before['identity'][2:]
              and seen['owner'] == before['owner'], 'native family has exact same process and owner', seen)
        parent = native_parent(member)
        after_member = independent_snapshot(member)
        check(after_member['identity'] == seen['identity'] and after_member['owner'] == seen['owner']
              and after_member['bounds'] == seen['bounds'], 'member instance/owner/basis remain exact after ancestry read')
        members[str(member)] = {'identity': seen['identity'], 'owner': seen['owner'], 'bounds': seen['bounds'], 'parent': parent}
    check(members[str(wid)]['parent'] == 0, 'audited native root has no parent')
    for member in ids:
        visited, cursor = set(), member
        while cursor != wid:
            check(cursor not in visited and str(cursor) in members, 'native family ancestry is complete and acyclic', members)
            visited.add(cursor)
            cursor = members[str(cursor)]['parent']
    after = independent_snapshot(wid)
    check(after['identity'] == before['identity'] and after['owner'] == before['owner'], 'family root remains exact after discovery')
    return members


def save_json(path, value):
    target = Path(path)
    temp = target.with_suffix(target.suffix + '.new')
    temp.write_text(json.dumps(value, sort_keys=True))
    os.chmod(temp, 0o600)
    os.replace(temp, target)


def baseline(args):
    if preflight(args.replica_destination):
        return 3
    result = {'roles': {}, 'identities': {}, 'original': {}}
    for role in ROLES:
        host = args.hosts[role]
        wid = read_ready(args.evidence, role, host['pid'])
        probe, observed = identities(host['runtime'], host['nonce'], host['pid'], wid)
        inspection, independent = observed[wid]['inspection'], observed[wid]['independent']
        check(inspection['transform'] == independent['transform'] and inspection['bounds'] == independent['bounds']
              and inspection['screen_rect'] == independent['screen_rect'],
              'helper INSPECT matches independent original geometry', (role, wid))
        result['roles'][role] = {
            'host_pid': host['pid'], 'wid': wid,
            'helper_probe': {'scope': probe['scope'], 'server_pid': probe['server_pid'], 'fixtures': probe['fixtures']},
        }
        result[role + '_wid'] = wid
        result['identities'][str(wid)] = observed[wid]['identity']
        result['original'][str(wid)] = independent
        if args.replica_destination:
            family = native_family(wid, independent)
            save_json(Path(args.evidence) / (role + '-family.json'), family)
            check(set(map(int, family)) == {entry[1] for entry in probe['fixtures']},
                  'full audited family equals explicitly enrolled helper WIDs; no root-only fallback', (role, family, probe['fixtures']))
            result['roles'][role]['family'] = family
    source, destination = (result['roles'][role] for role in ROLES)
    check(source['host_pid'] != destination['host_pid'] and source['wid'] != destination['wid']
          and result['original'][str(source['wid'])]['owner'] != result['original'][str(destination['wid'])]['owner'],
          'source and destination are independent AppKit processes and native owners', result)
    save_json(Path(args.evidence) / 'native-before.json', result)
    print('PASS: both independent v2 hosts expose only their exact role window; original native geometry recorded')
    return 0


def ask(sock_path, request):
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(4)
    try:
        client.connect(sock_path)
        client.sendall((json.dumps(request) + '\n').encode())
        data = bytearray()
        while not data.endswith(b'\n'):
            chunk = client.recv(65536)
            if not chunk:
                break
            data.extend(chunk)
        return json.loads(data)
    finally:
        client.close()


def msg(app, socket_path, *args):
    import subprocess
    done = subprocess.run([app, 'msg', '--socket', socket_path, *args], capture_output=True, text=True, timeout=5)
    check(done.returncode == 0, 'Infinify msg command succeeds', (args, done.stderr, done.stdout))
    return done.stdout.strip()


def state(sock_path):
    reply = ask(sock_path, 'State')
    check('Ok' in reply and 'State' in reply['Ok'], 'Infinify State IPC reply', reply)
    return reply['Ok']['State']


def canvas_window(pid):
    rows = [row for row in window_rows(1) if row['pid'] == pid and row['screen_rect'][2:] == [1100, 700]]
    check(len(rows) == 1, 'exactly one test-owned canvas panel is visible', rows)
    return rows[0]


def expected_rect(window, panel, current):
    (px, py), (width, height) = window['position'], window['size']
    cx, cy = current['camera']
    zoom = current['zoom']
    left = px - width // 2
    top = -py - height // 2
    return [panel[0] + panel[2] / 2 + (left - cx) * zoom,
            panel[1] + panel[3] / 2 + (top + cy) * zoom,
            width * zoom, height * zoom]


def split_outputs(scene, panel):
    outputs = {output['name']: output for output in scene['outputs']}
    check(set(outputs) == {'fixture-view-a', 'fixture-view-b'}, 'exact two owned logical view names', outputs)
    width, height = panel[2] / 2, panel[3]
    check(width == 550 and height == 700 and all(output['size'] == [550, 700] for output in outputs.values()),
          'two disjoint full-height logical outputs fit the existing owned canvas', outputs)
    return [(outputs[name], [panel[0] + index * width, panel[1], width, height])
            for index, name in enumerate(('fixture-view-a', 'fixture-view-b'))]


def native_at(seen, wanted):
    mx, my = seen['bounds'][2] / wanted[2], seen['bounds'][3] / wanted[3]
    expected = [mx, 0, 0, my, -wanted[0] * mx, -wanted[1] * my]
    narrowed = [C.c_float(value).value for value in expected]
    if seen['transform'] != narrowed:
        return False
    left, top = -narrowed[4] / narrowed[0], -narrowed[5] / narrowed[3]
    right, bottom = left + seen['bounds'][2] / narrowed[0], top + seen['bounds'][3] / narrowed[3]
    return seen['screen_rect'] == [math.floor(left), math.floor(top), math.ceil(right) - math.floor(left), math.ceil(bottom) - math.floor(top)]


def png_rgb(path):
    """Bounded 8-bit screenshot decoder; reject other formats, never infer pixels."""
    check(Path(path).stat().st_size <= 1024 * 1024, 'bounded actual PNG screenshot')
    width, height, channels, rows = png_pixels.decode(Path(path))
    check(0 < width <= 256 and 0 < height <= 256, 'supported bounded screenshot pixel format', (width, height))
    return width, height, [tuple(row[x:x + 3]) for row in rows for x in range(0, len(row), channels)]


def verify_replica_pixels(evidence, destination_copy, targets, canvas_wid):
    # Below the title/text, inside the destination's displayed green content.
    crop = [math.ceil(destination_copy[0] + destination_copy[2] * .45),
            math.ceil(destination_copy[1] + destination_copy[3] * .65), 32, 20]
    check(contains(destination_copy, crop[:2]) and contains(destination_copy, [crop[0] + crop[2], crop[1] + crop[3]]), 'capture rectangle lies inside replica')
    points = [[crop[0] + x, crop[1] + y] for x, y in ((0, 0), (31, 0), (0, 19), (31, 19), (16, 10))]
    path = evidence / 'destination-replica-before.png'
    for _ in range(8):
        for point in points:
            check(owned_hit(point, targets)['wid'] == canvas_wid, 'independent optical sample sees exact canvas at replica, not native destination')
        done = subprocess.run(['/usr/sbin/screencapture', '-x', '-R' + ','.join(map(str, crop)), str(path)], capture_output=True, timeout=3)
        check(done.returncode == 0, 'bounded owned-canvas screenshot succeeds', done.stderr.decode(errors='replace'))
        width, height, pixels = png_rgb(path)
        green = sum(g > r * 1.3 and g > b * 1.2 and g >= 55 for r, g, b in pixels)
        for point in points:
            check(owned_hit(point, targets)['wid'] == canvas_wid, 'replica optical sample remains exact owned canvas')
        if green >= len(pixels) * .9:
            save_json(evidence / 'replica-optical.json', {'crop': crop, 'width': width, 'height': height, 'green_pixels': green, 'total_pixels': len(pixels), 'canvas_wid': canvas_wid})
            return
        time.sleep(.15)
    fail('independent owned-canvas pixels show the green destination replica before any physical drag', {'green': green, 'pixels': len(pixels)})


def capture_status(sock_path, source, destination):
    # Existing read-only diagnostics supplement the optical prerequisite;
    # neither a stream flag nor an ACK can replace independent canvas pixels.
    return {'captures': {role: ask(sock_path, {'DebugCapture': {'window': window, 'phase': 'status'}})
                         for role, window in (('source', source), ('destination', destination))},
            'native': ask(sock_path, {'DebugNative': {}})}


def wait_for(timeout, condition, label):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        last = condition()
        if last:
            return last
        time.sleep(.04)
    fail(label, last)


def get_pointer():
    event = cg.CGEventCreate(None)
    check(bool(event), 'current pointer location is available')
    try:
        point = cg.CGEventGetLocation(event)
        return [point.x, point.y]
    finally:
        cf.CFRelease(event)


def restore_cursor(evidence):
    path = Path(evidence) / 'cursor.json'
    if not path.exists():
        return
    value = json.loads(path.read_text())
    point = Point(*value['original'])
    # Restore position only; this fixture never owns mouse/cursor association.
    cg.CGWarpMouseCursorPosition(point)


def event_at(source, kind, point):
    event = cg.CGEventCreateMouseEvent(source, kind, Point(float(point[0]), float(point[1])), 0)
    check(bool(event), 'mouse event creation')
    if kind in (1, 2, 3, 4):
        cg.CGEventSetIntegerValueField(event, 1, 1)  # kCGMouseEventClickState
    return event


def post_mouse(source, kind, point):
    event = event_at(source, kind, point)
    try:
        cg.CGEventPost(0, event)  # kCGHIDEventTap: WindowServer hit-tests real native fixture windows.
    finally:
        cf.CFRelease(event)


def contains(rect, point):
    return rect[0] <= point[0] <= rect[0] + rect[2] and rect[1] <= point[1] <= rect[1] + rect[3]


def topmost(point):
    at, local, wid, owner, pid = Point(*point), Point(), C.c_uint32(), C.c_int(), C.c_int()
    if sky.SLSFindWindowAndOwner(sky.SLSMainConnectionID(), 0, 1, 0, C.byref(at),
                                C.byref(local), C.byref(wid), C.byref(owner)) != 0:
        return None
    if not wid.value or sky.SLSConnectionGetPID(owner.value, C.byref(pid)) != 0:
        return None
    return {'wid': wid.value, 'pid': pid.value, 'owner': owner.value,
            'local': [local.x, local.y]}


def owned_hit(point, targets):
    row = topmost(point)
    check(row is not None and row['wid'] in targets, 'input point is confined to this run’s native windows', (point, row))
    expected = targets[row['wid']]
    check(row['pid'] == expected['identity'][0] and row['owner'] == expected['owner'],
          'event-eligible native window has the exact owned PID and connection', (point, row, expected))
    return row


def validate_path(points, source_wid, destination_wid, targets):
    observations = []
    for index, point in enumerate(points):
        row = owned_hit(point, targets)
        if index == 0:
            check(row['wid'] == source_wid, 'drag starts at the exact source window', row)
        if index == len(points) - 1:
            check(row['wid'] == destination_wid, 'drop ends at the exact destination window', row)
        observations.append({'point': point, **row})
    return observations


def receipts_when_complete(evidence):
    try:
        receipts = {role: json.loads((Path(evidence) / role / 'receipt.json').read_text()) for role in ROLES}
    except (OSError, json.JSONDecodeError):
        return None
    return receipts if receipts['source'].get('source_ended') and receipts['destination'].get('destination_concluded') else None


def run(args):
    if preflight(args.replica_destination):
        return 3
    evidence = Path(args.evidence)
    before = json.loads((evidence / 'native-before.json').read_text())
    check(all(before['roles'][role]['host_pid'] == args.hosts[role]['pid'] for role in ROLES),
          'baseline role PIDs match both live fixtures')
    source_wid, destination_wid = before['source_wid'], before['destination_wid']
    app_pid = args.app_pid
    sock_path = args.socket
    old_cursor = get_pointer()
    save_json(evidence / 'cursor.json', {'original': old_cursor})
    event_source = cg.CGEventSourceCreate(1)  # kCGEventSourceStateHIDSystemState
    check(bool(event_source), 'HID-state event source creation')
    pressed = False
    try:
        for role in ROLES:
            try:
                os.kill(args.hosts[role]['pid'], 0)
            except OSError as error:
                fail('both owned fixture processes remain live', (role, str(error)))

        def adopted():
            scene = state(sock_path)
            windows = scene.get('windows', [])
            src = next((window for window in windows if 'Native Drag Source' in window.get('title', '')), None)
            dst = next((window for window in windows if 'Native Drag Destination' in window.get('title', '')), None)
            return (scene, src, dst) if src and dst else None
        current, src, dst = wait_for(12, adopted, 'Infinify adopts both exact named fixture windows')
        check(src['id'] != dst['id'], 'source and destination have separate logical windows', (src, dst))
        if args.replica_destination:
            panel_row = canvas_window(app_pid)
            canvas_original = independent_snapshot(panel_row['wid'])
            for output, viewport in split_outputs(current, panel_row['screen_rect']):
                # IPC targets the real cursor's output. Warp only to an exact,
                # currently event-eligible owned canvas corner; no fake handlers.
                point = [viewport[0] + 20, viewport[1] + 20]
                check(owned_hit(point, {panel_row['wid']: canvas_original})['wid'] == panel_row['wid'], 'output setup point is the owned canvas')
                check(cg.CGWarpMouseCursorPosition(Point(*point)) == 0, 'cursor selects exact owned logical view')
                msg(args.app, sock_path, 'zoom', '0.5')
                wait_for(5, lambda output=output: next(item for item in state(sock_path)['outputs'] if item['name'] == output['name'])['zoom'] == .5, 'per-output zoom flight settles')
                def centered(output=output, point=point):
                    # The final zoom anchor tick may consume the first camera
                    # target even when State already reports the target zoom.
                    # Repeat the explicit target, checking the selected view.
                    check(owned_hit(point, {panel_row['wid']: canvas_original})['wid'] == panel_row['wid'], 'camera setup stays on the exact owned canvas')
                    msg(args.app, sock_path, 'camera', '0', '0')
                    seen = next(item for item in state(sock_path)['outputs'] if item['name'] == output['name'])
                    return seen if seen['zoom'] == .5 and seen['camera'] == [0.0, 0.0] else None
                wait_for(5, centered, 'selected output camera center settles after zoom')
        else:
            msg(args.app, sock_path, 'zoom', '0.5')
            wait_for(5, lambda: state(sock_path)['zoom'] == .5, 'zoom flight settles')
            wait_for(5, lambda: (msg(args.app, sock_path, 'camera', '0', '0'), state(sock_path))[1]['camera'] == [0.0, 0.0], 'camera center settles after zoom')
        msg(args.app, sock_path, 'move', '--id', str(src['id']), '-160', '0')
        msg(args.app, sock_path, 'move', '--id', str(dst['id']), '160', '0')

        prior = None
        repeated = 0
        def settled():
            nonlocal prior, repeated
            scene = state(sock_path)
            pair = next((window['position'] for window in scene['windows'] if window['id'] == src['id']), None)
            other = next((window['position'] for window in scene['windows'] if window['id'] == dst['id']), None)
            target = (tuple(scene['camera']), scene['zoom'], tuple(pair or ()), tuple(other or ()))
            target_reached = (target[0] == (0.0, 0.0) and target[1] == .5
                              and target[2] == (-160.0, 0.0) and target[3] == (160.0, 0.0))
            if args.replica_destination:
                target_reached = target_reached and all(tuple(output['camera']) == (0.0, 0.0) and output['zoom'] == .5 for output in scene['outputs'])
            if target_reached and target == prior:
                repeated += 1
            else:
                repeated = 0
            prior = target
            return scene if target_reached and repeated >= 3 else None
        current = wait_for(10, settled, 'scaled fixture placement settles')
        src = next(window for window in current['windows'] if window['id'] == src['id'])
        dst = next(window for window in current['windows'] if window['id'] == dst['id'])
        # Allow the native frame writer to apply both placements before using the
        # independent WindowServer geometry as the source of event coordinates.
        end = time.monotonic() + 5
        actual = {}
        while time.monotonic() < end:
            actual = {source_wid: independent_snapshot(source_wid), destination_wid: independent_snapshot(destination_wid)}
            scales = [actual[wid]['screen_rect'][2] / actual[wid]['bounds'][2] for wid in (source_wid, destination_wid)]
            if all(.48 <= value <= .52 for value in scales):
                break
            time.sleep(.05)
        check(all(.48 <= actual[wid]['screen_rect'][2] / actual[wid]['bounds'][2] <= .52 for wid in (source_wid, destination_wid)),
              'both native windows are independently shown at half scale', actual)
        panel = canvas_window(app_pid)['screen_rect']
        view_a = split_outputs(current, panel)[0][1] if args.replica_destination else panel
        wanted = {src['id']: expected_rect(src, view_a, current), dst['id']: expected_rect(dst, view_a, current)}
        view_b = split_outputs(current, panel)[1][1] if args.replica_destination else None
        destination_copy = expected_rect(dst, view_b, current) if view_b else None
        for wid, logical in ((source_wid, src), (destination_wid, dst)):
            seen = actual[wid]['screen_rect']
            expected = wanted[logical['id']]
            check(all(abs(a - b) <= 2 for a, b in zip(seen, expected)),
                  'independent native rect agrees with scaled canvas placement', {'wid': wid, 'seen': seen, 'expected': expected})

        native_reply = ask(sock_path, {'DebugNative': {}})
        check('Ok' in native_reply and 'DebugNative' in native_reply['Ok'], 'native helper diagnostic is available', native_reply)
        native_state = native_reply['Ok']['DebugNative']
        records = {record['wid']: record for record in native_state.get('records', [])}
        sessions = native_state.get('sessions', [])
        check(native_state.get('group') is True and not native_state.get('ended') and len(sessions) == 2
              and set(records) == {source_wid, destination_wid},
              'active presenter groups exactly the two independent fixture helpers', native_state)
        for role, logical in (('source', src), ('destination', dst)):
            host, wid = args.hosts[role], before['roles'][role]['wid']
            matching = [session for session in sessions if session.get('server_pid') == host['pid']]
            check(len(matching) == 1 and matching[0].get('scope') == 1 and not matching[0].get('ended')
                  and len(matching[0].get('records', [])) == 1
                  and matching[0]['records'][0]['wid'] == wid and matching[0]['records'][0]['window'] == logical['id'],
                  'each scoped helper presents only its own exact role window', (role, native_state))
        save_json(evidence / 'grouped-native.json', native_state)

        source_rect = actual[source_wid]['screen_rect']
        destination_rect = destination_copy or actual[destination_wid]['screen_rect']
        start = [source_rect[0] + source_rect[2] * .30, source_rect[1] + source_rect[3] * .50]
        drop = [destination_rect[0] + destination_rect[2] * .65, destination_rect[1] + destination_rect[3] * .50]
        path = [[start[0] + (drop[0] - start[0]) * i / 16, start[1] + (drop[1] - start[1]) * i / 16] for i in range(17)]
        if args.replica_destination:
            # Stay below both copies while crossing B; entering the source's
            # replica would request an unintended source ownership transfer.
            corridor = max(source_rect[1] + source_rect[3], destination_rect[1] + destination_rect[3]) + 30
            check(corridor < panel[1] + panel[3] - 10, 'owned canvas has an unclipped drag corridor')
            corners = [start, [start[0], corridor], [drop[0], corridor], drop]
            path = [start]
            for first, last in zip(corners, corners[1:]):
                path.extend([[first[0] + (last[0] - first[0]) * i / 6, first[1] + (last[1] - first[1]) * i / 6] for i in range(1, 7)])
        panel_wid = canvas_window(app_pid)['wid']
        targets = {**actual, panel_wid: independent_snapshot(panel_wid)}
        check(targets[panel_wid]['identity'][0] == app_pid, 'canvas belongs to this run’s exact app process')
        path_guard = validate_path(path, source_wid, panel_wid if args.replica_destination else destination_wid, targets)
        if args.replica_destination:
            check(native_at(actual[source_wid], wanted[src['id']]) and native_at(actual[destination_wid], wanted[dst['id']]), 'both original native sites start exactly on output A')
            check(all(contains(view_b, point) for point in (destination_copy[:2], [destination_copy[0] + destination_copy[2], destination_copy[1] + destination_copy[3]])), 'destination copy is wholly inside B with no unsupported native clip')
            save_json(evidence / 'capture-before-optical.json', capture_status(sock_path, src['id'], dst['id']))
            try:
                verify_replica_pixels(evidence, destination_copy, targets, panel_wid)
            finally:
                save_json(evidence / 'capture-after-optical.json', capture_status(sock_path, src['id'], dst['id']))
        save_json(evidence / 'path-guard.json', {'samples': path_guard, 'source': source_wid, 'destination': destination_wid, 'canvas': panel_wid})

        # Reconfirm both full identities and original geometry immediately before
        # any input. The helper identity is PID + window ID + process birth tuple.
        exact = {tuple(value) for value in before['identities'].values()}
        check(len(exact) == 2 and {value[1] for value in exact} == {source_wid, destination_wid}, 'fresh exact helper identities remain recorded')
        for wid in (source_wid, destination_wid):
            observed = independent_snapshot(wid)
            check(observed['identity'] == before['identities'][str(wid)]
                  and observed['owner'] == before['original'][str(wid)]['owner'], 'fresh identity matches baseline', wid)
            check(observed['transform'] != before['original'][str(wid)]['transform'], 'native helper has transformed this fixture window', wid)
            check(observed['alpha'] == before['original'][str(wid)]['alpha'], 'native test did not alter fixture alpha', wid)

        input_guard = []
        def guarded_post(kind, point, expected_wid=None):
            # Recheck ownership and process births at each posted sample. No
            # input goes to a window that has appeared over the fixture path.
            for wid, target in targets.items():
                current_native = independent_snapshot(wid)
                check(current_native['identity'] == target['identity'] and current_native['owner'] == target['owner'],
                      'exact fixture or canvas instance remains live immediately before input', wid)
                if args.replica_destination and wid in (source_wid, destination_wid):
                    role = 'source' if wid == source_wid else 'destination'
                    check(native_family(wid, current_native) == before['roles'][role]['family'], 'complete authorized native family/basis remains exact before physical packet', role)
                    check(native_at(current_native, wanted[src['id']] if wid == source_wid else wanted[dst['id']])
                          or (wid == destination_wid and native_at(current_native, destination_copy)), 'fresh native geometry is at an exact full-viewport requested site', current_native)
            row = owned_hit(point, targets)
            check(expected_wid is None or row['wid'] == expected_wid,
                  'mouse pair stays on its exact source and destination', (kind, row, expected_wid))
            input_guard.append({'kind': kind, 'point': point, **row})
            save_json(evidence / 'input-guard.json', {'samples': input_guard})
            post_mouse(event_source, kind, point)

        guarded_post(5, start, source_wid)  # kCGEventMouseMoved
        time.sleep(.12)
        guarded_post(1, start, source_wid)  # kCGEventLeftMouseDown
        pressed = True
        time.sleep(.12)
        for point in path[1:]:
            guarded_post(6, point)  # kCGEventLeftMouseDragged
            time.sleep(.025)
        if args.replica_destination:
            initial_destination = actual[destination_wid]
            promoted = None
            for _ in range(20):
                observed = independent_snapshot(destination_wid)
                if native_at(observed, destination_copy) and owned_hit(drop, targets)['wid'] == destination_wid:
                    promoted = observed
                    break
                guarded_post(6, drop)  # Continue the original physical native pair.
                time.sleep(.025)
            check(promoted is not None, 'original AppKit session triggered real destination movement A to B and fresh event eligibility', observed)
            check(independent_snapshot(source_wid)['transform'] == actual[source_wid]['transform'], 'source native placement stayed fixed during destination transfer')
            actual[destination_wid] = promoted
            save_json(evidence / 'destination-transfer.json', {'from': initial_destination, 'to': promoted, 'requested_copy': destination_copy, 'event_hit': owned_hit(drop, targets), 'physical_packets': len(input_guard)})
            drop = [drop[0] + 8, drop[1]]
            check(contains(destination_copy, drop), 'final continuation remains inside admitted destination')
            guarded_post(6, drop, destination_wid)
            time.sleep(.05)
        guarded_post(2, drop, destination_wid)  # kCGEventLeftMouseUp
        pressed = False

        receipts = wait_for(10, lambda: receipts_when_complete(evidence), 'both independent AppKit callback paths complete')
        for role, receipt in receipts.items():
            check(receipt.get('role') == role and receipt.get('host_pid') == args.hosts[role]['pid']
                  and receipt.get('wid') == before['roles'][role]['wid'] and receipt.get('file_nonce') == args.file_nonce,
                  'callback receipt belongs to the exact role process, window and file', (role, receipt))
        source_receipt, destination_receipt = (receipts[role] for role in ROLES)
        check(source_receipt.get('source_session_started') and source_receipt.get('source_mouse_down')
              and source_receipt.get('source_event_window') == source_wid,
              'source began a real AppKit NSDraggingSession in its own window', source_receipt)
        check(NS_DRAGGING_CONTEXT_OUTSIDE_APPLICATION in source_receipt.get('source_dragging_contexts', []),
              'AppKit requested the source operation for an outside-application drag', source_receipt)
        events = destination_receipt.get('destination_events', [])
        check('entered' in events and 'prepare' in events and 'perform' in events and 'conclude' in events,
              'registered NSDraggingDestination received a complete AppKit callback path', events)
        check(destination_receipt.get('destination_file_url_type_seen') and destination_receipt.get('destination_prepared')
              and destination_receipt.get('destination_performed') and destination_receipt.get('destination_concluded'),
              'destination accepted the actual file URL and completed the drop', destination_receipt)
        check(destination_receipt.get('destination_received_path') == str(evidence / 'drop.txt')
              and destination_receipt.get('destination_received_contents') == args.file_nonce,
              'destination read the exact nonce-bearing file from NSDraggingInfo pasteboard', destination_receipt)
        check(source_receipt.get('source_end_operation') == NS_DRAG_OPERATION_COPY
              and destination_receipt.get('destination_source_operation_mask', 0) & NS_DRAG_OPERATION_COPY,
              'independent AppKit source and destination agreed on copy operation', receipts)
        local = destination_receipt['destination_location']
        bounds = destination_receipt['destination_view_bounds']
        check(len(bounds) == 4 and bounds[2] > 0 and bounds[3] > 0, 'destination view has native bounds', bounds)
        expected_local = [actual[destination_wid]['bounds'][2] * .65 + (16 if args.replica_destination else 0), actual[destination_wid]['bounds'][3] * .5]
        check(abs(local[0] - expected_local[0]) <= 8 and abs(local[1] - expected_local[1]) <= 8,
              'destination AppKit local drop point matches the transformed native hit point', {'actual': local, 'expected': expected_local})
        check(all(abs(a - b) < 1e-6 for a, b in zip(independent_snapshot(source_wid)['transform'], actual[source_wid]['transform']))
              and all(abs(a - b) < 1e-6 for a, b in zip(independent_snapshot(destination_wid)['transform'], actual[destination_wid]['transform'])),
              'source transform stayed fixed and destination retained its settled target through release')
        summary = {'result': 'PASS', 'scope': 'two independent exact cooperative AppKit processes, replica destination transferred A to B' if args.replica_destination else 'two independent exact cooperative AppKit processes with primary-native windows',
                          'source_identity': before['identities'][str(source_wid)],
                          'destination_identity': before['identities'][str(destination_wid)],
                          'scaled_screen_rects': {str(wid): actual[wid]['screen_rect'] for wid in actual},
                          'path_guard_samples': len(path_guard), 'destination_location': local,
                          'destination_events': events, 'file_path': destination_receipt['destination_received_path']}
        save_json(evidence / 'result.json', summary)
        print(json.dumps(summary, sort_keys=True))
        return 0
    finally:
        if pressed:
            try:
                current_source = independent_snapshot(source_wid)
                check(current_source['identity'] == before['identities'][str(source_wid)]
                      and current_source['owner'] == before['original'][str(source_wid)]['owner'],
                      'cleanup release still targets the exact owned source instance')
                event = event_at(event_source, 2, get_pointer())
                try:
                    cg.CGEventPostToPid(args.hosts['source']['pid'], event)
                finally:
                    cf.CFRelease(event)
            except Exception as error:  # Cleanup must still warp the cursor back.
                print(f'cleanup release failed: {error}', file=sys.stderr)
        restore_cursor(evidence)
        if event_source:
            cf.CFRelease(event_source)


def verify_restored(args):
    evidence = Path(args.evidence)
    before = json.loads((evidence / 'native-before.json').read_text())
    results, failures = {}, {}
    # Audit both independent endpoints even if the first fails. Both children
    # remain alive until the shell has completed this restoration audit.
    for role in ROLES:
        host = args.hosts[role]
        wid = before['roles'][role]['wid']
        original = before['original'][str(wid)]
        identity = tuple(before['identities'][str(wid)])
        connection = None
        try:
            check(before['roles'][role]['host_pid'] == host['pid'], 'restoration uses the recorded role PID', role)
            end, seen = time.monotonic() + args.timeout, None
            while time.monotonic() < end:
                seen = independent_snapshot(wid)
                if seen == original:
                    break
                time.sleep(.05)
            check(seen == original, 'exact original identity, owner, transform, bounds, alpha and screen rectangle restored', (role, seen, original))
            connection = V2ReadOnly(host['runtime'], host['nonce'])
            probe = connection.probe()
            check(probe['server_pid'] == host['pid'] and probe['scope'] == 1 and probe['journal_pending'] == 0
                  and probe['held'] == 0 and probe['restoring'] == 0 and probe['table_count'] == 0
                  and probe['fixtures'] == [identity], 'role helper has exact scope and no pending native restoration', (role, probe))
            restored = connection.inspect(identity)
            check(restored['status'] == 0 and restored['owner'] == original['owner']
                  and all(restored[key] == original[key] for key in ('bounds', 'transform', 'screen_rect')),
                  'protocol-v2 INSPECT confirms restored exact role identity', (role, restored))
            results[role] = {'independent': seen, 'inspect': restored, 'probe': probe}
        except Exception as error:
            failures[role] = str(error)
        finally:
            if connection:
                connection.close()
    save_json(evidence / 'restoration.json', {'roles': results, 'failures': failures})
    check(not failures, 'both independent fixture restorations must succeed', failures)
    print('PASS: both independent owned processes restored exact native geometry and alpha; both v2 journals are clear')
    return 0


def private_token(path, newline):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        metadata = os.fstat(fd)
        size = 65 if newline else 64
        check(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
              and stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_size == size,
              'nonce file is private and belongs to this user', str(path))
        token = os.read(fd, size + 1)
        check(len(token) == size and (not newline or token[-1:] == b'\n')
              and all(chr(value) in '0123456789abcdef' for value in token[:64]), 'nonce file format', str(path))
        return token[:64].decode()
    finally:
        os.close(fd)


def main():
    if len(sys.argv) < 2:
        print('usage: native-drag-drop-driver.py preflight|baseline|run|verify-restored|restore-cursor ...', file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if mode == 'preflight':
        return preflight('--replica-destination' in sys.argv[2:])
    if mode == 'restore-cursor':
        restore_cursor(sys.argv[2])
        return 0
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('baseline', 'run', 'verify-restored'))
    parser.add_argument('evidence')
    for role in ROLES:
        parser.add_argument('--' + role + '-runtime', required=True)
        parser.add_argument('--' + role + '-nonce-file', required=True)
        parser.add_argument('--' + role + '-pid', required=True, type=int)
    parser.add_argument('--timeout', type=float, default=5)
    parser.add_argument('--app-pid', type=int, default=0)
    parser.add_argument('--app', default='')
    parser.add_argument('--socket', default='')
    parser.add_argument('--replica-destination', action='store_true')
    args = parser.parse_args()
    try:
        args.hosts = {role: {'pid': getattr(args, role + '_pid'), 'runtime': getattr(args, role + '_runtime'),
                             'nonce': private_token(getattr(args, role + '_nonce_file'), True)} for role in ROLES}
        check(args.hosts['source']['pid'] > 1 and args.hosts['destination']['pid'] > 1
              and args.hosts['source']['pid'] != args.hosts['destination']['pid'], 'fixture role PIDs are distinct')
        check(args.hosts['source']['runtime'] != args.hosts['destination']['runtime']
              and args.hosts['source']['nonce'] != args.hosts['destination']['nonce'], 'helper endpoints and private auth tokens are distinct')
        args.file_nonce = private_token(Path(args.evidence) / 'drop.txt', False)
        check(all(host['nonce'] != args.file_nonce for host in args.hosts.values()), 'pasteboard file does not expose helper auth')
        if args.mode == 'baseline': return baseline(args)
        if args.mode == 'run': return run(args)
        return verify_restored(args)
    except Exception as error:
        if args.mode == 'run':
            try:
                save_json(Path(args.evidence) / 'failure-state.json', state(args.socket))
            except Exception:
                pass
        print(f'FAIL: {args.mode}: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
