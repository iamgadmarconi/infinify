// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWRGBA;
NS_ASSUME_NONNULL_BEGIN
@interface DWDecoration : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *mode;
@property(nonatomic,readonly,nullable) NSNumber *borderWidth;
@property(nonatomic,readonly,nullable) DWRGBA *borderColor;
@property(nonatomic,readonly,nullable) DWRGBA *borderColorFocused;
@property(nonatomic,readonly,nullable) NSNumber *cornerRadius;
@property(nonatomic,readonly,nullable) NSNumber *shadow;
@property(nonatomic,readonly,nullable) NSNumber *shadowRadius;
@property(nonatomic,readonly,nullable) DWRGBA *shadowColor;
@property(nonatomic,readonly,nullable) NSNumber *opacity;
@property(nonatomic,readonly,nullable) NSNumber *blur;

@end
NS_ASSUME_NONNULL_END
