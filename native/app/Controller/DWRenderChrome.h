// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWRGBA;
NS_ASSUME_NONNULL_BEGIN
@interface DWRenderChrome : DWControllerValue
@property(nonatomic,readonly,nullable) DWRGBA *background;
@property(nonatomic,readonly,nullable) DWRGBA *foreground;
@property(nonatomic,readonly,nullable) NSNumber *cornerRadius;
@property(nonatomic,readonly,nullable) NSNumber *titleBarHeight;
@property(nonatomic,readonly,nullable) NSString *font;
@property(nonatomic,readonly,nullable) NSNumber *fontSize;
@property(nonatomic,readonly,nullable) NSString *fontWeight;
@property(nonatomic,readonly,nullable) NSString *titleAlign;

@end
NS_ASSUME_NONNULL_END
