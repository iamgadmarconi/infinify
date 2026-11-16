// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWControllerNative.h"
#import "DWScene+Private.h"
DWIdentity *DWControllerIdentity(NSDictionary *nativeIdentity) { return DWProject(DWIdentity.class,nativeIdentity); }
NSDictionary *DWNativeIdentity(DWIdentity *identity) { return identity.rawDictionary; }
NSDictionary *DWNativeCaptureSite(DWPlacement *placement,DWOutput *output,NSNumber *pixelMargin) {
    return @{@"screen_rect":placement.rawDictionary[@"screen_rect"]?:NSNull.null,@"viewport":output.rawDictionary[@"screen_bounds"]?:NSNull.null,@"pixel_margin":pixelMargin?:NSNull.null};
}
