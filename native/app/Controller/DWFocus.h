// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWFocusEffect, DWNativeResult;
NS_ASSUME_NONNULL_BEGIN
@interface DWFocus : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *intent;
@property(nonatomic,readonly,nullable) DWFocusEffect *observedNative;
@property(nonatomic,readonly,nullable) DWFocusEffect *pendingEffect;
@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *history;
@property(nonatomic,readonly,nullable) NSNumber *cycle;
@property(nonatomic,readonly,nullable) NSNumber *releasePending;
@property(nonatomic,readonly,nullable) DWNativeResult *lastResult;
@property(nonatomic,readonly) DWValuePresence pendingEffectPresence;
@end
NS_ASSUME_NONNULL_END
