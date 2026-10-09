#!/usr/bin/env python3
"""Independently inspect saved PNG bytes, without framework capture/telemetry."""
import json
import pathlib
import struct
import sys
import zlib


def pixels(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset = 8
    compressed = []
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + size]
        assert zlib.crc32(kind + body) == struct.unpack('>I', data[offset + 8 + size:offset + 12 + size])[0]
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', body)
            assert (width, height, depth, color, compression, filtering, interlace) == (1040, 600, 8, 6, 0, 0, 0)
        if kind == b'IDAT':
            compressed.append(body)
        offset += size + 12
    raw = zlib.decompress(b''.join(compressed))
    stride = width * 4
    assert len(raw) == height * (stride + 1)
    previous = bytearray(stride)
    rows = []
    for y in range(height):
        offset = y * (stride + 1)
        method = raw[offset]
        assert method in range(5)
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            above = previous[x]
            corner = previous[x - 4] if x >= 4 else 0
            predictor = 0
            if method == 1:
                predictor = left
            elif method == 2:
                predictor = above
            elif method == 3:
                predictor = (left + above) // 2
            elif method == 4:
                p = left + above - corner
                dl, da, dc = abs(p - left), abs(p - above), abs(p - corner)
                predictor = left if dl <= da and dl <= dc else above if da <= dc else corner
            row[x] = (row[x] + predictor) & 255
        rows.append(row)
        previous = row
    return rows


def verify(directory):
    phases = [set(), set()]
    results = []
    files = sorted(directory.glob('frame-*.png'))
    assert len(files) == 6
    for path in files:
        rows = pixels(path)
        observed = []
        views = []
        for i in range(2):
            green = []
            red = blue = outside = 0
            for y, row in enumerate(rows):
                for x in range(i * 520, (i + 1) * 520):
                    r, g, b, alpha = row[x * 4:x * 4 + 4]
                    # Saved PNG retains its native color profile. Broad disjoint
                    # masks identify the saturated fiducials in these bytes.
                    is_green = g > 180 and r < 180 and b < 140
                    is_red = r > 180 and g < 120 and b < 100
                    is_blue = b > 180 and r < 80 and g < 80
                    if is_green:
                        green.append((x, y))
                    red += is_red
                    blue += is_blue
                    if is_green or is_red or is_blue:
                        assert alpha == 255
                        outside += not (20 + i * 520 <= x < 500 + i * 520 and 60 <= y < 560)
            assert green and outside == 0
            bounds = [min(p[0] for p in green), min(p[1] for p in green),
                      max(p[0] for p in green) - min(p[0] for p in green) + 1,
                      max(p[1] for p in green) - min(p[1] for p in green) + 1]
            assert bounds == ([244, 148, 32, 32], [792, 168, 48, 48])[i], (path, bounds)
            phase = 'red' if red > (5600, 10600)[i] and blue == 0 else 'blue' if blue > (5900, 10600)[i] and red == 0 else None
            assert phase, (path, red, blue)
            phases[i].add(phase)
            observed.append(phase)
            views.append({'marker_bounds': bounds, 'green_pixels': len(green), 'red_pixels': red,
                          'blue_pixels': blue, 'outside_clip': outside})
        assert observed[0] == observed[1], (path, observed)
        results.append({'file': path.name, 'views': views})
    assert phases == [{'red', 'blue'}, {'red', 'blue'}]
    receipt = {'passed': True, 'method': 'independent saved PNG CRC/inflate/filter/coordinate inspection', 'frames': results}
    (directory / 'independent-pixels.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'passed': True, 'directory': str(directory), 'saved_pngs': len(files)}))


if __name__ == '__main__':
    verify(pathlib.Path(sys.argv[1]))
