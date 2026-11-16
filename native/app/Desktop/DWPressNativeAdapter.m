// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWPressNativeAdapter.h"
#import "DWNativeDecorations.h"
#import "DWNativeReplicaInput.h"
#import "DWNativeFocus.h"
#import "DWNativePlacementValidation.h"
#import "DWNativeWindowServer.h"
#import "DWDesktopSupport.h"
#import "DWNativeFamily.h"
#import "DWWindowEvents.h"
@implementation DWPressNativeAdapter
- (BOOL)trusted { return AXIsProcessTrusted(); }
- (BOOL)scope:(NSDictionary *)scope contains:(pid_t)pid { return DWInScope(scope,pid); }
- (BOOL)physicalButton:(CGMouseButton)button { return CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,button); }
- (NSUInteger)pressedButtons { return NSEvent.pressedMouseButtons; }
- (NSTimeInterval)uptime { return NSProcessInfo.processInfo.systemUptime; }
- (CFTimeInterval)mediaTime { return CACurrentMediaTime(); }
- (double)monotonicSeconds { return DWMonotonicSeconds(); }
- (CGWindowID)windowAt:(CGPoint)point { return (CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0]; }
- (BOOL)parent:(NSDictionary *)identity result:(uint32_t *)parent { return DWNativeWindowParent(identity,parent); }
- (BOOL)member:(NSDictionary *)member belongsTo:(NSDictionary *)root { return DWNativeWindowBelongsToRoot(member,root); }
- (BOOL)placement:(DWNativeAppliedPlacement *)placement presenter:(DWNativePresenter *)presenter recipient:(NSDictionary *)recipient at:(CGPoint)point {
    return DWNativeValidateAppliedPlacementInput(presenter,placement,recipient,point,NULL);
}
- (BOOL)endNativeDragAt:(CGPoint)point tag:(int64_t)tag {
    CGEventSourceRef quiet=CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef up=quiet?CGEventCreateMouseEvent(quiet,kCGEventLeftMouseUp,point,kCGMouseButtonLeft):NULL;
    if(up){CGEventSetIntegerValueField(up,kCGEventSourceUserData,tag);CGEventSetIntegerValueField(up,kCGMouseEventClickState,1);CGEventPost(kCGHIDEventTap,up);CFRelease(up);}
    if(quiet)CFRelease(quiet);
    return up!=NULL;
}
- (DWResizeResult)reposition:(DWResizeIdentity)identity from:(CGRect)from to:(CGPoint)origin deadline:(double)deadline { return dw_resize_reposition(identity,from,origin,deadline); }
// A native-recipient decision only authorizes leaving the original packet
// alone. It never grants scope or permission to post to that process/window.
// Our own panel's unclaimed down must still reach AppKit: AppKit may then admit
// a captured pointer grab whose tails belong to the existing consumer.
- (BOOL)foreignRecipient:(CGEventRef)event {
    if(CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)==getpid())return NO;
    int64_t window=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!window)window=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    if(window>0&&window<=INT32_MAX)return [NSApp windowWithWindowNumber:(NSInteger)window]==nil;
    int64_t pid=CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID);
    return pid>0&&pid!=getpid();
}
- (NSDictionary *)buttons:(NSDictionary *)identity { return DWNativeDecorationButtons(identity); }
- (NSDictionary *)recipient:(CGPoint)point { return DWNativeEventRecipientAtPoint(point); }
- (NSArray *)windows:(CGWindowID)window { return CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,window)); }
- (NSDictionary *)windowInfo:(CGWindowID)window { return windowInfo(window); }
- (NSArray *)birth:(pid_t)pid { return birth(pid); }
- (BOOL)bounds:(CGWindowID)window result:(CGRect *)bounds { return DWNativeBounds(window,bounds); }
- (BOOL)owner:(NSDictionary *)identity bounds:(CGRect *)bounds {
    DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
    return dw_focus_owner(selected,bounds);
}
@end
