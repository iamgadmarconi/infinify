#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One root, popup and sheet through the native desktop. Only spawned windows
are enrolled; geometry, transforms and alpha are read on an independent
WindowServer connection. This does not establish third-party application support.
"""
import ctypes as C
import importlib.util
import json
import math
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
export_images = sys.argv[1:] == ['--live-owned-export']
if sys.argv[1:] != ['--live-owned-fixture'] and not export_images:
    print('LIVE NOT RUN: pass --live-owned-fixture or --live-owned-export for the disposable popup/sheet scenario.')
    raise SystemExit(0 if len(sys.argv) == 1 else 2)
spec = importlib.util.spec_from_file_location('owned_helper', ROOT / 'native/privileged/fixture_test.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
APP = ROOT / 'target/app/Infinify.app/Contents/MacOS/Infinify'
if subprocess.run(['pgrep', '-f', 'Infinify.app/Contents/MacOS/Infinify'], capture_output=True).returncode == 0:
    raise SystemExit('NOT RUN: another Infinify is running.')
stage = subprocess.run(['defaults', 'read', 'com.apple.WindowManager', 'GloballyEnabled'], capture_output=True, text=True)
if stage.returncode == 0 and stage.stdout.strip() == '1':
    raise SystemExit('NOT RUN: Stage Manager is enabled.')
assert APP.is_file() and (owned.BUILD / 'host').is_file(), 'Build the app and helper first.'
(ROOT / 'target/ipc').mkdir(exist_ok=True)
evidence = Path(tempfile.mkdtemp(prefix='family.', dir=ROOT / 'target/ipc'))
print(f'Evidence: {evidence}', flush=True)
runtime = evidence / 'h'
runtime.mkdir(mode=0o700)
sock = evidence / 's'
host = app = before = None
log = None
live_helpers.exit_on_signals()

owned.sky.SLSGetWindowBounds.argtypes = [C.c_int, C.c_uint32, C.POINTER(owned.Rect)]
owned.sky.SLSGetWindowBounds.restype = C.c_int
owned.cg.CGRectMakeWithDictionaryRepresentation.argtypes = [C.c_void_p, C.POINTER(owned.Rect)]
owned.cg.CGRectMakeWithDictionaryRepresentation.restype = C.c_bool
K_PID = owned.cf.CFStringCreateWithCString(None, b'kCGWindowOwnerPID', 0x08000100)
K_BOUNDS = owned.cf.CFStringCreateWithCString(None, b'kCGWindowBounds', 0x08000100)

def own(wid):
    rect = owned.Rect()
    assert owned.sky.SLSGetWindowBounds(owned.sky.SLSMainConnectionID(), wid, C.byref(rect)) == 0
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]

def ask(request):
    return live_helpers.ask(sock, request, timeout=4)

until = live_helpers.until

def panel():
    rows = owned.cg.CGWindowListCopyWindowInfo(1, 0)
    assert rows
    matches = []
    try:
        for i in range(owned.cf.CFArrayGetCount(rows)):
            row = owned.cf.CFArrayGetValueAtIndex(rows, i)
            pid = C.c_longlong(0)
            owned.cf.CFNumberGetValue(owned.cf.CFDictionaryGetValue(row, K_PID), 4, C.byref(pid))
            if pid.value != app.pid:
                continue
            rect = owned.Rect()
            assert owned.cg.CGRectMakeWithDictionaryRepresentation(owned.cf.CFDictionaryGetValue(row, K_BOUNDS), C.byref(rect))
            if rect.size.width == 1100 and rect.size.height == 700:
                matches.append([rect.origin.x, rect.origin.y, rect.size.width, rect.size.height])
    finally:
        owned.cf.CFRelease(rows)
    assert len(matches) == 1, matches
    return matches[0]

def original(wid):
    return {'screen': owned.screen(wid), 'own': own(wid), 'transform': owned.transform(wid), 'alpha': owned.alpha(wid)}

def settled(zoom, camera):
    last = None
    def read():
        return ask('State')['State']
    def passed(now):
        nonlocal last
        value = (now['camera'], now['zoom'], [(w['position'], w['size']) for w in now['windows']])
        stable = value == last and abs(now['zoom'] - zoom) < 1e-6 and all(abs(a - b) < 1 for a, b in zip(now['camera'], camera))
        last = value
        return stable
    return until(read, passed)

try:
    host = owned.Host('--windows', '1', '--activation', 'regular', '--all-spaces', 'yes', '--family', 'both', '--watchdog', '90', run=runtime)
    until(host.text, lambda text: 'READY ' in text)
    wids = [int(x) for x in next(line for line in host.text().splitlines() if line.startswith('READY ')).split()[2:]]
    assert len(wids) == 3, wids
    time.sleep(.4)
    before = {str(w): original(w) for w in wids}
    (evidence / 'before.json').write_text(json.dumps(before, indent=2))
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
    initial = until(lambda: ask('State')['State'], lambda state: len(state['windows']) == 1 and not state['windows'][0]['suspended'])
    logical = initial['windows'][0]['id']
    native = until(lambda: ask({'DebugNative': {}})['DebugNative'], lambda value: len(value['records']) == 3)
    assert {row['wid'] for row in native['records']} == set(wids) and {row['window'] for row in native['records']} == {logical}, native
    assert native['stats']['records_failed'] == 0, native
    # Let startup focus observations settle before asking for camera animations.
    time.sleep(1)
    current = ask('State')['State']
    camera = [current['camera'][0] + 83, current['camera'][1] - 47]
    ask({'Camera': camera})
    settled(current['zoom'], camera)
    rows = []
    exports = []
    for zoom in (.5, .85):
        reply = ask({'Zoom': zoom})
        assert reply == {'Zoom': zoom}, reply
        now = settled(zoom, camera)
        ox, oy, width, height = panel()
        root = now['windows'][0]
        px, py = root['position']
        sw, sh = root['size']
        left = ox + width / 2 + (px - sw // 2 - now['camera'][0]) * zoom
        top = oy + height / 2 + (-py - sh // 2 + now['camera'][1]) * zoom
        original_root = before[str(wids[0])]['own']
        expected = [[left + (before[str(w)]['own'][0] - original_root[0]) * zoom, top + (before[str(w)]['own'][1] - original_root[1]) * zoom, before[str(w)]['own'][2] * zoom, before[str(w)]['own'][3] * zoom] for w in wids]
        owned.wait_rects(wids, expected, 3)
        assert all(own(w) == before[str(w)]['own'] for w in wids), [own(w) for w in wids]
        rows.append({'zoom': zoom, 'camera': now['camera'], 'independent_rectangles': [owned.screen(w) for w in wids], 'expected': expected})
        if export_images:
            # The canvas screenshot rectangle comes from independent native
            # root/child bounds and the public State's world geometry.
            world = [[px - sw // 2 + (before[str(w)]['own'][0] - original_root[0]) * sw / original_root[2],
                      -py - sh // 2 + (before[str(w)]['own'][1] - original_root[1]) * sh / original_root[3],
                      before[str(w)]['own'][2] * sw / original_root[2],
                      before[str(w)]['own'][3] * sh / original_root[3]] for w in wids]
            left = math.floor(min(r[0] for r in world)) - 24
            top = math.floor(min(r[1] for r in world)) - 24
            wide = math.ceil(max(r[0] + r[2] for r in world)) + 24 - left
            high = math.ceil(max(r[1] + r[3] for r in world)) + 24 - top
            wide += wide % 2
            high += high % 2
            path = evidence / f'family-{zoom}.png'
            unchanged = {str(w): original(w) for w in wids}
            result = subprocess.run([str(APP), 'msg', '--socket', str(sock), 'screenshot', '--scale', '1', '-o', str(path), 'region', str(left + wide // 2), str(-top - high // 2), str(wide), str(high)], capture_output=True, text=True, timeout=6)
            assert result.returncode == 0 and path.is_file(), (result.stdout, result.stderr, (evidence / 'app.log').read_text())
            png_spec = importlib.util.spec_from_file_location('png_bytes', ROOT / 'tests/e2e/png_pixels.py')
            png = importlib.util.module_from_spec(png_spec)
            png_spec.loader.exec_module(png)
            pixels = png.pixels(path, (wide, high))
            colors = []
            for index, color in ((1, 'orange'), (2, 'blue')):
                found = []
                for y, row in enumerate(pixels):
                    for x in range(wide):
                        r, g, b, alpha = row[x * 4:x * 4 + 4]
                        # AppKit's semantic colors depend on appearance and the
                        # saved color profile; identify hue rather than brightness.
                        matches = r > 50 and r > g * 1.4 and g > b * 1.4 if color == 'orange' else r < 100 and g < 190 and b > 190
                        if matches and alpha > 220:
                            found.append((x, y))
                target = [world[index][0] - left, world[index][1] - top, *world[index][2:]]
                assert len(found) > target[2] * target[3] * .25, ('missing child pixels', color, len(found), target)
                assert all(target[0] - 2 <= x < target[0] + target[2] + 2 and target[1] - 2 <= y < target[1] + target[3] + 2 for x, y in found), ('misplaced child pixels', color, target)
                bounds = [min(x for x, y in found), min(y for x, y in found), max(x for x, y in found) + 1, max(y for x, y in found) + 1]
                colors.append({'child': color, 'pixels': len(found), 'bounds': bounds, 'independently_expected_rect': target})
            assert {str(w): original(w) for w in wids} == unchanged, 'Export mutated live native geometry.'
            exports.append({'zoom': zoom, 'file': str(path), 'size': [wide, high], 'child_pixels': colors, 'live_native_geometry_unchanged': True})
    ask({'Action': 'quit'})
    app.wait(timeout=6)
    until(lambda: {str(w): original(w) for w in wids}, lambda value: value == before, seconds=3)
    (evidence / 'result.json').write_text(json.dumps({'scope': 'one owned root, popup and sheet; no foreign applications', 'placements': rows, 'exports': exports, 'exact_restoration': True}, indent=2))
    print(json.dumps({'status': 'PASS', 'placements': rows, 'exports': exports, 'exact_restoration': True}, indent=2), flush=True)
finally:
    if app and app.poll() is None:
        try:
            ask({'Action': 'quit'})
            app.wait(timeout=6)
        except Exception:
            app.terminate()
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
    # Disconnect restoration gets its bounded chance before removing the host.
    try:
        if host and before and host.child.poll() is None:
            until(lambda: {str(w): original(w) for w in wids}, lambda value: value == before, seconds=3)
    finally:
        for child in owned.hosts:
            child.stop()
    if log:
        log.close()
    owned.cf.CFRelease(K_PID)
    owned.cf.CFRelease(K_BOUNDS)
