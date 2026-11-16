// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWIdentity;
NS_ASSUME_NONNULL_BEGIN
@interface DWSource : DWControllerValue
@property(nonatomic,readonly,nullable) DWIdentity *identity;
@property(nonatomic,readonly,nullable) NSNumber *generation;
@property(nonatomic,readonly) CGSize buffer;
@property(nonatomic,readonly) CGRect contentRect;
@property(nonatomic,readonly) CGRect originalRect;
@property(nonatomic,readonly) CGRect observedRect;
@property(nonatomic,readonly,nullable) NSNumber *observationKnown;
@property(nonatomic,readonly,nullable) NSString *visibility;
@property(nonatomic,readonly,nullable) NSNumber *visibilityRevision;
@property(nonatomic,readonly,nullable) NSNumber *visibilityPending;
@property(nonatomic,readonly,nullable) NSNumber *visibilityPlacementReady;
+ (instancetype)sourceWithIdentity:(DWIdentity *)identity generation:(NSNumber *)generation buffer:(CGSize)buffer contentRect:(CGRect)contentRect originalRect:(CGRect)originalRect observedRect:(CGRect)observedRect observationKnown:(BOOL)known;
@property(nonatomic,readonly) DWValuePresence bufferPresence;
@property(nonatomic,readonly) BOOL bufferHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence contentRectPresence;
@property(nonatomic,readonly) BOOL contentRectHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence originalRectPresence;
@property(nonatomic,readonly) BOOL originalRectHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence observedRectPresence;
@property(nonatomic,readonly) BOOL observedRectHasNumericComponents;
@property(nonatomic,readonly) CGRect contentRectOrNull;
@property(nonatomic,readonly) CGRect originalRectOrNull;
@property(nonatomic,readonly) CGRect observedRectOrNull;
@end
NS_ASSUME_NONNULL_END
