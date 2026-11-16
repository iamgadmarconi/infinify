// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWScreenshotRegionTarget : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *x;
@property(nonatomic,readonly,nullable) NSNumber *y;
@property(nonatomic,readonly,nullable) NSNumber *w;
@property(nonatomic,readonly,nullable) NSNumber *h;
@property(nonatomic,readonly,nullable) NSNumber *fromScreen;
@end
NS_ASSUME_NONNULL_END
