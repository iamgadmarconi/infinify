// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWRenderBackground, DWRenderChrome, DWRenderEffects, DWRenderOutline;
NS_ASSUME_NONNULL_BEGIN
@interface DWRender : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *revision;
@property(nonatomic,readonly,nullable) DWRenderBackground *background;
@property(nonatomic,readonly,nullable) DWRenderChrome *chrome;
@property(nonatomic,readonly,nullable) DWRenderOutline *outline;
@property(nonatomic,readonly,nullable) DWRenderEffects *effects;
@property(nonatomic,readonly,nullable) NSArray<NSString *> *errors;

@end
NS_ASSUME_NONNULL_END
