// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWFocusCycle : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *index;
@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *windows;

@end
NS_ASSUME_NONNULL_END
