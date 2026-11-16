// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWLifecycleEvent : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *serial;
@property(nonatomic,readonly,nullable) NSString *event;
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) NSNumber *output;

@end
NS_ASSUME_NONNULL_END
