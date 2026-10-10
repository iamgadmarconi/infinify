// SPDX-License-Identifier: GPL-3.0-or-later
#import "focus.h"
#import <AppKit/AppKit.h>
#include <libproc.h>
#include <dlfcn.h>
#include <math.h>
#include <time.h>
// Signature provenance: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:8 and src/misc/helpers.h:499-504, as native/resize.
// New implementation; no title matching or copied upstream implementation.
typedef AXError (*GetWindow)(AXUIElementRef, uint32_t *);
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
bool dw_focus_birth(pid_t p,uint64_t *s,uint64_t *u) {
    struct proc_bsdinfo b={0};
    if(!s||!u||p<=0||proc_pidinfo(p,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b))return false;
    *s=b.pbi_start_tvsec;*u=b.pbi_start_tvusec;return true;
}
static bool fresh(DWFocusIdentity i) { uint64_t s,u;return dw_focus_birth(i.pid,&s,&u)&&s==i.seconds&&u==i.microseconds; }
bool dw_focus_owner(DWFocusIdentity i,CGRect *out) { @autoreleasepool {
    if(!i.window||!fresh(i))return false;
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,i.window));
    if(list.count!=1)return false; NSDictionary *w=list[0]; CGRect r=CGRectZero;
    if([w[(id)kCGWindowOwnerPID] intValue]!=i.pid||[w[(id)kCGWindowNumber] unsignedIntValue]!=i.window||
       !w[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r)||
       !isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0||!fresh(i))return false;
    if(out)*out=r;return true;
} }
bool dw_focus_identity(pid_t p,CGWindowID w,DWFocusIdentity *out) {
    if(!out)return false;*out=(DWFocusIdentity){0};DWFocusIdentity i={.pid=p,.window=w};
    if(!dw_focus_birth(p,&i.seconds,&i.microseconds)||!dw_focus_owner(i,NULL))return false;*out=i;return true;
}
static AXError timeout(AXUIElementRef w,double end) { double r=end-now();return r>0?AXUIElementSetMessagingTimeout(w,(float)fmin(.1,r)):kAXErrorCannotComplete; }
static AXError copy(AXUIElementRef w,CFStringRef key,CFTypeRef *v,double end) { AXError e=timeout(w,end);return e==kAXErrorSuccess?AXUIElementCopyAttributeValue(w,key,v):e; }
static AXUIElementRef resolve(DWFocusIdentity i,double end,DWFocusResult *r) {
    if(!dw_focus_owner(i,&r->bounds)){r->outcome=DWFocusStale;return NULL;}
    GetWindow get=(GetWindow)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    if(!AXIsProcessTrusted()||!get){r->outcome=DWFocusUnavailable;return NULL;}
    AXUIElementRef app=AXUIElementCreateApplication(i.pid);CFTypeRef list=NULL;
    r->ax_error=copy(app,kAXWindowsAttribute,&list,end);CFRelease(app);
    if(r->ax_error||!list||CFGetTypeID(list)!=CFArrayGetTypeID()){if(list)CFRelease(list);r->outcome=DWFocusUnavailable;return NULL;}
    AXUIElementRef found=NULL;int matches=0;bool valid=true;
    for(CFIndex n=0;n<CFArrayGetCount(list);n++) {
        AXUIElementRef w=(AXUIElementRef)CFArrayGetValueAtIndex(list,n);uint32_t wid=0;pid_t pid=0;
        if(now()>=end){r->outcome=DWFocusTimedOut;valid=false;break;}
        if(CFGetTypeID(w)!=AXUIElementGetTypeID()||(r->ax_error=timeout(w,end))||(r->ax_error=get(w,&wid))){r->outcome=DWFocusUnavailable;valid=false;break;}
        if(wid==i.window){if((r->ax_error=AXUIElementGetPid(w,&pid))||pid!=i.pid){valid=false;r->outcome=DWFocusStale;break;}matches++;if(!found)found=(AXUIElementRef)CFRetain(w);}
    }
    CFRelease(list);
    if(valid&&matches==1&&dw_focus_owner(i,&r->bounds))return found;
    if(valid)r->outcome=matches>1?DWFocusAmbiguous:matches==0?DWFocusMissing:DWFocusStale;
    if(found)CFRelease(found);return NULL;
}
static bool focusedWindow(AXUIElementRef app,pid_t expected,CGWindowID *wid,double end,AXError *e) {
    CFTypeRef w=NULL;*e=copy(app,kAXFocusedWindowAttribute,&w,end);pid_t pid=0;
    GetWindow get=(GetWindow)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    bool ok=!*e&&w&&CFGetTypeID(w)==AXUIElementGetTypeID()&&get;
    if(ok)ok=!(*e=timeout(w,end))&&!(*e=AXUIElementGetPid(w,&pid))&&pid==expected&&!(*e=get(w,wid));
    if(w)CFRelease(w);return ok;
}
static bool readback(DWFocusIdentity i,AXUIElementRef w,double end,DWFocusResult *r) {
    r->focused=false;r->system_pid=0;r->system_window=0;r->app_window=0;
    if(!dw_focus_owner(i,&r->bounds)){r->outcome=DWFocusStale;return false;}
    CFTypeRef pos=NULL,size=NULL;CGPoint p=CGPointZero;CGSize s=CGSizeZero;
    r->ax_error=copy(w,kAXPositionAttribute,&pos,end);
    if(!r->ax_error)r->ax_error=copy(w,kAXSizeAttribute,&size,end);
    bool bounds=!r->ax_error&&pos&&size&&CFGetTypeID(pos)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()&&AXValueGetValue(pos,kAXValueCGPointType,&p)&&AXValueGetValue(size,kAXValueCGSizeType,&s);
    if(pos)CFRelease(pos);if(size)CFRelease(size);
    CGRect cg;bounds=bounds&&dw_focus_owner(i,&cg)&&fabs(cg.origin.x-p.x)<=1&&fabs(cg.origin.y-p.y)<=1&&fabs(cg.size.width-s.width)<=1&&fabs(cg.size.height-s.height)<=1;
    if(!bounds){r->outcome=DWFocusReadbackFailed;return false;}r->bounds=cg;
    AXUIElementRef system=AXUIElementCreateSystemWide(),app=AXUIElementCreateApplication(i.pid);CFTypeRef front=NULL;
    // The system-wide element names no focused application for some applications while they are the one in front: an
    // Electron window, activated and raised, was answered kAXErrorNoValue for as long as it was asked (2026-10-10), so a
    // focus that had happened was reported as timed out. Unnamed, the frontmost application stands in for it and that
    // application's own focused window, read next, for its window; the frontmost check below is the same one either way.
    AXError unnamed=copy(system,kAXFocusedApplicationAttribute,&front,end);
    bool named=!unnamed&&front&&CFGetTypeID(front)==AXUIElementGetTypeID(),ok=true;
    if(named){ok=!(r->ax_error=AXUIElementGetPid(front,&r->system_pid));if(ok)ok=focusedWindow(front,r->system_pid,&r->system_window,end,&r->ax_error);}
    else r->system_pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if(ok)ok=focusedWindow(app,i.pid,&r->app_window,end,&r->ax_error);
    if(ok&&!named&&r->system_pid==i.pid)r->system_window=r->app_window;
    if(front)CFRelease(front);CFRelease(app);CFRelease(system);
    if(!dw_focus_owner(i,&cg)||!CGRectEqualToRect(cg,r->bounds)){r->outcome=DWFocusStale;return false;}
    if(!ok){r->outcome=now()>=end?DWFocusTimedOut:DWFocusReadbackFailed;return false;}
    r->focused=r->system_pid==i.pid&&r->system_window==i.window&&r->app_window==i.window&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==i.pid;
    r->outcome=r->focused?DWFocusFocused:DWFocusObserved;return true;
}
DWFocusResult dw_focus_observe(DWFocusIdentity i) { @autoreleasepool {
    DWFocusResult r={.outcome=DWFocusInvalid};double end=now()+1.5;AXUIElementRef w=resolve(i,end,&r);
    if(w){readback(i,w,end,&r);CFRelease(w);}return r;
} }
static bool allowed(DWFocusIdentity i,DWFocusGuard guard,void *ctx,double end,DWFocusResult *r) {
    if(now()>=end){r->outcome=DWFocusTimedOut;return false;}
    if(!guard||!guard(i,ctx)){r->outcome=DWFocusDenied;return false;}
    CGRect b;if(!dw_focus_owner(i,&b)||!CGRectEqualToRect(b,r->bounds)){r->outcome=DWFocusStale;return false;}return true;
}
DWFocusResult dw_focus_select(DWFocusIdentity i,DWFocusGuard guard,void *ctx) { @autoreleasepool {
    DWFocusResult r={.outcome=DWFocusInvalid};if(!guard)return r;
    double end=now()+1.5;AXUIElementRef w=resolve(i,end,&r);if(!w)return r;
    if(!allowed(i,guard,ctx,end,&r)){CFRelease(w);return r;}
    r.mutation_attempted=true;
    BOOL activated=[[NSRunningApplication runningApplicationWithProcessIdentifier:i.pid] activateWithOptions:0];
    if(!activated){r.outcome=DWFocusAXFailed;CFRelease(w);return r;}
    CFStringRef attributes[]={kAXMainAttribute,kAXFocusedAttribute};
    for(int n=0;n<3;n++) {
        if(!allowed(i,guard,ctx,end,&r)){CFRelease(w);return r;}
        r.ax_error=timeout(w,end);
        if(!r.ax_error)r.ax_error=n<2?AXUIElementSetAttributeValue(w,attributes[n],kCFBooleanTrue):AXUIElementPerformAction(w,kAXRaiseAction);
        if(r.ax_error){r.outcome=DWFocusAXFailed;CFRelease(w);return r;}
    }
    while(allowed(i,guard,ctx,end,&r)) {
        if(readback(i,w,end,&r)&&r.focused){if(!allowed(i,guard,ctx,end,&r))r.focused=false;CFRelease(w);return r;}
        if(r.outcome==DWFocusStale)break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.015]];
    }
    r.focused=false;CFRelease(w);return r;
} }
const char *dw_focus_outcome_name(DWFocusOutcome o) { const char *n[]={"observed","focused","invalid","stale_identity_or_bounds","unavailable","missing_window","ambiguous_window","readback_failed","guard_denied","ax_failed","timed_out"};return o>=0&&o<=DWFocusTimedOut?n[o]:"unknown"; }
