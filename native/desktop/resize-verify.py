#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent saved-byte oracle for the disposable resize probe (no native APIs)."""
import hashlib
import json
import math
import pathlib
import struct
import sys
import zlib

WIDTH, HEIGHT = 1040, 600
ZOOMS = [0.6, 0.9]
COLORS = [(255, 64, 0), (128, 0, 255), (255, 0, 0), (0, 0, 255),
          (0, 255, 0), (0, 255, 255), (255, 0, 255), (255, 255, 0)]
NAMES = ['marker-a', 'marker-b', 'red', 'blue', 'green', 'cyan', 'magenta', 'yellow']
EDGES = {'left', 'right', 'top', 'bottom', 'top_left', 'top_right',
         'bottom_left', 'bottom_right'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_file(directory, name, limit):
    path = directory / name
    require(not path.is_symlink() and path.resolve().parent == directory.resolve(),
            f'unsafe input path: {name}')
    require(path.is_file() and path.stat().st_size <= limit, f'missing/oversized input: {name}')
    return path.read_bytes()


def decode_png(data):
    require(data[:8] == b'\x89PNG\r\n\x1a\n', 'invalid PNG signature')
    offset, header, ended, idat_closed = 8, None, False, False
    compressed = bytearray()
    seen_idat = False
    while offset < len(data):
        require(offset + 12 <= len(data), 'truncated PNG chunk')
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data), 'truncated PNG body')
        body = data[offset + 8:end - 4]
        require(zlib.crc32(kind + body) == struct.unpack_from('>I', data, end - 4)[0],
                'PNG CRC mismatch')
        require(header is not None or kind == b'IHDR', 'IHDR must be first')
        if kind == b'IHDR':
            require(header is None and length == 13, 'invalid/duplicate IHDR')
            header = struct.unpack('>IIBBBBB', body)
            w, h, depth, color, compression, filtering, interlace = header
            require((w, h, depth, compression, filtering, interlace) ==
                    (WIDTH, HEIGHT, 8, 0, 0, 0) and color in (2, 6),
                    'expected 1040x600, noninterlaced 8-bit RGB/RGBA PNG')
        elif kind == b'IDAT':
            require(not idat_closed, 'noncontiguous IDAT')
            seen_idat = True
            compressed.extend(body)
        elif kind == b'IEND':
            require(length == 0 and seen_idat and end == len(data), 'invalid PNG ending')
            ended = True
        else:
            require(kind[0] & 32 or kind == b'PLTE', 'unsupported critical PNG chunk')
            if seen_idat:
                idat_closed = True
        offset = end
    require(ended and header is not None, 'missing PNG ending')
    channels = 4 if header[3] == 6 else 3
    stride = WIDTH * channels
    expected = HEIGHT * (stride + 1)
    inflater = zlib.decompressobj()
    raw = inflater.decompress(compressed, expected + 1)
    require(len(raw) == expected and inflater.eof and not inflater.unused_data
            and not inflater.unconsumed_tail, 'invalid/oversized PNG inflation')
    rows, previous = [], bytearray(stride)
    for y in range(HEIGHT):
        start = y * (stride + 1)
        method = raw[start]
        require(method <= 4, 'invalid PNG row filter')
        row = bytearray(raw[start + 1:start + 1 + stride])
        if method:
            for x in range(stride):
                left = row[x - channels] if x >= channels else 0
                above = previous[x]
                corner = previous[x - channels] if x >= channels else 0
                if method == 1:
                    predictor = left
                elif method == 2:
                    predictor = above
                elif method == 3:
                    predictor = (left + above) // 2
                else:
                    p = left + above - corner
                    dl, da, dc = abs(p - left), abs(p - above), abs(p - corner)
                    predictor = left if dl <= da and dl <= dc else above if da <= dc else corner
                row[x] = (row[x] + predictor) & 255
        rows.append(row)
        previous = row
    return rows, channels


def frame(value):
    require(isinstance(value, list) and len(value) == 4 and
            all(type(v) in (int, float) and math.isfinite(v) for v in value),
            'invalid AX/CG frame')
    require(value[2] > 0 and value[3] > 0, 'nonpositive AX/CG size')
    return value


def geometry(receipt):
    require(receipt.get('zooms') == ZOOMS and receipt.get('camera') == [0, 0],
            'camera/zoom configuration mismatch')
    scenario = receipt.get('scenario')
    require(isinstance(scenario, str), 'missing scenario')
    if scenario == 'static':
        scenario = 'right-shrink'
    pieces = scenario.rsplit('-', 1)
    require(len(pieces) == 2 and pieces[0] in EDGES and
            pieces[1] in ('grow', 'shrink', 'clamp'), 'unknown scenario')
    edge, action = pieces
    observations = receipt.get('observations')
    require(isinstance(observations, list) and len(observations) == 2 and
            all(isinstance(o, dict) for o in observations), 'expected two observations')
    require(sorted(o.get('phase', '') for o in observations) == ['after', 'before'],
            'missing/duplicate observation phase')
    phases = {o['phase']: o for o in observations}
    for phase, observation in phases.items():
        require(observation.get('png') == phase + '.png', 'unsafe/mismatched PNG observation')
        ax, cg = frame(observation.get('ax')), frame(observation.get('cg'))
        require(all(abs(a - b) <= 1 for a, b in zip(ax, cg)), 'AX/CG disagreement')
    before = phases['before']['ax']
    after = phases['after']['ax']
    require(abs(before[2] - 440) <= 1 and abs(before[3] - 280) <= 1,
            'wrong initial native size')
    horizontal = 'left' in edge or 'right' in edge
    vertical = 'top' in edge or 'bottom' in edge
    delta = {'grow': 40, 'shrink': -120}[action] if action != 'clamp' else None
    w = max(260, min(500, 100 if delta is None else 440 + delta)) if horizontal else 440
    h = max(200, min(360, 100 if delta is None else 280 + delta)) if vertical else 280
    # Native origin may move during AX resize. World anchoring is checked
    # independently in saved pixels; AX and CG must still agree on origin.
    desired = [w, h]
    require(all(abs(a - b) <= 1 for a, b in zip(after[2:], desired)),
            f'wrong resize/clamp geometry: expected {desired}, got {after[2:]}')
    return edge, phases


def rectangles(edge, observation, phase):
    w, h = observation['ax'][2:]
    origin = (30 + (440 - w if phase == 'after' and 'left' in edge else 0),
              30 + (280 - h if phase == 'after' and 'top' in edge else 0))
    columns = 6 if w >= 400 else 3
    native = [(16, 16, 24, 24), (w - 40, h - 40, 24, 24)]
    native += [(16 + (i % columns) * 56, 64 + (i // columns) * 56, 36, 36)
               for i in range(6)]
    views = []
    for view, zoom in enumerate(ZOOMS):
        vx, vy = 20 + view * 520, 60
        bounds = []
        for x, y, width, height in native:
            left, top = vx + (origin[0] + x) * zoom, vy + (origin[1] + y) * zoom
            bounds.append((max(vx, left), max(vy, top),
                           min(vx + 480, left + width * zoom),
                           min(vy + 500, top + height * zoom)))
        views.append(bounds)
    return views


def color_masks(rows, channels):
    # Disjoint +/-24 sRGB boxes: marker orange cannot be mistaken for red,
    # marker purple cannot be mistaken for blue/magenta. No area-only scoring.
    masks = [set() for _ in COLORS]
    cache = {}
    for y, row in enumerate(rows):
        for x in range(WIDTH):
            offset = x * channels
            rgb = bytes(row[offset:offset + 3])
            if rgb not in cache:
                cache[rgb] = next((i for i, target in enumerate(COLORS)
                                   if all(abs(a - b) <= 24 for a, b in zip(rgb, target))), None)
            match = cache[rgb]
            if match is not None:
                require(channels == 3 or row[offset + 3] == 255,
                        'nonopaque fiducial pixel')
                masks[match].add(y * WIDTH + x)
    return masks


def components(mask):
    remaining, result = set(mask), []
    while remaining:
        seed = remaining.pop()
        found, pending = {seed}, [seed]
        while pending:
            p = pending.pop()
            x, y = p % WIDTH, p // WIDTH
            adjacent = []
            if x: adjacent.append(p - 1)
            if x + 1 < WIDTH: adjacent.append(p + 1)
            if y: adjacent.append(p - WIDTH)
            if y + 1 < HEIGHT: adjacent.append(p + WIDTH)
            for q in adjacent:
                if q in remaining:
                    remaining.remove(q)
                    found.add(q)
                    pending.append(q)
        result.append(found)
    return result


def inspect(rows, channels, expected):
    report = []
    for i, mask in enumerate(color_masks(rows, channels)):
        groups = sorted(components(mask), key=lambda g: min(p % WIDTH for p in g))
        require(len(groups) == 2, f'{NAMES[i]}: expected exactly two components, got {len(groups)}')
        for view, points in enumerate(groups):
            left, top, right, bottom = expected[view][i]
            require(right > left and bottom > top, 'unexpected fully clipped fixture feature')
            xs, ys = [p % WIDTH for p in points], [p // WIDTH for p in points]
            actual = (min(xs), min(ys), max(xs) + 1, max(ys) + 1)
            require(all(abs(a - b) <= 1.01 for a, b in zip(actual, (left, top, right, bottom))),
                    f'{NAMES[i]} view {view}: pixel bounds {actual}, expected {(left, top, right, bottom)}')
            vx = 20 + 520 * view
            require(all(vx <= x < vx + 480 and 60 <= y < 560 for x, y in zip(xs, ys)),
                    f'{NAMES[i]}: leaked viewport pixels')
            # Require every interior pixel. A correct bounding box with holes,
            # a thin outline, or stretched/rearranged features is insufficient.
            for y in range(math.ceil(top + 1), math.floor(bottom - 1)):
                for x in range(math.ceil(left + 1), math.floor(right - 1)):
                    require(y * WIDTH + x in points, f'{NAMES[i]} view {view}: missing interior pixel')
            report.append({'feature': NAMES[i], 'view': view, 'bounds': actual,
                           'pixels': len(points)})
    return report


def verify(directory):
    receipt = json.loads(safe_file(directory, 'receipt.json', 1024 * 1024))
    require(isinstance(receipt, dict), 'receipt must be an object')
    edge, phases = geometry(receipt)
    result = []
    hashes = []
    for phase in ('before', 'after'):
        data = safe_file(directory, phase + '.png', 16 * 1024 * 1024)
        digest = hashlib.sha256(data).hexdigest()
        hashes.append(digest)
        rows, channels = decode_png(data)
        result.append({'phase': phase, 'sha256': digest,
                       'features': inspect(rows, channels, rectangles(edge, phases[phase], phase))})
    require(hashes[0] != hashes[1], 'stale whole PNG')
    return result


def main():
    if len(sys.argv) != 2:
        print('usage: resize-verify.py RUN_DIRECTORY', file=sys.stderr)
        return 2
    directory = pathlib.Path(sys.argv[1])
    output = {'passed': False, 'method': 'independent saved PNG CRC/inflate/filter/connected-component geometry',
              'scope': 'saved pixels and declared AX/CG measurements; not standalone native proof'}
    try:
        output['frames'] = verify(directory)
        output['passed'] = True
    except (ValueError, OSError, TypeError, KeyError, zlib.error, struct.error) as error:
        output['error'] = str(error)
    try:
        path = directory / 'independent-pixels.json'
        require(not path.is_symlink(), 'unsafe output symlink')
        path.write_text(json.dumps(output, indent=2) + '\n')
    except (ValueError, OSError) as error:
        output['passed'] = False
        output['error'] = f'cannot write independent receipt: {error}'
    print(json.dumps(output))
    return 0 if output['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
