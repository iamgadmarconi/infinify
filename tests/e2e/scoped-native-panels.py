#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise a new owned floating utility panel beside a normal native root.
Independent WindowServer reads check fixed panel placement through camera pan
and zoom, and exact transform/alpha restoration. No third-party window is used.
"""
import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
if sys.argv[1:] != ['--live-owned-fixture']:
    print('LIVE NOT RUN: pass --live-owned-fixture for the disposable floating-panel scenario.')
    raise SystemExit(0 if len(sys.argv) == 1 else 2)
spec = importlib.util.spec_from_file_location('owned_helper', ROOT / 'native/privileged/fixture_v2_test.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
APP = ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify'
if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
    raise SystemExit('NOT RUN: another Infinify is running.')
assert APP.is_file() and (owned.BUILD / 'host').is_file(), 'Build the app and helper first.'
(ROOT / 'target/ipc').mkdir(exist_ok=True)
evidence = Path(tempfile.mkdtemp(prefix='panel.', dir=ROOT / 'target/ipc'))
print(f'Evidence: {evidence}', flush=True)
runtime = evidence / 'h'
runtime.mkdir(mode=0o700)
sock = evidence / 's'
host = app = before = log = None
owned.sky.SLSGetWindowBounds.argtypes = [C.c_int, C.c_uint32, C.POINTER(owned.Rect)]
owned.sky.SLSGetWindowBounds.restype = C.c_int

def interrupted(number, _frame):
    raise SystemExit(128 + number)

for number in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, interrupted)

def own(wid):
    rect = owned.Rect()
    assert owned.sky.SLSGetWindowBounds(owned.sky.SLSMainConnectionID(), wid, C.byref(rect)) == 0
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]

def originals():
    return {str(w): {'transform': owned.transform(w), 'alpha': owned.alpha(w)} for w in wids}

def ask(request):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(4)
        connection.connect(str(sock))
        connection.sendall((json.dumps(request) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data)
    assert 'Ok' in reply, reply
    return reply['Ok']

def until(read, passed, seconds=8):
    deadline = time.monotonic() + seconds
    while True:
        value = read()
        if passed(value):
            return value
        assert time.monotonic() < deadline, value
        time.sleep(.05)

def state():
    return ask('State')['State']

try:
    host = owned.Host('--windows', '2', '--floating-panel', 'yes', '--activation', 'regular', '--all-spaces', 'yes', '--watchdog', '90', run=runtime)
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
    config.touch()
    home = evidence / 'home'
    home.mkdir()
    log = open(evidence / 'app.log', 'w')
    app = subprocess.Popen([str(APP), '--windowed', '1100x700', '--only-pid', str(host.child.pid), '--debug-pointer', '--no-native-focus', '--no-hover-forwarding', '--config', str(config), '--socket', str(sock), '--state', str(evidence / 'state.json'), '--native-helper', str(runtime), str(nonce)], stdout=log, stderr=log, env={**os.environ, 'CFFIXED_USER_HOME': str(home)})
    until(lambda: sock.exists() or app.poll() is not None, bool)
    assert app.poll() is None, (evidence / 'app.log').read_text()
    initial = until(state, lambda value: len(value['windows']) == 1 and len(value['pinned']) == 1 and not any(w['suspended'] for w in value['windows']))
    assert initial['pinned'][0]['title'] == 'DriftWM disposable independent floating panel', initial
    native = until(lambda: ask({'DebugNative': {}})['DebugNative'], lambda value: len(value['records']) == 2 and value['probe']['frames_applied'] > 0)
    fixed = wids[-1]
    pin = initial['pinned'][0]
    pin_before = {'transform': owned.transform(fixed), 'screen': owned.screen(fixed), 'own': own(fixed)}
    root_before = owned.transform(wids[0])
    camera = [initial['camera'][0] + 83, initial['camera'][1] - 47]
    ask({'Camera': camera})
    until(state, lambda value: all(abs(a - b) < 1 for a, b in zip(value['camera'], camera)))
    phases = []
    for zoom in (.5, .85):
        ask({'Zoom': zoom})
        until(state, lambda value: abs(value['zoom'] - zoom) < 1e-6 and all(abs(a - b) < 1 for a, b in zip(value['camera'], camera)))
        until(lambda: ask({'DebugNative': {}})['DebugNative'], lambda value: value['stats']['records_failed'] == 0 and any(r['wid'] == wids[0] and abs(r['m'][0] - 1 / zoom) < 1e-6 for r in value['records']))
        until(lambda: owned.transform(wids[0]), lambda value: abs(value[0] - 1 / zoom) < 1e-6)
        current = {'transform': owned.transform(fixed), 'screen': owned.screen(fixed), 'own': own(fixed)}
        assert current == pin_before, ('panel moved', pin_before, current)
        assert own(wids[0]) == native_before[0], 'Canvas motion changed native root geometry.'
        assert owned.transform(wids[0]) != root_before, 'The normal root did not follow the canvas.'
        now = state()
        assert now['pinned'] == [pin], now
        phases.append({'zoom': zoom, 'camera': camera, 'fixed_panel': current, 'root_transform': owned.transform(wids[0])})
    ask({'Action': 'quit'})
    app.wait(timeout=6)
    until(originals, lambda value: value == before, seconds=3)
    assert [own(w) for w in wids] == native_before
    result = {'status': 'PASS', 'scope': 'two newly spawned owned windows', 'pinned_panel': pin, 'phases': phases, 'exact_transform_alpha_bounds_restoration': True}
    (evidence / 'result.json').write_text(json.dumps(result, indent=2))
    print('PASS: independent native utility panel remains display-fixed through pan/zoom; exact restoration.', flush=True)
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
