// SPDX-License-Identifier: GPL-3.0-or-later
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
// Whether a native press on a transformed window has become the application's own window drag: the window is drawn somewhere other
// than its native frame (identity placements drag natively without trouble), the native origin has moved by more than a point since
// the press while the extent has not (an edge resize or an application's own resize changes the extent; a content drag moves nothing),
// (DWNativeWindowDragMoved), and for DWNativeWindowDragStarted the pointer has travelled more than 4 points from where the press fell. `pressNative` and `pressDrawn` are the native frame and
// the window-list bounds read when the press began; `nativeNow` is the native frame now.
static inline BOOL DWNativeWindowDragMoved(CGRect pressNative,CGRect pressDrawn,CGRect nativeNow) {
    BOOL transformed=fabs(pressNative.origin.x-pressDrawn.origin.x)>1||fabs(pressNative.origin.y-pressDrawn.origin.y)>1
        ||fabs(pressNative.size.width-pressDrawn.size.width)>1||fabs(pressNative.size.height-pressDrawn.size.height)>1;
    BOOL moved=fabs(nativeNow.origin.x-pressNative.origin.x)>1||fabs(nativeNow.origin.y-pressNative.origin.y)>1;
    BOOL extent=fabs(nativeNow.size.width-pressNative.size.width)<=1&&fabs(nativeNow.size.height-pressNative.size.height)<=1;
    return transformed&&moved&&extent;
}
static inline BOOL DWNativeWindowDragStarted(CGRect pressNative,CGRect pressDrawn,CGRect nativeNow,CGPoint start,CGPoint point) {
    return hypot(point.x-start.x,point.y-start.y)>4&&DWNativeWindowDragMoved(pressNative,pressDrawn,nativeNow);
}
// A press that never travelled (the pointer within 4 points of where it fell) whose native origin has nevertheless moved with the extent
// unchanged is the same application drag, begun by the press itself: Chromium's performWindowDragWithEvent: on a caption area the shell
// does not recognise moves the window at the mouse down, 50 to 65 ms after it, with no pointer motion at all (measured in the guest).
static inline BOOL DWNativeWindowDragBegunInPlace(CGRect pressNative,CGRect pressDrawn,CGRect nativeNow,CGPoint start,CGPoint point) {
    return hypot(point.x-start.x,point.y-start.y)<=4&&DWNativeWindowDragMoved(pressNative,pressDrawn,nativeNow);
}
// What a settled native press that was not taken over comes to. A click whose native origin has moved with the extent unchanged was moved
// by WindowServer's own window drag (from where the window is drawn, not from where it is: +327 pt per click at zoom 0.5, measured in the
// guest on a Chromium caption area the shell does not recognise); it is not a move of the window, so the native frame goes back to where
// the press found it. A press that moved the pointer past the click slop, or was taken over, is adopted as before; a click that left the
// native frame and the window list's bounds as they were is the unchanged click.
typedef enum { DWNativeClickSettleAdopt, DWNativeClickSettleUnchanged, DWNativeClickSettleRevert } DWNativeClickSettle;
static inline DWNativeClickSettle DWNativeClickSettleKind(BOOL clickEnded,BOOL taken,CGRect pressNative,CGRect nativeNow,BOOL boundsUnchanged) {
    if(CGRectEqualToRect(pressNative,nativeNow)&&boundsUnchanged)return DWNativeClickSettleUnchanged;
    BOOL moved=fabs(nativeNow.origin.x-pressNative.origin.x)>1||fabs(nativeNow.origin.y-pressNative.origin.y)>1;
    BOOL extent=fabs(nativeNow.size.width-pressNative.size.width)<=1&&fabs(nativeNow.size.height-pressNative.size.height)<=1;
    return clickEnded&&!taken&&moved&&extent?DWNativeClickSettleRevert:DWNativeClickSettleAdopt;
}
