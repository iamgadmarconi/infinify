// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/native-presenter.h (37b27b1): window-server queries and clip geometry for native presentation.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
//
// A window's own frame, untransformed, in global top-left points: where the window is
// and how large, whatever transform the helper has put on it. kCGWindowBounds follows
// the transform and is of no use for that (a 320x232 window drawn at half size reads
// 160x116 there); SLSGetWindowBounds, asked from this process about another's window,
// stays the window's own (measured 2026-10-11 on 27.2, on a cooperative host window:
// [80,937,320,232] untouched, at half size and parked). NO when the window server
// does not answer for that window. Any thread.
bool DWNativeBounds(uint32_t wid,CGRect *out);
// Balanced, bounded by the caller, on this app connection. Private signatures
// follow pinned yabai; success alone does not prove cross-process atomicity.
CGError DWNativeScreenUpdates(BOOL enabled);
// Desired rectangular display clipping in a member's own local coordinates.
// Pure geometry: native and rootNative are untransformed bounds; rootScreen is
// the canvas placement in global top-left points. The viewport is that output's
// screen_bounds, not the root's clip_rect (a popup may extend beyond its root).
// This does not read or replace the native window's original shape, shadow or
// event region, and is not evidence that WindowServer can enforce the clip.
typedef struct {
    CGRect screen,visible,local;
    bool required;
} DWNativeClipGeometry;
bool DWNativeClipPlacement(CGRect native,CGRect rootNative,CGRect rootScreen,CGRect viewport,DWNativeClipGeometry *out);
