// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Native windows sit above the canvas and receive ordinary input themselves. This
// bridge lets the desktop take only a configured canvas gesture on a bound window.
// The consumer must validate the window and scope before returning YES. Events are
// never copied or posted to an application. Main thread only; no permission prompts.
// AppKit-convertible magnify events share the configured canvas pinch path.
// A gesture's admission is decided once; an unbound stream stays with its app.
@interface DWNativeInput : NSObject
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume cancelled:(void (^)(void))cancelled;
- (BOOL)start;
- (void)stop;
@end
