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
// Admission and identity fences: scope, owner and process-instance resolution, restore-time instance proof, transform comparison,
// fenced pin sublevel reads and writes, the reattach guard and the held/restoring counts.
// Moved verbatim from native/privileged/payload.m (37b27b1), lines 279-287, 319-474, 1140-1143. #imported by DWPayload.m in a fixed order; never compiled alone.
// Edited since the move: the re-basing (v2RestoreTransform) is removed and the reattach guard compares the layer.

static uint64_t v2Now(void) { return (uint64_t)nowMS(); }
static BOOL v2SameProcess(const struct dw2_identity *a,const struct dw2_identity *b) { return a->pid==b->pid && a->birth_sec==b->birth_sec && a->birth_usec==b->birth_usec; }
static BOOL v2Listed(const struct dw2_identity *who) {
    for(NSDictionary *entry in allowlist)
        if([entry[@"pid"] longLongValue]==who->pid && [entry[@"birth_sec"] unsignedLongLongValue]==who->birth_sec && [entry[@"birth_usec"] unsignedLongLongValue]==who->birth_usec)return YES;
    return NO;
}
static BOOL v2SpaceAPI(void) { return copyWindowSpaces&&copySpaceDisplay&&displayCurrentSpace&&getSpaceType&&moveWindowsToSpace&&createDisplayUUID; }
static uint32_t v2Caps(void) { return DW2_CAP_RESTORE_WINDOW|DW2_CAP_ENROLLMENT|DW2_CAP_INSPECT|(setAlpha&&getAlpha?DW2_CAP_ALPHA:0)|(fixtureOnly&&fixtureNativeFamilies?DW2_CAP_FIXTURE_FAMILY:0)|(v2SpaceAPI()?DW2_CAP_SPACE:0)|(v2SublevelAPI()?DW2_CAP_PINNED:0)|(v2VeilAvailable()?DW2_CAP_VEIL:0); }
// Scope, allowlist first: decided from the record alone, before
// any window-server lookup, and again for every record of every frame and restore.
static BOOL v2InScope(const struct dw2_identity *who) {
    if(allowlist && !v2Listed(who))return NO;
    if(!fixtureOnly)return YES;
    if(who->pid!=getpid())return NO;
    for(uint32_t i=0;i<fixtureCount;i++)if(fixtureWids[i]==who->wid)return YES;
    return NO;
}
// A missing enumeration is uncertainty, not evidence a recorded window is gone.
// A successful list can prove absence or a replacement owner PID.
enum { DW2_WINDOW_UNKNOWN=-1, DW2_WINDOW_ABSENT=0, DW2_WINDOW_PRESENT=1 };
static int v2ListedPID(uint32_t wid,int *pid) {
    *pid=0;
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    if(!rows)return DW2_WINDOW_UNKNOWN;
    int result=DW2_WINDOW_ABSENT;
    for(id row in (__bridge NSArray *)rows) {
        id windowNumber=[row isKindOfClass:NSDictionary.class] ? row[(id)kCGWindowNumber] : nil;
        if(!isNumber(windowNumber) || CFNumberIsFloatType((__bridge CFNumberRef)windowNumber)
            || [windowNumber longLongValue]<=0 || [windowNumber unsignedLongLongValue]>UINT32_MAX){result=DW2_WINDOW_UNKNOWN;break;}
        if([windowNumber unsignedLongLongValue]!=wid)continue;
        id ownerPID=row[(id)kCGWindowOwnerPID];
        if(!isNumber(ownerPID) || CFNumberIsFloatType((__bridge CFNumberRef)ownerPID)
            || [ownerPID longLongValue]<=0 || [ownerPID longLongValue]>INT_MAX){result=DW2_WINDOW_UNKNOWN;break;}
        *pid=[ownerPID intValue];result=DW2_WINDOW_PRESENT;break;
    }
    CFRelease(rows);
    return result;
}
// The window's current owner connection, process instance and user, from the window
// server and the kernel. Nothing a client sent is trusted here.
static BOOL v2Resolve(uint32_t wid,int *owner,struct dw2_identity *who,uid_t *uid) {
    int pid=0;
    if(getOwner(mainConnection(),wid,owner) || *owner<=0)return NO;
    if((!connectionPID || connectionPID(*owner,&pid) || pid<=0) && v2ListedPID(wid,&pid)!=DW2_WINDOW_PRESENT)return NO;
    struct proc_bsdinfo b={0};
    if(pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b))return NO;
    *who=(struct dw2_identity){.pid=pid,.wid=wid,.birth_sec=b.pbi_start_tvsec,.birth_usec=b.pbi_start_tvusec};
    *uid=b.pbi_uid;
    return YES;
}
// Journal I/O and preceding records can outlive a window. Recheck the exact
// admission at each mutation boundary; the saved entry is restoration state,
// not continuing authority over a reused window number.
static BOOL v2EntryCurrent(DW2Entry *entry) {
    int owner=0;struct dw2_identity current={0};uid_t uid=0;
    return v2InScope(&entry->who) && v2Resolve(entry->who.wid,&owner,&current,&uid)
        && owner==entry->owner && v2SameProcess(&current,&entry->who) && uid==getuid();
}
// Restore may discard an original only after a query positively establishes that
// its window instance is absent/reused. Transient lookup failures or a changed
// admission scope retain the obligation for a later authorized retry.
enum { DW2_INSTANCE_CURRENT, DW2_INSTANCE_GONE, DW2_INSTANCE_UNCERTAIN };
static NSString *v2RestoreIdentityName(int value) {
    return value==DW2_INSTANCE_CURRENT ? @"current" : value==DW2_INSTANCE_GONE ? @"gone" : @"uncertain";
}
// IncludingWindow can return NULL for a destroyed WID while a cached owner
// connection still resolves. Only a complete, valid all-window enumeration can
// independently establish absence; it includes hidden and offscreen windows.
static NSDictionary<NSNumber *,NSNumber *> *v2RestoreOwners(void) {
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
    if(!rows)return nil;
    if(CFGetTypeID(rows)!=CFArrayGetTypeID() || CFArrayGetCount(rows)>65536){CFRelease(rows);return nil;}
    NSMutableDictionary *owners=[NSMutableDictionary dictionary];BOOL valid=YES;
    for(id row in (__bridge NSArray *)rows) {
        id wid=[row isKindOfClass:NSDictionary.class] ? row[(id)kCGWindowNumber] : nil;
        id pid=[row isKindOfClass:NSDictionary.class] ? row[(id)kCGWindowOwnerPID] : nil;
        if(!isNumber(wid) || CFNumberIsFloatType((__bridge CFNumberRef)wid) || [wid longLongValue]<=0
            || [wid unsignedLongLongValue]>UINT32_MAX || !isNumber(pid) || CFNumberIsFloatType((__bridge CFNumberRef)pid)
            || [pid longLongValue]<=0 || [pid longLongValue]>INT_MAX || owners[wid]){valid=NO;break;}
        owners[wid]=pid;
    }
    CFRelease(rows);return valid ? owners : nil;
}
static int v2RestoreIdentityWithOwners(const struct dw2_identity *recorded,int recordedOwner,NSDictionary<NSNumber *,NSNumber *> *owners) {
    if(!owners)return DW2_INSTANCE_UNCERTAIN;
    NSNumber *listedPID=owners[@(recorded->wid)];
    if(!listedPID || listedPID.intValue!=recorded->pid)return DW2_INSTANCE_GONE;
    int owner=0;struct dw2_identity current={0};uid_t uid=0;
    if(v2Resolve(recorded->wid,&owner,&current,&uid)) {
        if(!v2SameProcess(&current,recorded) || owner!=recordedOwner)return DW2_INSTANCE_GONE;
        return uid==getuid() && v2InScope(recorded) ? DW2_INSTANCE_CURRENT : DW2_INSTANCE_UNCERTAIN;
    }
    struct proc_bsdinfo process={0};
    if(proc_pidinfo(recorded->pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process))return DW2_INSTANCE_UNCERTAIN;
    return process.pbi_start_tvsec!=recorded->birth_sec || process.pbi_start_tvusec!=recorded->birth_usec ? DW2_INSTANCE_GONE : DW2_INSTANCE_UNCERTAIN;
}
static int v2RestoreIdentity(const struct dw2_identity *recorded,int recordedOwner) {
    return v2RestoreIdentityWithOwners(recorded,recordedOwner,v2RestoreOwners());
}
// The window server keeps transforms as 32-bit floats, so a request is applied when it reads back equal after the same rounding,
// give or take the rounding of composing the layer with placement 0 (DW_*_TOLERANCE above; the linear part of a plain placement 0
// passes through exactly, so only a translation can differ, by less than 1/256 of a point). A layer read back alone is exact.
static BOOL v2NearFloat(double a,double b,float tolerance) {
    float x=(float)a,y=(float)b;return x==y || fabsf(x-y)<=tolerance;
}
static BOOL v2SameTransform(CGAffineTransform a,CGAffineTransform b) {
    return v2NearFloat(a.a,b.a,DW_LINEAR_TOLERANCE) && v2NearFloat(a.b,b.b,DW_LINEAR_TOLERANCE) && v2NearFloat(a.c,b.c,DW_LINEAR_TOLERANCE)
        && v2NearFloat(a.d,b.d,DW_LINEAR_TOLERANCE) && v2NearFloat(a.tx,b.tx,DW_TRANSLATION_TOLERANCE) && v2NearFloat(a.ty,b.ty,DW_TRANSLATION_TOLERANCE);
}
static BOOL v2FiniteRect(CGRect r);
// The sublevel getter has a direct int return, not a status. Fence it with
// a successful base-level read and exact current identity on both sides.
static BOOL v2ReadSublevel(DW2Entry *e,int *value) {
    int level=0;
    if(!v2SublevelAPI()||!v2EntryCurrent(e)||v2GetWindowLevel(mainConnection(),e->who.wid,&level))return NO;
    *value=v2GetWindowSublevel(mainConnection(),e->who.wid);
    return v2EntryCurrent(e);
}
static BOOL v2SublevelMatches(DW2Entry *e,int expected) {
    int actual=0;return v2ReadSublevel(e,&actual)&&actual==expected;
}
static BOOL v2ApplySublevel(DW2Entry *e,int requested,int *setStatus) {
    int actual=0;*setStatus=0;
    if(!v2ReadSublevel(e,&actual))return NO;
    if(actual!=requested){
        if(!v2EntryCurrent(e))return NO;
        *setStatus=v2SetWindowSublevel(mainConnection(),e->who.wid,requested);
        if(*setStatus)return NO;
    }
    return v2SublevelMatches(e,requested);
}
static BOOL v2ReattachCurrent(DW2Entry *e) {
    // The window's layer is either still the original or has been reset to the identity by the death of the connection that wrote it
    // (the Dock, which is what a reattachment follows); anything else was written by someone since, and is not the helper's to undo.
    // Where the window is does not matter: a layer is relative to placement 0, so what it says does not depend on the frame, and a
    // window the application or a drag moved since it was released is natural where it now is. An original that is the identity
    // (the usual one) matches whatever else the window server holds.
    CGAffineTransform actual=CGAffineTransformIdentity;float alpha=-1;
    return v2EntryCurrent(e) && !getLayer(mainConnection(),e->who.wid,&actual) && finiteMatrix(actual)
        && (v2SameTransform(actual,e->layer) || v2SameTransform(actual,CGAffineTransformIdentity))
        && (!e->alphaTouched || e->veilAlpha || (getAlpha && !getAlpha(mainConnection(),e->who.wid,&alpha) && alpha==e->alpha))
        && (!e->sublevelTouched || v2SublevelMatches(e,e->originalSublevel)) && v2EntryCurrent(e);
}
static void v2Count(void) {
    uint32_t restoring=0;
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->state==DW2_RESTORING)restoring++;
    atomic_store(&v2Held,(uint32_t)v2Table.count-restoring);atomic_store(&v2Restoring,restoring);
}

static BOOL v2FiniteRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        && r.size.width>0 && r.size.height>0;
}
