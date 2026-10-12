#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# How the canvas keeps up with several large windows that all change on every refresh, measured from a process that has no
# Screen Recording access: four disposable fixture windows as large as the display holds, managed by a scoped run
# (`--only-pid`) in a window as large as the display allows, each fed 120 made-up frames a second of its own pixel size
# (INFINIFY_DEBUG_SYNTH, which goes through the path a captured frame takes), the camera zoomed out until all four tiles are
# in view. Ten seconds at rest, then ten while the camera is panned in small steps at the display's rate through the socket.
# What is read is Infinify's own frame line (INFINIFY_DEBUG, one every two seconds: native/desktop/README.md, "Frame pacing").
#
# It prints every frame line of both phases and a summary, and asserts what must hold of a canvas that paces itself by the
# display: the load arrived; the scene is gone through no more often than the display refreshes; the display is given a frame
# for nearly every refresh; and the main thread is never away from its run loop for 50 ms.
#
# In the default synthetic mode the pictures are made up, so ScreenCaptureKit's work and a window's drawing are not in it.
# Capture mode includes both. Everything acted on is a process this script started; nothing is clicked, the pointer is never moved and
# nothing is posted at the session level. Run it while nobody is using the machine: the canvas covers the visible screen.
#
# INFINIFY_BENCH_SIZE=WxH (1700x1100) is the fixture windows' content size, INFINIFY_BENCH_RATE (120) the frames a second.
# INFINIFY_BENCH_WINDOWS selects 1..16 owned fixture windows (default 4).
# INFINIFY_BENCH_MODE=capture uses real animated fixture captures and requires Screen Recording access; synthetic is the default.
# INFINIFY_BENCH_MODE=native uses cooperative helper windows at the requested size and an animated background, with no capture streams.
# Native mode measures background drawable times, samples one root's geometry at the requested rate, and checks every root's restoration;
# geometry samples and helper acknowledgements do not prove optical native-window FPS.
# INFINIFY_BENCH_ZOOM selects a zoom no larger than the fitted one (e.g. 0.21 for capture pixel-budget comparisons).
# INFINIFY_BENCH_VALIDATE_BUDGET=1 also checks reduced pixels, native/world geometry, zoom-in quality and full-resolution exports.
# INFINIFY_BENCH_BASELINE=1 uses full 2x captures and synchronous drawables in the same build for a controlled comparison.
# INFINIFY_BENCH_SCREEN_CLOCK=1 retains the timed CADisplayLink + private drawable pool baseline in the same build.
# INFINIFY_BENCH_METAL_CLOCK=1 selects the scoped direct CAMetalDisplayLink offer-clock diagnostic.
# INFINIFY_BENCH_SECONDS selects whole two-second measurement windows per phase (default 10, minimum 4).
# INFINIFY_BENCH_STRICT=1 additionally requires 99% of refreshes, no missed refreshes and no presentation silence above 1.5 refresh intervals.
# INFINIFY_BENCH_ANIMATION=1 keeps the scene changing every refresh with an animated background even for slower captures.
# INFINIFY_BENCH_ZOOM_MOTION=1 adds continuous zoom targets after the pan phase.
# INFINIFY_BENCH_MOVE_MOTION=1 moves one owned logical window continuously over IPC (not physical pointer forwarding).
# INFINIFY_BENCH_FOCUS_SWITCH=1 switches logical focus among owned windows over IPC (native activation remains disabled).
# INFINIFY_BENCH_CV_CLOCK=1 selects the scoped separate display-thread clock candidate.
# INFINIFY_BENCH_OPACITY sets only the owned fixture windows' scene opacity, to isolate native occlusion.
# INFINIFY_BENCH_HOST_ALPHA sets native fixtures' initial AppKit alpha (default 1), before adoption.
# INFINIFY_BENCH_HOST_OPAQUE=yes|no sets only native fixtures' initial opaque-region declaration (default yes).
# INFINIFY_BENCH_HOST_ALL_SPACES=yes|no makes only newly created native fixture windows stationary across Spaces (default yes).
# INFINIFY_BENCH_IDLE_DIAGNOSTIC=1 samples native idle geometry and scene state for six seconds, then exits.
# Read-only unless --live-owned-fixture is passed.
# Exit status: 0 measured and every assertion held; 1 something failed; 2 usage; 3 nothing was started (NOT RUN), because
# Stage Manager is on or another Infinify is running.
set -eu
cd "$(dirname "$0")/../.."
[ "$#" -ne 0 ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to benchmark disposable fixture windows'; exit 0; }
[ "$#" -eq 1 ] && [ "$1" = --live-owned-fixture ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }
root=$PWD
[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" != 1 ] || { echo 'NOT RUN: Stage Manager is on (com.apple.WindowManager GloballyEnabled is 1); nothing was started and nothing was measured.'; exit 3; }
# A desktop somebody is in must not have a second canvas laid over it, and its frames would be in the numbers.
if pgrep -f 'Infinify.app/Contents/MacOS/Infinify' >/dev/null 2>&1; then echo 'NOT RUN: another Infinify is running; nothing was started and nothing was measured.'; exit 3; fi
# INFINIFY_BENCH_APP: another build's executable, to set two builds side by side.
app=${INFINIFY_BENCH_APP:-$root/target/app/Infinify.app/Contents/MacOS/Infinify}
[ -x "$app" ] || ./scripts/build-app.sh
size=${INFINIFY_BENCH_SIZE:-1700x1100}; rate=${INFINIFY_BENCH_RATE:-120}
mode=${INFINIFY_BENCH_MODE:-synthetic}; synth=$rate; nativebench=0
baseline=${INFINIFY_BENCH_BASELINE:-0}
case "$mode" in synthetic) ;; capture) synth=0 ;; native) synth=0; nativebench=1; INFINIFY_BENCH_ANIMATION=1; export INFINIFY_BENCH_ANIMATION ;; *) echo 'INFINIFY_BENCH_MODE must be synthetic, capture or native' >&2; exit 2 ;; esac
fixture_count=${INFINIFY_BENCH_WINDOWS:-4}
case "$fixture_count" in ''|*[!0-9]*) echo 'INFINIFY_BENCH_WINDOWS must be 1..16' >&2; exit 2 ;; esac
[ "$fixture_count" -ge 1 ] && [ "$fixture_count" -le 16 ] || { echo 'INFINIFY_BENCH_WINDOWS must be 1..16' >&2; exit 2; }
if [ "$fixture_count" -ne 4 ] && [ "${INFINIFY_BENCH_VALIDATE_BUDGET:-0}" = 1 ]; then
  echo 'Capture-budget export validation retains its four-window layout; use four windows for those checks.' >&2; exit 2
fi
INFINIFY_BENCH_WINDOWS=$fixture_count; export INFINIFY_BENCH_WINDOWS
fixture_names=$(python3 -c 'import os; print(" ".join(chr(97+i) for i in range(int(os.environ["INFINIFY_BENCH_WINDOWS"]))))')
mkdir -p target/ipc
# Short: a socket path has room for about a hundred bytes.
evidence=$(mktemp -d "$root/target/ipc/bench.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
state=$evidence/state.json; config=$evidence/config.toml; socket=$evidence/s; : > "$config"
if [ "${INFINIFY_BENCH_ANIMATION:-0}" = 1 ]; then
  cat > "$evidence/motion.glsl" <<'GLSL'
// SPDX-License-Identifier: GPL-3.0-or-later
precision highp float;
varying vec2 v_coords;
uniform float u_time;
void main() {
    float pulse = 0.04 * sin(u_time * 3.0 + v_coords.x * 8.0);
    gl_FragColor = vec4(0.07 + pulse, 0.09 + pulse, 0.12 + pulse, 1.0);
}
GLSL
  cat > "$config" <<CONFIG
[background]
type = "shader"
path = "$evidence/motion.glsl"
animate_fps = 0
CONFIG
fi
infinify=; fixtures=; nativehost=; driverpid=
quit() {
  [ -n "$infinify" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done
  kill -0 "$infinify" 2>/dev/null && kill "$infinify" 2>/dev/null || true
  wait "$infinify" 2>/dev/null || true; infinify=
}
# Only what this script started is ever signalled.
cleanup() {
  code=$?
  if [ -n "$driverpid" ]; then kill "$driverpid" 2>/dev/null || true; wait "$driverpid" 2>/dev/null || true; driverpid=; fi
  quit; restored=0
  if [ -n "$nativehost" ] && [ -f "$evidence/native-original.json" ]; then
    python3 "$evidence/native-observer.py" "$evidence" restore || restored=$?
  fi
  for pid in $fixtures; do kill "$pid" 2>/dev/null || true; done
  for pid in $fixtures; do wait "$pid" 2>/dev/null || true; done
  [ "$restored" -eq 0 ] || exit "$restored"
  return "$code"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# Native mode owns one cooperative process and exactly the requested fixture windows.
if [ "$mode" = native ]; then
  [ -x target/privileged/host ] && [ -f target/privileged/payload-arm64.dylib ] || ./scripts/build-privileged.sh
  bundle=$evidence/CooperativeHost.app; mkdir -p "$bundle/Contents/MacOS" "$evidence/h"; chmod 700 "$evidence/h"
  cp target/privileged/host "$bundle/Contents/MacOS/CooperativeHost"
  cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.infinify.cooperative-host</string><key>CFBundleName</key><string>CooperativeHost</string><key>CFBundleExecutable</key><string>CooperativeHost</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
  nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); (umask 077; printf '%s\n' "$nonce" > "$evidence/nonce")
  "$bundle/Contents/MacOS/CooperativeHost" "$root/target/privileged/payload-arm64.dylib" "$evidence/h" "$nonce" --windows "$fixture_count" --size "$size" --activation regular --watchdog 150 --level 4 --alpha "${INFINIFY_BENCH_HOST_ALPHA:-1}" --opaque "${INFINIFY_BENCH_HOST_OPAQUE:-yes}" --all-spaces "${INFINIFY_BENCH_HOST_ALL_SPACES:-yes}" >"$evidence/host.log" 2>&1 &
  nativehost=$!; fixtures=$nativehost; printf '%s\n' "$nativehost" > "$evidence/native-host.pid"
  n=0; while ! grep -q '^READY ' "$evidence/host.log" 2>/dev/null && [ "$n" -lt 80 ]; do sleep .1; n=$((n+1)); done
  grep -q '^READY ' "$evidence/host.log" || { echo 'FAIL: cooperative host did not start'; exit 1; }
  cat > "$evidence/native-observer.py" <<'PY'
# SPDX-License-Identifier: GPL-3.0-or-later
# Independent readback, as in scoped-native.sh; never sends native mutations.
import ctypes as C, json, os, pathlib, sys, time
class Point(C.Structure): _fields_ = [('x', C.c_double), ('y', C.c_double)]
class Size(C.Structure): _fields_ = [('width', C.c_double), ('height', C.c_double)]
class Rect(C.Structure): _fields_ = [('origin', Point), ('size', Size)]
class Affine(C.Structure): _fields_ = [(k, C.c_double) for k in ('a', 'b', 'c', 'd', 'tx', 'ty')]
sky = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
sky.SLSMainConnectionID.restype = C.c_int
sky.SLSGetWindowTransform.argtypes = [C.c_int, C.c_uint32, C.POINTER(Affine)]; sky.SLSGetWindowTransform.restype = C.c_int
for n in ('SLSGetScreenRectForWindow', 'SLSGetWindowBounds'):
    getattr(sky, n).argtypes = [C.c_int, C.c_uint32, C.POINTER(Rect)]; getattr(sky, n).restype = C.c_int
cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGWindowListCopyWindowInfo.argtypes = [C.c_uint32, C.c_uint32]; cg.CGWindowListCopyWindowInfo.restype = C.c_void_p
cf.CFArrayGetCount.argtypes = [C.c_void_p]; cf.CFArrayGetCount.restype = C.c_long
cf.CFArrayGetValueAtIndex.argtypes = [C.c_void_p, C.c_long]; cf.CFArrayGetValueAtIndex.restype = C.c_void_p
cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]; cf.CFDictionaryGetValue.restype = C.c_void_p
cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]; cf.CFNumberGetValue.restype = C.c_bool
cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]; cf.CFStringCreateWithCString.restype = C.c_void_p
cf.CFRelease.argtypes = [C.c_void_p]
alpha_key = cf.CFStringCreateWithCString(None, b'kCGWindowAlpha', 0x08000100)
def rect(wid, bounds=False):
    r = Rect(); fn = sky.SLSGetWindowBounds if bounds else sky.SLSGetScreenRectForWindow
    if fn(sky.SLSMainConnectionID(), wid, C.byref(r)): raise RuntimeError(f'cannot read owned window {wid}')
    return [r.origin.x, r.origin.y, r.size.width, r.size.height]
def transform(wid):
    value = Affine()
    if sky.SLSGetWindowTransform(sky.SLSMainConnectionID(), wid, C.byref(value)): raise RuntimeError(f'cannot read transform {wid}')
    return [getattr(value, k) for k, _ in Affine._fields_]
def observe(wids):
    result = {}
    for wid in wids:
        transform = Affine()
        if sky.SLSGetWindowTransform(sky.SLSMainConnectionID(), wid, C.byref(transform)): raise RuntimeError(f'cannot read transform {wid}')
        info = cg.CGWindowListCopyWindowInfo(8, wid); alpha = C.c_double()
        if not info: raise RuntimeError(f'no window-list record {wid}')
        try:
            if cf.CFArrayGetCount(info) != 1: raise RuntimeError(f'window is gone {wid}')
            value = cf.CFDictionaryGetValue(cf.CFArrayGetValueAtIndex(info, 0), alpha_key)
            if not value or not cf.CFNumberGetValue(value, 13, C.byref(alpha)): raise RuntimeError(f'cannot read alpha {wid}')
        finally: cf.CFRelease(info)
        result[str(wid)] = {'transform': [getattr(transform, k) for k, _ in Affine._fields_], 'alpha': alpha.value, 'bounds': rect(wid, True)}
    return result
if __name__ == '__main__':
    evidence = pathlib.Path(sys.argv[1]); mode = sys.argv[2]
    ready = next(l for l in (evidence / 'host.log').read_text().splitlines() if l.startswith('READY ')).split()
    wids = [int(x) for x in ready[2:]]
    count = int(os.environ['INFINIFY_BENCH_WINDOWS'])
    if len(wids) != count or len(set(wids)) != count: raise RuntimeError(f'expected {count} distinct owned windows, got {wids}')
    if mode == 'initial':
        initial = observe(wids); (evidence / 'native-original.json').write_text(json.dumps(initial))
        for i, (name, wid) in enumerate(zip((chr(97+i) for i in range(count)), wids), 1):
            folder = evidence / name; folder.mkdir()
            (folder / 'status.json').write_text(json.dumps({'title': f'DriftWM disposable fixture {i}', 'bounds': initial[str(wid)]['bounds'], 'visible': True, 'window': wid}))
    elif mode == 'restore':
        initial = json.loads((evidence / 'native-original.json').read_text()); until = time.monotonic() + 3
        while True:
            current = observe(wids)
            if current == initial: print('ok: independent native transforms, alpha and bounds restored exactly', flush=True); break
            if time.monotonic() >= until: raise RuntimeError(f'owned native restoration differs: {current}')
            time.sleep(.02)
PY
  python3 "$evidence/native-observer.py" "$evidence" initial
  scope=$nativehost
else
# The fixture of scoped-windows.sh, opened at the size asked.
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
start() { mkdir "$evidence/$1"; if [ "$mode" = capture ]; then "$fixture" "$evidence/$1" "Bench fixture $1 $$" "$2" 150 size "$size" animate "$rate" & else "$fixture" "$evidence/$1" "Bench fixture $1 $$" "$2" 150 size "$size" & fi; fixtures="$fixtures $!"; }
scope=; fixture_index=0
for name in $fixture_names; do
  start "$name" "$((fixture_index % 4 * 20 - 30))"; fixture_pid=$!
  scope=${scope:+$scope,}$fixture_pid; fixture_index=$((fixture_index+1))
done
fi

# One read-only list outside each measured phase diagnoses an occluded canvas
# without moving or inspecting pixels from any other window. Keep only numeric
# metadata, and never count this WindowServer query as a frame-thread workload.
cat > "$evidence/visibility.m" <<'OBJC'
// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;pid_t pid=atoi(argv[1]);
    CFArrayRef copied=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
    NSArray *rows=CFBridgingRelease(copied);NSMutableArray *panels=[NSMutableArray array];
    for(NSUInteger index=0;index<rows.count;index++){
        NSDictionary *row=rows[index];if([row[(id)kCGWindowOwnerPID]intValue]!=pid)continue;
        CGRect panel=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&panel)||panel.size.width<64||panel.size.height<64)continue;
        NSMutableArray *front=[NSMutableArray array];
        for(NSUInteger i=0;i<index;i++){
            NSDictionary *other=rows[i];CGRect bounds=CGRectZero;
            if([other[(id)kCGWindowAlpha]doubleValue]<=0||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)other[(id)kCGWindowBounds],&bounds)||!CGRectIntersectsRect(panel,bounds))continue;
            CGRect overlap=CGRectIntersection(panel,bounds);
            [front addObject:@{@"wid":other[(id)kCGWindowNumber]?:@0,@"pid":other[(id)kCGWindowOwnerPID]?:@0,@"level":other[(id)kCGWindowLayer]?:@0,@"alpha":other[(id)kCGWindowAlpha]?:@0,@"bounds":other[(id)kCGWindowBounds]?:@{},@"coverage":@(overlap.size.width*overlap.size.height/(panel.size.width*panel.size.height))}];
        }
        [panels addObject:@{@"wid":row[(id)kCGWindowNumber]?:@0,@"level":row[(id)kCGWindowLayer]?:@0,@"alpha":row[(id)kCGWindowAlpha]?:@0,@"bounds":row[(id)kCGWindowBounds]?:@{},@"front":front}];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"read":@(rows!=nil),@"panels":panels} options:0 error:nil];
    if(!data)return 1;fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return 0;
}}
OBJC
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror "$evidence/visibility.m" -framework Foundation -framework CoreGraphics -o "$evidence/visibility"

cat > "$evidence/driver.py" <<'PY'
import json, math, os, pathlib, re, runpy, socket, struct, subprocess, sys, threading, time
evidence = pathlib.Path(sys.argv[1]); rate = float(sys.argv[2]); app = sys.argv[3]; mode = sys.argv[4]
sock = str(evidence / 's'); errlog = evidence / 'err.log'
failed = []
def ok(what, observed): print(f'ok: {what}: {observed}', flush=True)
def check(what, passed, observed):
    print(f'{"ok" if passed else "FAIL"}: {what}: {observed}', flush=True)
    if not passed: failed.append(what)
def stop(what, observed): print(f'FAIL: {what}: {observed}', flush=True); sys.exit(1)
def status(name): return json.loads((evidence / name / 'status.json').read_text())
# One JSON line each way: what `Infinify msg` sends (crates/desktop/src/ipc_client.rs).
def ask(request):
    s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock); s.sendall((json.dumps(request) + '\n').encode())
    data = b''
    while not data.endswith(b'\n'):
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    s.close(); return json.loads(data)
def state(): return ask('State')['Ok']['State']
def msg(*args): return subprocess.run([app, 'msg', '--socket', sock, *args], capture_output=True, text=True)
def helper_counters():
    if mode != 'native': return None
    reply = ask({'DebugNative': {}})
    value = reply.get('Ok', {}).get('DebugNative', {})
    if not isinstance(value.get('stats'), dict): stop('native helper counters', reply)
    return (time.monotonic(), value['stats'])
server_pids = subprocess.run(['pgrep', '-x', 'WindowServer'], capture_output=True, text=True).stdout.split()
server_pid = server_pids[0] if len(server_pids) == 1 else None
def read_process(pid):
    if pid is None: return None
    result = subprocess.run(['ps', '-p', pid, '-o', 'lstart=,time=,rss='], capture_output=True, text=True)
    fields = result.stdout.split()
    if result.returncode or len(fields) < 3: return None
    cpu = 0.0
    for part in fields[-2].split(':'): cpu = cpu * 60 + float(part)
    return {'pid': int(pid), 'started': ' '.join(fields[:-2]), 'time': time.monotonic(), 'cpu_seconds': cpu, 'rss_kib': int(fields[-1])}
def process_snapshot():
    # Outside selected presentation windows: cumulative CPU and RSS, not physical
    # footprint or GPU allocations. The owned helper and whole-desktop WindowServer
    # are separate costs; missing/ambiguous processes remain unavailable, not zero.
    app_row = read_process((evidence / 'app.pid').read_text().strip())
    if app_row is None: stop('benchmark process counters', 'owned Infinify process is unavailable')
    helper_pid = (evidence / 'native-host.pid').read_text().strip() if mode == 'native' else None
    return {'app': app_row, 'helper': read_process(helper_pid), 'window_server_whole_desktop': read_process(server_pid)}
def process_interval(before, after):
    if before is None or after is None or (before['pid'], before['started']) != (after['pid'], after['started']): return None
    elapsed = after['time'] - before['time']; cpu = after['cpu_seconds'] - before['cpu_seconds']
    if elapsed <= 0 or cpu < 0: return None
    return {'pid': before['pid'], 'interval_seconds': elapsed, 'cpu_percent_one_core': 100 * cpu / elapsed,
            'rss_start_kib': before['rss_kib'], 'rss_end_kib': after['rss_kib']}
def visibility(name, pid=None):
    # No WindowServer API executes on the app's main queue, and these probes
    # remain outside the frame windows selected below.
    result = subprocess.run([str(evidence / 'visibility'), str(pid) if pid is not None else (evidence / 'app.pid').read_text().strip()], capture_output=True, text=True)
    if result.returncode: stop(f'{name}: read-only canvas ordering', result.stderr)
    value = json.loads(result.stdout)
    ok(f'{name}: read-only canvas ordering (coverage does not prove opacity)', value)
    return value
def until(what, seconds, read, passed):
    end = time.time() + seconds
    while True:
        value = read()
        if passed(value): return value
        if time.time() > end:
            if what == 'adopts the four fixture windows':
                visibility('failed adoption canvas')
                if mode == 'native':
                    host_pid = int(next(l for l in (evidence / 'host.log').read_text().splitlines() if l.startswith('READY ')).split()[1])
                    visibility('failed adoption owned fixture', host_pid)
            stop(what, value)
        time.sleep(.05)
def lines(): return [l for l in errlog.read_text(errors='replace').splitlines() if l.startswith('frames: ')]
fixture_count = int(os.environ['INFINIFY_BENCH_WINDOWS'])
names = [chr(97+i) for i in range(fixture_count)]; titles = sorted(status(n)['title'] for n in names)
adopted = until(f'adopts the {fixture_count} fixture windows', 10, lambda: state()['windows'], lambda w: sorted(x['title'] for x in w) == titles)
ok(f'adopts the {fixture_count} fixture windows', [(w['id'], w['size']) for w in adopted])
if os.environ.get('INFINIFY_BENCH_OPACITY'):
    opacity = float(os.environ['INFINIFY_BENCH_OPACITY'])
    if not math.isfinite(opacity) or not 0 < opacity <= 1: stop('fixture opacity must be in (0,1]', opacity)
    for w in adopted:
        done = msg('opacity', '--id', str(w['id']), str(opacity))
        if done.returncode: stop('owned fixture scene opacity', done.stderr.strip())
    ok('owned fixture scene opacity', opacity)
managing = [l for l in errlog.read_text(errors='replace').splitlines() if l.startswith('Managing only')]
access = not (managing and 'No Screen Recording access' in managing[0])
if mode == 'capture' and not access: stop('capture benchmark requires Screen Recording access', managing)
ok('frame source', {'capture': 'real ScreenCaptureKit streams', 'synthetic': 'synthetic only; real streams disabled', 'native': 'cooperative native windows; no capture streams'}[mode])
oracle = runpy.run_path(str(evidence / 'native-observer.py')) if mode == 'native' else None
for n in names: ok(f'fixture {n} window', {'points': status(n)['bounds'][2:], 'pixels': [2 * v for v in status(n)['bounds'][2:]]})

# Native focus observation may finish after all four adoptions. It may follow
# the owned host's initial key window even with native activation disabled.
# Let that first reconciliation land before choosing the layout's center.
if mode == 'native': time.sleep(1.1)

# A grid about the middle of the view, with room for the pan. Four windows retain
# the original two-by-two geometry used by the native and capture-budget oracles.
first = state(); cx, cy = first['camera']; out = first['outputs'][0]['size']; gap = 40; swing = 120
wide = max(w['size'][0] for w in adopted); high = max(w['size'][1] for w in adopted)
columns = math.ceil(math.sqrt(fixture_count)); rows = math.ceil(fixture_count / columns)
requested_zoom = float(os.environ['INFINIFY_BENCH_ZOOM']) if os.environ.get('INFINIFY_BENCH_ZOOM') else None
if requested_zoom is not None:
    if not math.isfinite(requested_zoom) or requested_zoom <= 0: stop('overview zoom must be finite and positive', requested_zoom)
    # The layout bounds set DriftWM's dynamic minimum zoom. Leave enough world space to permit the requested overview.
    gap = max(gap, int(out[1] / (2 * requested_zoom) - 2 * high + 100))
spots = [(i % columns - (columns-1)/2, (rows-1)/2 - i//columns) for i in range(fixture_count)]
for w, (sx, sy) in zip(sorted(adopted, key=lambda w: w['title']), spots):
    done = msg('move', '--id', str(w['id']), str(int(cx + sx * (wide + gap))), str(int(cy + sy * (high + gap))))
    if done.returncode: stop(f'msg move {w["title"]}', done.stderr.strip())
zoom = min(out[0] / (columns * wide + (columns+1) * gap + 2 * swing), out[1] / (rows * high + (rows+1) * gap))
if requested_zoom is not None: zoom = requested_zoom if mode == 'native' else min(zoom, requested_zoom)
zoom = float(f'{zoom:.4f}')
done = msg('zoom', f'{zoom:.4f}')
if done.returncode: stop('msg zoom', done.stderr.strip())
# Camera begins a new flight. Let zoom arrive before starting it. A late initial
# focus observation can cancel that first target; retry only after half a
# second with no zoom progress, outside every selected presentation window.
last_zoom = {'value': None, 'changed': time.monotonic()}
def setup_zoom():
    s = state(); now = time.monotonic()
    if s['zoom'] != last_zoom['value']: last_zoom.update(value=s['zoom'], changed=now)
    elif abs(s['zoom'] - zoom) >= 1e-10 and now - last_zoom['changed'] > .5:
        reply = ask({'Zoom': zoom})
        if 'Ok' not in reply: stop('overview zoom after initial focus reconciliation', reply)
        last_zoom['changed'] = now
        ok('reissued cancelled setup zoom before measurement', s['zoom'])
    return s
until('the zoom arrives fully before a camera target', 8, setup_zoom, lambda s: abs(s['zoom'] - zoom) < 1e-10)
done = msg('camera', str(cx), str(cy))
if done.returncode: stop('msg camera', done.stderr.strip())
# Is every tile whole inside what the output shows with the camera at `x`? Positions are frame centres, Y up, as the camera's.
def inside(s, x):
    z = s['zoom']; half = [out[0] / z / 2, out[1] / z / 2]
    return all(abs(w['position'][0] - x) + w['size'][0] / 2 <= half[0] and abs(w['position'][1] - s['camera'][1]) + w['size'][1] / 2 <= half[1] for w in s['windows'])
settled = until('the zoom and the camera arrive', 5, state, lambda s: abs(s['zoom'] - zoom) < .002 and abs(s['camera'][0] - cx) < 1 and abs(s['camera'][1] - cy) < 1)
check(f'all {fixture_count} tiles are in view, at either end of the pan too', inside(settled, cx - swing) and inside(settled, cx + swing), {'output': out, 'zoom': round(settled['zoom'], 4), 'camera': settled['camera'], 'tiles': [(w['position'], w['size']) for w in settled['windows']]})
if os.environ.get('INFINIFY_BENCH_IDLE_DIAGNOSTIC') == '1':
    if not oracle: stop('idle native diagnostic requires native mode', mode)
    # This is an observation of the owned fixtures, not a cadence benchmark:
    # state and transforms are read at 4 Hz, rectangles at the requested rate.
    wids = [status(n)['window'] for n in names]; samples = []; rects = []; next_state = 0
    time.sleep(.5); start = time.monotonic(); next_at = start
    while time.monotonic() - start < 6:
        now = time.monotonic(); rects.append({'time': now - start, 'rects': {str(w): oracle['rect'](w) for w in wids}})
        if now >= next_state:
            samples.append({'time': now - start, 'state': state(), 'native': oracle['observe'](wids)}); next_state = now + .25
        next_at += 1 / rate; time.sleep(max(0, next_at - time.monotonic()))
    (evidence / 'idle-geometry.json').write_text(json.dumps({'state': samples, 'rects': rects}))
    def ranges(values): return [[min(v[i] for v in values), max(v[i] for v in values)] for i in range(len(values[0]))]
    ok('idle scene camera and zoom ranges', ranges([s['state']['camera'] + [s['state']['zoom']] for s in samples]))
    for w in wids:
        key = str(w); native = [s['native'][key] for s in samples]; positions = [s['rects'][key] for s in rects]
        ok(f'idle independent native window {w} ranges', {'transform': ranges([s['transform'] for s in native]), 'bounds': ranges([s['bounds'] for s in native]), 'rect': ranges(positions), 'alpha': ranges([[s['alpha']] for s in native]), 'rect_changes': sum(a != b for a,b in zip(positions, positions[1:]))})
    sys.exit(0)

fields = re.compile(r'frames: ([\d.]+)s display=(\d+) redraws=([\d.]+) flushes=([\d.]+) drawn=([\d.]+) presented=([\d.]+) flush_ms=([\d.]+)/([\d.]+) main_gap_ms=([\d.]+) sources(.*)')
presentation_fields = re.compile(r'presentation: output=(\d+) frames=(\d+) intervals=(\d+) gap_ms=([\d.]+)/([\d.]+)/([\d.]+) missed=(\d+) latency_ms=([\d.]+)/([\d.]+) late_ms=([\d.]+) gpu_ms=([\d.]+)/([\d.]+) errors=(\d+) overflow=(\d+) camera_updates=(\d+) camera_repeats=(\d+) silence_ms=([\d.]+) duplicate_time=(\d+) reordered_time=(\d+)')
drawable_fields = re.compile(r'drawable: output=(\d+) acquisitions=(\d+) timeouts=(\d+) acquire_ms=([\d.]+)/([\d.]+) queue_ms=([\d.]+) publish_ms=([\d.]+) completed=(\d+) completion_ms=([\d.]+)/([\d.]+) not_presented=(\d+)(?: notify_ms=([\d.]+))?')
panel_fields = re.compile(r'panel: wid=(\d+) level=(-?\d+) visible=(\d+) unoccluded=(\d+) alpha=([\d.]+) layer_hidden=(\d+) layer_opacity=([\d.]+) size=([\d.]+)x([\d.]+)(?: hides_inactive=(\d+) can_hide=(\d+) active_space=(\d+))?')
def records():
    frames = []; pending = []
    for line in errlog.read_text(errors='replace').splitlines():
        if line.startswith(('presentation:', 'drawable:')): pending.append(line)
        elif line.startswith('frames:'): frames.append((line, pending)); pending = []
        elif line.startswith('panel:') and frames: frames[-1][1].append(line)
    return frames
windows = max(2, math.ceil(float(os.environ.get('INFINIFY_BENCH_SECONDS', '10')) / 2))
# Whole frame windows: the line being counted when the phase began is left out. `work` runs meanwhile.
def measure(name, work):
    # A helper probe can wait on its socket: take it outside the selected
    # presentation windows, with the first partial window still discarded.
    helper_before = helper_counters()
    process_before = process_snapshot()
    panel_ids = [p['wid'] for p in visibility(name + ' before')['panels']]
    time.sleep(1); begun = len(lines()); end = time.time() + windows * 2 + 12
    observations = []; canvas_observations = []; errors = []; finished = threading.Event(); observer = None
    def sample_native():
        wid = status('a')['window']; previous = None; next_at = time.monotonic()
        try:
            while not finished.is_set():
                now = time.monotonic(); value = oracle['rect'](wid)
                observations.append((now, value != previous, value)); previous = value; next_at += 1 / rate
                # At 10 Hz, independently distinguish the canvas's own transform
                # from WindowServer's screen rectangle (for example a Space
                # transition). This calls no app IPC/CG list or mutation API.
                if len(observations) % max(1, round(rate / 10)) == 0:
                    canvas_observations.append({'time': now, 'native': {'wid': wid, 'rect': value, 'bounds': oracle['rect'](wid, True), 'transform': oracle['transform'](wid)}, 'panels': {str(p): {'rect': oracle['rect'](p), 'bounds': oracle['rect'](p, True), 'transform': oracle['transform'](p)} for p in panel_ids}, 'read_span_ms': (time.monotonic() - now) * 1000})
                finished.wait(max(0, next_at - time.monotonic()))
        except Exception as error: errors.append(str(error))
    try:
        while len(lines()) < begun + windows + 1:
            if time.time() > end: stop(f'{name}: frame lines', lines()[begun:])
            if oracle and observer is None and len(lines()) >= begun + 1:
                observer = threading.Thread(target=sample_native); observer.start()
            work()
    finally:
        finished.set()
        if observer: observer.join()
    if errors: stop(f'{name}: independent native geometry sampling', errors)
    if canvas_observations:
        (evidence / (name.replace(' ', '-') + '-canvas-geometry.json')).write_text(json.dumps(canvas_observations))
        for p in panel_ids:
            values = [s['panels'][str(p)] for s in canvas_observations]
            report = {}
            for key in ('rect', 'bounds', 'transform'):
                report[key + '_changes'] = sum(a[key] != b[key] for a, b in zip(values, values[1:]))
                report[key + '_ranges'] = [[min(v[key][i] for v in values), max(v[key][i] for v in values)] for i in range(len(values[0][key]))]
            ok(f'{name}: independently observed canvas {p} geometry', report)
            # When both own transforms/bounds stay fixed, compare the native
            # screen rectangle with the same global axis-aligned affine motion
            # measured on the canvas. These adjacent read-only calls are not an
            # atomic WindowServer snapshot; retain their span and actual error.
            first = canvas_observations[0]; base = first['panels'][str(p)]; native = first['native']; errors_by_axis = []
            for sample in canvas_observations:
                canvas = sample['panels'][str(p)]; source = sample['native']
                if any(v[key] != original[key] for v, original in ((canvas, base), (source, native)) for key in ('bounds', 'transform')): continue
                if base['rect'][2] <= 0 or base['rect'][3] <= 0: continue
                sx = canvas['rect'][2] / base['rect'][2]; sy = canvas['rect'][3] / base['rect'][3]
                expected = [canvas['rect'][0] + (native['rect'][0] - base['rect'][0]) * sx, canvas['rect'][1] + (native['rect'][1] - base['rect'][1]) * sy, native['rect'][2] * sx, native['rect'][3] * sy]
                errors_by_axis.append([abs(a-b) for a, b in zip(source['rect'], expected)])
            if errors_by_axis:
                ok(f'{name}: common canvas/native screen motion diagnostic (adjacent non-atomic reads)', {'unchanged_own_geometry_samples': len(errors_by_axis), 'max_rect_error_points': [round(max(e[i] for e in errors_by_axis), 3) for i in range(4)], 'max_read_span_ms': round(max(s['read_span_ms'] for s in canvas_observations), 3)})
    if observations:
        changed = [t for t, differs, _ in observations[1:] if differs]; span = observations[-1][0] - observations[0][0]
        gaps = [b-a for a, b in zip(changed, changed[1:])]
        extent = [[min(v[i] for _,_,v in observations), max(v[i] for _,_,v in observations)] for i in range(4)]
        ok(f'{name}: independently observed native geometry (not optical presentation)', {'samples': len(observations), 'span_s': round(span, 3), 'changes': len(changed), 'changes_per_second': round(len(changed)/span, 2), 'worst_change_gap_ms': round(max(gaps, default=0)*1000, 3), 'rect_ranges': extent})
    if oracle:
        observed = oracle['observe']([status(n)['window'] for n in names])
        alphas = {wid: value['alpha'] for wid,value in observed.items()}
        ok(f'{name}: independently observed current native alpha', alphas)
        if os.environ.get('INFINIFY_BENCH_OPACITY'):
            check(f'{name}: helper applied owned scene opacity', all(abs(a - opacity) < 1e-6 for a in alphas.values()), alphas)
    taken = records()[begun + 1:begun + windows + 1]; rows = []; presentations = []; drawables = []; panels = []
    visibility(name + ' after')
    helper_after = helper_counters()
    if helper_before is not None:
        keys = ('submitted', 'written', 'applied', 'superseded', 'dropped_local', 'discarded', 'records_failed')
        deltas = {key: helper_after[1][key] - helper_before[1][key] for key in keys}
        ok(f'{name}: native helper delivery counters (not optical presentation)', {'span_s': round(helper_after[0] - helper_before[0], 3), **deltas})
    print(f'--- {name}', flush=True)
    for l, shown in taken:
        print(l, flush=True); m = fields.match(l)
        if not m: stop(f'{name}: a frame line that does not parse', l)
        rows.append([float(v) for v in m.groups()[:9]] + [[[float(v) for v in s.split('=')[1].split('/')] for s in m.group(10).split()]])
        for line in shown:
            print(line, flush=True)
            if line.startswith('drawable:'):
                match = drawable_fields.fullmatch(line)
                if not match: stop(f'{name}: drawable line that does not parse', line)
                drawables.append([float(v or 0) for v in match.groups()]); continue
            if line.startswith('panel:'):
                match = panel_fields.fullmatch(line)
                if not match: stop(f'{name}: panel line that does not parse', line)
                panels.append([float(v) if v is not None else None for v in match.groups()]); continue
            match = presentation_fields.fullmatch(line)
            if not match: stop(f'{name}: presentation line that does not parse', line)
            presentations.append([float(v) for v in match.groups()])
    mean = lambda i: sum(r[i] for r in rows) / len(rows)
    # The mean flush is weighted by the flushes of each line.
    flushes = sum(r[3] * r[0] for r in rows)
    sources = [min(s[i][1] for r in rows for s in [r[9]] if i < len(s)) for i in range(max(len(r[9]) for r in rows))]
    process_after = process_snapshot(); app_usage = process_interval(process_before['app'], process_after['app'])
    if app_usage is None: stop('benchmark process interval', 'owned Infinify process identity or counters changed')
    # The CPU interval includes phase setup/alignment; the drawable metrics above
    # cover only whole two-second windows. Keep both intervals explicit.
    return {'process_interval_seconds': app_usage['interval_seconds'],
            'cpu_percent_one_core': app_usage['cpu_percent_one_core'],
            'rss_start_kib': app_usage['rss_start_kib'], 'rss_end_kib': app_usage['rss_end_kib'],
            'related_processes': {key: process_interval(process_before[key], process_after[key]) for key in ('helper', 'window_server_whole_desktop')},
            'display': rows[0][1], 'redraws': mean(2), 'flushes': mean(3), 'drawn': mean(4), 'presented': mean(5),
            'flush_mean_ms': sum(r[6] * r[3] * r[0] for r in rows) / flushes if flushes else 0, 'flush_worst_ms': max(r[7] for r in rows), 'main_gap_worst_ms': max(r[8] for r in rows),
            'sources': len(sources), 'accepted_least': min(sources) if sources else 0,
            'received_most': max((s[0] for r in rows for s in r[9]), default=0), 'accepted_most': max((s[1] for r in rows for s in r[9]), default=0),
            'presentation_rows': len(presentations), 'presentation_gap_worst_ms': max((r[5] for r in presentations), default=0),
            'actual_presented': sum(r[1] for r in presentations),
            'presentation_p99_worst_ms': max((r[4] for r in presentations), default=0), 'missed': sum(r[6] for r in presentations),
            'latency_worst_ms': max((r[8] for r in presentations), default=0), 'gpu_worst_ms': max((r[11] for r in presentations), default=0),
            'errors': sum(r[12] + r[13] for r in presentations),
            'duplicate_time': sum(r[17] for r in presentations), 'reordered_time': sum(r[18] for r in presentations),
            'camera_updates': sum(r[14] for r in presentations), 'camera_repeats': sum(r[15] for r in presentations),
            'presentation_silence_worst_ms': max((r[16] for r in presentations), default=0),
            'panel_rows': len(panels), 'occluded_rows': sum(not r[3] for r in panels),
            'hidden_rows': sum(not r[2] or r[5] or r[4] <= 0 or r[6] <= 0 or r[7] <= 0 or r[8] <= 0 for r in panels),
            'hides_inactive_rows': sum(r[9] == 1 for r in panels), 'inactive_space_rows': sum(r[11] == 0 for r in panels),
            'acquire_worst_ms': max((r[4] for r in drawables), default=0), 'acquire_queue_worst_ms': max((r[5] for r in drawables), default=0), 'publish_worst_ms': max((r[6] for r in drawables), default=0),
            'notify_worst_ms': max((r[11] for r in drawables), default=0),
            'completion_worst_ms': max((r[9] for r in drawables), default=0), 'acquire_timeouts': sum(r[2] for r in drawables), 'not_presented': sum(r[10] for r in drawables)}
rest = measure('at rest', lambda: time.sleep(.25))
# The pan: a camera target a step on at each refresh, back and forth across `swing` canvas units in two seconds, as a hand on
# the trackpad sends them. Each is its own request, and the camera flies after it.
step = {'n': 0, 'next': time.time(), 'seen': []}
def pan():
    for _ in range(int(rate) // 4):
        t = step['n'] / rate; phase = (t / 2) % 1; x = cx + swing * (4 * phase - 1 if phase < .5 else 3 - 4 * phase)
        reply = ask({'Camera': [x, cy]})
        if 'Ok' not in reply: stop('camera step', reply)
        step['n'] += 1; step['next'] += 1 / rate; wait = step['next'] - time.time()
        if wait > 0: time.sleep(wait)
        else: step['next'] = time.time()
    step['seen'].append(state()['camera'][0])
step['next'] = time.time(); began = time.time(); moving = measure('panning', pan); took = time.time() - began
seen = step['seen']; ok('the camera was panned', {'requests_per_second': round(step['n'] / took, 1), 'camera_x_seen': [round(min(seen) - cx, 1), round(max(seen) - cx, 1)]})
check('the camera moved through the pan', max(seen) - min(seen) > swing / 2, [round(v - cx, 1) for v in seen])
phases = [('at rest', rest), ('panning', moving)]
if os.environ.get('INFINIFY_BENCH_ZOOM_MOTION') == '1':
    zoom_step = {'n': 0, 'next': time.time(), 'seen': []}; high_zoom = min(1.0, zoom * 1.75)
    if high_zoom <= zoom + .002: stop('zoom motion requires an overview below 1:1', zoom)
    def zooming():
        for _ in range(max(1, int(rate) // 4)):
            phase = (zoom_step['n'] / rate / 2) % 1
            target = zoom + (high_zoom - zoom) * (2 * phase if phase < .5 else 2 - 2 * phase)
            reply = ask({'Zoom': target})
            if 'Ok' not in reply: stop('zoom step', reply)
            zoom_step['n'] += 1; zoom_step['next'] += 1 / rate; wait = zoom_step['next'] - time.time()
            if wait > 0: time.sleep(wait)
            else: zoom_step['next'] = time.time()
        zoom_step['seen'].append(state()['zoom'])
    phases.append(('zooming', measure('zooming', zooming)))
    check('the camera zoomed continuously', max(zoom_step['seen']) - min(zoom_step['seen']) > (high_zoom - zoom) / 2, [round(min(zoom_step['seen']), 4), round(max(zoom_step['seen']), 4)])
    ask({'Zoom': zoom}); until('overview zoom resumes', 5, state, lambda s: abs(s['zoom'] - zoom) < 1e-10)
if os.environ.get('INFINIFY_BENCH_MOVE_MOTION') == '1':
    chosen = min(state()['windows'], key=lambda w: w['id']); origin = chosen['position']
    window_step = {'n': 0, 'next': time.monotonic(), 'seen': []}
    def moving_window():
        for _ in range(max(1, int(rate) // 4)):
            phase = (window_step['n'] / rate / 2) % 1
            x = round(origin[0] + swing * (4 * phase - 1 if phase < .5 else 3 - 4 * phase))
            reply = ask({'Move': {'window': chosen['id'], 'to': [x, round(origin[1])]}})
            if 'Ok' not in reply: stop('owned logical window move', reply)
            window_step['n'] += 1; window_step['next'] += 1 / rate
            remaining = window_step['next'] - time.monotonic()
            if remaining > 0: time.sleep(remaining)
            else: window_step['next'] = time.monotonic()
        window_step['seen'].append(next(w['position'][0] for w in state()['windows'] if w['id'] == chosen['id']))
    phases.append(('moving window', measure('moving window', moving_window)))
    check('owned logical window moved continuously', max(window_step['seen']) - min(window_step['seen']) > swing / 2, [min(window_step['seen']), max(window_step['seen'])])
    restored = ask({'Move': {'window': chosen['id'], 'to': [round(origin[0]), round(origin[1])]}})
    if 'Ok' not in restored: stop('restore owned logical window position', restored)
if os.environ.get('INFINIFY_BENCH_FOCUS_SWITCH') == '1':
    ids = sorted(w['id'] for w in adopted); focus_step = {'n': 0, 'seen': set()}
    def switching_focus():
        wanted = ids[focus_step['n'] % len(ids)]; reply = ask({'Focus': wanted})
        focused = reply.get('Ok', {}).get('Focused')
        if not focused or focused.get('id') != wanted: stop('owned logical focus switch', reply)
        focus_step['seen'].add(wanted); focus_step['n'] += 1; time.sleep(.125)
    phases.append(('switching focus', measure('switching focus', switching_focus)))
    check('logical focus reached every owned window', focus_step['seen'] == set(ids), sorted(focus_step['seen']))
if mode == 'capture':
    for line in errlog.read_text(errors='replace').splitlines():
        if line.startswith('buffers:'): print(line, flush=True)
    if os.environ.get('INFINIFY_BENCH_VALIDATE_BUDGET') == '1':
        def buffers():
            result = {}
            for line in errlog.read_text(errors='replace').splitlines():
                if line.startswith('buffers:'):
                    result.update({int(i): [int(w), int(h)] for i, w, h in re.findall(r'#(\d+)=(\d+)x(\d+)', line)})
                if line.startswith('capture:'):
                    for i, w, h in re.findall(r'window=(\d+) pixels=(\d+)x(\d+)', line): result[int(i)] = [int(w), int(h)]
            return result
        native = {w['id']: status(n)['bounds'][2:] for w in adopted for n in names if status(n)['title'] == w['title']}
        density = min(2, 2 ** math.ceil(math.log2(zoom * 2)))
        reduced = {i: [math.ceil(v * density) for v in dims] for i, dims in native.items()}
        full = {i: [2 * v for v in dims] for i, dims in native.items()}
        until('captures match the overview pixel budget', 4, buffers, lambda b: b == reduced)
        check('overview captures have fewer pixels', density < 2, {'actual': buffers(), 'full': full, 'pixel_ratio': (density / 2) ** 2})
        before = {w['id']: [w['position'], w['size']] for w in state()['windows']}
        native_before = {n: status(n)['bounds'] for n in names}
        done = msg('zoom', '1')
        if done.returncode: stop('zoom in for capture quality', done.stderr)
        until('zoom reaches 1:1', 5, state, lambda s: abs(s['zoom'] - 1) < .002)
        # The inner corners of all four tiles still intersect the viewport at 1:1.
        until('zoomed-in captures regain full resolution', 4, buffers, lambda b: b == full)
        done = msg('zoom', f'{zoom:.4f}')
        if done.returncode: stop('return to overview', done.stderr)
        until('zoom returns', 5, state, lambda s: abs(s['zoom'] - zoom) < .002)
        until('overview captures reduce again', 4, buffers, lambda b: b == reduced)
        chosen_name = next(n for n in names if status(n)['title'] == adopted[0]['title'])
        (evidence / chosen_name / 'stripes').write_text('1')
        until('native export marker is enabled', 2, lambda: status(chosen_name), lambda s: s['export_stripes'])
        chosen = adopted[0]['id']; beginning = len(errlog.read_text(errors='replace').splitlines())
        done = msg('screenshot', 'window', '--id', str(chosen), '-o', str(evidence / 'export.png'), '--scale', '2')
        if done.returncode: stop('full-resolution screenshot from overview', done.stderr.strip())
        fresh = errlog.read_text(errors='replace').splitlines()[beginning:]
        check('export received an actual full-resolution frame', any(f'window={chosen} pixels={full[chosen][0]}x{full[chosen][1]}' in l for l in fresh), fresh)
        image = evidence / 'export.png'; data = image.read_bytes(); png_size = struct.unpack('>II', data[16:24])
        check('export wrote a full-size PNG', data.startswith(b'\x89PNG\r\n\x1a\n') and all(v >= want for v, want in zip(png_size, full[chosen])), png_size)
        # Inspect the file's pixels independently of the renderer. Upsampling an overview cannot recover these stripes.
        rows = runpy.run_path('native/captured-windows/verify-png.py')['pixels'](image, png_size)
        longest = 0
        for row in rows[::8]:
            for phase in (0, 1):
                last = None; run = 0
                for x in range(phase, png_size[0], 2):
                    r, g, b, alpha = row[x * 4:x * 4 + 4]
                    color = None if alpha < 240 else 0 if max(r, g, b) < 40 else 1 if min(r, g, b) > 215 else None
                    run = run + 1 if color is not None and last is not None and color != last else int(color is not None)
                    last = color; longest = max(longest, run)
        check('export preserves one-point black/white stripe contrast', longest >= 48, {'alternating_samples': longest})
        until('overview budget resumes after export', 4, buffers, lambda b: b == reduced)
        check('capture budgets preserve every world rectangle', before == {w['id']: [w['position'], w['size']] for w in state()['windows']}, state()['windows'])
        check('camera and capture budgets preserve native bounds', native_before == {n: status(n)['bounds'] for n in names}, native_before)

if os.environ.get('INFINIFY_BENCH_CV_CLOCK') == '1':
    clocks = [l for l in errlog.read_text(errors='replace').splitlines() if l.startswith('display_thread:')]
    check('separate display-thread candidate was active', bool(clocks), clocks)
    for line in clocks: print(line, flush=True)

print('--- summary (per second; milliseconds)', flush=True)
for name, r in phases:
    print(f'{name}: display={r["display"]:.0f} sources={r["sources"]} accepted_least={r["accepted_least"]:.1f} redraws={r["redraws"]:.1f} flushes={r["flushes"]:.1f} drawn={r["drawn"]:.1f} presented={r["presented"]:.1f} flush_mean_ms={r["flush_mean_ms"]:.2f} flush_worst_ms={r["flush_worst_ms"]:.2f} main_gap_worst_ms={r["main_gap_worst_ms"]:.1f}', flush=True)
    print(f'{name}: actual_gap_p99_worst_ms={r["presentation_p99_worst_ms"]:.3f} actual_gap_worst_ms={r["presentation_gap_worst_ms"]:.3f} presentation_silence_worst_ms={r["presentation_silence_worst_ms"]:.3f} missed_refreshes={r["missed"]:.0f} submission_latency_worst_ms={r["latency_worst_ms"]:.3f} gpu_worst_ms={r["gpu_worst_ms"]:.3f} camera_updates={r["camera_updates"]:.0f} camera_repeats={r["camera_repeats"]:.0f}', flush=True)
    print(f'{name}: acquire_worst_ms={r["acquire_worst_ms"]:.3f} acquire_queue_worst_ms={r["acquire_queue_worst_ms"]:.3f} publish_worst_ms={r["publish_worst_ms"]:.3f} notify_worst_ms={r["notify_worst_ms"]:.3f} completion_worst_ms={r["completion_worst_ms"]:.3f} acquire_timeouts={r["acquire_timeouts"]:.0f} not_presented={r["not_presented"]:.0f}', flush=True)
    print(f'{name}: panel_observations={r["panel_rows"]} occluded_observations={r["occluded_rows"]} hidden_observations={r["hidden_rows"]} hides_inactive_observations={r["hides_inactive_rows"]} inactive_space_observations={r["inactive_space_rows"]}', flush=True)
    print(f'{name}: cpu_percent_one_core={r["cpu_percent_one_core"]:.2f} cpu_interval_seconds={r["process_interval_seconds"]:.2f} rss_start_kib={r["rss_start_kib"]} rss_end_kib={r["rss_end_kib"]}', flush=True)
    print(f'{name}: separate related-process intervals (WindowServer is whole desktop; RSS excludes GPU allocations): {json.dumps(r["related_processes"])}', flush=True)
(evidence / 'summary.json').write_text(json.dumps({'mode': mode, 'fixture_count': fixture_count, 'requested_rate': rate,
    'fixture_points': [status(n)['bounds'][2:] for n in names], 'output_points': out,
    'selected_seconds_per_phase': windows * 2, 'phases': dict(phases)}, indent=2) + '\n')
for name, r in phases:
    hz = r['display']
    if mode == 'native': check(f'{name}: native scene has no captured frame delivery or acceptance', r['received_most'] == 0 and r['accepted_most'] == 0, {'bound_sources': r['sources'], 'received_most': r['received_most'], 'accepted_most': r['accepted_most']})
    else: check(f'{name}: {fixture_count} sources, each kept at least 90% of {rate:.0f} frames a second', r['sources'] == fixture_count and r['accepted_least'] >= .9 * rate, {'sources': r['sources'], 'least': r['accepted_least']})
    check(f'{name}: flushes a second do not exceed the display\'s {hz:.0f} by more than 3%', r['flushes'] <= hz * 1.03, round(r['flushes'], 1))
    # A load slower than the display leaves refreshes with nothing new to show: then it is printed and not judged.
    if rate >= hz: check(f'{name}: frames presented a second are within 10% of the display\'s {hz:.0f}', hz * .9 <= r['presented'] <= hz * 1.1, round(r['presented'], 1))
    else: ok(f'{name}: frames presented a second (not judged: the load is below the display\'s {hz:.0f})', round(r['presented'], 1))
    check(f'{name}: the main thread was never away from its run loop for 50 ms', r['main_gap_worst_ms'] < 50, r['main_gap_worst_ms'])
    if os.environ.get('INFINIFY_BENCH_STRICT') == '1' and (rate >= hz or os.environ.get('INFINIFY_BENCH_ANIMATION') == '1'):
        check(f'{name}: measured canvas is visible and unoccluded', r['panel_rows'] >= windows and r['occluded_rows'] == 0 and r['hidden_rows'] == 0, {'observed': r['panel_rows'], 'occluded': r['occluded_rows'], 'hidden': r['hidden_rows']})
        check(f'{name}: actual drawable times cover measured frame windows', r['presentation_rows'] >= windows, r['presentation_rows'])
        check(f'{name}: strict target keeps at least 99% of {hz:.0f} refreshes', r['presented'] >= hz * .99, round(r['presented'], 2))
        check(f'{name}: strict target has no missed refreshes or presentation silence', r['missed'] == 0 and max(r['presentation_gap_worst_ms'], r['presentation_silence_worst_ms']) <= 1500 / hz, {'missed': r['missed'], 'worst_gap_ms': r['presentation_gap_worst_ms'], 'silence_ms': r['presentation_silence_worst_ms']})
        check(f'{name}: strict target has no GPU errors or lost timing samples', r['errors'] == 0, r['errors'])
        check(f'{name}: positive timestamps establish distinct ordered display updates', r['duplicate_time'] == 0 and r['reordered_time'] == 0,
              {'duplicate_time': r['duplicate_time'], 'reordered_time': r['reordered_time']})
        if name in ('panning', 'zooming'):
            check(f'{name}: every presented motion frame has a fresh camera pose', r['actual_presented'] > 0 and r['camera_updates'] == r['actual_presented'] and r['camera_repeats'] == 0,
                  {'presented': r['actual_presented'], 'camera_updates': r['camera_updates'], 'camera_repeats': r['camera_repeats']})
if mode == 'native':
    # Give shutdown a final settled pose; independently compare the persisted
    # viewport after quit, which must follow all earlier asynchronous saves.
    ask({'Zoom': zoom}); until('final zoom lands', 5, state, lambda s: abs(s['zoom'] - zoom) < 1e-10)
    # A zoom value can land a tick before its anchor is retired. Repeat the
    # camera target if that final anchor tick consumed the first one.
    until('final camera lands', 5, lambda: (ask({'Camera': [cx, cy]}), state())[1], lambda s: abs(s['camera'][0] - cx) < 1e-6 and abs(s['camera'][1] - cy) < 1e-6)
    time.sleep(.1); final = state()
    (evidence / 'final-state.json').write_text(json.dumps(final))
if failed: print(f'FAILED: {len(failed)} of the assertions above', flush=True); sys.exit(1)
PY

shown() { grep -Eq '"visible"[[:space:]]*:[[:space:]]*true' "$evidence/$1/status.json" 2>/dev/null; }
for name in $fixture_names; do
  n=0; while ! shown "$name" && [ "$n" -lt 150 ]; do sleep .1; n=$((n+1)); done
  shown "$name" || { echo "FAIL: fixture $name never showed its window"; exit 1; }
done
sleep .5
# Larger than any display: the run takes what the screen's visible area gives it.
set --; if [ "$mode" = native ]; then set -- --native-helper "$evidence/h" "$evidence/nonce" --debug-pointer; fi
INFINIFY_DEBUG=1 INFINIFY_DEBUG_BENCH=1 INFINIFY_DEBUG_NATIVE_BENCH=$nativebench INFINIFY_DEBUG_SCREEN_CLOCK=${INFINIFY_BENCH_SCREEN_CLOCK:-0} INFINIFY_DEBUG_METAL_CLOCK=${INFINIFY_BENCH_METAL_CLOCK:-0} INFINIFY_DEBUG_CV_CLOCK=${INFINIFY_BENCH_CV_CLOCK:-0} INFINIFY_DEBUG_SYNC_DRAWABLE=$baseline INFINIFY_DEBUG_FULL_CAPTURE=$baseline INFINIFY_DEBUG_SYNTH=$synth "$app" --windowed 16384x16384 --state "$state" --config "$config" --socket "$socket" --no-native-focus --no-hover-forwarding --only-pid "$scope" "$@" 2>"$evidence/err.log" & infinify=$!
printf '%s\n' "$infinify" > "$evidence/app.pid"
n=0; while [ ! -S "$socket" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done; [ -S "$socket" ] || { echo "FAIL: no socket: $(cat "$evidence/err.log")"; exit 1; }
python3 "$evidence/driver.py" "$evidence" "$rate" "$app" "$mode" & driverpid=$!
if wait "$driverpid"; then result=0; else result=$?; fi
driverpid=
quit
if [ "$mode" = native ] && [ -f "$evidence/final-state.json" ]; then
  python3 - "$evidence" <<'PY'
import json, os, pathlib, sys
folder = pathlib.Path(sys.argv[1]); final = json.loads((folder / 'final-state.json').read_text()); saved = json.loads((folder / 'state.json').read_text())
assert saved['version'] == 1 and len(saved['scene']['windows']) == int(os.environ['INFINIFY_BENCH_WINDOWS']), 'final scene must contain exactly the owned fixture placeholders'
view = next(iter(saved['outputs'].values()))['viewport']; size = view['screen_bounds']['size']; zoom = view['zoom']
center = [view['camera']['x'] + size['width'] / zoom / 2, -view['camera']['y'] - size['height'] / zoom / 2]
assert abs(zoom - final['zoom']) < 1e-10 and all(abs(a-b) < 1e-6 for a,b in zip(center, final['camera'])), f'final save differs: {center}, {zoom}'
print(f'ok: asynchronous saves drain before the final persisted camera and zoom: {center}, {zoom}', flush=True)
PY
fi
[ "$result" -eq 0 ] || exit 1
if [ "${INFINIFY_BENCH_IDLE_DIAGNOSTIC:-0}" = 1 ]; then echo 'PASS: scoped idle native geometry diagnostic'; exit 0; fi
echo "PASS: scoped render bench: $fixture_count owned windows, $mode, requested $rate Hz, at rest and panning"
