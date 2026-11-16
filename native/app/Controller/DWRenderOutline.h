// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWRGBA;
NS_ASSUME_NONNULL_BEGIN
@interface DWRenderOutline : DWControllerValue
@property(nonatomic,readonly,nullable) DWRGBA *color;
@property(nonatomic,readonly,nullable) NSNumber *thickness;
@property(nonatomic,readonly,nullable) NSNumber *opacity;

@end
NS_ASSUME_NONNULL_END
