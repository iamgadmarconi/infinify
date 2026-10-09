#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline real-CLI tests using synthetic bytes. This is NOT native-window proof."""
import copy
import json
import math
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
PALETTE = [(255, 64, 0), (128, 0, 255), (255, 0, 0), (0, 0, 255),
           (0, 255, 0), (0, 255, 255), (255, 0, 255), (255, 255, 0)]


def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))


def png(pixels, filters=False, channels=4):
    raw = bytearray()
    previous = bytes(1040 * channels)
    for y in range(600):
        rgba = pixels[y * 4160:(y + 1) * 4160]
        row = rgba if channels == 4 else bytes(v for i, v in enumerate(rgba) if i % 4 != 3)
        method = y % 5 if filters else 0
        raw.append(method)
        if method == 0:
            raw.extend(row)
        else:
            for x, value in enumerate(row):
                a = row[x - channels] if x >= channels else 0
                b = previous[x]
                c = previous[x - channels] if x >= channels else 0
                if method == 1: predictor = a
                elif method == 2: predictor = b
                elif method == 3: predictor = (a + b) // 2
                else:
                    distances = [abs(b - c), abs(a - c), abs(a + b - 2 * c)]
                    predictor = [a, b, c][distances.index(min(distances))]
                raw.append((value - predictor) % 256)
        previous = row
    header = struct.pack('>IIBBBBB', 1040, 600, 8, 6 if channels == 4 else 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def paint(pixels, bounds, color):
    # Pixel-center rasterization, authored independently of verifier bounds.
    x0, y0, x1, y1 = bounds
    for y in range(max(0, math.ceil(y0 - .5)), min(600, math.ceil(y1 - .5))):
        for x in range(max(0, math.ceil(x0 - .5)), min(1040, math.ceil(x1 - .5))):
            start = (y * 1040 + x) * 4
            pixels[start:start + 4] = bytes((*color, 255))


def render(w=440, h=280, origin=(30, 30), old_wrap=False, stretch=False):
    pixels = bytearray(bytes((20, 20, 20, 255)) * (1040 * 600))
    tile_positions = [(16, 64), (72, 64), (128, 64), (184, 64), (240, 64), (296, 64)]
    if w < 400 and not old_wrap:
        tile_positions = [(16, 64), (72, 64), (128, 64), (16, 120), (72, 120), (128, 120)]
    if stretch:
        shapes = [(16, 16, 24, 24), (400, 240, 24, 24)]
        shapes += [(x, y, 36, 36) for x, y in [(16, 64), (72, 64), (128, 64), (184, 64), (240, 64), (296, 64)]]
        shapes = [(x * w / 440, y * h / 280, a * w / 440, b * h / 280) for x, y, a, b in shapes]
    else:
        shapes = [(16, 16, 24, 24), (w - 40, h - 40, 24, 24)]
        shapes += [(x, y, 36, 36) for x, y in tile_positions]
    for vx, scale in [(20, .6), (540, .9)]:
        for (x, y, a, b), color in zip(shapes, PALETTE):
            x0 = vx + scale * (origin[0] + x)
            y0 = 60 + scale * (origin[1] + y)
            paint(pixels, (max(vx, x0), max(60, y0), min(vx + 480, x0 + scale * a),
                           min(560, y0 + scale * b)), color)
    return pixels


def receipt(scenario='right-shrink', w=320, h=280):
    return {'scenario': scenario, 'camera': [0, 0], 'zooms': [.6, .9],
            'observations': [
                {'phase': 'before', 'ax': [100, 200, 440, 280], 'cg': [100, 200, 440, 280], 'png': 'before.png'},
                {'phase': 'after', 'ax': [101, 198, w, h], 'cg': [101, 198, w, h], 'png': 'after.png'}]}


def run(directory, name, document, before, after, passes, alter=None):
    for path in directory.iterdir():
        path.unlink()
    (directory / 'receipt.json').write_text(json.dumps(document))
    (directory / 'before.png').write_bytes(before)
    (directory / 'after.png').write_bytes(after)
    if alter:
        alter(directory)
    completed = subprocess.run([sys.executable, str(HERE / 'resize-verify.py'), str(directory)],
                               capture_output=True, text=True, timeout=30)
    result = json.loads((directory / 'independent-pixels.json').read_text())
    assert (completed.returncode == 0) == passes, (name, completed.stdout, completed.stderr)
    assert result['passed'] is passes, (name, result)
    if not passes:
        assert result.get('error'), (name, result)
    print(f'{name}: {"PASS" if passes else "rejected as expected"}')


def main():
    before_pixels, after_pixels = render(), render(320)
    # Literal independently calculated coordinates: marker A and wrapped cyan.
    for x, y, color in [(48, 88, PALETTE[0]), (582, 102, PALETTE[0]),
                        (48, 151, PALETTE[5]), (582, 196, PALETTE[5])]:
        assert tuple(after_pixels[(y * 1040 + x) * 4:(y * 1040 + x) * 4 + 3]) == color
    before, after = png(before_pixels), png(after_pixels)
    baseline = receipt()
    count = 0
    with tempfile.TemporaryDirectory(prefix='resize-oracle-regression-') as temporary:
        directory = pathlib.Path(temporary)
        def case(name, document=baseline, pre=before, post=after, passes=False, alter=None):
            nonlocal count
            run(directory, name, document, pre, post, passes, alter)
            count += 1
        # Exercise all accepted edges/actions with concrete native sizes and
        # independently authored raster coordinates, including min-size clamps.
        for edge in ['left', 'right', 'top', 'bottom', 'top_left', 'top_right', 'bottom_left', 'bottom_right']:
            for action in ['grow', 'shrink', 'clamp']:
                w = {'grow': 480, 'shrink': 320, 'clamp': 260}[action] if 'left' in edge or 'right' in edge else 440
                h = {'grow': 320, 'shrink': 200, 'clamp': 200}[action] if 'top' in edge or 'bottom' in edge else 280
                origin = (470 - w if 'left' in edge else 30, 310 - h if 'top' in edge else 30)
                case(edge + '-' + action, receipt(edge + '-' + action, w, h),
                     post=png(render(w, h, origin)), passes=True)
        case('static alias', receipt('static'), passes=True)
        case('all PNG filters RGB', pre=png(before_pixels, True, 3), post=png(after_pixels, True, 3), passes=True)
        case('all PNG filters RGBA', pre=png(before_pixels, True), post=png(after_pixels, True), passes=True)
        # Literal bounding boxes pin the verifier's decoded output as well as
        # the synthetic input. No verifier helper is imported by this test.
        case('literal pixel bounds', passes=True)
        saved = json.loads((directory / 'independent-pixels.json').read_text())
        features = saved['frames'][1]['features']
        assert features[0]['bounds'] == [48, 88, 62, 102]
        assert features[1]['bounds'] == [581, 101, 603, 123]
        assert features[10]['bounds'] == [48, 150, 69, 172]
        assert features[11]['bounds'] == [581, 195, 614, 227]
        case('stale whole capture', post=before)
        case('stretched old bitmap', post=png(render(320, stretch=True)))
        case('correct markers wrong wrap', post=png(render(320, old_wrap=True)))
        case('wrong world anchor', post=png(render(320, origin=(40, 30))))
        case('image native size disagrees with AX', post=png(render(330)))
        for name, mutate in [
            ('AX CG mismatch', lambda r: r['observations'][1]['cg'].__setitem__(2, 324)),
            ('wrong resize request', lambda r: [r['observations'][1][k].__setitem__(2, 330) for k in ['ax', 'cg']]),
            ('wrong clamp outcome', lambda r: r.__setitem__('scenario', 'right-clamp')),
            ('wrong initial size', lambda r: [r['observations'][0][k].__setitem__(2, 439 - 1) for k in ['ax', 'cg']]),
            ('duplicate phase', lambda r: r['observations'][1].__setitem__('phase', 'before')),
            ('missing phase', lambda r: r['observations'].pop()),
            ('duplicate observation', lambda r: r['observations'].append(r['observations'][0])),
            ('path traversal', lambda r: r['observations'][1].__setitem__('png', '../after.png')),
            ('unknown scenario', lambda r: r.__setitem__('scenario', 'family')),
            ('wrong zoom', lambda r: r.__setitem__('zooms', [.61, .9])),
            ('wrong camera', lambda r: r.__setitem__('camera', [1, 0])),
            ('missing camera', lambda r: r.pop('camera')),
            ('nonfinite frame', lambda r: r['observations'][0]['ax'].__setitem__(0, float('nan'))),
        ]:
            document = copy.deepcopy(baseline)
            mutate(document)
            case(name, document)
        for name, bounds, color in [
            ('viewport leak', (10, 90, 14, 94), PALETTE[0]),
            ('duplicate marker', (400, 400, 405, 405), PALETTE[0]),
            ('missing marker interior', (51, 91, 54, 94), (20, 20, 20)),
            ('clipped marker', (48, 88, 55, 102), (20, 20, 20)),
            ('missing tile', (47, 149, 70, 176), (20, 20, 20)),
            ('oversized tile', (47, 149, 78, 181), PALETTE[5]),
        ]:
            pixels = bytearray(after_pixels)
            paint(pixels, bounds, color)
            case(name, post=png(pixels))
        transparent = bytearray(after_pixels)
        transparent[(91 * 1040 + 51) * 4 + 3] = 128
        case('translucent fiducial', post=png(transparent))
        case('missing PNG', alter=lambda d: (d / 'after.png').unlink())
        case('malformed receipt', alter=lambda d: (d / 'receipt.json').write_text('{'))
        bad_crc = bytearray(after)
        bad_crc[-1] ^= 1
        case('bad CRC', post=bad_crc)
        case('truncated PNG', post=after[:-9])
        case('trailing PNG bytes', post=after + b'extra')
        case('oversized PNG', post=b'x' * (16 * 1024 * 1024 + 1))
        huge_header = struct.pack('>IIBBBBB', 104000, 600, 8, 6, 0, 0, 0)
        case('oversized dimensions', post=after[:8] + chunk(b'IHDR', huge_header) + after[33:])
        header = after[8:33]
        case('invalid row filter', post=after[:8] + header + chunk(b'IDAT', zlib.compress(b'\x05' + bytes(600 * 4161 - 1))) + chunk(b'IEND', b''))
        case('duplicate IHDR', post=after[:8] + header + after[8:])
        case('inflate bomb', post=after[:8] + header + chunk(b'IDAT', zlib.compress(bytes(600 * 4161 + 100))) + chunk(b'IEND', b''))
        case('symlink PNG', alter=lambda d: ((d / 'after.png').unlink(), (d / 'after.png').symlink_to(d / 'before.png')))
    print(f'{count} offline CLI cases passed; no native window behavior was exercised.')


if __name__ == '__main__':
    main()
