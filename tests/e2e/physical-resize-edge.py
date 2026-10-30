#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One guarded physical right-edge drag per capture/native mode, on owned windows.

DebugPointer is read-only here: every press, motion and release is a real CGEvent
posted through WindowServer. Capture edge coordinates are the compositor's
presentation geometry; native edges are independently observed WindowServer
rectangles. Neither observation establishes arbitrary third-party parity.
"""
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify'
PAYLOAD = ROOT / 'target/privileged/payload-arm64.dylib'
spec = importlib.util.spec_from_file_location('owned_dnd', ROOT / 'tests/e2e/native-drag-drop-driver.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
ax = C.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
ax.AXUIElementCreateApplication.argtypes = [C.c_int]
ax.AXUIElementCreateApplication.restype = C.c_void_p
ax.AXUIElementCopyAttributeValue.argtypes = [C.c_void_p, C.c_void_p, C.POINTER(C.c_void_p)]
ax.AXUIElementCopyAttributeValue.restype = C.c_int
ax.AXUIElementSetAttributeValue.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p]
ax.AXUIElementSetAttributeValue.restype = C.c_int
ax._AXUIElementGetWindow.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
ax._AXUIElementGetWindow.restype = C.c_int
ax.AXValueCreate.argtypes = [C.c_int, C.c_void_p]
ax.AXValueCreate.restype = C.c_void_p
owned.cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
owned.cf.CFStringCreateWithCString.restype = C.c_void_p


def until(seconds, read, passes, label):
    end, last = time.monotonic() + seconds, None
    while time.monotonic() < end:
        last = read()
        if passes(last):
            return last
        time.sleep(.05)
    raise AssertionError((label, last))


def exact(wid, original):
    current = owned.independent_snapshot(wid)
    owned.check(current['identity'] == original['identity'] and current['owner'] == original['owner'],
                'input or restoration names the exact owned instance', current)
    return current


def presentation_rect(value):
    origin, size = value['origin'], value['size']
    return [origin['x'], origin['y'], size['width'], size['height']]


def restore_bounds(wid, original):
    # Select only this spawned process's exact AX window, revalidating its
    # independent owner/birth immediately before each setter. No other window
    # is eligible even if AX returns a longer application window list.
    exact(wid, original)
    application = ax.AXUIElementCreateApplication(original['identity'][0])
    windows, keys = C.c_void_p(), []
    try:
        for name in (b'AXWindows', b'AXSize', b'AXPosition'):
            key = owned.cf.CFStringCreateWithCString(None, name, 0x08000100)
            owned.check(bool(key), 'AX key creation')
            keys.append(key)
        owned.check(ax.AXUIElementCopyAttributeValue(application, keys[0], C.byref(windows)) == 0 and windows.value,
                    'exact owned fixture AX windows are readable')
        selected = []
        for index in range(owned.cf.CFArrayGetCount(windows)):
            window = owned.cf.CFArrayGetValueAtIndex(windows, index)
            number = C.c_uint32()
            if ax._AXUIElementGetWindow(window, C.byref(number)) == 0 and number.value == wid:
                selected.append(window)
        owned.check(len(selected) == 1, 'only the exact owned window is restored', wid)
        bounds = original['bounds']
        for key, kind, value in ((keys[1], 2, owned.Size(*bounds[2:])), (keys[2], 1, owned.Point(*bounds[:2]))):
            exact(wid, original)
            encoded = ax.AXValueCreate(kind, C.byref(value))
            owned.check(bool(encoded), 'owned native geometry encoding')
            try:
                owned.check(ax.AXUIElementSetAttributeValue(selected[0], key, encoded) == 0,
                            'owned fixture native geometry restored')
            finally:
                owned.cf.CFRelease(encoded)
    finally:
        if windows.value:
            owned.cf.CFRelease(windows)
        for key in keys:
            owned.cf.CFRelease(key)
        if application:
            owned.cf.CFRelease(application)


def stop(child, app_socket=None):
    if not child:
        return
    if child.poll() is None and app_socket:
        try:
            owned.msg(str(APP), str(app_socket), 'action', 'quit')
            child.wait(timeout=6)
        except Exception:
            pass
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
    child.wait(timeout=3)


def scenario(mode, evidence, host_binary):
    run = evidence / mode
    run.mkdir(mode=0o700)
    runtime = run / 'runtime'
    runtime.mkdir(mode=0o700)
    (run / 'home').mkdir(mode=0o700)
    nonce = secrets.token_hex(32)
    nonce_file = run / 'nonce'
    nonce_file.write_text(nonce + '\n')
    nonce_file.chmod(0o600)
    (run / 'config.toml').touch()
    socket_path = run / 'app.sock'
    host = app = None
    original = wid = event_source = None
    pressed = False
    outcome = {'mode': mode, 'result': 'FAIL'}
    logs = []
    try:
        host_log = open(run / 'host.log', 'w'); logs.append(host_log)
        host = subprocess.Popen([str(host_binary), str(PAYLOAD), str(runtime), nonce, '--windows', '1', '--activation', 'regular', '--size', '320x230', '--level', '4' if mode == 'native' else '0', '--all-spaces', 'yes', '--watchdog', '90'], stdout=host_log, stderr=host_log)
        def ready():
            owned.check(host.poll() is None, 'owned fixture remains live')
            return [line.split() for line in (run / 'host.log').read_text().splitlines() if line.startswith('READY ')]
        line = until(8, ready, bool, 'one regular owned host becomes ready')[0]
        owned.check(len(line) == 3 and int(line[1]) == host.pid,
                    'fixture READY reports the exact spawned process and one window', line)
        wid = int(line[2])
        # AppKit can briefly expose a transitional opening frame. Wait for the
        # same coherent independently read original snapshot for at least100ms.
        last, stable_since = None, time.monotonic()
        def coherent():
            nonlocal last, stable_since
            peer = owned.V2ReadOnly(str(runtime), nonce)
            try:
                probe = peer.probe()
                owned.check(probe['scope'] == 1 and probe['server_pid'] == host.pid and len(probe['fixtures']) == 1,
                            'fixture helper scope is exactly one spawned process/window', probe)
                identity = tuple(probe['fixtures'][0])
                seen = owned.independent_snapshot(wid)
                observed = peer.inspect(identity)
                owned.check(list(identity) == seen['identity'], 'full helper and independent identities agree')
                agrees = observed['status'] == 0 and observed['owner'] == seen['owner'] and all(observed[key] == seen[key] for key in ('bounds', 'transform', 'screen_rect'))
                agrees &= seen['bounds'] == seen['screen_rect']
                if not agrees or seen != last:
                    last, stable_since = seen if agrees else None, time.monotonic()
                return seen if agrees and time.monotonic() - stable_since >= .1 else None
            finally:
                peer.close()
        original = until(5, coherent, bool, 'native original settles coherently')
        original_level = next(row['layer'] for row in owned.window_rows(0) if row['wid'] == wid and row['pid'] == host.pid)
        outcome['original_level'] = original_level
        owned.save_json(run / 'native-before.json', original)
        app_log = open(run / 'app.log', 'w'); logs.append(app_log)
        args = [str(APP), '--windowed', '1100x700', '--state', str(run / 'scene.json'), '--config', str(run / 'config.toml'), '--socket', str(socket_path), '--only-pid', str(host.pid), '--debug-pointer', '--no-hover-forwarding']
        if mode == 'native':
            args += ['--native-helper', str(runtime), str(nonce_file)]
        environment = {**os.environ, 'CFFIXED_USER_HOME': str(run / 'home'), 'INFINIFY_DEBUG': '1'}
        if mode == 'native':
            environment.update(INFINIFY_DEBUG_TEST_PANEL='1', INFINIFY_DEBUG_NATIVE_PANEL='1')
        app = subprocess.Popen(args, stdout=app_log, stderr=app_log, env=environment)
        until(8, lambda: socket_path.exists() or app.poll() is not None, bool, 'scoped app opens IPC')
        owned.check(app.poll() is None, 'scoped app remains live')
        scene = until(10, lambda: owned.state(str(socket_path)), lambda s: len(s['windows']) == 1, 'exactly one owned window adopted')
        logical = scene['windows'][0]['id']
        owned.msg(str(APP), str(socket_path), 'zoom', '0.5')
        scene = until(6, lambda: owned.state(str(socket_path)), lambda s: s['zoom'] == .5, 'half-scale zoom settles')
        camera = scene['camera']
        owned.msg(str(APP), str(socket_path), 'move', '--id', str(logical), str(round(camera[0])), str(round(camera[1])))
        settled = until(6, lambda: owned.state(str(socket_path)),
              lambda s: s['zoom'] == .5 and all(abs(a-b) < .1 for a,b in zip(s['camera'], camera))
              and s['windows'][0]['position'] == [round(camera[0]), round(camera[1])], 'owned tile settles at actual viewport center')
        time.sleep(.6)
        setup = {'scene': settled, 'original': original}
        if mode == 'capture':
            setup['capture'] = until(6, lambda: owned.ask(str(socket_path), {'DebugCapture': {'window': logical, 'phase': 'status'}})['Ok']['DebugCapture'], lambda s: s['stream'] and s['accepted'] > 0 and s['error'] is None, 'real capture pixels accepted')
        def rect():
            # No DebugPointer down/drag/up is ever issued by this scenario.
            value = owned.ask(str(socket_path), {'DebugPointer': {'phase': 'probe', 'window': logical, 'at': [1, .5], 'offset': [-2, 0]}})['Ok']['DebugPointer']
            owned.save_json(run / 'pointer-probe.json', value)
            projected = presentation_rect(value['screen_rect'])
            if mode == 'native':
                native = exact(wid, original)['screen_rect']
                owned.check(all(abs(a - b) <= 2 for a, b in zip(native, projected)), 'independent native edge agrees with presentation', (native, value))
                return native
            return projected
        initial = rect()
        owned.check(abs(initial[2] / original['bounds'][2] - .5) < .01, 'actual presented width is half the original native width', initial)
        start = [initial[0] + initial[2] - 2, initial[1] + initial[3] / 2]
        # Inward motion stays over the owned window even before the next resize
        # readback. An outward point could name an unrelated window behind it.
        delta = -24
        panel = owned.canvas_window(app.pid)
        panel_original = owned.independent_snapshot(panel['wid'])
        targets = {wid: original, panel['wid']: panel_original}
        setup.update(initial_rect=initial, start=start, delta=delta, panel=panel_original)
        owned.save_json(run / 'setup.json', setup)
        owned.save_json(run / 'cursor.json', {'original': owned.get_pointer()})
        event_source = owned.cg.CGEventSourceCreate(1)
        owned.check(bool(event_source), 'HID event source exists')
        samples = []
        def post(kind, point):
            exact(wid, original)
            exact(panel['wid'], panel_original)
            target = owned.owned_hit(point, targets)
            if kind == 1:
                owned.check(target['wid'] == (wid if mode == 'native' else panel['wid']), 'physical down reaches the exact native root or capture canvas', target)
            owned.post_mouse(event_source, kind, point)
            time.sleep(.13)
            observed = rect()
            actual_pointer = owned.get_pointer()
            samples.append({'kind': kind, 'requested_pointer': point, 'actual_pointer': actual_pointer, 'event_target': target, 'edge_rect': observed, 'native': exact(wid, original), 'edge_error': observed[0] + observed[2] - actual_pointer[0] - 2})
            owned.save_json(run / 'samples.json', samples)
        post(5, start)
        pressed = True; post(1, start)
        for step in range(1, 7):
            post(6, [start[0] + delta * step / 6, start[1]])
        post(2, [start[0] + delta, start[1]]); pressed = False
        until(5, lambda: rect(), lambda r: abs(r[0] + r[2] - start[0] - delta - 2) <= 2, 'right edge catches final physical pointer')
        trace = (run / 'app.log').read_text()
        owned.check('debug: resize grab ' in trace and 'edges=right ' in trace,
                    'physical unmodified border press enters the production resize coordinator')
        errors = [sample['edge_error'] for sample in samples if sample['kind'] in (6, 2)]
        owned.check(all(abs(error) <= 2 for error in errors), 'visible edge stays within2pt of every settled physical pointer', errors)
        outcome.update(result='PASS', identity=original['identity'], owner=original['owner'], samples=len(samples), maximum_edge_error=max(abs(error) for error in errors))
    except Exception as error:
        outcome['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        if pressed and event_source and original:
            try:
                exact(wid, original)
                event = owned.event_at(event_source, 2, owned.get_pointer())
                try:
                    owned.cg.CGEventPostToPid(host.pid, event)
                finally:
                    owned.cf.CFRelease(event)
            except Exception as error:
                outcome['release_failure'] = str(error)
        stop(app, socket_path)
        if original:
            try:
                restore_bounds(wid, original)
                until(5, lambda: exact(wid, original), lambda value: value == original, 'exact native original restored after size/position reset')
                restored_level = next(row['layer'] for row in owned.window_rows(0) if row['wid'] == wid and row['pid'] == host.pid)
                owned.check(restored_level == original_level, 'owned fixture original native level preserved', restored_level)
                peer = owned.V2ReadOnly(str(runtime), nonce)
                try:
                    probe = peer.probe()
                    inspection = peer.inspect(tuple(original['identity']))
                    owned.check(not any(probe[key] for key in ('held', 'restoring', 'table_count', 'journal_pending')),
                                'durable helper restoration is empty', probe)
                    owned.check(inspection['status'] == 0 and inspection['owner'] == original['owner'] and all(inspection[key] == original[key] for key in ('bounds', 'transform', 'screen_rect')),
                                'helper INSPECT agrees with independently restored original')
                    outcome['restoration'] = {'independent': exact(wid, original), 'probe': probe, 'inspect': inspection}
                finally:
                    peer.close()
            except Exception as error:
                outcome.update(result='FAIL', restoration_failure=str(error))
        owned.restore_cursor(run)
        if event_source:
            owned.cf.CFRelease(event_source)
        stop(host)
        outcome['children_exited'] = all(child is None or child.poll() is not None for child in (app, host))
        for log in logs:
            log.close()
        owned.save_json(run / 'result.json', outcome)
    print(json.dumps(outcome, sort_keys=True), flush=True)
    return outcome['result'] == 'PASS'


def main():
    if sys.argv[1:] != ['--live-owned-fixture']:
        print('LIVE NOT RUN: pass --live-owned-fixture for one bounded physical edge drag per owned capture/native mode.')
        return 0 if not sys.argv[1:] else 2
    if owned.preflight():
        return 3
    owned.cg.CGPreflightScreenCaptureAccess.restype = C.c_bool
    if not owned.cg.CGPreflightScreenCaptureAccess():
        print('NOT RUN: existing Screen Recording access required; no permission requested.')
        return 3
    if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
        print('NOT RUN: another Infinify instance is running.')
        return 3
    if subprocess.run(['defaults', 'read', 'com.apple.WindowManager', 'GloballyEnabled'], capture_output=True, text=True).stdout.strip() == '1':
        print('NOT RUN: Stage Manager enabled; no setting changed.')
        return 3
    owned.check(APP.is_file() and PAYLOAD.is_file(), 'delivered app and helper exist; this test does not build either')
    evidence = Path(tempfile.mkdtemp(prefix='physical-edge.', dir=ROOT / 'target/ipc'))
    evidence.chmod(0o700)
    print('Evidence:', evidence, flush=True)
    bundle = evidence / 'EdgeFixture.app'
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.infinify.physical-edge-fixture</string><key>CFBundleName</key><string>EdgeFixture</string><key>CFBundleExecutable</key><string>EdgeFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>''')
    executable = bundle / 'Contents/MacOS/EdgeFixture'
    subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=26.0', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'native/dock-helper/Client'), str(ROOT / 'tests/native/dock-helper/Payload/HostFixture.m'), '-framework', 'AppKit', '-o', str(executable)], check=True)
    manifest = json.loads((ROOT / 'target/app/BUILD.json').read_text())
    owned.check(manifest.get('schema_version') == 1, 'delivery manifest uses schema 1')
    app_hash = hashlib.sha256(APP.read_bytes()).hexdigest()
    owned.check(app_hash == manifest['executable_sha256'], 'tested app bytes match delivery manifest')
    owned.save_json(evidence / 'provenance.json', {'git_commit': manifest['git_commit'], 'app_sha256': app_hash, 'helper_sha256': hashlib.sha256(PAYLOAD.read_bytes()).hexdigest(), 'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'fixture_sha256': hashlib.sha256(executable.read_bytes()).hexdigest()})
    def interrupted(number, frame):
        del frame
        raise KeyboardInterrupt('bounded fixture interrupted: ' + str(number))
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    results = [scenario(mode, evidence, executable) for mode in ('capture', 'native')]
    return 0 if all(results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
