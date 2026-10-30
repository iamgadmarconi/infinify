// SPDX-License-Identifier: GPL-3.0-or-later
// Process, window-list, pointer, screen and JSON helpers shared across the desktop shell, and the run's stop flag.
#import <AppKit/AppKit.h>
#import <signal.h>
#import "DWAXLookup.h"
#import "DWTypedValue.h"
// The run stops when this is set: a signal, the quit action, a closed chooser. Defined in main.m.
extern volatile sig_atomic_t stopped;
static inline NSArray *birth(pid_t pid) {
    uint64_t seconds=0,microseconds=0;
    if (!DWProcessBirth(pid,&seconds,&microseconds)) return nil;
    return @[@(seconds),@(microseconds)];
}
static inline NSDictionary *windowInfo(uint32_t wid) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));
    for (NSDictionary *w in windows) if ([w[(id)kCGWindowNumber] unsignedIntValue] == wid) return w;
    return nil;
}
static inline CGPoint pointer(void) { CGEventRef e=CGEventCreate(NULL); CGPoint p=CGEventGetLocation(e); CFRelease(e); return p; }

// AppKit services the main run loop while waiting for an event, including
// dispatch blocks and timer/display callbacks. One deadline covers the wait.
// Events wake this wait immediately; a nonblocking turn after delivery also
// services callbacks when a continuous event stream never lets AppKit wait.
static inline void DWDesktopPump(double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES];
        if(event){[NSApp sendEvent:event];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0,true);}
    } while(!stopped&&deadline.timeIntervalSinceNow>0);
}

static inline NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static inline CGPoint jsonPoint(NSDictionary *p) { return CGPointMake([p[@"x"] doubleValue],[p[@"y"] doubleValue]); }
static inline CGFloat screenTop(void) { return NSMaxY(NSScreen.screens.firstObject.frame); }
static inline CGRect topRect(NSRect r) { return CGRectMake(r.origin.x,screenTop()-NSMaxY(r),r.size.width,r.size.height); }
// AppKit sends screen-parameter notices for changes such as the Dock's usable
// rectangle as well as actual display changes. Only physical display geometry,
// density or cadence changes require new output layers. In particular a
// windowed canvas must retain its panel through a visibleFrame-only notice.
static inline NSDictionary *physicalScreens(void) {
    NSMutableDictionary *displays=[NSMutableDictionary dictionary];
    for(NSScreen *screen in NSScreen.screens){NSNumber *number=screen.deviceDescription[@"NSScreenNumber"];if(!number)continue;
        displays[number]=@{@"frame":NSStringFromRect(screen.frame),@"scale":@(screen.backingScaleFactor),@"fps":@(screen.maximumFramesPerSecond)};}
    return @{@"displays":displays,@"top":@(screenTop())};
}
static inline NSArray *asArray(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
// Is `named`, an identity the controller wrote, exactly the one this shell bound? The
// shell binds no WindowServer owner, so a named one never matches.
static inline BOOL boundIdentity(NSDictionary *bound,NSDictionary *named) {
    if(!bound||!DWTyped(named,NSDictionary.class)||DWTyped(named[@"owner"],NSNumber.class))return NO;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(!DWTyped(named[key],NSNumber.class)||![bound[key]isEqual:named[key]])return NO;
    return YES;
}
// The effect of a native size transaction in a controller reply, or nil. A sizing action's reply carries it under "effect",
// the key begin_native_resize answers with; an entry of "effects" is read the same way, which is where the attach of a window
// whose rule names a size carries it, its "effect" being the focus request.
static inline NSDictionary *sizeEffect(NSDictionary *reply) {
    for(id effect in [@[reply[@"effect"]?:NSNull.null] arrayByAddingObjectsFromArray:asArray(reply[@"effects"])]){NSString *op=DWTyped(DWTyped(effect,NSDictionary.class)[@"op"],NSString.class);if([op isEqual:@"observe_resize_source"]||[op isEqual:@"resize_native_window"])return effect;}
    return nil;
}
// Physical modifiers as the controller reads them: JSON booleans, since a boxed comparison would be sent as 0 or 1.
static inline NSDictionary *modifiersJSON(NSEventModifierFlags flags) { return @{@"control":flags&NSEventModifierFlagControl?@YES:@NO,@"option":flags&NSEventModifierFlagOption?@YES:@NO,@"shift":flags&NSEventModifierFlagShift?@YES:@NO,@"command":flags&NSEventModifierFlagCommand?@YES:@NO}; }
// The first line and how many follow: the resting status has room for one.
static inline NSString *summary(NSString *subject,NSArray<NSString *> *lines) { return [NSString stringWithFormat:@"%@: %@%@",subject,lines[0],lines.count>1?[NSString stringWithFormat:@" (+%lu more)",(unsigned long)lines.count-1]:@""]; }
// Said once per run, on stderr and in the resting status, when a normal run has no Accessibility access.
static NSString *const focusAccessNote=@"Native window focus needs Accessibility access: focus is logical only; navigation still works.";
