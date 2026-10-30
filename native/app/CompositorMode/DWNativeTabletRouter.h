// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Mouse event types, by what the delivery code does with them. Each covers the left, right and
// other button. DWMouseMove is any pointer motion (moved, or dragged with a button down);
// DWMouseForwardable is every type a captured mouse or tablet stroke can carry: motion, down and up.
static inline BOOL DWMouseDown(CGEventType type) { return type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown; }
static inline BOOL DWMouseUp(CGEventType type) { return type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp; }
static inline BOOL DWMouseDragged(CGEventType type) { return type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged; }
static inline BOOL DWMouseMove(CGEventType type) { return type==kCGEventMouseMoved||DWMouseDragged(type); }
static inline BOOL DWMouseForwardable(CGEventType type) { return DWMouseMove(type)||DWMouseDown(type)||DWMouseUp(type); }

BOOL DWNativeTabletEvent(CGEventRef event);
BOOL DWNativeTabletProximityEvent(CGEventRef event);

typedef BOOL (^DWNativeTabletValidate)(NSDictionary *target);
typedef BOOL (^DWNativeTabletPost)(CGEventRef event,NSDictionary *target,CGPoint local);

// Main-thread-only delivery state for a tablet tool on a captured display view.
// Observe physical events after rejecting our posting tags, including proximity
// events over ordinary native windows. A target is an immutable binding key:
// {identity, generation, window, output}. The caller revalidates that binding and
// the view's ownership before every post; the ordinary replica adapter then
// checks the current process birth, WindowServer owner and unscaled geometry.
// No tablet mapping or device settings are changed. Original packets are copied
// so pressure, tilt, rotation, tool/eraser identity and vendor data survive.
@interface DWNativeTabletRouter : NSObject
- (void)observeEvent:(CGEventRef)event;
// Immediately after observing a new physical tool entry, close any old
// admission that reused this device ID. The new tool's packet remains native;
// the returned old binding lets the caller end only its matching view gesture.
- (NSDictionary *)retireReplacedToolForEvent:(CGEventRef)event
                                  validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post;
// Admission, not proof of posting. Sample before forwarding a contact tail:
// YES also covers deliberately dropped motion and a dead owner's release tail.
- (BOOL)ownsEvent:(CGEventRef)event;
// Snapshot before forwarding a release. Use its stable binding keys to clear
// only the matching view's pressed record when multiple tools share a button.
- (NSDictionary *)capturedTargetForEvent:(CGEventRef)event;
- (BOOL)forwardEvent:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local
            validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post;
// A captured contact may refresh target geometry/local coordinates while keeping
// the same binding. With target=nil, held motion is suppressed and its physical
// release returns to the last admitted application point. A physical proximity
// exit likewise returns to the admitted recipient outside the canvas display.
// Cancel only while a target can still be validated. It releases the tablet
// pressure/buttons and proximity for admitted recipients, never arbitrary apps.
// Cancellation emits full-payload mouse-up packets for every admitted button;
// the desktop must not add a second plain mouse-up for the same tablet pair.
- (void)cancelWithValidate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post;
- (void)cancelTargetsMatching:(BOOL (^)(NSDictionary *target))matching
                     validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post;
// Forget stale/session-inactive state without posting to a possibly dead owner.
- (void)reset;
@end
