// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1.
// The private SkyLight route to one process's window (per-window input router).
// New implementation. Private signatures/routing fields referenced from Cantrip
// 4da10af479701c8007074c65f9eb6a2db03c8ffc, macos/skylight.rs; no code copied.
// Source: https://github.com/ArcaneArts/Cantrip/blob/4da10af479701c8007074c65f9eb6a2db03c8ffc/cantrip_cua/src/macos/skylight.rs
#import <AppKit/AppKit.h>
// The private SkyLight route to one process's window: an event is stamped with the window and the router's tag and posted
// to that process only. The window and its process are checked again at every post.
@interface Router : NSObject
@property pid_t pid;
@property uint32_t wid;
@property NSArray *processBirth;
@property NSDictionary *bounds;
@property CGEventSourceRef eventSource;
@property int64_t tag;
@property void (*privatePost)(pid_t,CGEventRef);
@property void (*privateLocation)(CGEventRef,CGPoint);
@property void (*privateField)(CGEventRef,uint32_t,int64_t);
- (BOOL)valid;
- (BOOL)loadPrivate;
- (BOOL)post:(CGEventRef)event at:(CGPoint)point;
@end
