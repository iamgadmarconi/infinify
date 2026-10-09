// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit owned resize mode only. Historical/production application classes stay unchanged.
@interface RPIsolationState : NSObject
@property (atomic) BOOL unexpectedInput,foregroundInterrupted,exclusionFailed,windowsExcluded;
@property (atomic) NSInteger firstRejectedType;
@property pid_t foreground;
@property NSArray *foregroundBirth;
@property NSDictionary *startup;
@end
@implementation RPIsolationState @end
static RPIsolationState *rpIsolation;
@interface RPIsolatedApplication : NSApplication @end
@implementation RPIsolatedApplication
- (void)sendEvent:(NSEvent *)event {
    // Only framework housekeeping reaches AppKit. Unknown future event kinds are
    // rejected too. No tag or synthetic-event exemption: scripted handles invoke
    // DesktopView methods directly and never enter the application event queue.
    switch(event.type){
        case NSEventTypeAppKitDefined:case NSEventTypeApplicationDefined:case NSEventTypePeriodic:break;
        default:rpIsolation.unexpectedInput=YES;if(!rpIsolation.firstRejectedType)rpIsolation.firstRejectedType=event.type;return;
    }
    [super sendEvent:event];
}
@end
@interface RPIsolatedWindow : NSWindow @end
@implementation RPIsolatedWindow
- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer {
    self=[super initWithContentRect:rect styleMask:style backing:backing defer:defer];if(self)self.ignoresMouseEvents=YES;return self;
}
- (BOOL)canBecomeKeyWindow{return NO;}
- (BOOL)canBecomeMainWindow{return NO;}
@end
@interface RPIsolatedPanel : CanvasPanel @end
@implementation RPIsolatedPanel
- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer {
    self=[super initWithContentRect:rect styleMask:style backing:backing defer:defer];if(self)self.ignoresMouseEvents=YES;return self;
}
- (BOOL)canBecomeKeyWindow{return NO;}
- (BOOL)canBecomeMainWindow{return NO;}
@end
static BOOL rpInputExcluded(void){return rpIsolation&&[NSApp isKindOfClass:RPIsolatedApplication.class]&&!rpIsolation.unexpectedInput&&!rpIsolation.foregroundInterrupted&&!rpIsolation.exclusionFailed;}
static BOOL rpWindowExcluded(NSWindow *w){
    return ([w isKindOfClass:RPIsolatedWindow.class]||[w isKindOfClass:RPIsolatedPanel.class])&&w.ignoresMouseEvents&&!w.canBecomeKeyWindow&&!w.canBecomeMainWindow&&!w.keyWindow&&!w.mainWindow;
}
static BOOL rpForegroundMatches(void){return rpIsolation&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==rpIsolation.foreground&&[birth(rpIsolation.foreground)isEqual:rpIsolation.foregroundBirth];}
static BOOL rpBeforeOrder(NSWindow *w){
    BOOL valid=rpForegroundMatches()&&rpWindowExcluded(w)&&rpInputExcluded();
    if(!valid)rpIsolation.exclusionFailed=YES;return valid;
}
// Main-thread AppKit inspection; workers use the atomic published flag plus the
// input/foreground latches. Unexpected delivery is dropped even between polls.
static BOOL rpCheckWindows(void){
    BOOL valid=rpInputExcluded();for(NSWindow *w in NSApp.windows)valid&=rpWindowExcluded(w);
    rpIsolation.windowsExcluded=valid;if(!valid)rpIsolation.exclusionFailed=YES;return valid;
}
static NSDictionary *rpIsolationDiagnostics(void){return @{@"dedicated_application":@([NSApp isKindOfClass:RPIsolatedApplication.class]),@"unexpected_input":@(rpIsolation.unexpectedInput),@"first_rejected_event_type":@(rpIsolation.firstRejectedType),@"foreground_interrupted":@(rpIsolation.foregroundInterrupted),@"exclusion_failed":@(rpIsolation.exclusionFailed),@"windows_excluded":@(rpIsolation.windowsExcluded)};}
static NSWindow *rpMakeWindow(NSRect frame,NSString *title,NSWindowStyleMask style){
    NSWindow *window=[[RPIsolatedWindow alloc]initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title=title;window.releasedWhenClosed=NO;window.animationBehavior=NSWindowAnimationBehaviorNone;window.hasShadow=NO;return window;
}
