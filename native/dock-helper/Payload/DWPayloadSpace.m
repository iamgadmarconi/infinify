// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation. Private ABI declarations cross-checked against
// yabai (MIT), https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/osax/payload.m; its notice is native/app/Resources/YABAI-NOTICE.txt.
// The arrival veil (v2Veil below) adapts an idea and a technique of Sunlight,
// https://github.com/spacefarm-digital/sunlight commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm): that a window an
// application opens must not be seen at its native place before the canvas has placed it
// (LiveWindows/README.md:129 and LiveWindows/osax/sunbeam.h:40-51, which keep the canvas and its
// windows one window level up), and the window server's own announcement of it, SkyLight
// connection notification 1325 with the Space id (u64) then the window id (u32) as payload,
// registered with SLSRegisterConnectionNotifyProc (Sources/Canvas/RealWindows/WindowServerEvents.swift:4-15,
// 36-55 and 73-85). The level lift is not taken: here the window is held at alpha 0 instead.
// Private ABI declarations below are cross-checked against yabai (MIT),
// https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd; its notice is native/app/Resources/YABAI-NOTICE.txt.
// Space membership: reads, forward-move eligibility, confirmation of void move requests, deleted-target evidence, and restoration
// to the original Space with its settling.
// Moved verbatim from native/privileged/payload.m (37b27b1), lines 288-318, 523-642. #imported by DWPayload.m in a fixed order; never compiled alone.
// Edited since the move: the settlement sample compares the layer.

static uint64_t v2WindowSpace(uint32_t wid) {
    if(!v2SpaceAPI())return 0;
    CFArrayRef raw=copyWindowSpaces(mainConnection(),7,(__bridge CFArrayRef)@[@(wid)]);
    if(!raw)return 0;uint64_t result=0;
    if(CFGetTypeID(raw)==CFArrayGetTypeID()&&CFArrayGetCount(raw)==1){
        id value=(__bridge id)CFArrayGetValueAtIndex(raw,0);
        if(isNumber(value)&&!CFNumberIsFloatType((__bridge CFNumberRef)value)&&[value compare:@0]==NSOrderedDescending)result=[value unsignedLongLongValue];
    }
    CFRelease(raw);return result;
}
// Targets must be the current ordinary Space of an active, awake display.
// Restoration only requires the original ordinary Space/display still exists;
// it must not substitute a different current Space when the original is hidden.
static NSString *v2SpaceDisplay(uint64_t space,BOOL target) {
    if(!space||!v2SpaceAPI()||getSpaceType(mainConnection(),space)!=0)return nil;
    CFStringRef raw=copySpaceDisplay(mainConnection(),space);
    if(!raw)return nil;
    if(CFGetTypeID(raw)!=CFStringGetTypeID()){CFRelease(raw);return nil;}
    NSString *uuid=CFBridgingRelease(raw);if(!uuid.length)return nil;
    if(!target)return uuid;
    CGDirectDisplayID displays[32];uint32_t count=0;
    if(CGGetActiveDisplayList(32,displays,&count)||!count||count>32)return nil;
    for(uint32_t i=0;i<count;i++) {
        CGDirectDisplayID display=displays[i];
        if(!CGDisplayIsOnline(display)||CGDisplayIsAsleep(display)||CGDisplayMirrorsDisplay(display))continue;
        CFUUIDRef id=createDisplayUUID(display);if(!id)continue;
        NSString *candidate=CFBridgingRelease(CFUUIDCreateString(NULL,id));CFRelease(id);
        if([uuid isEqual:candidate]&&displayCurrentSpace(mainConnection(),(__bridge CFStringRef)uuid)==space)return uuid;
    }
    return nil;
}
static BOOL v2CanMoveSpace(uint32_t wid,uint64_t target,uint64_t *source,NSString **display) {
    NSString *targetDisplay=v2SpaceDisplay(target,YES);
    uint64_t current=v2WindowSpace(wid);NSString *sourceDisplay=v2SpaceDisplay(current,YES);
    if(!targetDisplay||!sourceDisplay||(current!=target&&[sourceDisplay isEqual:targetDisplay]))return NO;
    if(source)*source=current;if(display)*display=sourceDisplay;return YES;
}
// Confirm an earlier void request before allowing any replacement request.
// A failed durability fence keeps the old pending target in memory and on retry.
static uint8_t v2ConfirmSpace(DW2Entry *e) {
    if(!e->pendingSpace)return DW2_APPLIED;
    if(!v2EntryCurrent(e))return DW2_IDENTITY;
    if(!e->pendingSpaceObserved) {
        if(v2WindowSpace(e->who.wid)!=e->pendingSpace)return DW2_NOT_APPLIED;
    }
    if(!v2EntryCurrent(e))return DW2_IDENTITY;
    e->pendingSpaceObserved=YES;
    uint64_t pending=e->pendingSpace;e->pendingSpace=0;
    if(!v2Persist()){e->pendingSpace=pending;v2JournalStale=YES;return DW2_JOURNAL;}
    e->pendingSpaceObserved=NO;
    return DW2_APPLIED;
}
static void v2ForgetUnsentSpace(DW2Entry *e) {
    if(!e->pendingSpaceFresh)return;
    uint64_t pending=e->pendingSpace,original=e->originalSpace;NSString *display=e->originalSpaceDisplay;
    e->pendingSpace=0;
    if(e->spaceFresh){e->originalSpace=0;e->originalSpaceDisplay=nil;}
    if(!v2Persist()){e->pendingSpace=pending;e->originalSpace=original;e->originalSpaceDisplay=display;v2JournalStale=YES;}
    e->pendingSpaceFresh=e->spaceFresh=NO;
}
// A removed display may destroy an unobserved forward target and return its
// windows to the original Space. A failed per-Space getter is not deletion
// evidence: require a complete, valid inventory with the original on its saved
// display and the pending target absent, including every current active display.
static BOOL v2PendingSpaceDeleted(DW2Entry *e) {
    if(!v2CopyManagedSpaces&&!v2ManagedSpacesResolved){
        v2ManagedSpacesResolved=YES;
        void *sky=v2Sky();
        if(sky)v2CopyManagedSpaces=dlsym(sky,"SLSCopyManagedDisplaySpaces");
    }
    if(!v2CopyManagedSpaces)return NO;
    CFArrayRef raw=v2CopyManagedSpaces(mainConnection());if(!raw)return NO;
    BOOL valid=CFGetTypeID(raw)==CFArrayGetTypeID()&&CFArrayGetCount(raw)>0&&CFArrayGetCount(raw)<=32;
    NSMutableSet *displays=[NSMutableSet set],*spaces=[NSMutableSet set];BOOL originalFound=NO;
    if(valid)for(id row in (__bridge NSArray *)raw){
        id display=[row isKindOfClass:NSDictionary.class]?row[@"Display Identifier"]:nil;
        id list=[row isKindOfClass:NSDictionary.class]?row[@"Spaces"]:nil;
        if(![display isKindOfClass:NSString.class]||![[NSUUID alloc]initWithUUIDString:display]
            ||[displays containsObject:display]||![list isKindOfClass:NSArray.class]||![list count]||[list count]>1024){valid=NO;break;}
        [displays addObject:display];
        for(id item in list){
            id value=[item isKindOfClass:NSDictionary.class]?item[@"id64"]:nil;
            if(!isNumber(value)||CFNumberIsFloatType((__bridge CFNumberRef)value)||[value compare:@0]!=NSOrderedDescending
                ||[spaces containsObject:value]){valid=NO;break;}
            [spaces addObject:value];
            if([value unsignedLongLongValue]==e->originalSpace&&[display isEqual:e->originalSpaceDisplay])originalFound=YES;
        }
        if(!valid)break;
    }
    CFRelease(raw);
    if(!valid||!originalFound||[spaces containsObject:@(e->pendingSpace)])return NO;
    CGDirectDisplayID active[32];uint32_t count=0;
    if(CGGetActiveDisplayList(32,active,&count)||!count||count>=32)return NO;
    for(uint32_t i=0;i<count;i++){
        if(CGDisplayMirrorsDisplay(active[i]))continue;
        CFUUIDRef uuid=createDisplayUUID(active[i]);if(!uuid)return NO;
        NSString *display=CFBridgingRelease(CFUUIDCreateString(NULL,uuid));CFRelease(uuid);
        if(!display||![displays containsObject:display])return NO;
    }
    return YES;
}
static void v2ForgetDeletedSpace(DW2Entry *e) {
    if(!e->pendingSpace||!v2EntryCurrent(e)||v2WindowSpace(e->who.wid)!=e->originalSpace
        ||![v2SpaceDisplay(e->originalSpace,NO)isEqual:e->originalSpaceDisplay]||!v2PendingSpaceDeleted(e)
        ||v2WindowSpace(e->who.wid)!=e->originalSpace||!v2EntryCurrent(e))return;
    uint64_t pending=e->pendingSpace;e->pendingSpace=0;
    if(!v2Persist()){e->pendingSpace=pending;v2JournalStale=YES;}
    else e->pendingSpaceObserved=NO;
}
static BOOL v2RestoreSpace(DW2Entry *e) {
    if(!e->originalSpace)return YES;
    if(![v2SpaceDisplay(e->originalSpace,NO)isEqual:e->originalSpaceDisplay]||!v2EntryCurrent(e))return NO;
    // Confirmation failure must not block an inverse already owed. It does
    // prevent reporting RESTORED while an unobserved forward remains possible.
    (void)v2ConfirmSpace(e);
    v2ForgetDeletedSpace(e);
    uint64_t current=v2WindowSpace(e->who.wid);
    if(current!=e->originalSpace) {
        if(![v2SpaceDisplay(e->originalSpace,NO)isEqual:e->originalSpaceDisplay]||!v2EntryCurrent(e))return NO;
        e->restoreSpaceStarted=v2Now();e->restoreSpaceQuiet=0;e->restoreSpaceSample=NO;
        moveWindowsToSpace(mainConnection(),(__bridge CFArrayRef)@[@(e->who.wid)],e->originalSpace);
    }
    return !e->pendingSpace&&v2WindowSpace(e->who.wid)==e->originalSpace
        &&[v2SpaceDisplay(e->originalSpace,NO)isEqual:e->originalSpaceDisplay]&&v2EntryCurrent(e);
}
// Space membership can read back before AppKit finishes a cross-display reflow.
// Sample before corrective writes so those writes cannot hide continued drift.
// Each retry is nonblocking; crashes discard these transient timing witnesses.
static void v2SpaceRestoreSample(DW2Entry *e) {
    if(!e->originalSpace)return;
    if(!e->restoreSpaceStarted)e->restoreSpaceStarted=v2Now();
    CGRect bounds=CGRectZero;CGAffineTransform actual=CGAffineTransformIdentity;float alpha=-1;
    BOOL stable=e->restoreSpaceSample&&!e->pendingSpace&&v2EntryCurrent(e)
        &&v2WindowSpace(e->who.wid)==e->originalSpace
        &&!getBounds(mainConnection(),e->who.wid,&bounds)&&v2FiniteRect(bounds)&&CGRectEqualToRect(bounds,e->restoreSpaceBounds)
        &&!getLayer(mainConnection(),e->who.wid,&actual)&&v2SameTransform(actual,e->layer)
        &&(!e->alphaTouched||e->veilAlpha||(getAlpha&&!getAlpha(mainConnection(),e->who.wid,&alpha)&&alpha==e->alpha))
        &&(!e->sublevelTouched||v2SublevelMatches(e,e->originalSublevel))
        &&v2EntryCurrent(e);
    if(!stable)e->restoreSpaceQuiet=0;
}
static BOOL v2SpaceRestoreSettled(DW2Entry *e,CGRect bounds,BOOL exact) {
    if(!e->originalSpace)return exact;
    if(!exact){e->restoreSpaceQuiet=0;e->restoreSpaceSample=NO;return NO;}
    uint64_t now=v2Now();
    if(!e->restoreSpaceQuiet||!e->restoreSpaceSample||!CGRectEqualToRect(bounds,e->restoreSpaceBounds))e->restoreSpaceQuiet=now;
    e->restoreSpaceBounds=bounds;e->restoreSpaceSample=YES;
    return now>=e->restoreSpaceStarted&&now-e->restoreSpaceStarted>=2000
        &&now>=e->restoreSpaceQuiet&&now-e->restoreSpaceQuiet>=500;
}

