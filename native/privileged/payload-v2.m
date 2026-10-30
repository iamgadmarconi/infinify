// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol v2: many windows per frame, newest frame wins, journalled restoration.
// Original implementation, compiled as part of payload.m (one translation unit, so
// it shares resolved native symbols, scope and runtime directory). Wire format:
// protocol2.h. Semantics: README.md "Protocol v2".
// The arrival veil (v2Veil below) adapts an idea and a technique of spacefarm-digital/sunlight
// afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm): that a window an
// application opens must not be seen at its native place before the canvas has placed it
// (LiveWindows/README.md:129 and LiveWindows/osax/sunbeam.h:40-51, which keep the canvas and its
// windows one window level up), and the window server's own announcement of it, SkyLight
// connection notification 1325 with the Space id (u64) then the window id (u32) as payload,
// registered with SLSRegisterConnectionNotifyProc (Sources/Canvas/RealWindows/WindowServerEvents.swift:4-15,
// 36-55 and 73-85). The level lift is not taken: here the window is held at alpha 0 instead.
#import <pthread.h>
#import <stdatomic.h>
#import <sys/uio.h>
#import "protocol2.h"

#ifndef DW_V2_MAIN_QUEUE
#define DW_V2_MAIN_QUEUE 0
#endif

// Every v2 native call, the table, the journal, restore and its retries run on v2q.
// Socket reads, parsing, heartbeats and the lease watch run on connection threads
// and never wait on it.
static dispatch_queue_t v2q;
static BOOL v2OnMain;
static uint32_t fixtureWids[16], fixtureCount;

@interface DW2Connection : NSObject { @public int fd; pthread_mutex_t writeLock; atomic_bool closed; int role; uint64_t session, lastFrame; } @end
@implementation DW2Connection
- (void)dealloc { close(fd);pthread_mutex_destroy(&writeLock); }
@end
@interface DW2Entry : NSObject { @public struct dw2_identity who; int owner; CGAffineTransform transform; CGRect bounds; float alpha; BOOL hasAlpha, alphaTouched, fresh, alphaFresh; uint32_t state;
    // A released original imported after its writer died needs the narrower
    // unchanged-geometry/reset guard on every retry, including after a crash.
    BOOL reattaching;
    // Apply-only state. Originals and restoration never depend on this hint.
    CGAffineTransform appliedTransform; BOOL appliedTransformKnown;
    float appliedAlpha; BOOL appliedAlphaKnown;
    // Optional pin obligation, immutable after first durable admission.
    int originalSublevel; BOOL sublevelTouched, sublevelFresh;
    // Arrival veil. veiled (memory only): alpha is held at 0 by v2Veil, and the first frame that places the
    // window gives it back. veilBare: nothing but the alpha has been changed, so a release does not write
    // the transform (the window server's transform follows the window's position, which the application
    // may have changed since); the first frame clears it, durably, before any write. veilAlpha: the alpha
    // obligation is the veil's, so a release writes the original only while the alpha still reads 0 (the
    // application may have taken it over); a frame that carries an alpha makes it unconditional, durably.
    // veilBare and veilAlpha are journalled (optional keys veil_bare, veil_alpha). The Cleared flags and
    // veilPrior* only undo a first-frame change whose journal write failed.
    BOOL veiled, veilBare, veilAlpha, veilBareCleared, veilAlphaCleared;
    CGAffineTransform veilPriorTransform; CGRect veilPriorBounds;
    // Optional Space obligation. Original membership is immutable. A void
    // forward request remains uncertain until its target is actually observed.
    uint64_t originalSpace, pendingSpace; NSString *originalSpaceDisplay;
    BOOL spaceFresh, pendingSpaceFresh, pendingSpaceObserved;
    // Transient settlement evidence is never imported from a journal.
    uint64_t restoreSpaceStarted, restoreSpaceQuiet; CGRect restoreSpaceBounds;
    BOOL restoreSpaceSample;
} @end
@implementation DW2Entry
@end

// Session, lease and the one-frame slot, shared between connection threads and v2q.
static pthread_mutex_t v2Lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t v2Session, v2Sessions, v2Barrier, v2SlotSeq;
static uint16_t v2SlotType;
static uint32_t v2SupersededPending;
static uint8_t v2Token[16];
static NSMutableArray<DW2Connection *> *v2Beats;
static NSData *v2Slot;
static DW2Connection *v2SlotOwner;
static _Atomic uint64_t v2Deadline, v2FramesReceived, v2FramesApplied, v2FramesSuperseded, v2JournalWrites;
static _Atomic uint32_t v2Held, v2Restoring;
static _Atomic int v2Connections;
// Touched on v2q only.
static NSMutableDictionary<NSNumber *,DW2Entry *> *v2Table;
static NSMutableDictionary<NSNumber *,DW2Entry *> *v2Released;
static NSDictionary *v2WriterIdentity;
static NSDictionary *v2LastRestore;
static uint64_t v2Generation;
static BOOL v2JournalStale, v2RetryScheduled;
static unsigned v2RetryDelayMS=250;
// Optional deletion evidence only; this getter is not needed for forward moves.
// ABI/schema: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:60 and src/display.c:203-234 (MIT).
static CFArrayRef (*v2CopyManagedSpaces)(int);
static BOOL v2ManagedSpacesResolved;
// ABI and nonactivating layer use: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:14-15,36 and src/osax/payload.m:749-758 (MIT).
// Resolve once before journal recovery/listener startup; no native calls here.
static CGError (*v2GetWindowLevel)(int,uint32_t,int *);
static int (*v2GetWindowSublevel)(int,uint32_t);
static CGError (*v2SetWindowSublevel)(int,uint32_t,int);
static BOOL v2SublevelAPI(void) { return v2GetWindowLevel&&v2GetWindowSublevel&&v2SetWindowSublevel; }
// Arrival veil. v2VeilOn is set on v2q by the session's VEIL request and cleared with the session; the
// notification handler reads it from the main thread. v2VeilClient is the control connection's process.
static int (*v2RegisterNotify)(int,void (*)(uint32_t,void *,size_t,void *),uint32_t,void *);
static BOOL v2VeilRegistered;
static _Atomic bool v2VeilOn;
static _Atomic int32_t v2VeilClient;
// A window narrower or shorter than this is never offered to the shell (window-manager.m), so it is not veiled.
static const CGFloat v2VeilMinimumExtent=40;
// Only the explicit same-user (desktop) helper; allowlist and cooperative scopes are not veiled.
static BOOL v2VeilAvailable(void) { return v2VeilRegistered&&!fixtureOnly&&!allowlist&&setAlpha&&getAlpha&&getBounds&&getTransform; }
static void v2ResolveSublevels(void) {
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    if(!sky)return;
    v2GetWindowLevel=dlsym(sky,"SLSGetWindowLevel");
    v2GetWindowSublevel=dlsym(sky,"SLSGetWindowSubLevel");
    v2SetWindowSublevel=dlsym(sky,"SLSSetWindowSubLevel");
}

#import "forward-operations.h"

static uint64_t v2Now(void) { return (uint64_t)nowMS(); }
static BOOL v2SameProcess(const struct dw2_identity *a,const struct dw2_identity *b) { return a->pid==b->pid && a->birth_sec==b->birth_sec && a->birth_usec==b->birth_usec; }
static BOOL v2Listed(const struct dw2_identity *who) {
    for(NSDictionary *entry in allowlist)
        if([entry[@"pid"] longLongValue]==who->pid && [entry[@"birth_sec"] unsignedLongLongValue]==who->birth_sec && [entry[@"birth_usec"] unsignedLongLongValue]==who->birth_usec)return YES;
    return NO;
}
static BOOL v2SpaceAPI(void) { return copyWindowSpaces&&copySpaceDisplay&&displayCurrentSpace&&getSpaceType&&moveWindowsToSpace&&createDisplayUUID; }
static uint32_t v2Caps(void) { return DW2_CAP_RESTORE_WINDOW|DW2_CAP_ENROLLMENT|DW2_CAP_INSPECT|(setAlpha&&getAlpha?DW2_CAP_ALPHA:0)|(fixtureOnly&&fixtureNativeFamilies?DW2_CAP_FIXTURE_FAMILY:0)|(v2SpaceAPI()?DW2_CAP_SPACE:0)|(v2SublevelAPI()?DW2_CAP_PINNED:0)|(v2VeilAvailable()?DW2_CAP_VEIL:0); }
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
// The window server keeps transforms as 32-bit floats, so a request is applied when
// it reads back equal after the same rounding.
static BOOL v2SameTransform(CGAffineTransform a,CGAffineTransform b) {
    return (float)a.a==(float)b.a && (float)a.b==(float)b.b && (float)a.c==(float)b.c && (float)a.d==(float)b.d && (float)a.tx==(float)b.tx && (float)a.ty==(float)b.ty;
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
    CGRect bounds=CGRectZero;CGAffineTransform actual=CGAffineTransformIdentity;float alpha=-1;
    return v2EntryCurrent(e) && !getBounds(mainConnection(),e->who.wid,&bounds) && v2FiniteRect(bounds)
        && CGRectEqualToRect(bounds,e->bounds) && !getTransform(mainConnection(),e->who.wid,&actual) && finiteMatrix(actual)
        && (v2SameTransform(actual,e->transform) || v2SameTransform(actual,CGAffineTransformIdentity))
        && (!e->alphaTouched || e->veilAlpha || (getAlpha && !getAlpha(mainConnection(),e->who.wid,&alpha) && alpha==e->alpha))
        && (!e->sublevelTouched || v2SublevelMatches(e,e->originalSublevel)) && v2EntryCurrent(e);
}
static void v2Count(void) {
    uint32_t restoring=0;
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->state==DW2_RESTORING)restoring++;
    atomic_store(&v2Held,(uint32_t)v2Table.count-restoring);atomic_store(&v2Restoring,restoring);
}

// The alpha a frame leaves a window at: the record's own or, for a veiled window whose record carries none, its original.
static BOOL v2FrameAlpha(DW2Entry *e,const struct dw2_record *r,float *alpha) {
    if(r->flags&DW2_RECORD_HAS_ALPHA){*alpha=r->alpha;return YES;}
    if(e->veiled){
        // No alpha of its own to ask for: lift the veil, unless the application has taken the alpha over since (it no longer reads 0).
        float held=-1;
        if(!getAlpha(mainConnection(),e->who.wid,&held) && held!=0){e->veiled=NO;return NO;}
        *alpha=e->alpha;return YES;
    }
    return NO;
}

#if DW_V2_BATCH_COMPILED
// The explicit batching comparison builds share final property verification.
// Hints only omit a setter after a fresh getter proves the desired native value;
// originals, identity fences and restoration never depend on a hint.
static uint8_t v2FinishForward(DW2Entry *e,const struct dw2_record *r,uint64_t target,BOOL ok) {
    BOOL alphaOK=YES;float want=0;
    BOOL wantsAlpha=v2FrameAlpha(e,r,&want);
    if(wantsAlpha) {
        if(!v2EntryCurrent(e))return DW2_IDENTITY;
        float actual=-1;
        BOOL repeated=DW_V2_ALPHA_DEDUP && e->appliedAlphaKnown && e->appliedAlpha==want;
        alphaOK=repeated && !getAlpha(mainConnection(),e->who.wid,&actual) && actual==want;
        e->appliedAlphaKnown=NO;
        if(!alphaOK) {
            // A corrective write after the getter needs the same fresh identity
            // fence as a corrective transform; a reused WID receives no write.
            if(repeated && !v2EntryCurrent(e))return DW2_IDENTITY;
            alphaOK=!setAlpha(mainConnection(),e->who.wid,want)
                && !getAlpha(mainConnection(),e->who.wid,&actual) && actual==want;
        }
        if(!alphaOK)ok=NO;else e->veiled=NO;
    }
    if(e->sublevelTouched) {
        int requested=(r->flags&DW2_RECORD_PINNED)?CGWindowLevelForKey(kCGFloatingWindowLevelKey):e->originalSublevel;
        int setStatus=0;if(!v2ApplySublevel(e,requested,&setStatus))ok=NO;
    }
    BOOL spaceOK=!target||(v2WindowSpace(e->who.wid)==target&&v2SpaceDisplay(target,YES));
    if(!v2EntryCurrent(e))return DW2_IDENTITY;
    if(!spaceOK||!ok)return DW2_NOT_APPLIED;
    e->appliedTransform=CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]);
    e->appliedTransformKnown=YES;
    if(wantsAlpha){e->appliedAlpha=want;e->appliedAlphaKnown=alphaOK;}
    return DW2_APPLIED;
}

#endif // DW_V2_BATCH_COMPILED

// Durable no-follow staging and rename; original values survive every frame.
static NSDictionary *v2JournalEntry(DW2Entry *e,NSString *state) {
    NSMutableDictionary *row=[@{@"pid":@(e->who.pid),@"birth_sec":@(e->who.birth_sec),@"birth_usec":@(e->who.birth_usec),@"wid":@(e->who.wid),@"owner":@(e->owner),
        @"transform":matrix(e->transform),@"alpha":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,@"alpha_touched":@(e->alphaTouched),
        @"bounds":@[@(e->bounds.origin.x),@(e->bounds.origin.y),@(e->bounds.size.width),@(e->bounds.size.height)],@"state":state}mutableCopy];
    if(e->sublevelTouched)row[@"original_sublevel"]=@(e->originalSublevel);
    if(e->veilBare)row[@"veil_bare"]=@YES;
    if(e->veilAlpha)row[@"veil_alpha"]=@YES;
    if(e->originalSpace)row[@"original_space"]=@{@"id":@(e->originalSpace),@"display":e->originalSpaceDisplay,@"pending_target":@(e->pendingSpace)};
    return row;
}
static BOOL v2Persist(void) {
    if(!v2WriterIdentity || v2Table.count+v2Released.count>DW2_MAX_TABLE)return NO;
    NSMutableArray *windows=[NSMutableArray array],*released=[NSMutableArray array];
    BOOL restoring=NO;
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(e->state==DW2_RESTORING)restoring=YES;
        [windows addObject:v2JournalEntry(e,e->reattaching ? @"reattaching" : e->state==DW2_HELD ? @"held" : @"restoring")];
    }
    for(NSNumber *wid in [v2Released.allKeys sortedArrayUsingSelector:@selector(compare:)])[released addObject:v2JournalEntry(v2Released[wid],@"released")];
    NSMutableDictionary *journal=[v2WriterIdentity mutableCopy];
    [journal addEntriesFromDictionary:@{@"v":@3,@"generation":@(v2Generation+1),@"state":!windows.count ? @"empty" : restoring ? @"restoring" : @"holding",
        @"windows":windows,@"released_windows":released,@"last_restore":v2LastRestore ?: (id)NSNull.null}];
    NSData *data=[NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingPrettyPrinted error:NULL];
    if(!data)return NO;
    int fd=openat(directoryFD,"v2-journal.next",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return NO;
    BOOL ok=writeAll(fd,data.bytes,data.length) && fsync(fd)==0;
    if(close(fd))ok=NO;
    if(ok)ok=renameat(directoryFD,"v2-journal.next",directoryFD,"v2-journal.json")==0 && fsync(directoryFD)==0;
    if(!ok){unlinkat(directoryFD,"v2-journal.next",0);return NO;}
    v2Generation++;atomic_fetch_add(&v2JournalWrites,1);
    return YES;
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
        void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LOCAL|RTLD_NOW);
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
        &&!getTransform(mainConnection(),e->who.wid,&actual)&&v2SameTransform(actual,e->transform)
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

static void v2Restore(NSString *reason,BOOL retry,NSMutableData *results,struct dw2_restore_reply *summary);
// Live released originals remain obligations across connection death. Make room only by proving
// a recorded instance is gone, never age. Returns whether the released table changed.
static BOOL v2PruneReleased(void) {
    BOOL changed=NO;
    NSDictionary *owners=v2RestoreOwners();
    for(NSNumber *releasedKey in v2Released.allKeys){DW2Entry *old=v2Released[releasedKey];
        if(v2RestoreIdentityWithOwners(&old->who,old->owner,owners)==DW2_INSTANCE_GONE){[v2Released removeObjectForKey:releasedKey];changed=YES;}}
    return changed;
}
static void v2ScheduleRetry(void) {
    if(v2RetryScheduled)return;
    v2RetryScheduled=YES;
    unsigned delay=v2RetryDelayMS;
    v2RetryDelayMS=MIN(v2RetryDelayMS*2,2000U);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay*NSEC_PER_MSEC),v2q,^{
        v2RetryScheduled=NO;
        if(atomic_load(&v2Restoring) || v2JournalStale)v2Restore(@"automatic retry",YES,nil,NULL);
    });
}
// Puts back what was captured at first touch, for every window (or, on a retry, for
// those still pending). Each window is resolved again: one that is no longer the
// recorded window of the recorded process instance is left alone and dropped; one
// whose restore cannot be confirmed stays, blocks nothing else and is retried.
static void v2Restore(NSString *reason,BOOL retry,NSMutableData *results,struct dw2_restore_reply *summary) {
    NSMutableArray *report=[NSMutableArray array];
    uint32_t count=0,pending=0;
    // Share the initial enumeration across this bounded table pass. Successful
    // restoration still takes a fresh enumeration at its final identity fence.
    NSDictionary *owners=v2Table.count ? v2RestoreOwners() : nil;
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(retry && e->state!=DW2_RESTORING)continue;
        struct dw2_restore_result r={.id=e->who,.outcome=DW2_PENDING,.set_status=-1};
        BOOL transformSet=NO,transformRead=NO,transformMatches=NO,alphaChecked=NO,alphaCurrent=NO,alphaSet=NO,alphaRead=NO;
        int transformSetStatus=0,transformGetStatus=0,alphaSetStatus=0,alphaGetStatus=0,finalIdentity=-1;
        CGAffineTransform actual=CGAffineTransformIdentity;float alpha=-1;CGRect releasedBounds=CGRectZero;
        int observed=v2RestoreIdentityWithOwners(&e->who,e->owner,owners);
        BOOL admitted=observed==DW2_INSTANCE_CURRENT&&(!e->reattaching||v2ReattachCurrent(e));
        if(e->originalSpace&&!admitted){e->restoreSpaceQuiet=0;e->restoreSpaceSample=NO;}
        if(observed==DW2_INSTANCE_GONE){r.outcome=DW2_GONE;r.set_status=0;}
        else if(admitted) {
            BOOL spaceRestored=v2RestoreSpace(e);
            v2SpaceRestoreSample(e);
            // Space calls and their readbacks can outlive the window as well.
            if(e->originalSpace&&!v2EntryCurrent(e)){e->restoreSpaceQuiet=0;e->restoreSpaceSample=NO;e->state=DW2_RESTORING;pending++;count++;[results appendBytes:&r length:sizeof(r)];
                [report addObject:@{@"pid":@(r.id.pid),@"birth_sec":@(r.id.birth_sec),@"birth_usec":@(r.id.birth_usec),@"wid":@(r.id.wid),@"outcome":@"pending",@"set_status":@(-1)}];continue;}
            BOOL ok;
            if(e->veilBare) {
                // Nothing but alpha was changed: the transform in force is the window's own, and moves with it. Adopt it as the original.
                r.set_status=0;transformRead=YES;
                ok=(transformGetStatus=getTransform(mainConnection(),e->who.wid,&actual))==0 && finiteMatrix(actual);
                if(ok){e->transform=actual;transformMatches=YES;}
            } else {
                transformSet=YES;r.set_status=transformSetStatus=setTransform(mainConnection(),e->who.wid,e->transform);
                ok=r.set_status==0 && (transformRead=YES,transformGetStatus=getTransform(mainConnection(),e->who.wid,&actual))==0
                    && (transformMatches=v2SameTransform(actual,e->transform));
            }
            if(e->alphaTouched) {
                alphaChecked=YES;alphaCurrent=e->reattaching ? v2ReattachCurrent(e) : v2EntryCurrent(e);
                // The veil's alpha is put back only while it still reads 0: a window the application has since taken over, or that
                // a frame lifted without asking for an alpha of its own, is left as it is.
                float held=-1;BOOL owed=!(e->veilAlpha && alphaCurrent && !getAlpha(mainConnection(),e->who.wid,&held) && held!=0);
                if(owed) {
                    int status=alphaCurrent ? (alphaSet=YES,alphaSetStatus=setAlpha(mainConnection(),e->who.wid,e->alpha)) : -1;
                    if(status && !r.set_status)r.set_status=status;
                    if(status || (alphaRead=YES,alphaGetStatus=getAlpha(mainConnection(),e->who.wid,&alpha)) || alpha!=e->alpha)ok=NO;
                }
            }
            if(e->sublevelTouched){
                int sublevelStatus=0;
                if(!v2ApplySublevel(e,e->originalSublevel,&sublevelStatus))ok=NO;
                if(sublevelStatus&&!r.set_status)r.set_status=sublevelStatus;
            }
            // The retained release describes the geometry at restoration, not
            // the possibly resized geometry from first admission.
            ok=ok && spaceRestored && (!e->originalSpace||v2WindowSpace(e->who.wid)==e->originalSpace)
                && !getBounds(mainConnection(),e->who.wid,&releasedBounds) && v2FiniteRect(releasedBounds)
                && (!e->reattaching || CGRectEqualToRect(releasedBounds,e->bounds));
            ok=ok && (finalIdentity=v2RestoreIdentity(&e->who,e->owner))==DW2_INSTANCE_CURRENT;
            r.outcome=v2SpaceRestoreSettled(e,releasedBounds,ok) ? DW2_RESTORED : DW2_PENDING;
        }
        if(r.outcome==DW2_PENDING){e->state=DW2_RESTORING;pending++;}
        else {
            if(r.outcome==DW2_RESTORED){e->bounds=releasedBounds;e->reattaching=NO;e->appliedTransformKnown=NO;
                // A veil's conditional alpha was settled by this release; its mark is not an original to guard later.
                if(e->veilAlpha)e->alphaTouched=NO;
                e->veiled=e->veilBare=e->veilAlpha=NO;v2Released[wid]=e;}
            [v2Table removeObjectForKey:wid];
        }
        count++;
        [results appendBytes:&r length:sizeof(r)];
        NSMutableDictionary *receipt=[@{@"pid":@(r.id.pid),@"birth_sec":@(r.id.birth_sec),@"birth_usec":@(r.id.birth_usec),@"wid":@(r.id.wid),
            @"outcome":r.outcome==DW2_RESTORED ? @"restored" : r.outcome==DW2_GONE ? @"gone" : @"pending",@"set_status":@(r.set_status)} mutableCopy];
        if(r.outcome==DW2_PENDING) {
            // Record only calls already made above, including short-circuited
            // checks. Null statuses mean not called, never success. This is
            // explanatory journal/log metadata, not protocol or restore state.
            receipt[@"diagnostic"]=@{@"initial_identity":v2RestoreIdentityName(observed),
                @"transform_set_status":transformSet ? @(transformSetStatus) : (id)NSNull.null,
                @"transform_get_status":transformRead ? @(transformGetStatus) : (id)NSNull.null,
                @"saved_transform":matrix(e->transform),
                @"actual_transform":transformRead && !transformGetStatus && finiteMatrix(actual) ? matrix(actual) : (id)NSNull.null,
                @"transform_matches":transformRead && !transformGetStatus ? @(transformMatches) : (id)NSNull.null,
                @"alpha":e->alphaTouched ? @{@"identity_current":alphaChecked ? @(alphaCurrent) : (id)NSNull.null,
                    @"set_status":alphaSet ? @(alphaSetStatus) : (id)NSNull.null,
                    @"get_status":alphaRead ? @(alphaGetStatus) : (id)NSNull.null,
                    @"saved":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,
                    @"actual":alphaRead && !alphaGetStatus && isfinite(alpha) ? @(alpha) : (id)NSNull.null} : (id)NSNull.null,
                @"final_identity":finalIdentity>=0 ? v2RestoreIdentityName(finalIdentity) : (id)NSNull.null};
            if(e->originalSpace){NSMutableDictionary *diagnostic=[receipt[@"diagnostic"]mutableCopy];
                diagnostic[@"space"]=@{@"original":@(e->originalSpace),@"pending_target":@(e->pendingSpace),
                    @"settle_started_ms":@(e->restoreSpaceStarted),@"quiet_since_ms":@(e->restoreSpaceQuiet),
                    @"sample_current":@(e->restoreSpaceSample)};receipt[@"diagnostic"]=diagnostic;}
        }
        [report addObject:receipt];
    }
    BOOL saved=YES;
    if(count || v2JournalStale) {
        if(count)v2LastRestore=@{@"reason":reason,@"results":report};
        saved=v2Persist();v2JournalStale=!saved;
    }
    v2Count();
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->originalSpace&&e->restoreSpaceSample){v2RetryDelayMS=250;break;}
    if(atomic_load(&v2Restoring) || v2JournalStale)v2ScheduleRetry();
    else v2RetryDelayMS=250;
    if(summary)*summary=(struct dw2_restore_reply){.count=count,.pending=pending,.journal_persisted=saved};
    if(!summary && count) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"reason":reason,@"results":report,@"journal_persisted":@(saved)} options:0 error:NULL];
        fprintf(stderr,"V2_RESTORE %s\n",data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "serialization failed");
    }
}

// One frame. A record that cannot be applied fails alone. Windows not yet in the
// table are captured first and journalled together, once, before any of them is
// changed; a frame of known windows writes nothing to disk.
static void v2ApplyWithSpaces(const struct dw2_record *records,const uint64_t *targets,uint32_t count,uint8_t *status) {
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:count];
    NSMutableDictionary *replacedReleases=[NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *releasing=[NSMutableSet set];
    NSMutableData *sourceData=[NSMutableData dataWithLength:count*sizeof(uint64_t)];uint64_t *sources=sourceData.mutableBytes;
    for(uint32_t i=0;i<count;i++)if(records[i].flags==DW2_RECORD_RESTORE)[releasing addObject:@(records[i].id.wid)];
    NSMutableSet *seen=[NSMutableSet set],*duplicates=[NSMutableSet set];
    if(targets)for(uint32_t i=0;i<count;i++){NSNumber *wid=@(records[i].id.wid);if([seen containsObject:wid])[duplicates addObject:wid];[seen addObject:wid];}
    // Finish releases and confirmations of prior requests before staging any
    // new Space intent. Their journal writes must never commit another record's
    // not-yet-admitted pending target halfway through this frame.
    NSMutableData *priorData=[NSMutableData dataWithLength:count];uint8_t *prior=priorData.mutableBytes;
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];
        if(r->flags!=DW2_RECORD_RESTORE||!v2InScope(&r->id)||[duplicates containsObject:@(r->id.wid)]||(targets&&targets[i]))continue;
        DW2Entry *entry=v2Table[@(r->id.wid)];
        if(entry&&!v2SameProcess(&entry->who,&r->id)){prior[i]=DW2_IDENTITY;continue;}
        if(entry)entry->state=DW2_RESTORING;
        if(entry||v2JournalStale){struct dw2_restore_reply summary={0};v2Restore(@"window released",YES,nil,&summary);
            prior[i]=v2Table[@(r->id.wid)]?DW2_RESTORE_PENDING:summary.journal_persisted?DW2_APPLIED:DW2_JOURNAL;}
    }
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];DW2Entry *entry=v2Table[@(r->id.wid)];
        if(r->flags!=DW2_RECORD_RESTORE&&![releasing containsObject:@(r->id.wid)]&&v2InScope(&r->id)
            &&entry&&entry->pendingSpace&&v2SameProcess(&entry->who,&r->id))prior[i]=v2ConfirmSpace(entry);
    }
    BOOL changed=NO;
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];
        [entries addObject:NSNull.null];
        uint64_t target=targets?targets[i]:0;
        if([duplicates containsObject:@(r->id.wid)]||(target&&r->flags==DW2_RECORD_RESTORE)){status[i]=DW2_MALFORMED;continue;}
        if((r->flags&~(uint32_t)(DW2_RECORD_HAS_ALPHA|DW2_RECORD_RESTORE|DW2_RECORD_PINNED))
            ||((r->flags&DW2_RECORD_RESTORE)&&r->flags!=DW2_RECORD_RESTORE)){status[i]=DW2_MALFORMED;continue;}
        if(!v2InScope(&r->id)){status[i]=DW2_SCOPE;continue;}
        if(r->flags==DW2_RECORD_RESTORE){status[i]=prior[i];continue;}
        if(prior[i]!=DW2_APPLIED){status[i]=prior[i];continue;}
        // A malformed frame cannot both release and transform the same number.
        // Restoration wins, regardless of its position in that frame.
        if([releasing containsObject:@(r->id.wid)]){status[i]=DW2_RESTORE_PENDING;continue;}
        if(!finiteMatrix(CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]))){status[i]=DW2_MATRIX;continue;}
        BOOL wantsAlpha=(r->flags&DW2_RECORD_HAS_ALPHA)!=0,wantsPin=(r->flags&DW2_RECORD_PINNED)!=0;
        if(wantsPin&&!v2SublevelAPI()){status[i]=DW2_SUBLEVEL;continue;}
        if(wantsAlpha && (!setAlpha || !getAlpha || !isfinite(r->alpha) || r->alpha<0 || r->alpha>1)){status[i]=DW2_ALPHA;continue;}
        int owner=0;struct dw2_identity now={0};uid_t uid=0;
        if(!v2Resolve(r->id.wid,&owner,&now,&uid) || !v2SameProcess(&now,&r->id) || uid!=getuid()){status[i]=DW2_IDENTITY;continue;}
        uint64_t source=0;NSString *sourceDisplay=nil;
        if(target&&!v2CanMoveSpace(r->id.wid,target,&source,&sourceDisplay)){status[i]=DW2_SPACE;continue;}
        sources[i]=source;
        NSNumber *key=@(r->id.wid);
        DW2Entry *e=v2Table[key];
        if(e && !v2SameProcess(&e->who,&now)) {
            // The number now names another process's window: the recorded one is gone.
            [v2Table removeObjectForKey:key];e=nil;changed=YES;
        }
        if(e && e->owner!=owner){status[i]=DW2_IDENTITY;continue;}
        if(e && e->state==DW2_RESTORING){status[i]=DW2_RESTORE_PENDING;continue;}
        if(!e) {
            if(!v2Released[key] && v2Table.count+v2Released.count>=DW2_MAX_TABLE && v2PruneReleased())changed=YES;
            if(v2Table.count+v2Released.count-(v2Released[key]?1:0)>=DW2_MAX_TABLE){status[i]=DW2_TABLE_FULL;continue;}
            e=[DW2Entry new];e->who=now;e->owner=owner;e->state=DW2_HELD;e->fresh=YES;
            if(getTransform(mainConnection(),now.wid,&e->transform) || !finiteMatrix(e->transform) || getBounds(mainConnection(),now.wid,&e->bounds) || !v2FiniteRect(e->bounds)){status[i]=DW2_SNAPSHOT;continue;}
            // The original alpha is captured with the window, whether or not this
            // record changes it, so a later record can.
            if(getAlpha && setAlpha) {
                if(getAlpha(mainConnection(),now.wid,&e->alpha) || !isfinite(e->alpha)){status[i]=DW2_SNAPSHOT;continue;}
                e->hasAlpha=YES;
            }
            if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            if(v2Released[key]){replacedReleases[key]=v2Released[key];[v2Released removeObjectForKey:key];}
            v2Table[key]=e;changed=YES;
        }
        if(wantsPin&&!e->sublevelTouched){
            int original=0;
            if(!v2ReadSublevel(e,&original)){
                status[i]=DW2_SNAPSHOT;
                if(e->fresh){[v2Table removeObjectForKey:key];if(replacedReleases[key])v2Released[key]=replacedReleases[key];}
                continue;
            }
            e->originalSublevel=original;e->sublevelTouched=e->sublevelFresh=YES;changed=YES;
        }
        if(target&&source!=target){
            if(!e->originalSpace){e->originalSpace=source;e->originalSpaceDisplay=sourceDisplay;e->spaceFresh=YES;}
            e->pendingSpace=target;e->pendingSpaceFresh=YES;e->pendingSpaceObserved=NO;changed=YES;
        }
        if(wantsAlpha && !e->alphaTouched){e->alphaTouched=e->alphaFresh=YES;changed=YES;}
        if(e->veilBare && !e->veilBareCleared) {
            // The first frame for a window the veil only hid. Its original was read at the announcement and the application may have moved or
            // resized the window since: read it again, and make the record say a transform is now owed, before anything is written.
            CGAffineTransform current=CGAffineTransformIdentity;CGRect bounds=CGRectZero;
            if(getTransform(mainConnection(),now.wid,&current) || !finiteMatrix(current) || getBounds(mainConnection(),now.wid,&bounds) || !v2FiniteRect(bounds)){status[i]=DW2_SNAPSHOT;continue;}
            e->veilPriorTransform=e->transform;e->veilPriorBounds=e->bounds;
            e->transform=current;e->bounds=bounds;e->veilBare=NO;e->veilBareCleared=YES;changed=YES;
        }
        if(wantsAlpha && e->veilAlpha && !e->veilAlphaCleared){e->veilAlpha=NO;e->veilAlphaCleared=YES;changed=YES;}
        entries[i]=e;status[i]=DW2_APPLIED;
    }
    if(changed) {
        BOOL saved=v2Persist();
        for(uint32_t i=0;i<count;i++) {
            DW2Entry *e=entries[i];
            if((id)e==NSNull.null || !(e->fresh || e->alphaFresh || e->sublevelFresh || e->pendingSpaceFresh || e->veilBareCleared || e->veilAlphaCleared))continue;
            if(!saved) {
                // Nothing of this window (or of its alpha) is changed without a record on disk.
                status[i]=DW2_JOURNAL;entries[i]=NSNull.null;
                if(e->fresh){NSNumber *key=@(e->who.wid);[v2Table removeObjectForKey:key];if(replacedReleases[key])v2Released[key]=replacedReleases[key];}
                else {if(e->alphaFresh)e->alphaTouched=NO;
                    // The window stays veiled, with what the announcement read, and is asked again with the next frame.
                    if(e->veilBareCleared){e->transform=e->veilPriorTransform;e->bounds=e->veilPriorBounds;e->veilBare=YES;}
                    if(e->veilAlphaCleared)e->veilAlpha=YES;
                    if(e->sublevelFresh)e->sublevelTouched=NO;
                    if(e->spaceFresh){e->originalSpace=0;e->originalSpaceDisplay=nil;}
                    if(e->pendingSpaceFresh)e->pendingSpace=0;}
            }
        }
        for(DW2Entry *e in v2Table.objectEnumerator)e->fresh=e->alphaFresh=e->sublevelFresh=e->veilBareCleared=e->veilAlphaCleared=NO;
        if(!saved){v2JournalStale=YES;v2ScheduleRetry();}
    }
    BOOL spaceAttempted=NO;
#if DW_V2_BATCH_COMPILED
    // Only this explicit build variant stages transforms. Production retains
    // the scalar path until owned optical/readback/abort comparisons establish
    // the private transaction behavior on each supported OS.
    BOOL listBatch=v2UseWindowListBatch&&v2SetWindowTransforms&&count>1;
    BOOL batching=listBatch||(v2UseTransactionBatch&&count>1&&v2ForwardTransactionsAvailable());
    NSMutableData *stagedData=batching?[NSMutableData dataWithLength:count]:nil;
    uint8_t *staged=stagedData.mutableBytes;
    CFTypeRef transaction=NULL;BOOL stagedAny=NO;
#endif
    for(uint32_t i=0;i<count;i++) {
        DW2Entry *e=entries[i];
        if((id)e==NSNull.null)continue;
        const struct dw2_record *r=&records[i];
        uint64_t target=targets?targets[i]:0;
#if DW_V2_BATCH_COMPILED
        // A staged transform has no scalar mutation here: the fresh precommit
        // audit below is its mutation fence. Space operations still need theirs.
        if((!batching||target)&&!v2EntryCurrent(e)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_IDENTITY;continue;}
#else
        if(!v2EntryCurrent(e)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_IDENTITY;continue;}
#endif
        if(target){
            uint64_t current=0;
            if(!v2CanMoveSpace(e->who.wid,target,&current,NULL)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_SPACE;continue;}
            if(current!=target){
                if(current!=sources[i]||e->pendingSpace!=target||!v2EntryCurrent(e)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_IDENTITY;continue;}
                e->pendingSpaceFresh=e->spaceFresh=NO;spaceAttempted=YES;
                moveWindowsToSpace(mainConnection(),(__bridge CFArrayRef)@[@(e->who.wid)],target);
            } // A preceding root move may have carried this member already.
              // Its observed target confirms, but never erases, its original.
            uint8_t confirmed=v2ConfirmSpace(e);
            if(confirmed!=DW2_APPLIED){status[i]=confirmed;continue;}
            if(v2WindowSpace(e->who.wid)!=target||!v2EntryCurrent(e)){status[i]=DW2_NOT_APPLIED;continue;}
        }
        CGAffineTransform requested=CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]),actual=CGAffineTransformIdentity;
        // Frames stay complete, but moving one window need not rewrite every
        // unchanged neighbour. Only a previously applied request is eligible,
        // and it still needs a fresh native read and the final identity fence.
        BOOL repeated=e->appliedTransformKnown && v2SameTransform(e->appliedTransform,requested);
        BOOL ok=repeated && getTransform(mainConnection(),e->who.wid,&actual)==0 && v2SameTransform(actual,requested);
        e->appliedTransformKnown=NO;
        if(!ok){
            // The extra read above may have outlived this window. Never use its
            // cached request to authorize the corrective write to a replacement.
#if DW_V2_BATCH_COMPILED
            if(repeated && !batching && !v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            if(batching) {
                if(listBatch){staged[i]=1;stagedAny=YES;continue;}
                if(!transaction)transaction=v2TransactionCreate(mainConnection());
                if(transaction) {
                    v2TransactionSetTransform(transaction,e->who.wid,0,0,requested);
                    if(DW_V2_TRANSACTION_TRACE)fprintf(stderr,"DW_TX_STAGE wid=%u\n",e->who.wid);
                    staged[i]=1;stagedAny=YES;continue;
                }
                // Missing/create-failed transactions retain the scalar contract.
                batching=NO;
                if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            }
#else
            if(repeated && !v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
#endif
            ok=setTransform(mainConnection(),e->who.wid,requested)==0 && getTransform(mainConnection(),e->who.wid,&actual)==0 && v2SameTransform(actual,requested);
        }
#if DW_V2_BATCH_COMPILED
        status[i]=v2FinishForward(e,r,target,ok);
#else
        // Keep the ordinary scalar loop in its original shape: no batching
        // objects, nil message sends, or extracted finalization call. The only
        // optional extra behavior here is freshly verified alpha deduplication.
        BOOL alphaOK=YES;float wantAlpha=0;
        BOOL wantsAlphaWrite=v2FrameAlpha(e,r,&wantAlpha);
        if(wantsAlphaWrite) {
            if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            float actualAlpha=-1;
            BOOL repeatedAlpha=DW_V2_ALPHA_DEDUP&&e->appliedAlphaKnown&&e->appliedAlpha==wantAlpha;
            alphaOK=repeatedAlpha&&!getAlpha(mainConnection(),e->who.wid,&actualAlpha)&&actualAlpha==wantAlpha;
            e->appliedAlphaKnown=NO;
            if(!alphaOK) {
                if(repeatedAlpha&&!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
                alphaOK=!setAlpha(mainConnection(),e->who.wid,wantAlpha)
                    &&!getAlpha(mainConnection(),e->who.wid,&actualAlpha)&&actualAlpha==wantAlpha;
            }
            if(!alphaOK)ok=NO;else e->veiled=NO;
        }
        if(e->sublevelTouched) {
            int requestedSublevel=(r->flags&DW2_RECORD_PINNED)?CGWindowLevelForKey(kCGFloatingWindowLevelKey):e->originalSublevel;
            int sublevelStatus=0;if(!v2ApplySublevel(e,requestedSublevel,&sublevelStatus))ok=NO;
        }
        BOOL spaceOK=!target||(v2WindowSpace(e->who.wid)==target&&v2SpaceDisplay(target,YES));
        if(!v2EntryCurrent(e))status[i]=DW2_IDENTITY;
        else if(!spaceOK||!ok)status[i]=DW2_NOT_APPLIED;
        else {
            e->appliedTransform=requested;e->appliedTransformKnown=YES;
            if(wantsAlphaWrite){e->appliedAlpha=wantAlpha;e->appliedAlphaKnown=alphaOK;}
        }
#endif
    }
#if DW_V2_BATCH_COMPILED
    if(stagedAny) {
        // No staged record is mutated if any exact identity changed. The native
        // list uses only local buffers until its call. Transaction cancellation
        // is release-without-commit, independently checked on the owned fixture.
        BOOL current=YES;
        for(uint32_t i=0;i<count;i++)if(staged[i]&&!v2EntryCurrent(entries[i]))current=NO;
        BOOL submitted=current;
        if(listBatch&&current) {
            NSMutableData *widsData=[NSMutableData dataWithLength:count*sizeof(uint32_t)];
            NSMutableData *matricesData=[NSMutableData dataWithLength:count*sizeof(CGAffineTransform)];
            uint32_t *wids=widsData.mutableBytes;CGAffineTransform *matrices=matricesData.mutableBytes;uint32_t nativeCount=0;
            for(uint32_t i=0;i<count;i++)if(staged[i]) {
                const struct dw2_record *r=&records[i];wids[nativeCount]=r->id.wid;
                matrices[nativeCount++]=CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]);
            }
            CGError result=v2SetWindowTransforms(mainConnection(),wids,matrices,nativeCount);submitted=!result;
            if(DW_V2_TRANSACTION_TRACE)fprintf(stderr,"DW_WINDOW_LIST count=%u status=%d\n",nativeCount,result);
        } else if(transaction) {
            if(current)v2TransactionCommit(transaction,DW_V2_TRANSACTION_SYNC);
            if(DW_V2_TRANSACTION_TRACE)fprintf(stderr,"DW_TX_COMMIT submitted=%d sync=%d\n",current,DW_V2_TRANSACTION_SYNC);
        }
        if(transaction)CFRelease(transaction);
        for(uint32_t i=0;i<count;i++)if(staged[i]) {
            DW2Entry *e=entries[i];
            if(!submitted){status[i]=v2EntryCurrent(e)?DW2_NOT_APPLIED:DW2_IDENTITY;continue;}
            const struct dw2_record *r=&records[i];
            CGAffineTransform requested=CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]),actual=CGAffineTransformIdentity;
            BOOL ok=!getTransform(mainConnection(),e->who.wid,&actual)&&v2SameTransform(actual,requested);
            status[i]=v2FinishForward(e,r,targets?targets[i]:0,ok);
        }
    }
#endif // DW_V2_BATCH_COMPILED
    for(DW2Entry *e in v2Table.objectEnumerator)e->spaceFresh=e->pendingSpaceFresh=NO;
    v2Count();
}

static void v2Apply(const struct dw2_record *records,uint32_t count,uint8_t *status) { v2ApplyWithSpaces(records,NULL,count,status); }

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
static void v2Veil(uint32_t wid) {
    if(!atomic_load(&v2VeilOn) || !wid || !v2Table)return;
    NSNumber *key=@(wid);
    // A window the table or a release already knows is the shell's to place, not an arrival.
    if(v2Table[key] || v2Released[key] || !v2VeilEligible(wid))return;
    int owner=0;struct dw2_identity who={0};uid_t uid=0;
    if(!v2Resolve(wid,&owner,&who,&uid) || uid!=getuid() || !v2InScope(&who) || who.pid==getpid() || who.pid==atomic_load(&v2VeilClient))return;
    DW2Entry *e=[DW2Entry new];e->who=who;e->owner=owner;e->state=DW2_HELD;
    if(getTransform(mainConnection(),wid,&e->transform) || !finiteMatrix(e->transform) || getBounds(mainConnection(),wid,&e->bounds) || !v2FiniteRect(e->bounds)
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
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->veiled && e->state==DW2_HELD)e->state=DW2_RESTORING;
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

static NSData *v2Enrollment(void) {
    struct dw2_enrollment_reply head={.scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.server_pid=getpid()};
    NSMutableData *reply=[NSMutableData dataWithLength:sizeof(head)];
    if(fixtureOnly){
        struct dw2_process own={.pid=getpid(),.birth_sec=[fixtureIdentity[@"birth_sec"]unsignedLongLongValue],.birth_usec=[fixtureIdentity[@"birth_usec"]unsignedLongLongValue]};
        [reply appendBytes:&own length:sizeof(own)];head.count=1;
    }else for(NSDictionary *entry in allowlist){
        struct dw2_process process={.pid=[entry[@"pid"]intValue],.birth_sec=[entry[@"birth_sec"]unsignedLongLongValue],.birth_usec=[entry[@"birth_usec"]unsignedLongLongValue]};
        [reply appendBytes:&process length:sizeof(process)];head.count++;
    }
    memcpy(reply.mutableBytes,&head,sizeof(head));return reply;
}
static BOOL v2FiniteRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        && r.size.width>0 && r.size.height>0;
}
// Inspect is independent of the held-window table. It can read originals before
// first touch and verify restoration after removal without claiming the window.
static struct dw2_inspect_reply v2Inspect(struct dw2_identity requested) {
    struct dw2_inspect_reply reply={.id=requested,.status=DW2_SCOPE};
    if(!v2InScope(&requested))return reply;
    reply.status=DW2_IDENTITY;
    if(requested.pid<=0 || !requested.wid || !requested.birth_sec || requested.birth_usec>=1000000)return reply;
    int owner=0;struct dw2_identity before={0},after={0};uid_t uid=0;
    if(!v2Resolve(requested.wid,&owner,&before,&uid) || uid!=getuid() || !v2SameProcess(&before,&requested))return reply;
    CGAffineTransform transform={0};CGRect bounds=CGRectZero,screen=CGRectZero;
    reply.status=DW2_SNAPSHOT;
    if(getTransform(mainConnection(),requested.wid,&transform) || getBounds(mainConnection(),requested.wid,&bounds)
        || getScreenRect(mainConnection(),requested.wid,&screen) || !finiteMatrix(transform) || !v2FiniteRect(bounds) || !v2FiniteRect(screen))return reply;
    int afterOwner=0;
    reply.status=DW2_IDENTITY;
    if(!v2Resolve(requested.wid,&afterOwner,&after,&uid) || uid!=getuid() || owner!=afterOwner || !v2SameProcess(&after,&requested) || !v2InScope(&after))return reply;
    reply.status=DW2_APPLIED;reply.owner=owner;
    memcpy(reply.transform,(double[]){transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty},sizeof(reply.transform));
    memcpy(reply.bounds,(double[]){bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height},sizeof(reply.bounds));
    memcpy(reply.screen_rect,(double[]){screen.origin.x,screen.origin.y,screen.size.width,screen.size.height},sizeof(reply.screen_rect));
    return reply;
}
static NSData *v2Probe(void) {
    struct dw2_probe_reply head={.scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.caps=v2Caps(),
        .queue=v2OnMain ? DW2_QUEUE_MAIN : DW2_QUEUE_OWN,.lease_ms=DW2_LEASE_MS,.server_pid=getpid(),.held=atomic_load(&v2Held),.restoring=atomic_load(&v2Restoring),.journal_pending=v2JournalStale,
        .frames_received=atomic_load(&v2FramesReceived),.frames_applied=atomic_load(&v2FramesApplied),.frames_superseded=atomic_load(&v2FramesSuperseded),.journal_writes=atomic_load(&v2JournalWrites),
        .table_count=(uint32_t)v2Table.count,.fixture_count=fixtureOnly ? fixtureCount : 0};
    NSMutableData *reply=[NSMutableData dataWithBytes:&head length:sizeof(head)];
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        struct dw2_probe_entry p={.id=e->who,.state=e->state,.alpha=-1};
        CGAffineTransform t={0};CGRect r=CGRectZero;
        if(getTransform(mainConnection(),e->who.wid,&t)==0){p.transform[0]=t.a;p.transform[1]=t.b;p.transform[2]=t.c;p.transform[3]=t.d;p.transform[4]=t.tx;p.transform[5]=t.ty;}
        if(getScreenRect(mainConnection(),e->who.wid,&r)==0){p.screen_rect[0]=r.origin.x;p.screen_rect[1]=r.origin.y;p.screen_rect[2]=r.size.width;p.screen_rect[3]=r.size.height;}
        if(getAlpha)getAlpha(mainConnection(),e->who.wid,&p.alpha);
        [reply appendBytes:&p length:sizeof(p)];
    }
    // Cooperative scope only: the host's own windows, so a test can name them.
    for(uint32_t i=0;i<head.fixture_count;i++) {
        int owner=0;struct dw2_identity who={.wid=fixtureWids[i]};uid_t uid=0;
        v2Resolve(fixtureWids[i],&owner,&who,&uid);
        [reply appendBytes:&who length:sizeof(who)];
    }
    return reply;
}

// Replies are written without ever waiting long for a reader: a client that does
// not take its replies within a quarter second loses the connection, and for the
// control connection that ends the session and restores everything.
static BOOL v2Send(DW2Connection *c,uint16_t type,uint64_t seq,const void *body,size_t length) {
    struct dw2_header header={.length=(uint32_t)length,.type=type|DW2_REPLY,.seq=seq};
    struct iovec parts[2]={{&header,sizeof(header)},{(void *)body,length}};
    uint64_t deadline=v2Now()+250;
    pthread_mutex_lock(&c->writeLock);
    BOOL ok=!atomic_load(&c->closed);
    while(ok && parts[0].iov_len+parts[1].iov_len) {
        ssize_t n=writev(c->fd,parts,2);
        if(n<0 && errno==EINTR)continue;
        if(n<0 && errno==EAGAIN) {
            int remaining=(int)((int64_t)deadline-(int64_t)v2Now());
            struct pollfd p={.fd=c->fd,.events=POLLOUT};
            if(remaining<=0 || (poll(&p,1,remaining)<0 && errno!=EINTR))ok=NO;
            continue;
        }
        if(n<=0){ok=NO;break;}
        for(int i=0;i<2 && n;i++) {
            size_t part=MIN((size_t)n,parts[i].iov_len);
            parts[i].iov_base=(char *)parts[i].iov_base+part;parts[i].iov_len-=part;n-=part;
        }
    }
    if(!ok && !atomic_exchange(&c->closed,true))shutdown(c->fd,SHUT_RDWR);
    pthread_mutex_unlock(&c->writeLock);
    return ok;
}

// Takes the newest frame, if no later request has discarded it, and applies it.
// One of these is queued per frame received; all but the one that finds the slot
// full return at once, so the queue never holds work for a frame already replaced.
static void v2Drain(uint64_t barrier) {
    pthread_mutex_lock(&v2Lock);
    NSData *frame=barrier==v2Barrier ? v2Slot : nil;
    DW2Connection *c=v2SlotOwner;
    uint64_t seq=v2SlotSeq;
    uint16_t type=v2SlotType;
    struct dw2_frame_reply head={.disposition=DW2_FRAME_APPLIED,.superseded=v2SupersededPending};
    if(frame){v2Slot=nil;v2SlotOwner=nil;v2SupersededPending=0;}
    pthread_mutex_unlock(&v2Lock);
    if(!frame)return;
    BOOL spaces=type==DW2_FRAME_SPACE;
    head.count=(uint32_t)(frame.length/(spaces?sizeof(struct dw2_space_record):sizeof(struct dw2_record)));
    NSMutableData *reply=[NSMutableData dataWithLength:sizeof(head)+head.count];
    if(spaces){
        NSMutableData *base=[NSMutableData dataWithLength:head.count*sizeof(struct dw2_record)];
        NSMutableData *targets=[NSMutableData dataWithLength:head.count*sizeof(uint64_t)];
        const struct dw2_space_record *extended=frame.bytes;
        for(uint32_t i=0;i<head.count;i++){((struct dw2_record *)base.mutableBytes)[i]=extended[i].record;((uint64_t *)targets.mutableBytes)[i]=extended[i].target_space;}
        v2ApplyWithSpaces(base.bytes,targets.bytes,head.count,(uint8_t *)reply.mutableBytes+sizeof(head));
    }else v2Apply(frame.bytes,head.count,(uint8_t *)reply.mutableBytes+sizeof(head));
    head.frames_applied=atomic_fetch_add(&v2FramesApplied,1)+1;
    memcpy(reply.mutableBytes,&head,sizeof(head));
    v2Send(c,type,seq,reply.bytes,reply.length);
}
// Called with v2Lock held. The frame in the slot will never be applied.
static BOOL v2Discard(uint64_t *seq,uint32_t *superseded,uint16_t *type) {
    BOOL had=v2Slot!=nil;
    *seq=v2SlotSeq;*superseded=v2SupersededPending;if(type)*type=v2SlotType;
    v2Slot=nil;v2SlotOwner=nil;v2SupersededPending=0;v2Barrier++;
    if(had)atomic_fetch_add(&v2FramesSuperseded,1);
    return had;
}
static void v2SendDropped(DW2Connection *c,uint64_t seq,uint32_t superseded,uint16_t type) {
    struct dw2_frame_reply head={.disposition=DW2_FRAME_DROPPED,.superseded=superseded,.frames_applied=atomic_load(&v2FramesApplied)};
    v2Send(c,type,seq,&head,sizeof(head));
}

static BOOL v2Hello(DW2Connection *c,const struct dw2_header *h,const void *body) {
    struct dw2_hello_reply reply={.status=DW2_HELLO_OK,.lease_ms=DW2_LEASE_MS,.max_records=DW2_MAX_RECORDS,.max_body=DW2_MAX_BODY,.caps=v2Caps(),
        .scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.queue=v2OnMain ? DW2_QUEUE_MAIN : DW2_QUEUE_OWN,.server_pid=getpid()};
    struct dw2_hello hello;
    if(h->type!=DW2_HELLO)return NO;
    if(h->length!=sizeof(hello))reply.status=DW2_HELLO_MALFORMED;
    else {
        memcpy(&hello,body,sizeof(hello));
        if(memcmp(hello.magic,DW2_MAGIC,4) || hello.version!=DW2_VERSION)reply.status=DW2_HELLO_VERSION;
        else if(memcmp(hello.nonce,secret.UTF8String,64))reply.status=DW2_HELLO_AUTH;
        else if(hello.role!=DW2_ROLE_CONTROL && hello.role!=DW2_ROLE_HEARTBEAT)reply.status=DW2_HELLO_MALFORMED;
        else {
            pthread_mutex_lock(&v2Lock);
            if(hello.role==DW2_ROLE_CONTROL) {
                // One session at a time: its end restores everything it placed.
                if(v2Session)reply.status=DW2_HELLO_BUSY;
                else {
                    v2Session=++v2Sessions;v2Beats=[NSMutableArray array];
                    arc4random_buf(v2Token,sizeof(v2Token));
                    // The client's own windows are never veiled; without its process there is no veil.
                    pid_t peer=0;socklen_t peerSize=sizeof(peer);
                    if(getsockopt(c->fd,SOL_LOCAL,LOCAL_PEERPID,&peer,&peerSize)||peerSize!=sizeof(peer)||peer<=1)peer=0;
                    atomic_store(&v2VeilClient,peer);
                    atomic_store(&v2VeilOn,false);
                }
            } else if(!v2Session || memcmp(hello.token,v2Token,sizeof(v2Token)))reply.status=DW2_HELLO_TOKEN;
            else [v2Beats addObject:c];
            if(!reply.status) {
                c->role=hello.role;c->session=v2Session;memcpy(reply.token,v2Token,sizeof(v2Token));
                atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
            }
            pthread_mutex_unlock(&v2Lock);
        }
    }
    return v2Send(c,DW2_HELLO,h->seq,&reply,sizeof(reply)) && !reply.status;
}
// NO is a protocol error: the connection ends, and with it, for the control
// connection, the session.
static BOOL v2Handle(DW2Connection *c,const struct dw2_header *h,const void *body) {
    if(!c->role)return v2Hello(c,h,body);
    if(h->type==DW2_HEARTBEAT) {
        if(h->length)return NO;
        pthread_mutex_lock(&v2Lock);
        BOOL live=c->session==v2Session;
        if(live)atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        pthread_mutex_unlock(&v2Lock);
        if(!live)return NO;
        // Answered here, from counters: a stalled apply queue never delays a heartbeat.
        struct dw2_heartbeat_reply reply={.status=0,.lease_ms=DW2_LEASE_MS,.held=atomic_load(&v2Held),.restoring=atomic_load(&v2Restoring)};
        return v2Send(c,DW2_HEARTBEAT,h->seq,&reply,sizeof(reply));
    }
    if(c->role!=DW2_ROLE_CONTROL)return NO;
    uint64_t seq=h->seq;
    if(h->type==DW2_INSPECT) {
        if(h->length!=sizeof(struct dw2_identity))return NO;
        struct dw2_identity requested;memcpy(&requested,body,sizeof(requested));
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        dispatch_async(v2q,^{struct dw2_inspect_reply reply=v2Inspect(requested);v2Send(c,DW2_INSPECT,seq,&reply,sizeof(reply));});
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->type==DW2_VEIL) {
        struct dw2_veil request;
        if(h->length!=sizeof(request))return NO;
        memcpy(&request,body,sizeof(request));
        if(request.reserved || request.mode>1)return NO;
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        dispatch_async(v2q,^{
            // The session may have ended since the request was read: it then enables nothing. Checked and stored under the lock the
            // session's end takes to clear it, so no interleaving leaves the veil on for a session that is gone.
            struct dw2_veil_reply reply={.status=DW2_SCOPE,.timeout_ms=DW2_VEIL_TIMEOUT_MS};
            pthread_mutex_lock(&v2Lock);
            BOOL allowed=c->session==v2Session && (!request.mode || (v2VeilAvailable() && atomic_load(&v2VeilClient)));
            if(allowed){atomic_store(&v2VeilOn,request.mode!=0);reply.status=DW2_APPLIED;}
            pthread_mutex_unlock(&v2Lock);
            if(allowed && !request.mode)v2VeilRelease();
            v2Send(c,DW2_VEIL,seq,&reply,sizeof(reply));
        });
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->type==DW2_FRAME||h->type==DW2_FRAME_SPACE) {
        BOOL spaces=h->type==DW2_FRAME_SPACE;
        if(spaces&&!v2SpaceAPI())return NO;
        struct dw2_frame head;
        if(h->length<sizeof(head))return NO;
        memcpy(&head,body,sizeof(head));
        size_t stride=spaces?sizeof(struct dw2_space_record):sizeof(struct dw2_record);
        if(head.reserved || head.count>DW2_MAX_RECORDS || h->length!=sizeof(head)+(size_t)head.count*stride || seq<=c->lastFrame)return NO;
        c->lastFrame=seq;
        NSData *frame=[NSData dataWithBytes:(const char *)body+sizeof(head) length:h->length-sizeof(head)];
        atomic_fetch_add(&v2FramesReceived,1);
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        // Newest wins: a frame not yet taken is replaced, never queued behind.
        if(v2Slot){v2SupersededPending++;atomic_fetch_add(&v2FramesSuperseded,1);}
        v2Slot=frame;v2SlotSeq=seq;v2SlotOwner=c;v2SlotType=h->type;
        uint64_t barrier=v2Barrier;
        dispatch_async(v2q,^{v2Drain(barrier);});
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->length || (h->type!=DW2_RESTORE_ALL && h->type!=DW2_PROBE && h->type!=DW2_ENROLLMENT))return NO;
    pthread_mutex_lock(&v2Lock);
    atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
    if(h->type==DW2_PROBE)dispatch_async(v2q,^{NSData *reply=v2Probe();v2Send(c,DW2_PROBE,seq,reply.bytes,reply.length);});
    else if(h->type==DW2_ENROLLMENT)dispatch_async(v2q,^{NSData *reply=v2Enrollment();v2Send(c,DW2_ENROLLMENT,seq,reply.bytes,reply.length);});
    else {
        // A frame still waiting is older than this request and must not follow it.
        uint64_t droppedSeq;uint32_t superseded;uint16_t droppedType;
        BOOL dropped=v2Discard(&droppedSeq,&superseded,&droppedType);
        dispatch_async(v2q,^{
            if(dropped)v2SendDropped(c,droppedSeq,superseded,droppedType);
            struct dw2_restore_reply summary;
            NSMutableData *reply=[NSMutableData dataWithLength:sizeof(summary)];
            v2Restore(@"explicit",NO,reply,&summary);
            memcpy(reply.mutableBytes,&summary,sizeof(summary));
            v2Send(c,DW2_RESTORE_ALL,seq,reply.bytes,reply.length);
        });
    }
    pthread_mutex_unlock(&v2Lock);
    return YES;
}
static void *v2Serve(void *argument) { @autoreleasepool {
    DW2Connection *c=(__bridge_transfer DW2Connection *)argument;
    const size_t capacity=sizeof(struct dw2_header)+DW2_MAX_BODY+65536;
    char *buffer=malloc(capacity);size_t used=0;
    uint64_t helloDeadline=v2Now()+DW2_LEASE_MS;
    NSString *reason=@"disconnect";
    while(buffer && !atomic_load(&c->closed)) {
        // The control connection carries the lease, which a heartbeat on the second
        // connection also renews: on a timeout the deadline is simply read again.
        int remaining=-1;
        if(c->role!=DW2_ROLE_HEARTBEAT) {
            int64_t left=(int64_t)(c->role ? atomic_load(&v2Deadline) : helloDeadline)-(int64_t)v2Now();
            if(left<=0){reason=@"lease expired";break;}
            remaining=(int)left;
        }
        struct pollfd p={.fd=c->fd,.events=POLLIN};
        int ready=poll(&p,1,remaining);
        if(ready<0 && errno!=EINTR)break;
        if(ready<=0)continue;
        ssize_t n=read(c->fd,buffer+used,MIN((size_t)65536,capacity-used));
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
        if(n<=0)break;
        used+=n;
        size_t offset=0;BOOL ok=YES;
        while(ok && used-offset>=sizeof(struct dw2_header)) { @autoreleasepool {
            struct dw2_header h;memcpy(&h,buffer+offset,sizeof(h));
            if(h.flags || h.length>DW2_MAX_BODY || (h.type&DW2_REPLY)){ok=NO;reason=@"protocol error";break;}
            if(used-offset<sizeof(h)+h.length)break;
            if(!v2Handle(c,&h,buffer+offset+sizeof(h))){ok=NO;reason=@"protocol error";break;}
            offset+=sizeof(h)+h.length;
        } }
        if(!ok)break;
        memmove(buffer,buffer+offset,used-offset);used-=offset;
    }
    free(buffer);
    pthread_mutex_lock(&v2Lock);
    if(c->role==DW2_ROLE_HEARTBEAT)[v2Beats removeObject:c];
    else if(c->role==DW2_ROLE_CONTROL) {
        // End of session, whatever the cause: nothing it placed outlives it. Queued
        // under the lock, so no request of a later session can precede the restore.
        NSArray<DW2Connection *> *beats=v2Beats;
        uint64_t droppedSeq;uint32_t superseded;
        v2Discard(&droppedSeq,&superseded,NULL);
        v2Beats=nil;v2Session=0;
        // No veil outlives its session: the restore queued below releases what it still holds.
        atomic_store(&v2VeilOn,false);atomic_store(&v2VeilClient,0);
        for(DW2Connection *beat in beats)if(!atomic_exchange(&beat->closed,true))shutdown(beat->fd,SHUT_RDWR);
        dispatch_async(v2q,^{v2Restore(reason,NO,nil,NULL);});
    }
    pthread_mutex_unlock(&v2Lock);
    if(!atomic_exchange(&c->closed,true))shutdown(c->fd,SHUT_RDWR);
    atomic_fetch_sub(&v2Connections,1);
    return NULL;
} }

// A journal left by an instance that died holding windows. Each recorded window is
// restored only if its whole recorded identity still resolves to the same process
// instance and passes this instance's scope; the value written is the one captured
// before any helper touched it. A bare window number is never trusted.
static BOOL v2Keys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:value.allKeys]isEqual:[NSSet setWithArray:keys]];
}
static BOOL v2Integer(id value,uint64_t minimum,uint64_t maximum) {
    return isNumber(value) && !CFNumberIsFloatType((__bridge CFNumberRef)value)
        && [value compare:@(minimum)]!=NSOrderedAscending && [value compare:@(maximum)]!=NSOrderedDescending;
}
static BOOL v2Boolean(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID(); }
static BOOL v2LastRestoreValid(id value) {
    if(value==NSNull.null)return YES;
    if(!v2Keys(value,@[@"reason",@"results"]) || ![value[@"reason"]isKindOfClass:NSString.class] || ![value[@"reason"]length]
        || ![value[@"results"]isKindOfClass:NSArray.class] || [value[@"results"]count]>DW2_MAX_TABLE)return NO;
    NSMutableSet *windows=[NSMutableSet set];
    for(NSDictionary *r in value[@"results"]) {
        if(![r isKindOfClass:NSDictionary.class])return NO;
        // Diagnostics never authorize writes and cannot make valid originals
        // unrecoverable. Keep validating the original restoration receipt only.
        NSMutableDictionary *fields=[r mutableCopy];[fields removeObjectForKey:@"diagnostic"];
        if(!v2Keys(fields,@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"outcome",@"set_status"])
            || !v2Integer(r[@"pid"],1,INT_MAX) || !v2Integer(r[@"birth_sec"],1,UINT64_MAX) || !v2Integer(r[@"birth_usec"],0,999999)
            || !v2Integer(r[@"wid"],1,UINT32_MAX) || !isNumber(r[@"set_status"]) || CFNumberIsFloatType((__bridge CFNumberRef)r[@"set_status"])
            || [r[@"set_status"]compare:@(INT_MIN)]==NSOrderedAscending || [r[@"set_status"]compare:@(INT_MAX)]==NSOrderedDescending
            || ![@[@"restored",@"gone",@"pending"]containsObject:r[@"outcome"]] || [windows containsObject:r[@"wid"]])return NO;
        [windows addObject:r[@"wid"]];
    }
    return YES;
}
// Schema 3 preserves released originals for a later, explicitly authorized
// connection handoff. No schema-2 journal can establish that missing obligation.
static NSArray *v2WriterKeys(void) {
    return @[@"server_pid",@"server_birth_sec",@"server_birth_usec",@"server_uid",@"boot_uuid"];
}
static BOOL v2BootUUIDValid(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=36)return NO;
    for(NSUInteger i=0;i<36;i++) {
        unichar c=[value characterAtIndex:i];
        if(i==8 || i==13 || i==18 || i==23){if(c!='-')return NO;}
        else if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return NO;
    }
    return YES;
}
static BOOL v2WriterValid(NSDictionary *value) {
    return v2Integer(value[@"server_pid"],1,INT_MAX) && v2Integer(value[@"server_birth_sec"],1,UINT64_MAX)
        && v2Integer(value[@"server_birth_usec"],0,999999) && v2Integer(value[@"server_uid"],0,UINT32_MAX)
        && v2BootUUIDValid(value[@"boot_uuid"]);
}
static NSDictionary *v2CurrentWriterIdentity(void) {
    struct proc_bsdinfo process={0};char boot[37]={0};size_t length=sizeof(boot);
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process)
        || process.pbi_uid!=getuid() || sysctlbyname("kern.bootsessionuuid",boot,&length,NULL,0) || length!=sizeof(boot)
        || boot[36]!='\0' || !process.pbi_start_tvsec)return nil;
    // Unlike calendar boottime, this kernel identity does not move when the
    // wall clock changes. Persist only its exact canonical uppercase spelling.
    NSString *bootUUID=[[NSString alloc]initWithBytes:boot length:36 encoding:NSASCIIStringEncoding];
    if(!v2BootUUIDValid(bootUUID))return nil;
    return @{@"server_pid":@(getpid()),@"server_birth_sec":@(process.pbi_start_tvsec),@"server_birth_usec":@(process.pbi_start_tvusec),
        @"server_uid":@(getuid()),@"boot_uuid":bootUUID};
}
static BOOL v2WriterSame(NSDictionary *a,NSDictionary *b) {
    for(NSString *key in v2WriterKeys())if(![a[key]isEqual:b[key]])return NO;
    return YES;
}
static BOOL v2OldWriterDead(NSDictionary *writer) {
    int pid=[writer[@"server_pid"]intValue];struct proc_bsdinfo process={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process))
        return process.pbi_start_tvsec!=[writer[@"server_birth_sec"]unsignedLongLongValue]
            || process.pbi_start_tvusec!=[writer[@"server_birth_usec"]unsignedLongLongValue];
    // An inaccessible process is not dead. ESRCH is affirmative kernel absence.
    errno=0;return kill(pid,0)<0 && errno==ESRCH;
}
static BOOL v2RetiredWriter(NSDictionary *writer) {
    return [writer[@"server_uid"]isEqual:v2WriterIdentity[@"server_uid"]]
        && [writer[@"boot_uuid"]isEqual:v2WriterIdentity[@"boot_uuid"]]
        && !v2WriterSame(writer,v2WriterIdentity) && v2OldWriterDead(writer);
}
static BOOL v2RecoveryConfigValid(NSDictionary *config) {
    NSArray *keys=@[@"recovery_source_sha256",@"recovery_server_pid",@"recovery_server_birth_sec",@"recovery_server_birth_usec",
        @"recovery_server_uid",@"recovery_boot_uuid"];
    NSUInteger count=0;
    for(NSString *key in config)if([key hasPrefix:@"recovery_"]){if(![keys containsObject:key])return NO;count++;}
    if(!count)return YES;
    NSString *hash=config[@"recovery_source_sha256"];
    if(count!=keys.count || ![hash isKindOfClass:NSString.class] || hash.length!=64)return NO;
    for(NSUInteger i=0;i<hash.length;i++){unichar c=[hash characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return NO;}
    NSMutableDictionary *writer=[NSMutableDictionary dictionary];
    for(NSString *key in v2WriterKeys())writer[key]=config[[@"recovery_"stringByAppendingString:key]];
    return v2WriterValid(writer);
}
static NSData *v2ReadJournal(const char *name,BOOL *absent) {
    *absent=NO;int fd=openat(directoryFD,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0){*absent=errno==ENOENT;return nil;}
    struct stat st;
    if(fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&0777)!=0600
        || st.st_size<=0 || st.st_size>4*1024*1024){close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];char chunk[4096];ssize_t n;
    for(;;){n=read(fd,chunk,sizeof(chunk));if(n<0&&errno==EINTR)continue;if(n<=0)break;
        [data appendBytes:chunk length:n];if(data.length>4*1024*1024){n=-1;break;}}
    close(fd);return n==0 && data.length==(NSUInteger)st.st_size ? data : nil;
}
static BOOL v2RemoveStaging(void) {
    struct stat stage;
    if(fstatat(directoryFD,"v2-journal.next",&stage,AT_SYMLINK_NOFOLLOW)==0) {
        if(!S_ISREG(stage.st_mode) || stage.st_uid!=getuid() || (stage.st_mode&0777)!=0600)return NO;
        return !unlinkat(directoryFD,"v2-journal.next",0) && !fsync(directoryFD);
    }
    return errno==ENOENT;
}
static DW2Entry *v2DecodeEntry(NSDictionary *w,BOOL released) {
    NSArray *keys=@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"owner",@"transform",@"alpha",@"alpha_touched",@"bounds",@"state"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"original_space"])keys=[keys arrayByAddingObject:@"original_space"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"original_sublevel"])keys=[keys arrayByAddingObject:@"original_sublevel"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"veil_bare"])keys=[keys arrayByAddingObject:@"veil_bare"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"veil_alpha"])keys=[keys arrayByAddingObject:@"veil_alpha"];
    if(!v2Keys(w,keys)
        || !v2Integer(w[@"pid"],1,INT_MAX) || !v2Integer(w[@"birth_sec"],1,UINT64_MAX) || !v2Integer(w[@"birth_usec"],0,999999)
        || !v2Integer(w[@"wid"],1,UINT32_MAX) || !v2Integer(w[@"owner"],1,INT_MAX) || !v2Boolean(w[@"alpha_touched"])
        || !(released ? [w[@"state"]isEqual:@"released"] : [@[@"held",@"restoring",@"reattaching"]containsObject:w[@"state"]]))return nil;
    NSArray *t=w[@"transform"],*b=w[@"bounds"];
    if(![t isKindOfClass:NSArray.class] || t.count!=6 || ![b isKindOfClass:NSArray.class] || b.count!=4)return nil;
    for(id value in [t arrayByAddingObjectsFromArray:b])if(!isNumber(value) || !isfinite([value doubleValue]))return nil;
    DW2Entry *e=[DW2Entry new];
    e->who=(struct dw2_identity){.pid=[w[@"pid"]intValue],.wid=[w[@"wid"]unsignedIntValue],.birth_sec=[w[@"birth_sec"]unsignedLongLongValue],.birth_usec=[w[@"birth_usec"]unsignedLongLongValue]};
    e->owner=[w[@"owner"]intValue];e->state=DW2_RESTORING;e->reattaching=[w[@"state"]isEqual:@"reattaching"];
    e->transform=CGAffineTransformMake([t[0]doubleValue],[t[1]doubleValue],[t[2]doubleValue],[t[3]doubleValue],[t[4]doubleValue],[t[5]doubleValue]);
    e->bounds=CGRectMake([b[0]doubleValue],[b[1]doubleValue],[b[2]doubleValue],[b[3]doubleValue]);
    if(!finiteMatrix(e->transform) || !v2FiniteRect(e->bounds))return nil;
    if(w[@"alpha"]!=NSNull.null) {
        if(!isNumber(w[@"alpha"]) || !isfinite([w[@"alpha"]doubleValue]) || [w[@"alpha"]doubleValue]<0 || [w[@"alpha"]doubleValue]>1)return nil;
        e->alpha=[w[@"alpha"]floatValue];e->hasAlpha=YES;
    }
    e->alphaTouched=[w[@"alpha_touched"]boolValue];
    if(e->alphaTouched && (!e->hasAlpha || !setAlpha || !getAlpha))return nil;
    // Marks of an arrival veil: only an active, never-released entry has them, and the alpha mark needs its alpha obligation.
    if(w[@"veil_bare"]||w[@"veil_alpha"]){
        if((w[@"veil_bare"]&&(!v2Boolean(w[@"veil_bare"])||![w[@"veil_bare"]boolValue]))||(w[@"veil_alpha"]&&(!v2Boolean(w[@"veil_alpha"])||![w[@"veil_alpha"]boolValue]||!e->alphaTouched))||released)return nil;
        e->veilBare=[w[@"veil_bare"]boolValue];e->veilAlpha=[w[@"veil_alpha"]boolValue];
    }
    id sublevel=w[@"original_sublevel"];
    if(sublevel){
        // Unlike identity fields, a signed sublevel can be negative.
        if(!isNumber(sublevel)||CFNumberIsFloatType((__bridge CFNumberRef)sublevel)
            ||[sublevel compare:@(INT_MIN)]==NSOrderedAscending||[sublevel compare:@(INT_MAX)]==NSOrderedDescending||!v2SublevelAPI())return nil;
        e->originalSublevel=[sublevel intValue];e->sublevelTouched=YES;
    }
    NSDictionary *space=w[@"original_space"];
    if(space) {
        if(!v2Keys(space,@[@"id",@"display",@"pending_target"])||!v2Integer(space[@"id"],1,UINT64_MAX)
            ||!v2Integer(space[@"pending_target"],0,UINT64_MAX)||!v2BootUUIDValid(space[@"display"])
            ||(released&&[space[@"pending_target"]unsignedLongLongValue]))return nil;
        e->originalSpace=[space[@"id"]unsignedLongLongValue];e->originalSpaceDisplay=space[@"display"];
        e->pendingSpace=[space[@"pending_target"]unsignedLongLongValue];
    }
    return e;
}
static NSDictionary *v2DecodeJournal(NSData *data,NSMutableDictionary *active,NSMutableDictionary *released) {
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *keys=[v2WriterKeys()arrayByAddingObjectsFromArray:@[@"v",@"generation",@"state",@"windows",@"released_windows",@"last_restore"]];
    if(!v2Keys(journal,keys) || !v2Integer(journal[@"v"],3,3) || !v2WriterValid(journal) || !v2Integer(journal[@"generation"],0,UINT64_MAX-1)
        || ![journal[@"windows"]isKindOfClass:NSArray.class] || ![journal[@"released_windows"]isKindOfClass:NSArray.class]
        || [journal[@"windows"]count]+[journal[@"released_windows"]count]>DW2_MAX_TABLE || !v2LastRestoreValid(journal[@"last_restore"]))return nil;
    BOOL restoring=NO;
    for(NSDictionary *w in journal[@"windows"]) {
        DW2Entry *e=v2DecodeEntry(w,NO);if(!e || active[@(e->who.wid)])return nil;
        restoring|=![w[@"state"]isEqual:@"held"];active[@(e->who.wid)]=e;
    }
    for(NSDictionary *w in journal[@"released_windows"]) {
        DW2Entry *e=v2DecodeEntry(w,YES);if(!e || active[@(e->who.wid)] || released[@(e->who.wid)])return nil;
        released[@(e->who.wid)]=e;
    }
    NSString *state=!active.count ? @"empty" : restoring ? @"restoring" : @"holding";
    return [journal[@"state"]isEqual:state] ? journal : nil;
}
static BOOL v2LoadJournal(NSDictionary *recovery) {
    BOOL absent=NO;NSData *data=v2ReadJournal("v2-journal.json",&absent);
    if(!data&&!absent)return NO;
    BOOL sourceAbsent=NO;NSData *source=v2ReadJournal("recovery-source.json",&sourceAbsent);
    if(recovery) {
        if(!source || !v2RecoveryConfigValid(recovery))return NO;
        unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(source.bytes,(CC_LONG)source.length,bytes);
        NSMutableString *hash=[NSMutableString stringWithCapacity:64];for(unsigned i=0;i<sizeof(bytes);i++)[hash appendFormat:@"%02x",bytes[i]];
        if(![hash isEqual:recovery[@"recovery_source_sha256"]])return NO;
        NSDictionary *history=v2DecodeJournal(source,[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]);if(!history)return NO;
        for(NSString *key in v2WriterKeys())if(![history[key]isEqual:recovery[[@"recovery_"stringByAppendingString:key]]])return NO;
        if(!v2RetiredWriter(history))return NO;
        // After a second crash the newer committed journal is the sole active
        // authority. Validate historical provenance, but never merge or fall
        // back to it when a newer committed journal is malformed.
        if(absent)data=source;
    }else if(!sourceAbsent)return NO;
    if(!data)return v2RemoveStaging();
    NSMutableDictionary *active=[NSMutableDictionary dictionary],*released=[NSMutableDictionary dictionary];
    NSDictionary *journal=v2DecodeJournal(data,active,released);if(!journal)return NO;
    BOOL handoff=!v2WriterSame(journal,v2WriterIdentity);
    if(handoff) {
        if(!v2RetiredWriter(journal))return NO;
        for(NSNumber *wid in released){DW2Entry *e=released[wid];e->reattaching=YES;active[wid]=e;}
        [released removeAllObjects];
    }
    if(!v2RemoveStaging())return NO;
    v2Generation=recovery && absent ? 0 : [journal[@"generation"]unsignedLongLongValue];
    v2LastRestore=journal[@"last_restore"]==NSNull.null ? nil : journal[@"last_restore"];
    [v2Table addEntriesFromDictionary:active];[v2Released addEntriesFromDictionary:released];v2Count();
    // Commit the new writer's complete recovery obligation before any native
    // setter. Reattaching records retain their stricter guard durably on retry.
    if(handoff && !v2Persist())return NO;
    if(active.count)v2Restore(handoff ? @"connection handoff" : @"startup recovery",NO,nil,NULL);
    return YES;
}
// The sole listener. A failure is startup failure, never a fallback server.
static int v2Start(const char *directory,BOOL onMain,NSDictionary *recovery) {
    v2ResolveSublevels();
#if DW_V2_BATCH_COMPILED
    v2ResolveForwardTransactions();
#endif
    v2WriterIdentity=v2CurrentWriterIdentity();if(!v2WriterIdentity)return -__LINE__;
    v2OnMain=onMain;
    v2q=onMain ? dispatch_get_main_queue() : dispatch_queue_create("dw.v2",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    v2Table=[NSMutableDictionary dictionary];v2Released=[NSMutableDictionary dictionary];
    // Announcements of new windows, for the arrival veil. Delivered on this (the main) thread, which has an
    // NSApplication in the Dock; the handler does nothing until a session asks for the veil.
    if(!fixtureOnly&&!allowlist&&v2RegisterNotify)v2VeilRegistered=v2RegisterNotify(mainConnection(),v2WindowAdded,1325,NULL)==0;
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/" DW2_SOCKET,directory)>=(int)sizeof(addr.sun_path))return -__LINE__;
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0)return -__LINE__;
    if(bind(listener,(struct sockaddr *)&addr,sizeof(addr))){close(listener);return -__LINE__;}
    if(chmod(addr.sun_path,0600) || listen(listener,DW2_MAX_CONNECTIONS)){close(listener);unlinkat(directoryFD,DW2_SOCKET,0);return -__LINE__;}
    // Recovery's first pass finishes before accepting clients. Readiness cannot
    // succeed on a malformed journal, and there is no other listener to fall back to.
    __block BOOL loaded=NO;
    if(onMain)loaded=v2LoadJournal(recovery);
    else dispatch_sync(v2q,^{loaded=v2LoadJournal(recovery);});
    if(!loaded){close(listener);unlinkat(directoryFD,DW2_SOCKET,0);return -__LINE__;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        for(;;) {
            int client=accept(listener,NULL,NULL);
            if(client<0) {
                if(errno==EINTR || errno==ECONNABORTED)continue;
                // Out of descriptors or buffers is the process's passing trouble, not
                // the end of the listener: wait and accept again.
                if(errno==EMFILE || errno==ENFILE || errno==ENOBUFS || errno==ENOMEM){usleep(100000);continue;}
                break;
            }
            uid_t uid;gid_t gid;int one=1,size=65536;
            if(getpeereid(client,&uid,&gid) || uid!=getuid()){close(client);continue;}
            if(atomic_fetch_add(&v2Connections,1)>=DW2_MAX_CONNECTIONS){atomic_fetch_sub(&v2Connections,1);close(client);continue;}
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
            setsockopt(client,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));setsockopt(client,SOL_SOCKET,SO_RCVBUF,&size,sizeof(size));
            fcntl(client,F_SETFL,fcntl(client,F_GETFL)|O_NONBLOCK);
            DW2Connection *c=[DW2Connection new];c->fd=client;pthread_mutex_init(&c->writeLock,NULL);
            pthread_t thread;pthread_attr_t attributes;pthread_attr_init(&attributes);pthread_attr_setdetachstate(&attributes,PTHREAD_CREATE_DETACHED);
            void *argument=(__bridge_retained void *)c;
            if(pthread_create(&thread,&attributes,v2Serve,argument)){c=(__bridge_transfer DW2Connection *)argument;atomic_fetch_sub(&v2Connections,1);}
            pthread_attr_destroy(&attributes);
        }
        close(listener);
    });
    return 0;
}
