// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWDockPayload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/app/CompositorMode/DWNativePresenter.m (37b27b1): describing and submitting frames.
#import "DWNativePresenter+Private.h"
#import "DWGeometryJSON.h"
#import "DWNativeDisplaySpace.h"
#import <AppKit/AppKit.h>

static CGRect DWNativeJSONRect(id value) {
    if(![value isKindOfClass:NSDictionary.class])return CGRectNull;
    NSDictionary *origin=value[@"origin"],*size=value[@"size"];
    if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class])return CGRectNull;
    for(id n in @[origin[@"x"]?:NSNull.null,origin[@"y"]?:NSNull.null,size[@"width"]?:NSNull.null,size[@"height"]?:NSNull.null])if(![n isKindOfClass:NSNumber.class])return CGRectNull;
    CGRect r=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);
    return DWFiniteRect(r)?r:CGRectNull;
}
static BOOL DWNativePlacementSourceMatches(id value,NSDictionary *identity) {
    if(![value isKindOfClass:NSDictionary.class])return NO;
    id owner=value[@"owner"];if(owner&&owner!=NSNull.null)return NO;
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(![value[key]isEqual:identity[key]])return NO;
    return YES;
}
@implementation DWNativePresenter (Frames)
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    atomic_store(&_turned,uptime());
    if(self.ended)return;
    if(![snapshot[@"outputs"]isKindOfClass:NSArray.class]||![snapshot[@"outputs"]count]){[self invalidatePlacementReadiness];_desiredPlacements=@{};_described=NO;return;}
    // One placement per window: where it is shown on several outputs, the one that shows most of it. A transform has one target.
    NSMutableDictionary<NSNumber *,NSDictionary *> *placed=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *shown=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSValue *> *viewports=[NSMutableDictionary dictionary];
    BOOL spaceFrames=_desktopWide&&(_info.caps&DW2_CAP_SPACE);
    NSMutableDictionary<NSNumber *,NSNumber *> *outputSpaces=[NSMutableDictionary dictionary],*windowSpaces=[NSMutableDictionary dictionary];
    for(NSDictionary *output in snapshot[@"outputs"]){CGRect viewport=DWNativeJSONRect(output[@"screen_bounds"]);NSNumber *identifier=output[@"id"];
        if([identifier isKindOfClass:NSNumber.class]&&!CGRectIsNull(viewport)){
            viewports[identifier]=[NSValue valueWithRect:NSRectFromCGRect(viewport)];
            if(spaceFrames)outputSpaces[identifier]=@(DWNativePresentationDisplaySpace(viewport));
        }}
    for(NSDictionary *p in snapshot[@"placements"]){
        NSNumber *logical=p[@"window"];NSDictionary *clip=p[@"clip_rect"][@"size"];if(!logical||!identities[logical])continue;
        double area=[clip[@"width"]doubleValue]*[clip[@"height"]doubleValue];if(placed[logical]&&area<=shown[logical].doubleValue)continue;
        placed[logical]=p;shown[logical]=@(area);
    }
    // Beyond every display, by a translation alone: the window keeps its size and is drawn nowhere. 256 points clear of the far
    // corner of the displays' union, so that neither the window nor its shadow reaches one.
    CGRect all=CGRectNull;CGFloat top=NSMaxY(NSScreen.screens.firstObject.frame);
    for(NSScreen *screen in NSScreen.screens)all=CGRectUnion(all,CGRectMake(screen.frame.origin.x,top-NSMaxY(screen.frame),screen.frame.size.width,screen.frame.size.height));
    if(CGRectIsNull(all)){[self invalidatePlacementReadiness];_desiredPlacements=@{};_described=NO;return;}
    double parkX=ceil(CGRectGetMaxX(all))+256,parkY=ceil(CGRectGetMaxY(all))+256;
    NSMutableDictionary<NSNumber *,NSNumber *> *logicals=[NSMutableDictionary dictionary];
    for(NSNumber *logical in identities){NSNumber *wid=identities[logical][@"wid"];DWNativeWindow *root=_windows[wid];if(!root||root->root!=wid.unsignedIntValue)continue;for(NSNumber *member in _families[wid]?:[NSSet setWithObject:wid])if(_windows[member])logicals[member]=logical;}
    [_records setLength:0];NSMutableArray<NSNumber *> *order=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,DWNativePlacementDescription *> *desired=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSMutableData *> *memberData=[NSMutableDictionary dictionary];
    for(NSNumber *logical in placed){
        NSDictionary *p=placed[logical],*source=[p[@"source"]isKindOfClass:NSDictionary.class]?p[@"source"]:nil;
        uint64_t identifier=0,generation=0,output=0;CGRect screen=DWNativeJSONRect(p[@"screen_rect"]),clip=DWNativeJSONRect(p[@"clip_rect"]);
        NSValue *viewport=viewports[p[@"output"]];DWNativeWindow *root=_windows[identities[logical][@"wid"]];
        if(!root||_withheld[@(root->root)]||!root->familyKnown||![DWNativePlacementIdentity(root->identity)isEqual:identities[logical]]||!DWNativePlacementSourceMatches(source[@"identity"],identities[logical])
            ||![source[@"observation_known"]isEqual:@YES]||!DWNativePlacementInteger(logical,&identifier)
            ||!DWNativePlacementInteger(source[@"generation"],&generation)||!DWNativePlacementInteger(p[@"output"],&output)
            ||!viewport||CGRectIsNull(screen)||CGRectIsNull(clip)||screen.size.width<1||screen.size.height<1)continue;
        DWNativePlacementDescription *description=[DWNativePlacementDescription new];
        description->binding=(DWNativePlacementBinding){.identity=root->identity,.window=identifier,.generation=generation,.output=output,
            .revision=_placementRevision,.screen=screen,.clip=clip,.viewport=NSRectToCGRect(viewport.rectValue)};
        desired[logical]=description;memberData[logical]=[NSMutableData data];
    }
    // An omitted placement still has a controller source binding. Retain a
    // separate kind of ACK correspondence for its complete parked family;
    // never manufacture an output/placement receipt for that backing source.
    for(NSDictionary *row in snapshot[@"windows"]){
        if(![row isKindOfClass:NSDictionary.class])continue;
        NSNumber *logical=row[@"window"];NSDictionary *identity=logical?identities[logical]:nil,*source=[row[@"source"]isKindOfClass:NSDictionary.class]?row[@"source"]:nil;
        DWNativeWindow *root=identity?_windows[identity[@"wid"]]:nil;uint64_t identifier=0,generation=0;
        if(!root||placed[logical]||desired[logical]||root->root!=root->identity.wid||!root->familyKnown||_withheld[@(root->root)]
            ||![DWNativePlacementIdentity(root->identity)isEqual:identity]||!DWNativePlacementSourceMatches(source[@"identity"],identity)
            ||![source[@"observation_known"]isEqual:@YES]||!DWFiniteRect(root->bounds)||!CGRectEqualToRect(DWNativeJSONRect(source[@"observed_rect"]),root->bounds)
            ||!DWNativePlacementInteger(logical,&identifier)||!identifier||!DWNativePlacementInteger(source[@"generation"],&generation)||!generation)continue;
        DWNativePlacementDescription *description=[DWNativePlacementDescription new];description->parked=YES;
        description->binding=(DWNativePlacementBinding){.identity=root->identity,.window=identifier,.generation=generation,.revision=_placementRevision};
        desired[logical]=description;memberData[logical]=[NSMutableData data];
    }
    // In the order of the window numbers: the same scene is then the same bytes, and is not sent twice.
    for(NSNumber *wid in [logicals.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        DWNativeWindow *window=_windows[wid];NSDictionary *p=placed[logicals[wid]];CGSize own=window->bounds.size;
        if(_withheld[@(window->root)]){
            DWNativeHiddenRoot *transition=_transitions[wid];
            if(transition&&[self transitionCurrent:transition]&&(transition->phase==1||transition->phase==2||transition->phase==4||transition->phase==5)){
                [_records appendBytes:&transition->record length:sizeof(transition->record)];[order addObject:logicals[wid]];
            }
            NSData *neutral=_rebases[wid];
            if(neutral&&window->root==wid.unsignedIntValue&&window->familyKnown&&_families[wid].count==1){[_records appendData:neutral];[order addObject:logicals[wid]];}
            continue;
        }
        window->logical=logicals[wid];
        struct dw2_record record={.id=window->identity,.m={1,0,0,1,-parkX,-parkY}};
        NSDictionary *origin=p[@"screen_rect"][@"origin"],*size=p[@"screen_rect"][@"size"];
        double sx=[origin[@"x"]doubleValue],sy=[origin[@"y"]doubleValue],sw=[size[@"width"]doubleValue],sh=[size[@"height"]doubleValue];
        DWNativeWindow *root=_windows[@(window->root)];CGSize rootSize=root?root->bounds.size:own;BOOL nativePlaced=NO;
        if(p&&sw>=1&&sh>=1&&own.width>0&&own.height>0&&rootSize.width>0&&rootSize.height>0){
            // Screen to window-local (DWHelperProtocol.h): the window's own width and height are drawn across the placement's.
            uint64_t targetSpace=spaceFrames?[outputSpaces[p[@"output"]]unsignedLongLongValue]:0;
            double mx=rootSize.width/sw,my=rootSize.height/sh;
            double dx=root?window->bounds.origin.x-root->bounds.origin.x:0,dy=root?window->bounds.origin.y-root->bounds.origin.y:0;
            double m[6]={mx,0,0,my,-sx*mx-dx,-sy*my-dy};
            // Space ownership belongs to the complete audited family. Losing that report must not move a root to another Space while its
            // children are restored; it does not hide the root either: a root that is placed stays placed, and only its Space request waits
            // for the family. Parking it hid the window until the next good audit, and an audit fails whenever a frame is read mid-resize,
            // a member has no readable parent or size, or a Chromium window meets a transient child with no parent or size yet
            // (parked, its main window vanished for 4 to 339 ms of each such read: the browser "flashing"). Context menus are no such
            // member: the guest's audits took every level-101 context menu measured as a child of its root (native/desktop/README.md,
            // "Popups and menus of a transformed window").
            BOOL sound=!spaceFrames||(targetSpace!=0&&root),spaceSound=sound&&(!spaceFrames||root->familyKnown);
            // The helper's bounds on a matrix; a placement they cannot express (a window a million points off, a zoom of a thousandth) is parked.
            for(int i=0;i<6;i++)if(!isfinite(m[i])||fabs(m[i])>1e6)sound=NO;
            if(sound){
                memcpy(record.m,m,sizeof(m));nativePlaced=YES;
                if(targetSpace&&spaceSound)windowSpaces[wid]=@(targetSpace);
                NSValue *viewport=viewports[p[@"output"]];DWNativeClipGeometry geometry={0};
                if(viewport&&root&&DWNativeClipPlacement(window->bounds,root->bounds,CGRectMake(sx,sy,sw,sh),NSRectToCGRect(viewport.rectValue),&geometry)&&geometry.required){
                    NSString *key=[NSString stringWithFormat:@"clip:%d:%llu:%llu:%u",window->identity.pid,(unsigned long long)window->identity.birth_sec,(unsigned long long)window->identity.birth_usec,window->identity.wid];
                    if(![_said containsObject:key]){[_said addObject:key];fprintf(stderr,"Infinify: native window %u of process %d needs display clipping; the helper cannot restore original native regions yet, so its transformed content may extend outside the selected output\n",window->identity.wid,window->identity.pid);}
                }
            }
        }
        // INFINIFY_DEBUG: one line when a window starts or stops being parked, and why, so a window that vanishes is explained.
        if(getenv("INFINIFY_DEBUG")){
            static NSMutableSet *parkedWindows;if(!parkedWindows)parkedWindows=[NSMutableSet set];
            BOOL was=[parkedWindows containsObject:wid];
            if(!nativePlaced&&!was){[parkedWindows addObject:wid];fprintf(stderr,"debug: native park begin wid=%u placement=%d screen=%gx%g own=%gx%g root=%gx%g family_known=%d reason=%s\n",window->identity.wid,p!=nil,sw,sh,own.width,own.height,rootSize.width,rootSize.height,root?root->familyKnown:-1,!p?"no_placement":!(sw>=1&&sh>=1)?"screen_extent":!(own.width>0&&own.height>0&&rootSize.width>0&&rootSize.height>0)?"native_extent":"matrix_or_space");}
            else if(nativePlaced&&was){[parkedWindows removeObject:wid];fprintf(stderr,"debug: native park end wid=%u\n",window->identity.wid);}
        }
        // Alpha is sent for a window from the first frame its opacity is not 1, and from then on always, 1 included: a window whose
        // alpha nobody asked to change is never written, and the helper journals no alpha for it. The one exception is a window the
        // helper's arrival veil holds: the helper lifts that alpha itself with the first frame, and puts it back only while it still reads 0.
        double opacity=[p[@"opacity"]isKindOfClass:NSNumber.class]?fmax(0,fmin(1,[p[@"opacity"]doubleValue])):1;
        if(p&&opacity!=1&&(_info.caps&DW2_CAP_ALPHA))window->alpha=YES;
        if(window->alpha){record.flags=DW2_RECORD_HAS_ALPHA;record.alpha=(float)opacity;}
        DWNativePlacementDescription *description=desired[logicals[wid]];
        if(!nativePlaced&&(!description||!description->parked)){[desired removeObjectForKey:logicals[wid]];[memberData removeObjectForKey:logicals[wid]];description=nil;}
        if(description){DWNativePlacementMember member={.record=record,.targetSpace=[windowSpaces[wid]unsignedLongLongValue],.native=window->bounds,.index=(uint32_t)(_records.length/sizeof(record)),.parent=window->parent};[memberData[logicals[wid]]appendBytes:&member length:sizeof(member)];}
        [_records appendBytes:&record length:sizeof(record)];[order addObject:logicals[wid]];
    }
    for(NSNumber *wid in [_releases.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        DWNativeWindow *window=_releases[wid];struct dw2_record record={.id=window->identity,.flags=DW2_RECORD_RESTORE};
        [_records appendBytes:&record length:sizeof(record)];[order addObject:window->logical?:wid];
    }
    NSMutableData *spaceRequests=[NSMutableData dataWithLength:(_records.length/sizeof(struct dw2_record))*sizeof(uint64_t)];
    const struct dw2_record *described=_records.bytes;uint64_t *spaces=spaceRequests.mutableBytes;
    for(NSUInteger i=0;i<_records.length/sizeof(*described);i++)spaces[i]=[windowSpaces[@(described[i].id.wid)]unsignedLongLongValue];
    _recordSpaces=spaceRequests.copy;
    for(NSNumber *logical in desired){
        DWNativePlacementDescription *description=desired[logical];NSMutableData *data=memberData[logical];
        NSDictionary *placement=placed[logical];
        // Apply the pin policy only after every member has a valid placement.
        // Parking, hidden transitions and ordinary frames omit the bit, asking
        // the helper to restore the journalled sublevel without changing focus.
        if(!description->parked&&[placement[@"pinned"]isEqual:@YES]
            &&(![placement[@"opacity"]isKindOfClass:NSNumber.class]||[placement[@"opacity"]doubleValue]>0)){
            DWNativePlacementMember *members=data.mutableBytes;struct dw2_record *records=_records.mutableBytes;
            for(NSUInteger i=0;i<data.length/sizeof(*members);i++){
                members[i].record.flags|=DW2_RECORD_PINNED;
                records[members[i].index].flags|=DW2_RECORD_PINNED;
            }
        }
        description->members=data.copy;
    }
    if(![_desiredPlacements isEqualToDictionary:desired]){
        [self invalidatePlacementReadiness];_forced=YES;for(DWNativePlacementDescription *description in desired.objectEnumerator)description->binding.revision=_placementRevision;
    }
    _desiredPlacements=desired.copy;_order=order;_described=YES;
}
- (void)submit {
    BOOL retry=_releases.count||atomic_load(&_retrying);
    if(self.ended||!_described||(!_forced&&[_records isEqualToData:_sent]&&[_recordSpaces isEqualToData:_sentSpaces]&&(!retry||uptime()-_lastSent<250)))return;
    NSUInteger count=_records.length/sizeof(struct dw2_record);
    // A frame describes every bound window except an explicitly withheld family,
    // which has no placement receipt. Never truncate the remaining frame.
    if(count>_info.max_records){fprintf(stderr,"Infinify: native presentation ended: %lu windows exceed the helper's frame limit of %u; restoring all windows\n",(unsigned long)count,_info.max_records);[self finish];return;}
    if(!(_info.caps&DW2_CAP_PINNED)){
        const struct dw2_record *records=_records.bytes;
        for(NSUInteger i=0;i<count;i++)if(records[i].flags&DW2_RECORD_PINNED){
            fprintf(stderr,"Infinify: native presentation ended: pinned windows require the helper's journalled sublevel capability; restoring all windows\n");
            [self finish];return;
        }
    }
    BOOL spaceFrames=_desktopWide&&(_info.caps&DW2_CAP_SPACE);
    NSMutableData *extended=nil;
    if(spaceFrames){
        if(_recordSpaces.length!=count*sizeof(uint64_t))return;
        extended=[NSMutableData dataWithLength:count*sizeof(struct dw2_space_record)];
        struct dw2_space_record *out=extended.mutableBytes;const struct dw2_record *in=_records.bytes;const uint64_t *spaces=_recordSpaces.bytes;
        for(NSUInteger i=0;i<count;i++)out[i]=(struct dw2_space_record){.record=in[i],.target_space=spaces[i]};
    }
    uint64_t seq=0;os_unfair_lock_lock(&_lock);
    int result=!_client?DW_CLIENT_LOST:spaceFrames?dw_client_submit_space_frame(_client,extended.bytes,(uint32_t)count,&seq):dw_client_submit_frame(_client,_records.bytes,(uint32_t)count,&seq);
    os_unfair_lock_unlock(&_lock);
    if(result!=DW_CLIENT_OK)return;
    if(spaceFrames){
        const struct dw2_space_record *records=extended.bytes;uint64_t now=uptime();
        for(NSUInteger i=0;i<count;i++){
            const struct dw2_space_record *record=&records[i];if(!record->target_space||record->record.flags&DW2_RECORD_RESTORE)continue;
            NSNumber *wid=@(record->record.id.wid);DWNativeWindow *window=_windows[wid];
            if(!window||window->root!=record->record.id.wid)continue;
            DWNativeSpaceReflow *prior=_spaceReflows[wid];
            if(prior&&!memcmp(&prior->identity,&record->record.id,sizeof(prior->identity))&&prior->target==record->target_space)continue;
            DWNativeSpaceReflow *reflow=[DWNativeSpaceReflow new];reflow->identity=record->record.id;
            reflow->original=prior&&prior->changed&&!memcmp(&prior->identity,&record->record.id,sizeof(prior->identity))?prior->original:window->bounds;
            reflow->before=reflow->observed=window->bounds;reflow->target=record->target_space;reflow->submittedAt=reflow->changedAt=now;
            reflow->changed=prior&&prior->changed;_spaceReflows[wid]=reflow;
        }
    }
    _sent=[_records copy];_sentSpaces=[_recordSpaces copy];_sentOrder=_order;_forced=NO;_lastSent=uptime();_submittedSeq=seq;
    _framePlacements[@(seq)]=_desiredPlacements;_acknowledgedPlacements=@{};_acknowledgedSequence=0;
    if(_releases.count)for(DWNativeWindow *window in _releases.objectEnumerator)if(!window->releaseSeq)window->releaseSeq=seq;
    // A frame the next one replaced is never answered: what is kept is bounded by age.
    _frames[@(seq)]=_sent;for(NSNumber *old in _frames.allKeys)if(old.unsignedLongLongValue+64<seq){[_frames removeObjectForKey:old];[_framePlacements removeObjectForKey:old];}
}
@end
