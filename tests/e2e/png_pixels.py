# SPDX-License-Identifier: GPL-3.0-or-later
"""Decode a saved 8-bit RGBA PNG to rows of bytes, checking every chunk's CRC.

Used by the live tests to inspect the bytes a window or screenshot was saved
with, independently of any framework capture or telemetry.
"""
import struct
import zlib


def decode(path):
    """Return (width, height, channels, rows) of the 8-bit RGB or RGBA PNG at `path`, checking every chunk's CRC.

    Each row is a bytearray of `channels` bytes per pixel. Any other format, interlacing or a bad CRC asserts.
    """
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset = 8
    compressed = []
    header = None
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + size]
        assert offset + 12 + size <= len(data)
        assert zlib.crc32(kind + body) == struct.unpack('>I', data[offset + 8 + size:offset + 12 + size])[0]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        if kind == b'IDAT':
            compressed.append(body)
        offset += size + 12
    assert header is not None
    width, height, depth, color, compression, filtering, interlace = header
    assert (depth, compression, filtering, interlace) == (8, 0, 0, 0) and color in (2, 6)
    channels = 3 if color == 2 else 4
    raw = zlib.decompress(b''.join(compressed))
    stride = width * channels
    assert len(raw) == height * (stride + 1)
    previous = bytearray(stride)
    rows = []
    for y in range(height):
        offset = y * (stride + 1)
        method = raw[offset]
        assert method in range(5)
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            above = previous[x]
            corner = previous[x - channels] if x >= channels else 0
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
    return width, height, channels, rows


def pixels(path, expected_size):
    """Return the rows (bytearrays of R, G, B, A) of the RGBA PNG at `path`, which must be `expected_size` pixels."""
    width, height, channels, rows = decode(path)
    assert (width, height) == expected_size and channels == 4
    return rows
