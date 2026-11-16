// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWRenderBackground : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *type;
@property(nonatomic,readonly,nullable) NSString *path;
@property(nonatomic,readonly,nullable) NSString *texture;
@property(nonatomic,readonly,nullable) NSNumber *mirrorTile;
@property(nonatomic,readonly,nullable) NSNumber *transparentShader;
@property(nonatomic,readonly,nullable) NSNumber *animateFPS;
@property(nonatomic,readonly,nullable) NSNumber *cacheShader;
@property(nonatomic,readonly,nullable) NSNumber *cacheBudgetMB;
@property(nonatomic,readonly,nullable) NSNumber *inheritMacOS;
@property(nonatomic,readonly,nullable) NSNumber *parallax;

@end
NS_ASSUME_NONNULL_END
