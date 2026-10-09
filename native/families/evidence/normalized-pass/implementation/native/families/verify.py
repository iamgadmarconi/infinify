#!/usr/bin/env python3
"""Independent saved-PNG checks; no source telemetry is used to generate pixels."""
import json
import pathlib
import struct
import sys
import zlib


def png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, compressed = 8, []
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        kind, payload = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        assert zlib.crc32(kind + payload) == struct.unpack('>I', data[pos + 8 + length:pos + 12 + length])[0]
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            assert depth == 8 and color in (2, 6) and (compression, filtering, interlace) == (0, 0, 0)
        elif kind == b'IDAT':
            compressed.append(payload)
        pos += length + 12
    channels = 4 if color == 6 else 3
    raw = zlib.decompress(b''.join(compressed))
    stride = width * channels
    assert len(raw) == height * (stride + 1)
    previous, rows = bytearray(stride), []
    for y in range(height):
        offset = y * (stride + 1)
        method, row = raw[offset], bytearray(raw[offset + 1:offset + 1 + stride])
        assert method in range(5)
        for x in range(stride):
            a, b, c = (row[x - channels] if x >= channels else 0), previous[x], (previous[x - channels] if x >= channels else 0)
            p = a + b - c
            distances = (abs(p-a), abs(p-b), abs(p-c))
            paeth = (a, b, c)[distances.index(min(distances))]
            row[x] = (row[x] + (0, a, b, (a+b)//2, paeth)[method]) % 256
        rows.append([tuple(row[x:x+3]) for x in range(0, stride, channels)])
        previous = row
    return width, height, rows


def classified(pixel, kind):
    r, g, b = pixel
    return {'parent': r > 180 and g < 80 and b < 80,
            'other-top': g > 180 and r < 150 and b < 100,
            'panel': b > 180 and r < 80 and g < 80,
            'sheet': r > 180 and b > 180 and g < 80,
            'yellow': r > 180 and g > 180 and b < 80,
            'cyan': g > 180 and b > 180 and r < 150}[kind]


def bounds(rows, kind):
    points = [(x,y) for y,row in enumerate(rows) for x,p in enumerate(row) if classified(p,kind)]
    assert points, ('missing marker', kind)
    xs, ys = zip(*points)
    return min(xs), min(ys), max(xs)+1, max(ys)+1


def verify_independent(directory):
    receipt = json.loads((directory/'receipt.json').read_text())
    assert receipt['capture_sequence_completed'], receipt.get('failure')
    assert receipt['source_reaped'] and receipt['source_exit_status'] == 0
    assert receipt['foreground_pid'] == receipt['foreground_after']
    assert all(receipt[k] == 0 for k in ('permission_requests','activation_requests','global_input_posts','source_custom_surface_exports'))
    assert receipt['controls'] == [], 'passive proof must not claim native input'
    assert len(receipt['stages']) == 5
    parent_id, other_id = [w['id'] for w in receipt['stages'][0]['windows']]
    original = {w['id']: w['bounds'] for w in receipt['stages'][0]['windows']}
    checked = 0
    for stage, count in zip(receipt['stages'], (2,3,2,3,2)):
        assert len(stage['windows']) == count
        ids = {w['id'] for w in stage['windows']}
        assert {parent_id,other_id} <= ids
        for w in stage['windows']:
            assert w['identity_verified'] and w['cg_owner'] == receipt['source_pid']
            if w['id'] in original:
                assert w['bounds'] == original[w['id']], 'native top-level moved'
            else:
                assert w['parent'] == parent_id or w['sheet_parent'] == parent_id
        # AX availability is recorded; passive startup cannot substantiate AX parentage.
        phases = {w['kind']: set() for w in stage['windows']}
        for frame in stage['frames']:
            width,height,canvas = png(directory/(frame['name']+'.png'))
            assert (width,height) == (1040,520)
            sources = {}
            for w in stage['windows']:
                sw,sh,pixels = png(directory/(frame['name']+'-'+w['kind']+'.png'))
                assert (sw,sh) == tuple(w['bounds'][2:])
                sources[w['kind']] = bounds(pixels,w['kind'])
                expected_marker=(20,sh-80,100,sh-20)
                assert all(abs(a-b)<=1 for a,b in zip(sources[w['kind']],expected_marker)), ('native surface is grouped/scaled',frame['name'],w['kind'],sources[w['kind']],expected_marker)
                for phase in ('yellow','cyan'):
                    if sum(classified(p,phase) for row in pixels for p in row) > 100:
                        phases[w['kind']].add(phase)
            for view in frame['views']:
                clip = view['clip']; z = view['zoom']; pan = view['pan']
                parent = stage['windows'][0]['bounds']
                for placement in view['placements']:
                    native,dest = placement['native_bounds'], placement['destination']
                    assert placement['frames'] >= 1
                    expected = [clip[0]+(native[0]-parent[0]-pan[0])*z, clip[1]+(native[1]-parent[1]-pan[1])*z, native[2]*z, native[3]*z]
                    assert all(abs(a-b)<1e-6 for a,b in zip(expected,dest))
                    x1,y1,x2,y2 = sources[placement['kind']]
                    # Interior expected marker pixels must retain their source identity,
                    # except where a later real surface overlaps them.
                    later = view['placements'][view['placements'].index(placement)+1:]
                    observed = 0
                    for y in range(max(int(clip[1])+2,int(dest[1]+(y1+3)*z)), min(int(clip[1]+clip[3])-2,int(dest[1]+(y2-3)*z))):
                        for x in range(max(int(clip[0])+2,int(dest[0]+(x1+3)*z)), min(int(clip[0]+clip[2])-2,int(dest[0]+(x2-3)*z))):
                            if any(d[0] <= x < d[0]+d[2] and d[1] <= y < d[1]+d[3] for d in (p['destination'] for p in later)):
                                continue
                            assert classified(canvas[y][x],placement['kind']), ('wrong placement',frame['name'],placement['kind'],x,y,canvas[y][x])
                            observed += 1
                    if placement['kind'] in ('panel','sheet'):
                        assert observed > 100, (frame['name'],placement['kind'],observed)
                checked += 1
            for y,row in enumerate(canvas):
                for x,p in enumerate(row):
                    inside = any(v['clip'][0] <= x < v['clip'][0]+v['clip'][2] and v['clip'][1] <= y < v['clip'][1]+v['clip'][3] for v in frame['views'])
                    if not inside:
                        assert max(p)-min(p) < 3 and max(p) < 30, ('clip leak', x,y,p)
        assert all(p == {'yellow','cyan'} for p in phases.values()), ('not live',stage['name'],phases)
    closed = receipt['closed_streams']
    assert len(closed) == 4 and all(c['frames'] >= 4 and c['stop_completed'] for c in closed)
    assert all(c['cg_absent_after_dismissal'] for c in closed if c['kind'] in ('panel','sheet'))
    return {'saved_pixel_views_checked':checked,'native_family_capture':True,'native_AXPress_create_dismiss':False,'AX_parentage':'not proven; passive startup has no AX server','pointer_keyboard_focus_parity':'untested','third_party_family_discovery':'unproven; fixture identities enrolled explicitly'}


def verify(directory):
    receipt=json.loads((directory/'receipt.json').read_text())
    assert receipt['capture_sequence_completed'],receipt.get('failure')
    assert receipt['source_reaped'] and receipt['source_exit_status']==0
    assert receipt['foreground_pid']==receipt['foreground_after']
    assert receipt['controls']==[]
    assert all(receipt[k]==0 for k in ('permission_requests','activation_requests','global_input_posts','source_custom_surface_exports'))
    independent=True;failure=''
    try:verify_independent(directory)
    except AssertionError as error:independent=False;failure=str(error)
    original={w['id']:w['bounds'] for w in receipt['stages'][0]['windows']}
    checked=0;native_markers=[]
    for stage,count in zip(receipt['stages'],(2,3,2,3,2)):
        assert len(stage['windows'])==count
        for w in stage['windows']:
            assert w['identity_verified'] and w['cg_owner']==receipt['source_pid']
            if w['id'] in original:assert w['bounds']==original[w['id']]
        assert stage['display_stream']['stop_completed'] and not stage['display_stream']['error']
        assert len(stage['display_frames'])==4
        crop=stage['display_native_bounds']
        tested=stage['windows'][-1:] if count==3 else stage['windows']
        phases={w['kind']:set() for w in tested}
        for frame in stage['display_frames']:
            sw,sh,source=png(directory/(frame['name']+'-application.png'))
            assert [sw,sh]==crop[2:]
            for w in tested:
                x,y,ww,hh=w['bounds'];x-=crop[0];y-=crop[1]
                def patch(dx,dy,pw,ph):
                    return [source[yy][xx] for yy in range(int(y+dy),int(y+dy+ph)) for xx in range(int(x+dx),int(x+dx+pw))]
                marker=patch(24,hh-76,72,52)
                assert sum(classified(p,w['kind']) for p in marker)>100,('display native placement',stage['name'],w['kind'])
                for phase in ('yellow','cyan'):
                    if sum(classified(p,phase) for p in patch(114,hh-56,32,32))>100:phases[w['kind']].add(phase)
            cw,ch,canvas=png(directory/(frame['name']+'.png'))
            assert (cw,ch)==(1040,520)
            for view in frame['views']:
                placement=view['placements'][0];dest=placement['destination'];clip=view['clip'];z=view['zoom'];pan=view['pan']
                assert placement['native_bounds']==crop and placement['frames']>=1
                expected=[clip[0]-pan[0]*z,clip[1]-pan[1]*z,sw*z,sh*z]
                assert all(abs(a-b)<1e-6 for a,b in zip(dest,expected))
                matches=0
                # Compare solid interior colored captured pixels with their rendered
                # positions. Skip edges to avoid interpolation differences.
                for sy in range(3,sh-3,3):
                    for sx in range(3,sw-3,3):
                        p=source[sy][sx]
                        if max(p)-min(p)<80:continue
                        if any(max(abs(a-b) for a,b in zip(p,source[sy+dy][sx+dx]))>2 for dx,dy in ((-2,0),(2,0),(0,-2),(0,2))):continue
                        tx,ty=int(dest[0]+(sx+.5)*z),int(dest[1]+(sy+.5)*z)
                        if not (clip[0]+2<=tx<clip[0]+clip[2]-2 and clip[1]+2<=ty<clip[1]+clip[3]-2):continue
                        assert max(abs(a-b) for a,b in zip(p,canvas[ty][tx]))<=6,('display transform',frame['name'],tx,ty,p,canvas[ty][tx])
                        matches+=1
                assert matches>100
                checked+=1
            for y,row in enumerate(canvas):
                for x in (0,19,500,519,520,539,1020,1039):
                    assert max(row[x])-min(row[x])<3 and max(row[x])<30,('clip leak',x,y)
            assert all(max(p)-min(p)<3 and max(p)<30 for y in (0,19,500,519) for p in canvas[y])
        assert all(p=={'yellow','cyan'} for p in phases.values()),('display not live',stage['name'],phases)
        native_markers.append({'stage':stage['name'],'kinds':list(phases)})
    assert len(receipt['stages'])==5
    closed=receipt['closed_streams'];assert len(closed)==4
    assert all(c['frames']>=4 and c['stop_completed'] for c in closed)
    assert all(c['cg_absent_after_dismissal'] for c in closed if c['kind'] in ('panel','sheet'))
    return {'independent_surface_placement':independent,'independent_failure':failure,
            'display_bound_owned_app_pixels':True,'saved_display_pixel_views_checked':checked,
            'native_markers':native_markers,'AX_parentage':'unproved; passive startup has no AX server',
            'native_input_and_focus':'unproved; scheduled genuine AppKit fixture actions only',
            'third_party_discovery':'unproved; owned fixture identities enrolled explicitly',
            'stale_SCWindow_after_dismissal':[c['kind'] for c in closed if c.get('sc_absent_after_dismissal') is False]}


if __name__ == '__main__':
    print(json.dumps(verify(pathlib.Path(sys.argv[1])),indent=2))
