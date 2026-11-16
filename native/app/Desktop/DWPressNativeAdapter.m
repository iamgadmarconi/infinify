// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWPressNativeAdapter.h"
#import "DWNativeDecorations.h"
#import "DWNativeReplicaInput.h"
#import "DWNativeFocus.h"
#import "DWNativePlacementValidation.h"
#import "DWNativeWindowServer.h"
#import "DWDesktopSupport.h"
@implementation DWPressNativeAdapter
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
