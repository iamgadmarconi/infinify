// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Resolution maps the physical screen point into the ORIGINAL recipient, even
// outside its replica or display. Return {target,local:{x,y}} or nil. Only
// native_bounds and other geometry may change: the stable ownership key below
// must remain equal. Validation and posting must independently check current
// scope, process birth, binding generation and native parentage.
typedef NSDictionary * (^DWNativePointerResolve)(NSDictionary *target,CGPoint screen);
typedef BOOL (^DWNativePointerValidate)(NSDictionary *target);
typedef BOOL (^DWNativePointerPost)(CGEventRef event,NSDictionary *target,CGPoint local);

// Main-thread implicit mouse capture for native replicas. No window ownership,
// focus, geometry, cursor warp or native posting is performed by this class.
// Tablet packets belong to DWNativeTabletRouter and are always excluded here.
// The immutable recipient key is identity/root_identity/generation/window/
// output/native_member. Mouse buttons 0..31 can be held together; unsupported
// physical buttons are consumed until their real release after cancellation.
@interface DWNativePointerGrab : NSObject
@property(nonatomic,readonly) NSDictionary *target;
@property(nonatomic,readonly) uint32_t buttonMask; // physically held supported buttons, including suppressed tails
@property(nonatomic,readonly) BOOL active;         // an admitted native recipient remains
@property(nonatomic,readonly) BOOL suppressed;     // physical tails remain after cancellation
// Admission is separate from posting: call ONLY AFTER an initial mouse-down
// was successfully posted. Additional buttons go through forwardEvent instead.
- (BOOL)admitEvent:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local;
// YES means consume this physical event even when forwarding returns NO.
// While a button is held, all mouse down/drag/up/moved events belong to this
// grab. Scroll, tablet packets and unrelated event types are never owned.
- (BOOL)ownsEvent:(CGEventRef)event;
- (BOOL)forwardEvent:(CGEventRef)event screen:(CGPoint)screen
              resolve:(DWNativePointerResolve)resolve
             validate:(DWNativePointerValidate)validate post:(DWNativePointerPost)post;
// Detach the recipient before callbacks, pair each admitted down with a copied
// matching up where validation still permits it, and consume real tails until
// every physically held button has come up. Failed validation never retargets.
- (void)cancelWithValidate:(DWNativePointerValidate)validate post:(DWNativePointerPost)post;
// Session termination only, AFTER caller cancellation: forget suppression and
// stale ownership without posting. A reset during a callback cannot resurrect
// that callback's old recipient.
- (void)reset;
@end
