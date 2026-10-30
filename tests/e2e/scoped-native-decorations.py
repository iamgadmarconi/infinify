#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the native green-control handler on newly spawned owned windows.
Actual AX control bounds and independent WindowServer size/restore reads are
required. Events call the bridge directly; this does not prove OS delivery or
third-party application compatibility. Nothing is posted to global input.
"""
import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import live_helpers  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
if sys.argv[1:] != ['--live-owned-fixture']:
    print('LIVE NOT RUN: pass --live-owned-fixture for the disposable green-control scenario.')
    raise SystemExit(0 if len(sys.argv) == 1 else 2)
spec = importlib.util.spec_from_file_location('owned_helper', ROOT / 'tests/native/dock-helper/Payload/DWPayloadFixtureTests.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
APP = ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify'
if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
    raise SystemExit('NOT RUN: another Infinify is running.')
assert APP.is_file() and (owned.BUILD / 'host').is_file(), 'Build the app and helper first.'
(ROOT / 'target/ipc').mkdir(exist_ok=True)
evidence = Path(tempfile.mkdtemp(prefix='green.', dir=ROOT / 'target/ipc'))
print(f'Evidence: {evidence}', flush=True)
runtime = evidence / 'h'
runtime.mkdir(mode=0o700)
sock = evidence / 's'
host = app = before = log = None
owned.sky.SLSGetWindowBounds.argtypes = [C.c_int, C.c_uint32, C.POINTER(owned.Rect)]
owned.sky.SLSGetWindowBounds.restype = C.c_int

live_helpers.exit_on_signals()

def own(wid):
    rect = owned.Rect()
    assert owned.sky.SLSGetWindowBounds(owned.sky.SLSMainConnectionID(), wid, C.byref(rect)) == 0
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]

def originals():
    return {str(w): {'transform': owned.transform(w), 'alpha': owned.alpha(w)} for w in wids}

def ask(request):
    return live_helpers.ask(sock, request, timeout=4)

until = live_helpers.until

def state():
    return ask('State')['State']

def green(logical, action='fullscreen'):
    request = {'window': logical, 'phase': 'probe', 'action': action}
    probe = until(lambda: ask({'DebugDecoration': request})['DebugDecoration'], lambda value: value['ready'])
    (evidence / 'last-probe.json').write_text(json.dumps(probe, indent=2))
    request['phase'] = 'click'
    click = ask({'DebugDecoration': request})['DebugDecoration']
    assert click['ready'] and click['handler_only'], click
    return probe

try:
    host = owned.Host('--windows', '2', '--activation', 'regular', '--all-spaces', 'yes', '--watchdog', '90', run=runtime)
    until(host.text, lambda text: 'READY ' in text)
    wids = [int(x) for x in next(line for line in host.text().splitlines() if line.startswith('READY ')).split()[2:]]
    assert len(wids) == 2, wids
    time.sleep(.3)
    before = originals()
    native_before = [own(w) for w in wids]
    (evidence / 'before.json').write_text(json.dumps({'originals': before, 'native_bounds': native_before}, indent=2))
    nonce = evidence / 'nonce'
    with open(nonce, 'x') as file:
        os.chmod(nonce, 0o600)
        file.write(host.nonce + '\n')
    config = evidence / 'config.toml'
    config.write_text('[snap]\nouter_gap = 16\n')
    home = evidence / 'home'
    home.mkdir()
    log = open(evidence / 'app.log', 'w')
    app = subprocess.Popen([str(APP), '--windowed', '1100x700', '--only-pid', str(host.child.pid), '--debug-pointer', '--no-native-focus', '--no-hover-forwarding', '--config', str(config), '--socket', str(sock), '--state', str(evidence / 'state.json'), '--native-helper', str(runtime), str(nonce)], stdout=log, stderr=log, env={**os.environ, 'CFFIXED_USER_HOME': str(home)})
    until(lambda: sock.exists() or app.poll() is not None, bool)
    assert app.poll() is None, (evidence / 'app.log').read_text()
    initial = until(state, lambda value: len(value['windows']) == 2 and not any(w['suspended'] for w in value['windows']))
    logical = initial['windows'][0]['id']
    until(lambda: ask({'DebugNative': {}})['DebugNative'], lambda value: len(value['records']) == 2 and value['probe']['frames_applied'] > 0)
    # Initial adoption can fly the camera; do not click a moving control.
    last = None
    def stationary(value):
        global last
        pose = (value['camera'], value['zoom'])
        stable = last == pose
        last = pose
        return stable
    until(state, stationary)
    rows = []
    for action, mode, size in [('fullscreen', 'Fullscreen', [1100, 700]), ('fullscreen', 'Normal', native_before[0][2:]), ('fit', 'Fit', [1068, 668]), ('fit', 'Normal', native_before[0][2:])]:
        probe = green(logical, action)
        target = probe['identity']['wid']
        assert target in wids, probe
        def arrived(value, mode=mode, target=target, size=size):
            if mode == 'Fullscreen':
                return any(w['id'] == logical for w in value['fullscreen']) and own(target)[2:] == size
            window = next((w for w in value['windows'] if w['id'] == logical), None)
            return window and window['mode'] == mode and window['size'] == size
        current = until(state, arrived)
        native = until(lambda target=target: own(target), lambda value, size=size: value[2:] == size)
        assert all(own(w) == native_before[i] for i, w in enumerate(wids) if w != target), 'The second window changed.'
        rows.append({'action': action, 'mode': mode, 'native_bounds': native, 'green_control': probe})
    ask({'Action': 'quit'})
    app.wait(timeout=6)
    until(originals, lambda value: value == before, seconds=3)
    result = {'status': 'PASS', 'scope': 'two newly spawned owned windows', 'handler_only': True, 'phases': rows, 'exact_transform_alpha_restoration': True}
    (evidence / 'result.json').write_text(json.dumps(result, indent=2))
    print('PASS: green fullscreen/restore, Option fit/restore; independent native sizes and exact transform/alpha restoration.', flush=True)
finally:
    if app and app.poll() is None:
        app.terminate()
        try:
            app.wait(timeout=6)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    try:
        if host and before and host.child.poll() is None:
            until(originals, lambda value: value == before, seconds=3)
    finally:
        for child in owned.hosts:
            child.stop()
        if log:
            log.close()
