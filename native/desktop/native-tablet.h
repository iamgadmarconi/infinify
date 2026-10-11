// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

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
// Admission, not proof of posting. Sample before forwarding a contact tail:
// YES also covers deliberately dropped motion and a dead owner's release tail.
- (BOOL)ownsEvent:(CGEventRef)event;
// Snapshot before forwarding a release. Use its stable binding keys to clear
// only the matching view's pressed record when multiple tools share a button.
- (NSDictionary *)capturedTargetForEvent:(CGEventRef)event;
- (BOOL)forwardEvent:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local
            validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post;
// A physical proximity exit can be forwarded with target=nil; it returns to the
// last admitted recipient even after the pointer has left the canvas display.
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
