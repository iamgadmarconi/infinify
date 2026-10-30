// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "DWDockControl.h"
@class NSEvent,DWTrackpadTouchFrame;

// The event types DWNativeInput's annotated session tap subscribes to: only the pointer,
// scroll, tablet and gesture types it acts on. Never the system-defined events (the volume,
// brightness and media keys), never key events, never AppKit-defined ones: an active tap
// on them makes macOS drop or lose those keys although it returns every event untouched.
CGEventMask DWNativeInputAnnotatedMask(void);

// Native windows sit above the canvas and receive ordinary input themselves. This
// bridge lets the desktop take only a configured canvas gesture on a bound window.
// The consumer must validate the window and scope before returning YES. The tap
// itself never posts to an application. Main thread only; no permission prompts.
// Dedicated tablet point/proximity packets are offered to the consumer as well;
// returning NO leaves their full physical payload with the native recipient.
// AppKit-convertible magnify events share the configured canvas pinch path.
// A gesture's admission is decided once; an unbound stream stays with its app.
// An unclaimed press addressed to a foreign native window keeps its physical
// button pair with WindowServer across canvas/app boundaries. This preserves
// native drag tracking; it does not forward a foreign NSDraggingSession into a
// captured image or create a destination on the application's behalf.
@interface DWNativeInput : NSObject
// Application-posted events identified by a lifetime tag must bypass BOTH the
// consumer and physical pair bookkeeping. Otherwise a synthetic release could
// be swallowed as a physical tail or a synthetic press clear an owned pair.
// The predicate receives ordinary packets only, before event classification.
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume
// Only positively identified managed chrome may be taken before destination
// annotation. A refused chrome action still reserves the entire pair. Owned
// drag/up packets use consume; unrecognized content stays annotated. Additional
// buttons cannot start another owner until the physical chrome pair is released.
                   earlyConsume:(BOOL (^)(CGEventType,CGEventRef))earlyConsume
                    ignoreEvent:(BOOL (^)(CGEventRef))ignoreEvent
                      cancelled:(void (^)(void))cancelled;
// The session tap's owned pair is authoritative even when suppression means
// AppKit's combined-session button state never sees the down.
@property (readonly) BOOL hasEarlyMousePress;
// Observation only: a Dock-control packet (type 30) reached this tap, so neither session tap dropped it. The packet is returned untouched and
// is not converted to an NSEvent. Called on the tap's thread, which is the main thread.
@property (copy) void (^dockControl)(CGEventRef event);
// Observation only, after an unclaimed native pair changes ownership or drags. The
// borrowed packet stays untouched; nil reports cancellation/lost-pair reset.
// The first down identifies the owner; later buttons/tails never retarget it.
@property (copy) void (^nativeMouseOwnershipChanged)(CGEventRef event,NSIndexSet *buttons);
// Bounds a lost release after 30 seconds without owned packets or a physically
// held left button. Ends the logical grab while retaining its suppressed tails.
- (void)cancelIdleEarlyMousePress;
// Called from nativeMouseOwnershipChanged: hands one held, unclaimed native button to the canvas. That packet and the physical
// tails of the pair are then swallowed and offered to consume. The application still holds a press, so the caller must end
// it with a release of its own (posted with a lifetime tag both taps let through). NO when the button is not held native.
- (BOOL)takeNativeButton:(NSUInteger)button;
// Whether the canvas still owns that button's physical pair (down seen or taken, release not yet). For a taken-over pair the
// application's own drag was ended with a posted release, so the system's button state says up while the finger is still down.
- (BOOL)holdsCapturedButton:(NSUInteger)button;
- (BOOL)start;
- (void)stop;
@end

// Desktop-mode gesture ownership, earlier than application destination annotation.
// Admission is once per physical contact/pinch. Returning YES authorizes suppressing
// its native tails; cancelling the controller does not hand a half-stream to an app.
// The DockSwipe decoder is a provenanced private event format, not a public ABI
// guarantee. Unknown formats pass through. No settings, permission prompts or
// synthesized input are used; stopping removes the interception. Main thread only.
@interface DWGlobalTrackpadInput : NSObject
- (instancetype)initWithEnabled:(BOOL (^)(void))enabled
                   admitTouches:(BOOL (^)(DWTrackpadTouchFrame *frame))admitTouches
                        touches:(void (^)(DWTrackpadTouchFrame *frame))touches
                        magnify:(BOOL (^)(NSEvent *event))magnify
                    ignoreEvent:(BOOL (^)(CGEventRef event))ignoreEvent
                      cancelled:(void (^)(void))cancelled;
@property (readonly) BOOL running;
@property (readonly) BOOL ownsTouches;
// The multitouch source's guard (DWDockGuard.h) decides Dock-control packets by finger count and per stream; this is its answer, asked per packet.
// Pass or Drop is final for a packet of any format, DockSwipe or not, and the tap's own ownership plays no part. Undecided (no touch source
// delivers) leaves the tap's own rules: a DockSwipe it saw begin while it owned the touch is dropped to its end, and so is any other
// Dock-control packet while it owns an admitted touch and for a moment after. Never converted to an NSEvent: type 30 is not one.
@property (copy) DWDockControlVerdict (^dockDecision)(CGEventRef event);
// An original mouse press is outside this adapter's owned touch contact.
// Tagged application-posted packets never alter
// this state. New global gesture admission must leave such a press alone.
@property (readonly) BOOL hasNativeMousePress;
- (BOOL)start;
// Ends logical gestures while retaining ownership of physical tails. Idempotent
// until another stream is admitted. Stopping instead discards all bridge state.
- (void)cancel;
- (void)stop;
@end
