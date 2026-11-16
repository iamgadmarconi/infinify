// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWDrawnValue.h"
@class DWIdentity;
NS_ASSUME_NONNULL_BEGIN
@interface DWPlacement : DWDrawnValue
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly) CGRect screenRect;
@property(nonatomic,readonly) CGRect clipRect;
@property(nonatomic,readonly) CGRect worldLocalCrop;
@property(nonatomic,readonly) CGRect bufferCrop;
@property(nonatomic,readonly,nullable) NSNumber *pinned;
@property(nonatomic,readonly,nullable) NSNumber *fullscreen;
@property(nonatomic,readonly,nullable) NSNumber *familyOnly;
@property(nonatomic,readonly,nullable) NSNumber *nativeMember;
@property(nonatomic,readonly,nullable) DWIdentity *rootIdentity;
- (DWPlacement *)placementWithScreenRect:(CGRect)screenRect clipRect:(CGRect)clipRect;
- (DWPlacement *)placementWithNativeMember:(NSNumber *)member rootIdentity:(DWIdentity *)identity;
@property(nonatomic,readonly) DWValuePresence bufferCropPresence;
@property(nonatomic,readonly) DWValuePresence worldLocalCropPresence;
- (BOOL)isEqualIgnoringFocus:(DWPlacement *)other;
@property(nonatomic,readonly) DWValuePresence screenRectPresence;
@property(nonatomic,readonly) BOOL screenRectHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence clipRectPresence;
@property(nonatomic,readonly) BOOL clipRectHasNumericComponents;
@property(nonatomic,readonly) BOOL worldLocalCropHasNumericComponents;
@property(nonatomic,readonly) BOOL bufferCropHasNumericComponents;
- (DWPlacement *)placementByRemovingFocus;
@property(nonatomic,readonly) CGRect screenRectOrNull;
@property(nonatomic,readonly) CGRect clipRectOrNull;
@property(nonatomic,readonly) CGRect worldLocalCropOrNull;
@property(nonatomic,readonly) CGRect bufferCropOrNull;
@property(nonatomic,readonly) BOOL isCurrentOutputPlacement;
@property(nonatomic,readonly) BOOL isPinned;
// Presenter-only legacy coercion: direct doubleValue, distinct from typed scene geometry.
@property(nonatomic,readonly) CGRect nativePresentationRect;
@property(nonatomic,readonly) double nativePresentationClipArea;
@property(nonatomic,readonly,nullable) NSNumber *alpha;
// Native adapter compatibility: direct doubleValue, distinct from strict numeric shape readers.
@property(nonatomic,readonly) CGRect nativeScreenRect;
// Native adapter compatibility: direct doubleValue, distinct from strict numeric shape readers.
@property(nonatomic,readonly) CGRect nativeClipRect;
@property(nonatomic,readonly) double nativePresentationAlpha;
@property(nonatomic,readonly) double nativePresentationOpacity;
@end
NS_ASSUME_NONNULL_END
