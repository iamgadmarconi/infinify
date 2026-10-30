// SPDX-License-Identifier: GPL-3.0-or-later
// Rectangles as the controller's JSON carries them: {origin:{x,y},size:{width,height}}.
// Shared by the native-* modules. The strict readers in DWNativePresenter.m, DWNativeViews.m,
// DWNativeTransition.m and DWNativePlacementValidation.m validate differently from each
// other and from the lenient reader here; they stay where they are.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>

static inline NSDictionary *DWRectJSON(CGRect r) {
    return @{ @"origin":@{@"x":@(r.origin.x),@"y":@(r.origin.y)},@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)} };
}
// Lenient reader for a rectangle this process wrote (or an already-validated one): a missing or
// non-numeric field reads as 0, nothing is checked for being finite or non-empty.
static inline CGRect DWRectFromJSON(NSDictionary *r) {
    return CGRectMake([r[@"origin"][@"x"]doubleValue],[r[@"origin"][@"y"]doubleValue],
                      [r[@"size"][@"width"]doubleValue],[r[@"size"][@"height"]doubleValue]);
}
// A rectangle that is finite everywhere and has a positive size.
static inline bool DWFiniteRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        &&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r));
}
