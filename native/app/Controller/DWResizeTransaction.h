// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWIdentity, DWNativeResult, DWSizeEffect;
NS_ASSUME_NONNULL_BEGIN
@interface DWResizeTransaction : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *transaction;
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) DWIdentity *identity;
@property(nonatomic,readonly,nullable) NSNumber *generation;
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) NSString *edges;
@property(nonatomic,readonly,nullable) NSNumber *interactive;
@property(nonatomic,readonly,nullable) NSNumber *screenSpace;
@property(nonatomic,readonly) CGSize initialSize;
@property(nonatomic,readonly) CGSize lastCommittedSize;
@property(nonatomic,readonly) CGSize latestRequested;
@property(nonatomic,readonly) CGSize lastSent;
@property(nonatomic,readonly) CGRect requestedOutline;
@property(nonatomic,readonly) CGSize coalescedLatest;
@property(nonatomic,readonly) CGPoint nativeOrigin;
@property(nonatomic,readonly,nullable) DWSizeEffect *pendingEffect;
@property(nonatomic,readonly,nullable) NSString *phase;
@property(nonatomic,readonly,nullable) NSNumber *baselineObserved;
@property(nonatomic,readonly,nullable) NSNumber *released;
@property(nonatomic,readonly,nullable) NSNumber *cancelled;
@property(nonatomic,readonly,nullable) NSNumber *uncertainMutation;
@property(nonatomic,readonly,nullable) DWNativeResult *lastResult;
@property(nonatomic,readonly) DWValuePresence pendingEffectPresence;
@property(nonatomic,readonly) DWValuePresence initialSizePresence;
@property(nonatomic,readonly) BOOL initialSizeHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence lastCommittedSizePresence;
@property(nonatomic,readonly) BOOL lastCommittedSizeHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence latestRequestedPresence;
@property(nonatomic,readonly) BOOL latestRequestedHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence lastSentPresence;
@property(nonatomic,readonly) BOOL lastSentHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence requestedOutlinePresence;
@property(nonatomic,readonly) BOOL requestedOutlineHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence coalescedLatestPresence;
@property(nonatomic,readonly) BOOL coalescedLatestHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence nativeOriginPresence;
@property(nonatomic,readonly) BOOL nativeOriginHasNumericComponents;
@property(nonatomic,readonly) CGRect requestedOutlineOrNull;
@end
NS_ASSUME_NONNULL_END
