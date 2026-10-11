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
# The pictures are made up, so this says nothing of what capturing costs: ScreenCaptureKit's own work, and a window's, are
# not in it. Everything acted on is a process this script started; nothing is clicked, the pointer is never moved and
# nothing is posted at the session level. Run it while nobody is using the machine: the canvas covers the visible screen.
#
# INFINIFY_BENCH_SIZE=WxH (1700x1100) is the fixture windows' content size, INFINIFY_BENCH_RATE (120) the frames a second.
# Exit status: 0 measured and every assertion held; 1 something failed; 2 usage; 3 nothing was started (NOT RUN), because
# Stage Manager is on or another Infinify is running.
set -eu
cd "$(dirname "$0")/../.."
[ "$#" -eq 0 ] || { echo "Usage: $0" >&2; exit 2; }
root=$PWD
[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" != 1 ] || { echo 'NOT RUN: Stage Manager is on (com.apple.WindowManager GloballyEnabled is 1); nothing was started and nothing was measured.'; exit 3; }
# A desktop somebody is in must not have a second canvas laid over it, and its frames would be in the numbers.
if pgrep -f 'Infinify.app/Contents/MacOS/Infinify' >/dev/null 2>&1; then echo 'NOT RUN: another Infinify is running; nothing was started and nothing was measured.'; exit 3; fi
# INFINIFY_BENCH_APP: another build's executable, to set two builds side by side.
app=${INFINIFY_BENCH_APP:-$root/target/app/Infinify.app/Contents/MacOS/Infinify}
[ -x "$app" ] || ./scripts/build-app.sh
size=${INFINIFY_BENCH_SIZE:-1700x1100}; rate=${INFINIFY_BENCH_RATE:-120}
mkdir -p target/ipc
# Short: a socket path has room for about a hundred bytes.
evidence=$(mktemp -d "$root/target/ipc/bench.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
state=$evidence/state.json; config=$evidence/config.toml; socket=$evidence/s; : > "$config"
infinify=; fixtures=
quit() {
  [ -n "$infinify" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0; while kill -0 "$infinify" 2>/dev/null && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done
  kill -0 "$infinify" 2>/dev/null && kill "$infinify" 2>/dev/null || true
  wait "$infinify" 2>/dev/null || true; infinify=
}
# Only what this script started is ever signalled.
cleanup() { quit; for pid in $fixtures; do kill "$pid" 2>/dev/null || true; done; for pid in $fixtures; do wait "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

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
start() { mkdir "$evidence/$1"; "$fixture" "$evidence/$1" "Bench fixture $1 $$" "$2" 150 size "$size" & fixtures="$fixtures $!"; }
start a -30; A=$!
start b -10; B=$!
start c 10; C=$!
start d 30; D=$!

cat > "$evidence/driver.py" <<'PY'
import json, pathlib, re, socket, subprocess, sys, time
evidence = pathlib.Path(sys.argv[1]); rate = float(sys.argv[2]); app = sys.argv[3]
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
def until(what, seconds, read, passed):
    end = time.time() + seconds
    while True:
        value = read()
        if passed(value): return value
        if time.time() > end: stop(what, value)
        time.sleep(.05)
def lines(): return [l for l in errlog.read_text(errors='replace').splitlines() if l.startswith('frames: ')]
names = ['a', 'b', 'c', 'd']; titles = sorted(status(n)['title'] for n in names)
adopted = until('adopts the four fixture windows', 10, lambda: state()['windows'], lambda w: sorted(x['title'] for x in w) == titles)
ok('adopts the four fixture windows', [(w['id'], w['size']) for w in adopted])
managing = [l for l in errlog.read_text(errors='replace').splitlines() if l.startswith('Managing only')]
ok('Screen Recording', 'not granted: every picture is the made-up load' if managing and 'No Screen Recording access' in managing[0] else 'granted: the windows are captured as well as fed')
for n in names: ok(f'fixture {n} window', {'points': status(n)['bounds'][2:], 'pixels': [2 * v for v in status(n)['bounds'][2:]]})

# Two rows of two about the middle of the view, and a zoom that shows all four with room for the pan.
first = state(); cx, cy = first['camera']; out = first['outputs'][0]['size']; gap = 40; swing = 120
wide = max(w['size'][0] for w in adopted); high = max(w['size'][1] for w in adopted)
spots = [(-1, 1), (1, 1), (-1, -1), (1, -1)]
for w, (sx, sy) in zip(sorted(adopted, key=lambda w: w['title']), spots):
    done = msg('move', '--id', str(w['id']), str(int(cx + sx * (wide + gap) / 2)), str(int(cy + sy * (high + gap) / 2)))
    if done.returncode: stop(f'msg move {w["title"]}', done.stderr.strip())
zoom = min(out[0] / (2 * wide + 3 * gap + 2 * swing), out[1] / (2 * high + 3 * gap))
done = msg('zoom', f'{zoom:.4f}')
if done.returncode: stop('msg zoom', done.stderr.strip())
done = msg('camera', str(cx), str(cy))
if done.returncode: stop('msg camera', done.stderr.strip())
# Is every tile whole inside what the output shows with the camera at `x`? Positions are frame centres, Y up, as the camera's.
def inside(s, x):
    z = s['zoom']; half = [out[0] / z / 2, out[1] / z / 2]
    return all(abs(w['position'][0] - x) + w['size'][0] / 2 <= half[0] and abs(w['position'][1] - s['camera'][1]) + w['size'][1] / 2 <= half[1] for w in s['windows'])
settled = until('the zoom and the camera arrive', 5, state, lambda s: abs(s['zoom'] - zoom) < .002 and abs(s['camera'][0] - cx) < 1 and abs(s['camera'][1] - cy) < 1)
check('all four tiles are in view, at either end of the pan too', inside(settled, cx - swing) and inside(settled, cx + swing), {'output': out, 'zoom': round(settled['zoom'], 4), 'camera': settled['camera'], 'tiles': [(w['position'], w['size']) for w in settled['windows']]})

fields = re.compile(r'frames: ([\d.]+)s display=(\d+) redraws=([\d.]+) flushes=([\d.]+) drawn=([\d.]+) presented=([\d.]+) flush_ms=([\d.]+)/([\d.]+) main_gap_ms=([\d.]+) sources(.*)')
# Five whole frame lines, ten seconds: the line that was being counted when the phase began is left out. `work` runs meanwhile.
def measure(name, work):
    time.sleep(1); begun = len(lines()); end = time.time() + 30
    while len(lines()) < begun + 6:
        if time.time() > end: stop(f'{name}: frame lines', lines()[begun:])
        work()
    taken = lines()[begun + 1:begun + 6]; rows = []
    print(f'--- {name}', flush=True)
    for l in taken:
        print(l, flush=True); m = fields.match(l)
        if not m: stop(f'{name}: a frame line that does not parse', l)
        rows.append([float(v) for v in m.groups()[:9]] + [[[float(v) for v in s.split('=')[1].split('/')] for s in m.group(10).split()]])
    mean = lambda i: sum(r[i] for r in rows) / len(rows)
    # The mean flush is weighted by the flushes of each line.
    flushes = sum(r[3] * r[0] for r in rows)
    sources = [min(s[i][1] for r in rows for s in [r[9]] if i < len(s)) for i in range(max(len(r[9]) for r in rows))]
    return {'display': rows[0][1], 'redraws': mean(2), 'flushes': mean(3), 'drawn': mean(4), 'presented': mean(5),
            'flush_mean_ms': sum(r[6] * r[3] * r[0] for r in rows) / flushes if flushes else 0, 'flush_worst_ms': max(r[7] for r in rows), 'main_gap_worst_ms': max(r[8] for r in rows),
            'sources': len(sources), 'accepted_least': min(sources) if sources else 0}
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

print('--- summary (per second; milliseconds)', flush=True)
for name, r in [('at rest', rest), ('panning', moving)]:
    print(f'{name}: display={r["display"]:.0f} sources={r["sources"]} accepted_least={r["accepted_least"]:.1f} redraws={r["redraws"]:.1f} flushes={r["flushes"]:.1f} drawn={r["drawn"]:.1f} presented={r["presented"]:.1f} flush_mean_ms={r["flush_mean_ms"]:.2f} flush_worst_ms={r["flush_worst_ms"]:.2f} main_gap_worst_ms={r["main_gap_worst_ms"]:.1f}', flush=True)
for name, r in [('at rest', rest), ('panning', moving)]:
    hz = r['display']
    check(f'{name}: four sources, each kept at least 90% of {rate:.0f} frames a second', r['sources'] == 4 and r['accepted_least'] >= .9 * rate, {'sources': r['sources'], 'least': r['accepted_least']})
    check(f'{name}: flushes a second do not exceed the display\'s {hz:.0f} by more than 3%', r['flushes'] <= hz * 1.03, round(r['flushes'], 1))
    # A load slower than the display leaves refreshes with nothing new to show: then it is printed and not judged.
    if rate >= hz: check(f'{name}: frames presented a second are within 10% of the display\'s {hz:.0f}', hz * .9 <= r['presented'] <= hz * 1.1, round(r['presented'], 1))
    else: ok(f'{name}: frames presented a second (not judged: the load is below the display\'s {hz:.0f})', round(r['presented'], 1))
    check(f'{name}: the main thread was never away from its run loop for 50 ms', r['main_gap_worst_ms'] < 50, r['main_gap_worst_ms'])
if failed: print(f'FAILED: {len(failed)} of the assertions above', flush=True); sys.exit(1)
PY

shown() { grep -q '"visible":true' "$evidence/$1/status.json" 2>/dev/null; }
for name in a b c d; do
  n=0; while ! shown "$name" && [ "$n" -lt 150 ]; do sleep .1; n=$((n+1)); done
  shown "$name" || { echo "FAIL: fixture $name never showed its window"; exit 1; }
done
sleep .5
# Larger than any display: the run takes what the screen's visible area gives it.
INFINIFY_DEBUG=1 INFINIFY_DEBUG_SYNTH=$rate "$app" --windowed 16384x16384 --state "$state" --config "$config" --socket "$socket" --no-hover-forwarding --only-pid "$A,$B,$C,$D" 2>"$evidence/err.log" & infinify=$!
n=0; while [ ! -S "$socket" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n+1)); done; [ -S "$socket" ] || { echo "FAIL: no socket: $(cat "$evidence/err.log")"; exit 1; }
if python3 "$evidence/driver.py" "$evidence" "$rate" "$app"; then result=0; else result=$?; fi
quit
[ "$result" -eq 0 ] || exit 1
echo "PASS: scoped render bench: four $size windows fed $rate frames a second each, at rest and panning"
