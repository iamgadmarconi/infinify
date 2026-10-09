// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit owned resize mode only. Historical/production application classes stay unchanged.
@interface RPIsolationState : NSObject
@property (atomic) BOOL unexpectedInput,foregroundInterrupted,exclusionFailed,windowsExcluded;
@property (atomic) NSInteger firstRejectedType;
@property (atomic,copy) NSDictionary *firstWindowExclusionFailure;
@property (atomic,copy) NSDictionary *firstAcceptedInertHelper;
@property (atomic,copy) NSArray *lastSharingHelperScan;
@property (atomic,copy) NSDictionary *firstSharingHelperFailure;
@property NSArray *ownBirth;
@property NSMapTable<NSWindow *,NSNumber *> *registeredHelpers;
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
        // Passive tracking notifications are discarded without dispatch or
        // authorization. They never clear an already latched interruption.
        case NSEventTypeMouseEntered:case NSEventTypeMouseExited:case NSEventTypeCursorUpdate:return;
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
    BOOL known=[w isKindOfClass:RPIsolatedWindow.class]||[w isKindOfClass:RPIsolatedPanel.class];
    BOOL ignores=w.ignoresMouseEvents,canKey=w.canBecomeKeyWindow,canMain=w.canBecomeMainWindow,key=w.keyWindow,main=w.mainWindow;
    BOOL valid=known&&ignores&&!canKey&&!canMain&&!key&&!main;
    // Main-thread callers preserve the first actual window failure, even when
    // another sticky gate already failed. No title or application text is read.
    if(!valid&&!rpIsolation.firstWindowExclusionFailure)rpIsolation.firstWindowExclusionFailure=@{@"class":NSStringFromClass(w.class),@"window_id":@(w.windowNumber),@"visible":@(w.visible),@"known_isolated_class":@(known),@"ignores_mouse_events":@(ignores),@"can_become_key":@(canKey),@"can_become_main":@(canMain),@"is_key":@(key),@"is_main":@(main)};
    return valid;
}
static BOOL rpForegroundMatches(void){return rpIsolation&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==rpIsolation.foreground&&[birth(rpIsolation.foreground)isEqual:rpIsolation.foregroundBirth];}
static BOOL rpBeforeOrder(NSWindow *w){
    BOOL valid=rpForegroundMatches()&&rpWindowExcluded(w)&&rpInputExcluded();
    if(!valid)rpIsolation.exclusionFailed=YES;return valid;
}
// Main-thread AppKit inspection; workers use the atomic published flag plus the
// input/foreground latches. Unexpected delivery is dropped even between polls.
static BOOL rpCheckWindows(void){
    BOOL valid=rpInputExcluded();NSMutableArray *helpers=[NSMutableArray array];
    for(NSWindow *w in NSApp.windows){
        // Admit only the observed hidden, noninteractive sharing-helper state.
        // This enumeration-only exception never applies to owned window ordering
        // or direct root/decoy/child validation. Reevaluate every field each scan.
        BOOL inert=NO;
        if(w.class==NSClassFromString(@"NSLocalWindowSharingWindow")){
            NSInteger number=w.windowNumber;BOOL visible=w.visible,canKey=w.canBecomeKeyWindow,canMain=w.canBecomeMainWindow,key=w.keyWindow,main=w.mainWindow;
            NSNumber *frozen=[rpIsolation.registeredHelpers objectForKey:w];
            BOOL stable=!frozen||frozen.integerValue==number;
            NSDictionary *cg=number>0?windowInfo((uint32_t)number):nil;
            id cgID=cg[(id)kCGWindowNumber],owner=cg[(id)kCGWindowOwnerPID],onscreen=cg[(id)kCGWindowIsOnscreen];
            BOOL identity=[cgID isKindOfClass:NSNumber.class]&&[cgID longLongValue]==number&&[owner isKindOfClass:NSNumber.class]&&[owner intValue]==getpid();
            BOOL hidden=[onscreen isKindOfClass:NSNumber.class]&&![onscreen boolValue];
            BOOL ownBirth=rpIsolation.ownBirth&&[birth(getpid())isEqual:rpIsolation.ownBirth];
            inert=!visible&&!canKey&&!canMain&&!key&&!main&&stable&&ownBirth&&(number==-1||(number>0&&identity&&hidden));
            if(inert&&number>0&&!frozen)[rpIsolation.registeredHelpers setObject:@(number) forKey:w];
            NSDictionary *snapshot=@{@"class":NSStringFromClass(w.class),@"window_id":@(number),@"visible":@(visible),@"ignores_mouse_events":@(w.ignoresMouseEvents),@"can_become_key":@(canKey),@"can_become_main":@(canMain),@"is_key":@(key),@"is_main":@(main),@"accepted_inert_auxiliary":@(inert),@"registered":@(number>0),@"frozen_registered_id":frozen?:@(inert&&number>0?number:-1),@"id_stable":@(stable),@"self_birth_matches":@(ownBirth),@"cg_row_present":@(cg!=nil),@"cg_window_id":[cgID isKindOfClass:NSNumber.class]?cgID:NSNull.null,@"cg_owner_pid":[owner isKindOfClass:NSNumber.class]?owner:NSNull.null,@"cg_onscreen":[onscreen isKindOfClass:NSNumber.class]?onscreen:NSNull.null,@"cg_identity_matches":@(identity),@"cg_explicitly_offscreen":@(hidden)};
            [helpers addObject:snapshot];if(inert&&!rpIsolation.firstAcceptedInertHelper)rpIsolation.firstAcceptedInertHelper=snapshot;
            if(!inert&&!rpIsolation.firstSharingHelperFailure)rpIsolation.firstSharingHelperFailure=snapshot;
        }
        if(!inert)valid&=rpWindowExcluded(w);
    }
    rpIsolation.lastSharingHelperScan=helpers;
    rpIsolation.windowsExcluded=valid;if(!valid)rpIsolation.exclusionFailed=YES;return valid;
}
static NSDictionary *rpIsolationDiagnostics(void){return @{@"dedicated_application":@([NSApp isKindOfClass:RPIsolatedApplication.class]),@"unexpected_input":@(rpIsolation.unexpectedInput),@"first_rejected_event_type":@(rpIsolation.firstRejectedType),@"foreground_interrupted":@(rpIsolation.foregroundInterrupted),@"exclusion_failed":@(rpIsolation.exclusionFailed),@"windows_excluded":@(rpIsolation.windowsExcluded),@"first_window_exclusion_failure":rpIsolation.firstWindowExclusionFailure?:@{},@"first_accepted_inert_helper":rpIsolation.firstAcceptedInertHelper?:@{},@"last_sharing_helper_scan":rpIsolation.lastSharingHelperScan?:@[],@"first_sharing_helper_failure":rpIsolation.firstSharingHelperFailure?:@{}};}
static NSWindow *rpMakeWindow(NSRect frame,NSString *title,NSWindowStyleMask style){
    NSWindow *window=[[RPIsolatedWindow alloc]initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    window.title=title;window.releasedWhenClosed=NO;window.animationBehavior=NSWindowAnimationBehaviorNone;window.hasShadow=NO;return window;
}
