#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The managed product on windows of this test's own processes only (`--only-pid`), end to end and without Screen
# Recording access if there is none: disposable fixture applications are started, Infinify manages exactly those, a
# left press and release is made on a fixture's tile through the DebugPointer request, and the fixture itself says
# whether focus arrived and where the click landed. A third fixture left out of the scope must not be touched.
#
# Everything acted on is a process this script started. It takes the foreground from whatever application has it (a
# click focuses its window, as the product does) and holds it until the fixtures exit, when macOS returns it. The pointer is never moved and nothing is
# posted at the session level. Run it while nothing else needs the keyboard: a foreground change in the middle of a
# focus request cancels that request, as it should, and fails the click that made it.
#
# Exit status: 0 everything was checked and held; 1 something failed; 3 nothing failed but the run was not whole, because a
# window of another application lay over a fixture (SKIPPED) or another application took the foreground after a click had
# landed (DISTURBED), or because Stage Manager is on and nothing was started (NOT RUN). The last line names what was not
# checked. 2 is a usage error.
set -eu
cd "$(dirname "$0")/../.."
[ "$#" -ne 0 ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to validate disposable managed windows'; exit 0; }
[ "$#" -eq 1 ] && [ "$1" = --live-owned-fixture ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }
root=$PWD
# Stage Manager keeps every window outside the current set as a thumbnail at the side, a fixture's among them: nothing here
# could be adopted or clicked, and the run would take the foreground only to fail on that. The setting is read, never written.
[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" != 1 ] || { echo 'NOT RUN: Stage Manager is on (com.apple.WindowManager GloballyEnabled is 1); nothing was started and nothing was checked. Run it with Stage Manager off.'; exit 3; }
app=$root/target/app/Infinify.app/Contents/MacOS/Infinify
[ -x "$app" ] || ./scripts/build-app.sh
mkdir -p target/ipc
# Short: a socket path has room for about a hundred bytes.
evidence=$(mktemp -d "$root/target/ipc/scope.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
state=$evidence/state.json; config=$evidence/config.toml; socket=$evidence/s; : > "$config"
infinify=; fixtures=
quit() {
  [ -n "$infinify" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 30 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify" 2>/dev/null; then kill "$infinify" 2>/dev/null || true; gone=no; else gone=yes; fi
  wait "$infinify" 2>/dev/null || true; infinify=
}
# Only what this script started is ever signalled.
cleanup() { quit; for pid in $fixtures; do kill "$pid" 2>/dev/null || true; done; for pid in $fixtures; do wait "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# Each launch below is refused before anything opens. Should one not be, it would be a run that manages: it is given two
# seconds, then killed and failed, and its home is a directory of this test's so that the one without --state has no real scene to load.
# The process named is a placeholder of this script's own; 4194304 is above the largest process id there can be.
sleep 120 & P=$!; fixtures="$fixtures $P"
mkdir "$evidence/home"
refused() {
  what=$1; shift; rm -f "$socket"
  HOME=$evidence/home CFFIXED_USER_HOME=$evidence/home "$app" --windowed 1100x700 --config "$config" --socket "$socket" "$@" 2>"$evidence/usage.log" & r=$!
  n=0; while kill -0 "$r" 2>/dev/null && [ "$n" -lt 20 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$r" 2>/dev/null; then kill "$r" 2>/dev/null || true; wait "$r" 2>/dev/null || true; echo "FAIL: $what: still running after 2 s and killed, $(cat "$evidence/usage.log")"; exit 1; fi
  if wait "$r"; then code=0; else code=$?; fi
  if [ "$code" -ne 64 ] || grep -q '^Managing' "$evidence/usage.log" || [ -e "$socket" ] || [ -n "$(ls -A "$evidence/home")" ]; then echo "FAIL: $what: exit $code, $(cat "$evidence/usage.log")"; exit 1; fi
  echo "ok: $what: exit 64, $(cat "$evidence/usage.log")"
}
refused 'a process that does not exist' --state "$state" --only-pid 4194304
refused "another user's process" --state "$state" --only-pid 1
refused 'a scope with the chooser' --state "$state" --only-pid "$P" --manual
refused 'a process named twice' --state "$state" --only-pid "$P,$P"
refused '--debug-pointer without a scope' --state "$state" --debug-pointer
refused 'a scope on the default scene (no --state)' --only-pid "$P"
kill "$P" 2>/dev/null || true

# The fixture: a minimal bundle, so that it has a bundle identifier, whose executable is run directly.
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
start() { mkdir "$evidence/$1"; "$fixture" "$evidence/$1" "$2" "$3" 110 & fixtures="$fixtures $!"; }
start a "Scope fixture A $$" -240; A=$!
start b "Scope fixture B $$" 240; B=$!
# Out of scope, started last so that it lies over the other two, and in the middle of where the canvas will be.
start z "Scope decoy Z $$" 0

cat > "$evidence/driver.py" <<'PY'
import json, os, pathlib, re, socket, subprocess, sys, time
evidence = pathlib.Path(sys.argv[1]); app = sys.argv[2]; phase = sys.argv[3]
sock = str(evidence / 's'); errlog = evidence / 'err.log'
def ok(what, observed): print(f'ok: {what}: {observed}', flush=True)
def fail(what, observed):
    print(f'FAIL: {what}: {observed}', flush=True)
    if disturbed: print(f'This run was disturbed before that: {"; ".join(disturbed)}', flush=True)
    sys.exit(1)
# What could not be checked (SKIPPED) and what another application did to the run (DISTURBED): neither is a failure of the
# product, and either makes the script end with status 3.
skipped = []; disturbed = []
def note(): (evidence / 'skipped').write_text('; '.join(skipped + disturbed))
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
# One JSON line each way: what `Infinify msg` sends (crates/desktop/src/ipc_client.rs).
def ask(request):
    s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sock); s.sendall((json.dumps(request) + '\n').encode())
    data = b''
    while not data.endswith(b'\n'):
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    s.close(); return json.loads(data)
def msg(*args): return subprocess.run([app, 'msg', '--socket', sock, *args], capture_output=True, text=True)
def windows(): return ask('State')['Ok']['State']['windows']
def trace(): return errlog.read_text(errors='replace').splitlines()
def centre(report, control):
    x, y, w, h = report['controls'][control]; return [x + w / 2, y + h / 2]
def fraction(report, control):
    c = centre(report, control); return [c[0] / report['bounds'][2], c[1] / report['bounds'][3]]
def pointer(phase, window, at): return ask({'DebugPointer': {'phase': phase, 'window': window, 'at': at}})
def near(a, b): return a is not None and abs(a[0] - b[0]) <= 2 and abs(a[1] - b[1]) <= 2

if phase == 'unscoped':
    names = sys.argv[4:]; before = {n: status(n) for n in names}
    time.sleep(3)
    lines = trace()
    check('unscoped run without Screen Recording says it manages nothing', any(l.startswith('Windows are not managed: Infinify has no Screen Recording access') for l in lines), lines)
    check('unscoped run has no Managing line', not any(l.startswith('Managing only') for l in lines), lines)
    check('unscoped run has no windows', windows() == [], windows())
    reply = pointer('probe', 1, [.5, .5]); check('DebugPointer is refused without --debug-pointer', 'Err' in reply, reply)
    for n in names:
        now = status(n)
        check(f'fixture {n} untouched by the unscoped run', now['counts'] | {'raf': 0} == before[n]['counts'] | {'raf': 0} and now['activations'] == before[n]['activations'], {'counts': now['counts'], 'activations': now['activations']})
    sys.exit(0)

infinify = int(sys.argv[4])
scope = ['a', 'b']
reports = {n: status(n) for n in scope + ['z']}
decoy = status('z')
titles = sorted(status(n)['title'] for n in scope)

# Adoption: exactly the scope's windows, and still there, not suspended, three seconds on (a tile without a picture is not detached).
adopted = until('adopts exactly the scope', 8, windows, lambda w: sorted(x['title'] for x in w) == titles)
ok('adopts exactly the scope', [(w['id'], w['title']) for w in adopted])
managing = [l for l in trace() if l.startswith('Managing only')]
check('says what it manages', len(managing) == 1 and all(str(status(n)['pid']) in managing[0] for n in scope) and str(decoy['pid']) not in managing[0], managing)
pictureless = 'No Screen Recording access' in managing[0]
(evidence / 'pictureless').write_text('yes' if pictureless else 'no')
ok('Screen Recording', 'not granted: tiles have no picture' if pictureless else 'granted: tiles are captured')
time.sleep(1)
# Covered, and drawing all the same: the canvas panel lies over each fixture window, whose page keeps its animation frames.
def contains(outer, inner): return outer[0] <= inner[0] and outer[1] <= inner[1] and outer[0] + outer[2] >= inner[0] + inner[2] and outer[1] + outer[3] >= inner[1] + inner[3]
# That holds only while nothing but the canvas and this test's own windows lies over the fixture. A window of some other
# application in front of it (somebody is using the machine) hides it for real, and what the canvas does to it cannot then be
# seen: those assertions are skipped for that fixture, and said to be. The clicks below do not depend on it.
def overlaps(a, b): return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
own = {infinify} | {status(n)['pid'] for n in scope + ['z']}
def foreign(name): return [[pid, b] for r in [status(name)] for pid, b, _ in r['above'] if pid not in own and overlaps(b, r['bounds'])]
for name in ['a', 'b']:
    report = status(name); over = [number for pid, b, number in report['above'] if pid == infinify and contains(b, report['bounds'])]
    check(f'{name} lies whole under the canvas', bool(over), {'bounds': report['bounds'], 'above': report['above']})
    # Each fixture is asked to put its window directly under the canvas: a window of another application that had come between
    # them and the canvas is then under them, and nothing is skipped for it. One that lies over the canvas itself is not this
    # test's to move.
    (evidence / name / 'below').write_text(str(over[-1])); until(f'{name} took its place under the canvas', 2, lambda: (evidence / name / 'below').exists(), lambda there: not there)
time.sleep(.3)
for name in ['a', 'b']:
    report = status(name); check(f'{name} still lies whole under the canvas', any(pid == infinify and contains(b, report['bounds']) for pid, b, _ in report['above']), {'bounds': report['bounds'], 'above': report['above']})
for name in scope:
    # Looked for before and after the second measured: such a window may arrive in the middle of it.
    before = foreign(name); visible = status(name).get('occlusion_visible'); first = status(name)['counts']['raf']; time.sleep(1); second = status(name)['counts']['raf']; others = before + foreign(name)
    if others:
        skipped.append(f'{name} visible and drawing under the canvas'); print(f'SKIPPED: {name} visible and drawing under the canvas: a window of another application lies over it: {others}', flush=True); continue
    check(f'{name} is visible to the window server', visible is True, visible)
    check(f'{name} draws under the canvas (animation frames in 1 s)', second - first >= 30, second - first)
note()
for name in ['a', 'b']:
    report = status(name); check(f'{name} is not active before its click', not report['app_active'] and not report['key_window'], {'app_active': report['app_active'], 'key_window': report['key_window']})

time.sleep(1)
later = windows()
check('still adopted and not suspended after 3 s', sorted(x['title'] for x in later) == titles and not any(x['suspended'] for x in later), [(w['title'], w['suspended']) for w in later])
ids = {n: next(w['id'] for w in later if w['title'] == status(n)['title']) for n in scope}

# Layout: zoom 1, the tiles side by side so that every point aimed at is the tile's own.
state = ask('State')['Ok']['State']; check('zoom is 1', state['zoom'] == 1.0, state['zoom'])
cx, cy = state['camera']
def place(name, x):
    done = msg('move', '--id', str(ids[name]), str(int(x)), str(int(cy)))
    if done.returncode: fail(f'msg move {name}', done.stderr.strip())
place('a', cx - 250); place('b', cx + 250)
time.sleep(.3)
check('adoption and msg move asked for no native focus', not any('native focus' in l for l in trace()), [l for l in trace() if 'native focus' in l])
for name, control in [('a', 'web'), ('a', 'plain'), ('a', 'button'), ('b', 'plain'), ('b', 'web')]:
    report = status(name); reply = pointer('probe', ids[name], fraction(report, control))
    size = reply.get('Ok', {}).get('DebugPointer', {}).get('screen_rect', {}).get('size', {})
    check(f'probe {name}.{control} hits its own tile at the window\'s size', 'Ok' in reply and reply['Ok']['DebugPointer']['hit'] == ids[name] and abs(size['width'] - report['bounds'][2]) <= 1 and abs(size['height'] - report['bounds'][3]) <= 1, reply)
reply = pointer('probe', 987654, [.5, .5]); check('probe of an unknown window is refused', 'Err' in reply, reply)

# A click as a person makes it: press, the press reaches the window once its native focus has landed, release.
def click(name, control, hold):
    report = status(name); window = ids[name]; at = fraction(report, control); start = len(trace())
    reply = pointer('down', window, at)
    if 'Ok' not in reply: fail(f'press on {name}.{control}', reply)
    delivered = lambda: [l for l in trace()[start:] if l.startswith(f'debug: press #{window} delivered')]
    if hold is None: until(f'press on {name}.{control} is delivered', 2, delivered, bool)
    else: time.sleep(hold)
    reply = pointer('up', window, at)
    if 'Ok' not in reply: fail(f'release on {name}.{control}', reply)
    until(f'press on {name}.{control} is delivered', 2, delivered, bool)
    time.sleep(.1); return trace()[start:]
def traced(lines, name, pending, within, released=None):
    window = ids[name]; pid = status(name)['pid']
    press = [l for l in lines if l.startswith(f'debug: press #{window} pid={pid} ')]
    check(f'{name}: press traced with focus_pending={pending}', len(press) == 1 and press[0].endswith(f'focus_pending={pending}'), press)
    focus = [l for l in lines if l.startswith(f'debug: native focus pid={pid} ')]
    check(f'{name}: native focus answered focused', bool(focus) and all(re.search(r'outcome=(focused|observed) focused=1 ', l) for l in focus), focus)
    sent = [l for l in lines if l.startswith(f'debug: press #{window} delivered')]
    took = re.search(r'delivered after (\d+) ms sent=(\d)', sent[0]) if len(sent) == 1 else None
    check(f'{name}: press sent to the window within {within} ms', took and took.group(2) == '1' and int(took.group(1)) < within, sent)
    if released is not None: check(f'{name}: the release was already in when the press went', f' released={released} ' in sent[0], sent)
def landed(name, kinds, control, times):
    def read(): r = status(name); return {'counts': {k: r['counts'][k] for k in kinds}, 'last': {k: r['last'].get(k) for k in kinds}}
    want = centre(status(name), control)
    # Two seconds for the events to arrive, then a moment more to see that no second copy follows.
    until(f'{name}.{control} click arrives', 2, read, lambda v: all(v['counts'][k] >= times for k in kinds)); time.sleep(.3); seen = read()
    check(f'{name}.{control}: each event exactly {times} time(s)', all(seen['counts'][k] == times for k in kinds), seen['counts'])
    check(f'{name}.{control}: landed within 2 points of {want}', all(near(seen['last'][k], want) for k in kinds), seen['last'])
    fronted(name, kinds)
# What the application was as it handled each event is what the click is judged by. That it is no longer active a moment later
# is another application's doing (nothing of this test activates anything but through a click): said, with who has the foreground, and not failed.
def fronted(name, kinds):
    report = status(name); front = {k: report['front'].get(k) for k in kinds}
    check(f'{name}: active and key as each event was handled', all(f and all(f.values()) for f in front.values()), front)
    if not report['app_active']:
        disturbed.append(f'{name} lost the foreground to pid {report.get("frontmost")} after its click'); note()
        print(f'DISTURBED: {name} was active as its click landed and is not now: the frontmost application is pid {report.get("frontmost")}', flush=True)
web = ['web_down', 'web_up', 'web_click']; plain = ['plain_down', 'plain_up']

# Click 1: a web view in an inactive application. The press must wait for native focus, then land.
lines = click('a', 'web', None); traced(lines, 'a', 1, 500); landed('a', web, 'web', 1)
# Click 2: the same, now the focused window of the frontmost application: no wait. The answer to click 1's focus request is what
# the controller holds as observed (crates/desktop/src/lib.rs, FocusResult), so nothing is waited for but the application still
# being frontmost; where another has taken the foreground the click would rightly wait, and the run ends as disturbed.
report = status('a')
if report['frontmost'] != report['pid'] or not report['app_active']:
    print(f'DISTURBED: a is not frontmost before its second click: the frontmost application is pid {report["frontmost"]}', flush=True)
    print('INCOMPLETE: scoped windows. NOT CHECKED: everything from the second click on', flush=True); sys.exit(3)
lines = click('a', 'web', None); traced(lines, 'a', 0, 50); landed('a', web, 'web', 2)
# Click 3: a plain view (no first click) of the other, inactive application, released at once, while the press is still held for
# its focus: the release must follow the press into the window, not overtake it or be lost.
quiet = status('a')['counts']
lines = click('b', 'plain', 0); traced(lines, 'b', 1, 500, released=1); landed('b', plain, 'plain', 1)
now = status('a')['counts']; check('a took nothing of b\'s click', now | {'raf': 0} == quiet | {'raf': 0}, now)
if not disturbed: check('a is no longer active', not status('a')['app_active'], status('a')['app_active'])
# Click 4: a first-mouse control of the application that is inactive again.
lines = click('a', 'button', None); traced(lines, 'a', 1, 500)
pressed = until('a.button click arrives', 2, lambda: status('a'), lambda r: r['counts']['button_action'] >= 1); time.sleep(.3); pressed = status('a')
check('a.button: its action ran exactly once, and nothing else of a took the click', pressed['counts'] | {'raf': 0} == quiet | {'raf': 0, 'button_action': 1}, pressed['counts'])
fronted('a', ['button_action'])
# A press nobody releases: b's plain view again, inactive again. The DebugPointer request lets it go where it went down, five
# seconds on, which is the only thing that ends an injected press (-endLostInput leaves it alone).
report = status('b'); before = report['counts']; at = fraction(report, 'plain'); start = len(trace()); began = time.time()
reply = pointer('down', ids['b'], at)
if 'Ok' not in reply: fail('abandoned press on b.plain', reply)
until('abandoned press on b.plain arrives', 2, lambda: status('b')['counts'], lambda c: c['plain_down'] == before['plain_down'] + 1)
time.sleep(3); held = status('b')['counts']; check('abandoned press: no release in its first 3 s', held['plain_up'] == before['plain_up'], held)
let = until('abandoned press is released by itself', 4, lambda: status('b'), lambda r: r['counts']['plain_up'] == before['plain_up'] + 1); took = time.time() - began
check('abandoned press: released once, where it went down, about 5 s on', let['counts']['plain_down'] == before['plain_down'] + 1 and near(let['last']['plain_up'], centre(let, 'plain')) and 4.5 <= took <= 6.5, {'counts': let['counts'], 'last': let['last']['plain_up'], 'seconds': round(took, 2)})
reply = pointer('up', ids['b'], at); check('abandoned press: a release after it is refused', 'no DebugPointer press is down' in reply.get('Err', ''), reply)

# The decoy: a regular application's window on screen under the canvas, and nothing of this run reached it.
after = status('z')
check('decoy took no event and was never activated', after['counts'] | {'raf': 0} == decoy['counts'] | {'raf': 0} and after['activations'] == decoy['activations'] == 0 and not after['app_active'], {'counts': after['counts'], 'activations': after['activations'], 'app_active': after['app_active']})
final = windows(); check('still exactly the scope', sorted(x['title'] for x in final) == titles, [w['title'] for w in final])
allowed = {status(n)['pid'] for n in scope}
named = {int(p) for l in trace() if l.startswith('debug:') for p in re.findall(r'(?<![a-z_])pid=(\d+)', l)}
check('every pid acted on is in the scope', named and named <= allowed, {'named': sorted(named), 'scope': sorted(allowed), 'decoy': decoy['pid']})
lost = [l for l in trace() if 'A button release never arrived' in l]; check('no press was ended as lost', not lost, lost)
note()
PY

launch() { : > "$evidence/err.log"; INFINIFY_DEBUG=1 "$app" --windowed 1100x700 --state "$state" --config "$config" --socket "$socket" --no-hover-forwarding "$@" 2>"$evidence/err.log" & infinify=$!
  n=0; while [ ! -S "$socket" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done; [ -S "$socket" ] || { echo "FAIL: no socket: $(cat "$evidence/err.log")"; exit 1; }; }
# The fixtures' windows are on screen before Infinify starts: it then adopts them as windows that were already open, which it
# neither focuses nor reveals. A window that appears later is a new one, which gets the focus as any new window does.
# Each fixture says when its window is shown.
shown() { grep -q '"visible":true' "$evidence/$1/status.json" 2>/dev/null; }
for name in a b z; do
  n=0; while ! shown "$name" && [ "$n" -lt 150 ]; do sleep .1; n=$((n+1)); done
  shown "$name" || { echo "FAIL: fixture $name never showed its window: $(cat "$evidence/$name/status.json" 2>/dev/null)"; exit 1; }
done
sleep .5
launch --debug-pointer --only-pid "$A,$B"
python3 "$evidence/driver.py" "$evidence" "$app" scoped "$infinify"
quit; [ "$gone" = yes ] || { echo 'FAIL: Infinify did not quit within 3 s of msg action quit'; exit 1; }
echo 'ok: quit within 3 s'
cp "$evidence/err.log" "$evidence/scoped.err.log"

# With no scope nothing may differ. Only where there is no Screen Recording access can that be run: with it an unscoped run adopts every window on screen.
if [ "$(cat "$evidence/pictureless")" = yes ]; then
  # Its own scene file: the scoped run saved a slot for each of its windows, and this run must start with none.
  state=$evidence/unscoped-state.json
  launch
  python3 "$evidence/driver.py" "$evidence" "$app" unscoped a b z
  quit
else
  echo 'SKIPPED: unscoped step, Screen Recording is granted and an unscoped run would adopt real windows'
fi
skipped=$(cat "$evidence/skipped")
what='scoped windows: adoption of the scope only, native focus and click delivery on a web view, a plain view and a button, decoy untouched'
[ -z "$skipped" ] || { echo "INCOMPLETE: $what. NOT CHECKED: $skipped"; exit 3; }
echo "PASS: $what"
