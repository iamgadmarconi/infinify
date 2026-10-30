// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

BOOL DWNativeRelativeMotionEvent(CGEventRef event);

// Main-thread-only accelerated mouse delta conversion for an admitted captured
// view. The target is an immutable ownership key containing identity, generation,
// window and output, with root_identity/native_member for a family member.
// Scales are application points per display point from that view's transform.
// This adapts coordinates only; it provides no pointer lock or confinement.
@interface DWNativeRelativeMotion : NSObject
// Call once on a copied eligible motion packet, immediately before posting.
// YES means conversion succeeded, not that the recipient accepted input.
// NO leaves event fields unchanged; unsupported packets are ignored. Invalid
// targets/scales/numeric overflow also reset accumulated fractional deltas.
// Unaccelerated fields 170/171 and all tablet/scroll/key payload stay unchanged.
- (BOOL)adjustEvent:(CGEventRef)event target:(NSDictionary *)target
             scaleX:(double)scaleX scaleY:(double)scaleY;
// Reset after posting failure, capture cancellation or a session transition.
// Target/scale changes reset automatically before the next accepted motion.
- (void)reset;
@end
