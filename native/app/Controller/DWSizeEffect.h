// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWEffect.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWSizeEffect : DWEffect
@property(nonatomic,readonly,nullable) NSNumber *transaction;
@property(nonatomic,readonly) CGSize requested;
@property(nonatomic,readonly) CGPoint nativeOrigin;
@property(nonatomic,readonly,nullable) NSString *nativeAction;
@property(nonatomic,readonly) DWValuePresence requestedPresence;
@property(nonatomic,readonly) DWValuePresence nativeOriginPresence;
@property(nonatomic,readonly) BOOL requestedHasNumericComponents;
@property(nonatomic,readonly) BOOL nativeOriginHasNumericComponents;
@end
NS_ASSUME_NONNULL_END
