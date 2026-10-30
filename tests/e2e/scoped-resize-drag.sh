#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# DriftWM's pointer resize on real windows, in a normal run with no flag: a press bound to resize-window (alt + right button)
# or resize-window-snapped (alt + shift + right button) on a window's tile, and a left press on the inner or outer resize border
# it, start upstream's resize grab; the drag asks each size of the real window and the canvas shows the size the window then
# has. Disposable fixture applications are started, Infinify manages exactly those (`--only-pid`), and the fixture itself says
# what size its window has. Checked: which edges move from where in the window the press fell, the opposite edge staying, a
# minimum, a maximum and a resize increment, a window that takes no size, the cluster a snapped resize carries, the border,
# a rule's preserve_aspect_ratio, a window that closes and an application that stops answering in the middle of a grab, a
# pointer held still, and that a click on a tile lands afterwards every time.
#
# The press, the drag and the release are made by the DebugPointer request (`--debug-pointer`): NSEvents handed to the canvas
# view's own mouse handlers, the same a person's events enter. The pointer is never moved and nothing is posted at the session
# level. Not shown here: the window server delivering a modified right-button drag to the canvas panel, and a trackpad
# gesture, which no request can make (the gesture's controller half is crates/desktop/tests/gesture_flow.rs; the size requests
# it then hands the shell are performed by the same coordinator this drag exercises).
#
# It runs with or without Screen Recording access; without it the tiles have no picture and everything here is the same.
# Everything acted on is a process this script started, as in tests/e2e/scoped-sizing.sh, whose conventions these are: the
# clicks take the foreground. Run it while nothing else needs the keyboard. Without --live-owned-fixture it starts nothing.
#
# Exit status: 0 everything was checked and held; 1 something failed; 2 usage; 3 nothing failed and nothing was checked,
# because Stage Manager is on or another Infinify is running (NOT RUN).
set -eu
cd "$(dirname "$0")/../.."
[ "$#" -ne 0 ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to validate the pointer resize on disposable windows'; exit 0; }
[ "$#" -eq 1 ] && [ "$1" = --live-owned-fixture ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }
root=$PWD
[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" != 1 ] || { echo 'NOT RUN: Stage Manager is on (com.apple.WindowManager GloballyEnabled is 1); nothing was started and nothing was checked. Run it with Stage Manager off.'; exit 3; }
app=$root/target/app/Infinify.app/Contents/MacOS/Infinify
[ -x "$app" ] || ./scripts/build-app.sh
# Another Infinify would manage these fixtures too. It is only looked for, never signalled.
if pgrep -f 'Infinify.app/Contents/MacOS/Infinify' >/dev/null 2>&1; then echo 'NOT RUN: another Infinify is running; nothing was started and nothing was checked.'; exit 3; fi
mkdir -p target/ipc
# Short: a socket path has room for about a hundred bytes.
evidence=$(mktemp -d "$root/target/ipc/drag.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
state=$evidence/state.json; config=$evidence/config.toml; socket=$evidence/s
infinify=; fixtures=
quit() {
  [ -n "$infinify" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 80 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify" 2>/dev/null; then kill "$infinify" 2>/dev/null || true; gone=no; else gone=yes; fi
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 30 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify" 2>/dev/null; then kill -KILL "$infinify" 2>/dev/null || true; fi
  wait "$infinify" 2>/dev/null || true; infinify=
}
# Only what this script started is ever signalled.
cleanup() {
  quit
  for pid in $fixtures; do kill -TERM "$pid" 2>/dev/null || true; done
  n=0; alive=yes
  while [ "$alive" = yes ] && [ "$n" -lt 30 ]; do
    alive=no; for pid in $fixtures; do if kill -0 "$pid" 2>/dev/null; then alive=yes; fi; done
    if [ "$alive" = yes ]; then sleep .1; n=$((n+1)); fi
  done
  for pid in $fixtures; do if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi; done
  for pid in $fixtures; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# The snap numbers are named so that every one below is the config's, not a default's. The bindings and resize_on_border
# are upstream's defaults, which the trace of each press shows in force. The rule keeps the ratio of the one window whose
# title it names.
cat > "$config" <<TOML
[snap]
gap = 12
distance = 16
break_force = 24
[[window_rules]]
title = "Ratio P $$"
preserve_aspect_ratio = true
TOML

bundle=$evidence/ScopeFixture.app
mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.infinify.scope-fixture</string><key>CFBundleName</key><string>ScopeFixture</string><key>CFBundleExecutable</key><string>ScopeFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror tests/native/app/Windows/ScopeFixture.m \
  -framework AppKit -framework WebKit -o "$bundle/Contents/MacOS/ScopeFixture"
fixture=$bundle/Contents/MacOS/ScopeFixture
start() { name=$1; title=$2; dx=$3; shift 3; mkdir "$evidence/$name"; "$fixture" "$evidence/$name" "$title" "$dx" 280 "$@" & fixtures="$fixtures $!"; }
start a "Drag fixture A $$" -300 resizable; A=$!
start b "Drag fixture B $$" 0 resizable min 300x260 max 640x520; B=$!
start c "Drag fixture C $$" 300 resizable increment 37x23; C=$!
# Four arguments: a window that cannot be resized at all.
start f "Drag fixture F $$" -150; F=$!
start n "Drag neighbour N $$" 150 resizable; N=$!
start p "Ratio P $$" 0 resizable; P=$!
start k "Drag fixture K $$" -200 resizable; K=$!
start h "Drag fixture H $$" 200 resizable; H=$!
# Out of scope and exactly as scoped-windows.sh starts it.
mkdir "$evidence/z"; "$fixture" "$evidence/z" "Drag decoy Z $$" 150 120 & Z=$!; fixtures="$fixtures $Z"

cat > "$evidence/driver.py" <<'PY'
import json, pathlib, re, socket, subprocess, sys, time
evidence = pathlib.Path(sys.argv[1]); app = sys.argv[2]
sock = str(evidence / 's'); errlog = evidence / 'err.log'
def ok(what, observed): print(f'ok: {what}: {observed}', flush=True)
def fail(what, observed):
    print(f'FAIL: {what}: {observed}', flush=True)
    for line in trace()[-30:]: print(f'    {line}', flush=True)
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
    try: return subprocess.run([app, 'msg', '--socket', sock, *args], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired: fail('msg ' + ' '.join(args), 'no answer within 10 s')
def trace(): return errlog.read_text(errors='replace').splitlines()
def native(name): return status(name)['bounds'][2:]
def State(): return ask('State')['Ok']['State']
def windows(): return State()['windows']

scope = ['a', 'b', 'c', 'f', 'n', 'p', 'k', 'h']
decoy = status('z')
titles = sorted(status(n)['title'] for n in scope)
adopted = until('adopts exactly the scope', 8, windows, lambda w: sorted(x['title'] for x in w) == titles)
ok('adopts exactly the scope', [(w['id'], w['title'], w['size']) for w in adopted])
managing = [l for l in trace() if l.startswith('Managing only')]
ok('Screen Recording', 'not granted: tiles have no picture' if 'No Screen Recording access' in managing[0] else 'granted: tiles are captured')
ids = {n: next(w['id'] for w in adopted if w['title'] == status(n)['title']) for n in scope}
def entry(name): return next((w for w in windows() if w['id'] == ids[name]), None)
# The world frame of a canvas window: State gives the center, Y-up, by upstream's truncating halving, so an origin read
# from it is exact for an even size and within one unit for an odd one.
def frame(name):
    w = entry(name)
    return None if w is None else [w['position'][0] - w['size'][0] // 2, -w['position'][1] - w['size'][1] // 2, w['size'][0], w['size'][1]]
def close(a, b, tol): return a is not None and b is not None and all(abs(x - y) <= tol for x, y in zip(a, b))
def agreed(what, name, want=None, tol=0, seconds=3):
    def read(): return {'native': native(name), 'canvas': (frame(name) or [None] * 4)[2:]}
    seen = until(what, seconds, read, lambda v: close(v['canvas'], v['native'], 0) and (want is None or close(v['native'], want, tol)))
    ok(what, seen); return seen['native']
def resize(name, w, h): return msg('resize', '--id', str(ids[name]), str(int(w)), str(int(h)))
def place(name, x, y):
    done = msg('move', '--id', str(ids[name]), str(int(x)), str(int(y)))
    if done.returncode: fail(f'msg move {name}', done.stderr.strip())
def pointer(**request): return ask({'DebugPointer': request})
def near(a, b): return a is not None and abs(a[0] - b[0]) <= 2 and abs(a[1] - b[1]) <= 2
# A click as a person makes it, on the window's plain view: it must land once, within two points of the middle of that
# view as the window lays it out at the size it has now. This is the check that no grab leaves a window whose input is refused.
def clicked(name, what):
    report = status(name); x, y, w, h = report['controls']['plain']; want = [x + w / 2, y + h / 2]
    at = [want[0] / report['bounds'][2], want[1] / report['bounds'][3]]; before = report['counts']; start = len(trace()); window = ids[name]
    reply = pointer(phase='down', window=window, at=at)
    if 'Ok' not in reply: fail(f'{what}: press on the tile of {name}', reply)
    delivered = lambda: [l for l in trace()[start:] if l.startswith(f'debug: press #{window} delivered')]
    until(f'{what}: press on {name} is delivered', 3, delivered, bool)
    reply = pointer(phase='up', window=window, at=at)
    if 'Ok' not in reply: fail(f'{what}: release on the tile of {name}', reply)
    kinds = ['plain_down', 'plain_up']
    def read(): r = status(name); return {'delta': {k: r['counts'][k] - before[k] for k in kinds}, 'last': {k: r['last'].get(k) for k in kinds}, 'want': want}
    until(f'{what}: the click on {name} arrives', 3, read, lambda v: all(d >= 1 for d in v['delta'].values())); time.sleep(.25); seen = read()
    check(f'{what}: a click on the tile of {name} lands once, within 2 points', all(d == 1 for d in seen['delta'].values()) and all(near(p, want) for p in seen['last'].values()), seen)
def setters(since, name):
    pid = status(name)['pid']; return [l for l in trace()[since:] if l.startswith('debug: native resize ') and f' pid={pid} ' in l]
def ended(since, name): return [l for l in trace()[since:] if re.match(rf'debug: size transaction \d+ of #{ids[name]} ended', l)]
def focused(): return [w['id'] for w in windows() if w.get('is_focused')]

state = State(); check('zoom is 1', state['zoom'] == 1.0, state['zoom'])
cx, cy = state['camera']
far = 0
def away(name):
    global far; far += 1; place(name, cx + 6000 * far, cy)
def rest():
    seen = [None]
    def still():
        camera = State()['camera']; was, seen[0] = seen[0], camera; time.sleep(.15); return camera == was
    until('the camera is at rest', 5, still, bool)
# Into view, wherever the camera is by now, `dx` and `dy` screen points right of and below the middle of the canvas.
def show(name, dx=0, dy=0):
    rest(); camera = State()['camera']; place(name, camera[0] + dx, camera[1] - dy)
# A size by msg resize, waited for to its end: one size transaction at a time, so a grab can begin only after it.
def sized(name, w, h, what):
    if native(name) == [w, h] and frame(name)[2:] == [w, h]: return
    since = len(trace()); done = resize(name, w, h)
    if done.returncode: fail(f'{what}: msg resize {name} {w} {h}', done.stderr.strip() or done.stdout.strip())
    until(f'{what}: the transaction of msg resize {name} {w} {h} ends', 5, lambda: ended(since, name), bool)
    agreed(f'{what}: {name} at {w}x{h}', name, [w, h])
for name in scope: away(name)
time.sleep(.3)

# A press, a drag in `steps` equal steps to (dx, dy) screen points from the press, and a release, each through the view's
# own handlers. Returns the trace index before the press.
def down(name, at, button='right', modifiers=('alt',), offset=None, what=''):
    rest(); since = len(trace()); request = dict(phase='down', window=ids[name], at=at, button=button, modifiers=list(modifiers))
    if offset: request['offset'] = offset
    reply = pointer(**request)
    if 'Ok' not in reply: fail(f'{what}: press on {name} at {at}', reply)
    return since
def drag(dx, dy, what='', steps=5, pause=.06):
    for i in range(1, steps + 1):
        reply = pointer(phase='drag', to=[dx * i / steps, dy * i / steps])
        if 'Ok' not in reply: fail(f'{what}: drag step {i} to {[dx * i / steps, dy * i / steps]}', reply)
        if pause: time.sleep(pause)
def up(what=''):
    reply = pointer(phase='up')
    if 'Ok' not in reply: fail(f'{what}: release', reply)
def grab(since): return [l for l in trace()[since:] if l.startswith('debug: resize grab ')]
def press_line(since): return [l for l in trace()[since:] if l.startswith('debug: pointer down ')]

# 1. Upstream's edges_from_position: a 3x3 grid over the window. Each cell is pressed at its middle with alt + right and
# dragged 40 across and 30 down or up, outwards for an edge cell. The edges of the cell move, the opposite ones stay, and
# what does not belong to the cell does not move: so a left cell changes the width alone. The native window's own top-left
# is written by nobody (a size write keeps it), which its fixture's bounds show.
show('n', 300, 0); show('a', -200, 0); time.sleep(.3); clicked('n', '1: N is focused first')
check('1: N holds the focus before the first press', focused() == [ids['n']], focused())
# Raise and focus at the start, before any motion. The raise is shown by what a press would hit: N, clicked last, is put over
# A's right side, so that part of A lies beneath it until the resize press on A's left; then it is A's.
show('n', 100, 0); time.sleep(.2); under = pointer(phase='probe', window=ids['a'], at=[.9, .5])
check('1: A\'s right side lies beneath N before the press', f"window #{ids['n']} is under that point" in json.dumps(under), under)
since = down('a', [1/6, 1/6], what='1 raise'); until('1: a resize grab began', 2, lambda: grab(since), bool)
got = until('1: the press focuses A before any drag', 2, focused, lambda f: f == [ids['a']]); ok('1: the press focuses A before any drag', got)
until('1: and A\'s application comes to the front', 3, lambda: status('a')['app_active'], bool)
over = pointer(phase='probe', window=ids['a'], at=[.9, .5])
check('1: and raises it: the same point is A\'s now', 'Ok' in over and over['Ok']['DebugPointer']['hit'] == ids['a'], over)
up('1 raise'); until('1: the grab that was not dragged ends', 5, lambda: ended(since, 'a'), bool)
# And out of the way: an edge of A dragged to within the snap distance of N would stop a snap gap short of it, as it should.
away('n'); time.sleep(.2)
cells = [('top_left', 1/6, 1/6, -40, -30), ('top', .5, 1/6, 40, -30), ('top_right', 5/6, 1/6, 40, -30),
         ('left', 1/6, .5, -40, 30), ('bottom_right', .5, .5, 40, 30), ('right', 5/6, .5, 40, 30),
         ('bottom_left', 1/6, 5/6, -40, 30), ('bottom', .5, 5/6, 40, 30), ('bottom_right', 5/6, 5/6, 40, 30)]
for edges, fx, fy, dx, dy in cells:
    what = f'1 {edges} from ({fx:.2f}, {fy:.2f})'
    sized('a', 480, 360, what); f0 = frame('a'); n0 = status('a')['bounds']
    since = down('a', [fx, fy], what=what)
    line = until(f'{what}: the press is traced', 2, lambda: press_line(since), bool)[0]
    check(f'{what}: the press is the right button\'s, bound to resize-window', ' button=1 trigger=right binding=resize_window ' in line, line)
    began = until(f'{what}: a resize grab began', 2, lambda: grab(since), bool)[0]
    check(f'{what}: the grab resizes the {edges} edge', f' edges={edges} group=0 ' in began, began)
    drag(dx, dy, what); up(what)
    until(f'{what}: the transaction ends', 5, lambda: ended(since, 'a'), bool)
    ew = 480 + (40 if 'left' in edges or 'right' in edges else 0); eh = 360 + (30 if 'top' in edges or 'bottom' in edges else 0)
    took = agreed(f'{what}: the window and the canvas end at {ew}x{eh}', 'a', [ew, eh])
    want = [f0[0] - (ew - 480 if 'left' in edges else 0), f0[1] - (eh - 360 if 'top' in edges else 0), ew, eh]; got = frame('a')
    check(f'{what}: the opposite edge stays on the canvas', got == want, {'before': f0, 'after': got, 'want': want})
    asked = setters(since, 'a'); n1 = status('a')['bounds']
    check(f'{what}: the native window keeps its own top-left (no setter moved it)', n1[:2] == n0[:2] and asked and all(l.endswith(' moved=0') for l in asked), {'before': n0, 'after': n1, 'setters': len(asked)})
    check(f'{what}: the transaction completed', ' phase=complete' in ended(since, 'a')[-1], ended(since, 'a'))
    clicked('a', what)

# 2. Thirty drag events with nothing between them: one size is asked at a time, the latest replaces the one waiting, and
# the last size asked is where the pointer ended.
sized('a', 480, 360, '2'); f0 = frame('a')
since = down('a', [5/6, 5/6], what='2'); until('2: a resize grab began', 2, lambda: grab(since), bool)
drag(150, 90, '2', steps=30, pause=0); up('2')
until('2: the transaction ends', 5, lambda: ended(since, 'a'), bool)
asked = setters(since, 'a')
check('2: thirty drag events asked fewer than thirty sizes, and the last is the final one', 0 < len(asked) < 30 and ' requested=630x450 ' in asked[-1], {'setters': len(asked), 'last': asked[-1] if asked else None})
agreed('2: the window and the canvas end where the pointer did', 'a', [630, 450]); check('2: the top-left stays', frame('a')[:2] == f0[:2], {'before': f0, 'after': frame('a')})
clicked('a', '2')

# 11. A pointer held still for three seconds in the middle of a grab: the grab is still the press's, and the size follows
# the next motion.
sized('a', 480, 360, '11'); since = down('a', [5/6, 5/6], what='11')
drag(20, 20, '11', steps=2); agreed('11: the first motion is followed', 'a', [500, 380])
time.sleep(3.2)
check('11: nothing ended the grab while the pointer rested', not ended(since, 'a'), ended(since, 'a'))
reply = pointer(phase='drag', to=[60, 40]); check('11: the next motion is taken', 'Ok' in reply, reply)
agreed('11: and the size follows it', 'a', [540, 400]); up('11')
until('11: the transaction ends', 5, lambda: ended(since, 'a'), bool); check('11: completed', ' phase=complete' in ended(since, 'a')[-1], ended(since, 'a'))
clicked('a', '11')

# 6. resize-window-snapped: N, a snap gap to the right of A, follows A's right edge by what A's window took, and its own
# window is asked for nothing. The plain binding leaves it where it is.
sized('a', 480, 360, '6'); a = frame('a'); nw, nh = native('n')
place('n', a[0] + a[2] + 12 + nw // 2, -(a[1] + nh // 2)); time.sleep(.3)
n = frame('n'); check('6: N is a snap gap to the right of A', n[0] == a[0] + a[2] + 12 and n[1] == a[1], {'a': a, 'n': n})
nb = status('n')['bounds']
since = down('a', [5/6, .5], modifiers=('alt', 'shift'), what='6')
line = until('6: the press is traced', 2, lambda: press_line(since), bool)[0]
check('6: alt + shift + right is bound to resize-window-snapped', ' trigger=right binding=resize_window_snapped ' in line, line)
began = until('6: a resize grab began', 2, lambda: grab(since), bool)[0]; check('6: it carries the cluster', ' edges=right group=1 ' in began, began)
drag(40, 0, '6'); up('6'); until('6: the transaction ends', 5, lambda: ended(since, 'a'), bool)
agreed('6: A grew by 40', 'a', [520, 360]); a2 = frame('a'); n2 = frame('n')
check('6: N moved on the canvas by what A\'s window took', n2 == [n[0] + 40, n[1], n[2], n[3]] and a2[:2] == a[:2], {'a': [a, a2], 'n': [n, n2]})
check('6: N\'s own window was neither resized nor moved', status('n')['bounds'] == nb and not setters(since, 'n'), {'before': nb, 'after': status('n')['bounds'], 'requests': setters(since, 'n')})
# Plain: A's right edge is held by the snap to N until the drag has retreated the break force (24), then follows.
since = down('a', [5/6, .5], what='6 plain'); began = until('6 plain: a resize grab began', 2, lambda: grab(since), bool)[0]
check('6 plain: resize-window carries no cluster', ' edges=right group=0 ' in began, began)
drag(-80, 0, '6 plain'); up('6 plain'); until('6 plain: the transaction ends', 5, lambda: ended(since, 'a'), bool)
agreed('6 plain: A shrank by 80', 'a', [440, 360]); check('6 plain: N stayed where it was', frame('n') == n2 and status('n')['bounds'] == nb, {'before': n2, 'after': frame('n')})
clicked('a', '6'); away('n'); time.sleep(.2)

# 7. Upstream's resize border: a left press with no modifier, four points outside A's right edge, resizes by that edge.
sized('a', 480, 360, '7'); f0 = frame('a')
probe = pointer(phase='probe', window=ids['a'], at=[1, .5], offset=[4, 0])
check('7: four points right of A\'s frame is its resize border, right edge', probe.get('Ok', {}).get('DebugPointer', {}).get('border') == 'right' and probe['Ok']['DebugPointer']['hit'] is None, probe)
since = down('a', [1, .5], button='left', modifiers=(), offset=[4, 0], what='7')
line = until('7: the press is traced', 2, lambda: press_line(since), bool)[0]
check('7: an unbound left press on the border starts a resize by that edge', ' trigger=left binding=none border=right ' in line, line)
began = until('7: a resize grab began', 2, lambda: grab(since), bool)[0]; check('7: by the right edge, without the cluster (decoration_resize_snapped is off)', ' edges=right group=0 ' in began, began)
until('7: the border press raises and focuses A', 2, focused, lambda f: f == [ids['a']])
drag(30, 0, '7'); up('7'); until('7: the transaction ends', 5, lambda: ended(since, 'a'), bool)
agreed('7: A grew by 30', 'a', [510, 360]); check('7: the left edge stays', frame('a') == [f0[0], f0[1], 510, 360], {'before': f0, 'after': frame('a')})
far_out = pointer(phase='probe', window=ids['a'], at=[1, .5], offset=[12, 0])
check('7: twelve points out is no window and no border', 'Err' in far_out, far_out)
clicked('a', '7')

# 7b. The two keys of the border, changed in the config file and reloaded. decoration_resize_snapped: the border's resize
# carries the cluster, since an edge drag has no modifier to say so. resize_on_border = false: the band takes no press.
base = (evidence / 'config.toml').read_text()
def reload(extra, what):
    (evidence / 'config.toml').write_text(base + extra); reply = ask({'Action': 'reload-config'})
    if 'Ok' not in reply: fail(f'{what}: reload-config', reply)
    time.sleep(.3)
reload('[mouse]\ndecoration_resize_snapped = true\n', '7b')
sized('a', 480, 360, '7b'); a = frame('a'); nw, nh = native('n'); place('n', a[0] + a[2] + 12 + nw // 2, -(a[1] + nh // 2)); time.sleep(.3)
n = frame('n'); check('7b: N is a snap gap to the right of A', n[0] == a[0] + a[2] + 12, {'a': a, 'n': n}); nb = status('n')['bounds']
since = down('a', [1, .5], button='left', modifiers=(), offset=[4, 0], what='7b')
began = until('7b: a resize grab began', 2, lambda: grab(since), bool)[0]; check('7b: with decoration_resize_snapped the border\'s resize carries the cluster', ' edges=right group=1 ' in began, began)
drag(30, 0, '7b'); up('7b'); until('7b: the transaction ends', 5, lambda: ended(since, 'a'), bool)
agreed('7b: A grew by 30', 'a', [510, 360]); n2 = frame('n')
check('7b: N moved by what A\'s window took, and its own window was left alone', n2 == [n[0] + 30, n[1], n[2], n[3]] and status('n')['bounds'] == nb and not setters(since, 'n'), {'n': [n, n2], 'native': [nb, status('n')['bounds']]})
away('n'); time.sleep(.2)
reload('[mouse]\nresize_on_border = false\n', '7b')
off = pointer(phase='probe', window=ids['a'], at=[1, .5], offset=[4, 0])
check('7b: with resize_on_border off the band is no border', 'Err' in off, off)
reload('', '7b'); on = pointer(phase='probe', window=ids['a'], at=[1, .5], offset=[4, 0])
check('7b: and it is one again with the default', on.get('Ok', {}).get('DebugPointer', {}).get('border') == 'right', on)

# 7c. Ordinary unmodified presses just inside every edge and corner, through
# the normal capture-overlay handlers. Measure display points against the full
# projected frame after native readback, at three zooms. No physical mouse is
# moved: this establishes handler/adapter geometry on owned windows only.
for zoom in (.5, .8, 1.):
    reply = ask({'Zoom': zoom}); check(f'7c zoom {zoom}: request accepted', 'Ok' in reply, reply)
    until(f'7c zoom {zoom}: settled', 5, State, lambda s: abs(s['zoom'] - zoom) < 1e-8); show('a')
    for edges, fx, fy in [('left', 0., .5), ('right', 1., .5), ('top', .5, 0.), ('bottom', .5, 1.),
                          ('top_left', 0., 0.), ('top_right', 1., 0.), ('bottom_left', 0., 1.), ('bottom_right', 1., 1.)]:
        what = f'7c {edges} zoom {zoom}'
        sized('a', 480, 360, what); show('a'); f0 = frame('a')
        left, right, top, bottom = ('left' in edges, 'right' in edges, 'top' in edges, 'bottom' in edges)
        offset = [2 if left else -2 if right else 0, 2 if top else -2 if bottom else 0]
        before = pointer(phase='probe', window=ids['a'], at=[fx, fy], offset=offset)
        check(f'{what}: the press is on A\'s own frame', before.get('Ok', {}).get('DebugPointer', {}).get('hit') == ids['a'], before)
        start = before['Ok']['DebugPointer']['screen']; full0 = before['Ok']['DebugPointer']['screen_rect']
        since = down('a', [fx, fy], button='left', modifiers=(), offset=offset, what=what)
        began = until(f'{what}: normal edge begins a resize grab', 2, lambda: grab(since), bool)[0]
        check(f'{what}: the correct edge was retained', f' edges={edges} group=0 ' in began, began)
        dx = (-40 if left else 40 if right else 0) * zoom
        dy = (-24 if top else 24 if bottom else 0) * zoom
        drag(dx, dy, what, steps=3, pause=.02); up(what)
        until(f'{what}: completed', 5, lambda: ended(since, 'a'), bool)
        want = [520 if left or right else 480, 384 if top or bottom else 360]
        agreed(f'{what}: native readback is the canvas size', 'a', want)
        projected = pointer(phase='probe', window=ids['a'], at=[fx, fy], offset=offset)['Ok']['DebugPointer']
        full = projected['screen_rect']; actual = projected['screen']; f1 = frame('a')
        # The same fractional edge plus its original inward offset must now
        # be where the pointer ended, independently of native top-left.
        check(f'{what}: visible edge tracks the pointer in display points',
              (not (left or right) or abs(actual[0] - start[0] - dx) <= 1.1) and
              (not (top or bottom) or abs(actual[1] - start[1] - dy) <= 1.1),
              {'start': start, 'pointer_end': [start[0] + dx, start[1] + dy], 'edge_with_offset': actual,
               'full_frame_before': full0, 'full_frame_after': full, 'world_before': f0, 'world_after': f1})
clicked('a', '7c: after zoomed ordinary edge grabs')

# 3. A minimum and a maximum. The drag asks for more than the window allows; the window ends at its limit and the canvas
# has that size. From the left edge the opposite edge stays for the size the window took. Unlike upstream's client, a Mac
# window does not declare its limits: each size past one is asked and refused.
away('a'); limits = status('b')['limits']
show('b', -200, -150); sized('b', limits['min'][0], limits['min'][1], '3'); time.sleep(.2); f0 = frame('b')
since = down('b', [5/6, 5/6], what='3 maximum'); until('3: a resize grab began', 2, lambda: grab(since), bool)
drag(400, 350, '3 maximum', steps=8); up('3 maximum'); until('3 maximum: the transaction ends', 8, lambda: ended(since, 'b'), bool)
agreed('3: dragged past its maximum the window ends at it', 'b', limits['max'])
check('3: the top-left stays, and some request was answered clamped', frame('b')[:2] == f0[:2] and any(' outcome=clamped ' in l for l in setters(since, 'b')), {'frame': [f0, frame('b')], 'outcomes': sorted({re.search(r'outcome=(\w+)', l).group(1) for l in setters(since, 'b')})})
clicked('b', '3 maximum')
f0 = frame('b'); since = down('b', [1/6, .5], what='3 minimum'); began = until('3: a resize grab began', 2, lambda: grab(since), bool)[0]
check('3 minimum: the grab is the left edge\'s', ' edges=left ' in began, began)
drag(450, 0, '3 minimum', steps=8); up('3 minimum'); until('3 minimum: the transaction ends', 8, lambda: ended(since, 'b'), bool)
took = agreed('3: dragged below its minimum the window ends at it', 'b', [limits['min'][0], limits['max'][1]])
want = [f0[0] + f0[2] - took[0], f0[1], took[0], took[1]]
check('3 minimum: the right edge stays for the size the window took', frame('b') == want, {'before': f0, 'after': frame('b'), 'want': want})
ok('3: what the adapter answered while B was dragged below its minimum', sorted({re.search(r'outcome=(\w+)', l).group(1) for l in setters(since, 'b')}))
clicked('b', '3 minimum')

# 4. A resize increment: the window ends on a whole step at or below the size asked, and the canvas has that size.
away('b'); show('c'); time.sleep(.3); c0 = native('c'); agreed('4: C before', 'c')
since = down('c', [5/6, .5], what='4'); until('4: a resize grab began', 2, lambda: grab(since), bool)
drag(50, 0, '4'); up('4'); until('4: the transaction ends', 5, lambda: ended(since, 'c'), bool)
got = agreed('4: the canvas has the size C took', 'c')
check('4: C ends on a whole step within one step of the 50 asked', (got[0] - c0[0]) % 37 == 0 and 0 <= c0[0] + 50 - got[0] < 37 and got[1] == c0[1], {'start': c0, 'asked': [c0[0] + 50, c0[1]], 'took': got})
clicked('c', '4')

# 5. A window that takes no size: the press still raises and focuses it, nothing is resized, the grab ends by itself and
# leaves nothing held.
away('c'); show('f'); time.sleep(.3)
check('5: C still holds the focus before the press on F', focused() == [ids['c']], focused())
f0 = frame('f'); n0 = status('f')['bounds']
since = down('f', [.5, .5], what='5'); line = until('5: the press is traced', 2, lambda: press_line(since), bool)[0]
check('5: the press is the right button\'s, bound to resize-window', ' button=1 trigger=right binding=resize_window ' in line, line)
until('5: the press raises and focuses F', 2, focused, lambda f: f == [ids['f']])
drag(40, 30, '5'); time.sleep(.3); up('5'); released = time.time()
until('5: the transaction ends within a second of the release', 1, lambda: ended(since, 'f'), bool)
answers = [l for l in trace()[since:] if l.startswith(('debug: native resize ', 'debug: native size read ')) and f" pid={status('f')['pid']} " in l]
ok('5: what the adapter answered for a window that cannot be resized', [re.search(r'native (resize|size read) .*outcome=(\w+)', l).groups() for l in answers])
check('5: nothing was resized, on the canvas or natively', frame('f') == f0 and status('f')['bounds'] == n0, {'canvas': [f0, frame('f')], 'native': [n0, status('f')['bounds']]})
sized_after = resize('f', f0[2], f0[3]); check('5: no size transaction is left behind', sized_after.returncode == 0, sized_after.stderr.strip() or sized_after.stdout.strip())
clicked('f', '5')

# 8. preserve_aspect_ratio: the window keeps the width / height it has when the grab begins. From an edge that axis drives;
# from a corner the axis that moved farther relative to the ratio does (upstream constrain_to_ratio).
away('f'); show('p'); sized('p', 400, 300, '8')
def ratio(what, at, dx, dy, want):
    sized('p', 400, 300, what); since = down('p', at, what=what); began = until(f'{what}: a resize grab began', 2, lambda: grab(since), bool)[0]
    check(f'{what}: the grab holds the ratio', ' ratio=1' in began, began)
    drag(dx, dy, what); up(what); until(f'{what}: the transaction ends', 5, lambda: ended(since, 'p'), bool)
    agreed(f'{what}: P ends at {want}', 'p', want, tol=1)
ratio('8 right edge +60', [5/6, .5], 60, 0, [460, round(460 * 300 / 400)])
ratio('8 corner, width drives (80 * 300 >= 10 * 400)', [5/6, 5/6], 80, 10, [480, 360])
ratio('8 corner, height drives (20 * 300 < 90 * 400)', [5/6, 5/6], 20, 90, [round(390 * 400 / 300), 390])
clicked('p', '8')

# 9. A window that closes in the middle of a grab, the pointer at rest: it leaves the canvas, the press still releases,
# and nothing is left held.
away('p'); show('k', -250, 0); show('a', 300, 0); sized('a', 480, 360, '9'); time.sleep(.2)
since = down('k', [5/6, 5/6], what='9'); until('9: a resize grab began', 2, lambda: grab(since), bool)
k0 = native('k'); drag(20, 20, '9', steps=2); agreed('9: K follows the drag', 'k', [k0[0] + 20, k0[1] + 20])
title = status('k')['title']; (evidence / 'k' / 'close').write_text('1'); closed = time.time()
until('9: the closed window leaves the canvas within 3 s', 3, lambda: [w['title'] for w in windows()], lambda t: title not in t)
ok('9: the closed window left the canvas', {'seconds': round(time.time() - closed, 2), 'transaction': ended(since, 'k')})
moved = pointer(phase='drag', to=[30, 30]); check('9: a drag after the close is taken', 'Ok' in moved, moved); up('9')
ok('9: a drag after the close asks nothing; the release answers Ok', {'drag': moved, 'setters after the close': len([l for l in setters(since, 'k') if ' requested=' in l and ' observed=0' in l])})
show('a', 300, 0); time.sleep(.2); clicked('a', '9: after the close')
check('9: another window is sizable at once', resize('a', 500, 380).returncode == 0, 'msg resize a 500 380'); agreed('9: and was resized', 'a', [500, 380])

# 10. An application that stops answering in the middle of a grab, before the next size is asked of it: the request is
# refused by a window that cannot be reached, the grab ends by itself, the release is taken, and a click on another window
# lands. 10b is the application that takes the size and never answers.
show('h', -250, 0); show('a', 300, 0); sized('a', 480, 360, '10'); time.sleep(.2)
since = down('h', [5/6, 5/6], what='10'); until('10: a resize grab began', 2, lambda: grab(since), bool)
h0 = native('h'); drag(20, 20, '10', steps=2); agreed('10: H follows the drag', 'h', [h0[0] + 20, h0[1] + 20])
(evidence / 'h' / 'hang').write_text('4'); time.sleep(.5); hung = time.time()
reply = pointer(phase='drag', to=[60, 60]); check('10: a drag over the hung application is taken', 'Ok' in reply, reply)
time.sleep(.2); up('10')
live = not ended(since, 'h'); clicked('a', '10: while H does not answer')
ok('10: the click on A landed while H\'s transaction was still unresolved' if live else '10: H\'s transaction had already ended when the click on A was made', {'seconds since the hang': round(time.time() - hung, 2), 'ended': ended(since, 'h')})
until('10: H\'s transaction ends within 8 s of the hang', max(.1, 8 - (time.time() - hung)), lambda: ended(since, 'h'), bool)
ok('10: H\'s transaction ended', {'seconds': round(time.time() - hung, 2), 'line': ended(since, 'h')[-1], 'answers': [re.search(r'native (resize|size read) .*outcome=(\w+) observed=(\d)', l).groups() for l in trace()[since:] if l.startswith(('debug: native resize ', 'debug: native size read ')) and f" pid={status('h')['pid']} " in l]})
clicked('a', '10: after H\'s transaction ended')
until('10: H answers again', 8, lambda: time.time() - (evidence / 'h' / 'status.json').stat().st_mtime, lambda age: age < .3)
agreed('10: the canvas has the size H\'s window has', 'h', seconds=5); clicked('h', '10: H after it answers again')

# 10b. The application takes the size and never answers the request (it blocks inside its own resize). Nothing can say
# whether the size was taken: the transaction stays unresolved until the adapter's deadline and one more read. The release
# is taken at once, a click on another window lands meanwhile, and in the end the canvas has the size H's window has.
h1 = native('h'); since = down('h', [5/6, 5/6], what='10b'); until('10b: a resize grab began', 2, lambda: grab(since), bool)
drag(20, 20, '10b', steps=2); agreed('10b: H follows the drag', 'h', [h1[0] + 20, h1[1] + 20])
(evidence / 'h' / 'stall').write_text('4'); time.sleep(.5); stalled = time.time()
reply = pointer(phase='drag', to=[60, 60]); check('10b: the drag that stalls H is taken', 'Ok' in reply, reply)
time.sleep(.2); up('10b'); live = not ended(since, 'h')
clicked('a', '10b: while H\'s size request is unanswered'); still = not ended(since, 'h')
check('10b: H\'s transaction was unresolved when the click on A was made', live, {'unresolved before the click': live, 'and after it': still, 'seconds since the stall': round(time.time() - stalled, 2)})
other = resize('a', 500, 380)
ok('10b: msg resize of another window meanwhile', 'refused as pending: ' + (other.stderr.strip() or other.stdout.strip()) if other.returncode else 'taken: H\'s transaction had ended')
until('10b: H\'s transaction ends within 8 s', max(.1, 8 - (time.time() - stalled)), lambda: ended(since, 'h'), bool)
ok('10b: H\'s transaction ended', {'seconds': round(time.time() - stalled, 2), 'line': ended(since, 'h')[-1], 'answers': [re.search(r'native (resize|size read) .*outcome=(\w+) observed=(\d)', l).groups() for l in trace()[since:] if l.startswith(('debug: native resize ', 'debug: native size read ')) and f" pid={status('h')['pid']} " in l]})
clicked('a', '10b: after H\'s transaction ended')
until('10b: H answers again', 8, lambda: time.time() - (evidence / 'h' / 'status.json').stat().st_mtime, lambda age: age < .3)
agreed('10b: the canvas has the size H\'s window took', 'h', [h1[0] + 60, h1[1] + 60], seconds=5); clicked('h', '10b: H after it answers again')

# 11b. A pinned native window keeps one display point per native point at every
# canvas zoom. The real adapter settles the size; DebugPointer reads the visible
# frame before/after and verifies the grabbed edge and opposite edge separately.
away('h')
for zoom in (.5, .8):
    reply = ask({'Zoom': zoom}); check(f'11b zoom {zoom}: accepted', 'Ok' in reply, reply)
    until(f'11b zoom {zoom}: settled', 5, State, lambda v: abs(v['zoom']-zoom)<1e-8)
    for edges, fx, fy, dx, dy in [('right',1.,.5,24,0),('left',0.,.5,-24,0),
                                  ('bottom_right',1.,1.,24,16),('top_left',0.,0.,-24,-16)]:
        what=f'11b pinned {edges} zoom {zoom}'
        sized('a',480,360,what); show('a')
        done=msg('pin','on','--id',str(ids['a'])); check(f'{what}: pinned',done.returncode==0,done.stderr)
        offset=[2 if 'left' in edges else -2 if 'right' in edges else 0,
                2 if 'top' in edges else -2 if 'bottom' in edges else 0]
        before=pointer(phase='probe',window=ids['a'],at=[fx,fy],offset=offset)['Ok']['DebugPointer']
        since=down('a',[fx,fy],button='left',modifiers=(),offset=offset,what=what)
        began=until(f'{what}: edge grab began',2,lambda:grab(since),bool)[0]
        check(f'{what}: edge and no cluster',f' edges={edges} group=0 ' in began,began)
        drag(dx,dy,what,steps=3,pause=.02);up(what)
        until(f'{what}: native transaction completed',5,lambda:ended(since,'a'),bool)
        want=[480+abs(dx),360+abs(dy)]
        def pin(): return next((w for w in State()['pinned'] if w['id']==ids['a']),None)
        settled=until(f'{what}: native size and pin agree',3,lambda:{'native':native('a'),'pin':pin()},
                      lambda v:v['native']==want and v['pin'] and v['pin']['size']==want)
        after=pointer(phase='probe',window=ids['a'],at=[fx,fy],offset=offset)['Ok']['DebugPointer']
        a,b=before['screen'],after['screen']
        check(f'{what}: edge tracks unscaled screen motion',
              (not dx or abs(b[0]-a[0]-dx)<=1.1) and (not dy or abs(b[1]-a[1]-dy)<=1.1),
              {'before':before,'after':after,'native':settled})
        def box(r): return [r['origin']['x'],r['origin']['y'],r['size']['width'],r['size']['height']]
        first,last=box(before['screen_rect']),box(after['screen_rect'])
        check(f'{what}: opposite corner fixed',
              abs((first[0]+(first[2] if dx<0 else 0))-(last[0]+(last[2] if dx<0 else 0)))<=1.1 and
              abs((first[1]+(first[3] if dy<0 else 0))-(last[1]+(last[3] if dy<0 else 0)))<=1.1,
              [first,last])
        done=msg('pin','off','--id',str(ids['a']));check(f'{what}: unpinned',done.returncode==0,done.stderr)
clicked('a','11b: click after pinned resizing')

# 12. Nothing but the scope was acted on, nothing was refused as unsettled or gated, and no transaction is left.
z = status('z')
check('12: decoy took no event, was never activated and has its bounds', z['counts'] | {'raf': 0} == decoy['counts'] | {'raf': 0} and z['activations'] == 0 and z['bounds'] == decoy['bounds'], {'bounds': z['bounds'], 'activations': z['activations']})
lines = trace(); allowed = {status(n)['pid'] for n in scope}
named = {int(p) for l in lines if l.startswith('debug:') for p in re.findall(r'(?<![a-z_])pid=(\d+)', l)}
check('12: every pid acted on is in the scope', named and named <= allowed, {'named': sorted(named), 'scope': sorted(allowed), 'decoy': decoy['pid']})
check('12: no press or tile was refused as unsettled', not any('source presentation unsettled' in l for l in lines), [l for l in lines if 'unsettled' in l])
check('12: nothing said a pointer resize is gated', not any('gated behind' in l for l in lines), [l for l in lines if 'gated behind' in l])
grabs = [l for l in lines if l.startswith('debug: resize grab ')]; over = {re.search(r'transaction (\d+) ', l).group(1) for l in lines if l.startswith('debug: size transaction ')}
left = [l for l in grabs if re.search(r'transaction=(\d+) ', l).group(1) not in over]
check('12: every resize grab\'s transaction ended', grabs and not left, {'grabs': len(grabs), 'not ended': left})
check('12: the one slot is free at the end', resize('a', 480, 360).returncode == 0, 'msg resize a 480 360'); agreed('12: and A was resized', 'a', [480, 360])
outcomes = {}
for l in lines:
    m = re.match(r'debug: native (resize|size read) .* outcome=(\w+)', l)
    if m: outcomes[f'{m.group(1)} {m.group(2)}'] = outcomes.get(f'{m.group(1)} {m.group(2)}', 0) + 1
ok('12: what the native adapter answered, by outcome', outcomes)
PY

launch() { : > "$evidence/err.log"; INFINIFY_DEBUG=1 "$app" --windowed 1100x700 --state "$state" --config "$config" --socket "$socket" --no-hover-forwarding "$@" 2>"$evidence/err.log" & infinify=$!
  n=0; while [ ! -S "$socket" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done; [ -S "$socket" ] || { echo "FAIL: no socket: $(cat "$evidence/err.log")"; exit 1; }; }
shown() { grep -q '"visible":true' "$evidence/$1/status.json" 2>/dev/null; }
for name in a b c f n p k h z; do
  n=0; while ! shown "$name" && [ "$n" -lt 150 ]; do sleep .1; n=$((n+1)); done
  shown "$name" || { echo "FAIL: fixture $name never showed its window"; exit 1; }
done
sleep .5
launch --debug-pointer --only-pid "$A,$B,$C,$F,$N,$P,$K,$H"
python3 "$evidence/driver.py" "$evidence" "$app"
quit; [ "$gone" = yes ] || { echo 'FAIL: Infinify did not quit within 8 s of msg action quit'; exit 1; }
echo 'ok: quit within 8 s'
echo 'PASS: scoped resize drag: the nine cells, zoomed ordinary and pinned edges/corners, coalesced requests, a pointer at rest, minimum, maximum and increment, a window that takes no size, the snapped cluster, the resize border, preserve_aspect_ratio, a window closed and an application hung or stalled mid-grab; decoy untouched'
