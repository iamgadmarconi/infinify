// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWScreenshotRegionTarget, DWScreenshotWindowTarget;
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger,DWScreenshotTargetKind) { DWScreenshotTargetUnknown,DWScreenshotTargetViewport,DWScreenshotTargetAll,DWScreenshotTargetWindow,DWScreenshotTargetRegion };
@interface DWScreenshotTarget : DWControllerValue
@property(nonatomic,readonly,nullable) DWScreenshotWindowTarget *window;
@property(nonatomic,readonly,nullable) DWScreenshotRegionTarget *region;

@property(nonatomic,readonly) DWScreenshotTargetKind kind;
@end
NS_ASSUME_NONNULL_END
