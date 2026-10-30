// SPDX-License-Identifier: GPL-3.0-or-later
#import "focus.h"
#import "../desktop/ax-lookup.h"
#import <AppKit/AppKit.h>
#include <libproc.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
// Signature provenance: yabai (https://github.com/asmvik/yabai, MIT) commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:8 and src/misc/helpers.h:499-504, as native/resize/resize.m.
// New implementation with no title matching, but for forward() below, which is adapted from yabai (MIT, same repository and commit):
// src/window_manager.c:1269-1291 (window_manager_make_key_window) and 1324-1335 (window_manager_focus_window_with_raise),
// with the signatures of src/misc/extern.h:81-82 and kCPSUserGenerated of src/window_manager.h:5.
// Licence text: native/desktop/YABAI-NOTICE.txt.
typedef AXError (*GetWindow)(AXUIElementRef, uint32_t *);
typedef CGError (*FrontWithOptions)(ProcessSerialNumber *,uint32_t,uint32_t);
typedef CGError (*PostEventRecord)(ProcessSerialNumber *,uint8_t *);
// Not yabai's, which is handed its serial numbers by Carbon process events: the deprecated HIServices call, looked up by
// name like the private ones.
typedef OSStatus (*ProcessForPID)(pid_t,ProcessSerialNumber *);
static double now(void) { return DWMonotonicSeconds(); }
bool dw_focus_birth(pid_t p,uint64_t *s,uint64_t *u) { return DWProcessBirth(p,s,u); }
static bool fresh(DWFocusIdentity i) { uint64_t s,u;return dw_focus_birth(i.pid,&s,&u)&&s==i.seconds&&u==i.microseconds; }
static bool (*ownBounds)(uint32_t,CGRect *);
void dw_focus_set_bounds(bool (*read)(uint32_t,CGRect *)) { ownBounds=read; }
bool dw_focus_owner(DWFocusIdentity i,CGRect *out) { @autoreleasepool {
    if(!i.window||!fresh(i))return false;
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,i.window));
    if(list.count!=1)return false; NSDictionary *w=list[0]; CGRect r=CGRectZero;
    if([w[(id)kCGWindowOwnerPID] intValue]!=i.pid||[w[(id)kCGWindowNumber] unsignedIntValue]!=i.window||
       !w[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r)||
       !isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0||!fresh(i))return false;
    // The window is this process's by the list above; its frame is the reader's when one is set.
    if(ownBounds&&!ownBounds(i.window,&r))return false;
    if(out)*out=r;return true;
} }
bool dw_focus_identity(pid_t p,CGWindowID w,DWFocusIdentity *out) {
    if(!out)return false;*out=(DWFocusIdentity){0};DWFocusIdentity i={.pid=p,.window=w};
    if(!dw_focus_birth(p,&i.seconds,&i.microseconds)||!dw_focus_owner(i,NULL))return false;*out=i;return true;
}
static AXError timeout(AXUIElementRef w,double end) { return DWAXTimeout(w,end,.1); }
static AXError copy(AXUIElementRef w,CFStringRef key,CFTypeRef *v,double end) { AXError e=timeout(w,end);return e==kAXErrorSuccess?AXUIElementCopyAttributeValue(w,key,v):e; }
static void log_window_lookup(AXUIElementRef element,pid_t expectedPID,uint32_t expectedWindow,CFIndex index,AXError error,double end) { DWAXLogWindowLookup("focus",.1,element,expectedPID,expectedWindow,index,error,end); }
static bool windowless_scroll_area(AXUIElementRef element,pid_t expectedPID,double end) { return DWAXWindowlessScrollArea(element,expectedPID,end,.1); }
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
        if(CFGetTypeID(w)!=AXUIElementGetTypeID()||(r->ax_error=timeout(w,end))){r->outcome=DWFocusUnavailable;valid=false;break;}
        r->ax_error=get(w,&wid);
        if(r->ax_error==kAXErrorIllegalArgument&&windowless_scroll_area(w,i.pid,end)){r->ax_error=kAXErrorSuccess;continue;}
        if(r->ax_error){log_window_lookup(w,i.pid,i.window,n,r->ax_error,end);r->outcome=DWFocusUnavailable;valid=false;break;}
        if(wid==i.window){if((r->ax_error=AXUIElementGetPid(w,&pid))||pid!=i.pid){valid=false;r->outcome=DWFocusStale;break;}matches++;if(!found)found=(AXUIElementRef)CFRetain(w);}
    }
    CFRelease(list);
    if(valid&&matches==1&&dw_focus_owner(i,&r->bounds))return found;
    if(valid)r->outcome=matches>1?DWFocusAmbiguous:matches==0?DWFocusMissing:DWFocusStale;
    if(found)CFRelease(found);return NULL;
}
bool dw_focus_minimized(DWFocusIdentity identity,bool *minimized) { @autoreleasepool {
    if(!minimized)return false;
    double end=now()+.08;DWFocusResult result={0};AXUIElementRef window=resolve(identity,end,&result);if(!window)return false;
    CFTypeRef value=NULL;AXError error=copy(window,kAXMinimizedAttribute,&value,end);CFRelease(window);
    bool known=error==kAXErrorSuccess&&value&&CFGetTypeID(value)==CFBooleanGetTypeID()&&now()<end&&dw_focus_owner(identity,NULL);
    if(known)*minimized=CFBooleanGetValue(value);
    if(value)CFRelease(value);return known;
} }
DWFocusResult dw_focus_set_minimized(DWFocusIdentity identity,bool minimized,DWFocusGuard guard,void *context) { @autoreleasepool {
    DWFocusResult result={.outcome=DWFocusDenied};double end=now()+.5;
    if(!guard||!guard(identity,context))return result;
    AXUIElementRef window=resolve(identity,end,&result);if(!window)return result;
    if(!guard(identity,context)||!dw_focus_owner(identity,NULL)||now()>=end){CFRelease(window);result.outcome=DWFocusStale;return result;}
    result.ax_error=timeout(window,end);
    if(!result.ax_error){result.mutation_attempted=true;result.ax_error=AXUIElementSetAttributeValue(window,kAXMinimizedAttribute,minimized?kCFBooleanTrue:kCFBooleanFalse);}
    CFRelease(window);result.outcome=result.ax_error?DWFocusAXFailed:DWFocusObserved;return result;
} }
static bool focusedWindow(AXUIElementRef app,pid_t expected,CGWindowID *wid,double end,AXError *e) {
    CFTypeRef w=NULL;*e=copy(app,kAXFocusedWindowAttribute,&w,end);pid_t pid=0;
    GetWindow get=(GetWindow)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    bool ok=!*e&&w&&CFGetTypeID(w)==AXUIElementGetTypeID()&&get;
    if(ok)ok=!(*e=timeout(w,end))&&!(*e=AXUIElementGetPid(w,&pid))&&pid==expected&&!(*e=get(w,wid));
    if(w)CFRelease(w);return ok;
}
bool dw_focus_frontmost(DWFocusIdentity *out) { @autoreleasepool {
    if(!out)return false;*out=(DWFocusIdentity){0};
    double end=now()+.05;
    DWFocusIdentity i={.pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier};
    if(i.pid<=0||!dw_focus_birth(i.pid,&i.seconds,&i.microseconds)||!AXIsProcessTrusted()||now()>=end)return false;
    AXUIElementRef app=AXUIElementCreateApplication(i.pid);if(!app)return false;
    AXError error=kAXErrorSuccess;
    bool known=focusedWindow(app,i.pid,&i.window,end,&error);
    CFRelease(app);
    if(!known||now()>=end||!dw_focus_owner(i,NULL)||!fresh(i)
        ||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=i.pid||now()>=end)return false;
    *out=i;return true;
} }
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
    if(!dw_focus_owner(i,&cg)){r->outcome=DWFocusStale;return false;}
    // The frame changed while it was read: the canvas's own size request, or the application's, was under way. What was read
    // is of no one moment, so it is read again; the window is the same window (process, start time and number above).
    if(!CGRectEqualToRect(cg,r->bounds)){r->bounds=cg;r->outcome=DWFocusReadbackFailed;return false;}
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
    // Stale is another window: its process, start time or number no longer the one asked for. A frame that moved or
    // changed size is the same window, and a size request made a moment before a click changes it under this very
    // request (a click after a fit ended stale_identity_or_bounds and was dropped, twice in the sizing test's runs).
    CGRect b;if(!dw_focus_owner(i,&b)){r->outcome=DWFocusStale;return false;}r->bounds=b;return true;
}
// A window on another desktop (Space) is in the window server's list and not in its application's Accessibility list while
// another desktop is shown, so resolve() answers DWFocusMissing for it and nothing above can reach it (the owner's run of
// 2026-10-10: fourteen requests for one window, each missing_window). It is brought forward the way yabai focuses a window,
// by the window server and by window number: macOS then shows the window's desktop, and the window is waited for in the
// Accessibility list, inside the caller's deadline. A symbol or serial number that is not to be had, or a window that is on
// screen, leaves the answer as it was. Never run on a window of another desktop: nothing that builds here can put one there.
static AXUIElementRef forward(DWFocusIdentity i,DWFocusGuard guard,void *ctx,double end,DWFocusResult *r) {
    FrontWithOptions front=(FrontWithOptions)dlsym(RTLD_DEFAULT,"_SLPSSetFrontProcessWithOptions");
    PostEventRecord post=(PostEventRecord)dlsym(RTLD_DEFAULT,"SLPSPostEventRecordTo");
    ProcessForPID serial=(ProcessForPID)dlsym(RTLD_DEFAULT,"GetProcessForPID");ProcessSerialNumber psn={0};
    if(!front||!post||!serial||serial(i.pid,&psn)!=noErr)return NULL;
    // Only a window that is not on screen, which one on another desktop is not. One the window server shows here and that its
    // application leaves out of the list would have that application fronted for nothing, so it stays missing.
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,i.window));
    if(list.count!=1||[list[0][(id)kCGWindowIsOnscreen] boolValue])return NULL;
    // The window server must still list the window as this process's, where resolve() saw it, and the caller must allow it.
    if(!allowed(i,guard,ctx,end,r))return NULL;
    r->mutation_attempted=true;r->brought_forward=true;
    // yabai dd845723416f5fe92af49fad5ebab00369e07edd src/window_manager.c:1329-1330, 1280-1290; 0x200 is kCPSUserGenerated.
    front(&psn,i.window,0x200);
    uint8_t bytes[0xf8]={0};bytes[0x04]=0xf8;bytes[0x3a]=0x10;memcpy(bytes+0x3c,&i.window,sizeof(uint32_t));memset(bytes+0x20,0xff,0x10);
    bytes[0x08]=0x01;post(&psn,bytes);
    bytes[0x08]=0x02;post(&psn,bytes);
    // The application is in front from here on, so the wait goes on through an answer that may pass (the list not read, the
    // window not in it yet) and ends on one that will not, or when the guard or the deadline ends it.
    while(allowed(i,guard,ctx,end,r)) {
        AXUIElementRef w=resolve(i,end,r);if(w)return w;
        if(r->outcome==DWFocusStale||r->outcome==DWFocusAmbiguous)break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.015]];
    }
    return NULL;
}
DWFocusResult dw_focus_select(DWFocusIdentity i,DWFocusGuard guard,void *ctx) { @autoreleasepool {
    DWFocusResult r={.outcome=DWFocusInvalid};if(!guard)return r;
    double end=now()+1.5;AXUIElementRef w=resolve(i,end,&r);
    if(!w&&r.outcome==DWFocusMissing)w=forward(i,guard,ctx,end,&r);
    if(!w)return r;
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
