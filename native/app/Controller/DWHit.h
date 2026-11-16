// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWIdentity;
NS_ASSUME_NONNULL_BEGIN
@interface DWHit : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) DWIdentity *identity;
@property(nonatomic,readonly) CGPoint local;
@property(nonatomic,readonly) CGPoint bufferLocal;
@property(nonatomic,readonly) CGPoint nativeScreen;
@property(nonatomic,readonly,nullable) NSNumber *requiresNativeRevalidation;
@property(nonatomic,readonly,nullable) NSNumber *widget;
@property(nonatomic,readonly,nullable) NSNumber *pinned;

@property(nonatomic,readonly) DWValuePresence localPresence;
@property(nonatomic,readonly) BOOL localHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence bufferLocalPresence;
@property(nonatomic,readonly) BOOL bufferLocalHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence nativeScreenPresence;
@property(nonatomic,readonly) BOOL nativeScreenHasNumericComponents;
@property(nonatomic,readonly,nullable) NSNumber *pick;
@property(nonatomic,readonly,nullable) NSNumber *placeholder;
@property(nonatomic,readonly,nullable) NSDictionary *nativeMember;
@property(nonatomic,readonly,nullable) DWIdentity *rootIdentity;
- (DWHit *)hitWithPick:(BOOL)pick;
- (DWHit *)hitWithPlaceholder:(BOOL)placeholder;
- (DWHit *)hitWithNativeMember:(NSDictionary *)member;
+ (instancetype)hitWithWindow:(nullable NSNumber *)window identity:(nullable DWIdentity *)identity generation:(nullable NSNumber *)generation local:(nullable NSValue *)local nativeMember:(nullable NSDictionary *)member pick:(nullable NSNumber *)pick widget:(nullable NSNumber *)widget pinned:(nullable NSNumber *)pinned;
// Native adapter compatibility: direct scalar doubleValue coercion.
@property(nonatomic,readonly) CGPoint nativeLocal;
@end
NS_ASSUME_NONNULL_END
