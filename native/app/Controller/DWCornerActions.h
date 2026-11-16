// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWCornerActions : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *topLeft;
@property(nonatomic,readonly,nullable) NSString *topRight;
@property(nonatomic,readonly,nullable) NSString *bottomLeft;
@property(nonatomic,readonly,nullable) NSString *bottomRight;
@end
NS_ASSUME_NONNULL_END
