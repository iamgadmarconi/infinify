// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// What the pointer policy asks of the canvas view it serves. Main thread only.
@protocol DWPointerHost <NSObject>
// One controller command: its reply's data, or nil when the controller refused it.
// `quiet` leaves the status line as it was, whatever the controller answered.
- (NSDictionary *)pointerCommand:(NSDictionary *)command quiet:(BOOL)quiet;
// The reply to a press the policy sent (activate, pick, pointer_nearest, and the
// begin_drag of a pick-mode press that became a move), carried out like every bound
// command's: its focus request, its flight, a redraw, the scene saved.
- (void)pointerApply:(NSDictionary *)reply;
// A hover moved the focus. Its focus request goes the way a click's does, and `effect`
// is nil for a window with no application behind it; the canvas is drawn again.
- (void)pointerFocused:(NSDictionary *)effect;
// The output whose screen_bounds hold a point in their coordinates, nil for none.
- (NSNumber *)outputAt:(CGPoint)screen;
// Where the pointer is now, by the shell's one reading of it, which is also what cursor
// edge pan is told: its global point in the coordinates of screen_bounds through
// `screen`, and the output of this view it is on. nil when a press there would not reach
// one: another window covers the panel, or the point is on another panel.
- (NSNumber *)pointerSample:(CGPoint *)screen;
// The shell's frame timer is running. It then carries the hover (-frame:output:), and
// no timer of this object's is armed beside it.
- (BOOL)pointerFramed;
// The pointer or the pad is taken: a button is down, a press, a drag or a pan is being
// handled on any panel, a trackpad gesture is recognised or held by the controller, a
// native resize is in progress, or the canvas is closing. No hover is sent then and no
// motion delivered.
- (BOOL)pointerBusy;
// A real modifier is physically down now, as the action of a key binding is told.
- (BOOL)pointerHeld;
// Pointer motion for the application whose window is under `screen`, by the route
// and through the validation a click takes. Nothing is said when it is not delivered.
- (void)pointerDeliver:(NSEvent *)motion at:(CGPoint)screen output:(NSNumber *)output;
// Update only this application's canvas cursor. A nil output withdraws this
// view's override. A hover reply may be reused for pick/hit policy; nil asks the
// host to resolve the current shape without forwarding or changing focus.
- (void)pointerCursor:(CGPoint)screen output:(NSNumber *)output reply:(NSDictionary *)reply;
@end
// DriftWM's pointer policy for one canvas panel of a normal run: pointer motion with
// no button down (hover: sloppy focus and the motion an application sees), a press in
// pick mode (below [zoom] interact_min) and a press bound to center-nearest. What each
// of them means is the controller's to say; this object gets them to it and carries
// out the reply. Main thread only.
@interface DWPointerHover : NSObject
// Turns on mouse-moved delivery for `host`, a view already in its panel: that panel is
// never key and its application rarely active, so the motion comes through a tracking
// area that is always active. The newest motion is sent as {"op":"hover"} at most once
// a frame, and only while the panel is what a click at the pointer would land on. While
// the shell's frame timer runs, that frame is its frame (-frame:output:); otherwise a
// timer of this object's sends it, a sixtieth of a second after the last one at the
// earliest. `host` is not retained.
- (instancetype)initWithHost:(NSView<DWPointerHost> *)host;
// A motion is waiting to be sent.
@property (readonly) BOOL pending;
// An observed native motion, coalesced through the same frame/timer path. The
// host must freshly select its source at flush and leave native delivery alone.
- (void)nativeMotion:(NSEvent *)event;
// One frame of the shell's timer: the waiting motion, if any, is sent now, with the
// frame's own reading of the pointer (`output` as -pointerSample: answers it).
- (void)frame:(CGPoint)screen output:(NSNumber *)output;
// NO (--no-hover-forwarding): hover still runs, and no motion reaches an application.
@property BOOL forwarding;
// A press on `hit`, as -[DesktopView hit:output:] answers it. YES when it is pick
// mode's: the hit is a pick target and `claimed`, a binding whose modifiers are held,
// is NO. The window is then focused and raised, the press is never the application's,
// and the left button is armed to pick.
- (BOOL)pickPress:(NSDictionary *)hit button:(NSInteger)button claimed:(BOOL)claimed at:(CGPoint)screen output:(NSNumber *)output;
// A press bound to center-nearest went down at `screen`; `focus` is a press bound to focus-nearest, which the
// controller answers with focus-nearest's reveal instead of center-nearest's park (the binding's "focus").
- (void)nearestPress:(CGPoint)screen output:(NSNumber *)output focus:(BOOL)focus;
// The pointer moved with that button down. YES when the press has just become a window
// move: the controller accepted begin_drag, and the host carries on from `screen` as its
// own move gesture. A center-nearest press sends its one pointer_nearest from here.
- (BOOL)pressDragged:(CGPoint)screen;
// The button came up: an armed pick is sent, and so is a center-nearest press that
// never took a direction, which the controller answers by doing nothing.
- (void)pressReleased:(CGPoint)screen;
// Removes the tracking area and drops the pending hover and any press. No host call
// after this. Required before the panel closes and before release.
- (void)stop;
@end
// Is `output` in pick mode, as that snapshot's "outputs" say? NO for an output it does
// not list.
BOOL DWPickOutput(NSDictionary *snapshot,NSNumber *output);
// A placeholder is hit-tested by the shell alone, so the controller never says whether
// it is a pick target. It is one, as upstream's stand-in is, whenever its output is in
// pick mode. Returns `hit` with "pick":true then, and `hit` itself otherwise.
NSDictionary *DWPickHit(NSDictionary *hit,NSDictionary *snapshot,NSNumber *output);
