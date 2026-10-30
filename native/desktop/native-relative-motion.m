// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-relative-motion.h"
#import "native-tablet.h"
#include <math.h>

BOOL DWNativeRelativeMotionEvent(CGEventRef event) {
    if(!event||DWNativeTabletEvent(event))return NO;
    CGEventType type=CGEventGetType(event);
    return DWMouseMove(type);
}
static NSDictionary *relativeTarget(NSDictionary *target) {
    if(![target isKindOfClass:NSDictionary.class]||![target[@"identity"]isKindOfClass:NSDictionary.class]
        ||![target[@"generation"]isKindOfClass:NSNumber.class]||![target[@"window"]isKindOfClass:NSNumber.class]
        ||![target[@"output"]isKindOfClass:NSNumber.class])return nil;
    NSDictionary *identity=target[@"identity"],*root=target[@"root_identity"]?:identity;
    if(![root isKindOfClass:NSDictionary.class])return nil;
    // Copy identities too: geometry and capture observations are deliberately
    // absent, and a caller's mutable dictionary cannot rewrite an admitted key.
    return @{@"identity":identity.copy,@"root_identity":root.copy,@"generation":target[@"generation"],
        @"window":target[@"window"],@"output":target[@"output"],@"native_member":@([target[@"native_member"]boolValue])};
}
static BOOL relativeInteger(long double value,int64_t *integer,long double *remainder) {
    if(!isfinite(value))return NO;
    long double rounded=roundl(value);
    // Use exclusive 2^63 rather than converting INT64_MAX to floating point:
    // Apple Silicon's long double has double precision and rounds that limit up.
    if(!isfinite(rounded)||rounded>=0x1p63L||rounded<-0x1p63L)return NO;
    *integer=(int64_t)rounded;*remainder=value-rounded;return isfinite(*remainder);
}
@implementation DWNativeRelativeMotion {
    NSDictionary *_target;
    double _scaleX,_scaleY;
    long double _remainderX,_remainderY;
}
- (BOOL)adjustEvent:(CGEventRef)event target:(NSDictionary *)target scaleX:(double)scaleX scaleY:(double)scaleY {
    if(!NSThread.isMainThread||!DWNativeRelativeMotionEvent(event))return NO;
    NSDictionary *key=relativeTarget(target);
    if(!key||!isfinite(scaleX)||!isfinite(scaleY)||scaleX<=0||scaleY<=0){[self reset];return NO;}
    BOOL same=[_target isEqual:key]&&_scaleX==scaleX&&_scaleY==scaleY;
    long double carryX=same?_remainderX:0,carryY=same?_remainderY:0,nextX=0,nextY=0;
    int64_t deltaX=0,deltaY=0;
    // CGEventTypes.h defines 4/5 as integer movement since the prior mouse
    // event. Keep the fractional part across the same ownership/scale stream.
    // Its independently documented unaccelerated movement (170/171) is raw
    // device data and must not be replaced by this view-coordinate conversion.
    if(!relativeInteger((long double)CGEventGetIntegerValueField(event,kCGMouseEventDeltaX)*scaleX+carryX,&deltaX,&nextX)
        ||!relativeInteger((long double)CGEventGetIntegerValueField(event,kCGMouseEventDeltaY)*scaleY+carryY,&deltaY,&nextY)){[self reset];return NO;}
    CGEventSetIntegerValueField(event,kCGMouseEventDeltaX,deltaX);
    CGEventSetIntegerValueField(event,kCGMouseEventDeltaY,deltaY);
    _target=key;_scaleX=scaleX;_scaleY=scaleY;_remainderX=nextX;_remainderY=nextY;
    return YES;
}
- (void)reset {
    if(!NSThread.isMainThread)return;
    _target=nil;_scaleX=_scaleY=0;_remainderX=_remainderY=0;
}
@end
