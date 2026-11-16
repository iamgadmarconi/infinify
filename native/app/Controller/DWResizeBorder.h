// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWResizeBorder : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) NSString *edges;
@property(nonatomic,readonly,nullable) NSNumber *snapped;
@end
NS_ASSUME_NONNULL_END
