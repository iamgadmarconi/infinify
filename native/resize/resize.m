// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize.h"
#import <AppKit/AppKit.h>
#include <libproc.h>
#include <dlfcn.h>
#include <math.h>
#include <time.h>
#include <unistd.h>

// Signature precedent: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:8 and src/misc/helpers.h:499-504. No upstream implementation copied.
typedef AXError (*WindowIDFunction)(AXUIElementRef, uint32_t *);
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec+t.tv_nsec/1e9; }
static bool birth(pid_t pid, uint64_t *sec, uint64_t *usec) {
    struct proc_bsdinfo p = {0};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &p, sizeof(p)) != sizeof(p)) return false;
    *sec=p.pbi_start_tvsec; *usec=p.pbi_start_tvusec; return true;
}
static bool valid_rect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height) && r.size.width>0 && r.size.height>0;
}
static bool (*own_bounds)(uint32_t, CGRect *);
void dw_resize_set_bounds(bool (*read)(uint32_t, CGRect *)) { own_bounds=read; }
static bool owner(DWResizeIdentity i, CGRect *rect) {
    uint64_t s=0,u=0;
    if (!i.window || !birth(i.pid,&s,&u) || s!=i.birth_seconds || u!=i.birth_microseconds) return false;
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,i.window));
    if (list.count!=1) return false;
    NSDictionary *d=list.firstObject; CGRect r=CGRectZero;
    if ([d[(__bridge NSString *)kCGWindowNumber] unsignedIntValue]!=i.window || [d[(__bridge NSString *)kCGWindowOwnerPID] intValue]!=i.pid ||
        !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(__bridge NSString *)kCGWindowBounds],&r) || !valid_rect(r)) return false;
    if (!birth(i.pid,&s,&u) || s!=i.birth_seconds || u!=i.birth_microseconds) return false;
    // The window is this process's by the list above; its frame is the reader's when one is set.
    if (own_bounds && (!own_bounds(i.window,&r) || !valid_rect(r))) return false;
    if (rect) *rect=r; return true;
}
bool dw_resize_identity(pid_t pid, CGWindowID window, DWResizeIdentity *identity) {
    if (!identity) return false;
    *identity=(DWResizeIdentity){0}; DWResizeIdentity i={.pid=pid,.window=window};
    if (!birth(pid,&i.birth_seconds,&i.birth_microseconds) || !owner(i,NULL)) return false;
    *identity=i; return true;
}
static DWResizeResult result(DWResizeOutcome o) { return (DWResizeResult){.outcome=o,.ax_error=kAXErrorSuccess}; }
static AXError timeout(AXUIElementRef element, double deadline) {
    double remaining=deadline-now();
    if (remaining<=0) return kAXErrorCannotComplete;
    return AXUIElementSetMessagingTimeout(element,(float)fmin(.15,remaining));
}
static AXUIElementRef resolve(DWResizeIdentity i, double deadline, DWResizeResult *r) {
    if (!owner(i,NULL)) { r->outcome=DWResizeStaleIdentity; return NULL; }
    if (!AXIsProcessTrusted()) { r->outcome=DWResizeUnavailable; return NULL; }
    WindowIDFunction getWindow=(WindowIDFunction)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    if (!getWindow) { r->outcome=DWResizeUnavailable; return NULL; }
    AXUIElementRef app=AXUIElementCreateApplication(i.pid); CFTypeRef value=NULL;
    r->ax_error=timeout(app,deadline);
    if (r->ax_error==kAXErrorSuccess) r->ax_error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&value);
    CFRelease(app);
    if (r->ax_error!=kAXErrorSuccess || !value || CFGetTypeID(value)!=CFArrayGetTypeID()) {
        if (value) CFRelease(value); r->outcome=DWResizeUnavailable; return NULL;
    }
    CFArrayRef windows=(CFArrayRef)value; AXUIElementRef found=NULL; size_t matches=0;
    r->outcome=DWResizeMissingWindow;
    for (CFIndex n=0;n<CFArrayGetCount(windows);n++) {
        if (now()>=deadline) { r->outcome=DWResizeTimedOut; break; }
        AXUIElementRef w=(AXUIElementRef)CFArrayGetValueAtIndex(windows,n); uint32_t wid=0; pid_t pid=0;
        if (CFGetTypeID(w)!=AXUIElementGetTypeID() || timeout(w,deadline)!=kAXErrorSuccess) { r->outcome=DWResizeUnavailable; break; }
        AXError e=getWindow(w,&wid);
        // Unknown elements must not hide a second match.
        if (e!=kAXErrorSuccess) { r->ax_error=e; r->outcome=DWResizeUnavailable; break; }
        if (wid==i.window) {
            if (AXUIElementGetPid(w,&pid)!=kAXErrorSuccess || pid!=i.pid) { r->outcome=DWResizeStaleIdentity; break; }
            matches++; if (!found) found=(AXUIElementRef)CFRetain(w);
        }
    }
    CFRelease(value);
    if (r->outcome==DWResizeMissingWindow && matches==1 && owner(i,NULL)) return found;
    if (r->outcome==DWResizeMissingWindow && matches>1) r->outcome=DWResizeAmbiguousWindow;
    else if (r->outcome==DWResizeMissingWindow && matches==1) r->outcome=DWResizeStaleIdentity;
    if (found) CFRelease(found); return NULL;
}
static bool near(double a,double b) { return fabs(a-b)<=1.; }
static bool same_size(CGSize a,CGSize b) { return near(a.width,b.width)&&near(a.height,b.height); }
// Where the window has to sit for `size` to be granted. macOS does not let an Accessibility size change carry a window past the
// visible frame of its screen: from an origin the size does not fit from, the request changes nothing (the owner's run of
// 2026-10-10: 2056x1329 asked four times of a window at (223,39) on a 2056x1329 display, answered each time with the 1833x1290
// that reaches the screen's edges). The least move that makes room, one axis at a time and only on an axis the request grows on:
// a size that fits the visible frame is given exactly its room, a larger one starts at the frame's origin and is asked as it is,
// so that the application grants what it can. The screen is the one that holds most of the window; a window on none is left alone.
// AppKit's screens are measured upwards from the primary screen's lower left corner, Accessibility downwards from its top left.
static bool room(CGRect before, CGSize size, CGPoint *to) {
    NSArray<NSScreen *> *screens=NSScreen.screens; if (!screens.count) return false;
    CGFloat top=NSMaxY(screens[0].frame), most=0; CGRect visible=CGRectZero;
    for (NSScreen *screen in screens) {
        NSRect f=screen.frame, v=screen.visibleFrame;
        CGRect shared=CGRectIntersection(before,CGRectMake(f.origin.x,top-NSMaxY(f),f.size.width,f.size.height));
        if (CGRectIsNull(shared) || shared.size.width*shared.size.height<=most) continue;
        most=shared.size.width*shared.size.height; visible=CGRectMake(v.origin.x,top-NSMaxY(v),v.size.width,v.size.height);
    }
    if (most<=0 || !valid_rect(visible)) return false;
    CGPoint p=before.origin;
    if (size.width>before.size.width && p.x+size.width>CGRectGetMaxX(visible)) p.x=fmax(CGRectGetMinX(visible),CGRectGetMaxX(visible)-size.width);
    if (size.height>before.size.height && p.y+size.height>CGRectGetMaxY(visible)) p.y=fmax(CGRectGetMinY(visible),CGRectGetMaxY(visible)-size.height);
    *to=p; return !CGPointEqualToPoint(p,before.origin);
}
static bool readback(DWResizeIdentity i, AXUIElementRef window, double deadline, DWResizeResult *r) {
    r->observed=false;
    CGRect cg=CGRectZero; if (!owner(i,&cg)) { r->outcome=DWResizeStaleIdentity; return false; }
    CFTypeRef pos=NULL,size=NULL; CGPoint p; CGSize s;
    r->ax_error=timeout(window,deadline);
    if (r->ax_error==kAXErrorSuccess) r->ax_error=AXUIElementCopyAttributeValue(window,kAXPositionAttribute,&pos);
    if (r->ax_error==kAXErrorSuccess) r->ax_error=timeout(window,deadline);
    if (r->ax_error==kAXErrorSuccess) r->ax_error=AXUIElementCopyAttributeValue(window,kAXSizeAttribute,&size);
    bool ok=r->ax_error==kAXErrorSuccess && pos && size && CFGetTypeID(pos)==AXValueGetTypeID() && CFGetTypeID(size)==AXValueGetTypeID() &&
        AXValueGetValue(pos,kAXValueCGPointType,&p) && AXValueGetValue(size,kAXValueCGSizeType,&s);
    if (pos) CFRelease(pos); if (size) CFRelease(size);
    if (!owner(i,&cg)) { r->outcome=DWResizeStaleIdentity; return false; }
    CGRect ax= ok ? (CGRect){p,s} : CGRectZero;
    if (!ok || !valid_rect(ax) || !near(ax.origin.x,cg.origin.x) || !near(ax.origin.y,cg.origin.y) || !same_size(ax.size,cg.size)) {
        r->outcome=now()>=deadline ? DWResizeTimedOut : DWResizeReadbackFailed; return false;
    }
    r->actual_ax=ax; r->actual_cg=cg; r->observed=true; return true;
}
DWResizeResult dw_resize_observe(DWResizeIdentity i) { @autoreleasepool {
    DWResizeResult r=result(DWResizeObserved); double deadline=now()+2.; AXUIElementRef w=resolve(i,deadline,&r);
    if (w) { if (readback(i,w,deadline,&r)) r.outcome=DWResizeObserved; CFRelease(w); } return r;
} }
DWResizeResult dw_resize_apply_scoped(DWResizeIdentity i, CGSize size, DWResizeGuard guard, DWResizeGuard final_authorize, void *context) { @autoreleasepool {
    DWResizeResult r=result(DWResizeInvalidRequest); r.requested=size;
    if (!isfinite(size.width)||!isfinite(size.height)||size.width<1||size.height<1||size.width>32768||size.height>32768) return r;
    double deadline=now()+2.; AXUIElementRef w=resolve(i,deadline,&r); if (!w) return r;
    if (!readback(i,w,deadline,&r)) { CFRelease(w); return r; }
    CGRect before=r.actual_ax; Boolean settable=false;
    r.ax_error=timeout(w,deadline);
    if (r.ax_error==kAXErrorSuccess) r.ax_error=AXUIElementIsAttributeSettable(w,kAXSizeAttribute,&settable);
    if (r.ax_error!=kAXErrorSuccess || !settable) { r.outcome=DWResizeUnsupported; CFRelease(w); return r; }
    if (!owner(i,NULL)) { r.outcome=DWResizeStaleIdentity; r.observed=false; CFRelease(w); return r; }
    r.ax_error=timeout(w,deadline);
    if (r.ax_error!=kAXErrorSuccess) { r.outcome=DWResizeTimedOut; CFRelease(w); return r; }
    if (guard && !guard(i,context)) { r.outcome=DWResizeUnsupported; CFRelease(w); return r; }
    if (guard && !owner(i,NULL)) { r.outcome=DWResizeStaleIdentity; r.observed=false; CFRelease(w); return r; }
    if (guard) { r.ax_error=timeout(w,deadline); if(r.ax_error!=kAXErrorSuccess) {r.outcome=DWResizeTimedOut;CFRelease(w);return r;} }
    // Room first, by a native position write that the same identity, settable and guard checks have just preceded. It is a
    // place on the real screen only: the caller maps the window by the origin every result reports and keeps its own geometry.
    // A scoped final authorization is one ticket for one setter, the size's, so nothing is moved under one. A write that fails
    // or is not honoured changes nothing below: the size is asked from wherever the window then is.
    CGPoint origin=before.origin, to=origin; bool positioned=false;
    if (!final_authorize && room(before,size,&to)) {
        AXValueRef p=AXValueCreate(kAXValueCGPointType,&to); DWResizeResult kept=r; bool seen=false;
        if (p) { positioned=true; AXUIElementSetAttributeValue(w,kAXPositionAttribute,p); CFRelease(p); }
        for (int n=0;positioned && n<4 && now()<deadline;n++) {
            usleep(30000); seen=readback(i,w,deadline,&r);
            if (r.outcome==DWResizeStaleIdentity) { CFRelease(w); return r; }
            if (seen && near(r.actual_ax.origin.x,to.x) && near(r.actual_ax.origin.y,to.y)) break;
        }
        // Unread, the window is taken to be where it was read last; the read after the size write says where it is.
        if (!seen) r=kept;
        r.moved=seen && !CGPointEqualToPoint(r.actual_ax.origin,origin);
        // The checks that stood before the position write stand before the size write as well.
        if (!owner(i,NULL)) { r.outcome=DWResizeStaleIdentity; r.observed=false; CFRelease(w); return r; }
        r.ax_error=timeout(w,deadline);
        if (r.ax_error!=kAXErrorSuccess) { r.outcome=DWResizeTimedOut; CFRelease(w); return r; }
    }
    AXValueRef v=AXValueCreate(kAXValueCGSizeType,&size);
    if (!v) { r.outcome=DWResizeUnavailable; CFRelease(w); return r; }
    // A scoped final callback must be lightweight: no AX/family/file operations.
    // No native call intervenes between final authorization and the AXSize setter.
    if (final_authorize && !final_authorize(i,context)) { r.outcome=DWResizeUnsupported; CFRelease(v); CFRelease(w); return r; }
    // Reserve the already configured <=150ms timeout, avoiding an AX timeout
    // update after final authorization. Legacy wrappers preserve their ordering.
    if (final_authorize && now()+.15>deadline) { r.outcome=DWResizeTimedOut; r.ax_error=kAXErrorCannotComplete; CFRelease(v); CFRelease(w); return r; }
    r.mutation_attempted=true;
    AXError setter=AXUIElementSetAttributeValue(w,kAXSizeAttribute,v); CFRelease(v);
    r.observed=false; r.outcome=now()>=deadline?DWResizeTimedOut:DWResizeReadbackFailed;
    // Always read back even after an error: the receiver may have accepted a timed-out call.
    bool observed=false;
    for (int n=0;n<4 && now()<deadline;n++) {
        usleep(30000); observed=readback(i,w,deadline,&r);
        if (observed && (!same_size(before.size,r.actual_ax.size)||same_size(size,r.actual_ax.size))) break;
        if (r.outcome==DWResizeStaleIdentity) break;
    }
    if (observed) r.outcome=same_size(size,r.actual_ax.size)?DWResizeApplied:(!same_size(before.size,r.actual_ax.size)?DWResizeClamped:DWResizeRejected);
    if (setter!=kAXErrorSuccess) r.ax_error=setter;
    if (positioned && observed) r.moved=!CGPointEqualToPoint(r.actual_ax.origin,origin);
    CFRelease(w); return r;
} }
DWResizeResult dw_resize_apply_guarded(DWResizeIdentity i, CGSize size, DWResizeGuard guard, void *context) { return dw_resize_apply_scoped(i,size,guard,NULL,context); }
DWResizeResult dw_resize_apply(DWResizeIdentity i, CGSize size) { return dw_resize_apply_guarded(i,size,NULL,NULL); }
DWResizeResult dw_resize_snapshot(DWResizeIdentity i,DWResizeSnapshot *s) {
    DWResizeResult r=dw_resize_observe(i); if (s) *s=(DWResizeSnapshot){.identity=i,.original=r.actual_ax,.valid=r.observed}; return r;
}
DWResizeResult dw_resize_restore(DWResizeSnapshot s) { return s.valid?dw_resize_apply(s.identity,s.original.size):result(DWResizeInvalidRequest); }
const char *dw_resize_outcome_name(DWResizeOutcome o) {
    static const char *names[]={"observed","applied","clamped","rejected","invalid_request","stale_identity","unavailable","missing_window","ambiguous_window","unsupported","readback_failed","timed_out"};
    return o<=DWResizeTimedOut && o>=DWResizeObserved?names[o]:"unknown";
}
