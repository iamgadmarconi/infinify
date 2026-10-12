// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Read-only, bounded Accessibility lookup of the exact native root's green
// control. Run on a worker. nil means unavailable, not an inferred button.
NSDictionary *DWNativeDecorationButtons(NSDictionary *identity);
// Pure hit test of those window-relative controls against freshly validated
// native and displayed bounds. A size change invalidates the stored geometry.
BOOL DWNativeDecorationHit(NSDictionary *report,NSDictionary *identity,CGRect own,CGRect displayed,CGPoint point);
// Hit a standard native frame's observed title chrome. Missing/ambiguous AX
// chrome or stale native geometry never authorizes intercepting a press.
BOOL DWNativeWindowDragHit(NSDictionary *identity,NSDictionary *report,CGPoint point);
