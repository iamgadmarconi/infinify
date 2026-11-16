// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWIdentity;
NS_ASSUME_NONNULL_BEGIN
@interface DWFocusCorrection : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *correction;
@property(nonatomic,readonly,nullable) DWIdentity *observed;
@property(nonatomic,readonly,nullable) NSNumber *intruderPID;
@property(nonatomic,readonly,nullable) NSNumber *startedAt;

@end
NS_ASSUME_NONNULL_END
