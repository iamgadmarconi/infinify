// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWIdentity : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *pid;
@property(nonatomic,readonly,nullable) NSNumber *birthSeconds;
@property(nonatomic,readonly,nullable) NSNumber *birthMicroseconds;
@property(nonatomic,readonly,nullable) NSNumber *wid;
@property(nonatomic,readonly,nullable) NSNumber *owner;
@property(nonatomic,readonly,nullable) NSNumber *generation;
+ (instancetype)identityWithPID:(NSNumber *)pid birthSeconds:(NSNumber *)seconds birthMicroseconds:(NSNumber *)microseconds windowID:(NSNumber *)wid owner:(nullable NSNumber *)owner;
- (DWIdentity *)identityWithGeneration:(nullable NSNumber *)generation;
@property(nonatomic,readonly) DWValuePresence ownerPresence;
@end
NS_ASSUME_NONNULL_END
