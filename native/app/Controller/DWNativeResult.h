// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
#import "DWNativeResize.h"
@class DWFocusEffect, DWSizeEffect;
NS_ASSUME_NONNULL_BEGIN
@interface DWNativeResult : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *outcome;
@property(nonatomic,readonly,nullable) NSNumber *axError;
@property(nonatomic,readonly,nullable) NSNumber *mutationAttempted;
@property(nonatomic,readonly,nullable) NSNumber *observed;
@property(nonatomic,readonly) CGSize requested;
@property(nonatomic,readonly) CGRect actualAX;
@property(nonatomic,readonly) CGRect actualCG;

@property(nonatomic,readonly) DWValuePresence requestedPresence;
@property(nonatomic,readonly) BOOL requestedHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence actualAXPresence;
@property(nonatomic,readonly) BOOL actualAXHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence actualCGPresence;
@property(nonatomic,readonly) BOOL actualCGHasNumericComponents;
@property(nonatomic,readonly,nullable) NSNumber *success;
@property(nonatomic,readonly,nullable) DWFocusEffect *effect;
@property(nonatomic,readonly) CGRect actualAXOrNull;
@property(nonatomic,readonly) CGRect actualCGOrNull;
+ (instancetype)resultWithNativeResize:(DWResizeResult)result;
+ (instancetype)unansweredForSizeEffect:(DWSizeEffect *)effect;
- (DWNativeResult *)withMutationAttempted:(BOOL)attempted;
@end
NS_ASSUME_NONNULL_END
