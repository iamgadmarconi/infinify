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
// Arrival: the arrival veil and the arrival placement of a placed root's children, their timeouts and release, and the window
// server's window-added handler. Adapted from Sunlight, see above.
// Moved verbatim from native/privileged/payload.m (37b27b1), lines 979-1127. #imported by DWPayload.m in a fixed order; never compiled alone.
// Edited since the move: the original is the placement-1 layer (getLayer), the absolute read only decides whether the window is already placed.

// Arrival veil. The window server announces a window added to a Space (SkyLight notification 1325) as
// the window appears, a few milliseconds before the shell can have placed it. A window that qualifies
// is admitted as an ordinary table entry, its original transform, bounds and alpha journalled before
// anything is written, and held at alpha 0. The first frame for it lifts the alpha after its transform
// (v2FrameAlpha); a RESTORE record, the end of the session, or DW2_VEIL_TIMEOUT_MS releases it by the
// ordinary release, which puts the original alpha back. A window that closes meanwhile is dropped by
// the identity logic of v2Restore, and the journal covers a crash like any other entry.
// Only ordinary windows are veiled: level 0, at full alpha, at least the shell's size floor, same user
// and process birth, in scope, and never the helper's own process or the client's. A window below full
// alpha is fading in under its application's own animation (a sheet was read at 0.79 and the application's
// next frames overwrote the veil): it is not veiled, and the fraction is never taken for an original to
// write back later. Whether a window is on screen is not asked: the announcement comes before it is ordered in.
static BOOL v2VeilEligible(uint32_t wid) {
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    if(!rows)return NO;
    BOOL eligible=NO;
    for(id row in (__bridge NSArray *)rows) {
        if(![row isKindOfClass:NSDictionary.class] || !isNumber(row[(id)kCGWindowNumber]) || [row[(id)kCGWindowNumber]unsignedLongLongValue]!=wid)continue;
        // The window server announces a window before it is ordered in: its row then has no kCGWindowIsOnscreen yet.
        eligible=isNumber(row[(id)kCGWindowLayer]) && [row[(id)kCGWindowLayer]integerValue]==0;
        break;
    }
    CFRelease(rows);return eligible;
}
static void v2VeilExpire(DW2Entry *e) {
    if(v2Table[@(e->who.wid)]!=e || !e->veiled || e->state!=DW2_HELD)return;
    e->state=DW2_RESTORING;
    struct dw2_restore_reply summary={0};
    v2Restore(@"veil timeout",YES,nil,&summary);
}
// Arrival placement. A window an application opens as a child of a window the shell has placed (a context menu, a pop-up button's
// menu, a popover, a sheet, a completion list: the window server names the root as its parent) was shown at its native place for
// the 23 to 40 ms the shell needed to list it and send a frame (measured), whatever its level or alpha: the veil above holds neither a window the
// application fades itself nor one that is not at level 0. Here the helper gives such a window, at the announcement, the placement
// the shell gives every member of that root's family (the root's transform with its translation moved by the window's native offset
// from the root, native/app/CompositorMode/DWNativePresenter+Frames.m, -describe:), computed from what the root's entry has applied and what the window
// server reads for both windows now. The shell's first frame naming the window replaces it (and normally equals it); until then it is a
// table entry like any other: journalled with its original transform, bounds and alpha before the write, released by the ordinary
// release by a RESTORE record, RESTORE_ALL, the end of the session, VEIL mode 0, or DW2_ARRIVAL_TIMEOUT_MS after it opened if no
// frame has named it. Only a window whose exact parent chain, in one process instance, ends at a held root with an applied
// transform is touched: the global menu bar's menus, status items and every other window without such a parent are not.
static BOOL v2FamilyRoot(const struct dw2_identity *who,uint32_t wid,uint32_t *root) {
    uint32_t seen[16],cursor=wid;
    for(unsigned depth=0;depth<16;depth++){
        for(unsigned i=0;i<depth;i++)if(seen[i]==cursor)return NO;seen[depth]=cursor;
        uint32_t parent=0;if(!v2ParentOf(cursor,&parent))return NO;
        if(!parent){*root=cursor;return cursor!=wid;}
        int owner=0;struct dw2_identity up={0};uid_t uid=0;
        if(!v2Resolve(parent,&owner,&up,&uid)||uid!=getuid()||!v2SameProcess(&up,who))return NO;
        cursor=parent;
    }
    return NO;
}
static void v2ArrivalExpire(DW2Entry *e) {
    if(v2Table[@(e->who.wid)]!=e || !e->arrival || e->state!=DW2_HELD)return;
    e->state=DW2_RESTORING;
    struct dw2_restore_reply summary={0};
    v2Restore(@"arrival placement timeout",YES,nil,&summary);
}
static BOOL v2ArrivalPlace(uint32_t wid) {
    if(!v2ParentOf||!getTransform||!setTransform||!getLayer||!getBounds)return NO;
    // Cheapest first: every window anywhere is announced here, and a window without a parent (all but a child) ends this read.
    uint32_t parent=0;if(!v2ParentOf(wid,&parent)||!parent)return NO;
    int owner=0;struct dw2_identity who={0};uid_t uid=0;
    if(!v2Resolve(wid,&owner,&who,&uid)||uid!=getuid()||!v2InScope(&who)||who.pid==getpid()||who.pid==atomic_load(&v2VeilClient))return NO;
    uint32_t rootWID=0;
    if(!v2FamilyRoot(&who,wid,&rootWID))return NO;
    DW2Entry *root=v2Table[@(rootWID)];
    // A held root the shell has placed, whose transform is still the one applied: nothing is extrapolated from a stale or absent placement.
    CGAffineTransform rootNow=CGAffineTransformIdentity;CGRect rootBounds=CGRectZero,bounds=CGRectZero;
    if(!root||root->state!=DW2_HELD||root->veilBare||!root->appliedTransformKnown||!v2SameProcess(&root->who,&who)||root->owner!=owner||!v2EntryCurrent(root)
        ||getTransform(mainConnection(),rootWID,&rootNow)||!v2SameTransform(rootNow,root->appliedTransform)||!finiteMatrix(rootNow)||rootNow.b||rootNow.c
        ||getBounds(mainConnection(),rootWID,&rootBounds)||!v2FiniteRect(rootBounds)||getBounds(mainConnection(),wid,&bounds)||!v2FiniteRect(bounds))return NO;
    CGAffineTransform placement=rootNow;
    placement.tx-=bounds.origin.x-rootBounds.origin.x;placement.ty-=bounds.origin.y-rootBounds.origin.y;
    if(!finiteMatrix(placement))return NO;
    NSNumber *key=@(wid);
    DW2Entry *e=[DW2Entry new];e->who=who;e->owner=owner;e->state=DW2_HELD;e->bounds=bounds;
    // The original is the window's layer; the absolute matrix is read only to see whether it is already where the family puts it.
    CGAffineTransform drawn=CGAffineTransformIdentity;
    if(getLayer(mainConnection(),wid,&e->layer)||!finiteMatrix(e->layer)||getTransform(mainConnection(),wid,&drawn)||!finiteMatrix(drawn))return NO;
    // Already where the root's family puts it (an identity placement of the root): nothing to take.
    if(v2SameTransform(drawn,placement))return NO;
    if(getAlpha&&setAlpha){if(getAlpha(mainConnection(),wid,&e->alpha)||!isfinite(e->alpha))return NO;e->hasAlpha=YES;}
    if(!v2EntryCurrent(e))return NO;
    BOOL pruned=NO;
    if(v2Table.count+v2Released.count>=DW2_MAX_TABLE)pruned=v2PruneReleased();
    if(v2Table.count+v2Released.count>=DW2_MAX_TABLE){if(pruned){v2JournalStale=YES;v2ScheduleRetry();}return NO;}
    e->arrival=YES;v2Table[key]=e;
    if(!v2Persist()){
        // Nothing of this window is changed without a record on disk.
        [v2Table removeObjectForKey:key];v2JournalStale=YES;v2ScheduleRetry();v2Count();return NO;
    }
    v2Count();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)DW2_ARRIVAL_TIMEOUT_MS*NSEC_PER_MSEC),v2q,^{v2ArrivalExpire(e);});
    CGAffineTransform actual=CGAffineTransformIdentity;
    if(!v2EntryCurrent(e)||setTransform(mainConnection(),wid,placement)||getTransform(mainConnection(),wid,&actual)||!v2SameTransform(actual,placement)||!v2EntryCurrent(e)){
        // It may have been changed: the ordinary release puts back what was journalled, or finds the window gone.
        e->state=DW2_RESTORING;struct dw2_restore_reply summary={0};
        v2Restore(@"arrival placement not applied",YES,nil,&summary);
        return YES;
    }
    e->appliedTransform=placement;e->appliedTransformKnown=YES;
    return YES;
}
static void v2Veil(uint32_t wid) {
    if(!atomic_load(&v2VeilOn) || !wid || !v2Table)return;
    NSNumber *key=@(wid);
    // A window the table or a release already knows is the shell's to place, not an arrival.
    if(v2Table[key] || v2Released[key])return;
    if(v2ArrivalPlace(wid))return;
    if(!v2VeilEligible(wid))return;
    int owner=0;struct dw2_identity who={0};uid_t uid=0;
    if(!v2Resolve(wid,&owner,&who,&uid) || uid!=getuid() || !v2InScope(&who) || who.pid==getpid() || who.pid==atomic_load(&v2VeilClient))return;
    DW2Entry *e=[DW2Entry new];e->who=who;e->owner=owner;e->state=DW2_HELD;
    if(getLayer(mainConnection(),wid,&e->layer) || !finiteMatrix(e->layer) || getBounds(mainConnection(),wid,&e->bounds) || !v2FiniteRect(e->bounds)
        || e->bounds.size.width<v2VeilMinimumExtent || e->bounds.size.height<v2VeilMinimumExtent
        || getAlpha(mainConnection(),wid,&e->alpha) || e->alpha!=1 || !v2EntryCurrent(e))return;
    e->hasAlpha=e->alphaTouched=e->veiled=e->veilBare=e->veilAlpha=YES;
    BOOL pruned=NO;
    if(v2Table.count+v2Released.count>=DW2_MAX_TABLE)pruned=v2PruneReleased();
    if(v2Table.count+v2Released.count>=DW2_MAX_TABLE){if(pruned){v2JournalStale=YES;v2ScheduleRetry();}return;}
    v2Table[key]=e;
    if(!v2Persist()) {
        // Nothing of this window is changed without a record on disk.
        [v2Table removeObjectForKey:key];v2JournalStale=YES;v2ScheduleRetry();v2Count();return;
    }
    v2Count();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)DW2_VEIL_TIMEOUT_MS*NSEC_PER_MSEC),v2q,^{v2VeilExpire(e);});
    float seen=-1;
    if(!v2EntryCurrent(e) || setAlpha(mainConnection(),wid,0) || getAlpha(mainConnection(),wid,&seen) || seen!=0) {
        // It may have been changed: the ordinary release puts back what was journalled, or finds the window gone.
        e->state=DW2_RESTORING;struct dw2_restore_reply summary={0};
        v2Restore(@"veil not applied",YES,nil,&summary);
    }
}
// On v2q. Ending the veil releases whatever it still holds.
static void v2VeilRelease(void) {
    for(DW2Entry *e in v2Table.objectEnumerator)if((e->veiled||e->arrival) && e->state==DW2_HELD)e->state=DW2_RESTORING;
    struct dw2_restore_reply summary={0};
    v2Restore(@"veil ended",YES,nil,&summary);
}

// Main thread, from the window server. Only a window id leaves it; every native call is v2q's.
static void v2WindowAdded(uint32_t type,void *data,size_t length,void *context) {
    (void)context;
    if(type!=1325 || !data || length<12 || !atomic_load(&v2VeilOn))return;
    uint32_t wid=0;memcpy(&wid,(const char *)data+8,sizeof(wid));
    if(wid)dispatch_async(v2q,^{v2Veil(wid);});
}

