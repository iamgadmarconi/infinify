// SPDX-License-Identifier: GPL-3.0-or-later
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
// Whether a native press on a transformed window has become the application's own window drag: the window is drawn somewhere other
// than its native frame (identity placements drag natively without trouble), the native origin has moved by more than a point since
// the press while the extent has not (an edge resize or an application's own resize changes the extent; a content drag moves nothing),
// and the pointer has travelled more than 4 points from where the press fell. `pressNative` and `pressDrawn` are the native frame and
// the window-list bounds read when the press began; `nativeNow` is the native frame now.
static inline BOOL DWNativeWindowDragStarted(CGRect pressNative,CGRect pressDrawn,CGRect nativeNow,CGPoint start,CGPoint point) {
    if(!(hypot(point.x-start.x,point.y-start.y)>4))return NO;
    BOOL transformed=fabs(pressNative.origin.x-pressDrawn.origin.x)>1||fabs(pressNative.origin.y-pressDrawn.origin.y)>1
        ||fabs(pressNative.size.width-pressDrawn.size.width)>1||fabs(pressNative.size.height-pressDrawn.size.height)>1;
    BOOL moved=fabs(nativeNow.origin.x-pressNative.origin.x)>1||fabs(nativeNow.origin.y-pressNative.origin.y)>1;
    BOOL extent=fabs(nativeNow.size.width-pressNative.size.width)<=1&&fabs(nativeNow.size.height-pressNative.size.height)<=1;
    return transformed&&moved&&extent;
}
