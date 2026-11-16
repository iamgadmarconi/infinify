// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWIdentity;
NS_ASSUME_NONNULL_BEGIN
@interface DWSourceBinding : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) DWIdentity *identity;
@property(nonatomic,readonly,nullable) NSNumber *generation;

@property(nonatomic,readonly,nullable) NSNumber *observationKnown;
@property(nonatomic,readonly) CGRect observedRect;
@property(nonatomic,readonly) CGRect observedRectOrNull;
+ (instancetype)bindingWithWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation;
@end
NS_ASSUME_NONNULL_END
