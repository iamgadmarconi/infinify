// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWScene.h"
// Native protocol adapters only. These records are independently validated by
// native drivers; projecting a controller identity grants no native authority.
FOUNDATION_EXPORT DWIdentity *DWControllerIdentity(NSDictionary *nativeIdentity);
FOUNDATION_EXPORT NSDictionary *DWNativeIdentity(DWIdentity *identity);
FOUNDATION_EXPORT NSDictionary *DWNativeCaptureSite(DWPlacement *placement,DWOutput *output,NSNumber *pixelMargin);
