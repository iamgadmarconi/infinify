#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Measure drag-and-drop between two disposable AppKit fixtures while Infinify's Dock helper draws them away from their
native frames (compositor mode), at several canvas zooms. Everything runs in a disposable guest reached through the
command prefix in $DND_GSSH; nothing here touches the machine that runs this script except ssh.

Modes (see tests/e2e/compositor-dnd.sh, which starts the two fixtures and passes their log and window facts):
  pair  Click the destination at two points, then drag the source's file URL onto the same points. The window-local point the
        destination reports for the drop must equal the one its own click reported, which itself must equal the point computed
        from the DRAWN rectangle (what a person sees). Also records the drag image window and the taps' own log lines.
  outside  Drop at a point inside the destination's native rectangle and outside its drawn one: nothing may be dropped.
  band  Press in the source's top rows at several (zoom, native offset) pairs and report whether the drop happened or
        WindowServer's window drag began instead, which Infinify takes over (a measured limit, asserted only for the controls).
"""
import json
import os
import shlex
import subprocess
import sys
import time

GSSH = shlex.split(os.environ['DND_GSSH'])
INF = os.environ.get('DND_INFINIFY', '$HOME/Applications/Infinify.app/Contents/MacOS/Infinify')
HID = os.environ.get('DND_HID', '/tmp/compositor-dnd-hid')
LOGS = os.environ.get('DND_LOG_DIR', '~/dnd-fixture-log')
INFINIFY_LOG = os.environ.get('DND_INFINIFY_LOG', '')
TITLE = 28.0   # a plain titled window's title bar, native points
SCREEN = tuple(float(x) for x in os.environ.get('DND_SCREEN', '1920x1200').split('x'))


def gs(cmd, timeout=180):
    r = subprocess.run(GSSH + [cmd], capture_output=True, text=True, timeout=timeout)
    return r.stdout


def state():
    return json.loads(gs(f'{INF} msg --json state'))['Ok']['State']


def msg(args):
    return gs(f'{INF} msg {args}')


def win(st, wid):
    return [w for w in st['windows'] if w['id'] == wid][0]


def hid(wids, ops, every=5):
    cmd = f'{HID} ' + ' '.join(f'--wid {w}' for w in wids) + f' --trace-every {every} ' + ' '.join(shlex.quote(str(o)) for o in ops)
    rows = []
    for line in gs(cmd, timeout=300).splitlines():
        if line.startswith('{'):
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def displayed(wid, wait=8.0):
    """(drawn rectangle, native rectangle, probe row) once the window is on a display and not parked past it."""
    end = time.time() + wait
    while True:
        r = [x for x in hid([wid], ['probe', 'p']) if 'cglist' in x][0]
        c = r['cglist']
        if (-300 <= c[0] < SCREEN[0] and 0 <= c[1] < SCREEN[1]) or time.time() > end:
            return tuple(c), tuple(r['native']), r
        time.sleep(0.4)


def layout(src, dst, zoom, gap=80):
    """Destination right of the origin, source left of it, camera at the origin; waits for the camera to settle. `msg move`
    takes integers only."""
    st = state()
    dist = int(round((win(st, src)['size'][0] + win(st, dst)['size'][0]) / 2 + gap))
    dist += dist % 2
    for _ in range(4):
        msg(f'move {dist // 2} 0 --id {dst}')
        msg(f'move {-(dist // 2)} 0 --id {src}')
        time.sleep(0.8)
        st = state()
        if abs(win(st, dst)['position'][0] - dist // 2) < 2 and abs(win(st, src)['position'][0] + dist // 2) < 2:
            break
    msg(f'focus --id {dst}')
    time.sleep(0.8)
    msg(f'zoom {zoom}')
    msg('camera 0 0')
    last = None
    for _ in range(30):
        time.sleep(0.6)
        o = state()['outputs'][0]
        cur = (tuple(o['camera']), o['zoom'])
        if cur == last and abs(cur[0][0]) < 1 and abs(cur[0][1]) < 1 and abs(cur[1] - zoom) < 0.01:
            break
        last = cur
    time.sleep(0.8)


def fixture(name):
    """(window number, pid) from the fixture's own ready line; its Infinify window id comes from the state's pid field."""
    for line in gs(f'cat {LOGS}/{name}.jsonl').splitlines():
        if '"ready"' in line:
            r = json.loads(line)
            return r['windowNumber'], r['pid']


def log_lines(name):
    return [json.loads(x) for x in gs(f'cat {LOGS}/{name}.jsonl').splitlines() if x.startswith('{')]


def drag(wsrc, wdst, p_src, p_dst, zoom, evidence, name):
    mark = int(gs(f'wc -l < {INFINIFY_LOG}').strip() or 0) if INFINIFY_LOG else 0
    n1, n2 = len(log_lines('p1')), len(log_lines('p2'))
    sx, sy = p_src
    dx, dy = p_dst
    z = min(zoom, 1)
    ops = ['move', sx, sy, 'sleep', 300, 'probe', 'pre', 'wins', 'pre', 90, 'down', sx, sy, 'sleep', 250,
           'drag', sx + 13 * z, sy + 6 * z, 6, 40, 'sleep', 350, 'wins', 'started', 90,
           'drag', dx, dy, 30, 20, 'sleep', 700, 'wins', 'hover', 90, 'probe', 'hover',
           'sh', f'screencapture -x /tmp/compositor-dnd-{name}.png', 'up', dx, dy, 'sleep', 1100, 'wins', 'after', 90, 'probe', 'after']
    rows = hid([wsrc, wdst], ops)
    mine = log_lines('p1')[n1:]
    dropped = any(e['ev'] == 'perform' for e in log_lines('p2')[n2:])
    began = any(e['ev'] == 'beginSession' for e in mine)
    # the source's own endedAtPoint says its session ended; a session that began and never ended outlived the release
    stuck = began and not any(e['ev'] == 'ended' for e in mine)
    after = [r for r in rows if r.get('label') == 'after' and 'wins' in r]
    residual = [(w['pid'], w['id']) for w in after[0]['wins'] if w['layer'] == 500] if after else []
    if stuck:   # free the guest and say so
        hid([], ['up', dx, dy, 'sleep', 800])
    taps = gs(f"tail -n +{mark + 1} {INFINIFY_LOG} | grep -a 'native mouse owner\\|taken over\\|lost\\|release' | cut -c1-200 | head -14").splitlines() if INFINIFY_LOG else []
    with open(f'{evidence}/{name}.jsonl', 'w') as f:
        f.write('\n'.join(json.dumps(r) for r in rows) + '\n')
    return {'rows': rows, 'stuck_session': stuck, 'session_started': began, 'dropped': dropped, 'taps': taps, 'residual_drag_windows_after_1s': residual}


def mode_pair(argv, evidence):
    p1, p2 = fixture('p1'), fixture('p2')
    st = state()
    ids = {w['pid']: w['id'] for w in st['windows'] if 'pid' in w}
    i1, i2 = ids[p1[1]], ids[p2[1]]
    w1, w2 = p1[0], p2[0]
    failures = []
    out = {}
    for zoom in (float(z) for z in (argv or ['1', '0.75', '0.5'])):
        layout(i1, i2, zoom)
        cg1, n1, _ = displayed(w1)
        cg2, n2, r2 = displayed(w2)
        ch, cw = n2[3] - TITLE, n2[2]
        for tag, fx, fy in (('A', 0.3, 0.7), ('B', 0.8, 0.25)):
            px, py = cg2[0] + fx * cw * zoom, cg2[1] + (TITLE + fy * ch) * zoom
            exp = [(px - cg2[0]) / zoom, ch - ((py - cg2[1]) / zoom - TITLE)]   # window-local, bottom-left origin, native points
            b0 = len(log_lines('p2'))
            hid([w2], ['move', px, py, 'sleep', 150, 'down', px, py, 'sleep', 60, 'up', px, py, 'sleep', 300])
            click = [e for e in log_lines('p2')[b0:] if e['ev'] == 'mouseDown']
            b0 = len(log_lines('p2'))
            sx, sy = cg1[0] + 0.5 * cg1[2], cg1[1] + (TITLE + 0.25 * ch) * zoom
            r = drag(w1, w2, (sx, sy), (px, py), zoom, evidence, f'pair-z{zoom}-{tag}')
            perform = [e for e in log_lines('p2')[b0:] if e['ev'] == 'perform']
            key = f'z{zoom}-{tag}'
            rec = {'zoom': zoom, 'point': [px, py], 'expected_winLoc': exp, 'drawn': cg2, 'native': n2, 'xf': r2['xf'],
                   'click_winLoc': click[0]['winLoc'] if click else None,
                   'drop_winLoc': perform[0]['winLoc'] if perform else None,
                   'stuck_session': r['stuck_session'], 'residual_drag_windows_after_1s': r['residual_drag_windows_after_1s'], 'taps': r['taps']}
            out[key] = rec
            if not perform or not click:
                failures.append(f'{key}: no drop or no click recorded')
            else:
                d = [perform[0]['winLoc'][i] - exp[i] for i in (0, 1)]
                c = [perform[0]['winLoc'][i] - click[0]['winLoc'][i] for i in (0, 1)]
                rec['delta_vs_drawn'], rec['delta_vs_click'] = d, c
                if max(abs(v) for v in d + c) > 1.5:
                    failures.append(f'{key}: drop {perform[0]["winLoc"]} vs expected {exp} vs click {click[0]["winLoc"]}')
            if r['stuck_session']:
                failures.append(f'{key}: the source began a session and never saw it end')
            print(key, 'expected', [round(v, 1) for v in exp], 'click', click[0]['winLoc'] if click else None,
                  'drop', perform[0]['winLoc'] if perform else None, flush=True)
    return out, failures


def mode_band(argv, evidence):
    p1, p2 = fixture('p1'), fixture('p2')
    ids = {w['pid']: w['id'] for w in state()['windows'] if 'pid' in w}
    i1, i2 = ids[p1[1]], ids[p2[1]]
    w1, w2 = p1[0], p2[0]
    out, failures = {}, []
    # (zoom, native offset of the press from the window's top edge, whether the drop must happen: None = measured only)
    cases = [(0.5, 40, None), (0.75, 40, None), (0.5, 70, True), (1.0, 40, True)]
    for zoom, off, must in cases:
        layout(i1, i2, zoom)
        cg1, _, _ = displayed(w1)
        cg2, _, _ = displayed(w2)
        p_src = (cg1[0] + 0.5 * cg1[2], cg1[1] + off * zoom)
        p_dst = (cg2[0] + 0.5 * cg2[2], cg2[1] + 0.8 * cg2[3])
        r = drag(w1, w2, p_src, p_dst, zoom, evidence, f'band-z{zoom}-y{off}')
        taken = any('taken over' in t for t in r['taps'])
        out[f'z{zoom}-y{off}'] = {'drawn_offset': off * zoom, 'session_started': r['session_started'], 'dropped': r['dropped'], 'window_drag_taken_over': taken, 'taps': r['taps']}
        print(f'zoom {zoom} press {off} native points below the top edge ({off * zoom:g} drawn): session began={r["session_started"]} dropped={r["dropped"]} window_drag_taken_over={taken}', flush=True)
        if must is not None and (r['dropped'] != must or taken == must):
            failures.append(f'z{zoom}-y{off}: dropped={r["dropped"]} taken_over={taken}, expected a drop={must}')
    return out, failures


def mode_outside(argv, evidence):
    """Drop at a point inside the destination's NATIVE rectangle but outside its DRAWN one (zoom 0.5, where they differ most): the
    destination must see nothing, since WindowServer targets what is drawn."""
    p1, p2 = fixture('p1'), fixture('p2')
    ids = {w['pid']: w['id'] for w in state()['windows'] if 'pid' in w}
    i1, i2 = ids[p1[1]], ids[p2[1]]
    w1, w2 = p1[0], p2[0]
    layout(i1, i2, 0.5)
    cg1, _, _ = displayed(w1)
    cg2, n2, _ = displayed(w2)
    def inside(r, x, y): return r[0] <= x < r[0] + r[2] and r[1] <= y < r[1] + r[3]
    pt = None
    for fx in (0.15, 0.3, 0.45, 0.6, 0.75, 0.9):
        for fy in (0.15, 0.3, 0.45, 0.6, 0.75, 0.9):
            x, y = n2[0] + fx * n2[2], n2[1] + fy * n2[3]
            if inside(n2, x, y) and not inside(cg2, x, y) and not inside(cg1, x, y) and 40 < x < SCREEN[0] - 40 and 40 < y < SCREEN[1] - 80:
                pt = pt or (x, y)
    if pt is None:
        return {}, ['no point inside the destination native rectangle and outside both drawn rectangles']
    p_src = (cg1[0] + 0.5 * cg1[2], cg1[1] + (TITLE + 0.25 * (n2[3] - TITLE)) * 0.5)
    r = drag(w1, w2, p_src, pt, 0.5, evidence, 'outside-z0.5')
    out = {'point': pt, 'dst_native': n2, 'dst_drawn': cg2, 'dropped': r['dropped'], 'taps': r['taps']}
    print(f'drop at {pt[0]:.0f},{pt[1]:.0f}: inside native {n2}, outside drawn {cg2}: destination dropped={r["dropped"]}', flush=True)
    return out, ([] if not r['dropped'] else ['the destination received a drop outside its drawn rectangle'])


if __name__ == '__main__':
    mode, evidence = sys.argv[1], sys.argv[2]
    os.makedirs(evidence, exist_ok=True)
    out, failures = {'pair': mode_pair, 'band': mode_band, 'outside': mode_outside}[mode](sys.argv[3:], evidence)
    with open(f'{evidence}/{mode}.json', 'w') as f:
        json.dump(out, f, indent=1, default=str)
    for line in failures:
        print('FAIL:', line)
    sys.exit(1 if failures else 0)
