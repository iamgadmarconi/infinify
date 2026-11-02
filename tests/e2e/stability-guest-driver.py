#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Guest-side driver of the stability live scripts (native-frame-cap.sh, native-snapshot-race.sh,
capture-stale-frame.sh, zero-screen-keys.sh). It runs INSIDE the disposable guest, started over the scripts' $GUEST_SSH
prefix, and never on the machine that runs those scripts. Every process it acts on is one it started itself in WORK (the
fixtures and Infinify, with --state/--socket/--config in WORK); all of them are killed on every exit. It changes no setting
and touches no other window: scoped runs are --windowed --only-pid; the zero-screen run is --manual, which leaves the
window settings alone and adopts nothing. Evidence goes to WORK/evidence.

  stability-guest-driver.py MODE WORK INFINIFY

MODE: frame-cap | frame-cap-oversized | snapshot-race | stale-frame | zero-screen
Exit status: 0 every check held; 1 a check failed; 3 nothing failed but the run did not reach what it measures.
"""
import atexit
import ctypes as C
import json
import math
import os
import pathlib
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

MODE, WORK, INF = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
EVIDENCE = WORK / 'evidence'
EVIDENCE.mkdir(exist_ok=True)
SOCK = str(WORK / 's')
ERRLOG = EVIDENCE / 'infinify.err.log'
children = []
reached = []


def now():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def ok(what, seen=''):
    print(f'ok: {what}: {seen}', flush=True)


def fail(what, seen=''):
    print(f'FAIL: {what}: {seen}', flush=True)
    sys.exit(1)


def check(what, passed, seen=''):
    (ok if passed else fail)(what, seen)


def until(what, seconds, read, passed, interval=.05):
    end = time.monotonic() + seconds
    while True:
        value = read()
        if passed(value):
            return value
        if time.monotonic() > end:
            fail(what, value)
        time.sleep(interval)


def cleanup():
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
    deadline = time.monotonic() + 5
    for child in children:
        try:
            child.wait(max(.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


atexit.register(cleanup)
for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(number, lambda n, _f: sys.exit(128 + n))


def start(args, env=None, stdout=None, stderr=None):
    child = subprocess.Popen(args, env={**os.environ, **(env or {})}, stdout=stdout or subprocess.DEVNULL,
                             stderr=stderr or subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    children.append(child)
    return child


def ask(request, timeout=5):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(timeout)
        s.connect(SOCK)
        s.sendall((json.dumps(request) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def msg(*args):
    done = subprocess.run([INF, 'msg', '--socket', SOCK, *args], capture_output=True, text=True, timeout=20)
    if done.returncode:
        fail('msg ' + ' '.join(args), done.stderr.strip() or done.stdout.strip())
    return done.stdout.strip()


def state():
    return ask('State')['Ok']['State']


def native():
    return ask({'DebugNative': {}})['Ok']['DebugNative']


def keys():
    try:
        return ask({'DebugInput': {}})['Ok']['DebugInput']['keys']
    except (OSError, KeyError, ValueError) as error:
        return {'unavailable': str(error)}


def brief(k):
    """DebugInput's key state with the long action list replaced by its length."""
    actions = k.get('actions', [])
    return {**{key: value for key, value in k.items() if key != 'actions'}, 'actions': len(actions)}


def trace():
    return ERRLOG.read_text(errors='replace').splitlines() if ERRLOG.exists() else []


def launch(args, env):
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    (WORK / 'config.toml').touch()
    err = open(ERRLOG, 'a')
    child = start([INF, '--state', str(WORK / 'state.json'), '--config', str(WORK / 'config.toml'), '--socket', SOCK, *args],
                  env={'INFINIFY_DEBUG': '1', **env}, stderr=err)
    until('Infinify opens its IPC socket', 15, lambda: os.path.exists(SOCK) or child.poll() is not None, bool)
    if child.poll() is not None:
        fail('Infinify keeps running after launch', f'exit {child.returncode}: {trace()[-5:]}')
    return child


def quit_infinify(child, what):
    try:
        msg('action', 'quit')
    except SystemExit:
        pass
    try:
        code = child.wait(8)
    except subprocess.TimeoutExpired:
        child.kill()
        fail(what, 'still running 8 s after msg action quit')
    check(what, code == 0, f'exit {code}')


def bundle(executable, name, identifier):
    """A fixture with its own application identity (ScreenCaptureKit lists such windows), made in WORK."""
    app = WORK / f'{name}.app'
    (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    shutil.copy2(WORK / executable, app / 'Contents/MacOS' / name)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleName': name,
                                                              'CFBundleExecutable': name, 'CFBundlePackageType': 'APPL'}))
    return str(app / 'Contents/MacOS' / name)


def ready(log, seconds=10):
    line = until(f'{log.name} reports READY', seconds, lambda: next((l for l in log.read_text().splitlines() if l.startswith('READY ')), None)
                 if log.exists() else None, bool)
    return [int(x) for x in line.split()[1:]]


# The window server, asked from this process (as tests/e2e/scoped-native.sh asks it).
class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]


class Size(C.Structure):
    _fields_ = [('width', C.c_double), ('height', C.c_double)]


class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Size)]


sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
for _name in ('SLSGetScreenRectForWindow', 'SLSGetWindowBounds'):
    getattr(sky, _name).argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]
    getattr(sky, _name).restype = C.c_int


def _rect(function, wid):
    r = Rect()
    if function(sky.SLSMainConnectionID(), wid, C.byref(r)):
        return None
    return [r.origin.x, r.origin.y, r.size.width, r.size.height]


def screen(wid):
    """Where the window server draws the window, its transform applied."""
    return _rect(sky.SLSGetScreenRectForWindow, wid)


def own(wid):
    """The window's own frame, whatever transform is on it."""
    return _rect(sky.SLSGetWindowBounds, wid)


def halved(wid):
    s, o = screen(wid), own(wid)
    return bool(s and o) and abs(s[2] * 2 - o[2]) <= 2 and abs(s[3] * 2 - o[3]) <= 2


def untransformed(wid):
    s, o = screen(wid), own(wid)
    return bool(s and o) and all(abs(a - b) <= 1 for a, b in zip(s, o))


def cg_windows(pid):
    """On-screen windows of one process: (number, bounds) from the window list, read by a child python with Quartz-free ctypes."""
    out = subprocess.run(['/usr/bin/python3', '-c', CG_LIST, str(pid)], capture_output=True, text=True, timeout=10).stdout
    return json.loads(out or '[]')


CG_LIST = r'''
import ctypes as C, json, sys
class R(C.Structure): _fields_ = [('x', C.c_double), ('y', C.c_double), ('w', C.c_double), ('h', C.c_double)]
cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics'); cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGWindowListCopyWindowInfo.argtypes = [C.c_uint32, C.c_uint32]; cg.CGWindowListCopyWindowInfo.restype = C.c_void_p
cg.CGRectMakeWithDictionaryRepresentation.argtypes = [C.c_void_p, C.POINTER(R)]
cf.CFArrayGetCount.argtypes = [C.c_void_p]; cf.CFArrayGetCount.restype = C.c_long
cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]; cf.CFArrayGetValueAtIndex.restype = C.c_void_p
cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]; cf.CFDictionaryGetValue.restype = C.c_void_p
cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]
cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]; cf.CFStringCreateWithCString.restype = C.c_void_p
key = lambda n: cf.CFStringCreateWithCString(None, n, 0x08000100)
K_N, K_P, K_B = key(b'kCGWindowNumber'), key(b'kCGWindowOwnerPID'), key(b'kCGWindowBounds')
rows = cg.CGWindowListCopyWindowInfo(1, 0); out = []
for i in range(cf.CFArrayGetCount(rows)):
    row = cf.CFArrayGetValueAtIndex(rows, i); n = C.c_longlong(); p = C.c_longlong(); r = R()
    cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_N), 4, C.byref(n)); cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_P), 4, C.byref(p))
    cg.CGRectMakeWithDictionaryRepresentation(cf.CFDictionaryGetValue(row, K_B), C.byref(r))
    if p.value == int(sys.argv[1]): out.append([n.value, [r.x, r.y, r.w, r.h]])
print(json.dumps(out))
'''


def cooperative_host(windows, extra=()):
    """The cooperative host of native/dock-helper (tests/native/dock-helper/Payload/HostFixture.m) with its helper."""
    runtime = WORK / 'h'
    runtime.mkdir(mode=0o700, exist_ok=True)
    nonce = os.urandom(32).hex()
    path = WORK / 'nonce'
    path.write_text(nonce + '\n')
    path.chmod(0o600)
    log = EVIDENCE / 'host.log'
    executable = bundle('host', 'CooperativeHost', 'org.infinify.cooperative-host')
    child = start([executable, str(WORK / 'payload-arm64.dylib'), str(runtime), nonce, '--windows', str(windows),
                   '--activation', 'regular', '--watchdog', '600', *extra], stdout=open(log, 'w'), stderr=subprocess.STDOUT)
    numbers = ready(log)
    check('the cooperative host started with its helper', numbers[0] == child.pid and (runtime / 'v2.sock').exists(), numbers)
    return child, numbers[1:], ['--native-helper', str(runtime), str(path)]


def scoped_native(host, helper, env):
    return launch(['--windowed', '1100x700', '--no-hover-forwarding', '--debug-pointer', '--only-pid', str(host.pid), *helper],
                  {'INFINIFY_DEBUG_TEST_PANEL': '1', 'INFINIFY_DEBUG_NATIVE_PANEL': '1', **env})


def settle(seconds=6):
    end = time.monotonic() + seconds
    last = None
    while time.monotonic() < end:
        s = state()
        view = (s['camera'], s['zoom'], [(w['id'], w['position'], w['size']) for w in s['windows']])
        if view == last:
            return s
        last = view
        time.sleep(.15)
    fail('the canvas comes to rest', last)


def arrange(ids):
    """Zoom 0.5 and the windows side by side around the camera, all in view."""
    msg('zoom', '0.5')
    s = settle()
    cx, cy = s['camera']
    for n, logical in enumerate(ids):
        msg('move', '--id', str(logical), str(int(cx + (n - (len(ids) - 1) / 2) * 360)), str(int(cy)))
    return settle()


def ids_by_wid(records):
    return {r['wid']: r['window'] for r in records}


def submitted_over(seconds):
    a = native()['stats']['submitted']
    time.sleep(seconds)
    return native()['stats']['submitted'] - a


def pan(seconds):
    s = state()
    cx, cy = s['camera']
    began = time.monotonic()
    while time.monotonic() - began < seconds:
        t = time.monotonic() - began
        reply = ask({'Camera': [cx + 90 * math.sin(t * 3), cy + 60 * math.sin(t * 2)]})
        if 'Ok' not in reply:
            fail('a camera request during the pan', reply)
    ask({'Camera': [cx, cy]})


def ended_lines():
    return [l for l in trace() if l.startswith('Infinify: native presentation ended')]


# ---------------------------------------------------------------------------------------------------------------------
def frame_cap():
    limit = 3
    host, wids, helper = cooperative_host(4)
    child = scoped_native(host, helper, {'INFINIFY_DEBUG_NATIVE_MAX_RECORDS': str(limit)})
    found = until('adopts exactly the host\'s four windows', 15, lambda: state()['windows'], lambda w: len(w) == 4 and not any(x['suspended'] for x in w))
    ok('adopts exactly the host\'s four windows', [(w['id'], w['title']) for w in found])
    first = until(f'a capped first frame of {limit} records', 6, native, lambda n: len(n['records']) == limit)
    arrange([w['id'] for w in found])
    records = native()['records']
    known = ids_by_wid(records)
    # Focus a window that is in the frame; then a window that was omitted, which must join while another family leaves.
    sent = [w for w in wids if w in known]
    omitted = [w for w in wids if w not in known]
    check(f'the first frames carry exactly {limit} of the 4 windows, whole single-window families', len(sent) == limit and len(omitted) == 1,
          {'records': [(r['wid'], r['window']) for r in records], 'host_wids': wids, 'first': [r['wid'] for r in first['records']]})
    title_of = {w['title']: w['id'] for w in found}
    logical_of = {wid: title_of[f'DriftWM disposable fixture {n + 1}'] for n, wid in enumerate(wids)}
    target = omitted[0]
    msg('focus', '--id', str(logical_of[target]))
    now_records = until('the focused, previously omitted family is in the frame', 4, lambda: native()['records'],
                        lambda r: target in ids_by_wid(r) and len(r) == limit)
    placed = until('the focused window is placed by the window server (drawn at half size, zoom 0.5)', 4, lambda: halved(target), bool)
    ok('the focused window is placed by the window server (drawn at half size, zoom 0.5)', {'screen': screen(target), 'own': own(target)})
    left = [w for w in wids if w not in ids_by_wid(now_records)]
    check('one other family is omitted instead and stays at its last native placement (still drawn at half size or untouched)',
          len(left) == 1 and (halved(left[0]) or untransformed(left[0])), {'omitted': left, 'screen': screen(left[0]), 'own': own(left[0])})
    pan(1.5)
    time.sleep(.5)
    lines = [l for l in trace() if 'omitted from a frame (helper limit' in l]
    families = [l.split('window family ', 1)[1].split(' omitted', 1)[0] for l in lines]
    check('each omitted family was logged once, not once per frame', lines and len(families) == len(set(families)), lines)
    idle = submitted_over(4)
    check('no resend storm: under 2 frames a second at rest over 4 s (a 250 ms retry sends 4 a second)', idle < 8, f'{idle} frames in 4 s')
    stats = native()
    check('presentation is not ended, and no "native presentation ended" line', not stats['ended'] and not ended_lines(), {'ended': stats['ended'], 'lines': ended_lines()})
    check(f'every frame stayed at {limit} records', len(stats['records']) == limit, len(stats['records']))
    reached.append('cap')
    quit_infinify(child, 'msg action quit ends the run with status 0')
    restored = until('every host window is back at its own frame after quit', 4, lambda: [untransformed(w) for w in wids], all)
    ok('every host window is back at its own frame after quit', restored)


def frame_cap_oversized():
    host, wids, helper = cooperative_host(2, ['--family', 'popup'])
    root, popup = wids[0], wids[-1]
    child = scoped_native(host, helper, {'INFINIFY_DEBUG_NATIVE_MAX_RECORDS': '1'})
    found = until('adopts the host\'s two windows (the popup joins its root\'s family)', 15, lambda: state()['windows'], lambda w: len(w) == 2)
    ok('adopts the host\'s two windows (the popup joins its root\'s family)', [(w['id'], w['title']) for w in found])
    root_logical = next(w['id'] for w in found if w['title'] == 'DriftWM disposable fixture 1')
    if not ended_lines():
        msg('focus', '--id', str(root_logical))
    line = until('focusing the two-window family ends presentation with the record-limit line', 6, ended_lines, bool)
    check('the line names the focused/enter family and the limit 1', any('focused/enter window family' in l and 'exceeds helper record limit 1' in l for l in line), line)
    check('it is said once', len(ended_lines()) == 1, ended_lines())
    until('the presenter reports ended', 3, lambda: native()['ended'], bool)
    restored = until('every host window (root, popup, the other) is back at its own frame', 4, lambda: [untransformed(w) for w in wids], all)
    ok('every host window (root, popup, the other) is back at its own frame', {'restored': restored, 'root': root, 'popup': popup})
    reached.append('oversized')
    quit_infinify(child, 'msg action quit ends the run with status 0')


def snapshot_race():
    host, wids, helper = cooperative_host(3, ['--churn', '8'])
    base, churn = wids[:3], wids[3:]
    child = scoped_native(host, helper, {})
    found = until('adopts the host\'s three visible windows', 15, lambda: state()['windows'], lambda w: len(w) == 3)
    ok('adopts the host\'s three visible windows', [(w['id'], w['title']) for w in found])
    arrange([w['id'] for w in found])
    until('the three are placed at half size', 4, lambda: [halved(w) for w in base], all)
    rates, named = [], {}
    for step in range(len(churn)):
        burst = threading.Thread(target=pan, args=(2.2,))
        burst.start()
        time.sleep(.2)
        os.kill(host.pid, signal.SIGUSR1)
        while burst.is_alive():
            try:
                if churn[step] in ids_by_wid(native()['records']):
                    named[churn[step]] = named.get(churn[step], 0) + 1
            except (OSError, KeyError, ValueError):
                pass
            time.sleep(.03)
        burst.join()
        time.sleep(1.5)
        rates.append(submitted_over(2))
        if ended_lines():
            fail('presentation continues while windows close under frames', ended_lines())
    (EVIDENCE / 'idle-submissions.json').write_text(json.dumps({'frames_per_2s_at_rest': rates, 'samples_naming_churn_window': named}))
    check('closing windows were named in sent frames while they went', len(named) >= len(churn) // 2, f'{len(named)} of {len(churn)} churn windows seen in DebugNative records: {named}')
    check('after every close, at rest: under 2 frames a second over 2 s (a 250 ms snapshot retry sends 4 a second)', max(rates) < 4, f'frames per 2 s: {rates}')
    stats = native()
    gone = [w for w in churn if w in ids_by_wid(stats['records'])]
    check('no closed churn window is still named in the frame', not gone, {'still_named': gone, 'records': [r['wid'] for r in stats['records']]})
    check('presentation is not ended', not stats['ended'] and not ended_lines(), stats['ended'])
    check('the three remaining windows are still placed', all(halved(w) for w in base), {w: screen(w) for w in base})
    lines = [l for l in trace() if ' not placed: ' in l and any(f'window {w} ' in l for w in churn)]
    (EVIDENCE / 'churn-statuses.txt').write_text('\n'.join(lines) + '\n')
    snapshot = [l for l in lines if 'its original could not be read' in l]
    print(f'info: churn statuses from the helper: {lines}', flush=True)
    if snapshot:
        reached.append('snapshot')
        ok('DW2_SNAPSHOT for a closing window was answered and not retried into a storm', snapshot)
    else:
        print('NOT REACHED: no DW2_SNAPSHOT ("its original could not be read") answer for a closing window in 8 attempts; '
              'the no-storm and continuity checks above held, the snapshot-specific path was not exercised live', flush=True)
    quit_infinify(child, 'msg action quit ends the run with status 0')
    until('the remaining host windows are back at their own frames', 4, lambda: [untransformed(w) for w in base], all)


def stale_frame():
    small, large, marker = (400, 300), (600, 450), 40
    executable = bundle('stale-frame', 'StaleFrameFixture', 'org.infinify.stale-frame-fixture')
    log = EVIDENCE / 'fixture.log'
    fixture = start([executable, f'{small[0]}x{small[1]}', f'{large[0]}x{large[1]}', '300'], stdout=open(log, 'w'), stderr=subprocess.STDOUT)
    pid, wid = ready(log)
    # This run's own config: no inherited macOS wallpaper behind the tile, whose colours could pass for a marker.
    (WORK / 'config.toml').write_text('[background]\ntype = "none"\n')
    child = launch(['--windowed', '1100x700', '--no-hover-forwarding', '--debug-pointer', '--only-pid', str(pid)], {'INFINIFY_DEBUG_TEST_PANEL': '1'})
    found = until('adopts the fixture window (capture overlay, no helper)', 15, lambda: state()['windows'], lambda w: len(w) == 1)
    logical = found[0]['id']
    capture = until('the fixture is captured', 10, lambda: ask({'DebugCapture': {'window': logical, 'phase': 'status'}}).get('Ok', {}).get('DebugCapture', {}),
                    lambda c: c.get('pixels') and c.get('captured_frames', 0) > 0)
    ok('the fixture is captured', {k: capture.get(k) for k in ('stream', 'pixels', 'captured_frames')})
    msg('zoom', '1')
    s = settle()
    msg('move', '--id', str(logical), str(int(s['camera'][0])), str(int(s['camera'][1])))
    s = settle()
    panels = [w for w in cg_windows(child.pid) if w[1][2:] == [1100, 700]]
    if len(panels) != 1:
        fail('the canvas panel in the window list', cg_windows(child.pid))
    sizes = []
    stop = threading.Event()

    def poll():
        while not stop.is_set():
            try:
                w = state()['windows'][0]
                sizes.append([now(), w['size']])
            except Exception as error:  # noqa: BLE001 - evidence only
                sizes.append([now(), str(error)])
            time.sleep(.02)

    frames = EVIDENCE / 'frames'
    frames.mkdir(exist_ok=True)
    recorder_log = EVIDENCE / 'recorder.log'
    recorder = start([str(WORK / 'canvas-recorder'), str(panels[0][0]), '7', str(frames)], stdout=open(recorder_log, 'w'), stderr=subprocess.STDOUT)
    until('the recorder records the canvas panel', 6, lambda: 'RECORDING' in recorder_log.read_text() or recorder.poll() is not None, bool)
    if recorder.poll() is not None:
        fail('the recorder records the canvas panel', recorder_log.read_text())
    poller = threading.Thread(target=poll)
    poller.start()
    events = {}
    for name, number, at in (('grow', signal.SIGUSR1, 1.0), ('shrink', signal.SIGUSR2, 4.0)):
        time.sleep(max(0, at - (now() - float(recorder_log.read_text().split('t=')[1].split()[0]))))
        # The live stream is interrupted first (scoped DebugCapture), so the retained picture outlives the resize for at
        # least the 0.25 s recovery delay: the stale frame is on screen long enough to be recorded.
        reply = ask({'DebugCapture': {'window': logical, 'phase': 'interrupt'}})
        events[name] = {'interrupt': now(), 'reply_ok': 'Ok' in reply}
        os.kill(pid, number)
    recorder.wait(15)
    stop.set()
    poller.join()
    (EVIDENCE / 'state-sizes.json').write_text(json.dumps(sizes))
    (EVIDENCE / 'events.json').write_text(json.dumps(events))
    check('both interrupts were accepted', all(e['reply_ok'] for e in events.values()), events)
    rows = [json.loads(l) for l in (frames / 'frames.jsonl').read_text().splitlines()]
    check('the canvas was recorded', len(rows) > 30, len(rows))

    def size_at(t):
        last = None
        for at, size in sizes:
            if at > t:
                break
            last = size
        return last

    def changed_after(t, wanted):
        return next((at for at, size in sizes if at > t and isinstance(size, list) and size == wanted), None)

    old_size = size_at(events['grow']['interrupt'])
    big_at = next((at for at, size in sizes if at > events['grow']['interrupt'] and isinstance(size, list) and size != old_size), None)
    big_size = size_at(big_at) if big_at else None
    small_at = changed_after(events['shrink']['interrupt'], old_size)
    check('the canvas saw the native size change both ways', big_at and small_at, {'old': old_size, 'big': big_size})

    def box(row, key):
        b = row[key]
        return None if b[4] == 0 else (b[0], b[1], b[2] - b[0] + 1, b[3] - b[1] + 1)

    def near(a, b, tolerance=3):
        return abs(a - b) <= tolerance

    stretched, stale_grow, stale_shrink, fresh = [], [], [], []
    for row in rows:
        red, blue = box(row, 'red'), box(row, 'blue')
        for name, b in (('red', red), ('blue', blue)):
            if b and not (near(b[2], marker) and near(b[3], marker)) and b[2] > 4 and b[3] > 4:
                # A marker partly cut by the tile edge is narrower on one axis only; a scaled one changes both.
                if not (near(b[2], marker) or near(b[3], marker)):
                    stretched.append({'n': row['n'], name: b})
        extent = (blue[0] + blue[2] - red[0], blue[1] + blue[3] - red[1]) if red and blue else None
        if big_at < row['pts'] < events['shrink']['interrupt'] and extent and near(extent[0], small[0]) and near(extent[1], small[1]):
            stale_grow.append({'n': row['n'], 'pts': row['pts'], 'red': red, 'extent': extent})
        if row['pts'] > small_at and red and not blue:
            stale_shrink.append({'n': row['n'], 'pts': row['pts'], 'red': red})
        if extent and (near(extent[0], large[0]) and near(extent[1], large[1]) or row['pts'] > small_at and near(extent[0], small[0])):
            fresh.append({'n': row['n'], 'pts': row['pts'], 'red': red, 'extent': extent})
    (EVIDENCE / 'classified.json').write_text(json.dumps({'stretched': stretched, 'stale_grow': stale_grow, 'stale_shrink': stale_shrink, 'fresh': fresh}))
    keep = {f['n'] for group in (stretched, stale_grow, stale_shrink) for f in group} | {f['n'] for f in fresh[:3]} | {rows[0]['n'], rows[-1]['n']}
    for png in frames.glob('frame-*.png'):
        if int(png.stem.split('-')[1]) not in keep:
            png.unlink()
    check('no frame shows a scaled marker (red/blue squares stay 40 px at zoom 1 in every recorded frame)', not stretched, stretched[:10])
    if not stale_grow and not stale_shrink:
        print('NOT REACHED: no recorded frame showed a retained picture at its old size after the canvas had the new native size', flush=True)
    else:
        reached.append('stale')
        ok('stale frames after growing: the old picture at its own size (extent 400x300) while the tile is 600x450', f'{len(stale_grow)} frames, first {stale_grow[:2]}')
        ok('stale frames after shrinking: the old picture cropped (blue corner cut off), the red marker unscaled', f'{len(stale_shrink)} frames, first {stale_shrink[:2]}')
        after = [f for f in fresh if f['pts'] > big_at and f['pts'] < events['shrink']['interrupt']]
        if stale_grow and after:
            dx, dy = stale_grow[-1]['red'][0] - after[0]['red'][0], stale_grow[-1]['red'][1] - after[0]['red'][1]
            check('top-left anchored: the stale picture\'s red corner is where the new capture puts it', abs(dx) <= 2 and abs(dy) <= 2, {'stale': stale_grow[-1], 'fresh': after[0]})
    quit_infinify(child, 'msg action quit ends the run with status 0')
    fixture.terminate()


def zero_screen():
    def press(child):
        # A first click on the inactive accessory app's window may only activate it: click again until the canvas reacts.
        opened = lambda: [l for l in trace() if 'INFINIFY_DEBUG_HIDE_SCREENS: AppKit screens hidden' in l]
        clicks = []
        for _ in range(4):
            done = until('the chooser is on screen and its Open canvas button can be clicked', 8,
                         lambda: subprocess.run([str(WORK / 'chooser-click'), str(child.pid)], capture_output=True, text=True, timeout=10), lambda d: d.returncode == 0, interval=.5)
            clicks.append(done.stdout.strip())
            end = time.monotonic() + 1.5
            while time.monotonic() < end and not opened():
                time.sleep(.05)
            if opened():
                break
        check('the chooser\'s Open canvas button opened the canvas (HID clicks on Infinify\'s own window only)', opened(), clicks)
        return now()

    def chord():
        done = subprocess.run([str(WORK / 'exit-chord')], capture_output=True, text=True, timeout=10)
        check('Control-Option-Escape is posted at the HID level (guest only)', done.returncode == 0, (done.stdout + done.stderr).strip())

    def phase(t0, at):
        time.sleep(max(0, t0 + at - now()))

    # Run 1: hidden for the first 8 s after the canvas first opens, shown, lost again from 16 to 24 s, shown again.
    child = launch(['--manual'], {'INFINIFY_DEBUG_HIDE_SCREENS': '0-8,16-24'})
    until('the --manual chooser is up and IPC answers DebugInput', 10, lambda: 'running' in keys(), bool)
    t0 = press(child)
    phase(t0, 1.5)
    k = keys()
    check('launch with no screen: no panel and no key at all (no Carbon chord, no system key filter)',
          k['panels'] == 0 and not k['running'] and k['carbon_registered'] == 0 and not k['system_filter'] and not k['exit_chord'], brief(k))
    waits = lambda: [l for l in trace() if 'openPanels: no AppKit screen' in l]
    check('the debug line says the canvas waits with no keys', any('canvas waits for a display (keys none)' in l for l in waits()), waits())
    chord()
    time.sleep(1.5)
    check('the exit chord does nothing while no panel ever opened (Infinify keeps running)', child.poll() is None, child.returncode)
    phase(t0, 9.5)
    k = keys()
    check('screens shown: panels open with the full key set (system key filter on, quit and exit chord registered)',
          k['panels'] >= 1 and k['running'] and k['system_filter'] and k['quit'] and k['exit_chord'] and k['carbon_registered'] > 0, brief(k))
    full = k['carbon_registered']
    phase(t0, 17.5)
    k = keys()
    check('runtime loss of every display: no panel, own keys only (no system key filter), quit and exit chord still registered',
          k['panels'] == 0 and k['running'] and not k['system_filter'] and k['quit'] and k['exit_chord'] and 0 < k['carbon_registered'] <= full, brief(k))
    check('the debug line says own keys only', any('canvas waits for a display (keys own only)' in l for l in waits()), waits())
    phase(t0, 25.5)
    k = keys()
    check('displays back: panels and the system key filter return', k['panels'] >= 1 and k['running'] and k['system_filter'] and k['quit'], brief(k))
    quit_infinify(child, 'run 1: msg action quit ends it with status 0')
    shutil.copy2(ERRLOG, EVIDENCE / 'run1.err.log')
    ERRLOG.write_text('')
    # Run 2: panels first, then every display lost at 6 s; the exit chord itself must still quit.
    child = launch(['--manual'], {'INFINIFY_DEBUG_HIDE_SCREENS': '6-300'})
    until('run 2: the chooser is up', 10, lambda: 'running' in keys(), bool)
    t0 = press(child)
    until('run 2: panels open with the system key filter', 5, keys, lambda k: k['panels'] >= 1 and k['system_filter'])
    phase(t0, 7.5)
    k = until('run 2: after the loss, own keys only', 4, keys, lambda k: k['panels'] == 0 and k['running'] and not k['system_filter'] and k['exit_chord'])
    ok('run 2: after the loss, own keys only', brief(k))
    chord()
    try:
        code = child.wait(6)
    except subprocess.TimeoutExpired:
        fail('run 2: the exit chord quits Infinify while it has no panel', 'still running 6 s after the chord')
    check('run 2: the exit chord quits Infinify while it has no panel, status 0', code == 0, f'exit {code}')
    reached.append('keys')


{'frame-cap': frame_cap, 'frame-cap-oversized': frame_cap_oversized, 'snapshot-race': snapshot_race,
 'stale-frame': stale_frame, 'zero-screen': zero_screen}[MODE]()
if MODE in ('snapshot-race', 'stale-frame') and not reached:
    print(f'NOT REACHED: {MODE}: nothing failed, the specific path was not exercised (evidence in {EVIDENCE})', flush=True)
    sys.exit(3)
print(f'PASS: {MODE} (guest-observed, disposable fixtures only; not third-party acceptance)', flush=True)
