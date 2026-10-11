#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# DriftWM's sizing actions, `msg resize`, a window rule's size and toggle-fullscreen on real windows, in a normal run with no
# flag: disposable fixture applications are started, Infinify manages exactly those (`--only-pid`), each size is asked through
# the socket, and the fixture itself says what size its window then has. The canvas must agree with it, whatever the
# application made of the request (a minimum, a maximum, a resize increment), and no request may leave a window that refuses
# a press: after each step a click is made on the window's tile and must land in the window. One window sits where a larger size
# does not fit its screen: its real window must be moved to make room, and its place on the canvas must not.
#
# It runs with or without Screen Recording access; without it the tiles have no picture and everything here is the same.
# Everything acted on is a process this script started, as in tests/e2e/scoped-windows.sh, whose conventions these are: the
# clicks take the foreground, the pointer is never moved and nothing is posted at the session level. Run it while nothing
# else needs the keyboard.
#
# Not run here: a launch without a scope (scoped-windows.sh makes that one) and the chords themselves, which no test can
# press; the bindings trace says that they are registered where a run registers any.
#
# Exit status: 0 everything was checked and held; 1 something failed; 2 usage; 3 nothing failed and nothing was checked,
# because Stage Manager is on (NOT RUN).
# INFINIFY_E2E_ELECTRON=/path/to/Electron (a generic Electron binary) adds an Electron window; unset, that case is skipped.
set -eu
cd "$(dirname "$0")/../.."
[ "$#" -ne 0 ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to validate disposable sizing windows'; exit 0; }
[ "$#" -eq 1 ] && [ "$1" = --live-owned-fixture ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }
root=$PWD
# Stage Manager keeps every window outside the current set as a thumbnail at the side, a fixture's among them: nothing here
# could be adopted or clicked, and the run would take the foreground only to fail on that. The setting is read, never written.
[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" != 1 ] || { echo 'NOT RUN: Stage Manager is on (com.apple.WindowManager GloballyEnabled is 1); nothing was started and nothing was checked. Run it with Stage Manager off.'; exit 3; }
app=$root/target/app/Infinify.app/Contents/MacOS/Infinify
[ -x "$app" ] || ./scripts/build-app.sh
mkdir -p target/ipc
# Short: a socket path has room for about a hundred bytes.
evidence=$(mktemp -d "$root/target/ipc/size.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
state=$evidence/state.json; config=$evidence/config.toml; socket=$evidence/s
infinify=; fixtures=
quit() {
  [ -n "$infinify" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 80 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify" 2>/dev/null; then kill "$infinify" 2>/dev/null || true; gone=no; else gone=yes; fi
  wait "$infinify" 2>/dev/null || true; infinify=
}
# Only what this script started is ever signalled.
cleanup() { quit; for pid in $fixtures; do kill "$pid" 2>/dev/null || true; done; for pid in $fixtures; do wait "$pid" 2>/dev/null || true; done; rm -rf "$evidence/electron-data"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# The step and the gaps are named so that every number below is the config's, not a default's. The rule sizes the one
# window whose title it names, which appears while Infinify runs.
cat > "$config" <<TOML
[navigation]
resize_step = 30
[snap]
gap = 12
outer_gap = 16
[[window_rules]]
title = "Size rule R $$"
size = [480, 360]
TOML

bundle=$evidence/ScopeFixture.app
mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.infinify.scope-fixture</string><key>CFBundleName</key><string>ScopeFixture</string><key>CFBundleExecutable</key><string>ScopeFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror native/fixture/scope-fixture.m \
  -framework AppKit -framework WebKit -o "$bundle/Contents/MacOS/ScopeFixture"
fixture=$bundle/Contents/MacOS/ScopeFixture
start() { name=$1; title=$2; dx=$3; shift 3; mkdir "$evidence/$name"; "$fixture" "$evidence/$name" "$title" "$dx" 280 "$@" & fixtures="$fixtures $!"; }
start a "Size fixture A $$" -300 resizable; A=$!
start b "Size fixture B $$" 0 resizable min 300x260 max 640x520; B=$!
start c "Size fixture C $$" 300 resizable increment 37x23; C=$!
start r "Size rule R $$" 0 resizable hidden; R=$!
# Shown together, late (case 23).
start n "Size pair N $$" -200 resizable hidden; N=$!
start m "Size pair M $$" 200 resizable hidden; M=$!
# Low and to the right, 40 points inside the visible area's corner: from there no larger size fits the screen (case 19).
start d "Size fixture D $$" 0 resizable corner 40x40; D=$!
# Out of scope and exactly as scoped-windows.sh starts it: four arguments, so none of the sizing test's commands apply to it.
mkdir "$evidence/z"; "$fixture" "$evidence/z" "Size decoy Z $$" 150 120 & Z=$!; fixtures="$fixtures $Z"
E=
if [ -n "${INFINIFY_E2E_ELECTRON:-}" ]; then
  [ -x "$INFINIFY_E2E_ELECTRON" ] || { echo "INFINIFY_E2E_ELECTRON is not an executable: $INFINIFY_E2E_ELECTRON" >&2; exit 2; }
  mkdir "$evidence/e" "$evidence/electron-data"
  SCOPE_DIR=$evidence/e SCOPE_TITLE="Size Electron $$" SCOPE_SECONDS=280 SCOPE_DY=-90 "$INFINIFY_E2E_ELECTRON" "$root/tests/e2e/scoped-electron" "--user-data-dir=$evidence/electron-data" >"$evidence/electron.log" 2>&1 &
  E=$!; fixtures="$fixtures $E"
else
  echo 'SKIPPED: Electron case, INFINIFY_E2E_ELECTRON is unset'
fi

cat > "$evidence/driver.py" <<'PY'
import json, os, pathlib, re, socket, subprocess, sys, time
evidence = pathlib.Path(sys.argv[1]); app = sys.argv[2]; phase = sys.argv[3]
sock = str(evidence / 's'); errlog = evidence / 'err.log'
def ok(what, observed): print(f'ok: {what}: {observed}', flush=True)
def fail(what, observed):
    print(f'FAIL: {what}: {observed}', flush=True)
    for line in trace()[-25:]: print(f'    {line}', flush=True)
    sys.exit(1)
def check(what, passed, observed): (ok if passed else fail)(what, observed)
def status(name):
    for _ in range(40):
        try: return json.loads((evidence / name / 'status.json').read_text())
        except (OSError, ValueError): time.sleep(.05)
    fail(f'fixture {name} reports', 'no status.json')
def until(what, seconds, read, passed):
    end = time.time() + seconds
    while True:
        value = read()
        if passed(value): return value
        if time.time() > end: fail(what, value)
        time.sleep(.02)
def ask(request):
    s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sock); s.sendall((json.dumps(request) + '\n').encode())
    data = b''
    while not data.endswith(b'\n'):
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    s.close(); return json.loads(data)
def msg(*args):
    # A request that hangs must not hold the driver, and the foreground with it, until the fixtures' own cap.
    try: return subprocess.run([app, 'msg', '--socket', sock, *args], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired: fail('msg ' + ' '.join(args), 'no answer within 10 s')
def trace(): return errlog.read_text(errors='replace').splitlines()
def native(name): return status(name)['bounds'][2:]

if phase == 'quit':
    # Infinify is gone. A window it left fullscreen has the size it had before, and the decoy is as it was.
    want = json.loads((evidence / 'before-quit.json').read_text())
    got = until('a window left fullscreen has its size back after quit', 3, lambda: native('a'), lambda size: size == want['a'])
    ok('a window left fullscreen has its size back after quit', {'before fullscreen': want['a'], 'after quit': got})
    z = status('z'); check('decoy untouched to the end', z['bounds'] == want['z']['bounds'] and z['counts'] | {'raf': 0} == want['z']['counts'] | {'raf': 0} and z['activations'] == 0, {'bounds': z['bounds'], 'activations': z['activations']})
    lines = trace()
    check('no press or tile was ever refused as unsettled', not any('source presentation unsettled' in l for l in lines), [l for l in lines if 'unsettled' in l])
    sys.exit(0)

infinify = int(sys.argv[4]); electron = len(sys.argv) > 5 and sys.argv[5] == 'electron'
scope = ['a', 'b', 'c', 'd'] + (['e'] if electron else [])
if electron: until('Electron fixture has a window', 15, lambda: status('e'), lambda r: r.get('window'))
decoy = status('z')
def State(): return ask('State')['Ok']['State']
def windows(): return State()['windows']
titles = sorted(status(n)['title'] for n in scope)
adopted = until('adopts exactly the scope', 8, windows, lambda w: sorted(x['title'] for x in w) == titles)
ok('adopts exactly the scope', [(w['id'], w['title'], w['size']) for w in adopted])
managing = [l for l in trace() if l.startswith('Managing only')]
ok('Screen Recording', 'not granted: tiles have no picture' if 'No Screen Recording access' in managing[0] else 'granted: tiles are captured')
ids = {n: next(w['id'] for w in adopted if w['title'] == status(n)['title']) for n in scope}
def entry(name): return next((w for w in windows() if w['id'] == ids[name]), None)
# The world frame of a canvas window, exactly: State gives the center, Y-up, by upstream's truncating halving.
def frame(name):
    w = entry(name)
    return None if w is None else [w['position'][0] - w['size'][0] // 2, -w['position'][1] - w['size'][1] // 2, w['size'][0], w['size'][1]]
def mode(name): return entry(name)['mode']
def close(a, b, tol): return a is not None and b is not None and all(abs(x - y) <= tol for x, y in zip(a, b))
# The canvas and the window agree on the window's size, which is `want` when one is named. Three seconds, and what was seen.
def agreed(what, name, want=None, tol=0, seconds=3):
    def read(): return {'native': native(name), 'canvas': (frame(name) or [None] * 4)[2:]}
    seen = until(what, seconds, read, lambda v: close(v['canvas'], v['native'], tol) and (want is None or close(v['native'], want, tol)))
    ok(what, seen); return seen['native']
def action(text): return ask({'Action': text})
def acted(text):
    reply = action(text)
    if 'Ok' not in reply: fail(f'action {text}', reply)
def resize(name, w, h): return msg('resize', '--id', str(ids[name]), str(int(w)), str(int(h)))
def resized(name, w, h):
    done = resize(name, w, h)
    if done.returncode: fail(f'msg resize {name} {w} {h}', done.stderr.strip() or done.stdout.strip())
def place(name, x, y):
    done = msg('move', '--id', str(ids[name]), str(int(x)), str(int(y)))
    if done.returncode: fail(f'msg move {name}', done.stderr.strip())
def pointer(phase, window, at): return ask({'DebugPointer': {'phase': phase, 'window': window, 'at': at}})
def near(a, b): return a is not None and abs(a[0] - b[0]) <= 2 and abs(a[1] - b[1]) <= 2
def tile(name, what):
    reply = until(f'{what}: the tile of {name} is on the canvas', 3, lambda: pointer('probe', ids[name], [.5, .5]), lambda r: 'Ok' in r)
    r = reply['Ok']['DebugPointer']['screen_rect']; return [r['origin']['x'], r['origin']['y'], r['size']['width'], r['size']['height']]
# A click as a person makes it, on the window's plain view (its page, for Electron): it must land once, within two points of
# the middle of that view as the window lays it out at the size it has now. This is the check that no size request leaves a
# window whose input is refused.
def clicked(name, what):
    control = 'web' if name == 'e' else 'plain'; kinds = ['web_down', 'web_up'] if name == 'e' else ['plain_down', 'plain_up']
    report = status(name); x, y, w, h = report['controls'][control]; want = [x + w / 2, y + h / 2]
    at = [want[0] / report['bounds'][2], want[1] / report['bounds'][3]]; before = report['counts']; start = len(trace()); window = ids[name]
    reply = pointer('down', window, at)
    if 'Ok' not in reply: fail(f'{what}: press on the tile of {name}', reply)
    delivered = lambda: [l for l in trace()[start:] if l.startswith(f'debug: press #{window} delivered')]
    until(f'{what}: press on {name} is delivered', 3, delivered, bool)
    reply = pointer('up', window, at)
    if 'Ok' not in reply: fail(f'{what}: release on the tile of {name}', reply)
    def read(): r = status(name); return {'delta': {k: r['counts'][k] - before[k] for k in kinds}, 'last': {k: r['last'].get(k) for k in kinds}, 'want': want}
    until(f'{what}: the click on {name} arrives', 3, read, lambda v: all(d >= 1 for d in v['delta'].values())); time.sleep(.25); seen = read()
    check(f'{what}: a click on the tile of {name} lands once, within 2 points', all(d == 1 for d in seen['delta'].values()) and all(near(p, want) for p in seen['last'].values()), seen)
def resizes(since, name=None):
    pid = status(name)['pid'] if name else None
    return [l for l in trace()[since:] if l.startswith('debug: native resize ') and (pid is None or f' pid={pid} ' in l)]
# Every answer of the native adapter for a window since then: its setters' and its reads'.
def answers(since, name):
    pid = status(name)['pid']; return [l for l in trace()[since:] if l.startswith(('debug: native resize ', 'debug: native size read ')) and f' pid={pid} ' in l]

# 1. The chords. A windowed run registers no hot key, so what is checked is what a run that registers them reads: the
# binding table marks Control-Option-M and Control-Option-F as bindings that run here.
runs = [l for l in trace() if l.startswith('debug: key bindings that run here:')]; idle = [l for l in trace() if l.startswith('debug: key bindings that do not run here:')]
check('mod+m (fit-window) and mod+f (toggle-fullscreen) are bindings that run here', bool(runs) and 'mod+m=fit-window' in runs[-1] and 'mod+f=toggle-fullscreen' in runs[-1] and 'fit-window' not in idle[-1] and 'toggle-fullscreen' not in idle[-1], {'sizing bindings that run': re.findall(r'[^ ;]+=(?:fit-window(?:-snapped)?|fill-window|toggle-fullscreen|(?:grow|shrink)-window [a-z-]+)', runs[-1]) if runs else None, 'do not run': idle[-1] if idle else None})

state = State(); check('zoom is 1', state['zoom'] == 1.0, state['zoom'])
cx, cy = state['camera']
far = 0
def away(name):
    global far; far += 1; place(name, cx + 6000 * far, cy)
# Into view, wherever the camera is by now: a window that closes hands the focus on, and the camera flies to the next one.
def show(name):
    seen = [None]
    def still():
        camera = State()['camera']; was, seen[0] = seen[0], camera; time.sleep(.15); return camera == was
    until('the camera is at rest', 5, still, bool); place(name, *State()['camera'])
show('a'); away('b'); away('c'); away('d')
if electron: away('e')
time.sleep(.3)
W0, H0 = agreed('adoption: the canvas has the size of A\'s window', 'a')
f0 = frame('a')
# Where the canvas panel's corner is on screen, from a tile and the camera: the same at every later reading, or the
# conversion used below is wrong.
def corner(name):
    s = State(); f = frame(name); t = tile(name, 'corner'); return [t[0] - (f[0] - (s['camera'][0] - 550)), t[1] - (f[1] - (-s['camera'][1] - 350))]
P = corner('a'); ok('the canvas panel\'s corner on screen', P)
clicked('a', 'adoption')

# 2 to 5. Steps: the named edge walks, the opposite one stays.
def stepped(what, text, dx, dy, dw, dh):
    before = frame('a'); acted(text)
    agreed(f'{what}: {text}', 'a', [before[2] + dw, before[3] + dh])
    after = frame('a'); check(f'{what}: the opposite edge stays', after == [before[0] + dx, before[1] + dy, before[2] + dw, before[3] + dh], {'before': before, 'after': after})
    clicked('a', what)
stepped('2', 'grow-window right', 0, 0, 30, 0)
stepped('3', 'grow-window left', -30, 0, 30, 0)
stepped('4', 'shrink-window right', 0, 0, -30, 0)
# (0.7071 * 30).round() on each axis.
stepped('5', 'grow-window down-right', 0, 0, 21, 21)
# The top edge, which only the canvas can hold still (no native position is set for a size that fits the screen from where the
# window sits), and a low edge walking inward.
stepped('5 up', 'grow-window up', 0, -30, 0, 30)
stepped('5 left', 'shrink-window left', 30, 0, -30, 0)

# 6. msg resize: the center stays, by half the difference in whole pixels, and the same request again asks nothing.
before = frame('a'); resized('a', 500, 400); agreed('6: msg resize 500 400', 'a', [500, 400])
half = lambda d: int(d / 2)
after = frame('a'); check('6: the top-left moves by half the difference', after == [before[0] + half(before[2] - 500), before[1] + half(before[3] - 400), 500, 400], {'before': before, 'after': after})
done = msg('resize', '--id', str(ids['a'])); check('6: msg resize reads the size', done.returncode == 0 and '500' in done.stdout and '400' in done.stdout, done.stdout.strip())
since = len(trace()); resized('a', 500, 400); time.sleep(.5)
check('6: the same request again resizes nothing', not resizes(since) and frame('a') == after, resizes(since))
clicked('a', '6')
# 6b. A press that follows a size request at once, while the window's frame is still changing under the focus request and
# the forwarded press: it must be sent and land, not end as another window (stale_identity_or_bounds). The size change is
# small so that the plain view is still under the point aimed at.
report = status('a'); x, y, w, h = report['controls']['plain']; at = [(x + w / 2) / report['bounds'][2], (y + h / 2) / report['bounds'][3]]
before = report['counts']; since = len(trace()); resize('a', 512, 412)
reply = pointer('down', ids['a'], at)
if 'Ok' not in reply: fail('6b: press on the tile of a behind a size request', reply)
until('6b: that press is delivered', 3, lambda: [l for l in trace()[since:] if l.startswith(f"debug: press #{ids['a']} delivered")], bool)
pointer('up', ids['a'], at)
landed = until('6b: the click arrives', 3, lambda: {k: status('a')['counts'][k] - before[k] for k in ('plain_down', 'plain_up')}, lambda v: all(d >= 1 for d in v.values()))
lines = trace()[since:]
check('6b: the press behind a size request was sent and landed once', landed == {'plain_down': 1, 'plain_up': 1} and all(' sent=1 ' in l for l in lines if ' delivered after ' in l), {'landed': landed, 'delivered': [l for l in lines if ' delivered after ' in l]})
check('6b: no focus request ended as another window', not [l for l in lines if 'stale_identity_or_bounds' in l], [l for l in lines if l.startswith('debug: native focus')])
agreed('6b: the size asked for', 'a', [512, 412]); resized('a', 500, 400); agreed('6b: back to 500x400', 'a', [500, 400])

# 7. Fit: the usable area less the outer gap on every side, the camera on the window at zoom 1; again gives the size back.
plain = frame('a'); acted('fit-window')
fit = agreed('7: fit-window', 'a', [1100 - 2 * 16, 700 - 2 * 16])
check('7: mode fit at zoom 1', mode('a') == 'Fit' and State()['zoom'] == 1.0, {'mode': mode('a'), 'zoom': State()['zoom']})
at = until('7: the fit window sits the outer gap inside the canvas', 3, lambda: tile('a', '7'), lambda t: close(t, [P[0] + 16, P[1] + 16, fit[0], fit[1]], .5)); ok('7: the fit window sits the outer gap inside the canvas', at)
check('7: the panel corner is where it was', close(corner('a'), P, .5), corner('a'))
clicked('a', '7 fit')
acted('fit-window'); agreed('7: fit-window again', 'a', [500, 400]); check('7: mode normal again', mode('a') == 'Normal', mode('a'))
clicked('a', '7 unfit')

# 8. Fill: in place, to the usable area less the outer gap (nothing else is on this output); again restores the frame.
plain = frame('a'); acted('fill-window')
fill = agreed('8: fill-window', 'a', [1068, 668]); check('8: mode fill', mode('a') == 'Fill', mode('a'))
at = tile('a', '8'); check('8: the filled window sits the outer gap inside the canvas', close(at, [P[0] + 16, P[1] + 16, 1068, 668], .5), at)
clicked('a', '8 fill')
acted('fill-window'); agreed('8: fill-window again', 'a', [500, 400])
check('8: the frame from before the fill', frame('a') == plain and mode('a') == 'Normal', {'before': plain, 'after': frame('a')})
clicked('a', '8 unfill')

# 9. Fit snapped: a window a snap gap to the right follows A's right edge, and its own size is not touched.
a = frame('a'); bw, bh = native('b')
place('b', a[0] + a[2] + 12 + bw // 2, -(a[1] + bh // 2)); time.sleep(.2)
b = frame('b'); check('9: B is a snap gap to the right of A', b[0] == a[0] + a[2] + 12, {'a': a, 'b': b})
since = len(trace()); acted('fit-window-snapped'); agreed('9: fit-window-snapped', 'a', [1068, 668])
a2 = frame('a'); b2 = frame('b')
check('9: B moved by A\'s right edge', b2[0] - b[0] == (a2[0] + a2[2]) - (a[0] + a[2]) and b2[2:] == b[2:], {'a': [a, a2], 'b': [b, b2]})
check('9: B\'s own window was not resized', native('b') == [bw, bh] and not resizes(since, 'b'), {'native': native('b'), 'requests': resizes(since, 'b')})
acted('fit-window-snapped'); agreed('9: fit-window-snapped again', 'a', [500, 400])
check('9: B is back', frame('b') == b, {'before': b, 'after': frame('b')})
clicked('a', '9')

# 10. A minimum and a maximum: the window ends at the size its application allows, and the canvas has that size. Upstream's
# cmd_resize clamps to the limits its client declares and keeps the center for the clamped size, so the frame's center is
# where it was, by half the difference from the size the window had to the size it took, in whole pixels.
away('a'); show('b'); limits = status('b')['limits']; time.sleep(.2)
def clamped(what, w, h, limit):
    before = frame('b'); since = len(trace()); resized('b', w, h); took = agreed(f'10: {what} ends at it', 'b', limit)
    check('10: the request was answered clamped', any('outcome=clamped' in l for l in resizes(since, 'b')), resizes(since, 'b'))
    want = [before[0] + half(before[2] - took[0]), before[1] + half(before[3] - took[1]), took[0], took[1]]; after = frame('b')
    check(f'10: {what}: the center stays, for the size the window took', after == want, {'before': before, 'asked': [w, h], 'after': after, 'want': want})
clamped('below the minimum', 100, 100, limits['min']); clicked('b', '10 minimum')
clamped('above the maximum', 2000, 2000, limits['max']); clicked('b', '10 maximum')

# 11. An increment: the window ends on a whole step, within one step of the size asked, and the canvas has that size.
away('b'); show('c'); time.sleep(.2); c0 = native('c'); snaps = status('c')['snapped']
ask_w, ask_h = c0[0] + round(2.4 * 37), c0[1] + round(2.4 * 23)
resized('c', ask_w, ask_h); until('11: the window takes a size', 3, lambda: native('c'), lambda size: size != c0); time.sleep(.3)
got = agreed('11: a size off the increment', 'c')
by = 'the fixture\'s own snap' if status('c')['snapped'] > snaps else 'AppKit'
check(f'11: ends on a whole step within one step of the request (snapped by {by})', (got[0] - c0[0]) % 37 == 0 and (got[1] - c0[1]) % 23 == 0 and 0 <= ask_w - got[0] < 37 and 0 <= ask_h - got[1] < 23, {'start': c0, 'asked': [ask_w, ask_h], 'took': got})
clicked('c', '11')

# 12. Fullscreen: the output's size is asked, the window is placed in the output's screen space, and leaving gives back the
# size, the place and the view. The panel's size fits the screen from where the window sits, so no native position is set for
# it (case 19 is the size that does not fit): where macOS has the window is printed.
away('c'); show('a'); time.sleep(.2); clicked('a', '12 before')
before = {'frame': frame('a'), 'camera': State()['camera'], 'zoom': State()['zoom'], 'origin': status('a')['bounds'][:2]}
since = len(trace()); acted('toggle-fullscreen')
took = until('12: the window takes a size for fullscreen', 3, lambda: native('a'), lambda size: size != before['frame'][2:]); time.sleep(.4); took = native('a')
check('12: toggle-fullscreen asked the window for the output\'s size, 1100x700', any(' requested=1100x700 ' in l for l in resizes(since, 'a')), resizes(since, 'a'))
check('12: and a window with no limits took it', took == [1100, 700], took)
check('12: no native position was set for a size that fits the screen from there', all(l.endswith(' moved=0') for l in resizes(since, 'a')), resizes(since, 'a'))
full = State()['fullscreen']; check('12: the output\'s fullscreen entry names A', len(full) == 1 and full[0]['id'] == ids['a'] and entry('a') is None, full)
at = tile('a', '12'); want = [P[0] + max(0, (1100 - took[0]) // 2), P[1] + max(0, (700 - took[1]) // 2), took[0], took[1]]
check('12: the tile has the window\'s size, at the corner or centred', close(at, want, .5), {'tile': at, 'want': want})
clicked('a', '12 fullscreen')
acted('toggle-fullscreen'); agreed('12: toggle-fullscreen again gives the size back', 'a', before['frame'][2:])
after = {'frame': frame('a'), 'camera': State()['camera'], 'zoom': State()['zoom'], 'origin': status('a')['bounds'][:2]}
check('12: the place, the camera and the zoom from before', (after['frame'], after['camera'], after['zoom']) == (before['frame'], before['camera'], before['zoom']) and State()['fullscreen'] == [], {'before': before, 'after': after})
ok('12: the native origin, which nothing here set', {'before': before['origin'], 'after': after['origin'], 'moved by macOS': before['origin'] != after['origin']})
clicked('a', '12 after')

# 13. A window that will not take the output's size is fullscreen at the size it took, centred.
away('a'); resized('b', 400, 300); agreed('13: B at 400x300', 'b', [400, 300]); show('b'); time.sleep(.2); clicked('b', '13 before')
before = {'frame': frame('b'), 'camera': State()['camera'], 'zoom': State()['zoom']}
since = len(trace()); acted('toggle-fullscreen'); until('13: B takes its maximum for fullscreen', 3, lambda: native('b'), lambda size: size == limits['max']); time.sleep(.4)
check('13: toggle-fullscreen asked B for the output\'s size all the same', any(' requested=1100x700 ' in l for l in resizes(since, 'b')), resizes(since, 'b'))
w, h = native('b'); at = tile('b', '13')
check('13: fullscreen at the maximum, centred on the canvas', close(at, [P[0] + (1100 - w) // 2, P[1] + (700 - h) // 2, w, h], .5), {'tile': at, 'window': [w, h]})
clicked('b', '13 fullscreen')
acted('toggle-fullscreen'); agreed('13: and back', 'b', [400, 300])
after = {'frame': frame('b'), 'camera': State()['camera'], 'zoom': State()['zoom']}
check('13: the place, the camera and the zoom from before', after == before and State()['fullscreen'] == [], {'before': before, 'after': after})
clicked('b', '13 after')

# 14. The application resizes its own window: the canvas follows, and the next step starts from that size.
away('b'); show('a'); time.sleep(.2)
(evidence / 'a' / 'frame').write_text('560 430'); agreed('14: a size the application set itself reaches the canvas', 'a', [560, 430], seconds=2)
clicked('a', '14'); acted('grow-window right'); agreed('14: a step from that size', 'a', [590, 430])

# 15. An application that stops answering in the middle of a size request: its window takes the size and the answer never
# comes. The request must end by itself, other windows must be sizable meanwhile, and when the application answers again the
# canvas has the size its window has, and the window takes a click.
away('a'); show('c'); time.sleep(.2); c1 = native('c'); want = [c1[0] + 3 * 37, c1[1] + 3 * 23]
(evidence / 'c' / 'stall').write_text('4'); time.sleep(.3); since = len(trace()); began = time.time()
resized('c', *want)
first = resize('a', 520, 410); busy = f'a native resize of window {ids["c"]} is still pending'; ended = answers(since, 'c')
# One size transaction at a time: while C's is live the request is refused in the controller's words. It may be taken only
# when C's had ended by then, which the adapter's answers for C say: its setter's, then the one read that follows it.
if first.returncode: check('15: another window\'s request at once is refused as pending, in the controller\'s words', busy in first.stderr + first.stdout, first.stderr.strip() or first.stdout.strip())
else: check('15: another window\'s request at once was taken only because C\'s had ended', len(ended) >= 2 and ended[-1].startswith('debug: native size read ') and any(l.startswith('debug: native resize ') for l in ended), ended)
def again():
    done = resize('a', 520, 410); return done.returncode == 0
until('15: another window is sizable within 10 s', 10, again, bool); took = time.time() - began
stale = time.time() - (evidence / 'c' / 'status.json').stat().st_mtime
agreed('15: the other window was resized', 'a', [520, 410])
ok('15: the stuck request ended and another window was sized', {'seconds': round(took, 2), 'C had not reported for': round(stale, 2), 'requests of C': resizes(since, 'c')})
check('15: C was still not answering when that happened', stale > .5, round(stale, 2))
check('15: C\'s setter was reported unanswered', any('observed=0' in l for l in resizes(since, 'c')), resizes(since, 'c'))
until('15: C answers again', 8, lambda: time.time() - (evidence / 'c' / 'status.json').stat().st_mtime, lambda age: age < .3)
agreed('15: the canvas has the size C\'s window took', 'c', want)
clicked('c', '15')

# 16. The application dies in the middle of a size request: its window leaves the canvas and nothing stays held.
(evidence / 'c' / 'stall').write_text('6'); time.sleep(.3); pid = status('c')['pid']; began = time.time()
resized('c', want[0] + 37, want[1] + 23); time.sleep(.3); os.kill(pid, 9)
until('16: the dead application\'s window leaves the canvas within 10 s', 10, lambda: [w['title'] for w in windows()], lambda t: status('c')['title'] not in t)
ok('16: the dead application\'s window left the canvas', {'seconds': round(time.time() - began, 2)})
until('16: another window is sizable', 10, lambda: resize('a', 500, 400).returncode == 0, bool); agreed('16: and was resized', 'a', [500, 400])

# 17. A fullscreen window is closed by its application: the view comes back and nothing stays held.
away('a'); show('b'); time.sleep(.2); clicked('b', '17 before'); view = {'camera': State()['camera'], 'zoom': State()['zoom']}
acted('toggle-fullscreen'); until('17: B is fullscreen', 3, lambda: State()['fullscreen'], lambda f: len(f) == 1 and f[0]['id'] == ids['b']); time.sleep(.5)
(evidence / 'b' / 'close').write_text('1')
until('17: the closed window leaves and no fullscreen is left', 10, lambda: (State()['fullscreen'], [w['title'] for w in windows()]), lambda v: v[0] == [] and status('b')['title'] not in v[1])
now = {'camera': State()['camera'], 'zoom': State()['zoom']}; check('17: the camera and the zoom from before the fullscreen', now == view, {'before': view, 'after': now})
until('17: another window is sizable', 10, lambda: resize('a', 520, 420).returncode == 0, bool); agreed('17: and was resized', 'a', [520, 420])

# 19. Room on the screen. macOS grants no size that would carry a window past its screen's visible area, so the adapter moves
# the real window first, by the least that makes room, and the canvas knows nothing of it: the frame on the canvas follows the
# size alone, by msg resize's rule (the center stays), and the camera stays. Every number is from the visible area D reports.
away('a'); show('d'); time.sleep(.2)
V = [int(v) for v in status('d')['screen_visible']]; d0 = status('d')['bounds']
W, H = V[2] - 200, V[3] - 150
check('19: D sits where a size that fits the visible area does not fit', d0[0] + W > V[0] + V[2] and d0[1] + H > V[1] + V[3] and d0[0] + d0[2] <= V[0] + V[2] and d0[1] + d0[3] <= V[1] + V[3], {'visible': V, 'window': d0, 'size to ask': [W, H]})
def roomed(what, w, h, outcome, origin, size, moved):
    before = frame('d'); view = State()['camera']; since = len(trace()); resized('d', w, h); took = agreed(f'19: {what}: the window and the canvas end at {size}', 'd', size)
    asked = resizes(since, 'd'); check(f'19: {what}: answered {outcome}, moved={moved}', len(asked) == 1 and f' outcome={outcome} ' in asked[0] and asked[0].endswith(f' moved={moved}'), asked)
    at = until(f'19: {what}: the fixture\'s own frame', 2, lambda: status('d')['bounds'], lambda b: b == origin + size)
    check(f'19: {what}: the fixture\'s own frame is at {origin} and inside the visible area', at[0] >= V[0] and at[1] >= V[1] and at[0] + at[2] <= V[0] + V[2] and at[1] + at[3] <= V[1] + V[3], {'frame': at, 'visible': V})
    want = [before[0] + half(before[2] - took[0]), before[1] + half(before[3] - took[1]), took[0], took[1]]
    # Once at the answer, and again after the shell has looked at the window where it now sits (it looks once a second).
    for when in ('at the answer', 'after the next look at the window'):
        now = {'frame': frame('d'), 'camera': State()['camera']}
        check(f'19: {what}: on the canvas the center and the camera stay, {when}', now == {'frame': want, 'camera': view}, {'before': before, 'now': now, 'want': want, 'camera before': view})
        if when == 'at the answer': time.sleep(1.3)
roomed('a size that fits the visible area but not from there', W, H, 'applied', [V[0] + 200, V[1] + 150], [W, H], 1)
# Wider than the visible area: asked as it is from the area's left edge, and the window takes the width there is.
roomed('wider than the visible area', V[2] + 300, H, 'clamped', [V[0], V[1] + 150], [V[2], H], 1)
# The screen's whole size, which a fullscreen on a whole display asks (the owner's 2056x1329): the visible area's, at its origin.
S = [int(v) for v in status('d')['screen_size']]
roomed(f'the whole screen, {S[0]}x{S[1]}', S[0], S[1], 'clamped', V[:2], V[2:], 1)
# Smaller needs no room: the window stays where it was put, and a click on its tile lands in it there.
roomed('a smaller size', 500, 400, 'applied', V[:2], [500, 400], 0); clicked('d', '19'); away('d')

# 22. Electron, within the adapter's one point: a step, an absolute size, fit and fullscreen.
if electron:
    away('a'); show('e'); time.sleep(.3); clicked('e', '22 before'); e0 = agreed('22: adoption', 'e', tol=1)
    acted('grow-window right'); agreed('22: grow-window right', 'e', [e0[0] + 30, e0[1]], tol=1); clicked('e', '22 step')
    resized('e', 500, 400); agreed('22: msg resize 500 400', 'e', [500, 400], tol=1); clicked('e', '22 absolute')
    acted('fit-window'); agreed('22: fit-window', 'e', [1068, 668], tol=1); clicked('e', '22 fit')
    acted('fit-window'); agreed('22: fit-window again', 'e', [500, 400], tol=1)
    since = len(trace()); acted('toggle-fullscreen'); until('22: Electron takes a size for fullscreen', 3, lambda: native('e'), lambda size: size[0] > 600); time.sleep(.4)
    check('22: toggle-fullscreen asked the window for the output\'s size, 1100x700', any(' requested=1100x700 ' in l for l in resizes(since, 'e')), resizes(since, 'e'))
    check('22: and Electron took it, within a point', close(native('e'), [1100, 700], 1), native('e')); clicked('e', '22 fullscreen')
    acted('toggle-fullscreen'); agreed('22: toggle-fullscreen again', 'e', [500, 400], tol=1); clicked('e', '22 after')
    away('e')

# 18. A window rule's size: a window that appears under a title its rule names is asked for that size.
(evidence / 'r' / 'show').write_text('1')
r = until('18: the ruled window is adopted', 8, windows, lambda w: any(x['title'] == status('r')['title'] for x in w))
ids['r'] = next(x['id'] for x in r if x['title'] == status('r')['title'])
agreed('18: the rule\'s size [480, 360]', 'r', [480, 360]); clicked('r', '18')

# 23. Two windows that appear together: each gets the focus a new window gets, the second request withdrawing the first
# after it has asked for its application. Both are adopted; the request that was withdrawn may end refused, which is what
# withdrawn means; the last one answered must end focused, where it used to be refused for the change of foreground the
# first one made; and the window the canvas holds focused is the one in front.
since = len(trace()); (evidence / 'n' / 'show').write_text('1'); (evidence / 'm' / 'show').write_text('1')
pair = until('23: both windows are adopted', 8, windows, lambda w: all(any(x['title'] == status(k)['title'] for x in w) for k in ('n', 'm')))
for k in ('n', 'm'): ids[k] = next(x['id'] for x in pair if x['title'] == status(k)['title'])
pids = {status(k)['pid']: k for k in ('n', 'm')}
def focus_lines(): return [l for l in trace()[since:] if l.startswith('debug: native focus') and any(f' pid={p} ' in l for p in pids)]
until('23: a focus request for one of them is answered focused', 5, focus_lines, lambda ls: any('outcome=focused' in l for l in ls)); time.sleep(.6)
lines = focus_lines()
check('23: the last focus request answered for the pair ended focused', bool(lines) and 'outcome=focused focused=1' in lines[-1], lines)
front = until('23: one of the two is the application in front', 3, lambda: {k: status(k)['app_active'] for k in ('n', 'm')}, lambda v: sum(v.values()) == 1)
held = [w['id'] for w in windows() if w.get('is_focused')]; want = ids[next(k for k, v in front.items() if v)]
check('23: the window the canvas holds focused is the one in front', held == [want], {'front': front, 'focused': held, 'ids': {k: ids[k] for k in ('n', 'm')}})
away('n'); away('m'); time.sleep(.3)

# 21. Nothing but the scope was acted on, and no window was ever left unsettled.
z = status('z')
check('21: decoy took no event, was never activated and has its bounds', z['counts'] | {'raf': 0} == decoy['counts'] | {'raf': 0} and z['activations'] == 0 and z['bounds'] == decoy['bounds'], {'bounds': z['bounds'], 'activations': z['activations']})
allowed = {status(n)['pid'] for n in scope + ['r', 'n', 'm']} | {pid}
named = {int(p) for l in trace() if l.startswith('debug:') for p in re.findall(r'(?<![a-z_])pid=(\d+)', l)}
check('21: every pid acted on is in the scope', named and named <= allowed, {'named': sorted(named), 'scope': sorted(allowed), 'decoy': decoy['pid']})
check('21: no press or tile was refused as unsettled', not any('source presentation unsettled' in l for l in trace()), [l for l in trace() if 'unsettled' in l])
outcomes = {}
for l in trace():
    m = re.match(r'debug: native (resize|size read) .* outcome=(\w+)', l)
    if m: outcomes[f'{m.group(1)} {m.group(2)}'] = outcomes.get(f'{m.group(1)} {m.group(2)}', 0) + 1
ok('21: what the native adapter answered, by outcome', outcomes)

# 20. Quit while a window is fullscreen: the shell part checks its size once Infinify is gone.
show('a'); away('r'); time.sleep(.2); clicked('a', '20 before'); size = native('a')
acted('toggle-fullscreen'); until('20: A is fullscreen before the quit', 3, lambda: native('a'), lambda s: s != size); time.sleep(.4)
ok('20: A is fullscreen before the quit', native('a'))
(evidence / 'before-quit.json').write_text(json.dumps({'a': size, 'z': {'bounds': decoy['bounds'], 'counts': decoy['counts']}}))
PY

launch() { : > "$evidence/err.log"; INFINIFY_DEBUG=1 "$app" --windowed 1100x700 --state "$state" --config "$config" --socket "$socket" --no-hover-forwarding "$@" 2>"$evidence/err.log" & infinify=$!
  n=0; while [ ! -S "$socket" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done; [ -S "$socket" ] || { echo "FAIL: no socket: $(cat "$evidence/err.log")"; exit 1; }; }
shown() { grep -q '"visible":true' "$evidence/$1/status.json" 2>/dev/null; }
for name in a b c d z ${E:+e}; do
  n=0; while ! shown "$name" && [ "$n" -lt 150 ]; do sleep .1; n=$((n+1)); done
  shown "$name" || { echo "FAIL: fixture $name never showed its window: $(cat "$evidence/electron.log" 2>/dev/null)"; exit 1; }
done
sleep .5
# The ruled fixture is in the scope from the start: its window appears later, and must be managed when it does.
launch --debug-pointer --only-pid "$A,$B,$C,$D,$R,$N,$M${E:+,$E}"
python3 "$evidence/driver.py" "$evidence" "$app" scoped "$infinify" ${E:+electron}
quit; [ "$gone" = yes ] || { echo 'FAIL: Infinify did not quit within 8 s of msg action quit'; exit 1; }
echo 'ok: quit within 8 s'
python3 "$evidence/driver.py" "$evidence" "$app" quit
echo 'PASS: scoped sizing: steps, msg resize, fit, fill, fit snapped, minimum, maximum and increment, fullscreen, a size the application set, an application that stops answering or dies mid-request, a fullscreen window closed, a size that needs room on the screen, a rule size, quit from fullscreen; decoy untouched'
