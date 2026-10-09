// SPDX-License-Identifier: GPL-3.0-or-later
// Private API declarations checked against yabai dd845723416f5fe92af49fad5ebab00369e07edd.
// No yabai implementation is copied. Private ABI availability is not runtime authority.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/utsname.h>

typedef int (*MainConnection)(void);
typedef CGError (*GetTransform)(int, uint32_t, CGAffineTransform *);
typedef CGError (*SetTransform)(int, uint32_t, CGAffineTransform);
typedef CGError (*GetBounds)(int, uint32_t, CGRect *);
typedef CGError (*GetOwner)(int, uint32_t, int *);
static MainConnection mainConnection;
static GetTransform getTransform;
static SetTransform setTransform;
static GetBounds getBounds;
static GetBounds getScreenRect;
static GetOwner getOwner;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void load(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    if (!h) return;
    mainConnection = (MainConnection)dlsym(h, "SLSMainConnectionID");
    getTransform = (GetTransform)dlsym(h, "SLSGetWindowTransform");
    setTransform = (SetTransform)dlsym(h, "SLSSetWindowTransform");
    getBounds = (GetBounds)dlsym(h, "SLSGetWindowBounds");
    getScreenRect = (GetBounds)dlsym(h, "SLSGetScreenRectForWindow");
    getOwner = (GetOwner)dlsym(h, "SLSGetWindowOwner");
}
static char *json(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return NULL;
    char *result = calloc(data.length + 1, 1);
    if (result) memcpy(result, data.bytes, data.length);
    return result;
}
void dw_free(char *p) { free(p); }
char *dw_doctor(void) { @autoreleasepool {
    pthread_once(&once, load);
    struct utsname machine; uname(&machine);
    return json(@{@"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"architecture": [NSString stringWithUTF8String:machine.machine], @"accessibility_trusted": [NSNumber numberWithBool:AXIsProcessTrusted()],
        @"screen_capture_preflight": @(CGPreflightScreenCaptureAccess()),
        @"symbols": @{@"SLSMainConnectionID": [NSNumber numberWithBool:(mainConnection != NULL)], @"SLSGetWindowTransform": [NSNumber numberWithBool:(getTransform != NULL)], @"SLSSetWindowTransform": [NSNumber numberWithBool:(setTransform != NULL)], @"SLSGetWindowBounds": [NSNumber numberWithBool:(getBounds != NULL)], @"SLSGetWindowOwner": [NSNumber numberWithBool:(getOwner != NULL)], @"SLSGetScreenRectForWindow": [NSNumber numberWithBool:(getScreenRect != NULL)]},
        @"foreign_transform": @"unproven; run fixture probe", @"multiple_live_presentations": @"unsupported: unproven", @"per_output_clipping": @"unsupported: unproven",
        @"prompts_requested": @NO});
} }
char *dw_list(void) { @autoreleasepool {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (!list) return NULL;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *w in (__bridge NSArray *)list) {
        [rows addObject:@{@"window_id": w[(id)kCGWindowNumber] ?: @0,
            @"pid": w[(id)kCGWindowOwnerPID] ?: @0,
            @"owner": w[(id)kCGWindowOwnerName] ?: @"",
            @"title": w[(id)kCGWindowName] ?: [NSNull null],
            @"layer": w[(id)kCGWindowLayer] ?: @0,
            @"bounds": w[(id)kCGWindowBounds] ?: @{},
            @"on_screen": w[(id)kCGWindowIsOnscreen] ?: @NO}];
    }
    CFRelease(list);
    return json(rows);
} }
int dw_process_start(int pid, uint64_t *seconds, uint64_t *micros) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    *seconds = info.pbi_start_tvsec; *micros = info.pbi_start_tvusec; return 0;
}
int dw_identity(uint32_t wid, int *pid, int *connection) { @autoreleasepool {
    pthread_once(&once, load);
    if (!mainConnection || !getOwner) return -10000;
    CGError e = getOwner(mainConnection(), wid, connection);
    if (e) return e;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
    if (!list) return -1;
    int found = 0;
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowNumber] unsignedIntValue] == wid) { *pid = [w[(id)kCGWindowOwnerPID] intValue]; found = 1; break; }
    }
    CFRelease(list); return found ? 0 : -1;
} }
int dw_get(uint32_t wid, double *matrix, double *bounds) {
    pthread_once(&once, load);
    if (!mainConnection || !getTransform || !getBounds) return -10000;
    CGAffineTransform t; CGRect b;
    CGError e = getTransform(mainConnection(), wid, &t); if (e) return e;
    e = getBounds(mainConnection(), wid, &b); if (e) return e;
    matrix[0]=t.a; matrix[1]=t.b; matrix[2]=t.c; matrix[3]=t.d; matrix[4]=t.tx; matrix[5]=t.ty;
    bounds[0]=b.origin.x; bounds[1]=b.origin.y; bounds[2]=b.size.width; bounds[3]=b.size.height;
    return 0;
}
int dw_set(uint32_t wid, const double *m) {
    pthread_once(&once, load);
    if (!mainConnection || !setTransform) return -10000;
    return setTransform(mainConnection(), wid, CGAffineTransformMake(m[0],m[1],m[2],m[3],m[4],m[5]));
}

int dw_screen_rect(uint32_t wid, double *bounds) {
    pthread_once(&once, load);
    if (!mainConnection || !getScreenRect) return -10000;
    CGRect b = CGRectZero;
    CGError e = getScreenRect(mainConnection(), wid, &b); if (e) return e;
    bounds[0]=b.origin.x; bounds[1]=b.origin.y; bounds[2]=b.size.width; bounds[3]=b.size.height;
    return 0;
}
// Deliberately bounded WindowServer input probe. Refuse if another visible window covers
// the target; never use app-local dispatch, which would bypass server hit testing.
char *dw_click_fixture(uint32_t wid, double x, double y) { @autoreleasepool {
    if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess()) return json(@{@"posted": @NO, @"reason": @"AX or event-post permission unavailable"});
    if (!isfinite(x) || !isfinite(y)) return json(@{@"posted": @NO, @"reason": @"nonfinite target"});
    pthread_once(&once, load);
    if (!getScreenRect || !mainConnection) return json(@{@"posted": @NO, @"reason": @"screen-rect symbol unavailable"});
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    uint32_t hit = 0;
    for (NSDictionary *w in (__bridge NSArray *)windows) {
        if ([w[(id)kCGWindowLayer] intValue] < 0 || [w[(id)kCGWindowAlpha] doubleValue] == 0) continue;
        uint32_t candidate = [w[(id)kCGWindowNumber] unsignedIntValue]; CGRect r;
        CGError rectStatus = getScreenRect(mainConnection(),candidate,&r);
        if (rectStatus != 0 || !isfinite(r.origin.x) || !isfinite(r.origin.y) || !isfinite(r.size.width) || !isfinite(r.size.height)) {
            CFRelease(windows); return json(@{@"posted": @NO, @"reason": @"cannot rule out foreground occlusion; no input posted", @"screen_rect_status": @(rectStatus)});
        }
        if (CGRectContainsPoint(r,CGPointMake(x,y))) {hit=candidate;break;}
    }
    if (windows) CFRelease(windows);
    if (hit != wid) return json(@{@"posted": @NO, @"reason": @"target occluded or missing; no input posted", @"hit_window": @(hit)});
    CGEventRef current = CGEventCreate(NULL);
    if (!current) return json(@{@"posted": @NO, @"reason": @"cannot snapshot pointer"});
    CGPoint original = CGEventGetLocation(current); CFRelease(current);
    CGPoint point = CGPointMake(x,y);
    for (int click=0;click<2;click++) {
        for (int i=0;i<3;i++) {
            CGEventType type = i==0 ? kCGEventMouseMoved : i==1 ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
            CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
            if (event) {CGEventSetIntegerValueField(event,kCGEventSourceUserData,0x44575052);CGEventSetIntegerValueField(event,kCGMouseEventClickState,1);CGEventPost(kCGHIDEventTap,event);CFRelease(event);} usleep(60000);
        }
    }
    CGError restored=CGWarpMouseCursorPosition(original);
    return json(@{@"posted": @YES, @"method": @"CGEventPost(kCGHIDEventTap), two clicks", @"target_screen": @[@(x),@(y)], @"pointer_original": @[@(original.x),@(original.y)], @"pointer_restore_status": @(restored)});
} }
