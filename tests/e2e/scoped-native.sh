#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Native presentation (`--native-helper`) end to end, against the cooperative host of native/privileged: an ordinary process of
# this test's that owns three windows and carries the transform helper, which moves and scales that process's own windows and
# no other. Infinify is started scoped to the host (`--only-pid`) and pointed at the host's helper; it manages the host's windows
# and has the window server draw them where the canvas places them.
#
# What the window server shows is read by this test's own process, never taken from Infinify or from the helper: a window's
# screen rectangle is SLSGetScreenRectForWindow, its alpha kCGWindowAlpha. Where a window should be is computed from `msg state`
# (camera centre, zoom, each window's centre and size) and the canvas panel's rectangle in the window list, and compared with
# the DebugPointer probe's screen_rect where the probe answers.
#
# Tolerance, everywhere a window is "shown at" a rectangle: the expected rectangle is widened to the whole-point rectangle that
# contains it and each of the four numbers may then differ by one point. The window server reports the smallest whole-point
# rectangle containing what it draws, and keeps a transform as six 32-bit floats, so a product like -1056*2 is exact and one
# like -1247.6*1.3 is not.
#
# Nothing is loaded into Dock and no window of another application is touched: the helper refuses every window but its own
# host's, and Infinify refuses a helper that is not a cooperative host inside its scope. The pointer is never moved and nothing
# is posted at the session level. The focus step makes the host the frontmost application, as a focus request does.
#
# Exit status: 0 everything was checked and held; 1 something failed; 3 nothing failed but the run was not whole (Stage Manager
# on: NOT RUN; no Accessibility access: the focus and resize steps are SKIPPED). 2 is a usage error.
set -eu
cd "$(dirname "$0")/../.."
case ${1:-} in
  '') echo 'LIVE NOT RUN: pass --live-owned-fixture to launch and transform the disposable host windows.'; exit 0 ;;
  --live-owned-fixture) shift ;;
  *) echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }
root=$PWD
[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" != 1 ] || { echo 'NOT RUN: Stage Manager is on (com.apple.WindowManager GloballyEnabled is 1); nothing was started and nothing was checked. Run it with Stage Manager off.'; exit 3; }
if pgrep -f 'Infinify.app/Contents/MacOS/Infinify' >/dev/null 2>&1; then echo 'NOT RUN: another Infinify is running; nothing was started.'; exit 3; fi
app=$root/target/app/Infinify.app/Contents/MacOS/Infinify
[ -x "$app" ] || ./scripts/build-app.sh
[ -x target/privileged/host ] && [ -f target/privileged/payload-arm64.dylib ] || ./scripts/build-privileged.sh
mkdir -p target/ipc
# Short: a socket path has room for about a hundred bytes, the helper's among them.
evidence=$(mktemp -d "$root/target/ipc/native.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
state=$evidence/state.json; config=$evidence/config.toml; socket=$evidence/s; : > "$config"
runtime=$evidence/h; mkdir -m 700 "$runtime"
# ScreenCaptureKit needs a fixture with its own application identity. A bare
# executable launched under a desktop agent can inherit that agent's bundle identity
# and its windows can be omitted from the shareable-window list.
bundle=$evidence/CooperativeHost.app
mkdir -p "$bundle/Contents/MacOS"
cp "$root/target/privileged/host" "$bundle/Contents/MacOS/CooperativeHost"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.infinify.cooperative-host</string><key>CFBundleName</key><string>CooperativeHost</string><key>CFBundleExecutable</key><string>CooperativeHost</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
hostExecutable=$bundle/Contents/MacOS/CooperativeHost
# The nonce reaches Infinify in a file of mode 0600, never on its command line. (The host takes it as an argument: that is the
# cooperative fixture's own interface, and the nonce is this run's alone.)
nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); (umask 077; printf '%s\n' "$nonce" > "$evidence/nonce")
infinify=; host=; others=
quit() {
  [ -n "$infinify" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify" 2>/dev/null; then kill "$infinify" 2>/dev/null || true; gone=no; else gone=yes; fi
  wait "$infinify" 2>/dev/null || true; infinify=
}
# Only what this script started is ever signalled.
cleanup() { quit; for pid in $host $others; do kill "$pid" 2>/dev/null || true; done; for pid in $host $others; do wait "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# Usage. Each launch below ends before anything opens: 64 for an argument that cannot be right, 69 for a helper that is not
# there or is not this run's to drive. One that did open would manage: it is given four seconds, then killed and failed.
sleep 300 & P=$!; others="$others $P"
mkdir "$evidence/home" "$evidence/empty"; chmod 700 "$evidence/empty"
(umask 022; printf '%s\n' "$nonce" > "$evidence/nonce-open"); chmod 644 "$evidence/nonce-open"
(umask 077; printf 'not a nonce\n' > "$evidence/nonce-bad")
refused() {
  want=$1; what=$2; shift 2; rm -f "$socket"
  CFFIXED_USER_HOME=$evidence/home "$app" --windowed 1100x700 --config "$config" --socket "$socket" --state "$state" "$@" 2>"$evidence/usage.log" & r=$!
  n=0; while kill -0 "$r" 2>/dev/null && [ "$n" -lt 40 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$r" 2>/dev/null; then kill "$r" 2>/dev/null || true; wait "$r" 2>/dev/null || true; echo "FAIL: $what: still running after 4 s and killed, $(cat "$evidence/usage.log")"; exit 1; fi
  if wait "$r"; then code=0; else code=$?; fi
  if [ "$code" -ne "$want" ] || [ "$(grep -c '^Infinify: native helper ' "$evidence/usage.log")" -ne 1 ] || grep -q '^Managing' "$evidence/usage.log" || [ -e "$socket" ] || [ -n "$(ls -A "$evidence/home")" ]; then echo "FAIL: $what: exit $code, $(cat "$evidence/usage.log")"; exit 1; fi
  echo "ok: $what: exit $code, $(cat "$evidence/usage.log")"
}
refused 64 '--native-helper without a scope' --native-helper "$runtime" "$evidence/nonce"
refused 64 'desktop helper cannot be windowed' --native-desktop-helper "$runtime" "$evidence/nonce"
refused 64 'desktop helper cannot mix finite scope' --only-pid "$P" --native-desktop-helper "$runtime" "$evidence/nonce"
refused 64 'desktop helper cannot mix helper endpoints' --native-desktop-helper "$runtime" "$evidence/nonce" --native-helper "$runtime" "$evidence/nonce"
refused 64 'a relative runtime directory' --only-pid "$P" --native-helper h "$evidence/nonce"
refused 64 'one path only' --only-pid "$P" --native-helper "$runtime"
refused 64 'the same helper runtime twice' --only-pid "$P" --native-helper "$runtime" "$evidence/nonce" --native-helper "$runtime" "$evidence/nonce"
refused 64 'a runtime directory that is none' --only-pid "$P" --native-helper "$evidence/nonce" "$evidence/nonce"
refused 64 'a nonce file others can read' --only-pid "$P" --native-helper "$runtime" "$evidence/nonce-open"
refused 64 'a nonce file that holds no nonce' --only-pid "$P" --native-helper "$runtime" "$evidence/nonce-bad"
refused 64 'a nonce file that is not there' --only-pid "$P" --native-helper "$runtime" "$evidence/nonce-none"
refused 69 'a runtime directory with no helper in it' --only-pid "$P" --native-helper "$evidence/empty" "$evidence/nonce"

# The cooperative host: a regular application (one a window manager adopts) with three titled, resizable windows, and the
# helper inside it. It ends by itself after ten minutes whatever becomes of this script.
"$hostExecutable" "$root/target/privileged/payload-arm64.dylib" "$runtime" "$nonce" --windows 3 --activation regular --watchdog 600 >"$evidence/host.log" 2>&1 &
host=$!
n=0; while ! grep -q '^READY ' "$evidence/host.log" 2>/dev/null && [ "$n" -lt 80 ]; do sleep .1; n=$((n+1)); done
grep -q '^READY ' "$evidence/host.log" || { echo "FAIL: the host did not start: $(cat "$evidence/host.log")"; exit 1; }
[ -S "$runtime/v2.sock" ] || { echo "FAIL: the host's helper has no protocol v2 socket: $(cat "$evidence/host.log")"; exit 1; }
refused 69 'a helper whose process the scope does not name' --only-pid "$P" --native-helper "$runtime" "$evidence/nonce"
refused 69 'a cooperative helper cannot present a second process' --only-pid "$host,$P" --native-helper "$runtime" "$evidence/nonce"
kill "$P" 2>/dev/null || true
# A second disposable process is never named in Infinify's scope. Observe its window
# throughout the run, including its transform and alpha, independently of the helper.
mkdir -m 700 "$evidence/decoy-runtime"
cp -R "$bundle" "$evidence/Decoy.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.infinify.native-decoy' "$evidence/Decoy.app/Contents/Info.plist"
"$evidence/Decoy.app/Contents/MacOS/CooperativeHost" "$root/target/privileged/payload-arm64.dylib" "$evidence/decoy-runtime" "$nonce" --activation regular --watchdog 600 >"$evidence/decoy.log" 2>&1 &
others="$others $!"
n=0; while ! grep -q '^READY ' "$evidence/decoy.log" 2>/dev/null && [ "$n" -lt 80 ]; do sleep .1; n=$((n+1)); done
grep -q '^READY ' "$evidence/decoy.log" || { echo "FAIL: the decoy did not start: $(cat "$evidence/decoy.log")"; exit 1; }
sleep .5

cat > "$evidence/driver.py" <<'PY'
import ctypes as C, json, math, os, pathlib, re, signal, socket, subprocess, sys, time
evidence = pathlib.Path(sys.argv[1]); app = sys.argv[2]; phase = sys.argv[3]; infinify = int(sys.argv[4]); host = int(sys.argv[5])
sock = str(evidence / 's'); errlog = evidence / 'err.log'
def ok(what, observed): print(f'ok: {what}: {observed}', flush=True)
def fail(what, observed): print(f'FAIL: {what}: {observed}', flush=True); sys.exit(1)
def check(what, passed, observed): (ok if passed else fail)(what, observed)
skipped = []
def skip(what, why): skipped.append(what); print(f'SKIPPED: {what}: {why}', flush=True); (evidence / 'skipped').write_text('; '.join(skipped))
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
def msg(*args):
    done = subprocess.run([app, 'msg', '--socket', sock, *args], capture_output=True, text=True)
    if done.returncode: fail('msg ' + ' '.join(args), done.stderr.strip() or done.stdout.strip())
    return done.stdout.strip()
def state(): return ask('State')['Ok']['State']
def trace(): return errlog.read_text(errors='replace').splitlines()
def native(): return ask({'DebugNative': {}})['Ok']['DebugNative']

# The window server, asked from this process. As native/privileged/fixture_test.py asks it.
class Point(C.Structure): _fields_ = [('x', C.c_double), ('y', C.c_double)]
class Size(C.Structure): _fields_ = [('width', C.c_double), ('height', C.c_double)]
class Rect(C.Structure): _fields_ = [('origin', Point), ('size', Size)]
class Affine(C.Structure): _fields_ = [(k, C.c_double) for k in ('a', 'b', 'c', 'd', 'tx', 'ty')]
sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetWindowTransform.argtypes = [C.c_int, C.c_uint32, C.POINTER(Affine)]; sky.SLSGetWindowTransform.restype = C.c_int
for name in ('SLSGetScreenRectForWindow', 'SLSGetWindowBounds'):
    getattr(sky, name).argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]; getattr(sky, name).restype = C.c_int
cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGWindowListCopyWindowInfo.argtypes = [C.c_uint32, C.c_uint32]; cg.CGWindowListCopyWindowInfo.restype = C.c_void_p
cg.CGRectMakeWithDictionaryRepresentation.argtypes = [C.c_void_p, C.POINTER(Rect)]; cg.CGRectMakeWithDictionaryRepresentation.restype = C.c_bool
cg.CGGetActiveDisplayList.argtypes = [C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32)]; cg.CGGetActiveDisplayList.restype = C.c_int
cg.CGDisplayBounds.argtypes = [C.c_uint32]; cg.CGDisplayBounds.restype = Rect
cf.CFArrayGetCount.argtypes = [C.c_void_p]; cf.CFArrayGetCount.restype = C.c_long
cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]; cf.CFArrayGetValueAtIndex.restype = C.c_void_p
cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]; cf.CFDictionaryGetValue.restype = C.c_void_p
cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]; cf.CFNumberGetValue.restype = C.c_bool
cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]; cf.CFStringCreateWithCString.restype = C.c_void_p
cf.CFRelease.argtypes = [C.c_void_p]
def key(name): return cf.CFStringCreateWithCString(None, name, 0x08000100)
K_NUMBER, K_ALPHA, K_PID, K_LAYER, K_BOUNDS = key(b'kCGWindowNumber'), key(b'kCGWindowAlpha'), key(b'kCGWindowOwnerPID'), key(b'kCGWindowLayer'), key(b'kCGWindowBounds')
def screen(wid):
    """Where the window server draws the window: its screen rectangle, transform applied."""
    rect = Rect(); status = sky.SLSGetScreenRectForWindow(sky.SLSMainConnectionID(), wid, C.byref(rect))
    if status: fail(f'SLSGetScreenRectForWindow({wid})', status)
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
def own(wid):
    """The window's own frame, whatever transform is on it."""
    rect = Rect(); status = sky.SLSGetWindowBounds(sky.SLSMainConnectionID(), wid, C.byref(rect))
    if status: fail(f'SLSGetWindowBounds({wid})', status)
    return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
def listed(option, wid=0):
    """Rows of the window list, front to back: number, owner, layer, alpha, bounds."""
    rows = cg.CGWindowListCopyWindowInfo(option, wid); out = []
    if not rows: return out
    try:
        for i in range(cf.CFArrayGetCount(rows)):
            row = cf.CFArrayGetValueAtIndex(rows, i); number = C.c_longlong(0); pid = C.c_longlong(0); layer = C.c_longlong(0); a = C.c_double(-1); r = Rect()
            cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_NUMBER), 4, C.byref(number)); cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_PID), 4, C.byref(pid))
            cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_LAYER), 4, C.byref(layer)); cf.CFNumberGetValue(cf.CFDictionaryGetValue(row, K_ALPHA), 13, C.byref(a))
            cg.CGRectMakeWithDictionaryRepresentation(cf.CFDictionaryGetValue(row, K_BOUNDS), C.byref(r))
            out.append({'wid': number.value, 'pid': pid.value, 'layer': layer.value, 'alpha': a.value, 'bounds': [r.origin.x, r.origin.y, r.size.width, r.size.height]})
    finally: cf.CFRelease(rows)
    return out
def alpha(wid):
    """kCGWindowAlpha, asked from this process."""
    for row in listed(1 << 3, wid):  # kCGWindowListOptionIncludingWindow
        if row['wid'] == wid: return row['alpha']
    fail(f'window {wid} in the window list', 'not listed')
def transform(wid):
    affine = Affine(); status = sky.SLSGetWindowTransform(sky.SLSMainConnectionID(), wid, C.byref(affine))
    if status: fail(f'SLSGetWindowTransform({wid})', status)
    return [getattr(affine, k) for k, _ in Affine._fields_]
def original(wid): return {'transform': transform(wid), 'alpha': alpha(wid)}
def displays():
    ids = (C.c_uint32 * 16)(); count = C.c_uint32(0); cg.CGGetActiveDisplayList(16, ids, C.byref(count))
    return [[b.origin.x, b.origin.y, b.size.width, b.size.height] for b in (cg.CGDisplayBounds(ids[i]) for i in range(count.value))]
def near(seen, target, tolerance=1.0):
    left, top = math.floor(target[0]), math.floor(target[1])
    whole = [left, top, math.ceil(target[0] + target[2]) - left, math.ceil(target[1] + target[3]) - top]
    return all(abs(x - y) <= tolerance for x, y in zip(seen, whole))
def overlaps(a, b): return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]

wids = [int(x) for x in next(l for l in (evidence / 'host.log').read_text().splitlines() if l.startswith('READY ')).split()[2:]]
decoy = int(next(l for l in (evidence / 'decoy.log').read_text().splitlines() if l.startswith('READY ')).split()[2])
if phase == 'baseline':
    (evidence / 'native-before.json').write_text(json.dumps({'windows': {str(w): original(w) for w in wids}, 'decoy': {'screen': screen(decoy), **original(decoy)}}))
    sys.exit(0)
baseline = json.loads((evidence / 'native-before.json').read_text())
def untouched():
    seen = {'screen': screen(decoy), **original(decoy)}
    check('the unscoped decoy keeps its rectangle, transform and alpha', seen == baseline['decoy'], seen)
def originals_restored():
    seen = {str(w): original(w) for w in wids}
    check('every original transform and alpha is restored (independent window-server reads)', seen == baseline['windows'], seen)
    untouched()
if phase == 'restored':
    originals_restored(); sys.exit(0)
titles = [f'DriftWM disposable fixture {n + 1}' for n in range(len(wids))]
def adopted():
    found = until('adopts exactly the host\'s windows', 10, lambda: state()['windows'], lambda w: len(w) == len(wids) and not any(x['suspended'] for x in w))
    ok('adopts exactly the host\'s windows', [(w['id'], w['title'], w['size']) for w in found]); return found
def restored(what, before, seconds):
    began = time.time()
    until(what, seconds, lambda: [screen(w) for w in wids], lambda now: now == before)
    ok(what, {'seconds': round(time.time() - began, 2), 'rectangles': [screen(w) for w in wids]})
    originals_restored()
def canvas():
    """The canvas panel as the window list has it: this run's one window of 1100 by 700."""
    rows = [r for r in listed(1 << 0) if r['pid'] == infinify and r['bounds'][2:] == [1100, 700]]  # kCGWindowListOptionOnScreenOnly
    if len(rows) != 1: fail('the canvas panel in the window list', [r for r in listed(1 << 0) if r['pid'] == infinify])
    return rows[0]
def settle(seconds=6):
    """A camera or zoom request flies there: wait until two readings of the state a moment apart are the same."""
    end = time.time() + seconds; last = None
    while time.time() < end:
        now = state(); view = (now['camera'], now['zoom'], [(w['id'], w['position'], w['size']) for w in now['windows']])
        if view == last: return now
        last = view; time.sleep(.15)
    fail('the canvas comes to rest', last)
def expected(now, panel):
    """Each window's screen rectangle from `msg state`: the output's centre plus (world - camera centre) * zoom. The camera
    centre and a window's position are Y-up, the position is the window's centre."""
    ox, oy, ow, oh = panel; cx, cy = now['camera']; z = now['zoom']; out = {}
    for w in now['windows']:
        (px, py), (sw, sh) = w['position'], w['size']; left = px - sw // 2; top = -py - sh // 2
        out[w['id']] = [ox + ow / 2 + (left - cx) * z, oy + oh / 2 + (top + cy) * z, sw * z, sh * z]
    return out
def transforms_on(what):
    """The zoom is halved and every window is seen at half its size: this run's transforms are in force."""
    msg('zoom', '0.5'); settle()
    seen = until(what, 3, lambda: [screen(w) for w in wids], lambda now: all(abs(r[2] * 2 - own(w)[2]) <= 2 for r, w in zip(now, wids)))
    ok(what, seen)

# Where the window server had each window before this run of Infinify started: read by the script, before the launch.
before = [[float(x) for x in r.split(',')] for r in (evidence / 'before').read_text().split()]
def close(a, b): return all(abs(x - y) < 1e-6 for x, y in zip(a, b))
def shifted(r, dx, dy): return [r[0] + dx, r[1] + dy, r[2], r[3]]
if phase == 'overlay':
    # Without --native-helper: the same scoped run is the overlay, and no rectangle of a window ever changes.
    journal = evidence / 'h' / 'v2-journal.json'; generation = json.loads(journal.read_text())['generation'] if journal.exists() else None
    found = adopted(); panel = canvas()
    check('overlay: the canvas panel is an ordinary window, level 0, as before', panel['layer'] == 0, panel)
    reply = ask({'DebugNative': {}}); check('overlay: DebugNative is not served', 'Err' in reply, reply)
    lines = [l for l in trace() if l.startswith('Managing only')]; check('overlay: says what it manages, and nothing of native presentation', len(lines) == 1 and 'Native presentation' not in lines[0], lines)
    seen = set(); end = time.time() + 3; first = found[0]; moved = False; panned = False
    while time.time() < end:
        seen.add(json.dumps([screen(w) for w in wids]))
        if not moved and time.time() > end - 2.5: msg('move', '--id', str(first['id']), str(first['position'][0] + 90), str(first['position'][1] + 40)); moved = True
        if not panned and time.time() > end - 1.5: now = state(); msg('camera', str(now['camera'][0] + 70), str(now['camera'][1] - 30)); panned = True
        time.sleep(.02)
    check('overlay: over 3 s with a move and a pan no window\'s rectangle changed', seen == {json.dumps(before)}, {'before': before, 'seen': sorted(seen)})
    after = json.loads(journal.read_text())['generation'] if journal.exists() else None
    check('overlay: the helper\'s journal was not written', after == generation, {'before': generation, 'after': after})
    originals_restored()
    sys.exit(0)

found = adopted()
managing = [l for l in trace() if l.startswith('Managing only')]
check('says what it manages and how it presents', len(managing) == 1 and str(host) in managing[0] and 'Native presentation' in managing[0], managing)
first = until('a first frame was sent for every window', 3, native, lambda n: len(n['records']) == len(wids))
ids = {r['wid']: r['window'] for r in first['records']}
check('every record names a window of the host and a window of the canvas', sorted(ids) == sorted(wids) and sorted(ids.values()) == sorted(w['id'] for w in found) and first['server_pid'] == host and first['scope'] == 1, {'records': first['records'], 'server_pid': first['server_pid'], 'scope': first['scope']})
panel = canvas()

if phase == 'kill':
    transforms_on('kill: transforms are on before the kill'); held = native()['probe']['held']
    os.kill(infinify, signal.SIGKILL)
    restored(f'kill: Infinify killed with SIGKILL while the helper held {held} windows, every rectangle back within the 2 s lease and a 1 s margin', before, 3)
    sys.exit(0)
if phase == 'stall':
    transforms_on('stall: transforms are on before the stall'); began = time.time()
    reply = ask({'DebugNative': {'stall': 14}}); check('stall: the main thread is told to stay away for 14 s', reply.get('Ok', {}).get('DebugNative', {}).get('stall') == 14, reply)
    restored('stall: with the process alive and its main thread away, every rectangle back within 12 s (the watchdog acts after 10)', before, 12)
    check('stall: the process is still there', subprocess.run(['kill', '-0', str(infinify)]).returncode == 0, infinify)
    said = lambda: [l for l in trace() if l.startswith('Infinify: native presentation ended: the main thread has not turned')]
    check('stall: the watchdog said so once', len(said()) == 1, said())
    time.sleep(max(0, began + 14.5 - time.time()))
    now = state(); check('stall: msg state answers once the main thread is back', len(now['windows']) == len(wids), [(w['id'], w['title']) for w in now['windows']])
    report = native(); check('stall: the presenter has ended and holds no session', report['ended'] is True and report['probe'] is None, {'ended': report['ended'], 'probe': report['probe']})
    time.sleep(1); check('stall: the rectangles stay restored and the line was said once', [screen(w) for w in wids] == before and len(said()) == 1, {'rectangles': [screen(w) for w in wids], 'lines': said()})
    sys.exit(0)
if phase == 'helper':
    transforms_on('helper: transforms are on before the helper is killed')
    os.kill(host, signal.SIGKILL)
    lost = lambda: [l for l in trace() if l.startswith('Infinify: native presentation lost')]
    until('helper: its loss is said within 4 s', 4, lost, bool); time.sleep(1.5)
    check('helper: its loss is said exactly once', len(lost()) == 1, lost())
    now = state(); check('helper: msg state still answers', 'windows' in now and 'camera' in now, {'windows': [(w['id'], w['suspended']) for w in now['windows']], 'camera': now['camera']})
    def cpu():
        text = subprocess.run(['ps', '-o', 'utime=,stime=', '-p', str(infinify)], capture_output=True, text=True).stdout.split()
        return sum(int(m) * 60 + float(s) for m, s in (t.split(':') for t in text))
    a = cpu(); time.sleep(2); b = cpu()
    check('helper: the run does not spin (processor time over 2 s under 0.5 s)', b - a < .5, round(b - a, 3))
    report = native(); check('helper: the presenter has ended', report['ended'] is True, report['ended'])
    untouched()
    sys.exit(0)

# The full run.
order = listed(1 << 0); place = {r['wid']: n for n, r in enumerate(order)}
check('the canvas panel is one level under the ordinary windows, and every window of the host is in front of it', panel['layer'] == -1 and all(place[w] < place[panel['wid']] for w in wids), {'canvas': panel, 'front_to_back': [(r['wid'], r['layer']) for r in order if r['wid'] in wids + [panel['wid']]]})
def shown(what, seconds=2):
    """Every window is where `msg state` puts it. The state is read first and must not move meanwhile."""
    now = settle(); want = expected(now, panel['bounds'])
    seen = until(what, seconds, lambda: {w: screen(w) for w in wids}, lambda s: all(near(s[w], want[ids[w]]) for w in wids))
    untouched()
    ok(what, {w: {'shown': seen[w], 'expected': [round(x, 2) for x in want[ids[w]]]} for w in wids}); return seen, want, now
def probe(window): return ask({'DebugPointer': {'phase': 'probe', 'window': window, 'at': [.5, .5]}})

# 3. At rest, zoom 1, side by side around the middle of the canvas.
msg('zoom', '1'); now = settle(); cx, cy = now['camera']
for n, w in enumerate(wids): msg('move', '--id', str(ids[w]), str(int(cx) + (n - 1) * 340), str(int(cy)))
seen, want, now = shown('3: at rest every window is shown at its placement, at its own size')
check('3: zoom is 1 and each is shown at its own size', now['zoom'] == 1.0 and all(seen[w][2:] == own(w)[2:] for w in wids), {'zoom': now['zoom'], 'own': {w: own(w) for w in wids}})
for w in wids:
    reply = probe(ids[w]); rect = reply.get('Ok', {}).get('DebugPointer', {}).get('screen_rect')
    if not rect: fail(f'3: the probe answers for window {ids[w]}', reply)
    probed = [rect['origin']['x'], rect['origin']['y'], rect['size']['width'], rect['size']['height']]
    check(f'3: the probe\'s screen_rect of window {ids[w]} is the state\'s and the one shown', near(probed, want[ids[w]]) and near(seen[w], probed) and reply['Ok']['DebugPointer']['hit'] == ids[w], {'probe': probed, 'state': want[ids[w]], 'shown': seen[w]})
check('3: no record was refused by the helper', native()['stats']['records_failed'] == 0 and not [l for l in trace() if 'not placed' in l], native()['stats'])

# 4. A canvas move of one window.
rest = dict(seen); mover = wids[0]; position = next(w['position'] for w in now['windows'] if w['id'] == ids[mover])
msg('move', '--id', str(ids[mover]), str(position[0] - 30), str(position[1] + 120))
seen, want, now = shown('4: after a canvas move of one window it is shown at its new placement')
check('4: it moved by the move (30 left, 120 up), and only it moved', near(seen[mover], shifted(rest[mover], -30, -120)) and all(seen[w] == rest[w] for w in wids[1:]), {'moved': [seen[mover], rest[mover]], 'others': {w: [seen[w], rest[w]] for w in wids[1:]}})

# 5. A camera pan.
rest = dict(seen); cx, cy = now['camera']; msg('camera', str(cx + 60), str(cy + 40))
seen, want, now = shown('5: after a camera pan every window is shown at its placement')
check('5: the camera moved 60 right and 40 up, and every window 60 left and 40 down', close(now['camera'], [cx + 60, cy + 40]) and all(near(seen[w], shifted(rest[w], -60, 40)) for w in wids), {'camera': now['camera'], 'shown': seen, 'before': rest})

# 6. Zoom one half.
msg('zoom', '0.5')
seen, want, now = shown('6: at zoom 0.5 every window is shown at its placement')
check('6: zoom is 0.5 and each is shown at half its own size', now['zoom'] == 0.5 and all(abs(seen[w][2] - own(w)[2] / 2) <= 1 and abs(seen[w][3] - own(w)[3] / 2) <= 1 for w in wids), {'zoom': now['zoom'], 'shown': {w: seen[w][2:] for w in wids}, 'own': {w: own(w)[2:] for w in wids}})
check('6: the window list\'s bounds follow the transform, and the window\'s own frame does not', all(listed(1 << 3, w)[0]['bounds'] == seen[w] and own(w) == before[n] for n, w in enumerate(wids)), {'kCGWindowBounds': {w: listed(1 << 3, w)[0]['bounds'] for w in wids}, 'own': {w: own(w) for w in wids}})
time.sleep(1.5); again, want, now = shown('6: a second later, after the windows were looked at again, still there')
check('6: the world sizes are still the windows\' own (nothing took the drawn size for the window\'s)', all(w['size'] == [int(x) for x in own(next(k for k in wids if ids[k] == w['id']))[2:]] for w in now['windows']), [(w['id'], w['size']) for w in now['windows']])

# 7. Native focus, by Accessibility, of a window drawn at half size somewhere else than its own frame.
target = wids[1]; since = len(trace()); msg('focus', '--id', str(ids[target]))
focus = lambda: [l for l in trace()[since:] if l.startswith(f'debug: native focus pid={host} wid={target} ')]
accessible = not any(l.startswith('Native window focus needs Accessibility access') for l in trace())
if not accessible: skip('7: native focus under a transform', 'Infinify has no Accessibility access')
else:
    lines = until('7: native focus ends focused', 4, focus, lambda l: any(re.search(r'outcome=(focused|observed) focused=1 ', x) for x in l))
    ok('7: native focus of a window shown at half size ends focused', lines)
    seen, want, now = shown('7: and every window is still shown at its placement')

# 8. Out of view: parked beyond every display, by translation alone, and back.
screens = displays(); park = [math.ceil(max(d[0] + d[2] for d in screens)) + 256, math.ceil(max(d[1] + d[3] for d in screens)) + 256]
far = wids[2]; position = next(w['position'] for w in now['windows'] if w['id'] == ids[far]); rest = dict(seen)
msg('move', '--id', str(ids[far]), str(position[0] + 100000), str(position[1]))
parked = until('8: a window moved far out of view is parked', 2, lambda: screen(far), lambda r: r == park + own(far)[2:])
check('8: it is shown on no display, at the park rectangle and at its own size', not any(overlaps(parked, d) for d in screens), {'shown': parked, 'displays': screens})
check('8: the others did not move, and the parked one still has its frame and its place in the window list', all(screen(w) == rest[w] for w in wids[:2]) and own(far) == before[2] and listed(1 << 3, far)[0]['bounds'] == parked, {'others': {w: screen(w) for w in wids[:2]}, 'own': own(far), 'listed': listed(1 << 3, far)})
time.sleep(1.5); check('8: still parked and still managed a second later', screen(far) == parked and len(state()['windows']) == len(wids) and not any(w['suspended'] for w in state()['windows']), {'shown': screen(far), 'windows': [(w['id'], w['suspended']) for w in state()['windows']]})
msg('move', '--id', str(ids[far]), str(position[0]), str(position[1]))
seen, want, now = shown('8: brought back, it is shown at its placement again')

# 9. Opacity: the alpha the helper applied, as the window list has it and as the helper's own probe reads it.
def helper_alpha(): return {e['wid']: e['alpha'] for e in native()['probe']['table']}
msg('opacity', '--id', str(ids[target]), '0.5')
until('9: an opacity of 0.5 is the window\'s alpha', 2, lambda: alpha(target), lambda a: a == 0.5)
check('9: 0.5 in the window list and in the helper\'s probe, and 1 for the others in both', alpha(target) == 0.5 and helper_alpha()[target] == 0.5 and all(alpha(w) == 1 and helper_alpha()[w] == 1 for w in wids if w != target), {'kCGWindowAlpha': {w: alpha(w) for w in wids}, 'helper': helper_alpha()})
check('9: only that window\'s record carries an alpha', {r['wid']: r['alpha'] for r in native()['records']} == {w: (0.5 if w == target else None) for w in wids}, native()['records'])
msg('opacity', '--id', str(ids[target]), '1')
until('9: set back to 1, its alpha is 1 again', 2, lambda: alpha(target), lambda a: a == 1)
ok('9: set back to 1, its alpha is 1 again', {'kCGWindowAlpha': alpha(target), 'helper': helper_alpha()[target], 'record': next(r['alpha'] for r in native()['records'] if r['wid'] == target)})

# 10. A size change through msg resize, at zoom 1: smaller, so that the window is not moved to make room.
msg('zoom', '1'); seen, want, now = shown('10: back at zoom 1 every window is shown at its placement')
sized = wids[0]; resized = False
if not accessible: skip('10: msg resize under native presentation', 'no Accessibility access')
else:
    since = len(trace()); msg('resize', '--id', str(ids[sized]), '280', '200')
    answer = lambda: [l for l in trace()[since:] if l.startswith(f'debug: native resize pid={host} wid={sized} ')]
    lines = until('10: the size request is answered', 5, answer, bool)
    check('10: the window took 280x200 and was not moved for it', 'outcome=applied' in lines[-1] and 'actual=280x200' in lines[-1] and 'moved=0' in lines[-1], lines)
    until('10: the window\'s own frame has the size, where it was', 2, lambda: own(sized), lambda r: r == before[0][:2] + [280, 200])
    seen, want, now = shown('10: after msg resize 280 200 the window is shown at its new placement')
    check('10: shown at 280x200, the size the state has', seen[sized][2:] == [280, 200] and next(w['size'] for w in now['windows'] if w['id'] == ids[sized]) == [280, 200], {'shown': seen[sized], 'state': [(w['id'], w['size']) for w in now['windows']]})
    resized = True
(evidence / 'resized').write_text('yes' if resized else 'no')

# 11. A continuous pan: camera requests as fast as they are answered, for three seconds.
start = native()['stats']; cx, cy = now['camera']; began = time.time(); asked = 0
while time.time() - began < 3:
    t = time.time() - began; reply = ask({'Camera': [cx + 120 * math.sin(t * 3), cy + 80 * math.sin(t * 2)]}); asked += 1
    if 'Ok' not in reply: fail('11: a camera request during the pan', reply)
reply = ask({'Camera': [cx + 25, cy - 15]})
seen, want, now = shown('11: after a 3 s pan every window is shown at the last camera\'s placement')
check('11: the camera is where the last request put it', close(now['camera'], [cx + 25, cy - 15]), now['camera'])
end = until('11: every frame written was answered', 2, lambda: native()['stats'], lambda s: s['written'] == s['applied'] + s['superseded'] + s['discarded'] and s['submitted'] == s['dropped_local'] + s['written'])
delta = {k: end[k] - start[k] for k in ('submitted', 'written', 'dropped_local', 'applied', 'superseded', 'discarded', 'records_applied', 'records_failed')}
check('11: frames were submitted throughout, none failed a record, and each was applied or superseded by a later one', delta['submitted'] >= 30 and delta['records_failed'] == 0 and delta['discarded'] == 0 and delta['submitted'] == delta['dropped_local'] + delta['applied'] + delta['superseded'], {'camera_requests': asked, **delta})
check('11: no record was ever refused in this run', end['records_failed'] == 0 and not [l for l in trace() if 'not placed' in l], end)
PY

launch() { : > "$evidence/err.log"; rects > "$evidence/before"; drive baseline; INFINIFY_DEBUG=1 "$app" --windowed 1100x700 --state "$state" --config "$config" --socket "$socket" --no-hover-forwarding --debug-pointer --only-pid "$host" "$@" 2>"$evidence/err.log" & infinify=$!
  n=0; while [ ! -S "$socket" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done; [ -S "$socket" ] || { echo "FAIL: no socket: $(cat "$evidence/err.log")"; exit 1; }; }
drive() { python3 "$evidence/driver.py" "$evidence" "$app" "$1" "${infinify:-0}" "$host"; }
# The window server's rectangle of each of the host's windows, asked from a process of this script's.
# The host's READY line lists its window numbers separated by spaces, and each is an argument of its own below.
rects() { ready_wids=$(sed -n 's/^READY [0-9]* //p' "$evidence/host.log" | head -1)
# shellcheck disable=SC2086
python3 - $ready_wids <<'PY'
import ctypes as C, sys
class R(C.Structure): _fields_ = [('x', C.c_double), ('y', C.c_double), ('w', C.c_double), ('h', C.c_double)]
sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight'); sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetScreenRectForWindow.argtypes = [C.c_int, C.c_uint32, C.POINTER(R)]
out = []
for wid in sys.argv[1:]:
    r = R(); assert sky.SLSGetScreenRectForWindow(sky.SLSMainConnectionID(), int(wid), C.byref(r)) == 0; out.append('%g,%g,%g,%g' % (r.x, r.y, r.w, r.h))
print(' '.join(out))
PY
}

# 2. The baseline: where and how large each window is before any Infinify has run.
R0=$(rects); echo "ok: 2: before Infinify starts the host's windows are at: $R0"

# 3 to 12. The full run, ended by the quit action.
launch --native-helper "$runtime" "$evidence/nonce"
drive full
quit; [ "$gone" = yes ] || { echo 'FAIL: 12: Infinify did not quit within 5 s of msg action quit'; exit 1; }
after=$(rects)
# The window that msg resize made 280 by 200 keeps that size: restoring gives a window its place and its alpha back, not a size it changed itself.
if [ "$(cat "$evidence/resized")" = yes ]; then want=$(printf '%s' "$R0" | sed 's/^\([^,]*,[^,]*\),[^ ]*/\1,280,200/'); else want=$R0; fi
[ "$after" = "$want" ] || { echo "FAIL: 12: after action quit the windows are at $after, not $want (before the run: $R0)"; exit 1; }
if grep -q '^Infinify: native presentation' "$evidence/err.log"; then echo "FAIL: 12: the quit did not restore cleanly: $(grep '^Infinify: native presentation' "$evidence/err.log")"; exit 1; fi
echo "ok: 12: action quit ended the run within 5 s and every window is back where it was: $after"
drive restored
cp "$evidence/err.log" "$evidence/full.err.log"

# 13. A run killed with SIGKILL: the helper sees its connections close, or its lease run out, and restores.
launch --native-helper "$runtime" "$evidence/nonce"
drive kill
wait "$infinify" 2>/dev/null || true; infinify=; rm -f "$socket"
cp "$evidence/err.log" "$evidence/kill.err.log"

# 14. A run whose main thread stays away: the heartbeat thread would keep the lease for ever, so the shell's watchdog closes the session.
launch --native-helper "$runtime" "$evidence/nonce"
drive stall
quit; [ "$gone" = yes ] || { echo 'FAIL: 14: Infinify did not quit within 5 s after the stall'; exit 1; }
[ "$(rects)" = "$want" ] || { echo "FAIL: 14: after the stalled run quit the windows are at $(rects), not $want"; exit 1; }
echo 'ok: 14: the stalled run then quit within 5 s, the windows where they were'
cp "$evidence/err.log" "$evidence/stall.err.log"

# 15. Without the argument the same scoped run is the overlay and touches no transform.
launch
drive overlay
quit; [ "$gone" = yes ] || { echo 'FAIL: 15: the overlay run did not quit within 5 s'; exit 1; }
[ "$(rects)" = "$want" ] || { echo "FAIL: 15: after the overlay run the windows are at $(rects), not $want"; exit 1; }
echo 'ok: 15: the overlay run quit within 5 s, the windows where they were'
cp "$evidence/err.log" "$evidence/overlay.err.log"

# 16. The helper killed under a running shell. The host is the helper's process, so its windows go with it.
launch --native-helper "$runtime" "$evidence/nonce"
drive helper
wait "$host" 2>/dev/null || true; host=
quit; [ "$gone" = yes ] || { echo 'FAIL: 16: Infinify did not quit within 5 s after its helper was killed'; exit 1; }
echo 'ok: 16: with its helper gone the run still quit within 5 s'
cp "$evidence/err.log" "$evidence/helper.err.log"

skipped=$(cat "$evidence/skipped" 2>/dev/null || true)
what='native presentation against the cooperative host: placement at rest, a move, a pan, zoom, parking, opacity, a size change, a continuous pan, restore on quit, on SIGKILL and on a stalled main thread, the overlay untouched, a lost helper'
[ -z "$skipped" ] || { echo "INCOMPLETE: $what. NOT CHECKED: $skipped"; exit 3; }
echo "PASS: $what"
