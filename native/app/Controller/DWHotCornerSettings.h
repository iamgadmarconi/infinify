// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWCornerActions;
NS_ASSUME_NONNULL_BEGIN
@interface DWHotCornerSettings : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) NSString *stableID;
@property(nonatomic,readonly,nullable) NSNumber *threshold;
@property(nonatomic,readonly,nullable) NSNumber *disableWhileDragging;
@property(nonatomic,readonly,nullable) NSNumber *disableWhenFullscreen;
@property(nonatomic,readonly,nullable) DWCornerActions *corners;
@end
NS_ASSUME_NONNULL_END
