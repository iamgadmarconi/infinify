// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Upstream's hot-corner trigger over an observed pointer: a bound corner fires once
// when the pointer enters its zone and is armed again when the pointer leaves it.
// Holds no timer, tap or observer: its owner hands it the pointer whenever it looks.
// Main thread only.
@interface DWHotCorners : NSObject
// The "hot_corners" member of the controller's {"op":"bindings"} reply: one entry
// per registered output, {"output":ID,"corners":{"top_left":ACTION,…},"threshold":
// POINTS,"disable_while_dragging":BOOL,"disable_when_fullscreen":BOOL}. A missing
// threshold is upstream's default 4 and a missing dragging or fullscreen rule its
// default true. An output with no bound corner is not watched. The latch is kept,
// as upstream keeps it across a reload.
- (void)arm:(NSArray *)outputs;
// Some corner of some output is bound: only then is the pointer worth reading.
@property (readonly) BOOL armed;
// One observation: the pointer at `point`, from the top-left of `output`'s display
// of `size`, with or without a window fullscreen on that output, and with or without
// a mouse button or pointer gesture held. Returns the bound corner the pointer has
// just entered ("top_left", "top_right", "bottom_left" or "bottom_right"), or nil:
// also for an entry one of the two rules suppresses, which is still an entry.
- (NSString *)enter:(CGPoint)point size:(CGSize)size output:(NSNumber *)output fullscreen:(BOOL)fullscreen dragging:(BOOL)dragging;
// The pointer is on no output: it is in no corner, and the next entry fires again.
- (void)leave;
// The action string bound to one corner of one output, nil for none.
- (NSString *)action:(NSString *)corner output:(NSNumber *)output;
@end
