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
// Shared state and native bindings of the Dock helper payload: the SkyLight calls (the absolute transform read and the placement 1
// write among them), process configuration, the window and connection records, session, frame-slot and table state, and the
// optional window server calls with their resolution. This file defines the classes DW2Connection and DW2Entry (the connection and window records).
// Moved verbatim from native/privileged/payload.m (37b27b1), lines 20-278. #imported by DWPayload.m in a fixed order; never compiled alone.
// Edited since the move: getLayer/setLayer (dwReadLayer, dwWriteLayer) and the entry field layer replace the absolute original.

static int (*mainConnection)(void);
static CGError (*getOwner)(int, uint32_t, int *);
// The window transform is read and written through getTransform and setTransform, which keep the meaning every call site was written
// for: one absolute matrix, the whole map from the screen into the window's own space ([1,0,0,1,-x,-y] for an untransformed window at
// (x,y)). They are dwReadAbsolute and dwWriteAbsolute below, set at start; a regression replaces them with substitutes.
static CGError (*getTransform)(int, uint32_t, CGAffineTransform *);
static CGError (*setTransform)(int, uint32_t, CGAffineTransform);
// What a window's ORIGINAL is, and what a restore writes back: the placement-1 layer alone (dwReadLayer and dwWriteLayer below), normally
// the identity. The absolute matrix above also contains placement 0 (the position, which follows the native frame) and any other
// placement some other writer holds, such as the system's own open animation, so an absolute original captured while one of those
// was non-natural could be restored to a window that is then left visibly displaced. A layer is exact whatever the other placements do.
static CGError (*getLayer)(int, uint32_t, CGAffineTransform *);
static CGError (*setLayer)(int, uint32_t, CGAffineTransform);
// The two SkyLight calls behind them, resolved at start. There is deliberately no SLSSetWindowTransform here: it is placement 0 (see
// "Placements" in docs/native/dock-helper/Payload/README.md), and nothing in this file writes placement 0.
static CGError (*skyGetPlacement)(int, uint32_t, int, void *, CGAffineTransform *);
static CGError (*skySetPlacement)(int, uint32_t, int, int, const CGAffineTransform *);
static CGError (*getBounds)(int, uint32_t, CGRect *);
static CGError (*getScreenRect)(int, uint32_t, CGRect *);
// Optional alpha operations. Signatures as declared by yabai (MIT),
// https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h lines 16, 17 and 79; resolved by dlsym like the six above.
static CGError (*getAlpha)(int, uint32_t, float *);
static CGError (*setAlpha)(int, uint32_t, float);
static CGError (*connectionPID)(int, pid_t *);
// Optional Space membership operations. Same pinned yabai commit, extern.h
// 22,40,42,54,56,63 and osax/payload.m:905-929. The move returns void;
// only fresh membership readback can establish that a request was applied.
static CFArrayRef (*copyWindowSpaces)(int,int,CFArrayRef);
static CFStringRef (*copySpaceDisplay)(int,uint64_t);
static uint64_t (*displayCurrentSpace)(int,CFStringRef);
static int (*getSpaceType)(int,uint64_t);
static void (*moveWindowsToSpace)(int,CFArrayRef,uint64_t);
static CFUUIDRef (*createDisplayUUID)(CGDirectDisplayID);
static NSDictionary *fixtureIdentity;
static NSString *secret;
static NSArray *allowlist;
static int directoryFD=-1;
static BOOL started=NO,fixtureOnly=YES,fixtureNativeFamilies=NO;
#define DW_SIDECAR_MAX_BYTES 4096

static NSArray *matrix(CGAffineTransform t) { return @[@(t.a),@(t.b),@(t.c),@(t.d),@(t.tx),@(t.ty)]; }
static BOOL finiteMatrix(CGAffineTransform t) {
    const double m[] = {t.a,t.b,t.c,t.d,t.tx,t.ty};
    for (int i=0;i<6;i++) if (!isfinite(m[i]) || fabs(m[i]) > 1000000) return NO;
    double determinant=t.a*t.d-t.b*t.c;
    return isfinite(determinant) && fabs(determinant) >= 1e-8;
}
// Placements. The window server keeps a transform per window per placement, and each entry remembers the connection that last
// wrote it: when that connection dies (the Dock, on every killall Dock, crash and restart) it resets the entry to identity.
// SLSSetWindowTransform is placement 0, whose entry encodes the window's position ([1,0,0,1,-x,-y] when untransformed), so a Dock
// death drew every window the helper had ever written at the top-left corner of the display until its application restarted.
// A placement of 1 or more is a relative layer applied after placement 0, whose identity means "as placed by placement 0", so
// the same death leaves the window where its native frame is. Everything here is therefore written at placement 1 (flags 0,
// relative) and read back as placement 0 composed with it. Observed on macOS 27.0.1 (26A434); not an upstream API: the signatures
// are those the system SkyLight's disassembly shows (SLSSetWindowTransform is a tail call into SLSSetWindowTransformAtPlacement
// (cid,wid,0,0,&t)), see docs/native/dock-helper/Payload/README.md "Placements". SLSGetCatenatedWindowTransform (all placements) is
// deliberately not used: a window the system is animating open carries a further placement of another writer, which a catenated
// readback would take for a request that did not take (the shell then logs "not placed" and retries until the animation ends).
enum { DW_BASE_PLACEMENT=0, DW_LAYER_PLACEMENT=1 };
// The window server stores 32-bit floats and composes two layers, so an absolute matrix read back after a layered write can differ
// from the request by a rounding or two: a few ulps of the largest translation, far below anything drawn. v2SameTransform allows this.
#define DW_LINEAR_TOLERANCE 1e-6f
#define DW_TRANSLATION_TOLERANCE (1.0f/256)
// The matrix every call site means: placement 0 composed with the layer (placement 0 first, as measured on the guest), which is what
// dwWriteAbsolute sets and so what a readback has to confirm, whatever any other writer's placement holds.
static CGError dwReadAbsolute(int cid,uint32_t wid,CGAffineTransform *absolute) {
    CGAffineTransform base=CGAffineTransformIdentity,layer=CGAffineTransformIdentity;
    CGError status=skyGetPlacement(cid,wid,DW_BASE_PLACEMENT,NULL,&base);
    if(!status)status=skyGetPlacement(cid,wid,DW_LAYER_PLACEMENT,NULL,&layer);
    if(!status)*absolute=CGAffineTransformConcat(base,layer);
    return status;
}
// Writes the absolute matrix A by leaving placement 0 as it is (T0, read now) and setting the layer L that composes with it to A:
// A = L after T0, so L = A after T0^-1. For a window that is where its native frame is (T0 = [1,0,0,1,-x,-y]) and A = T0 (a
// restore of an untransformed window) L is the identity, which is written as exactly the identity. Placement 0 is never written.
static CGError dwWriteAbsolute(int cid,uint32_t wid,CGAffineTransform absolute) {
    CGAffineTransform base=CGAffineTransformIdentity;
    CGError status=skyGetPlacement(cid,wid,DW_BASE_PLACEMENT,NULL,&base);
    if(status)return status;
    if(!finiteMatrix(base))return kCGErrorFailure;
    CGAffineTransform layer=CGAffineTransformConcat(CGAffineTransformInvert(base),absolute);
    if(fabs(layer.a-1)<DW_LINEAR_TOLERANCE&&fabs(layer.d-1)<DW_LINEAR_TOLERANCE&&fabs(layer.b)<DW_LINEAR_TOLERANCE&&fabs(layer.c)<DW_LINEAR_TOLERANCE
        &&fabs(layer.tx)<DW_TRANSLATION_TOLERANCE&&fabs(layer.ty)<DW_TRANSLATION_TOLERANCE)layer=CGAffineTransformIdentity;
    return skySetPlacement(cid,wid,DW_LAYER_PLACEMENT,0,&layer);
}
// The placement-1 layer, as the window server holds it. Reading an untouched window gives the identity; a restore writes the layer
// that was captured, verbatim, and the caller reads it back (v2SameTransform).
static CGError dwReadLayer(int cid,uint32_t wid,CGAffineTransform *layer) {
    return skyGetPlacement(cid,wid,DW_LAYER_PLACEMENT,NULL,layer);
}
static CGError dwWriteLayer(int cid,uint32_t wid,CGAffineTransform layer) {
    return skySetPlacement(cid,wid,DW_LAYER_PLACEMENT,0,&layer);
}
static NSDictionary *identity(uint32_t wid) {
    int owner=0, pid=0;
    int ownerStatus=getOwner(mainConnection(),wid,&owner);
    if (ownerStatus) {fprintf(stderr,"identity: owner status %d for wid %u cid %d\n",ownerStatus,wid,mainConnection());return nil;}
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    if (!rows) return nil;
    for (NSDictionary *w in (__bridge NSArray *)rows) {
        if ([w[(id)kCGWindowNumber] unsignedIntValue]==wid) { pid=[w[(id)kCGWindowOwnerPID] intValue]; break; }
    }
    CFRelease(rows);
    struct proc_bsdinfo b={0};
    if (pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)) {fprintf(stderr,"identity: process lookup failed for wid %u pid %d\n",wid,pid);return nil;}
    if(b.pbi_uid!=getuid())return nil;
    return @{@"pid": @(pid), @"birth_sec": @(b.pbi_start_tvsec), @"birth_usec": @(b.pbi_start_tvusec), @"wid": @(wid), @"owner": @(owner)};
}
static BOOL writeAll(int fd, const void *bytes, size_t count) {
    const char *p=bytes;
    while (count) { ssize_t n=write(fd,p,count); if (n<0 && errno==EINTR) continue; if(n<=0)return NO; p+=n;count-=n; }
    return YES;
}
static BOOL isNumber(id n) { return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID(); }
static NSArray *validAllowlist(id raw) {
    if(![raw isKindOfClass:NSArray.class] || [raw count]==0 || [raw count]>DW2_MAX_PROCESSES)return nil;
    NSMutableSet *pids=[NSMutableSet set];
    for(id entry in raw) {
        if(![entry isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:[entry allKeys]] isEqual:[NSSet setWithArray:@[@"pid",@"birth_sec",@"birth_usec"]]])return nil;
        for(id key in (NSDictionary *)entry){id n=((NSDictionary *)entry)[key];if(!isNumber(n) || CFNumberIsFloatType((__bridge CFNumberRef)n))return nil;}
        int64_t pid=[entry[@"pid"]longLongValue],seconds=[entry[@"birth_sec"]longLongValue],microseconds=[entry[@"birth_usec"]longLongValue];
        if(pid<=0 || pid>INT_MAX || seconds<=0 || microseconds<0 || microseconds>=1000000 || [pids containsObject:entry[@"pid"]])return nil;
        [pids addObject:entry[@"pid"]];
    }
    return raw;
}
static double nowMS(void) { return NSProcessInfo.processInfo.systemUptime*1000; }
// Protocol v2: many windows per frame, newest frame wins, journalled restoration.
// Original implementation. Wire format: DWHelperProtocol.h. Semantics: docs/native/dock-helper/Client/README.md "Protocol v2".
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
#import <pthread.h>
#import <stdatomic.h>
#import <sys/uio.h>
#import "DWJournalFields.h"

// Every v2 native call, the table, the journal, restore and its retries run on v2q.
// Socket reads, parsing, heartbeats and the lease watch run on connection threads
// and never wait on it.
static dispatch_queue_t v2q;
static uint32_t fixtureWids[16], fixtureCount;

@interface DW2Connection : NSObject { @public int fd; pthread_mutex_t writeLock; atomic_bool closed; int role; uint64_t session, lastFrame; } @end
@implementation DW2Connection
- (void)dealloc { close(fd);pthread_mutex_destroy(&writeLock); }
@end
@interface DW2Entry : NSObject { @public struct dw2_identity who; int owner; CGAffineTransform layer; CGRect bounds; float alpha; BOOL hasAlpha, alphaTouched, fresh, alphaFresh; uint32_t state;
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
    // Arrival placement (v2ArrivalPlace): a child of a placed root the helper itself placed when it opened, until a frame names it. Memory only.
    BOOL arrival;
    CGAffineTransform veilPriorLayer; CGRect veilPriorBounds;
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
// ABI/schema: yabai https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:60 and src/display.c:203-234 (MIT).
static CFArrayRef (*v2CopyManagedSpaces)(int);
static BOOL v2ManagedSpacesResolved;
// ABI and nonactivating layer use: yabai https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
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
// A window narrower or shorter than this is never offered to the shell (DWWindowManager.m), so it is not veiled.
static const CGFloat v2VeilMinimumExtent=40;
// Only the explicit same-user (desktop) helper; allowlist and cooperative scopes are not veiled.
static BOOL v2VeilAvailable(void) { return v2VeilRegistered&&!fixtureOnly&&!allowlist&&setAlpha&&getAlpha&&getBounds&&getLayer; }
// The one SkyLight handle of this translation unit. Every group of native symbols, required or optional, is resolved from it.
static void *v2Sky(void) {
    static void *handle;static dispatch_once_t once;
    dispatch_once(&once,^{handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LOCAL|RTLD_NOW);});
    return handle;
}
static void v2ResolveSublevels(void) {
    void *sky=v2Sky();
    if(!sky)return;
    v2GetWindowLevel=dlsym(sky,"SLSGetWindowLevel");
    v2GetWindowSublevel=dlsym(sky,"SLSGetWindowSubLevel");
    v2SetWindowSublevel=dlsym(sky,"SLSSetWindowSubLevel");
}

// The window server's own parent of a window, read-only, through the exact single-window query the shell's family audit uses
// (native/app/CompositorMode/DWWindowServerFamily.h, whose ABI and call sequence are yabai https://github.com/asmvik/yabai commit
// dd845723416f5fe92af49fad5ebab00369e07edd, src/window.c:872-897 and src/misc/extern.h:9,66-72, MIT). YES only when the query names exactly this window once; *parent is 0 for a root.
// A variable so that the tests substitute it.
static CFTypeRef (*v2SLSQueryWindows)(int,CFArrayRef,int);
static CFTypeRef (*v2SLSQueryCopyWindows)(CFTypeRef);
static int (*v2SLSIteratorCount)(CFTypeRef);
static bool (*v2SLSIteratorAdvance)(CFTypeRef);
static uint32_t (*v2SLSIteratorParent)(CFTypeRef);
static uint32_t (*v2SLSIteratorWindow)(CFTypeRef);
static void v2ResolveFamily(void) {
    void *sky=v2Sky();
    if(!sky)return;
    v2SLSQueryWindows=dlsym(sky,"SLSWindowQueryWindows");
    v2SLSQueryCopyWindows=dlsym(sky,"SLSWindowQueryResultCopyWindows");
    v2SLSIteratorCount=dlsym(sky,"SLSWindowIteratorGetCount");
    v2SLSIteratorAdvance=dlsym(sky,"SLSWindowIteratorAdvance");
    v2SLSIteratorParent=dlsym(sky,"SLSWindowIteratorGetParentID");
    v2SLSIteratorWindow=dlsym(sky,"SLSWindowIteratorGetWindowID");
}
static BOOL v2NativeParentOf(uint32_t wid,uint32_t *parent) {
    if(!v2SLSQueryWindows||!v2SLSQueryCopyWindows||!v2SLSIteratorCount||!v2SLSIteratorAdvance||!v2SLSIteratorParent||!v2SLSIteratorWindow||!mainConnection)return NO;
    CFTypeRef query=v2SLSQueryWindows(mainConnection(),(__bridge CFArrayRef)@[@(wid)],1);
    if(!query)return NO;
    CFTypeRef iterator=v2SLSQueryCopyWindows(query);
    int count=iterator?v2SLSIteratorCount(iterator):0;BOOL advanced=iterator&&count==1&&v2SLSIteratorAdvance(iterator);
    uint32_t actual=advanced?v2SLSIteratorWindow(iterator):0,up=advanced?v2SLSIteratorParent(iterator):0;
    BOOL extra=advanced&&v2SLSIteratorAdvance(iterator);
    if(iterator)CFRelease(iterator);CFRelease(query);
    if(!advanced||extra||actual!=wid)return NO;
    *parent=up;return YES;
}
static BOOL (*v2ParentOf)(uint32_t,uint32_t *)=v2NativeParentOf;

