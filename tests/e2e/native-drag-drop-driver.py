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

ROOT = Path(__file__).resolve().parents[2]
HEADER = struct.Struct('<IHHQ')
IDENTITY = struct.Struct('<iIQQ')
HELLO = 1
PROBE = 5
INSPECT = 7
REPLY = 0x8000
NS_DRAG_OPERATION_COPY = 1


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
sky.SLSGetWindowTransform.argtypes = [C.c_int, C.c_uint32, C.POINTER(Affine)]
sky.SLSGetWindowTransform.restype = C.c_int
sky.SLSGetWindowOwner.argtypes = [C.c_int, C.c_uint32, C.POINTER(C.c_int)]
sky.SLSGetWindowOwner.restype = C.c_int
sky.SLSConnectionGetPID.argtypes = [C.c_int, C.POINTER(C.c_int)]
sky.SLSConnectionGetPID.restype = C.c_int
# yabai dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:82.
# Event eligibility (not geometric containment); verified in the owned clip probe.
sky.SLSFindWindowAndOwner.argtypes = [C.c_int, C.c_int, C.c_int, C.c_int,
    C.POINTER(Point), C.POINTER(Point), C.POINTER(C.c_uint32), C.POINTER(C.c_int)]
sky.SLSFindWindowAndOwner.restype = C.c_int


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
cg.CGAssociateMouseAndMouseCursorPosition.argtypes = [C.c_bool]
cg.CGPreflightPostEventAccess.restype = C.c_bool
cf.CFArrayGetCount.argtypes = [C.c_void_p]
cf.CFArrayGetCount.restype = C.c_long
cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]
cf.CFArrayGetValueAtIndex.restype = C.c_void_p
cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]
cf.CFDictionaryGetValue.restype = C.c_void_p
cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]
cf.CFNumberGetValue.restype = C.c_bool
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
    check(sky.SLSGetWindowTransform(connection, wid, C.byref(transform)) == 0, f'WindowServer transform read for {wid}')
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


def identities(runtime, nonce, host_pid, wids):
    connection = V2ReadOnly(runtime, nonce)
    try:
        probe = connection.probe()
        check(probe['server_pid'] == host_pid and probe['scope'] == 1 and probe['journal_pending'] == 0
              and probe['held'] == 0 and probe['restoring'] == 0 and probe['table_count'] == 0,
              'helper is a cooperative fresh host with no pending restoration', probe)
        fixtures = [tuple(value) for value in probe['fixtures']]
        check(len(fixtures) == 2 and {value[1] for value in fixtures} == set(wids)
              and all(value[0] == host_pid for value in fixtures), 'helper allowlist is exactly the two owned windows', fixtures)
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


def read_ready(evidence, host_pid):
    lines = (Path(evidence) / 'host.log').read_text().splitlines()
    ready = [line.split() for line in lines if line.startswith('READY ')]
    check(len(ready) == 1 and len(ready[0]) == 4, 'fixture host reports exactly two owned window IDs', lines)
    _, pid, source, destination = ready[0]
    check(int(pid) == host_pid and int(source) != int(destination), 'fixture READY process and window IDs are fresh', ready[0])
    return int(source), int(destination)


def preflight():
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        print('NOT RUN: this focused native fixture requires Apple Silicon macOS; no fixture was started.')
        return 3
    if not K_AX_TRUSTED():
        print('NOT RUN: existing Accessibility trust is required for the input-preserving event tap; no permission was requested.')
        return 3
    if not cg.CGPreflightPostEventAccess():
        print('NOT RUN: existing event-post access is required for the bounded fixture mouse pair; no permission was requested.')
        return 3
    return 0


def save_json(path, value):
    target = Path(path)
    temp = target.with_suffix(target.suffix + '.new')
    temp.write_text(json.dumps(value, sort_keys=True))
    os.chmod(temp, 0o600)
    os.replace(temp, target)


def baseline(args):
    if preflight():
        return 3
    source_wid, destination_wid = read_ready(args.evidence, args.host_pid)
    probe, observed = identities(args.runtime, args.nonce, args.host_pid, [source_wid, destination_wid])
    result = {
        'host_pid': args.host_pid,
        'source_wid': source_wid,
        'destination_wid': destination_wid,
        'identities': {str(wid): observed[wid]['identity'] for wid in observed},
        'original': {str(wid): observed[wid]['independent'] for wid in observed},
        'helper_probe': {'scope': probe['scope'], 'server_pid': probe['server_pid'], 'fixtures': probe['fixtures']},
    }
    for wid in (source_wid, destination_wid):
        inspect = observed[wid]['inspection']
        independent = observed[wid]['independent']
        check(inspect['transform'] == independent['transform'] and inspect['bounds'] == independent['bounds']
              and inspect['screen_rect'] == independent['screen_rect'], 'helper INSPECT matches independent original geometry', wid)
    save_json(Path(args.evidence) / 'native-before.json', result)
    print(f"PASS: exact v2 identities and independent original transform/alpha recorded for {source_wid}, {destination_wid}")
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
    cg.CGWarpMouseCursorPosition(point)
    cg.CGAssociateMouseAndMouseCursorPosition(True)


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


def validate_path(points, source_wid, destination_wid, host_pid, app_pid, panel_wid):
    allowed = {source_wid, destination_wid, panel_wid}
    observations = []
    for index, point in enumerate(points):
        row = topmost(point)
        check(row is not None, 'every planned drag sample has a topmost on-screen window', point)
        check(row['wid'] in allowed and row['pid'] in {host_pid, app_pid},
              'drag path is confined to the two fixture windows and this run’s canvas', (point, row))
        if index == 0:
            check(row['wid'] == source_wid, 'drag starts at the exact source window', row)
        if index == len(points) - 1:
            check(row['wid'] == destination_wid, 'drop ends at the exact destination window', row)
        observations.append({'point': point, 'wid': row['wid'], 'pid': row['pid']})
    return observations


def receipt_when_complete(path):
    try:
        receipt = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return receipt if receipt.get('source_ended') and receipt.get('destination_concluded') else None


def run(args):
    if preflight():
        return 3
    evidence = Path(args.evidence)
    before = json.loads((evidence / 'native-before.json').read_text())
    check(before['host_pid'] == args.host_pid, 'baseline host PID matches live fixture')
    source_wid, destination_wid = before['source_wid'], before['destination_wid']
    app_pid = args.app_pid
    sock_path = args.socket
    old_cursor = get_pointer()
    save_json(evidence / 'cursor.json', {'original': old_cursor})
    event_source = cg.CGEventSourceCreate(1)  # kCGEventSourceStateHIDSystemState
    check(bool(event_source), 'HID-state event source creation')
    pressed = False
    try:
        try:
            os.kill(args.host_pid, 0)
        except OSError as error:
            fail('owned fixture process remains live', str(error))

        def adopted():
            scene = state(sock_path)
            windows = scene.get('windows', [])
            src = next((window for window in windows if 'Native Drag Source' in window.get('title', '')), None)
            dst = next((window for window in windows if 'Native Drag Destination' in window.get('title', '')), None)
            return (scene, src, dst) if src and dst else None
        current, src, dst = wait_for(12, adopted, 'Infinify adopts both exact named fixture windows')
        check(src['id'] != dst['id'], 'source and destination have separate logical windows', (src, dst))
        msg(args.app, sock_path, 'zoom', '0.5')
        wait_for(5, lambda: state(sock_path)['zoom'] == .5, 'zoom flight settles')
        msg(args.app, sock_path, 'camera', '0', '0')
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
        wanted = {src['id']: expected_rect(src, panel, current), dst['id']: expected_rect(dst, panel, current)}
        for wid, logical in ((source_wid, src), (destination_wid, dst)):
            seen = actual[wid]['screen_rect']
            expected = wanted[logical['id']]
            check(all(abs(a - b) <= 2 for a, b in zip(seen, expected)),
                  'independent native rect agrees with scaled canvas placement', {'wid': wid, 'seen': seen, 'expected': expected})

        native_reply = ask(sock_path, {'DebugNative': {}})
        check('Ok' in native_reply and 'DebugNative' in native_reply['Ok'], 'native helper diagnostic is available', native_reply)
        native_state = native_reply['Ok']['DebugNative']
        records = {record['wid']: record for record in native_state.get('records', [])}
        check(native_state.get('scope') == 1 and native_state.get('server_pid') == args.host_pid
              and set(records) == {source_wid, destination_wid}
              and records[source_wid]['window'] == src['id'] and records[destination_wid]['window'] == dst['id'],
              'active helper frame names only the two exact fresh fixture windows', native_state)

        source_rect = actual[source_wid]['screen_rect']
        destination_rect = actual[destination_wid]['screen_rect']
        start = [source_rect[0] + source_rect[2] * .30, source_rect[1] + source_rect[3] * .50]
        drop = [destination_rect[0] + destination_rect[2] * .65, destination_rect[1] + destination_rect[3] * .50]
        path = [[start[0] + (drop[0] - start[0]) * i / 16, start[1] + (drop[1] - start[1]) * i / 16] for i in range(17)]
        panel_wid = canvas_window(app_pid)['wid']
        path_guard = validate_path(path, source_wid, destination_wid, args.host_pid, app_pid, panel_wid)
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

        def guarded_post(kind, point):
            # Recheck ownership and process births at each posted sample. No
            # input goes to a window that has appeared over the fixture path.
            for wid in (source_wid, destination_wid):
                current_native = independent_snapshot(wid)
                check(current_native['identity'] == before['identities'][str(wid)]
                      and current_native['owner'] == before['original'][str(wid)]['owner'],
                      'exact fixture instance remains live immediately before input', wid)
            row = topmost(point)
            check(row is not None and row['wid'] in {source_wid, destination_wid, panel_wid}
                  and row['pid'] in {args.host_pid, app_pid}, 'current input point remains test-owned', row)
            post_mouse(event_source, kind, point)

        guarded_post(5, start)  # kCGEventMouseMoved
        time.sleep(.12)
        guarded_post(1, start)  # kCGEventLeftMouseDown
        pressed = True
        time.sleep(.12)
        for point in path[1:]:
            guarded_post(6, point)  # kCGEventLeftMouseDragged
            time.sleep(.025)
        guarded_post(2, drop)  # kCGEventLeftMouseUp
        pressed = False

        receipt_path = evidence / 'receipt.json'
        receipt = wait_for(10, lambda: receipt_when_complete(receipt_path), 'AppKit source and destination callbacks complete')
        check(receipt.get('source_session_started') and receipt.get('source_mouse_down'), 'source began a real AppKit NSDraggingSession', receipt)
        events = receipt.get('destination_events', [])
        check('entered' in events and 'prepare' in events and 'perform' in events and 'conclude' in events,
              'registered NSDraggingDestination received a complete AppKit callback path', events)
        check(receipt.get('destination_file_url_type_seen') and receipt.get('destination_prepared')
              and receipt.get('destination_performed') and receipt.get('destination_concluded'),
              'destination accepted the actual file URL and completed the drop', receipt)
        check(receipt.get('destination_received_path') == str(evidence / 'drop.txt')
              and receipt.get('destination_received_contents') == args.nonce,
              'destination read the exact nonce-bearing file from NSDraggingInfo pasteboard', receipt)
        check(receipt.get('source_end_operation') == NS_DRAG_OPERATION_COPY
              and receipt.get('destination_source_operation_mask', 0) & NS_DRAG_OPERATION_COPY,
              'AppKit source and destination agreed on copy operation', receipt)
        local = receipt['destination_location']
        bounds = receipt['destination_view_bounds']
        expected_local = [actual[destination_wid]['bounds'][2] * .65, actual[destination_wid]['bounds'][3] * .5]
        check(abs(local[0] - expected_local[0]) <= 8 and abs(local[1] - expected_local[1]) <= 8,
              'destination AppKit local drop point matches the transformed native hit point', {'actual': local, 'expected': expected_local})
        check(all(abs(a - b) < 1e-6 for a, b in zip(independent_snapshot(source_wid)['transform'], actual[source_wid]['transform']))
              and all(abs(a - b) < 1e-6 for a, b in zip(independent_snapshot(destination_wid)['transform'], actual[destination_wid]['transform'])),
              'native transforms stayed fixed for the whole drag session')
        print(json.dumps({'result': 'PASS', 'scope': 'two exact cooperative primary-native fixture windows',
                          'source_identity': before['identities'][str(source_wid)],
                          'destination_identity': before['identities'][str(destination_wid)],
                          'scaled_screen_rects': {str(wid): actual[wid]['screen_rect'] for wid in actual},
                          'path_guard_samples': len(path_guard), 'destination_location': local,
                          'destination_events': events, 'file_path': receipt['destination_received_path']}, sort_keys=True))
        return 0
    finally:
        if pressed:
            try:
                check(process_birth(args.host_pid) == before['identities'][str(source_wid)][2:],
                      'cleanup release still targets the exact owned process')
                event = event_at(event_source, 2, get_pointer())
                try:
                    cg.CGEventPostToPid(args.host_pid, event)
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
    source_wid, destination_wid = before['source_wid'], before['destination_wid']
    end = time.monotonic() + args.timeout
    seen = None
    while time.monotonic() < end:
        try:
            seen = {str(wid): independent_snapshot(wid) for wid in (source_wid, destination_wid)}
            if all(seen[str(wid)]['transform'] == before['original'][str(wid)]['transform']
                   and seen[str(wid)]['alpha'] == before['original'][str(wid)]['alpha']
                   and seen[str(wid)]['screen_rect'] == before['original'][str(wid)]['screen_rect']
                   for wid in (source_wid, destination_wid)):
                break
        except AssertionError:
            seen = None
        time.sleep(.05)
    check(seen is not None and all(seen[str(wid)]['transform'] == before['original'][str(wid)]['transform']
                                  and seen[str(wid)]['alpha'] == before['original'][str(wid)]['alpha']
                                  and seen[str(wid)]['screen_rect'] == before['original'][str(wid)]['screen_rect']
                                  for wid in (source_wid, destination_wid)),
          'exact original transform, alpha and screen rectangle restored independently', seen)
    connection = V2ReadOnly(args.runtime, args.nonce)
    try:
        probe = connection.probe()
        check(probe['server_pid'] == args.host_pid and probe['journal_pending'] == 0
              and probe['held'] == 0 and probe['restoring'] == 0 and probe['table_count'] == 0,
              'helper journal has no pending native restoration', probe)
        for identity in before['identities'].values():
            identity = tuple(identity)
            restored = connection.inspect(identity)
            check(restored['status'] == 0 and restored['owner'] == before['original'][str(identity[1])]['owner']
                  and seen[str(identity[1])]['identity'] == list(identity)
                  and restored['bounds'] == before['original'][str(identity[1])]['bounds']
                  and restored['transform'] == before['original'][str(identity[1])]['transform']
                  and restored['screen_rect'] == before['original'][str(identity[1])]['screen_rect'],
                  'protocol-v2 INSPECT confirms restored exact fixture identity', (identity, restored))
    finally:
        connection.close()
    print('PASS: both owned windows independently restored transform, alpha and screen rectangle; v2 journal is clear')
    return 0


def main():
    if len(sys.argv) < 2:
        print('usage: native-drag-drop-driver.py preflight|baseline|run|verify-restored|restore-cursor ...', file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if mode == 'preflight':
        return preflight()
    if mode == 'restore-cursor':
        restore_cursor(sys.argv[2])
        return 0
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('baseline', 'run', 'verify-restored'))
    parser.add_argument('evidence')
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--nonce-file', required=True)
    parser.add_argument('--host-pid', required=True, type=int)
    parser.add_argument('--timeout', type=float, default=5)
    parser.add_argument('--app-pid', type=int, default=0)
    parser.add_argument('--app', default='')
    parser.add_argument('--socket', default='')
    args = parser.parse_args()
    try:
        fd = os.open(args.nonce_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            metadata = os.fstat(fd)
            check(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
                  and stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_size == 65,
                  'nonce file is private and belongs to this user')
            token = os.read(fd, 66)
            check(len(token) == 65 and token[-1:] == b'\n'
                  and all(chr(value) in '0123456789abcdef' for value in token[:-1]), 'nonce file format')
            args.nonce = token[:-1].decode()
        finally:
            os.close(fd)
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
