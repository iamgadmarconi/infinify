// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWIdentity;
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger,DWEffectKind) {
    DWEffectUnknown, DWEffectFocusNativeWindow, DWEffectResizeNativeWindow,
    DWEffectObserveResizeSource, DWEffectExec, DWEffectLaunch,
    DWEffectCloseWindow, DWEffectSetMinimized, DWEffectScreenshot
};
@interface DWEffect : DWControllerValue

@property(nonatomic,readonly) DWEffectKind kind;
@property(nonatomic,readonly,nullable) NSNumber *effectID;
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) DWIdentity *identity;
@property(nonatomic,readonly,nullable) NSNumber *generation;
// Equality and hash include every decoded field, including unrecognized future fields.

@end
NS_ASSUME_NONNULL_END
