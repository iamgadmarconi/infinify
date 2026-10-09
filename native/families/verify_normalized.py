#!/usr/bin/env python3
"""Verify real saved SCK family pixels against independently recorded CG geometry.

Fixture rectangles define test expectations, never the compositor's mapping.
"""
import json
import math
import pathlib
import sys
from verify import png


def color(pixel, kind):
    r,g,b=pixel
    # AppKit's modal sheet dims its parent; retain the hue test at lower brightness.
    return {'parent':r>60 and g<r*.45 and b<r*.45,
            'other-top':g>150 and r<g*.65 and b<g*.5,
            'panel':b>150 and r<b*.45 and g<b*.45,
            'sheet':r>150 and b>150 and g<min(r,b)*.45,
            'yellow':r>60 and g>60 and b<min(r,g)*.6,
            'cyan':g>60 and b>60 and r<min(g,b)*.6}[kind]


def rectangle(value):
    return [value[k] for k in ('X','Y','Width','Height')]


def near(actual,expected,tolerance=1):
    assert len(actual)==len(expected) and all(abs(a-b)<=tolerance for a,b in zip(actual,expected)),(actual,expected)


def union(rects):
    x=min(r[0] for r in rects);y=min(r[1] for r in rects)
    return [x,y,max(r[0]+r[2] for r in rects)-x,max(r[1]+r[3] for r in rects)-y]


def bounds(rows,kind):
    xs=[];ys=[]
    for y,row in enumerate(rows):
        for x,pixel in enumerate(row):
            if color(pixel,kind):xs.append(x);ys.append(y)
    assert xs,('no actual native marker',kind)
    return [min(xs),min(ys),max(xs)+1-min(xs),max(ys)+1-min(ys)]


def world_from_pixels(marker,normalization):
    native=normalization['native_extent'];pixel=normalization['pixel_rect']
    return [native[0]+(marker[0]-pixel[0])*native[2]/pixel[2],
            native[1]+(marker[1]-pixel[1])*native[3]/pixel[3],
            marker[2]*native[2]/pixel[2],marker[3]*native[3]/pixel[3]]


def verify(directory):
    receipt=json.loads((directory/'receipt.json').read_text())
    assert receipt['capture_sequence_completed'],receipt.get('failure')
    assert receipt['source_reaped'] and receipt['source_exit_status']==0
    assert receipt['foreground_pid']==receipt['foreground_after']
    assert receipt['controls']==[]
    assert all(receipt[k]==0 for k in ('permission_requests','activation_requests','global_input_posts','source_custom_surface_exports'))
    assert [s['name'] for s in receipt['stages']]==['baseline','panel','panel-dismissed','sheet','sheet-dismissed','left-up-panel','left-up-dismissed']
    roots=receipt['stages'][0]['windows'];assert len(roots)==2
    root_ids=[r['id'] for r in roots];original={r['id']:r['cg_bounds'] for r in roots}
    camera_origin=roots[0]['cg_bounds'][:2];view_checks=0;native_checks=[];clipped=set()
    for stage,expected_count in zip(receipt['stages'],(2,3,2,3,2,3,2)):
        windows=stage['windows'];assert len(windows)==expected_count
        for w in windows:
            assert w['identity_verified'] and w['cg_owner']==receipt['source_pid']
            near(w['sc_bounds'],w['cg_bounds'],0)
            if w['id'] in original:near(w['cg_bounds'],original[w['id']],0)
        family_members=[w for w in windows if w['id']!=root_ids[1]]
        expected_extent=union([w['cg_bounds'] for w in family_members])
        assert len(stage['frames'])==4
        phases={w['kind']:set() for w in windows};last_native={}
        for frame in stage['frames']:
            cw,ch,canvas=png(directory/(frame['name']+'.png'));assert (cw,ch)==(1040,520)
            placements=frame['views'][0]['placements']
            assert [p['id'] for p in placements]==root_ids, 'child captured/drawn separately or unrelated root missing'
            for placement,members,extent in ((placements[0],family_members,expected_extent),(placements[1],[windows[1]],windows[1]['cg_bounds'])):
                n=placement['normalization'];assert n['valid']
                near(n['native_extent'],extent)
                metadata=placement['stream_metadata'];screen=rectangle(metadata['SCStreamUpdateFrameScreenRect'])
                content=rectangle(metadata['SCStreamUpdateFrameContentRect'])
                scale=metadata['SCStreamUpdateFrameDisplayResolution'];cs=metadata['SCStreamUpdateFrameContentScale']
                family=n['native_family'];assert family['valid']
                assert family['root']==placement['id'] and family['pid']==receipt['source_pid']
                assert family['process_birth']==receipt['source_final']['birth']
                expected_ids={w['id'] for w in members}
                assert {m['id'] for m in family['members']}==expected_ids
                assert set(family['associated_ids'])-{placement['id']}==expected_ids-{placement['id']}
                assert family['root_query']['valid'] and family['root_query']['parent_id']==0
                for member in family['members']:
                    oracle=next(w for w in members if w['id']==member['id'])
                    assert member['valid'] and member['iterator_count']==1 and member['iterator_id']==member['id']
                    assert member['cg_owner']==receipt['source_pid']
                    near(member['cg_bounds'],oracle['cg_bounds'],0)
                    assert member['parent_id']==(oracle['parent'] or oracle['sheet_parent']),('private parent differs from AppKit oracle',member,oracle)
                near(family['native_bounds'],extent,0)
                near(n['native_extent'],family['native_bounds'][:2]+[content[2]/cs,content[3]/cs],1e-6);near(n['pixel_rect'],[v*scale for v in content],1e-6)
                near(n['screen_rect'],screen,0)
                assert math.isclose(n['pixel_to_native_scale'],1/(scale*cs),rel_tol=1e-8)
                sw,sh,source=png(directory/(frame['name']+'-'+placement['kind']+'.png'))
                assert [sw,sh]==n['buffer_size']
                initial=placement['filter_metadata'];near([sw,sh],[math.ceil(initial['content_rect'][2]*initial['point_pixel_scale']),math.ceil(initial['content_rect'][3]*initial['point_pixel_scale'])],0)
                for w in members:
                    marker=bounds(source,w['kind']);native=world_from_pixels(marker,n)
                    x,y,width,height=w['cg_bounds'];expected=[x+20,y+height-80,80,60]
                    near(native,expected,2)
                    last_native[w['kind']]=native
                    # The native dynamic patch is at x=110,y=height-60. Sample its
                    # interior via API metadata, independently of camera rendering.
                    world=[x+115,y+height-55,30,30];nr=n['native_extent'];pr=n['pixel_rect']
                    px=int(pr[0]+(world[0]-nr[0])*pr[2]/nr[2]);py=int(pr[1]+(world[1]-nr[1])*pr[3]/nr[3])
                    pw=max(1,int(world[2]*pr[2]/nr[2]));ph=max(1,int(world[3]*pr[3]/nr[3]))
                    patch=[]
                    occluders=[other['cg_bounds'] for other in members[members.index(w)+1:]]
                    for yy in range(py,py+ph):
                        for xx in range(px,px+pw):
                            wx=nr[0]+(xx-pr[0])*nr[2]/pr[2];wy=nr[1]+(yy-pr[1])*nr[3]/pr[3]
                            if not any(r[0]<=wx<r[0]+r[2] and r[1]<=wy<r[1]+r[3] for r in occluders):patch.append(source[yy][xx])
                    for phase in ('yellow','cyan'):
                        if patch and sum(color(p,phase) for p in patch)>len(patch)*.8:phases[w['kind']].add(phase)
            for view in frame['views']:
                clip=view['clip'];z=view['zoom'];pan=view['pan'];assert len(view['placements'])==2
                for placement in view['placements']:
                    extent=placement['normalization']['native_extent'];dest=placement['destination']
                    near(dest,[clip[0]+(extent[0]-camera_origin[0]-pan[0])*z,clip[1]+(extent[1]-camera_origin[1]-pan[1])*z,extent[2]*z,extent[3]*z],1e-6)
                # Every colored native identity occurs exactly once in each viewport,
                # at its expected world bounds, including partial clipping.
                for w in windows:
                    x,y,width,height=w['cg_bounds'];marker=[clip[0]+(x+20-camera_origin[0]-pan[0])*z,clip[1]+(y+height-80-camera_origin[1]-pan[1])*z,80*z,60*z]
                    left=max(marker[0],clip[0]);top=max(marker[1],clip[1]);right=min(marker[0]+marker[2],clip[0]+clip[2]);bottom=min(marker[1]+marker[3],clip[1]+clip[3])
                    for edge,condition in (('left',marker[0]<clip[0]),('top',marker[1]<clip[1]),('right',marker[0]+marker[2]>clip[0]+clip[2]),('bottom',marker[1]+marker[3]>clip[1]+clip[3])):
                        if condition:clipped.add(edge)
                    assert right-left>10 and bottom-top>10,(stage['name'],w['kind'],'fixture marker not visible in both views')
                    region=[row[int(clip[0]):int(clip[0]+clip[2])] for row in canvas[int(clip[1]):int(clip[1]+clip[3])]]
                    actual=bounds(region,w['kind']);actual[0]+=clip[0];actual[1]+=clip[1]
                    near(actual,[left,top,right-left,bottom-top],2)
                    for yy in range(math.ceil(top)+2,math.floor(bottom)-2):
                        for xx in range(math.ceil(left)+2,math.floor(right)-2):
                            wx=(xx-clip[0])/z+camera_origin[0]+pan[0];wy=(yy-clip[1])/z+camera_origin[1]+pan[1]
                            if any(r[0]<=wx<r[0]+r[2] and r[1]<=wy<r[1]+r[3] for r in (other['cg_bounds'] for other in windows[windows.index(w)+1:])):continue
                            assert color(canvas[yy][xx],w['kind']),('native content misplaced',frame['name'],w['kind'],xx,yy)
                for absent in {'panel','sheet'}-{w['kind'] for w in windows}:
                    assert not any(color(p,absent) for row in canvas[int(clip[1]):int(clip[1]+clip[3])] for p in row[int(clip[0]):int(clip[0]+clip[2])]),('stale transient',stage['name'],absent)
                view_checks+=1
            for y,row in enumerate(canvas):
                for x,p in enumerate(row):
                    if not any(v['clip'][0]<=x<v['clip'][0]+v['clip'][2] and v['clip'][1]<=y<v['clip'][1]+v['clip'][3] for v in frame['views']):
                        assert max(p)-min(p)<3 and max(p)<30,('clip leak',x,y,p)
        assert all(p=={'yellow','cyan'} for p in phases.values()),('not live',stage['name'],phases)
        native_checks.append({'stage':stage['name'],'family_extent':expected_extent,'native_marker_bounds':last_native})
    assert {'left','top','bottom'}<=clipped,clipped
    # The unrelated root extends through the right clip even when its marker ends
    # exactly on that edge; its per-frame native placement and outside pixels are checked.
    assert any(p['destination'][0]+p['destination'][2]>v['clip'][0]+v['clip'][2] for v in receipt['stages'][0]['frames'][0]['views'] for p in v['placements'])
    clipped.add('right')
    closed=receipt['closed_streams'];assert len(closed)==2
    assert {c['id'] for c in closed}==set(root_ids)
    assert all(c['frames']>=10 and c['stop_completed'] and not c['error'] for c in closed)
    dismissed=[d for s in receipt['stages'] for d in s['dismissed']]
    assert len(dismissed)==3 and all(d['cg_absent'] for d in dismissed)
    return {'normalized_owned_family_pixels':True,'verified_clip_edges':sorted(clipped),'saved_pixel_views_checked':view_checks,
            'native_geometry_checks':native_checks,'root_stream_count':2,'child_stream_count':0,
            'native_input_focus':'unproved; scheduled genuine AppKit setup only',
            'owned_WindowServer_parentage':True,'native_origin_from_verified_parent_associations':True,
            'left_up_extension':True,'production_scope':'only explicitly enrolled disposable process; arbitrary third-party apps unproved',
            'stale_SCWindow_after_dismissal':[d['kind'] for d in dismissed if d['sc_still_enumerated']]}


if __name__=='__main__':
    print(json.dumps(verify(pathlib.Path(sys.argv[1])),indent=2))
