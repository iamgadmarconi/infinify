// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWLifecycle : DWControllerValue
@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *relaunching;

@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *standins;
@property(nonatomic,readonly,nullable) NSNumber *settled;
@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *held;
@end
NS_ASSUME_NONNULL_END
