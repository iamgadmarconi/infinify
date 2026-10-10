#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Dock real-window compositing spike driver.

Two modes share one body of driver code (socket handling, the heartbeat thread, the
affine, the readback checks, the 240-step slide loop, restore, the finally path and
the evidence file):

  --dock         the owner's single privileged run. It injects Infinify's helper
                 into Dock (sudo), transforms a disposable spike fixture owned by
                 another process at half size, and waits for a real owner click.
  --cooperative  the same driver code against the cooperative fixture host and its
                 own window, with no Dock, no sudo and no owner. The owner-only steps
                 become recorded skips. This is how the driver is tested.

The display claim never rests on a status code, a resolved symbol, or the fixture's
own self-report: it rests on the owner's answer plus the fixture's click count rising
after a real click. See the evidence file's "claims" object.
"""
import ctypes as C
import json
import os
import platform
import secrets
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

BUILD = Path('target/privileged')
EVIDENCE = BUILD / 'spike-evidence.json'
PREFLIGHT_STOP = BUILD / 'spike-preflight.json'
# The payload's exact scope name and refusal error for a one-window spike allowlist.
DOCK_ALLOWLIST_SCOPE = 'spike allowlist: 1 window(s) only'
ALLOWLIST_VIOLATION = 'allowlist scope violation'

OWNER_STEPS = """\
Owner-only preparation (run at the machine, see native/privileged/README.md
"Dock spike (owner-run)"). This run changed nothing and started nothing.
  1. In Recovery: csrutil enable --without fs --without debug --without nvram ; reboot
  2. sudo nvram boot-args=-arm64e_preview_abi ; reboot
  3. Re-run ./scripts/spike-compositor.sh
Undo: csrutil enable (Recovery) and sudo nvram -d boot-args, then reboot.\
"""


# --- SkyLight / CoreGraphics / Accessibility observation helpers -------------
class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]
class Size(C.Structure):
    _fields_ = [('width', C.c_double), ('height', C.c_double)]
class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Size)]

sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetWindowOwner.argtypes = [C.c_int, C.c_uint32, C.POINTER(C.c_int)]
sky.SLSGetWindowOwner.restype = C.c_int
sky.SLSGetScreenRectForWindow.argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]
sky.SLSGetScreenRectForWindow.restype = C.c_int


def window_owner(wid):
    owner = C.c_int(0)
    status = sky.SLSGetWindowOwner(sky.SLSMainConnectionID(), wid, C.byref(owner))
    if status:
        raise RuntimeError(f'SLSGetWindowOwner failed: {status}')
    return owner.value


def screen_rect(wid):
    rect = Rect()
    status = sky.SLSGetScreenRectForWindow(sky.SLSMainConnectionID(), wid, C.byref(rect))
    if status:
        return {'skipped': f'SLSGetScreenRectForWindow status {status}'}
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]


def cg_bounds(wid):
    """CGWindowListCopyWindowInfo bounds for one window number (no permission)."""
    try:
        cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGWindowListCopyWindowInfo.argtypes = [C.c_uint32, C.c_uint32]
        cg.CGWindowListCopyWindowInfo.restype = C.c_void_p
        cg.CGRectMakeWithDictionaryRepresentation.argtypes = [C.c_void_p, C.POINTER(Rect)]
        cg.CGRectMakeWithDictionaryRepresentation.restype = C.c_bool
        cf.CFArrayGetCount.argtypes = [C.c_void_p]; cf.CFArrayGetCount.restype = C.c_long
        cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]; cf.CFArrayGetValueAtIndex.restype = C.c_void_p
        cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]; cf.CFDictionaryGetValue.restype = C.c_void_p
        cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]; cf.CFNumberGetValue.restype = C.c_bool
        cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]; cf.CFStringCreateWithCString.restype = C.c_void_p
        cf.CFRelease.argtypes = [C.c_void_p]
        utf8 = 0x08000100
        knum = cf.CFStringCreateWithCString(None, b'kCGWindowNumber', utf8)
        kbounds = cf.CFStringCreateWithCString(None, b'kCGWindowBounds', utf8)
        arr = cg.CGWindowListCopyWindowInfo(1 << 3, wid)  # kCGWindowListOptionIncludingWindow
        try:
            if not arr:
                return {'skipped': 'CGWindowListCopyWindowInfo returned null'}
            found = {'skipped': 'window number absent from CGWindowList'}
            for i in range(cf.CFArrayGetCount(arr)):
                entry = cf.CFArrayGetValueAtIndex(arr, i)
                numref = cf.CFDictionaryGetValue(entry, knum)
                if not numref:
                    continue
                num = C.c_longlong(0)
                cf.CFNumberGetValue(numref, 4, C.byref(num))  # kCFNumberSInt64Type
                if num.value != wid:
                    continue
                bref = cf.CFDictionaryGetValue(entry, kbounds)
                rect = Rect()
                if bref and cg.CGRectMakeWithDictionaryRepresentation(bref, C.byref(rect)):
                    found = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
                break
            return found
        finally:
            if arr:
                cf.CFRelease(arr)
            cf.CFRelease(knum); cf.CFRelease(kbounds)
    except Exception as exc:  # observation only; never abort the spike for it
        return {'skipped': f'CGWindowList observation failed: {exc!r}'}


def ax_frame(pid):
    """Accessibility position/size of the process's first window, if AX is trusted."""
    try:
        app = C.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        app.AXIsProcessTrusted.restype = C.c_bool
        if not app.AXIsProcessTrusted():
            return {'skipped': 'Accessibility is not trusted for this process'}
        app.AXUIElementCreateApplication.argtypes = [C.c_int]; app.AXUIElementCreateApplication.restype = C.c_void_p
        app.AXUIElementCopyAttributeValue.argtypes = [C.c_void_p, C.c_void_p, C.POINTER(C.c_void_p)]
        app.AXUIElementCopyAttributeValue.restype = C.c_int
        app.AXValueGetValue.argtypes = [C.c_void_p, C.c_int, C.c_void_p]; app.AXValueGetValue.restype = C.c_bool
        cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]; cf.CFArrayGetValueAtIndex.restype = C.c_void_p
        cf.CFArrayGetCount.argtypes = [C.c_void_p]; cf.CFArrayGetCount.restype = C.c_long
        cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]; cf.CFStringCreateWithCString.restype = C.c_void_p
        cf.CFRelease.argtypes = [C.c_void_p]
        utf8 = 0x08000100
        element = app.AXUIElementCreateApplication(pid)
        kwin = cf.CFStringCreateWithCString(None, b'AXWindows', utf8)
        kpos = cf.CFStringCreateWithCString(None, b'AXPosition', utf8)
        ksize = cf.CFStringCreateWithCString(None, b'AXSize', utf8)
        windows = C.c_void_p(0)
        if app.AXUIElementCopyAttributeValue(element, kwin, C.byref(windows)) or not windows.value or cf.CFArrayGetCount(windows) < 1:
            return {'skipped': 'no Accessibility windows for pid'}
        window = cf.CFArrayGetValueAtIndex(windows, 0)
        pos = C.c_void_p(0); size = C.c_void_p(0)
        app.AXUIElementCopyAttributeValue(window, kpos, C.byref(pos))
        app.AXUIElementCopyAttributeValue(window, ksize, C.byref(size))
        p = Point(); s = Size()
        ok_p = pos.value and app.AXValueGetValue(pos, 1, C.byref(p))   # kAXValueCGPointType
        ok_s = size.value and app.AXValueGetValue(size, 2, C.byref(s))  # kAXValueCGSizeType
        for ref in (kwin, kpos, ksize):
            cf.CFRelease(ref)
        if not (ok_p and ok_s):
            return {'skipped': 'AXValueGetValue failed'}
        return [p.x, p.y, s.width, s.height]
    except Exception as exc:
        return {'skipped': f'Accessibility observation failed: {exc!r}'}


def fixture_frame(status_path):
    if status_path is None:
        return {'skipped': 'cooperative host publishes no status file'}
    try:
        data = json.loads(Path(status_path).read_text())
        return {k: data[k] for k in ('frame_global_topleft', 'click_count', 'key_down_count',
                                     'is_key', 'app_active', 'occlusion_visible') if k in data}
    except Exception as exc:
        return {'skipped': f'status file unreadable: {exc!r}'}


# --- protocol session --------------------------------------------------------
class Session:
    """One long-lived controller connection. Shared by the heartbeat thread and the
    main thread under a lock, since protocol v1 serves exactly one controller."""

    def __init__(self, run, nonce):
        self.nonce = nonce
        self.lock = threading.Lock()
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(4)
        self.sock.connect(str(Path(run) / 'helper.sock'))

    def request(self, op, **fields):
        packet = json.dumps(dict(v=1, nonce=self.nonce, op=op, **fields)).encode() + b'\n'
        with self.lock:
            start = time.monotonic()
            self.sock.sendall(packet)
            data = b''
            while not data.endswith(b'\n'):
                part = self.sock.recv(4096)
                if not part:
                    break
                data += part
            rtt = time.monotonic() - start
        return (json.loads(data) if data else None), rtt

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Heartbeat(threading.Thread):
    def __init__(self, session):
        super().__init__(daemon=True)
        self.session = session
        self.stop = threading.Event()
        self.beats = 0
        self.ok = True

    def run(self):
        while not self.stop.wait(0.8):
            try:
                reply, _ = self.session.request('heartbeat')
                self.beats += 1
                if not (reply and reply.get('ok')):
                    self.ok = False
                    break
            except OSError:
                self.ok = False
                break


def one_shot(run, nonce, op, **fields):
    """A fresh connection for a request we expect to be rejected (a rejected request
    closes the controller connection, so each goes on its own socket)."""
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(4)
    s.connect(str(Path(run) / 'helper.sock'))
    try:
        s.sendall(json.dumps(dict(v=1, nonce=nonce, op=op, **fields)).encode() + b'\n')
        data = b''
        while not data.endswith(b'\n'):
            part = s.recv(4096)
            if not part:
                break
            data += part
        return json.loads(data) if data else None
    finally:
        s.close()


def prompt_with_timeout(prompt, timeout):
    """Ask one terminal question without ever blocking the restore path forever: the
    fixture self-terminates on its own cap, so an unanswered prompt must not outlive
    it. Returns the line, or None if nothing was typed within the timeout."""
    sys.stdout.write(prompt)
    sys.stdout.flush()
    ready, _, _ = select.select([sys.stdin], [], [], timeout)
    if not ready:
        sys.stdout.write('\n')
        return None
    return sys.stdin.readline()


def affine(w, h, sx, sy, sw, sh):
    # screen-to-window-local, global top-left points (payload README / design §3).
    return [w / sw, 0.0, 0.0, h / sh, -sx * w / sw, -sy * h / sh]


def approx(a, b, tol=0.75):
    if not (isinstance(a, list) and isinstance(b, list) and len(a) == len(b)):
        return False
    return all(abs(x - y) <= tol for x, y in zip(a, b))


# --- shared spike body -------------------------------------------------------
def observe(session, identity, status_path):
    probe, _ = session.request('probe')
    return {
        'protocol_readback': probe.get('readback') if probe else None,
        'window_server_screen_rect': screen_rect(identity['wid']),
        'cgwindowlist_bounds': cg_bounds(identity['wid']),
        'accessibility': ax_frame(identity['pid']),
        'fixture_status': fixture_frame(status_path),
    }


def drive(evidence, state, mode, run, nonce, identity, status_path):
    is_owner = mode == 'dock'
    steps = evidence.setdefault('steps', {})

    # Step 5: scope must be restricted, and two out-of-scope enrolls must be refused.
    # In --dock the allowlist is the thing under test, so require its exact scope name
    # and its distinct error — a refusal for any other reason is not the allowlist
    # doing the refusing. In --cooperative the host is fixture-scoped and carries no
    # allowlist, so accept any non-open scope and any refusal; the allowlist error
    # itself is proven separately in fixture_test.py.
    probe = one_shot(run, nonce, 'probe')
    scope = probe.get('scope') if probe else None
    steps['scope'] = scope
    if is_owner:
        if scope != DOCK_ALLOWLIST_SCOPE:
            raise RuntimeError(f'helper scope is not the single-window allowlist: {scope!r}')
    elif scope is None or scope == 'explicit same-UID enrollment':
        raise RuntimeError(f'helper scope is not restricted: {scope!r}')
    wrong_pid = dict(identity, pid=identity['pid'] + 1)
    driver_wid0 = dict(pid=os.getpid(), birth_sec=0, birth_usec=0, wid=0, owner=0)
    refusals = {}
    for name, who in (('fixture_wid_wrong_pid', wrong_pid), ('driver_pid_wid0', driver_wid0)):
        reply = one_shot(run, nonce, 'enroll', identity=who)
        refusals[name] = reply
        if not reply or reply.get('ok'):
            raise RuntimeError(f'out-of-scope enroll {name} was not refused: {reply!r}')
        if is_owner and reply.get('error') != ALLOWLIST_VIOLATION:
            raise RuntimeError(f'out-of-scope enroll {name} refused for the wrong reason: {reply!r}')
    steps['refused_foreign_enrolls'] = refusals

    # Step 6: enroll the real fixture window.
    main = Session(run, nonce)
    state['main'] = main
    enrolled, _ = main.request('enroll', identity=identity)
    if not (enrolled and enrolled.get('ok')):
        raise RuntimeError(f'enroll of fixture window failed: {enrolled!r}')
    baseline = enrolled['readback']
    steps['enroll'] = enrolled

    # Step 7: observations before any change.
    steps['before'] = observe(main, identity, status_path)

    # Step 8: verify the untransformed convention, then one half-size transform.
    bounds = baseline['bounds']
    w, h = bounds[2], bounds[3]
    sx0, sy0, _, _ = baseline['screen_rect']
    expected_identity = [1.0, 0.0, 0.0, 1.0, -bounds[0], -bounds[1]]
    steps['baseline_matrix'] = baseline['matrix']
    steps['expected_baseline_matrix'] = expected_identity
    if not approx(baseline['matrix'], expected_identity, tol=1e-6):
        raise RuntimeError(f'untransformed matrix {baseline["matrix"]} is not Translate(-origin) {expected_identity}')
    tx, ty, tsw, tsh = sx0 + 120.0, sy0 + 120.0, w / 2.0, h / 2.0
    target = affine(w, h, tx, ty, tsw, tsh)
    # Mark transformed before issuing the request: if it raises mid-flight the finally
    # path must still attempt restore (the payload also restores on disconnect).
    state['transformed'] = True
    reply, _ = main.request('transform', identity=identity, matrix=target)
    if not (reply and reply.get('readback_matches_requested')):
        raise RuntimeError(f'half-size transform did not read back as requested: {reply!r}')
    steps['half_size_transform'] = {'requested_matrix': target,
                                    'target_screen_rect': [tx, ty, tsw, tsh],
                                    'reply': reply}

    # Step 9: observations transformed; then the owner looks and clicks (dock only).
    # A heartbeat thread keeps the lease alive while the main thread only polls, so
    # it is the sole socket user during the wait (the slide loop renews via its own
    # transforms, so no heartbeat runs then and the connection has one user at a time).
    steps['transformed'] = observe(main, identity, status_path)
    heartbeat = Heartbeat(main)
    heartbeat.start()
    state['heartbeat'] = heartbeat
    if is_owner and state.get('fixture') and state['fixture'].poll() is not None:
        # The disposable fixture already self-terminated (its lifetime cap elapsed
        # during the sudo prompt), so there is no window to look at or click.
        steps['owner_click'] = {'skipped': 'fixture exited before the click wait'}
        steps['owner_answer'] = {'skipped': 'fixture exited before the owner could answer'}
    elif is_owner:
        print('\nThe test window should now be HALF its size, moved about 120 points right and down, still at the\n'
              'lower left and still above other windows. Click its big button once (you have 90 seconds).\n'
              'If it still looks full size, click the button anyway: you are asked what you saw next.\n', flush=True)
        if not fixture_frame(status_path).get('occlusion_visible'):
            print('(The window reports that it is not visible at the moment. If you cannot see it, say so below.)\n',
                  flush=True)
        before_clicks = fixture_frame(status_path).get('click_count', 0)
        start = time.monotonic()
        rose = False
        ended = None
        while time.monotonic() - start < 90:
            status = fixture_frame(status_path)
            if isinstance(status.get('click_count'), int) and status['click_count'] > before_clicks:
                rose = True
                break
            if state['fixture'].poll() is not None:
                ended = 'the test window closed during the wait'
                break
            if not heartbeat.ok:
                ended = 'the helper stopped answering heartbeats during the wait'
                break
            time.sleep(0.1)
        waited = fixture_frame(status_path)
        steps['owner_click'] = {
            'click_count_rose': rose,
            'seconds_waited': round(time.monotonic() - start, 2),
            'is_key': waited.get('is_key'),
            'occlusion_visible': waited.get('occlusion_visible'),
        }
        if ended:
            steps['owner_click']['ended_early'] = ended
            raise RuntimeError(ended)
        answer = prompt_with_timeout(
            'What did you see? y = half size at the new place; n = unchanged or not visible; or a few words: ', 120)
        steps['owner_answer'] = answer.strip() if isinstance(answer, str) else \
            {'skipped': 'no answer typed within 120 s'}
    else:
        # Hold briefly so the heartbeat thread demonstrably renews the lease, then
        # record the owner-only steps as skips.
        time.sleep(1.6)
        steps['owner_click'] = {'skipped': 'cooperative mode: no owner, no display verification'}
        steps['owner_answer'] = {'skipped': 'cooperative mode: no owner'}

    # Stop the heartbeat thread before the loop so the socket again has one user.
    heartbeat.stop.set()
    heartbeat.join(timeout=2)
    steps['heartbeat'] = {'beats': heartbeat.beats, 'ok': heartbeat.ok}

    # Step 10: the only frame-rate measurement — 240 transforms sliding 200pt and back.
    matched = 0
    worst_rtt = 0.0
    loop_start = time.monotonic()
    for i in range(240):
        # Integer offsets keep every requested tx float32-exact, so the window
        # server's readback matches exactly (it stores transforms as 32-bit floats).
        offset = float(round(200.0 * (1.0 - abs(1.0 - i / 120.0))))
        m = affine(w, h, tx + offset, ty, tsw, tsh)
        reply, rtt = main.request('transform', identity=identity, matrix=m)
        worst_rtt = max(worst_rtt, rtt)
        if reply and reply.get('readback_matches_requested'):
            matched += 1
        pause = (1.0 / 120.0) - rtt
        if pause > 0:
            time.sleep(pause)
    steps['slide_loop'] = {
        'requested': 240,
        'readback_matched': matched,
        'wall_seconds': round(time.monotonic() - loop_start, 3),
        'worst_round_trip_ms': round(worst_rtt * 1000, 2),
    }

    # Step 11: restore and verify, by readback and by the outside observations.
    restored, _ = main.request('restore')
    steps['restore'] = restored
    if not (restored and restored.get('ok') and restored.get('restored')):
        raise RuntimeError(f'restore failed: {restored!r}')
    if not approx(restored['readback']['matrix'], baseline['matrix'], tol=1e-6):
        raise RuntimeError(f'restored matrix {restored["readback"]["matrix"]} != baseline {baseline["matrix"]}')
    state['restored'] = True
    after = observe(main, identity, status_path)
    steps['after'] = after
    outside_back = {}
    for key in ('window_server_screen_rect', 'cgwindowlist_bounds', 'accessibility', 'fixture_status'):
        b, a = steps['before'].get(key), after.get(key)
        skipped = (isinstance(b, dict) and 'skipped' in b) or (isinstance(a, dict) and 'skipped' in a)
        if skipped:
            outside_back[key] = {'skipped': 'observation unavailable in this mode'}
        elif key == 'fixture_status':
            outside_back[key] = b.get('frame_global_topleft') == a.get('frame_global_topleft')
        else:
            outside_back[key] = approx(b, a)
    steps['outside_observations_restored'] = outside_back
    # The restore claim rests on these, so a window that did not come back must fail
    # the run, not be silently recorded. Skipped observations do not count against it.
    unrestored = [k for k, v in outside_back.items() if v is False]
    if unrestored:
        raise RuntimeError(f'outside observations did not return to baseline after restore: {unrestored}')


def build_claims(evidence):
    steps = evidence.get('steps', {})
    loop = steps.get('slide_loop', {})
    refusals = steps.get('refused_foreign_enrolls', {})
    both_refused = bool(refusals) and all(r and not r.get('ok') for r in refusals.values())
    if evidence['mode'] == 'dock':
        # The allowlist must be what refused: the exact scope and the distinct error.
        both_refused = both_refused \
            and steps.get('scope') == DOCK_ALLOWLIST_SCOPE \
            and all(r.get('error') == ALLOWLIST_VIOLATION for r in refusals.values())
    owner_answer = steps.get('owner_answer')
    click = steps.get('owner_click', {})
    click_rose = isinstance(click, dict) and click.get('click_count_rose') is True
    # Guard the empty-loop case: if the slide loop never ran, loop is {} and a naive
    # None == None would falsely assert a 240/240 match that never happened.
    transform_ok = bool(steps.get('half_size_transform', {}).get('reply', {}).get('readback_matches_requested')) \
        and loop.get('requested') is not None and loop.get('readback_matched') == loop.get('requested')

    display_rests = ("the owner's verbal answer AND the fixture's click_count rising after a "
                     "real owner click — never a status code, a resolved symbol, or the "
                     "fixture's own self-report")
    if evidence['mode'] == 'dock':
        display = {'observed': isinstance(owner_answer, str) and owner_answer.lower().startswith('y') and click_rose,
                   'owner_answer': owner_answer, 'click_count_rose': click_rose, 'rests_on': display_rests}
        loaded = {'observed': evidence.get('loader', {}).get('returncode') == 0,
                  'rests_on': 'loader exit status 0 after its own authenticated probe of Dock'}
    else:
        display = {'observed': 'not established',
                   'rests_on': display_rests + ' (cooperative mode: skipped, no owner)'}
        loaded = {'observed': 'not applicable',
                  'rests_on': 'cooperative mode drives the cooperative host, not Dock'}

    restore_step = steps.get('restore') or {}
    restore_finally = steps.get('restore_in_finally') or {}
    restored_ok = bool(restore_step.get('restored')) or bool(restore_finally.get('restored'))
    outside = steps.get('outside_observations_restored', {})
    outside_ok = bool(outside) and all(
        v is True or (isinstance(v, dict) and 'skipped' in v) for v in outside.values())
    # A run that stopped early restores in the finally path and takes no outside observations:
    # say that the helper reported the restore, rather than call a restored window unrestored.
    if outside:
        restored_observed = restored_ok and outside_ok
    elif restored_ok:
        restored_observed = 'helper reported restored; outside observations not taken (the run stopped early)'
    elif not steps.get('half_size_transform') and not steps.get('restore_in_finally'):
        restored_observed = 'nothing was changed'
    else:
        restored_observed = False
    refused_rests = ('two out-of-scope enroll attempts each returned ok:false before any window '
                     'was touched')
    if evidence['mode'] == 'dock':
        refused_rests += (f', each with error {ALLOWLIST_VIOLATION!r} under scope '
                          f'{DOCK_ALLOWLIST_SCOPE!r}')
    evidence['claims'] = {
        'helper_loaded_into_dock': loaded,
        'scope_refused_two_foreign_enrolls': {
            'observed': both_refused,
            'rests_on': refused_rests},
        'transform_read_back_as_requested': {
            'observed': transform_ok,
            'rests_on': 'payload readback_matches_requested for the half-size transform and all 240 slide steps'},
        'window_displayed_scaled_at_target_rectangle': display,
        'owner_click_reached_window': {
            'observed': click_rose if evidence['mode'] == 'dock' else 'not established',
            'rests_on': "the fixture's click_count increased after the owner clicked at the displayed location"},
        'restored_to_original': {
            'observed': restored_observed,
            'rests_on': 'restore readback matrix equals the pre-change baseline and every non-skipped '
                        'outside observation (window-server rect, CGWindowList bounds, Accessibility, '
                        'fixture frame) returned to its first value'},
    }


def macos_build():
    try:
        out = subprocess.check_output(['sw_vers'], text=True)
        fields = dict(line.split(':', 1) for line in out.splitlines() if ':' in line)
        return {k.strip(): v.strip() for k, v in fields.items()}
    except Exception:
        return {'ProductVersion': platform.mac_ver()[0]}


def new_runtime():
    run = Path(tempfile.mkdtemp(prefix='spike-', dir=BUILD)).resolve()
    os.chmod(run, 0o700)
    if len(str(run / 'helper.sock')) >= 104:
        raise RuntimeError(f'runtime socket path too long for AF_UNIX: {run}')
    return run


def run_cooperative(evidence):
    state = {'transformed': False, 'restored': False, 'main': None, 'heartbeat': None}
    run = new_runtime()
    nonce = secrets.token_hex(32)
    payload = (BUILD / 'payload-arm64.dylib').resolve()
    log = open(run / 'host.log', 'w')
    host = subprocess.Popen([str(BUILD / 'host'), str(payload), str(run), nonce], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 8
        while not (run / 'helper.sock').exists():
            if host.poll() is not None:
                raise RuntimeError('cooperative host exited early: ' + (run / 'host.log').read_text())
            if time.monotonic() > deadline:
                raise RuntimeError('cooperative host socket not ready')
            time.sleep(0.04)
        probe = one_shot(run, nonce, 'probe')
        identity = probe['identity']
        drive(evidence, state, 'cooperative', run, nonce, identity, status_path=None)
    except Exception as exc:
        evidence['error'] = repr(exc)
    finally:
        finish(evidence, state, run, nonce, [host])
        log.close()


def run_dock(evidence):
    doctor = json.loads(subprocess.check_output([str(BUILD / 'doctor')], text=True))
    evidence['doctor'] = doctor
    if not doctor.get('injection_preflight_passed'):
        print(json.dumps(doctor, indent=2))
        print('\nSIP/boot preflight has NOT passed, so the spike cannot load into Dock.')
        print(OWNER_STEPS)
        evidence['stopped_at'] = 'doctor preflight not passed'
        # A preflight stop writes its own file, never the real-run evidence, so a
        # later SIP-on run cannot clobber evidence from an actual owner run.
        PREFLIGHT_STOP.write_text(json.dumps(evidence, indent=2) + '\n')
        sys.exit(1)

    # A sidecar from a previous run means a helper may still be loaded in Dock, and
    # the loader fails closed on it. Stop with the cleanup instruction before starting
    # the fixture or prompting for sudo, rather than reporting a confusing "1a failed".
    sidecar = BUILD / 'payload-arm64e.dylib.json'
    if sidecar.exists():
        print(f'A helper sidecar from a previous run is still present: {sidecar}')
        print('A helper may still be loaded in Dock. Run "killall Dock" to remove it,')
        print(f'delete {sidecar}, then re-run ./scripts/spike-compositor.sh.')
        evidence['stopped_at'] = 'stale sidecar present'
        PREFLIGHT_STOP.write_text(json.dumps(evidence, indent=2) + '\n')
        sys.exit(1)

    # Infinify's own canvas covers every window, the fixture included: the owner could not see or click it.
    if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
        print('Infinify itself is running and its canvas would cover the test window. Quit it')
        print('(Control-Option-Escape), then re-run ./scripts/spike-compositor.sh. Nothing was started.')
        evidence['stopped_at'] = 'Infinify shell running'
        PREFLIGHT_STOP.write_text(json.dumps(evidence, indent=2) + '\n')
        sys.exit(1)

    # --- Beyond here runs only on the owner's prepared machine. --------------
    state = {'transformed': False, 'restored': False, 'main': None, 'heartbeat': None, 'fixture': None}
    run = new_runtime()
    nonce = secrets.token_hex(32)  # never printed
    status_path = run / 'fixture-status.json'
    payload = (BUILD / 'payload-arm64e.dylib').resolve()
    # 600 s (the fixture's cap) so a slow sudo prompt or a slow owner cannot let the
    # fixture self-terminate mid-transform; the question below is separately bounded.
    fixture = subprocess.Popen([str(BUILD / 'spike-fixture'), str(status_path), '600'])
    fixture_started = time.monotonic()
    state['fixture'] = fixture
    try:
        deadline = time.monotonic() + 8
        while not status_path.exists():
            if fixture.poll() is not None:
                raise RuntimeError('spike fixture exited early')
            if time.monotonic() > deadline:
                raise RuntimeError('spike fixture status not ready')
            time.sleep(0.05)
        status = json.loads(status_path.read_text())
        wid = status['window_number']
        identity = {'pid': status['pid'], 'birth_sec': status['birth_sec'],
                    'birth_usec': status['birth_usec'], 'wid': wid, 'owner': window_owner(wid)}
        print(f'Spike fixture: pid {identity["pid"]}, window number {wid}.')
        # The baseline is only worth taking once the window server shows the window where
        # AppKit put it: one launch in three was seen elsewhere for most of a second.
        deadline = time.monotonic() + 6
        while True:
            status = fixture_frame(status_path)
            shown, placed = screen_rect(wid), status.get('frame_global_topleft')
            if isinstance(shown, list) and isinstance(placed, list) and approx(shown, placed) \
                    and status.get('occlusion_visible'):
                break
            if time.monotonic() > deadline:
                raise RuntimeError(f'the test window did not settle on screen (window server {shown}, '
                                   f'AppKit {placed}, visible {status.get("occlusion_visible")}); '
                                   'nothing was injected')
            time.sleep(0.1)
        print('A test window titled "DriftWM disposable spike fixture" is now at the lower left of the')
        print('main display. It stays above other windows and does not take the keyboard. Leave it there.')

        cmd = ['sudo', str(BUILD / 'loader-arm64e'), '--inject-dock', str(payload),
               str(run), nonce, '--only-pid', str(identity['pid'])]
        shown = ['sudo', str(BUILD / 'loader-arm64e'), '--inject-dock', str(payload),
                 str(run), '<64-hex-nonce-hidden>', '--only-pid', str(identity['pid'])]
        print('\nAbout to run, with sudo (it will prompt for your password on this terminal):')
        print('  ' + ' '.join(shown))
        print('This injects Infinify\'s helper into Dock. Loading touches no window. Undo: killall Dock.\n', flush=True)
        loader = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
        evidence['loader'] = {'returncode': loader.returncode, 'stderr': loader.stderr}
        if loader.stderr:
            print(loader.stderr, end='' if loader.stderr.endswith('\n') else '\n')
        if loader.returncode != 0:
            raise RuntimeError(f'loader did not report a ready helper (1a failed), exit status {loader.returncode}')
        # The fixture ends itself 600 s after it started. The rest needs about four minutes at
        # most; with less left, stop here rather than lose the window while it is transformed.
        if time.monotonic() - fixture_started > 360:
            raise RuntimeError('the password prompt took so long that the test window is about to close; '
                               'the helper is loaded and holds nothing: run "killall Dock", delete the '
                               'sidecar named above, and re-run')

        drive(evidence, state, 'dock', run, nonce, identity, status_path)
    except Exception as exc:
        evidence['error'] = repr(exc)
    finally:
        finish(evidence, state, run, nonce, [fixture])

    steps = evidence.get('steps', {})
    claims = evidence.get('claims', {})
    print('\n--- spike result ---')
    print(f'1. helper loaded into Dock: {claims.get("helper_loaded_into_dock", {}).get("observed")}')
    print(f'2. scope refused the two foreign enrolls: {claims.get("scope_refused_two_foreign_enrolls", {}).get("observed")}')
    print(f'3. transform displayed (owner said): {steps.get("owner_answer")!r}; '
          f'screen rect read back: {steps.get("transformed", {}).get("protocol_readback", {}).get("screen_rect")}')
    print(f'4. owner click arrived: {claims.get("owner_click_reached_window", {}).get("observed")}')
    print(f'5. restored: {claims.get("restored_to_original", {}).get("observed")}')
    if evidence.get('error'):
        print(f'\nSTOPPED: {evidence["error"]}')
    loader_code = evidence.get('loader', {}).get('returncode')
    if loader_code == 0:
        print('\nThe helper stays loaded in Dock, listening and holding nothing, until Dock restarts.')
        print('"killall Dock" removes it.')
    elif loader_code is None:
        print('\nThe loader was not run: nothing was injected into Dock.')
    else:
        print('\nThe loader failed; its own last line above says whether anything began to run in Dock.')
        print('If it did, "killall Dock" removes it. Delete target/privileged/payload-arm64e.dylib.json before a re-run.')
    print(f'evidence: {EVIDENCE}')


def finish(evidence, state, run, nonce, procs):
    """Runs on every exit path: restore if anything was set, write evidence, kill
    only the processes this driver started. Process termination is in an inner finally
    so that a failure while building claims or writing still stops the fixture."""
    try:
        if state.get('heartbeat'):
            state['heartbeat'].stop.set()
        if state.get('transformed') and not state.get('restored'):
            # Close the main controller first: the payload serves one client at a time,
            # so a restore on a second connection would queue behind the still-open
            # lease until it expired. Closing main lets this restore run at once (and
            # the payload also restores on that disconnect).
            if state.get('main'):
                state['main'].close()
                state['main'] = None
            try:
                reply = one_shot(run, nonce, 'restore')
                state['restored'] = bool(reply and reply.get('restored'))
                evidence.setdefault('steps', {})['restore_in_finally'] = reply
            except Exception as exc:
                evidence.setdefault('steps', {})['restore_in_finally'] = {'error': repr(exc)}
        if state.get('main'):
            state['main'].close()
        build_claims(evidence)
        EVIDENCE.write_text(json.dumps(evidence, indent=2) + '\n')
    finally:
        for proc in procs:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else '--dock'
    if mode not in ('--dock', '--cooperative') or len(sys.argv) > 2:
        print('usage: spike.py [--dock | --cooperative]', file=sys.stderr)
        sys.exit(2)
    evidence = {'mode': mode.lstrip('-'), 'macos': macos_build(), 'evidence_file': str(EVIDENCE)}
    if mode == '--cooperative':
        evidence['doctor'] = json.loads(subprocess.check_output([str(BUILD / 'doctor')], text=True))
        run_cooperative(evidence)
    else:
        run_dock(evidence)
    print('\nclaims:')
    print(json.dumps(evidence.get('claims', {}), indent=2))
    print(f'\nevidence: {EVIDENCE}')


if __name__ == '__main__':
    main()
