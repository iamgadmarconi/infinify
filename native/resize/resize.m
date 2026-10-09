// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize.h"
#import <Foundation/Foundation.h>
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
static bool owner(DWResizeIdentity i, CGRect *rect) {
    uint64_t s=0,u=0;
    if (!i.window || !birth(i.pid,&s,&u) || s!=i.birth_seconds || u!=i.birth_microseconds) return false;
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,i.window));
    if (list.count!=1) return false;
    NSDictionary *d=list.firstObject; CGRect r=CGRectZero;
    if ([d[(__bridge NSString *)kCGWindowNumber] unsignedIntValue]!=i.window || [d[(__bridge NSString *)kCGWindowOwnerPID] intValue]!=i.pid ||
        !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(__bridge NSString *)kCGWindowBounds],&r) || !valid_rect(r)) return false;
    if (!birth(i.pid,&s,&u) || s!=i.birth_seconds || u!=i.birth_microseconds) return false;
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
DWResizeResult dw_resize_apply_guarded(DWResizeIdentity i, CGSize size, DWResizeGuard guard, void *context) { @autoreleasepool {
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
    AXValueRef v=AXValueCreate(kAXValueCGSizeType,&size); r.mutation_attempted=true;
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
    CFRelease(w); return r;
} }
DWResizeResult dw_resize_apply(DWResizeIdentity i, CGSize size) { return dw_resize_apply_guarded(i,size,NULL,NULL); }
DWResizeResult dw_resize_snapshot(DWResizeIdentity i,DWResizeSnapshot *s) {
    DWResizeResult r=dw_resize_observe(i); if (s) *s=(DWResizeSnapshot){.identity=i,.original=r.actual_ax,.valid=r.observed}; return r;
}
DWResizeResult dw_resize_restore(DWResizeSnapshot s) { return s.valid?dw_resize_apply(s.identity,s.original.size):result(DWResizeInvalidRequest); }
const char *dw_resize_outcome_name(DWResizeOutcome o) {
    static const char *names[]={"observed","applied","clamped","rejected","invalid_request","stale_identity","unavailable","missing_window","ambiguous_window","unsupported","readback_failed","timed_out"};
    return o<=DWResizeTimedOut && o>=DWResizeObserved?names[o]:"unknown";
}
