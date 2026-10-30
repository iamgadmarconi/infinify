#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Two separately spawned cooperative helpers on one canvas. WindowServer
reads independently check native placement and exact sibling restoration after
partial loss. No third-party application is used or implicitly enrolled.
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
    print('LIVE NOT RUN: pass --live-owned-fixture for the disposable two-helper scenario.')
    raise SystemExit(0 if len(sys.argv) == 1 else 2)
spec = importlib.util.spec_from_file_location('owned_helper', ROOT / 'tests/native/dock-helper/Payload/DWPayloadFixtureTests.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
APP = ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify'
if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
    raise SystemExit('NOT RUN: another Infinify is running.')
assert APP.is_file() and (owned.BUILD / 'host').is_file(), 'Build the app and helper first.'
(ROOT / 'target/ipc').mkdir(exist_ok=True)
evidence = Path(tempfile.mkdtemp(prefix='group.', dir=ROOT / 'target/ipc'))
print(f'Evidence: {evidence}', flush=True)
sock = evidence / 's'
hosts, wids, before, logs = [], [], {}, []
app = None
owned.sky.SLSGetWindowBounds.argtypes = [C.c_int, C.c_uint32, C.POINTER(owned.Rect)]
owned.sky.SLSGetWindowBounds.restype = C.c_int

live_helpers.exit_on_signals()

def original(wid):
    rect = owned.Rect()
    assert owned.sky.SLSGetWindowBounds(owned.sky.SLSMainConnectionID(), wid, C.byref(rect)) == 0
    return {'transform': owned.transform(wid), 'alpha': owned.alpha(wid),
            'own': [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]}

until = live_helpers.until

def ask(request):
    return live_helpers.ask(sock, request, timeout=5)

def native():
    return ask({'DebugNative': {}})['DebugNative']

def settled(zoom, camera):
    last = None
    def passed(value):
        nonlocal last
        geometry = (value['camera'], value['zoom'])
        result = geometry == last and abs(value['zoom'] - zoom) < 1e-6 and all(abs(a - b) < 1 for a, b in zip(value['camera'], camera))
        last = geometry
        return result
    return until(lambda: ask('State')['State'], passed)

try:
    endpoints = []
    for index in range(2):
        runtime = evidence / f'h{index}'
        runtime.mkdir(mode=0o700)
        host = owned.Host('--windows', '1', '--activation', 'regular', '--all-spaces', 'yes', '--watchdog', '90', run=runtime)
        hosts.append(host)
        until(host.text, lambda text: 'READY ' in text)
        windows = [int(x) for x in next(line for line in host.text().splitlines() if line.startswith('READY ')).split()[2:]]
        assert len(windows) == 1, windows
        wids.extend(windows)
        nonce = evidence / f'nonce{index}'
        with open(nonce, 'x') as file:
            os.chmod(nonce, 0o600)
            file.write(host.nonce + '\n')
        endpoints.extend(['--native-helper', str(runtime), str(nonce)])
    time.sleep(.3)
    before = {wid: original(wid) for wid in wids}
    (evidence / 'before.json').write_text(json.dumps(before, indent=2))
    config = evidence / 'config.toml'
    config.touch()
    home = evidence / 'home'
    home.mkdir()
    log = open(evidence / 'app.log', 'w')
    logs.append(log)
    app = subprocess.Popen([str(APP), '--windowed', '1100x700', '--only-pid', ','.join(str(h.child.pid) for h in hosts), '--debug-pointer', '--no-native-focus', '--no-hover-forwarding', '--config', str(config), '--socket', str(sock), '--state', str(evidence / 'state.json'), *endpoints], stdout=log, stderr=log, env={**os.environ, 'CFFIXED_USER_HOME': str(home)})
    until(lambda: sock.exists() or app.poll() is not None, bool)
    assert app.poll() is None, (evidence / 'app.log').read_text()
    initial = until(lambda: ask('State')['State'], lambda value: len(value['windows']) == 2 and not any(w['suspended'] for w in value['windows']))
    checked = until(native, lambda value: len(value.get('sessions', [])) == 2 and len(value['records']) == 2 and value['probe'] and value['probe']['frames_applied'] > 0)
    assert checked['group'] and not checked['ended'], checked
    for host, wid in zip(hosts, wids):
        sessions = [s for s in checked['sessions'] if s['server_pid'] == host.child.pid]
        assert len(sessions) == 1 and {r['wid'] for r in sessions[0]['records']} == {wid}, checked
    time.sleep(.5)
    current = ask('State')['State']
    camera = [current['camera'][0] + 83, current['camera'][1] - 47]
    ask({'Camera': camera})
    settled(current['zoom'], camera)
    phases = []
    for zoom in (.5, .85):
        ask({'Zoom': zoom})
        settled(zoom, camera)
        checked = until(native, lambda value, zoom=zoom: len(value['records']) == 2 and all(abs(r['m'][0] - 1 / zoom) < 1e-6 for r in value['records']))
        assert all(s['stats']['records_failed'] == 0 for s in checked['sessions']), checked
        until(lambda: [owned.transform(w) for w in wids], lambda values, zoom=zoom: all(abs(v[0] - 1 / zoom) < 1e-6 for v in values))
        assert all(original(w)['own'] == before[w]['own'] for w in wids)
        phases.append({'zoom': zoom, 'camera': camera, 'transforms': [owned.transform(w) for w in wids], 'rectangles': [owned.screen(w) for w in wids], 'sessions': checked['sessions']})
    hosts[0].stop()
    until(native, lambda value: value['ended'])
    until(lambda: original(wids[1]), lambda value: value == before[wids[1]], seconds=4)
    assert app.poll() is None, 'Helper loss killed the responsive canvas.'
    ask('State')
    ask({'Action': 'quit'})
    app.wait(timeout=6)
    assert original(wids[1]) == before[wids[1]]
    (evidence / 'result.json').write_text(json.dumps({'status': 'PASS', 'scope': 'two newly spawned cooperative fixture processes', 'phases': phases, 'sibling_exact_restoration_after_partial_loss': True, 'ipc_responsive_after_loss': True}, indent=2))
    print('PASS: two explicit helpers route separately; partial loss restores the sibling exactly and IPC stays responsive.', flush=True)
finally:
    if app and app.poll() is None:
        app.terminate()
        try:
            app.wait(timeout=6)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    try:
        for host, wid in zip(hosts, wids):
            if host.child.poll() is None and wid in before:
                until(lambda wid=wid: original(wid), lambda value, wid=wid: value == before[wid], seconds=3)
    finally:
        for host in owned.hosts:
            host.stop()
        for log in logs:
            log.close()
