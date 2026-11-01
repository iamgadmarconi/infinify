// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativeResize.h"
#import "DWAXLookup.h"
#import <AppKit/AppKit.h>
#include <libproc.h>
#include <dlfcn.h>
#include <math.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Signature precedent: yabai (https://github.com/asmvik/yabai, MIT) commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:8 and src/misc/helpers.h:499-504. No upstream implementation copied.
// Licence text: native/app/Resources/YABAI-NOTICE.txt.
typedef AXError (*WindowIDFunction)(AXUIElementRef, uint32_t *);
static double now(void) { return DWMonotonicSeconds(); }
static bool birth(pid_t pid, uint64_t *sec, uint64_t *usec) { return DWProcessBirth(pid,sec,usec); }
static bool valid_rect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height) && r.size.width>0 && r.size.height>0;
}
static bool (*own_bounds)(uint32_t, CGRect *);
void dw_resize_set_bounds(bool (*read)(uint32_t, CGRect *)) { own_bounds=read; }
static DWResizeMoveOutcome (*mover)(DWResizeIdentity, CGPoint);
void dw_resize_set_mover(DWResizeMoveOutcome (*move)(DWResizeIdentity, CGPoint)) { mover=move; }
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
static DWResizeResult result(DWResizeOutcome o) { return (DWResizeResult){.outcome=o,.ax_error=kAXErrorSuccess}; }
static AXError timeout(AXUIElementRef element, double deadline) { return DWAXTimeout(element,deadline,.15); }
static void log_window_lookup(AXUIElementRef element,pid_t expectedPID,uint32_t expectedWindow,CFIndex index,AXError error,double deadline) { DWAXLogWindowLookup("resize",.15,element,expectedPID,expectedWindow,index,error,deadline); }
static bool windowless_scroll_area(AXUIElementRef element,pid_t expectedPID,double deadline) { return DWAXWindowlessScrollArea(element,expectedPID,deadline,.15); }
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
        if (e==kAXErrorIllegalArgument && windowless_scroll_area(w,i.pid,deadline)) continue;
        // Unknown elements and real-window errors must not hide a second match.
        if (e!=kAXErrorSuccess) { log_window_lookup(w,i.pid,i.window,n,e,deadline); r->ax_error=e; r->outcome=DWResizeUnavailable; break; }
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
static bool same_frame(CGRect a,CGRect b) { return same_size(a.size,b.size)&&near(a.origin.x,b.origin.x)&&near(a.origin.y,b.origin.y); }
// Where the window has to sit for `size` to be granted. macOS does not let an Accessibility size change carry a window past the
// available frame of its screen: from an origin the size does not fit from, the request changes nothing (the owner's run of
// 2026-10-10: 2056x1329 asked four times of a window at (223,39) on a 2056x1329 display, answered each time with the 1833x1290
// that reaches the screen's edges). The window is moved once, on each axis the request grows on and would overflow, to the frame's
// origin on that axis: the most room the screen has, so that the sizes a drag asks next from that same place need no further move.
// (The least move that makes room was tried first, 2026-10-30: dragging an edge past the screen moved the window 4 to 7 times by
// a few points each, each move a jump of the drawn window until the shell re-based on the origin the result reported.) A size
// larger than the frame is then asked as it is, so that the application grants what it can. Match the canvas's menu/notch-only
// exclusion: the Dock overlays it and must not make this preparatory move ask for less room. AX readback still reports any
// stricter limit the application actually enforces.
// The screen is the one that holds most of the window; a window on none is left alone.
// AppKit's screens are measured upwards from the primary screen's lower left corner, Accessibility downwards from its top left.
static bool visible_frame(CGRect before, CGRect *visible) {
    NSArray<NSScreen *> *screens=NSScreen.screens; if (!screens.count) return false;
    CGFloat top=NSMaxY(screens[0].frame), most=0; CGRect found=CGRectZero;
    for (NSScreen *screen in screens) {
        NSRect f=screen.frame;CGFloat inset=MAX(screen.safeAreaInsets.top,MAX(0,NSMaxY(f)-NSMaxY(screen.visibleFrame)));
        inset=isfinite(inset)?MIN(ceil(inset),MAX(0,f.size.height-1)):0;
        NSRect v=NSMakeRect(f.origin.x,f.origin.y,f.size.width,f.size.height-inset);
        CGRect shared=CGRectIntersection(before,CGRectMake(f.origin.x,top-NSMaxY(f),f.size.width,f.size.height));
        if (CGRectIsNull(shared) || shared.size.width*shared.size.height<=most) continue;
        most=shared.size.width*shared.size.height; found=CGRectMake(v.origin.x,top-NSMaxY(v),v.size.width,v.size.height);
    }
    if (most<=0 || !valid_rect(found)) return false;
    *visible=found; return true;
}
static bool room(CGRect before, CGSize size, CGPoint *to) {
    CGRect visible; if (!visible_frame(before,&visible)) return false;
    CGPoint p=before.origin;
    if (size.width>before.size.width && p.x+size.width>CGRectGetMaxX(visible)) p.x=CGRectGetMinX(visible);
    if (size.height>before.size.height && p.y+size.height>CGRectGetMaxY(visible)) p.y=CGRectGetMinY(visible);
    *to=p; return !CGPointEqualToPoint(p,before.origin);
}
// A size that stops short of the request on an axis where the request reaches past the screen's visible frame from where the window is
// is that frame's limit and final: AppKit constrains the frame to it (measured on macOS 27.0.1, 2026-10-30: TextEdit, Terminal, Finder,
// Safari, Chrome and Ghostty all end at the visible frame's far edge or within a few points of it, whether sized by AX or by AppleScript,
// from every order of position and size, with AXEnhancedUserInterface off or on). No second read can change it, so none is waited for.
static bool screen_limited(CGRect actual, CGSize size) {
    CGRect visible; if (!visible_frame(actual,&visible)) return false;
    bool narrow=size.width>actual.size.width+1 && actual.origin.x+size.width>CGRectGetMaxX(visible)+1;
    bool short_=size.height>actual.size.height+1 && actual.origin.y+size.height>CGRectGetMaxY(visible)+1;
    return (narrow||short_) && (narrow||near(actual.size.width,size.width)) && (short_||near(actual.size.height,size.height));
}
static bool readback_once(DWResizeIdentity i, AXUIElementRef window, double deadline, DWResizeResult *r, bool *frame_disagreement) {
    if(frame_disagreement)*frame_disagreement=false;
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
        if(frame_disagreement)*frame_disagreement=ok&&valid_rect(ax);
        r->outcome=now()>=deadline ? DWResizeTimedOut : DWResizeReadbackFailed; return false;
    }
    r->actual_ax=ax; r->actual_cg=cg; r->observed=true; return true;
}
static bool readback(DWResizeIdentity i, AXUIElementRef window, double deadline, DWResizeResult *r) {
    for (;;) {
        if (readback_once(i,window,deadline,r,NULL)) return true;
        // A busy owner can time out a read even though it remains available.
        // Retry the complete observation with fresh identity and geometry, never
        // a setter. Permanent errors and AX/CG disagreement still fail closed.
        if (r->outcome==DWResizeStaleIdentity || r->ax_error!=kAXErrorCannotComplete) return false;
        double remaining=deadline-now();
        if (remaining<=0) { r->outcome=DWResizeTimedOut; return false; }
        usleep((useconds_t)ceil(fmin(.03,remaining)*1e6));
    }
}
DWResizeResult dw_resize_observe(DWResizeIdentity i) { @autoreleasepool {
    DWResizeResult r=result(DWResizeObserved); double deadline=now()+2.; AXUIElementRef w=resolve(i,deadline,&r);
    if (w) { if (readback(i,w,deadline,&r)) r.outcome=DWResizeObserved; CFRelease(w); } return r;
} }
static bool fill_attribute(AXUIElementRef element,CFStringRef attribute,double deadline,bool optional,CFTypeRef *value,DWResizeResult *r) {
    *value=NULL;r->ax_error=timeout(element,deadline);
    if(r->ax_error==kAXErrorSuccess)r->ax_error=AXUIElementCopyAttributeValue(element,attribute,value);
    if(optional&&(r->ax_error==kAXErrorAttributeUnsupported||r->ax_error==kAXErrorNoValue)) {r->ax_error=kAXErrorSuccess;return true;}
    if(r->ax_error!=kAXErrorSuccess){r->outcome=now()>=deadline?DWResizeTimedOut:DWResizeUnavailable;return false;}
    return true;
}
static bool fill_focused(DWResizeIdentity i,AXUIElementRef app,double deadline,bool requireFrontmost,DWResizeResult *r) {
    CFTypeRef front=NULL,focused=NULL;bool ok=true;
    if(requireFrontmost){ok=fill_attribute(app,kAXFrontmostAttribute,deadline,false,&front,r);
        ok=ok&&front&&CFGetTypeID(front)==CFBooleanGetTypeID()&&CFBooleanGetValue((CFBooleanRef)front);}
    // Restore may owe an old app's Fill after focus moved elsewhere. Its menu
    // must still target this exact app-local focused window; never activate it.
    if(ok)ok=fill_attribute(app,kAXFocusedWindowAttribute,deadline,false,&focused,r);
    if(ok){pid_t pid=0;uint32_t wid=0;WindowIDFunction getWindow=(WindowIDFunction)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
        ok=focused&&CFGetTypeID(focused)==AXUIElementGetTypeID()&&getWindow;
        if(ok){r->ax_error=timeout((AXUIElementRef)focused,deadline);if(!r->ax_error)r->ax_error=getWindow((AXUIElementRef)focused,&wid);
            ok=!r->ax_error&&wid==i.window&&!AXUIElementGetPid((AXUIElementRef)focused,&pid)&&pid==i.pid;}
    }
    if(front)CFRelease(front);if(focused)CFRelease(focused);
    if(!ok){if(r->outcome!=DWResizeTimedOut)r->outcome=DWResizeUnavailable;return false;}
    if(!owner(i,NULL)){r->outcome=DWResizeStaleIdentity;r->observed=false;return false;}return true;
}
// Real macOS 27 menus expose Fill directly (depth3) and Return to Previous Size
// in one submenu (depth5). Match identifiers only at the observed depth, never
// translated titles. Descend no further into unrelated application menus.
static bool fill_menu(AXUIElementRef element,DWResizeIdentity i,double deadline,CFStringRef actionIdentifier,unsigned itemDepth,unsigned depth,unsigned *remaining,AXUIElementRef *found,unsigned *matches,DWResizeResult *r) {
    if(!*remaining||depth>itemDepth||now()>=deadline){r->outcome=now()>=deadline?DWResizeTimedOut:DWResizeUnavailable;return false;}(*remaining)--;
    pid_t pid=0;if(AXUIElementGetPid(element,&pid)||pid!=i.pid){r->outcome=DWResizeStaleIdentity;return false;}
    CFTypeRef role=NULL,identifier=NULL,children=NULL;bool ok=fill_attribute(element,kAXRoleAttribute,deadline,false,&role,r);
    CFStringRef roles[]={kAXMenuBarRole,kAXMenuBarItemRole,kAXMenuRole,kAXMenuItemRole,kAXMenuRole,kAXMenuItemRole};bool item=depth==itemDepth;
    if(ok)ok=role&&CFGetTypeID(role)==CFStringGetTypeID()&&CFEqual(role,roles[depth]);
    if(ok&&item){ok=fill_attribute(element,kAXIdentifierAttribute,deadline,true,&identifier,r);
        if(ok&&identifier){if(CFGetTypeID(identifier)!=CFStringGetTypeID())ok=false;
            else if(CFEqual(identifier,actionIdentifier)){(*matches)++;if(!*found)*found=(AXUIElementRef)CFRetain(element);}}
    }
    if(ok&&!item)ok=fill_attribute(element,kAXChildrenAttribute,deadline,true,&children,r);
    if(ok&&children){ok=CFGetTypeID(children)==CFArrayGetTypeID();if(ok)for(CFIndex n=0;n<CFArrayGetCount((CFArrayRef)children);n++){
        AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)children,n);
        if(CFGetTypeID(child)!=AXUIElementGetTypeID()||!fill_menu(child,i,deadline,actionIdentifier,itemDepth,depth+1,remaining,found,matches,r)){ok=false;break;}
    }}
    if(role)CFRelease(role);if(identifier)CFRelease(identifier);if(children)CFRelease(children);
    if(!ok&&r->outcome!=DWResizeTimedOut&&r->outcome!=DWResizeStaleIdentity)r->outcome=DWResizeUnavailable;return ok;
}
static DWResizeResult menu_resize(DWResizeIdentity i,CGSize requested,const CGRect *savedFrame) { @autoreleasepool {
    DWResizeResult r=result(DWResizeInvalidRequest);r.requested=requested;
    if(!isfinite(requested.width)||!isfinite(requested.height)||requested.width<1||requested.height<1||requested.width>32768||requested.height>32768||(savedFrame&&!valid_rect(*savedFrame)))return r;
    double deadline=now()+2.;AXUIElementRef w=resolve(i,deadline,&r);if(!w)return r;
    AXUIElementRef app=AXUIElementCreateApplication(i.pid),action=NULL;CFTypeRef menu=NULL,enabled=NULL;CFArrayRef actions=NULL;
    bool eligible=readback(i,w,deadline,&r)&&fill_focused(i,app,deadline,savedFrame==NULL,&r);CGRect before=r.actual_ax;
    if(eligible){eligible=fill_attribute(app,kAXMenuBarAttribute,deadline,true,&menu,&r);
        if(eligible&&!menu){r.outcome=DWResizeUnsupported;eligible=false;}
        else if(eligible&&CFGetTypeID(menu)!=AXUIElementGetTypeID()){r.outcome=DWResizeUnavailable;eligible=false;}
    }
    if(eligible){unsigned remaining=512,matches=0;eligible=fill_menu((AXUIElementRef)menu,i,deadline,savedFrame?CFSTR("_zoomUntile:"):CFSTR("_zoomFill:"),savedFrame?5:3,0,&remaining,&action,&matches,&r);
        if(eligible&&matches!=1){r.outcome=matches?DWResizeUnavailable:DWResizeUnsupported;eligible=false;}
    }
    if(eligible){eligible=fill_attribute(action,kAXEnabledAttribute,deadline,false,&enabled,&r);
        if(eligible&&(!enabled||CFGetTypeID(enabled)!=CFBooleanGetTypeID())){r.outcome=DWResizeUnavailable;eligible=false;}
        else if(eligible&&!CFBooleanGetValue((CFBooleanRef)enabled)){r.outcome=DWResizeUnsupported;eligible=false;}
    }
    if(eligible){r.ax_error=timeout(action,deadline);if(!r.ax_error)r.ax_error=AXUIElementCopyActionNames(action,&actions);
        if(r.ax_error){r.outcome=now()>=deadline?DWResizeTimedOut:DWResizeUnavailable;eligible=false;}
        else if(!actions||!CFArrayContainsValue(actions,CFRangeMake(0,CFArrayGetCount(actions)),kAXPressAction)){r.outcome=DWResizeUnsupported;eligible=false;}
    }
    // Menu discovery can take time. Revalidate the focused exact window and its
    // native baseline immediately before the single action; never activate it.
    if(eligible){eligible=readback(i,w,deadline,&r)&&fill_focused(i,app,deadline,savedFrame==NULL,&r);before=r.actual_ax;}
    if(eligible){r.ax_error=timeout(action,deadline);if(r.ax_error||now()>=deadline){r.outcome=DWResizeTimedOut;eligible=false;}}
    if(eligible){
        r.mutation_attempted=true;r.observed=false;
        AXError pressed=AXUIElementPerformAction(action,kAXPressAction);double sent=now(),stableSince=sent;CGRect stableFrame=CGRectZero;bool haveStableFrame=false,stable=false;
        r.outcome=DWResizeReadbackFailed;
        while(now()<deadline){
            bool disagreement=false;
            if(!readback_once(i,w,deadline,&r,&disagreement)){
                // AppKit animates these actions. AX and native reads can sample
                // different animation frames; neither is accepted as a result.
                // Retry observation only, resetting the complete quiet interval.
                haveStableFrame=false;stable=false;
                if(r.outcome==DWResizeStaleIdentity||(!disagreement&&r.ax_error!=kAXErrorCannotComplete))break;
                double remaining=deadline-now();if(remaining>0)usleep((useconds_t)ceil(fmin(.03,remaining)*1e6));
                continue;
            }
            CGRect actual=r.actual_ax;double sampled=now();
            // Compare with the start of the quiet interval, not the preceding
            // sample: individually subpixel changes may accumulate into motion.
            bool same=haveStableFrame&&same_size(stableFrame.size,actual.size)&&near(stableFrame.origin.x,actual.origin.x)&&near(stableFrame.origin.y,actual.origin.y);
            if(!same){stableSince=sampled;stableFrame=actual;}haveStableFrame=true;
            stable=same&&sampled-stableSince>=.15;
            bool changed=!same_size(before.size,actual.size)||!near(before.origin.x,actual.origin.x)||!near(before.origin.y,actual.origin.y);
            // Untile can pause before a later animation update. Observe its
            // full existing budget before the caller corrects the saved frame;
            // an early quiet plateau must not let AppKit overwrite that fix.
            if(!savedFrame&&stable&&changed&&sampled-sent>=.25)break;
            double remaining=deadline-now();if(remaining>0)usleep((useconds_t)ceil(fmin(.03,remaining)*1e6));
        }
        if(r.observed&&stable){
            if(savedFrame)r.outcome=same_frame(*savedFrame,r.actual_ax)?DWResizeApplied:(same_frame(before,r.actual_ax)?DWResizeRejected:DWResizeClamped);
            else r.outcome=same_size(requested,r.actual_ax.size)?DWResizeApplied:(!same_size(before.size,r.actual_ax.size)?DWResizeClamped:DWResizeRejected);
            r.moved=!CGPointEqualToPoint(before.origin,r.actual_ax.origin);
        }
        else {r.observed=false;if(now()>=deadline&&r.outcome!=DWResizeStaleIdentity)r.outcome=DWResizeTimedOut;}
        if(pressed!=kAXErrorSuccess)r.ax_error=pressed;
    }
    // A preflight refusal has no final observation except Unsupported, whose
    // valid baseline permits the caller's explicit ordinary-size fallback.
    if(!r.mutation_attempted&&r.outcome!=DWResizeUnsupported)r.observed=false;
    if(actions)CFRelease(actions);if(enabled)CFRelease(enabled);if(menu)CFRelease(menu);if(action)CFRelease(action);CFRelease(app);CFRelease(w);return r;
} }
DWResizeResult dw_resize_fill(DWResizeIdentity i,CGSize requested) {return menu_resize(i,requested,NULL);}
DWResizeResult dw_resize_unfill(DWResizeIdentity i,CGRect savedFrame) {return menu_resize(i,savedFrame.size,&savedFrame);}
static bool reposition_readback(DWResizeIdentity i,AXUIElementRef w,double deadline,DWResizeResult *r) {
    while(now()<deadline){
        bool disagreement=false;
        if(readback_once(i,w,fmin(deadline,now()+.05),r,&disagreement))return true;
        if(r->outcome==DWResizeStaleIdentity||(!disagreement&&r->ax_error!=kAXErrorCannotComplete))return false;
        double remaining=deadline-now();if(remaining>0)usleep((useconds_t)ceil(fmin(.01,remaining)*1e6));
    }
    r->outcome=DWResizeTimedOut;r->observed=false;return false;
}
DWResizeResult dw_resize_reposition(DWResizeIdentity i,CGRect expectedBefore,CGPoint origin,double absoluteDeadline) { @autoreleasepool {
    DWResizeResult r=result(DWResizeInvalidRequest);r.requested=expectedBefore.size;
    if(!valid_rect(expectedBefore)||expectedBefore.size.width<1||expectedBefore.size.height<1||expectedBefore.size.width>32768||expectedBefore.size.height>32768||!isfinite(origin.x)||!isfinite(origin.y)||!isfinite(absoluteDeadline))return r;
    double deadline=fmin(absoluteDeadline,now()+.35);
    if(now()>=deadline){r.outcome=DWResizeTimedOut;r.ax_error=kAXErrorCannotComplete;return r;}
    AXUIElementRef w=resolve(i,fmin(deadline,now()+.05),&r);if(!w)return r;
    AXValueRef value=NULL;Boolean settable=false;CGRect current=CGRectZero,target={origin,expectedBefore.size};AXError setter=kAXErrorSuccess;
    r.ax_error=timeout(w,fmin(deadline,now()+.05));
    if(!r.ax_error)r.ax_error=AXUIElementIsAttributeSettable(w,kAXPositionAttribute,&settable);
    if(r.ax_error||!settable){r.outcome=r.ax_error==kAXErrorCannotComplete?DWResizeTimedOut:DWResizeUnsupported;goto finished;}
    if(!reposition_readback(i,w,deadline,&r))goto finished;
    // A display lease authorizes only the enrolled native baseline, not a
    // later user/app move. AX may round, but native bounds must match exactly.
    if(!CGRectEqualToRect(r.actual_cg,expectedBefore)||!same_frame(r.actual_ax,expectedBefore)){r.outcome=DWResizeUnavailable;r.observed=false;goto finished;}
    value=AXValueCreate(kAXValueCGPointType,&origin);
    if(!value){r.outcome=DWResizeUnavailable;r.observed=false;goto finished;}
    r.ax_error=timeout(w,fmin(deadline,now()+.05));
    if(r.ax_error){r.outcome=DWResizeTimedOut;r.observed=false;goto finished;}
    if(!owner(i,&current)){r.outcome=DWResizeStaleIdentity;r.observed=false;goto finished;}
    if(!CGRectEqualToRect(current,expectedBefore)){r.outcome=DWResizeUnavailable;r.observed=false;goto finished;}
    // No remote call follows this local lease check before the one setter.
    // Reserve its full configured timeout inside the independent update hold.
    if(now()+.05>deadline){r.outcome=DWResizeTimedOut;r.ax_error=kAXErrorCannotComplete;r.observed=false;goto finished;}
    r.mutation_attempted=true;r.observed=false;r.outcome=DWResizeReadbackFailed;
    setter=AXUIElementSetAttributeValue(w,kAXPositionAttribute,value);
    while(now()<deadline){
        if(!reposition_readback(i,w,deadline,&r))break;
        if(now()>=deadline)break;
        if(CGRectEqualToRect(r.actual_cg,target)&&same_frame(r.actual_ax,target)){r.outcome=DWResizeApplied;r.moved=!CGPointEqualToPoint(origin,expectedBefore.origin);goto finished;}
        double remaining=deadline-now();if(remaining>0)usleep((useconds_t)ceil(fmin(.01,remaining)*1e6));
    }
    r.observed=false;if(now()>=deadline&&r.outcome!=DWResizeStaleIdentity)r.outcome=DWResizeTimedOut;
finished:
    if(setter!=kAXErrorSuccess)r.ax_error=setter;
    if(value)CFRelease(value);CFRelease(w);return r;
} }
// Full-frame restoration must retain every setter attempt and timeout across
// its size/position stages; the result of a plain dw_resize_apply is not affected.
typedef struct { bool attempted, timed_out; } FrameMutation;
static void record_mutation(FrameMutation *m,AXError error) {
    if (m) { m->attempted=true; m->timed_out|=error==kAXErrorCannotComplete; }
}
static DWResizeResult frame_result(DWResizeResult r,FrameMutation m) {
    r.mutation_attempted|=m.attempted;
    if(m.timed_out)r.ax_error=kAXErrorCannotComplete;
    if(r.mutation_attempted) {
        switch(r.outcome) {
            case DWResizeInvalidRequest: case DWResizeUnavailable: case DWResizeMissingWindow:
            case DWResizeAmbiguousWindow: case DWResizeUnsupported:
                r.outcome=DWResizeReadbackFailed;r.observed=false;break;
            case DWResizeTimedOut:r.observed=false;break;
            default:break;
        }
    }
    return r;
}
static DWResizeResult apply_size(DWResizeIdentity i, CGSize size, double deadline, FrameMutation *mutation) { @autoreleasepool {
    DWResizeResult r=result(DWResizeInvalidRequest); r.requested=size;
    if (!isfinite(size.width)||!isfinite(size.height)||size.width<1||size.height<1||size.width>32768||size.height>32768) return r;
    AXUIElementRef w=resolve(i,deadline,&r); if (!w) return r;
    if (!readback(i,w,deadline,&r)) { CFRelease(w); return r; }
    CGRect before=r.actual_ax; Boolean settable=false;
    r.ax_error=timeout(w,deadline);
    if (r.ax_error==kAXErrorSuccess) r.ax_error=AXUIElementIsAttributeSettable(w,kAXSizeAttribute,&settable);
    if (r.ax_error!=kAXErrorSuccess || !settable) { r.outcome=DWResizeUnsupported; CFRelease(w); return r; }
    if (!owner(i,NULL)) { r.outcome=DWResizeStaleIdentity; r.observed=false; CFRelease(w); return r; }
    r.ax_error=timeout(w,deadline);
    if (r.ax_error!=kAXErrorSuccess) { r.outcome=DWResizeTimedOut; CFRelease(w); return r; }
    // Room first, by a native position write that the same identity and settable checks have just preceded. It is a
    // place on the real screen only: the caller maps the window by the origin every result reports and keeps its own geometry.
    // A write that fails or is not honoured changes nothing below: the size is asked from wherever the window then is.
    CGPoint origin=before.origin, to=origin; bool positioned=false;
    if (room(before,size,&to)) {
        DWResizeResult kept=r; bool seen=false;
        // The helper's move first, where there is one: it keeps a transformed window drawn where it is (dw_resize_set_mover).
        DWResizeMoveOutcome helped=mover?mover(i,to):DWResizeMoveDeclined;
        if (helped!=DWResizeMoveDeclined) { positioned=true; record_mutation(mutation,helped==DWResizeMoveMoved?kAXErrorSuccess:kAXErrorCannotComplete); }
        else { AXValueRef p=AXValueCreate(kAXValueCGPointType,&to);
            if (p) { positioned=true; record_mutation(mutation,AXUIElementSetAttributeValue(w,kAXPositionAttribute,p)); CFRelease(p); } }
        // As after the size: AX has the new origin when the setter returns and the window list a few ms later, so a read where they
        // disagree is retried in 2ms. An agreed origin that is not the one asked (the menu bar, a limit) holds when a second read,
        // 8ms on, shows it again. The shell re-bases the canvas on the origin this call reports; every ms spent here is a ms the drawn
        // window sits at the new native origin before that (measured at zoom .5 with a real drag: each move showed as a 165ms jump on a 30ms poll grid).
        double moveBegan=now();CGPoint lastOrigin=CGPointZero;bool haveOrigin=false;
        while (positioned && now()<deadline && now()-moveBegan<=.12) {
            seen=readback_once(i,w,deadline,&r,NULL);
            if (r.outcome==DWResizeStaleIdentity) { CFRelease(w); return r; }
            double wait=.002;
            if (seen) {
                if (near(r.actual_ax.origin.x,to.x) && near(r.actual_ax.origin.y,to.y)) break;
                if (haveOrigin && near(r.actual_ax.origin.x,lastOrigin.x) && near(r.actual_ax.origin.y,lastOrigin.y)) break;
                lastOrigin=r.actual_ax.origin;haveOrigin=true;wait=.008;
            } else haveOrigin=false;
            usleep((useconds_t)(wait*1e6));
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
    r.mutation_attempted=true;
    AXError setter=AXUIElementSetAttributeValue(w,kAXSizeAttribute,v); CFRelease(v);
    double returned=now(),readSeconds=0,sleepSeconds=0;int attempts=0;
    record_mutation(mutation,setter);
    r.observed=false; r.outcome=now()>=deadline?DWResizeTimedOut:DWResizeReadbackFailed;
    // Always read back even after an error: the receiver may have accepted a timed-out call.
    // An AX setter has completed in the app when it returns, but the window list shows the new frame a few milliseconds later, and a
    // read is only taken where AX and the window list agree; so a disagreement is retried at once (2ms), not on the old 30ms grid.
    // The first agreed read is the answer when it is the size asked for or the screen's own limit. Anything else (a minimum, a
    // maximum, an increment, an app's animation) is accepted when a second agreed read, 8ms later, shows the same size; a size still
    // moving is followed for up to 120ms after the setter, as before, and the last agreed read then stands.
    bool observed=false,havePrior=false;CGSize prior=CGSizeZero;double spacing=.008,pollSpacing=.002;DWResizeResult agreed=r;
    double until=returned+.12;
    while (now()<deadline && now()<=until) {
        double began=now();attempts++;bool disagreement=false;
        bool read=readback_once(i,w,deadline,&r,&disagreement);
        readSeconds+=now()-began;
        if (r.outcome==DWResizeStaleIdentity) {observed=false;break;}
        double wait=pollSpacing;
        if (read) {
            observed=true;agreed=r;
            if (same_size(size,r.actual_ax.size)||screen_limited(r.actual_ax,size)||(havePrior&&same_size(prior,r.actual_ax.size))) break;
            prior=r.actual_ax.size;havePrior=true;wait=spacing;
        } else {
            if (!disagreement&&r.ax_error!=kAXErrorCannotComplete) break;
            // A read that itself timed out ate the window: the owner is busy, not settled, so it is asked once more.
            if (r.ax_error==kAXErrorCannotComplete) until=fmax(until,now()+.03);
            havePrior=false;
        }
        double began2=now();usleep((useconds_t)(wait*1e6));sleepSeconds+=now()-began2;
    }
    // A read that failed after an agreed one leaves that one the answer: it was the last the owner and the window list agreed on.
    if (!observed&&now()>=deadline){r.observed=false;r.outcome=DWResizeTimedOut;}
    else if (observed&&!r.observed) {r=agreed;}
    const char *debug=getenv("INFINIFY_DEBUG");
    if(debug&&atoi(debug)==1)fprintf(stderr,"debug: native size settle pid=%d wid=%u attempts=%d elapsed_ms=%.3f read_ms=%.3f sleep_ms=%.3f requested=%gx%g observed=%d actual=%gx%g\n",i.pid,i.window,attempts,(now()-returned)*1000,readSeconds*1000,sleepSeconds*1000,size.width,size.height,observed,r.actual_ax.size.width,r.actual_ax.size.height);
    if (observed) r.outcome=same_size(size,r.actual_ax.size)?DWResizeApplied:(!same_size(before.size,r.actual_ax.size)?DWResizeClamped:DWResizeRejected);
    // Once per window: the canvas keeps the size the app took and later asks past it are answered from the first read, silently.
    if (observed&&debug&&atoi(debug)==1&&screen_limited(r.actual_ax,size)) {
        static NSMutableSet *told;static dispatch_once_t once;dispatch_once(&once,^{told=[NSMutableSet set];});
        NSString *key=[NSString stringWithFormat:@"%d/%u",i.pid,i.window];BOOL first;@synchronized(told){first=![told containsObject:key];[told addObject:key];}
        if(first)fprintf(stderr,"debug: native size limit pid=%d wid=%u requested=%gx%g actual=%gx%g at %g,%g: the screen's visible frame ends the window; the canvas keeps the size taken\n",i.pid,i.window,size.width,size.height,r.actual_ax.size.width,r.actual_ax.size.height,r.actual_ax.origin.x,r.actual_ax.origin.y);
    }
    if (setter!=kAXErrorSuccess) r.ax_error=setter;
    if (positioned && observed) r.moved=!CGPointEqualToPoint(r.actual_ax.origin,origin);
    CFRelease(w); return r;
} }
DWResizeResult dw_resize_apply(DWResizeIdentity i, CGSize size) { return apply_size(i,size,now()+2.,NULL); }
DWResizeResult dw_resize_apply_frame(DWResizeIdentity i, CGRect frame) { @autoreleasepool {
    DWResizeResult r=result(DWResizeInvalidRequest); r.requested=frame.size;
    if (!valid_rect(frame) || frame.size.width<1 || frame.size.height<1 || frame.size.width>32768 || frame.size.height>32768) return r;
    double deadline=now()+2.; AXUIElementRef w=resolve(i,deadline,&r); if (!w) return r;
    if (!readback(i,w,deadline,&r)) { CFRelease(w); return r; }
    CGRect before=r.actual_ax; Boolean settable=false;
    r.ax_error=timeout(w,deadline);
    if (r.ax_error==kAXErrorSuccess) r.ax_error=AXUIElementIsAttributeSettable(w,kAXPositionAttribute,&settable);
    if (r.ax_error!=kAXErrorSuccess || !settable) { r.outcome=DWResizeUnsupported; CFRelease(w); return r; }
    // Frame ordering precedent: yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd,
    // src/window_manager.c:729-762. No upstream implementation copied.
    // A window may stop accepting AXSize while keeping the saved extent.
    // Restoring only its origin must not require an unrelated size setter.
    FrameMutation mutation={0};
    bool resize=!CGSizeEqualToSize(before.size,frame.size);
    if (resize) {
        r=apply_size(i,frame.size,deadline,&mutation);
        r=frame_result(r,mutation);
        if (!r.observed || !r.mutation_attempted) { CFRelease(w); return r; }
    }
    if (!owner(i,NULL)) { r.outcome=DWResizeStaleIdentity; r.observed=false; CFRelease(w); return frame_result(r,mutation); }
    r.ax_error=timeout(w,deadline);
    if (r.ax_error!=kAXErrorSuccess) { r.outcome=DWResizeTimedOut; r.observed=false; CFRelease(w); return frame_result(r,mutation); }
    AXValueRef position=AXValueCreate(kAXValueCGPointType,&frame.origin);
    if (!position) { r.outcome=DWResizeReadbackFailed; r.observed=false; CFRelease(w); return frame_result(r,mutation); }
    r.mutation_attempted=true;
    AXError positionStatus=AXUIElementSetAttributeValue(w,kAXPositionAttribute,position); CFRelease(position);
    record_mutation(&mutation,positionStatus);
    r.observed=false; r.outcome=now()>=deadline?DWResizeTimedOut:DWResizeReadbackFailed;
    for (int n=0;n<5 && now()<deadline;n++) {
        if (n) usleep(30000);
        if (readback(i,w,deadline,&r) && near(r.actual_ax.origin.x,frame.origin.x) && near(r.actual_ax.origin.y,frame.origin.y)) break;
        if (r.outcome==DWResizeStaleIdentity) { CFRelease(w); return frame_result(r,mutation); }
    }
    if (!r.observed) { if(positionStatus!=kAXErrorSuccess)r.ax_error=positionStatus; CFRelease(w); return frame_result(r,mutation); }
    // Positioning may change the extent. Repeat size only when its fresh AX
    // and native CG readback do not both exactly match the saved dimensions.
    DWResizeResult sized=(CGSizeEqualToSize(r.actual_ax.size,frame.size) && CGSizeEqualToSize(r.actual_cg.size,frame.size))
        ? r : apply_size(i,frame.size,deadline,&mutation);
    sized.mutation_attempted|=r.mutation_attempted;
    if (!sized.observed && sized.mutation_attempted && (sized.outcome==DWResizeUnavailable || sized.outcome==DWResizeMissingWindow || sized.outcome==DWResizeAmbiguousWindow)) sized.outcome=DWResizeReadbackFailed;
    if (sized.observed) {
        CGRect actual=sized.actual_ax;
        BOOL exact=same_size(actual.size,frame.size)&&near(actual.origin.x,frame.origin.x)&&near(actual.origin.y,frame.origin.y);
        BOOL unchanged=same_size(actual.size,before.size)&&near(actual.origin.x,before.origin.x)&&near(actual.origin.y,before.origin.y);
        sized.outcome=exact?DWResizeApplied:(unchanged?DWResizeRejected:DWResizeClamped);
        sized.moved=!CGPointEqualToPoint(actual.origin,before.origin);
    }
    if (positionStatus!=kAXErrorSuccess) sized.ax_error=positionStatus;
    CFRelease(w); return frame_result(sized,mutation);
} }
const char *dw_resize_outcome_name(DWResizeOutcome o) {
    static const char *names[]={"observed","applied","clamped","rejected","invalid_request","stale_identity","unavailable","missing_window","ambiguous_window","unsupported","readback_failed","timed_out"};
    return o<=DWResizeTimedOut && o>=DWResizeObserved?names[o]:"unknown";
}
